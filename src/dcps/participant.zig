//! DomainParticipantImpl — DCPS DomainParticipant implementation.
//!
//! Owns the RTPS GUID, transport, discovery, and security plugins.
//! Creates and tracks Publishers, Subscribers, Topics, and their underlying
//! RTPS ProtocolWriter/ProtocolReader protocol objects.
//!
//! Entity hierarchy:
//!   DomainParticipantFactory → DomainParticipantImpl
//!     → PublisherImpl → DataWriterImpl (+ RtpsProtocolWriter)
//!     → SubscriberImpl → DataReaderImpl (+ RtpsProtocolReader)
//!     → TopicImpl
//!
//! Lock ordering (to prevent deadlocks):
//!   participant.mu → StatefulWriter.mu / StatefulReader.mu
//! Discovery callbacks hold participant.mu and may call into RTPS state machines.
//! Never hold an RTPS lock while calling back up into the participant.

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const nil = @import("nil.zig");
const proto = @import("../protocol/interface.zig");
const trace_mod = @import("../trace.zig");
const config_mod = @import("../config/schema.zig");
const log_mod = @import("../log.zig");
const publisher_mod = @import("publisher.zig");
const subscriber_mod = @import("subscriber.zig");
const topic_mod = @import("topic.zig");
const filter_mod = @import("filter.zig");
const waitset = @import("waitset.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const adapters = @import("../rtps/protocol_adapters.zig");
const history_mod = @import("../rtps/history.zig");
const guid_mod = @import("../rtps/guid.zig");
const disc = @import("../discovery/interface.zig");
const transport_if = @import("../transport/interface.zig");
const security_if = @import("../security/interface.zig");
const parser_mod = @import("../rtps/message/parser.zig");
const submsg_mod = @import("../rtps/message/submessage.zig");
const time_mod = @import("../util/time.zig");
const build_opts = @import("build_options");
const qm_mod = @import("qos_match.zig");
const reader_mod = @import("reader.zig");
const writer_mod = @import("writer.zig");
const zidl_rt = @import("zidl_rt");

pub const Guid = guid_mod.Guid;
pub const GuidPrefix = guid_mod.GuidPrefix;
pub const EntityId = guid_mod.EntityId;
pub const EntityIds = guid_mod.EntityIds;
pub const EntityKind = guid_mod.EntityKind;
pub const Transport = transport_if.Transport;
pub const Locator = transport_if.Locator;
pub const Discovery = disc.Discovery;
pub const SecurityPlugins = security_if.SecurityPlugins;

fn parseIpv4(s: []const u8) ![4]u8 {
    return (try std.Io.net.Ip4Address.parse(s, 0)).bytes;
}

// ── Noop ProtocolReader for built-in subscriber DataReaders ──────────────────
//
// Built-in DataReaders receive samples via pushCdr() from discovery callbacks,
// not through the RTPS state machine. They carry a noop ProtocolReader so that
// DataReaderImpl.init() can call setDataCallback() without crashing.

var noop_pr_ctx: u8 = 0;

const noop_pr_vtable = proto.ProtocolReader.Vtable{
    .set_data_callback = struct {
        fn f(_: *anyopaque, _: proto.DataCallback) void {}
    }.f,
    .set_writer_match_callback = struct {
        fn f(_: *anyopaque, _: proto.WriterMatchCallback) void {}
    }.f,
    .add_matched_writer = struct {
        fn f(_: *anyopaque, _: *const proto.MatchedWriterInfo) anyerror!void {}
    }.f,
    .remove_matched_writer = struct {
        fn f(_: *anyopaque, _: proto.Guid) void {}
    }.f,
    .matched_writer_count = struct {
        fn f(_: *anyopaque) usize {
            return 0;
        }
    }.f,
    .list_matched_writers = struct {
        fn f(_: *anyopaque, _: std.mem.Allocator, _: *std.ArrayListUnmanaged(proto.Guid)) anyerror!void {}
    }.f,
    .handle_incoming_change = struct {
        fn f(_: *anyopaque, _: proto.Guid, _: proto.SequenceNumber, _: proto.RtpsTimestamp, _: [16]u8, _: []const u8, _: proto.ChangeKind) void {}
    }.f,
    .handle_heartbeat = struct {
        fn f(_: *anyopaque, _: proto.Guid, _: proto.SequenceNumber, _: proto.SequenceNumber, _: i32, _: bool) void {}
    }.f,
    .handle_data_frag = struct {
        fn f(_: *anyopaque, _: proto.Guid, _: proto.DataFragSubmessage) void {}
    }.f,
    .handle_heartbeat_frag = struct {
        fn f(_: *anyopaque, _: proto.Guid, _: proto.SequenceNumber, _: u32, _: i32) void {}
    }.f,
    .handle_gap = struct {
        fn f(_: *anyopaque, _: proto.Guid, _: proto.SequenceNumber, _: proto.SequenceNumberSet) void {}
    }.f,
    .historical_delivered = struct {
        fn f(_: *anyopaque) bool {
            return true;
        }
    }.f,
    .deinit = struct {
        fn f(_: *anyopaque) void {}
    }.f,
};

fn noopProtocolReader() proto.ProtocolReader {
    return .{ .ctx = @ptrCast(&noop_pr_ctx), .vtable = &noop_pr_vtable };
}

// ── BuiltinTopicDescImpl — minimal TopicDescription for built-in topics ───────

const BuiltinTopicDescImpl = struct {
    name: []const u8,
    type_name: []const u8,
    participant: DDS.DomainParticipant,

    const vtbl = DDS.TopicDescription.Vtable{
        .get_type_name = struct {
            fn f(ctx: *anyopaque) []const u8 {
                return cast(ctx).type_name;
            }
        }.f,
        .get_name = struct {
            fn f(ctx: *anyopaque) []const u8 {
                return cast(ctx).name;
            }
        }.f,
        .get_participant = struct {
            fn f(ctx: *anyopaque) DDS.DomainParticipant {
                return cast(ctx).participant;
            }
        }.f,
        .deinit = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    };

    fn cast(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }

    fn toTopicDescription(self: *@This()) DDS.TopicDescription {
        return .{ .ptr = self, .vtable = &vtbl };
    }
};

// ── BuiltinSubscriberState ────────────────────────────────────────────────────
//
// Holds the built-in Subscriber and its four DataReaders. Created once in
// DomainParticipantImpl.init(); torn down in deinit().
//
// Layout: this struct is heap-allocated. The four BuiltinTopicDescImpl fields
// are embedded (stable address), so their toTopicDescription() pointers remain
// valid for the lifetime of the struct.

const BuiltinSubscriberState = struct {
    alloc: std.mem.Allocator,
    sub: *subscriber_mod.SubscriberImpl,
    part_desc: BuiltinTopicDescImpl,
    topic_desc: BuiltinTopicDescImpl,
    pub_desc: BuiltinTopicDescImpl,
    sub_desc: BuiltinTopicDescImpl,
    part_dr: *reader_mod.DataReaderImpl,
    topic_dr: *reader_mod.DataReaderImpl,
    pub_dr: *reader_mod.DataReaderImpl,
    sub_dr: *reader_mod.DataReaderImpl,

    fn init(alloc: std.mem.Allocator, participant: *DomainParticipantImpl) !*@This() {
        const dp = participant.toDDSParticipant();

        const self = try alloc.create(@This());
        errdefer alloc.destroy(self);
        self.alloc = alloc;

        // Noop ParticipantCbs: no RTPS readers are created; destroy is a no-op.
        const noop_cbs = subscriber_mod.ParticipantCbs{
            .ctx = @ptrCast(participant),
            .create_proto_reader = struct {
                fn f(_: *anyopaque, _: []const u8, _: []const u8, _: DDS.DataReaderQos, _: DDS.InstanceHandle_t) anyerror!proto.ProtocolReader {
                    return noopProtocolReader();
                }
            }.f,
            .destroy_proto_reader = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t) void {}
            }.f,
            .next_handle = DomainParticipantImpl.nextHandle,
            .register_incompat_qos = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, i32) void) void {}
            }.f,
            .register_matched_notify = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, DDS.InstanceHandle_t, bool) void) void {}
            }.f,
            .announce_reader = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: []const []const u8, _: DDS.PresentationQosPolicy) void {}
            }.f,
            .timer_clock = participant.timer_clock,
            .register_timer_notify = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, i64) void) void {}
            }.f,
            .get_field_fn = struct {
                fn f(_: *anyopaque, _: []const u8) ?*const fn ([]const u8, []const u8) ?filter_mod.FilterValue {
                    return null;
                }
            }.f,
        };

        self.sub = try subscriber_mod.SubscriberImpl.init(
            alloc,
            dp,
            noop_cbs,
            .{},
            nil.nil_sub_listener,
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
        );
        errdefer self.sub.deinit();

        const sub_dds = self.sub.toDDSSubscriber();

        // Embedded topic descriptions — their addresses are stable because self
        // is heap-allocated; assignments here set their initial values.
        self.part_desc = .{ .name = "DCPSParticipant", .type_name = "ParticipantBuiltinTopicData", .participant = dp };
        self.topic_desc = .{ .name = "DCPSTopic", .type_name = "TopicBuiltinTopicData", .participant = dp };
        self.pub_desc = .{ .name = "DCPSPublication", .type_name = "PublicationBuiltinTopicData", .participant = dp };
        self.sub_desc = .{ .name = "DCPSSubscription", .type_name = "SubscriptionBuiltinTopicData", .participant = dp };

        // Create all four DataReaders; track how many succeeded for errdefer.
        var readers: [4]*reader_mod.DataReaderImpl = undefined;
        var n_ok: usize = 0;
        errdefer for (readers[0..n_ok]) |r| r.deinit();

        readers[0] = try reader_mod.DataReaderImpl.init(
            alloc,
            self.part_desc.toTopicDescription(),
            sub_dds,
            noopProtocolReader(),
            .{},
            nil.nil_dr_listener,
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
            participant.timer_clock,
        );
        n_ok = 1;
        readers[1] = try reader_mod.DataReaderImpl.init(
            alloc,
            self.topic_desc.toTopicDescription(),
            sub_dds,
            noopProtocolReader(),
            .{},
            nil.nil_dr_listener,
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
            participant.timer_clock,
        );
        n_ok = 2;
        readers[2] = try reader_mod.DataReaderImpl.init(
            alloc,
            self.pub_desc.toTopicDescription(),
            sub_dds,
            noopProtocolReader(),
            .{},
            nil.nil_dr_listener,
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
            participant.timer_clock,
        );
        n_ok = 3;
        readers[3] = try reader_mod.DataReaderImpl.init(
            alloc,
            self.sub_desc.toTopicDescription(),
            sub_dds,
            noopProtocolReader(),
            .{},
            nil.nil_dr_listener,
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
            participant.timer_clock,
        );
        n_ok = 4;

        // Pre-reserve capacity so appends below are infallible.
        self.sub.mu.lock();
        self.sub.readers.ensureUnusedCapacity(alloc, 4) catch {
            self.sub.mu.unlock();
            return error.OutOfMemory;
        };
        for (readers) |r| self.sub.readers.appendAssumeCapacity(r);
        self.sub.mu.unlock();

        // Ownership transferred to sub.readers; suppress individual errdefers.
        n_ok = 0;

        self.part_dr = readers[0];
        self.topic_dr = readers[1];
        self.pub_dr = readers[2];
        self.sub_dr = readers[3];

        return self;
    }

    fn deinit(self: *@This()) void {
        // sub.deinit() calls destroy_proto_reader (noop) + r.deinit() for each
        // reader in sub.readers, which covers our four DataReaderImpls.
        self.sub.deinit();
        self.alloc.destroy(self);
    }
};

// ── Built-in topic CDR serialization helpers ──────────────────────────────────
//
// Called from discovery callbacks AFTER releasing participant.mu, so that
// DataReaderImpl.pushCdr() (which fires listener callbacks) does not run
// with participant.mu held.

fn pushBuiltinParticipantCdr(
    alloc: std.mem.Allocator,
    dr: *reader_mod.DataReaderImpl,
    data: *const disc.ParticipantData,
) void {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = zidl_rt.CdrWriter(.xcdr1).init(&buf, alloc);
    w.writeEncapHeader() catch return;
    const v = DDS.ParticipantBuiltinTopicData{
        .key = writer_mod.guidToBuiltinKey(data.guid),
        .user_data = .{},
    };
    DDS.ParticipantBuiltinTopicData.serialize(&w, v) catch return;
    dr.pushCdr(buf.items);
}

fn qosReliability(kind: u8) DDS.ReliabilityQosPolicy {
    return .{ .kind = if (kind == 1) .RELIABLE_RELIABILITY_QOS else .BEST_EFFORT_RELIABILITY_QOS };
}
fn qosDurability(kind: u8) DDS.DurabilityQosPolicy {
    return .{ .kind = @enumFromInt(kind) };
}
fn qosLiveliness(kind: u8) DDS.LivelinessQosPolicy {
    return .{ .kind = @enumFromInt(kind) };
}
fn qosOwnership(kind: u8) DDS.OwnershipQosPolicy {
    return .{ .kind = if (kind == 1) .EXCLUSIVE_OWNERSHIP_QOS else .SHARED_OWNERSHIP_QOS };
}
fn qosDestOrder(kind: u8) DDS.DestinationOrderQosPolicy {
    return .{ .kind = if (kind == 1) .BY_SOURCE_TIMESTAMP_DESTINATIONORDER_QOS else .BY_RECEPTION_TIMESTAMP_DESTINATIONORDER_QOS };
}

fn pushBuiltinPublicationCdr(
    alloc: std.mem.Allocator,
    dr: *reader_mod.DataReaderImpl,
    data: *const disc.WriterData,
) void {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = zidl_rt.CdrWriter(.xcdr1).init(&buf, alloc);
    w.writeEncapHeader() catch return;
    const v = DDS.PublicationBuiltinTopicData{
        .key = writer_mod.guidToBuiltinKey(data.guid),
        .participant_key = writer_mod.guidToBuiltinKey(data.participant_guid),
        .topic_name = data.topic_name,
        .type_name = data.type_name,
        .reliability = qosReliability(data.qos.reliability_kind),
        .durability = qosDurability(data.qos.durability_kind),
        .liveliness = qosLiveliness(data.qos.liveliness_kind),
        .ownership = qosOwnership(data.qos.ownership_kind),
        .destination_order = qosDestOrder(data.qos.destination_order_kind),
    };
    DDS.PublicationBuiltinTopicData.serialize(&w, v) catch return;
    dr.pushCdr(buf.items);
}

fn pushBuiltinSubscriptionCdr(
    alloc: std.mem.Allocator,
    dr: *reader_mod.DataReaderImpl,
    data: *const disc.ReaderData,
) void {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = zidl_rt.CdrWriter(.xcdr1).init(&buf, alloc);
    w.writeEncapHeader() catch return;
    const v = DDS.SubscriptionBuiltinTopicData{
        .key = writer_mod.guidToBuiltinKey(data.guid),
        .participant_key = writer_mod.guidToBuiltinKey(data.participant_guid),
        .topic_name = data.topic_name,
        .type_name = data.type_name,
        .reliability = qosReliability(data.qos.reliability_kind),
        .durability = qosDurability(data.qos.durability_kind),
        .liveliness = qosLiveliness(data.qos.liveliness_kind),
        .ownership = qosOwnership(data.qos.ownership_kind),
        .destination_order = qosDestOrder(data.qos.destination_order_kind),
    };
    DDS.SubscriptionBuiltinTopicData.serialize(&w, v) catch return;
    dr.pushCdr(buf.items);
}

fn pushBuiltinTopicCdr(
    alloc: std.mem.Allocator,
    dr: *reader_mod.DataReaderImpl,
    v: DDS.TopicBuiltinTopicData,
) void {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = zidl_rt.CdrWriter(.xcdr1).init(&buf, alloc);
    w.writeEncapHeader() catch return;
    DDS.TopicBuiltinTopicData.serialize(&w, v) catch return;
    dr.pushCdr(buf.items);
}

/// Deterministic BuiltinTopicKey_t derived from the topic name.
/// Three independent FNV-1a passes with different initial values.
fn topicNameToKey(topic_name: []const u8) DDS.BuiltinTopicKey_t {
    const ivs = [3]u32{ 0xd95c1265, 0x811c9dc5, 0x40503259 };
    var vals: [3]i32 = undefined;
    for (&vals, ivs) |*v, iv| {
        var h: u32 = iv;
        for (topic_name) |b| {
            h ^= b;
            h *%= 16777619;
        }
        v.* = @bitCast(h);
    }
    return .{ .value = vals };
}

/// Deterministic instance handle derived from topic name + type name.
fn topicToHandle(topic_name: []const u8, type_name: []const u8) DDS.InstanceHandle_t {
    var h: u32 = 2166136261;
    for (topic_name) |b| {
        h ^= b;
        h *%= 16777619;
    }
    h ^= 0xFF;
    for (type_name) |b| {
        h ^= b;
        h *%= 16777619;
    }
    const v: i32 = @intCast(h & 0x7FFF_FFFF);
    return if (v == 0) 1 else v;
}

// ── Per-writer / per-reader tracking ─────────────────────────────────────────

/// Callback registered by DataWriterImpl / DataReaderImpl so that the participant
/// can notify them of an incompatible-QoS event from the discovery thread.
const IncompatQosNotify = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque, policy_id: i32) void,
};

/// Callback registered by DataWriterImpl / DataReaderImpl so that the participant
/// can fire on_publication_matched / on_subscription_matched when a remote entity
/// matches or unmatches.  `added` is true on match, false on unmatch.
const MatchedNotify = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque, remote_handle: DDS.InstanceHandle_t, added: bool) void,
};

/// Callback registered by DataWriterImpl / DataReaderImpl so that the participant
/// can invoke periodic timer checks (DEADLINE, LIVELINESS) via checkTimers().
const TimerNotify = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, now_ns: i64) void,
};

/// Callback registered by DataWriterImpl so that the participant can assert
/// liveliness on all relevant writers via vtAssertLiveliness().
const AssertNotify = struct {
    ctx: *anyopaque,
    assert_fn: *const fn (ctx: *anyopaque) void,
};

const DiscoveredParticipant = struct {
    guid: Guid,
    handle: DDS.InstanceHandle_t,
};

const DiscoveredTopic = struct {
    topic_name: []const u8, // owned (heap-allocated)
    type_name: []const u8, // owned (heap-allocated)
    handle: DDS.InstanceHandle_t,
    reliability_kind: u8,
    durability_kind: u8,
    liveliness_kind: u8,
    ownership_kind: u8,
    dest_order_kind: u8,
};

/// Callback table registered per type name via registerTypeSupport().
/// Used to compute key hashes from CDR payloads when a received change
/// carries no inline-QoS key_hash.  Keyed types should register this to
/// enable per-instance OWNERSHIP, TIME_BASED_FILTER, and SampleInfo tracking.
pub const TypeSupport = struct {
    /// Compute the 16-byte DDS key hash from a CDR-encoded payload.
    /// `payload` includes the 4-byte encapsulation header (as received from
    /// the wire).  Return `zeroes([16]u8)` for keyless types.
    compute_key_hash: *const fn (payload: []const u8) [16]u8,
    /// Optional: extract a named field value from a raw CDR payload.
    /// Used to evaluate ContentFilteredTopic expressions at delivery time.
    /// null = CFT evaluation deferred to the typed DataReader layer.
    get_field: ?*const fn (payload: []const u8, field: []const u8) ?filter_mod.FilterValue = null,
};

const ActiveWriter = struct {
    handle: DDS.InstanceHandle_t,
    guid: Guid,
    proto: proto.ProtocolWriter,
    topic_name: []const u8, // borrowed from topic_name slice in active list
    type_name: []const u8,
    qos: DDS.DataWriterQos,
    partition_names: []const []const u8 = &.{}, // publisher's partition names (borrowed)
    presentation: DDS.PresentationQosPolicy = .{},
    incompat_qos: ?IncompatQosNotify = null,
    matched_notify: ?MatchedNotify = null,
    timer_check: ?TimerNotify = null,
    liveliness_assert: ?AssertNotify = null,
};

const ActiveReader = struct {
    handle: DDS.InstanceHandle_t,
    guid: Guid,
    proto: proto.ProtocolReader,
    topic_name: []const u8,
    type_name: []const u8,
    qos: DDS.DataReaderQos,
    partition_names: []const []const u8 = &.{}, // subscriber's partition names (borrowed)
    presentation: DDS.PresentationQosPolicy = .{},
    incompat_qos: ?IncompatQosNotify = null,
    matched_notify: ?MatchedNotify = null,
    timer_check: ?TimerNotify = null,
    key_hash_fn: ?*const fn ([]const u8) [16]u8 = null,
};

// ── DomainParticipantImpl ────────────────────────────────────────────────────

pub const DomainParticipantImpl = struct {
    alloc: std.mem.Allocator,
    domain_id: DDS.DomainId_t,
    guid: Guid,
    qos: DDS.DomainParticipantQos,
    listener: DDS.DomainParticipantListener,
    listener_mask: DDS.StatusMask,
    instance_handle: DDS.InstanceHandle_t,
    status_changes: DDS.StatusMask,
    status_cond: ?*waitset.StatusConditionImpl,
    transport: Transport,
    discovery: Discovery,
    security: SecurityPlugins,
    config: config_mod.Config,

    publishers: std.ArrayListUnmanaged(*publisher_mod.PublisherImpl),
    subscribers: std.ArrayListUnmanaged(*subscriber_mod.SubscriberImpl),
    topics: std.ArrayListUnmanaged(*topic_mod.TopicImpl),
    cft_topics: std.ArrayListUnmanaged(*topic_mod.ContentFilteredTopicImpl),

    active_writers: std.AutoHashMapUnmanaged(u32, ActiveWriter),
    active_readers: std.AutoHashMapUnmanaged(u32, ActiveReader),

    /// Cache of discovered remote participants; keyed by GUID, guarded by mu.
    discovered_participants: std.ArrayListUnmanaged(DiscoveredParticipant),

    /// GUID prefixes passed to ignore_participant(); all discovery events from
    /// these prefixes are silently dropped.  Guarded by mu.
    ignored_prefixes: std.ArrayListUnmanaged(GuidPrefix),

    /// Topic names passed to ignore_topic(); discovery events for these topics
    /// are silently dropped.  Owned strings.  Guarded by mu.
    ignored_topic_names: std.ArrayListUnmanaged([]const u8),

    /// Handles of remote publications passed to ignore_publication().
    /// Derived via guidToHandle(remote_writer_guid).  Guarded by mu.
    ignored_publication_handles: std.ArrayListUnmanaged(DDS.InstanceHandle_t),

    /// Handles of remote subscriptions passed to ignore_subscription().
    /// Derived via guidToHandle(remote_reader_guid).  Guarded by mu.
    ignored_subscription_handles: std.ArrayListUnmanaged(DDS.InstanceHandle_t),

    /// Topics discovered via SEDP writer/reader announcements, deduped by
    /// (topic_name, type_name).  Backing strings are owned.  Guarded by mu.
    discovered_topics: std.ArrayListUnmanaged(DiscoveredTopic),

    /// Built-in subscriber (DCPSParticipant / DCPSTopic / DCPSPublication /
    /// DCPSSubscription DataReaders). Created in init(); null on OOM.
    builtin_sub: ?*BuiltinSubscriberState,

    /// Maps type_name → CDR-encoded XTypes TypeInformation blob.
    /// Populated by registerTypeInfo(); consulted when announcing writers/readers.
    type_info_registry: std.StringHashMapUnmanaged([]const u8),

    /// Maps type_name → TypeSupport callbacks.
    /// Populated by registerTypeSupport(); consulted when a received change has no inline key_hash.
    type_support_registry: std.StringHashMapUnmanaged(TypeSupport),

    default_pub_qos: DDS.PublisherQos,
    default_sub_qos: DDS.SubscriberQos,
    default_topic_qos: DDS.TopicQos,

    /// Entity ID counter; protected by `mu`.  Wraps at 2^24.
    next_entity_key: u32,
    /// InstanceHandle counter; protected by `mu`.
    next_handle_val: DDS.InstanceHandle_t,

    /// Stable heap address — passed to `discovery.start()`.
    disc_callbacks: disc.Callbacks,

    /// Port on which we listen for user DataWriter traffic.
    /// 0 = not yet listening (before start()).  Used by deinit() to unlisten.
    data_listen_port: u16,

    /// Wire tracer applied to all user-plane protocol adapters (zero-size when disabled).
    tracer: trace_mod.Tracer,

    /// Monotonic clock used for internal interval timers (deadline, liveliness).
    /// Resolved from the factory's ClockRegistry at participant creation time.
    timer_clock: time_mod.Clock,

    mu: Mutex,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        domain_id: DDS.DomainId_t,
        guid: Guid,
        transport: Transport,
        discovery: Discovery,
        security: SecurityPlugins,
        config: config_mod.Config,
        qos: DDS.DomainParticipantQos,
        listener: DDS.DomainParticipantListener,
        mask: DDS.StatusMask,
        handle: DDS.InstanceHandle_t,
        tracer: trace_mod.Tracer,
        timer_clock: time_mod.Clock,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .domain_id = domain_id,
            .guid = guid,
            .qos = qos,
            .listener = listener,
            .listener_mask = mask,
            .instance_handle = handle,
            .status_changes = 0,
            .status_cond = null,
            .transport = transport,
            .discovery = discovery,
            .security = security,
            .config = config,
            .publishers = .empty,
            .subscribers = .empty,
            .topics = .empty,
            .cft_topics = .empty,
            .active_writers = .empty,
            .active_readers = .empty,
            .discovered_participants = .empty,
            .ignored_prefixes = .empty,
            .ignored_topic_names = .empty,
            .ignored_publication_handles = .empty,
            .ignored_subscription_handles = .empty,
            .discovered_topics = .empty,
            .builtin_sub = null,
            .type_info_registry = .empty,
            .type_support_registry = .empty,
            .default_pub_qos = .{},
            .default_sub_qos = .{},
            .default_topic_qos = .{},
            .next_entity_key = 1,
            .next_handle_val = 2, // 1 is reserved for the participant's own handle
            .disc_callbacks = .{
                .ctx = self,
                .on_participant_discovered = onParticipantDiscovered,
                .on_participant_lost = onParticipantLost,
                .on_writer_discovered = onWriterDiscovered,
                .on_writer_lost = onWriterLost,
                .on_reader_discovered = onReaderDiscovered,
                .on_reader_lost = onReaderLost,
            },
            .data_listen_port = 0,
            .tracer = tracer,
            .timer_clock = timer_clock,
            .mu = .{},
        };
        errdefer alloc.destroy(self);
        const sc = try waitset.StatusConditionImpl.init(alloc, self.toEntity(), getStatusFn);
        self.status_cond = sc;
        self.builtin_sub = BuiltinSubscriberState.init(alloc, self) catch null;
        return self;
    }

    /// Start discovery. Call once after init(). The discovery plugin begins
    /// announcing the participant and delivering remote-endpoint callbacks.
    pub fn start(self: *Self) !void {
        const udp_cfg = &self.config.transport.udp;
        const part_cfg = &self.config.participant;

        // Metatraffic unicast locators come from the transport (already computed
        // using the configured port formula).
        var meta_locators: std.ArrayListUnmanaged(Locator) = .empty;
        defer meta_locators.deinit(self.alloc);
        try self.transport.unicastLocators(&meta_locators, self.alloc);

        // Data unicast locators. Two cases:
        //   data_unicast_port override → fixed port for all interfaces
        //   default → meta port + (D3 - D1) offset
        var data_locators: std.ArrayListUnmanaged(Locator) = .empty;
        defer data_locators.deinit(self.alloc);
        if (udp_cfg.data_unicast_port) |dp| {
            for (meta_locators.items) |loc| {
                switch (loc) {
                    .udp_v4 => |u| try data_locators.append(self.alloc, Locator.udp4(u.addr, dp)),
                    .udp_v6 => |u| try data_locators.append(self.alloc, Locator{ .udp_v6 = .{ .addr = u.addr, .port = dp } }),
                    else => {},
                }
            }
            self.data_listen_port = dp;
        } else {
            const port_delta: u16 = udp_cfg.data_unicast_offset - udp_cfg.meta_unicast_offset;
            for (meta_locators.items) |loc| {
                switch (loc) {
                    .udp_v4 => |u| {
                        const dp = u.port + port_delta;
                        try data_locators.append(self.alloc, Locator.udp4(u.addr, dp));
                        if (self.data_listen_port == 0) self.data_listen_port = dp;
                    },
                    .udp_v6 => |u| {
                        const dp = u.port + port_delta;
                        try data_locators.append(self.alloc, Locator{ .udp_v6 = .{ .addr = u.addr, .port = dp } });
                        if (self.data_listen_port == 0) self.data_listen_port = dp;
                    },
                    else => {},
                }
            }
        }

        // SPDP metatraffic multicast locator derived from config.
        const mc_port = config_mod.metatrafficMulticastPort(udp_cfg, self.domain_id);
        var mc_locs_buf: [1]Locator = undefined;
        var mc_locs: []const Locator = &.{};
        if (udp_cfg.multicast_group_v4.len > 0) {
            const mc_ip = parseIpv4(udp_cfg.multicast_group_v4) catch blk: {
                log_mod.dcps.warn("participant: invalid multicast_group_v4 '{s}'; skipping multicast locator", .{udp_cfg.multicast_group_v4});
                break :blk null;
            };
            if (mc_ip) |ip| {
                mc_locs_buf[0] = Locator.udp4(ip, mc_port);
                mc_locs = mc_locs_buf[0..1];
            }
        }

        // All six SPDP + SEDP built-in endpoints (RTPS §8.5.4.2 Table 8.58).
        const BUILTIN_ENDPOINTS: u32 =
            0x00000001 | // DISC_BUILTIN_ENDPOINT_PARTICIPANT_ANNOUNCER
            0x00000002 | // DISC_BUILTIN_ENDPOINT_PARTICIPANT_DETECTOR
            0x00000004 | // DISC_BUILTIN_ENDPOINT_PUBLICATIONS_ANNOUNCER
            0x00000008 | // DISC_BUILTIN_ENDPOINT_PUBLICATIONS_DETECTOR
            0x00000010 | // DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_ANNOUNCER
            0x00000020; // DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_DETECTOR

        const ann = disc.ParticipantAnnouncement{
            .guid = self.guid,
            .domain_id = self.domain_id,
            .name = part_cfg.name,
            .metatraffic_unicast_locators = meta_locators.items,
            .metatraffic_multicast_locators = mc_locs,
            .default_unicast_locators = data_locators.items,
            .default_multicast_locators = &.{},
            .lease_duration_ms = part_cfg.lease_duration_ms,
            .builtin_endpoint_set = BUILTIN_ENDPOINTS,
            .initial_peers = udp_cfg.initial_peers,
        };
        try self.discovery.start(&ann, &self.disc_callbacks);

        // Listen on the data unicast port for user DataWriter traffic.
        if (self.data_listen_port != 0) {
            const listen_loc = Locator.udp4(.{ 0, 0, 0, 0 }, self.data_listen_port);
            try self.transport.listen(&listen_loc, transport_if.ReceiveHandler{
                .ctx = self,
                .on_receive = userDataOnReceive,
            });
        }
    }

    pub fn deinit(self: *Self) void {
        self.discovery.stop();

        // Stop receiving user data before tearing down readers.
        if (self.data_listen_port != 0) {
            const loc = Locator.udp4(.{ 0, 0, 0, 0 }, self.data_listen_port);
            self.transport.unlisten(&loc, transport_if.ReceiveHandler{
                .ctx = self,
                .on_receive = userDataOnReceive,
            });
        }

        if (self.status_cond) |sc| sc.deinit();
        if (self.builtin_sub) |bs| bs.deinit();

        // Drain publishers, subscribers, topics.
        // Do NOT hold participant.mu while calling deinit() — publisher/subscriber
        // deinit() calls destroy_proto_writer/reader callbacks that re-lock mu.
        var pubs = self.publishers;
        var subs = self.subscribers;
        var tops = self.topics;
        var cfts = self.cft_topics;
        self.publishers = .empty;
        self.subscribers = .empty;
        self.topics = .empty;
        self.cft_topics = .empty;

        for (pubs.items) |p| p.deinit();
        pubs.deinit(self.alloc);
        for (subs.items) |s| s.deinit();
        subs.deinit(self.alloc);
        for (tops.items) |t| t.deinit();
        tops.deinit(self.alloc);
        for (cfts.items) |c| c.deinit();
        cfts.deinit(self.alloc);

        self.type_info_registry.deinit(self.alloc);
        self.type_support_registry.deinit(self.alloc);

        // Any remaining active writers/readers (normally all removed by pub/sub deinit).
        var wit = self.active_writers.valueIterator();
        while (wit.next()) |aw| aw.proto.deinit();
        self.active_writers.deinit(self.alloc);
        var rit = self.active_readers.valueIterator();
        while (rit.next()) |ar| ar.proto.deinit();
        self.active_readers.deinit(self.alloc);
        self.discovered_participants.deinit(self.alloc);
        self.ignored_prefixes.deinit(self.alloc);
        for (self.ignored_topic_names.items) |n| self.alloc.free(n);
        self.ignored_topic_names.deinit(self.alloc);
        self.ignored_publication_handles.deinit(self.alloc);
        self.ignored_subscription_handles.deinit(self.alloc);
        for (self.discovered_topics.items) |dt| {
            self.alloc.free(dt.topic_name);
            self.alloc.free(dt.type_name);
        }
        self.discovered_topics.deinit(self.alloc);

        self.alloc.destroy(self);
    }

    pub fn toDDSParticipant(self: *Self) DDS.DomainParticipant {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Associate a CDR-encoded XTypes TypeInformation blob with a type name.
    /// The caller owns `cdr`; it must remain valid for the lifetime of the participant.
    /// Called before creating DataWriters/DataReaders for the type.
    /// Register TypeSupport callbacks for a type name.
    /// Call before creating DataReaders for the type.  The caller must ensure
    /// `type_name` remains valid for the lifetime of the participant.
    pub fn registerTypeSupport(self: *Self, type_name: []const u8, ts: TypeSupport) void {
        self.type_support_registry.put(self.alloc, type_name, ts) catch {};
    }

    pub fn registerTypeInfo(self: *Self, type_name: []const u8, cdr: []const u8) void {
        if (!build_opts.xtypes) return;
        self.type_info_registry.put(self.alloc, type_name, cdr) catch {};
    }

    fn toEntity(self: *Self) DDS.Entity {
        return .{ .ptr = self, .vtable = &entity_vtable };
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    /// Used as `get_participant_fn` in TopicImpl so Topics can return the
    /// participant handle without a circular import.
    fn getDDSParticipant(ctx: *anyopaque) DDS.DomainParticipant {
        return cast(ctx).toDDSParticipant();
    }

    /// Allocate the next entity key.  Caller must hold `mu`.
    fn nextEntityKeyLocked(self: *Self) [3]u8 {
        const k = self.next_entity_key;
        self.next_entity_key +%= 1;
        return .{
            @truncate((k >> 16) & 0xFF),
            @truncate((k >> 8) & 0xFF),
            @truncate(k & 0xFF),
        };
    }

    fn nextHandle(ctx: *anyopaque) DDS.InstanceHandle_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        const h = self.next_handle_val;
        self.next_handle_val +%= 1;
        return h;
    }

    // ── PublisherImpl callbacks ───────────────────────────────────────────────

    fn pubCreateProtoWriter(
        ctx: *anyopaque,
        topic_name: []const u8,
        type_name: []const u8,
        qos: DDS.DataWriterQos,
        handle: DDS.InstanceHandle_t,
    ) anyerror!proto.ProtocolWriter {
        const self = cast(ctx);

        self.mu.lock();
        const key = self.nextEntityKeyLocked();
        self.mu.unlock();

        const guid = Guid{
            .prefix = self.guid.prefix,
            .entity_id = .{
                .entity_key = key,
                .entity_kind = EntityKind.user_writer_with_key,
            },
        };

        const cache_kind: history_mod.HistoryKind = if (qos.history.kind == .KEEP_ALL_HISTORY_QOS)
            .keep_all
        else
            .keep_last;
        const cache_depth: u32 = if (cache_kind == .keep_last)
            @max(1, @as(u32, @bitCast(qos.history.depth)))
        else
            0;
        const replay_on_match = qos.durability.kind != .VOLATILE_DURABILITY_QOS;
        const adapter = try adapters.RtpsProtocolWriter.init(
            self.alloc,
            guid,
            self.transport,
            cache_kind,
            cache_depth,
            EntityIds.unknown,
            self.config.rtps.fragment_size,
            replay_on_match,
        );
        errdefer adapter.deinit();
        adapter.setTracer(self.tracer);

        const pw = adapter.toProtocolWriter();

        {
            self.mu.lock();
            defer self.mu.unlock();
            try self.active_writers.put(self.alloc, entityIdKey(guid.entity_id), .{
                .handle = handle,
                .guid = guid,
                .proto = pw,
                .topic_name = topic_name,
                .type_name = type_name,
                .qos = qos,
            });
        }

        return pw;
    }

    fn pubDestroyProtoWriter(ctx: *anyopaque, handle: DDS.InstanceHandle_t) void {
        const self = cast(ctx);
        var found_guid: ?Guid = null;
        var found_proto: ?proto.ProtocolWriter = null;

        self.mu.lock();
        var writ = self.active_writers.valueIterator();
        while (writ.next()) |aw| {
            if (aw.handle == handle) {
                found_guid = aw.guid;
                found_proto = aw.proto;
                break;
            }
        }
        if (found_guid) |g| _ = self.active_writers.remove(entityIdKey(g.entity_id));
        self.mu.unlock();

        if (found_guid) |g| self.discovery.retractWriter(g);
        if (found_proto) |p| p.deinit();
    }

    // ── SubscriberImpl callbacks ──────────────────────────────────────────────

    fn subCreateProtoReader(
        ctx: *anyopaque,
        topic_name: []const u8,
        type_name: []const u8,
        qos: DDS.DataReaderQos,
        handle: DDS.InstanceHandle_t,
    ) anyerror!proto.ProtocolReader {
        const self = cast(ctx);

        self.mu.lock();
        const key = self.nextEntityKeyLocked();
        self.mu.unlock();

        const guid = Guid{
            .prefix = self.guid.prefix,
            .entity_id = .{
                .entity_key = key,
                .entity_kind = EntityKind.user_reader_with_key,
            },
        };

        const r_cache_kind: history_mod.HistoryKind = if (qos.history.kind == .KEEP_ALL_HISTORY_QOS)
            .keep_all
        else
            .keep_last;
        const r_cache_depth: u32 = if (r_cache_kind == .keep_last)
            @max(1, @as(u32, @bitCast(qos.history.depth)))
        else
            0;
        const r_reliable = qos.reliability.kind == .RELIABLE_RELIABILITY_QOS;
        const adapter = try adapters.RtpsProtocolReader.init(
            self.alloc,
            guid,
            self.transport,
            r_cache_kind,
            r_cache_depth,
            r_reliable,
        );
        errdefer adapter.deinit();
        adapter.setTracer(self.tracer);

        const pr = adapter.toProtocolReader();

        {
            self.mu.lock();
            defer self.mu.unlock();
            try self.active_readers.put(self.alloc, entityIdKey(guid.entity_id), .{
                .handle = handle,
                .guid = guid,
                .proto = pr,
                .topic_name = topic_name,
                .type_name = type_name,
                .qos = qos,
                .key_hash_fn = if (self.type_support_registry.get(type_name)) |ts|
                    ts.compute_key_hash
                else
                    null,
            });
        }

        return pr;
    }

    fn subDestroyProtoReader(ctx: *anyopaque, handle: DDS.InstanceHandle_t) void {
        const self = cast(ctx);
        var found_guid: ?Guid = null;
        var found_proto: ?proto.ProtocolReader = null;

        self.mu.lock();
        var rrit = self.active_readers.valueIterator();
        while (rrit.next()) |ar| {
            if (ar.handle == handle) {
                found_guid = ar.guid;
                found_proto = ar.proto;
                break;
            }
        }
        if (found_guid) |g| _ = self.active_readers.remove(entityIdKey(g.entity_id));
        self.mu.unlock();

        if (found_guid) |g| self.discovery.retractReader(g);
        if (found_proto) |p| p.deinit();
    }

    // ── QoS → discovery snapshot conversion ──────────────────────────────────

    fn writerQosSnapshot(qos: DDS.DataWriterQos, presentation: DDS.PresentationQosPolicy) disc.QosSnapshot {
        const keep_last = qos.history.kind != .KEEP_ALL_HISTORY_QOS;
        // DDS spec: deadline default is DURATION_INFINITE; {0,0} from codegen means unset → treat as infinite.
        const dl_zero_w = qos.deadline.period.sec == 0 and qos.deadline.period.nanosec == 0;
        // Liveliness lease: {0,0} from codegen means unset → treat as infinite.
        const ll_zero_w = qos.liveliness.lease_duration.sec == 0 and qos.liveliness.lease_duration.nanosec == 0;
        return .{
            .reliability_kind = if (qos.reliability.kind == .RELIABLE_RELIABILITY_QOS) @as(u8, 1) else 0,
            .durability_kind = @as(u8, @truncate(@intFromEnum(qos.durability.kind))),
            .history_kind = if (qos.history.kind == .KEEP_ALL_HISTORY_QOS) @as(u8, 1) else 0,
            // DDS spec: KEEP_LAST depth must be >= 1; default 0 from codegen → clamp to 1.
            .history_depth = if (keep_last and qos.history.depth < 1) 1 else qos.history.depth,
            .liveliness_kind = @as(u8, @truncate(@intFromEnum(qos.liveliness.kind))),
            .liveliness_lease_sec = if (ll_zero_w) 0x7fff_ffff else qos.liveliness.lease_duration.sec,
            .liveliness_lease_nanosec = if (ll_zero_w) 0x7fff_ffff else qos.liveliness.lease_duration.nanosec,
            .ownership_kind = if (qos.ownership.kind == .EXCLUSIVE_OWNERSHIP_QOS) @as(u8, 1) else 0,
            .ownership_strength = qos.ownership_strength.value,
            .destination_order_kind = if (qos.destination_order.kind == .BY_SOURCE_TIMESTAMP_DESTINATIONORDER_QOS) @as(u8, 1) else 0,
            .data_representation = if (comptime build_opts.xtypes)
                reprFromQos(qos.data_representation.value.items)
            else
                1,
            .deadline_sec = if (dl_zero_w) 0x7fff_ffff else qos.deadline.period.sec,
            .deadline_nanosec = if (dl_zero_w) 0x7fff_ffff else qos.deadline.period.nanosec,
            .presentation_access_scope = @as(u8, @intCast(@intFromEnum(presentation.access_scope))),
            .coherent_access = presentation.coherent_access,
            .ordered_access = presentation.ordered_access,
        };
    }

    fn readerQosSnapshot(qos: DDS.DataReaderQos, presentation: DDS.PresentationQosPolicy) disc.QosSnapshot {
        const keep_last = qos.history.kind != .KEEP_ALL_HISTORY_QOS;
        // DDS spec: deadline default is DURATION_INFINITE; {0,0} from codegen means unset → treat as infinite.
        const dl_zero_r = qos.deadline.period.sec == 0 and qos.deadline.period.nanosec == 0;
        return .{
            .reliability_kind = if (qos.reliability.kind == .RELIABLE_RELIABILITY_QOS) @as(u8, 1) else 0,
            .durability_kind = @as(u8, @truncate(@intFromEnum(qos.durability.kind))),
            .history_kind = if (qos.history.kind == .KEEP_ALL_HISTORY_QOS) @as(u8, 1) else 0,
            // DDS spec: KEEP_LAST depth must be >= 1; default 0 from codegen → clamp to 1.
            .history_depth = if (keep_last and qos.history.depth < 1) 1 else qos.history.depth,
            .liveliness_kind = @as(u8, @truncate(@intFromEnum(qos.liveliness.kind))),
            .ownership_kind = if (qos.ownership.kind == .EXCLUSIVE_OWNERSHIP_QOS) @as(u8, 1) else 0,
            .destination_order_kind = if (qos.destination_order.kind == .BY_SOURCE_TIMESTAMP_DESTINATIONORDER_QOS) @as(u8, 1) else 0,
            .data_representation = if (comptime build_opts.xtypes)
                reprFromQos(qos.data_representation.value.items)
            else
                2, // Advertise XCDR2 acceptance so XCDR2-capable writers (OpenDDS) match.
            // zzdds stores raw CDR bytes and interop programs parse both XCDR1/2.
            .deadline_sec = if (dl_zero_r) 0x7fff_ffff else qos.deadline.period.sec,
            .deadline_nanosec = if (dl_zero_r) 0x7fff_ffff else qos.deadline.period.nanosec,
            .presentation_access_scope = @as(u8, @intCast(@intFromEnum(presentation.access_scope))),
            .coherent_access = presentation.coherent_access,
            .ordered_access = presentation.ordered_access,
        };
    }

    /// Map DDS-XTypes DataRepresentationId_t sequence to QosSnapshot encoding.
    /// QosSnapshot uses 1=XCDR1, 2=XCDR2. Wire values: XCDR1=0, XCDR2=2.
    /// Empty sequence (generated default) → XCDR1.
    fn reprFromQos(ids: []const i16) u16 {
        // Empty sequence = default; per XTypes §7.6.3.1.1 this means the implementation
        // accepts all representations it supports.  zzdds stores raw CDR bytes so it
        // can receive XCDR2 payloads, so advertise XCDR2 acceptance for the common case.
        if (ids.len == 0) return 2;
        for (ids) |id| {
            if (id == 2) return 2; // XCDR2_DATA_REPRESENTATION
        }
        return 1; // explicit XCDR1-only list
    }

    // ── User data receive dispatcher ──────────────────────────────────────────
    //
    // ── userDataOnReceive helpers ─────────────────────────────────────────────

    fn entityIdKey(id: EntityId) u32 {
        return @bitCast([4]u8{ id.entity_key[0], id.entity_key[1], id.entity_key[2], id.entity_kind });
    }

    fn decodeChangeKind(iq: ?submsg_mod.InlineQos) history_mod.ChangeKind {
        if (iq) |q| {
            if (q.get(.status_info)) |si| {
                if (si.len >= 4) {
                    // StatusInfo_t is {unused,unused,unused,status} (RTPS §9.4.5.11),
                    // always big-endian regardless of message endianness.
                    const v = std.mem.readInt(u32, si[0..4], .big);
                    if (v & 0x1 != 0) return .not_alive_disposed;
                    if (v & 0x2 != 0) return .not_alive_unregistered;
                }
            }
        }
        return .alive;
    }

    fn decodeKeyHash(iq: ?submsg_mod.InlineQos) [16]u8 {
        if (iq) |q| {
            if (q.get(.key_hash)) |kh| {
                if (kh.len >= 16) {
                    var h: [16]u8 = undefined;
                    @memcpy(&h, kh[0..16]);
                    return h;
                }
            }
        }
        return std.mem.zeroes([16]u8);
    }

    fn resolveKeyHash(kh: [16]u8, ar: *ActiveReader, payload: []const u8) [16]u8 {
        if (!std.mem.eql(u8, &kh, &std.mem.zeroes([16]u8))) return kh;
        if (ar.key_hash_fn) |f| return f(payload);
        return kh;
    }

    fn dispatchDirectedWrite(
        self: *DomainParticipantImpl,
        dw_bytes: []const u8,
        little_endian: bool,
        writer_guid: Guid,
        sn: anytype,
        ts: time_mod.RtpsTimestamp,
        key_hash: [16]u8,
        payload: []const u8,
        kind: history_mod.ChangeKind,
    ) void {
        if (dw_bytes.len < 4) return;
        const endian: std.builtin.Endian = if (little_endian) .little else .big;
        const count = std.mem.readInt(u32, dw_bytes[0..4], endian);
        self.mu.lock();
        defer self.mu.unlock();
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const offset = 4 + i * 16;
            if (offset + 16 > dw_bytes.len) break;
            var prefix: GuidPrefix = undefined;
            @memcpy(&prefix.bytes, dw_bytes[offset..][0..12]);
            if (!prefix.eql(self.guid.prefix)) continue;
            const eid = EntityId{
                .entity_key = dw_bytes[offset + 12 ..][0..3].*,
                .entity_kind = dw_bytes[offset + 15],
            };
            const rkey = entityIdKey(eid);
            if (self.active_readers.getPtr(rkey)) |ar| {
                const kh = resolveKeyHash(key_hash, ar, payload);
                ar.proto.handleIncomingChange(writer_guid, sn, ts, kh, payload, kind);
            }
        }
    }

    // Called from the transport's receive thread on the data unicast port.
    // Parses each RTPS message and delivers DATA submessages to all active
    // readers; each ProtocolReader filters internally via isWriterMatched().
    //
    // Lock order: participant.mu → StatefulReader.mu (correct order).

    fn userDataOnReceive(ctx: *anyopaque, raw: []const u8, _: Locator) void {
        const self = cast(ctx);

        var it = parser_mod.MessageIterator.init(raw) catch return;
        var param_buf: [32]submsg_mod.InlineQosParam = undefined;

        var src_prefix = it.header.guid_prefix;
        var dst_prefix = GuidPrefix.unknown;
        // Tracks the source timestamp supplied by the most recent INFO_TS submessage
        // in this message, per RTPS §8.3.3.  Initialized to "now" so that DATA
        // submessages without a preceding INFO_TS get the receive time.
        var current_ts: time_mod.RtpsTimestamp = time_mod.RtpsTimestamp.now();

        while (it.next(&param_buf) catch return) |sm| {
            switch (sm) {
                .info_ts => |info| {
                    current_ts = info.timestamp orelse time_mod.RtpsTimestamp.now();
                },
                .info_dst => |dst| {
                    dst_prefix = dst.guid_prefix;
                },
                .info_src => |src| {
                    src_prefix = src.guid_prefix;
                },
                .data => |d| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;

                    const writer_guid = Guid{ .prefix = src_prefix, .entity_id = d.writer_entity_id };
                    const kind = decodeChangeKind(d.inline_qos);
                    if (kind == .alive and d.serialized_payload.len == 0) continue;
                    const key_hash = decodeKeyHash(d.inline_qos);

                    if (d.inline_qos) |iq| {
                        if (iq.get(.directed_write)) |dw_bytes| {
                            dispatchDirectedWrite(self, dw_bytes, d.isLittleEndian(), writer_guid, d.writer_sn, current_ts, key_hash, d.serialized_payload, kind);
                            continue;
                        }
                    }

                    self.mu.lock();
                    if (d.reader_entity_id.eql(EntityIds.unknown)) {
                        var fan_it = self.active_readers.valueIterator();
                        while (fan_it.next()) |ar| {
                            const kh = resolveKeyHash(key_hash, ar, d.serialized_payload);
                            ar.proto.handleIncomingChange(writer_guid, d.writer_sn, current_ts, kh, d.serialized_payload, kind);
                        }
                    } else {
                        const rkey = entityIdKey(d.reader_entity_id);
                        if (self.active_readers.getPtr(rkey)) |ar| {
                            const kh = resolveKeyHash(key_hash, ar, d.serialized_payload);
                            ar.proto.handleIncomingChange(writer_guid, d.writer_sn, current_ts, kh, d.serialized_payload, kind);
                        }
                    }
                    self.mu.unlock();
                },
                .heartbeat => |hb| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const writer_guid = Guid{ .prefix = src_prefix, .entity_id = hb.writer_entity_id };
                    self.mu.lock();
                    if (hb.reader_entity_id.eql(EntityIds.unknown)) {
                        var fan_it = self.active_readers.valueIterator();
                        while (fan_it.next()) |ar| {
                            ar.proto.handleHeartbeat(writer_guid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal());
                        }
                    } else {
                        const rkey = entityIdKey(hb.reader_entity_id);
                        if (self.active_readers.getPtr(rkey)) |ar| {
                            ar.proto.handleHeartbeat(writer_guid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal());
                        }
                    }
                    self.mu.unlock();
                },
                .acknack => |an| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const reader_guid = Guid{ .prefix = src_prefix, .entity_id = an.reader_entity_id };
                    self.mu.lock();
                    const wkey = entityIdKey(an.writer_entity_id);
                    if (self.active_writers.getPtr(wkey)) |aw| {
                        aw.proto.handleAckNack(reader_guid, an.reader_sn_state.base - 1, an.reader_sn_state, an.count, an.isFinal());
                    }
                    self.mu.unlock();
                },
                .data_frag => |df| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const writer_guid = Guid{ .prefix = src_prefix, .entity_id = df.writer_entity_id };
                    self.mu.lock();
                    if (df.reader_entity_id.eql(EntityIds.unknown)) {
                        var fan_it = self.active_readers.valueIterator();
                        while (fan_it.next()) |ar| ar.proto.handleDataFrag(writer_guid, df);
                    } else {
                        const rkey = entityIdKey(df.reader_entity_id);
                        if (self.active_readers.getPtr(rkey)) |ar| ar.proto.handleDataFrag(writer_guid, df);
                    }
                    self.mu.unlock();
                },
                .heartbeat_frag => |hbf| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const writer_guid = Guid{ .prefix = src_prefix, .entity_id = hbf.writer_entity_id };
                    self.mu.lock();
                    if (hbf.reader_entity_id.eql(EntityIds.unknown)) {
                        var fan_it = self.active_readers.valueIterator();
                        while (fan_it.next()) |ar| {
                            ar.proto.handleHeartbeatFrag(writer_guid, hbf.writer_sn, hbf.last_fragment_num, hbf.count);
                        }
                    } else {
                        const rkey = entityIdKey(hbf.reader_entity_id);
                        if (self.active_readers.getPtr(rkey)) |ar| {
                            ar.proto.handleHeartbeatFrag(writer_guid, hbf.writer_sn, hbf.last_fragment_num, hbf.count);
                        }
                    }
                    self.mu.unlock();
                },
                .nack_frag => |nf| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const reader_guid = Guid{ .prefix = src_prefix, .entity_id = nf.reader_entity_id };
                    self.mu.lock();
                    const wkey = entityIdKey(nf.writer_entity_id);
                    if (self.active_writers.getPtr(wkey)) |aw| {
                        aw.proto.handleNackFrag(reader_guid, nf.writer_sn, nf.fragment_number_state, nf.count);
                    }
                    self.mu.unlock();
                },
                .gap => |g| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const writer_guid = Guid{ .prefix = src_prefix, .entity_id = g.writer_entity_id };
                    self.mu.lock();
                    if (g.reader_entity_id.eql(EntityIds.unknown)) {
                        var fan_it = self.active_readers.valueIterator();
                        while (fan_it.next()) |ar| ar.proto.handleGap(writer_guid, g.gap_start, g.gap_list);
                    } else {
                        const rkey = entityIdKey(g.reader_entity_id);
                        if (self.active_readers.getPtr(rkey)) |ar| ar.proto.handleGap(writer_guid, g.gap_start, g.gap_list);
                    }
                    self.mu.unlock();
                },
                else => {},
            }
        }
    }

    // ── Discovery callbacks ────────────────────────────────────────────────────
    //
    // Called from the discovery plugin's internal thread.
    // Callbacks hold participant.mu and then call into RTPS state machines
    // (which lock their own mu). Lock order: participant.mu → RTPS mu.

    fn onParticipantDiscovered(ctx: *anyopaque, data: *const disc.ParticipantData) void {
        const self = cast(ctx);
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        self.mu.lock();
        if (!data.guid.prefix.eql(self.guid.prefix)) {
            for (self.ignored_prefixes.items) |p| {
                if (p.eql(data.guid.prefix)) {
                    self.mu.unlock();
                    return;
                }
            }
            var is_dup = false;
            for (self.discovered_participants.items) |e| {
                if (e.guid.eql(data.guid)) {
                    is_dup = true;
                    break;
                }
            }
            if (!is_dup) {
                const handle = writer_mod.guidToHandle(data.guid);
                self.discovered_participants.append(
                    self.alloc,
                    .{ .guid = data.guid, .handle = handle },
                ) catch {};
                if (self.builtin_sub) |bs| push_dr = bs.part_dr;
            }
        }
        self.mu.unlock();
        if (push_dr) |dr| pushBuiltinParticipantCdr(self.alloc, dr, data);
    }

    fn onParticipantLost(ctx: *anyopaque, guid: disc.Guid) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.discovered_participants.items, 0..) |e, i| {
            if (e.guid.eql(guid)) {
                _ = self.discovered_participants.swapRemove(i);
                return;
            }
        }
    }

    fn onWriterDiscovered(ctx: *anyopaque, data: *const disc.WriterData) void {
        const self = cast(ctx);
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        self.mu.lock();
        for (self.ignored_prefixes.items) |p| {
            if (p.eql(data.guid.prefix)) {
                self.mu.unlock();
                return;
            }
        }
        const pub_handle = writer_mod.guidToHandle(data.guid);
        for (self.ignored_publication_handles.items) |h| {
            if (h == pub_handle) {
                self.mu.unlock();
                return;
            }
        }
        for (self.ignored_topic_names.items) |n| {
            if (std.mem.eql(u8, n, data.topic_name)) {
                self.mu.unlock();
                return;
            }
        }
        var ar_it = self.active_readers.valueIterator();
        while (ar_it.next()) |ar| {
            if (!std.mem.eql(u8, ar.topic_name, data.topic_name)) continue;
            if (!std.mem.eql(u8, ar.type_name, data.type_name)) continue;
            const local_snap = readerQosSnapshot(ar.qos, ar.presentation);
            const result = qm_mod.checkSnapshots(data.qos, local_snap);
            if (!result.isCompatible()) {
                if (ar.incompat_qos) |cb|
                    cb.notify(cb.ctx, @as(i32, @intCast(@intFromEnum(result.incompatible))));
                continue;
            }
            const part_result = qm_mod.checkPartition(
                .{ .name = data.qos.partition_names },
                .{ .name = ar.partition_names },
            );
            if (!part_result.isCompatible()) continue;
            const ll_sec = data.qos.liveliness_lease_sec;
            const ll_ns = data.qos.liveliness_lease_nanosec;
            const lease_ns: i64 = if (ll_sec == 0x7fff_ffff)
                0 // infinite — no expiry tracking
            else
                @as(i64, ll_sec) * std.time.ns_per_s + @as(i64, ll_ns);
            const info = proto.MatchedWriterInfo{
                .guid = data.guid,
                .unicast_locators = data.unicast_locators,
                .multicast_locators = data.multicast_locators,
                .reliability = if (data.qos.reliability_kind == 1) .reliable else .best_effort,
                .ownership_strength = data.qos.ownership_strength,
                .liveliness_lease_ns = lease_ns,
                .history_expected = data.qos.durability_kind > 0 and data.qos.reliability_kind == 1,
            };
            ar.proto.addMatchedWriter(&info) catch {};
            if (ar.matched_notify) |cb|
                cb.notify(cb.ctx, writer_mod.guidToHandle(data.guid), true);
        }
        if (self.builtin_sub) |bs| push_dr = bs.pub_dr;
        // Register newly-seen topic in the discovered-topic registry.
        var new_topic: ?DiscoveredTopic = null;
        var push_topic_dr: ?*reader_mod.DataReaderImpl = null;
        known: {
            for (self.discovered_topics.items) |dt| {
                if (std.mem.eql(u8, dt.topic_name, data.topic_name) and
                    std.mem.eql(u8, dt.type_name, data.type_name)) break :known;
            }
            const tn = self.alloc.dupe(u8, data.topic_name) catch break :known;
            const tt = self.alloc.dupe(u8, data.type_name) catch {
                self.alloc.free(tn);
                break :known;
            };
            const dt = DiscoveredTopic{
                .topic_name = tn,
                .type_name = tt,
                .handle = topicToHandle(data.topic_name, data.type_name),
                .reliability_kind = data.qos.reliability_kind,
                .durability_kind = data.qos.durability_kind,
                .liveliness_kind = data.qos.liveliness_kind,
                .ownership_kind = data.qos.ownership_kind,
                .dest_order_kind = data.qos.destination_order_kind,
            };
            self.discovered_topics.append(self.alloc, dt) catch {
                self.alloc.free(tn);
                self.alloc.free(tt);
                break :known;
            };
            new_topic = dt;
            if (self.builtin_sub) |bs| push_topic_dr = bs.topic_dr;
        }
        self.mu.unlock();
        if (push_dr) |dr| pushBuiltinPublicationCdr(self.alloc, dr, data);
        if (push_topic_dr) |dr| if (new_topic) |dt| pushBuiltinTopicCdr(self.alloc, dr, .{
            .key = topicNameToKey(dt.topic_name),
            .name = dt.topic_name,
            .type_name = dt.type_name,
            .reliability = qosReliability(dt.reliability_kind),
            .durability = qosDurability(dt.durability_kind),
            .liveliness = qosLiveliness(dt.liveliness_kind),
            .ownership = qosOwnership(dt.ownership_kind),
            .destination_order = qosDestOrder(dt.dest_order_kind),
        });
    }

    fn onWriterLost(ctx: *anyopaque, guid: disc.Guid) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        const remote_handle = writer_mod.guidToHandle(guid);
        var ar_it2 = self.active_readers.valueIterator();
        while (ar_it2.next()) |ar| {
            const before = ar.proto.matchedWriterCount();
            ar.proto.removeMatchedWriter(guid);
            if (ar.proto.matchedWriterCount() < before) {
                if (ar.matched_notify) |cb|
                    cb.notify(cb.ctx, remote_handle, false);
            }
        }
    }

    fn onReaderDiscovered(ctx: *anyopaque, data: *const disc.ReaderData) void {
        const self = cast(ctx);
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        self.mu.lock();
        for (self.ignored_prefixes.items) |p| {
            if (p.eql(data.guid.prefix)) {
                self.mu.unlock();
                return;
            }
        }
        const sub_handle = writer_mod.guidToHandle(data.guid);
        for (self.ignored_subscription_handles.items) |h| {
            if (h == sub_handle) {
                self.mu.unlock();
                return;
            }
        }
        for (self.ignored_topic_names.items) |n| {
            if (std.mem.eql(u8, n, data.topic_name)) {
                self.mu.unlock();
                return;
            }
        }
        var aw_it = self.active_writers.valueIterator();
        while (aw_it.next()) |aw| {
            if (!std.mem.eql(u8, aw.topic_name, data.topic_name)) continue;
            if (!std.mem.eql(u8, aw.type_name, data.type_name)) continue;
            const local_snap = writerQosSnapshot(aw.qos, aw.presentation);
            const result = qm_mod.checkSnapshots(local_snap, data.qos);
            if (!result.isCompatible()) {
                if (aw.incompat_qos) |cb|
                    cb.notify(cb.ctx, @as(i32, @intCast(@intFromEnum(result.incompatible))));
                continue;
            }
            const part_result = qm_mod.checkPartition(
                .{ .name = aw.partition_names },
                .{ .name = data.qos.partition_names },
            );
            if (!part_result.isCompatible()) continue;
            const info = proto.MatchedReaderInfo{
                .guid = data.guid,
                .unicast_locators = data.unicast_locators,
                .multicast_locators = data.multicast_locators,
                .expects_inline_qos = false,
                .reliability = if (data.qos.reliability_kind == 1) .reliable else .best_effort,
            };
            aw.proto.addMatchedReader(&info) catch {};
            if (aw.matched_notify) |cb|
                cb.notify(cb.ctx, writer_mod.guidToHandle(data.guid), true);
        }
        if (self.builtin_sub) |bs| push_dr = bs.sub_dr;
        // Register newly-seen topic in the discovered-topic registry.
        var new_topic: ?DiscoveredTopic = null;
        var push_topic_dr: ?*reader_mod.DataReaderImpl = null;
        known: {
            for (self.discovered_topics.items) |dt| {
                if (std.mem.eql(u8, dt.topic_name, data.topic_name) and
                    std.mem.eql(u8, dt.type_name, data.type_name)) break :known;
            }
            const tn = self.alloc.dupe(u8, data.topic_name) catch break :known;
            const tt = self.alloc.dupe(u8, data.type_name) catch {
                self.alloc.free(tn);
                break :known;
            };
            const dt = DiscoveredTopic{
                .topic_name = tn,
                .type_name = tt,
                .handle = topicToHandle(data.topic_name, data.type_name),
                .reliability_kind = data.qos.reliability_kind,
                .durability_kind = data.qos.durability_kind,
                .liveliness_kind = data.qos.liveliness_kind,
                .ownership_kind = data.qos.ownership_kind,
                .dest_order_kind = data.qos.destination_order_kind,
            };
            self.discovered_topics.append(self.alloc, dt) catch {
                self.alloc.free(tn);
                self.alloc.free(tt);
                break :known;
            };
            new_topic = dt;
            if (self.builtin_sub) |bs| push_topic_dr = bs.topic_dr;
        }
        self.mu.unlock();
        if (push_dr) |dr| pushBuiltinSubscriptionCdr(self.alloc, dr, data);
        if (push_topic_dr) |dr| if (new_topic) |dt| pushBuiltinTopicCdr(self.alloc, dr, .{
            .key = topicNameToKey(dt.topic_name),
            .name = dt.topic_name,
            .type_name = dt.type_name,
            .reliability = qosReliability(dt.reliability_kind),
            .durability = qosDurability(dt.durability_kind),
            .liveliness = qosLiveliness(dt.liveliness_kind),
            .ownership = qosOwnership(dt.ownership_kind),
            .destination_order = qosDestOrder(dt.dest_order_kind),
        });
    }

    fn onReaderLost(ctx: *anyopaque, guid: disc.Guid) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        const remote_handle = writer_mod.guidToHandle(guid);
        var aw_it2 = self.active_writers.valueIterator();
        while (aw_it2.next()) |aw| {
            const before = aw.proto.matchedReaderCount();
            aw.proto.removeMatchedReader(guid);
            if (aw.proto.matchedReaderCount() < before) {
                if (aw.matched_notify) |cb|
                    cb.notify(cb.ctx, remote_handle, false);
            }
        }
    }

    // ── ParticipantCbs factory helpers ────────────────────────────────────────

    fn pubAnnounceProtoWriter(ctx: *anyopaque, handle: DDS.InstanceHandle_t, partition_names: []const []const u8, presentation: DDS.PresentationQosPolicy) void {
        const self = cast(ctx);
        // Find the writer and snapshot its announcement fields outside the lock.
        var ann_opt: ?struct {
            guid: Guid,
            topic_name: []const u8,
            type_name: []const u8,
            qos: DDS.DataWriterQos,
            presentation: DDS.PresentationQosPolicy,
        } = null;
        {
            self.mu.lock();
            defer self.mu.unlock();
            var aw_it3 = self.active_writers.valueIterator();
            while (aw_it3.next()) |aw| {
                if (aw.handle == handle) {
                    aw.partition_names = partition_names;
                    aw.presentation = presentation;
                    ann_opt = .{
                        .guid = aw.guid,
                        .topic_name = aw.topic_name,
                        .type_name = aw.type_name,
                        .qos = aw.qos,
                        .presentation = presentation,
                    };
                    break;
                }
            }
        }
        const ann = ann_opt orelse return;
        const type_info_cdr = self.type_info_registry.get(ann.type_name) orelse &.{};
        var snap = writerQosSnapshot(ann.qos, ann.presentation);
        snap.partition_names = partition_names;
        self.discovery.announceWriter(&disc.WriterAnnouncement{
            .guid = ann.guid,
            .participant_guid = self.guid,
            .topic_name = ann.topic_name,
            .type_name = ann.type_name,
            .qos = snap,
            .type_object = &.{},
            .type_info_cdr = type_info_cdr,
        }) catch {};
    }

    fn subAnnounceProtoReader(ctx: *anyopaque, handle: DDS.InstanceHandle_t, partition_names: []const []const u8, presentation: DDS.PresentationQosPolicy) void {
        const self = cast(ctx);
        var ann_opt: ?struct {
            guid: Guid,
            topic_name: []const u8,
            type_name: []const u8,
            qos: DDS.DataReaderQos,
            presentation: DDS.PresentationQosPolicy,
        } = null;
        {
            self.mu.lock();
            defer self.mu.unlock();
            var ar_it3 = self.active_readers.valueIterator();
            while (ar_it3.next()) |ar| {
                if (ar.handle == handle) {
                    ar.partition_names = partition_names;
                    ar.presentation = presentation;
                    ann_opt = .{
                        .guid = ar.guid,
                        .topic_name = ar.topic_name,
                        .type_name = ar.type_name,
                        .qos = ar.qos,
                        .presentation = presentation,
                    };
                    break;
                }
            }
        }
        const ann = ann_opt orelse return;
        const type_info_cdr = self.type_info_registry.get(ann.type_name) orelse &.{};
        var snap = readerQosSnapshot(ann.qos, ann.presentation);
        snap.partition_names = partition_names;
        self.discovery.announceReader(&disc.ReaderAnnouncement{
            .guid = ann.guid,
            .participant_guid = self.guid,
            .topic_name = ann.topic_name,
            .type_name = ann.type_name,
            .qos = snap,
            .type_info_cdr = type_info_cdr,
        }) catch {};
    }

    fn pubRegisterWriterIncompatQos(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (*anyopaque, i32) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it4 = self.active_writers.valueIterator();
        while (aw_it4.next()) |aw| {
            if (aw.handle == handle) {
                aw.incompat_qos = .{ .ctx = notify_ctx, .notify = notify_fn };
                break;
            }
        }
    }

    fn pubRegisterWriterMatchedNotify(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (*anyopaque, DDS.InstanceHandle_t, bool) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it5 = self.active_writers.valueIterator();
        while (aw_it5.next()) |aw| {
            if (aw.handle == handle) {
                aw.matched_notify = .{ .ctx = notify_ctx, .notify = notify_fn };
                break;
            }
        }
    }

    fn subRegisterReaderIncompatQos(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (*anyopaque, i32) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var ar_it4 = self.active_readers.valueIterator();
        while (ar_it4.next()) |ar| {
            if (ar.handle == handle) {
                ar.incompat_qos = .{ .ctx = notify_ctx, .notify = notify_fn };
                break;
            }
        }
    }

    fn subRegisterReaderMatchedNotify(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (*anyopaque, DDS.InstanceHandle_t, bool) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var ar_it5 = self.active_readers.valueIterator();
        while (ar_it5.next()) |ar| {
            if (ar.handle == handle) {
                ar.matched_notify = .{ .ctx = notify_ctx, .notify = notify_fn };
                break;
            }
        }
    }

    fn pubRegisterWriterTimerNotify(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (*anyopaque, i64) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it6 = self.active_writers.valueIterator();
        while (aw_it6.next()) |aw| {
            if (aw.handle == handle) {
                aw.timer_check = .{ .ctx = notify_ctx, .check = notify_fn };
                break;
            }
        }
    }

    fn pubRegisterWriterLivelinessAssert(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        assert_fn: *const fn (*anyopaque) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it7 = self.active_writers.valueIterator();
        while (aw_it7.next()) |aw| {
            if (aw.handle == handle) {
                aw.liveliness_assert = .{ .ctx = notify_ctx, .assert_fn = assert_fn };
                break;
            }
        }
    }

    fn subRegisterReaderTimerNotify(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (*anyopaque, i64) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var ar_it6 = self.active_readers.valueIterator();
        while (ar_it6.next()) |ar| {
            if (ar.handle == handle) {
                ar.timer_check = .{ .ctx = notify_ctx, .check = notify_fn };
                break;
            }
        }
    }

    fn makePubCbs(self: *Self) publisher_mod.ParticipantCbs {
        return .{
            .ctx = self,
            .create_proto_writer = pubCreateProtoWriter,
            .destroy_proto_writer = pubDestroyProtoWriter,
            .next_handle = nextHandle,
            .register_incompat_qos = pubRegisterWriterIncompatQos,
            .register_matched_notify = pubRegisterWriterMatchedNotify,
            .announce_writer = pubAnnounceProtoWriter,
            .timer_clock = self.timer_clock,
            .register_timer_notify = pubRegisterWriterTimerNotify,
            .register_liveliness_assert = pubRegisterWriterLivelinessAssert,
        };
    }

    fn subGetFieldFn(
        ctx: *anyopaque,
        type_name: []const u8,
    ) ?*const fn ([]const u8, []const u8) ?filter_mod.FilterValue {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        if (self.type_support_registry.get(type_name)) |ts| return ts.get_field;
        return null;
    }

    fn makeSubCbs(self: *Self) subscriber_mod.ParticipantCbs {
        return .{
            .ctx = self,
            .create_proto_reader = subCreateProtoReader,
            .destroy_proto_reader = subDestroyProtoReader,
            .next_handle = nextHandle,
            .register_incompat_qos = subRegisterReaderIncompatQos,
            .register_matched_notify = subRegisterReaderMatchedNotify,
            .announce_reader = subAnnounceProtoReader,
            .timer_clock = self.timer_clock,
            .register_timer_notify = subRegisterReaderTimerNotify,
            .get_field_fn = subGetFieldFn,
        };
    }

    /// Check all active writer and reader deadline/liveliness timers and fire
    /// notifications for any that have expired.  Call from a timer thread or
    /// directly from tests (with a ManualClock) for deterministic control.
    pub fn checkTimers(self: *Self) void {
        const now_ns = self.timer_clock.nowNs();
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it8 = self.active_writers.valueIterator();
        while (aw_it8.next()) |aw| {
            if (aw.timer_check) |cb| cb.check(cb.ctx, now_ns);
        }
        var ar_it7 = self.active_readers.valueIterator();
        while (ar_it7.next()) |ar| {
            if (ar.timer_check) |cb| cb.check(cb.ctx, now_ns);
        }
    }

    // ── Entity vtable ─────────────────────────────────────────────────────────

    const entity_vtable = DDS.Entity.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .deinit = vtDeinit,
    };

    // ── DomainParticipant vtable ──────────────────────────────────────────────

    const vtable = DDS.DomainParticipant.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .create_publisher = vtCreatePublisher,
        .delete_publisher = vtDeletePublisher,
        .create_subscriber = vtCreateSubscriber,
        .delete_subscriber = vtDeleteSubscriber,
        .get_builtin_subscriber = vtGetBuiltinSubscriber,
        .create_topic = vtCreateTopic,
        .delete_topic = vtDeleteTopic,
        .find_topic = vtFindTopic,
        .lookup_topicdescription = vtLookupTopicDesc,
        .create_contentfilteredtopic = vtCreateCFTopic,
        .delete_contentfilteredtopic = vtDeleteCFTopic,
        .create_multitopic = vtCreateMultiTopic,
        .delete_multitopic = vtDeleteMultiTopic,
        .delete_contained_entities = vtDeleteContained,
        .set_qos = vtSetQos,
        .get_qos = vtGetQos,
        .set_listener = vtSetListener,
        .get_listener = vtGetListener,
        .ignore_participant = vtIgnoreParticipant,
        .ignore_topic = vtIgnoreTopic,
        .ignore_publication = vtIgnorePublication,
        .ignore_subscription = vtIgnoreSubscription,
        .get_domain_id = vtGetDomainId,
        .assert_liveliness = vtAssertLiveliness,
        .set_default_publisher_qos = vtSetDefaultPubQos,
        .get_default_publisher_qos = vtGetDefaultPubQos,
        .set_default_subscriber_qos = vtSetDefaultSubQos,
        .get_default_subscriber_qos = vtGetDefaultSubQos,
        .set_default_topic_qos = vtSetDefaultTopicQos,
        .get_default_topic_qos = vtGetDefaultTopicQos,
        .get_discovered_participants = vtGetDiscoveredParticipants,
        .get_discovered_participant_data = vtGetDiscoveredParticipantData,
        .get_discovered_topics = vtGetDiscoveredTopics,
        .get_discovered_topic_data = vtGetDiscoveredTopicData,
        .contains_entity = vtContainsEntity,
        .get_current_time = vtGetCurrentTime,
        .deinit = vtDeinit,
    };

    fn vtEnable(_: *anyopaque) DDS.ReturnCode_t {
        return DDS.RETCODE_OK;
    }

    fn vtGetStatusCond(ctx: *anyopaque) DDS.StatusCondition {
        const self = cast(ctx);
        if (self.status_cond) |sc| return sc.toDDSStatusCondition();
        return nil.nil_status_condition;
    }

    fn vtGetStatusChanges(ctx: *anyopaque) DDS.StatusMask {
        return cast(ctx).status_changes;
    }

    fn vtGetHandle(ctx: *anyopaque) DDS.InstanceHandle_t {
        return cast(ctx).instance_handle;
    }

    fn vtCreatePublisher(
        ctx: *anyopaque,
        qos: DDS.PublisherQos,
        a_listener: DDS.PublisherListener,
        mask: DDS.StatusMask,
    ) DDS.Publisher {
        const self = cast(ctx);
        const handle = nextHandle(ctx);
        const p = publisher_mod.PublisherImpl.init(
            self.alloc,
            self.toDDSParticipant(),
            self.makePubCbs(),
            qos,
            a_listener,
            mask,
            handle,
        ) catch return nil.nil_publisher;
        self.mu.lock();
        self.publishers.append(self.alloc, p) catch {
            self.mu.unlock();
            p.deinit();
            return nil.nil_publisher;
        };
        self.mu.unlock();
        return p.toDDSPublisher();
    }

    fn vtDeletePublisher(ctx: *anyopaque, a_publisher: DDS.Publisher) DDS.ReturnCode_t {
        const self = cast(ctx);
        var found: ?*publisher_mod.PublisherImpl = null;
        self.mu.lock();
        for (self.publishers.items, 0..) |p, i| {
            if (p.toDDSPublisher().ptr == a_publisher.ptr) {
                _ = self.publishers.swapRemove(i);
                found = p;
                break;
            }
        }
        self.mu.unlock();
        // Deinit outside lock: publisher.deinit() calls destroy_proto_writer which locks mu.
        if (found) |p| {
            p.deinit();
            return DDS.RETCODE_OK;
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    fn vtCreateSubscriber(
        ctx: *anyopaque,
        qos: DDS.SubscriberQos,
        a_listener: DDS.SubscriberListener,
        mask: DDS.StatusMask,
    ) DDS.Subscriber {
        const self = cast(ctx);
        const handle = nextHandle(ctx);
        const s = subscriber_mod.SubscriberImpl.init(
            self.alloc,
            self.toDDSParticipant(),
            self.makeSubCbs(),
            qos,
            a_listener,
            mask,
            handle,
        ) catch return nil.nil_subscriber;
        self.mu.lock();
        self.subscribers.append(self.alloc, s) catch {
            self.mu.unlock();
            s.deinit();
            return nil.nil_subscriber;
        };
        self.mu.unlock();
        return s.toDDSSubscriber();
    }

    fn vtDeleteSubscriber(ctx: *anyopaque, a_subscriber: DDS.Subscriber) DDS.ReturnCode_t {
        const self = cast(ctx);
        var found: ?*subscriber_mod.SubscriberImpl = null;
        self.mu.lock();
        for (self.subscribers.items, 0..) |s, i| {
            if (s.toDDSSubscriber().ptr == a_subscriber.ptr) {
                _ = self.subscribers.swapRemove(i);
                found = s;
                break;
            }
        }
        self.mu.unlock();
        if (found) |s| {
            s.deinit();
            return DDS.RETCODE_OK;
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    fn vtGetBuiltinSubscriber(ctx: *anyopaque) DDS.Subscriber {
        const self = cast(ctx);
        if (self.builtin_sub) |bs| return bs.sub.toDDSSubscriber();
        return nil.nil_subscriber;
    }

    fn vtCreateTopic(
        ctx: *anyopaque,
        topic_name: []const u8,
        type_name: []const u8,
        qos: DDS.TopicQos,
        a_listener: DDS.TopicListener,
        mask: DDS.StatusMask,
    ) DDS.Topic {
        const self = cast(ctx);
        const handle = nextHandle(ctx);
        const t = topic_mod.TopicImpl.init(
            self.alloc,
            topic_name,
            type_name,
            self,
            getDDSParticipant,
            qos,
            a_listener,
            mask,
            handle,
        ) catch return nil.nil_topic;
        self.mu.lock();
        self.topics.append(self.alloc, t) catch {
            self.mu.unlock();
            t.deinit();
            return nil.nil_topic;
        };
        // Register in discovered_topics so get_discovered_topics / get_discovered_topic_data
        // work for locally-created topics.  The same (topic_name, type_name) dedup key used
        // by the SEDP callbacks prevents a duplicate entry when the topic later appears on wire.
        new_dt: {
            for (self.discovered_topics.items) |dt| {
                if (std.mem.eql(u8, dt.topic_name, topic_name) and
                    std.mem.eql(u8, dt.type_name, type_name)) break :new_dt;
            }
            const tn = self.alloc.dupe(u8, topic_name) catch break :new_dt;
            const tt = self.alloc.dupe(u8, type_name) catch {
                self.alloc.free(tn);
                break :new_dt;
            };
            const dt = DiscoveredTopic{
                .topic_name = tn,
                .type_name = tt,
                .handle = topicToHandle(topic_name, type_name),
                .reliability_kind = if (qos.reliability.kind == .RELIABLE_RELIABILITY_QOS) @as(u8, 1) else 0,
                .durability_kind = @as(u8, @intCast(@intFromEnum(qos.durability.kind))),
                .liveliness_kind = @as(u8, @intCast(@intFromEnum(qos.liveliness.kind))),
                .ownership_kind = if (qos.ownership.kind == .EXCLUSIVE_OWNERSHIP_QOS) @as(u8, 1) else 0,
                .dest_order_kind = if (qos.destination_order.kind == .BY_SOURCE_TIMESTAMP_DESTINATIONORDER_QOS) @as(u8, 1) else 0,
            };
            self.discovered_topics.append(self.alloc, dt) catch {
                self.alloc.free(tn);
                self.alloc.free(tt);
                break :new_dt;
            };
        }
        const maybe_topic_dr: ?*reader_mod.DataReaderImpl =
            if (self.builtin_sub) |bs| bs.topic_dr else null;
        self.mu.unlock();
        if (maybe_topic_dr) |dr| pushBuiltinTopicCdr(self.alloc, dr, .{
            .key = topicNameToKey(topic_name),
            .name = topic_name,
            .type_name = type_name,
            .durability = qos.durability,
            .durability_service = qos.durability_service,
            .deadline = qos.deadline,
            .latency_budget = qos.latency_budget,
            .liveliness = qos.liveliness,
            .reliability = qos.reliability,
            .transport_priority = qos.transport_priority,
            .lifespan = qos.lifespan,
            .destination_order = qos.destination_order,
            .history = qos.history,
            .resource_limits = qos.resource_limits,
            .ownership = qos.ownership,
        });
        return t.toDDSTopic();
    }

    fn vtDeleteTopic(ctx: *anyopaque, a_topic: DDS.Topic) DDS.ReturnCode_t {
        const self = cast(ctx);
        var found: ?*topic_mod.TopicImpl = null;
        self.mu.lock();
        for (self.topics.items, 0..) |t, i| {
            if (t.toDDSTopic().ptr == a_topic.ptr) {
                _ = self.topics.swapRemove(i);
                found = t;
                break;
            }
        }
        self.mu.unlock();
        if (found) |t| {
            t.deinit();
            return DDS.RETCODE_OK;
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    fn vtFindTopic(ctx: *anyopaque, topic_name: []const u8, _: DDS.Duration_t) DDS.Topic {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.topics.items) |t| {
            if (std.mem.eql(u8, t.topic_name, topic_name)) return t.toDDSTopic();
        }
        return nil.nil_topic;
    }

    fn vtLookupTopicDesc(ctx: *anyopaque, name: []const u8) DDS.TopicDescription {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.topics.items) |t| {
            if (std.mem.eql(u8, t.topic_name, name)) return t.toTopicDescription();
        }
        return nil.nil_topic_description;
    }

    fn vtCreateCFTopic(
        ctx: *anyopaque,
        name: []const u8,
        related_topic: DDS.Topic,
        filter_expression: []const u8,
        expression_parameters: DDS.StringSeq,
    ) DDS.ContentFilteredTopic {
        const self = cast(ctx);
        const cft = topic_mod.ContentFilteredTopicImpl.init(
            self.alloc,
            name,
            related_topic,
            filter_expression,
            expression_parameters,
            self.toDDSParticipant(),
        ) catch return nil.nil_cft;
        self.mu.lock();
        self.cft_topics.append(self.alloc, cft) catch {
            self.mu.unlock();
            cft.deinit();
            return nil.nil_cft;
        };
        self.mu.unlock();
        return cft.toDDSContentFilteredTopic();
    }

    fn vtDeleteCFTopic(ctx: *anyopaque, a_cft: DDS.ContentFilteredTopic) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.cft_topics.items, 0..) |c, i| {
            if (c.toDDSContentFilteredTopic().ptr == a_cft.ptr) {
                _ = self.cft_topics.swapRemove(i);
                c.deinit();
                return DDS.RETCODE_OK;
            }
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    fn vtCreateMultiTopic(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: DDS.StringSeq,
    ) DDS.MultiTopic {
        return nil.nil_multitopic;
    }

    fn vtDeleteMultiTopic(_: *anyopaque, _: DDS.MultiTopic) DDS.ReturnCode_t {
        return DDS.RETCODE_UNSUPPORTED;
    }

    fn vtDeleteContained(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        // Take ownership of entity lists under the lock.
        var pubs: std.ArrayListUnmanaged(*publisher_mod.PublisherImpl) = undefined;
        var subs: std.ArrayListUnmanaged(*subscriber_mod.SubscriberImpl) = undefined;
        var tops: std.ArrayListUnmanaged(*topic_mod.TopicImpl) = undefined;
        self.mu.lock();
        pubs = self.publishers;
        self.publishers = .empty;
        subs = self.subscribers;
        self.subscribers = .empty;
        tops = self.topics;
        self.topics = .empty;
        self.mu.unlock();
        // Deinit outside lock to allow destroy_proto callbacks to re-lock mu.
        for (pubs.items) |p| p.deinit();
        pubs.deinit(self.alloc);
        for (subs.items) |s| s.deinit();
        subs.deinit(self.alloc);
        for (tops.items) |t| t.deinit();
        tops.deinit(self.alloc);
        return DDS.RETCODE_OK;
    }

    fn vtSetQos(ctx: *anyopaque, qos: DDS.DomainParticipantQos) DDS.ReturnCode_t {
        cast(ctx).qos = qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetQos(ctx: *anyopaque, qos: *DDS.DomainParticipantQos) DDS.ReturnCode_t {
        qos.* = cast(ctx).qos;
        return DDS.RETCODE_OK;
    }

    fn vtSetListener(
        ctx: *anyopaque,
        a_listener: DDS.DomainParticipantListener,
        mask: DDS.StatusMask,
    ) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.listener = a_listener;
        self.listener_mask = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.DomainParticipantListener {
        return cast(ctx).listener;
    }

    fn vtIgnoreParticipant(ctx: *anyopaque, handle: DDS.InstanceHandle_t) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        // Find the participant with this handle to get its GUID prefix.
        var found_prefix: ?GuidPrefix = null;
        for (self.discovered_participants.items, 0..) |e, i| {
            if (e.handle == handle) {
                found_prefix = e.guid.prefix;
                _ = self.discovered_participants.swapRemove(i);
                break;
            }
        }
        const prefix = found_prefix orelse return DDS.RETCODE_BAD_PARAMETER;
        // Check not already in the ignore list.
        for (self.ignored_prefixes.items) |p| {
            if (p.eql(prefix)) return DDS.RETCODE_OK;
        }
        self.ignored_prefixes.append(self.alloc, prefix) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtIgnoreTopic(ctx: *anyopaque, handle: DDS.InstanceHandle_t) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        // Resolve handle → topic name from local topics or discovered topics.
        var found_name: ?[]const u8 = null;
        for (self.topics.items) |t| {
            if (t.instance_handle == handle) {
                found_name = t.topic_name;
                break;
            }
        }
        if (found_name == null) {
            for (self.discovered_topics.items) |dt| {
                if (dt.handle == handle) {
                    found_name = dt.topic_name;
                    break;
                }
            }
        }
        const name = found_name orelse return DDS.RETCODE_BAD_PARAMETER;
        for (self.ignored_topic_names.items) |n| {
            if (std.mem.eql(u8, n, name)) return DDS.RETCODE_OK;
        }
        const owned = self.alloc.dupe(u8, name) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.ignored_topic_names.append(self.alloc, owned) catch {
            self.alloc.free(owned);
            return DDS.RETCODE_OUT_OF_RESOURCES;
        };
        return DDS.RETCODE_OK;
    }

    fn vtIgnorePublication(ctx: *anyopaque, handle: DDS.InstanceHandle_t) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.ignored_publication_handles.items) |h| {
            if (h == handle) return DDS.RETCODE_OK;
        }
        self.ignored_publication_handles.append(self.alloc, handle) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        // NOTE: guards future onWriterDiscovered callbacks only. Existing matched
        // writers (already added via addMatchedWriter) are not retroactively removed.
        // This matches FastDDS/CycloneDDS behaviour; full retroactive unmatching would
        // require iterating active_readers and calling removeMatchedWriter here.
        return DDS.RETCODE_OK;
    }

    fn vtIgnoreSubscription(ctx: *anyopaque, handle: DDS.InstanceHandle_t) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.ignored_subscription_handles.items) |h| {
            if (h == handle) return DDS.RETCODE_OK;
        }
        self.ignored_subscription_handles.append(self.alloc, handle) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        // NOTE: guards future onReaderDiscovered callbacks only; see vtIgnorePublication.
        return DDS.RETCODE_OK;
    }

    fn vtGetDomainId(ctx: *anyopaque) DDS.DomainId_t {
        return cast(ctx).domain_id;
    }

    fn vtAssertLiveliness(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it9 = self.active_writers.valueIterator();
        while (aw_it9.next()) |aw| {
            if (aw.liveliness_assert) |cb| cb.assert_fn(cb.ctx);
        }
        return DDS.RETCODE_OK;
    }

    fn vtSetDefaultPubQos(ctx: *anyopaque, qos: DDS.PublisherQos) DDS.ReturnCode_t {
        cast(ctx).default_pub_qos = qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultPubQos(ctx: *anyopaque, qos: *DDS.PublisherQos) DDS.ReturnCode_t {
        qos.* = cast(ctx).default_pub_qos;
        return DDS.RETCODE_OK;
    }

    fn vtSetDefaultSubQos(ctx: *anyopaque, qos: DDS.SubscriberQos) DDS.ReturnCode_t {
        cast(ctx).default_sub_qos = qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultSubQos(ctx: *anyopaque, qos: *DDS.SubscriberQos) DDS.ReturnCode_t {
        qos.* = cast(ctx).default_sub_qos;
        return DDS.RETCODE_OK;
    }

    fn vtSetDefaultTopicQos(ctx: *anyopaque, qos: DDS.TopicQos) DDS.ReturnCode_t {
        cast(ctx).default_topic_qos = qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultTopicQos(ctx: *anyopaque, qos: *DDS.TopicQos) DDS.ReturnCode_t {
        qos.* = cast(ctx).default_topic_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDiscoveredParticipants(
        ctx: *anyopaque,
        handles: *DDS.InstanceHandleSeq,
    ) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        handles.clearRetainingCapacity();
        for (self.discovered_participants.items) |e| {
            handles.append(self.alloc, e.handle) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        }
        return DDS.RETCODE_OK;
    }

    fn vtGetDiscoveredParticipantData(
        ctx: *anyopaque,
        data: *DDS.ParticipantBuiltinTopicData,
        handle: DDS.InstanceHandle_t,
    ) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.discovered_participants.items) |e| {
            if (e.handle == handle) {
                data.* = .{};
                data.key = writer_mod.guidToBuiltinKey(e.guid);
                return DDS.RETCODE_OK;
            }
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    fn vtGetDiscoveredTopics(
        ctx: *anyopaque,
        handles: *DDS.InstanceHandleSeq,
    ) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        handles.clearRetainingCapacity();
        for (self.discovered_topics.items) |dt| {
            handles.append(self.alloc, dt.handle) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        }
        return DDS.RETCODE_OK;
    }

    fn vtGetDiscoveredTopicData(
        ctx: *anyopaque,
        data: *DDS.TopicBuiltinTopicData,
        handle: DDS.InstanceHandle_t,
    ) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.discovered_topics.items) |dt| {
            if (dt.handle != handle) continue;
            // name/type_name are slices into heap-allocated strings owned by the
            // DiscoveredTopic entry.  They are valid for the participant's lifetime
            // as long as no undiscovery path frees them.  If topic undiscovery is
            // ever added, these fields must be duped into caller-owned storage instead.
            data.* = .{
                .key = topicNameToKey(dt.topic_name),
                .name = dt.topic_name,
                .type_name = dt.type_name,
                .reliability = qosReliability(dt.reliability_kind),
                .durability = qosDurability(dt.durability_kind),
                .liveliness = qosLiveliness(dt.liveliness_kind),
                .ownership = qosOwnership(dt.ownership_kind),
                .destination_order = qosDestOrder(dt.dest_order_kind),
            };
            return DDS.RETCODE_OK;
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    fn vtContainsEntity(ctx: *anyopaque, handle: DDS.InstanceHandle_t) bool {
        const self = cast(ctx);
        if (self.instance_handle == handle) return true;
        self.mu.lock();
        defer self.mu.unlock();
        for (self.publishers.items) |p| if (p.instance_handle == handle) return true;
        for (self.subscribers.items) |s| if (s.instance_handle == handle) return true;
        for (self.topics.items) |t| if (t.instance_handle == handle) return true;
        var aw_it10 = self.active_writers.valueIterator();
        while (aw_it10.next()) |aw| if (aw.handle == handle) return true;
        var ar_it8 = self.active_readers.valueIterator();
        while (ar_it8.next()) |ar| if (ar.handle == handle) return true;
        return false;
    }

    fn vtGetCurrentTime(_: *anyopaque, current_time: *DDS.Time_t) DDS.ReturnCode_t {
        const now = time_mod.Time.now();
        current_time.* = .{
            .sec = now.sec,
            .nanosec = now.nanosec,
        };
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    // ── Status helper for StatusConditionImpl ─────────────────────────────────

    fn getStatusFn(entity_ptr: *anyopaque) DDS.StatusMask {
        return cast(entity_ptr).status_changes;
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};
