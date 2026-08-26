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
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const extensions_mod = @import("../c_abi/extensions.zig");
const nil = @import("nil.zig");
const proto = @import("../protocol/interface.zig");
const trace_mod = @import("../trace.zig");
const config_mod = @import("../config/schema.zig");
const generated_config_mod = @import("../config/generated.zig");
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
const TcpTransport = @import("../transport/tcp.zig").TcpTransport;
const security_if = @import("../security/interface.zig");
const parser_mod = @import("../rtps/message/parser.zig");
const submsg_mod = @import("../rtps/message/submessage.zig");
const time_mod = @import("../util/time.zig");
const header_mod = @import("../rtps/message/header.zig");
const build_opts = @import("build_options");
const qm_mod = @import("qos_match.zig");
const reader_mod = @import("reader.zig");
const writer_mod = @import("writer.zig");
const zidl_rt = @import("zidl_rt");
const c_abi_handle = @import("../util/c_abi_handle.zig");
const ListenerBox = @import("../util/listener_box.zig").ListenerBox;
const listener_fallback = @import("../util/listener_fallback.zig");

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

/// DataLocatorReachability.can_reach implementation: ctx is a *const Transport
/// pointing at this participant's own (possibly TCP) data transport field.
fn dataTransportCanReach(ctx: *anyopaque, loc: *const Locator) bool {
    const tr: *const Transport = @ptrCast(@alignCast(ctx));
    return tr.canReach(loc);
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
        fn f(_: *anyopaque, _: proto.Guid, _: proto.SequenceNumber, _: proto.RtpsTimestamp, _: [16]u8, _: []const u8, _: proto.ChangeKind, _: ?proto.SequenceNumber, _: ?proto.SequenceNumber, _: ?i64) void {}
    }.f,
    .handle_heartbeat = struct {
        fn f(_: *anyopaque, _: proto.Guid, _: proto.SequenceNumber, _: proto.SequenceNumber, _: i32, _: bool, _: bool) void {}
    }.f,
    .handle_data_frag = struct {
        fn f(_: *anyopaque, _: proto.Guid, _: proto.RtpsTimestamp, _: proto.DataFragSubmessage) void {}
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
    // No real reader backs this stub, so there's nothing to ever match --
    // `true` here (not `false`) is what lets vtWaitForHistorical's
    // `is_zero_wait or hasMatchedWriters()` check still short-circuit to OK
    // immediately for a stub/null reader, matching historical_delivered's
    // own unconditional `true` above rather than blocking until max_wait.
    .has_matched_writers = struct {
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
    alloc: std.mem.Allocator,
    name: [*:0]const u8,
    type_name: [*:0]const u8,
    participant: DDS.DomainParticipant,
    c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const vtbl = DDS.TopicDescription.Vtable{
        .get_type_name = struct {
            fn f(ctx: *anyopaque) [*:0]const u8 {
                return cast(ctx).type_name;
            }
        }.f,
        .get_name = struct {
            fn f(ctx: *anyopaque) [*:0]const u8 {
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
        .get_c_abi_handle = struct {
            fn f(ctx: *anyopaque) *anyopaque {
                const self = cast(ctx);
                return self.c_abi.get(self.alloc, ctx, &vtbl);
            }
        }.f,
        .get_allocator = struct {
            fn f(ctx: *anyopaque) std.mem.Allocator {
                return cast(ctx).alloc;
            }
        }.f,
    };

    fn cast(ctx: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ctx));
    }

    fn toTopicDescription(self: *@This()) DDS.TopicDescription {
        return .{ .ptr = self, .vtable = &vtbl };
    }

    fn deinit(self: *@This()) void {
        self.c_abi.free(self.alloc);
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
                fn f(_: *anyopaque, _: []const u8, _: []const u8, _: DDS.DataReaderQos, _: DDS.InstanceHandle_t, _: DDS.PresentationQosPolicy, guid: *Guid) anyerror!proto.ProtocolReader {
                    guid.* = std.mem.zeroes(Guid);
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
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, i64) void, _: *const fn (*anyopaque) bool, _: *const fn (*anyopaque) void) void {}
            }.f,
            .register_get_field_refresh = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: []const u8, _: *anyopaque, _: *const fn (*anyopaque, ?filter_mod.CdrFieldGetter) void) void {}
            }.f,
            .register_wlp_alive_notify = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, GuidPrefix, u8) void) void {}
            }.f,
        };

        self.sub = try subscriber_mod.SubscriberImpl.init(
            alloc,
            dp,
            noop_cbs,
            .{}, // builtin subscriber: fixed internal QoS, not user-config-driven
            .{},
            nil.nil_sub_listener,
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
        );
        errdefer self.sub.deinit();

        const sub_dds = self.sub.toDDSSubscriber();

        // Embedded topic descriptions — their addresses are stable because self
        // is heap-allocated; assignments here set their initial values.
        self.part_desc = .{ .alloc = alloc, .name = "DCPSParticipant", .type_name = "ParticipantBuiltinTopicData", .participant = dp };
        self.topic_desc = .{ .alloc = alloc, .name = "DCPSTopic", .type_name = "TopicBuiltinTopicData", .participant = dp };
        self.pub_desc = .{ .alloc = alloc, .name = "DCPSPublication", .type_name = "PublicationBuiltinTopicData", .participant = dp };
        self.sub_desc = .{ .alloc = alloc, .name = "DCPSSubscription", .type_name = "SubscriptionBuiltinTopicData", .participant = dp };

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
            std.mem.zeroes(Guid),
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
            std.mem.zeroes(Guid),
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
            std.mem.zeroes(Guid),
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
            std.mem.zeroes(Guid),
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
        self.part_desc.deinit();
        self.topic_desc.deinit();
        self.pub_desc.deinit();
        self.sub_desc.deinit();
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
        .user_data = .{ .value = .{
            ._maximum = @intCast(data.qos.user_data.len),
            ._length = @intCast(data.qos.user_data.len),
            ._buffer = @constCast(data.qos.user_data.ptr),
            ._release = false,
        } },
    };
    DDS.PublicationBuiltinTopicData.serialize(&w, v) catch return;
    var key_hash: [16]u8 = undefined;
    @memcpy(&key_hash, std.mem.asBytes(&data.guid));
    dr.pushBuiltinCdr(buf.items, key_hash, .alive);
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
        .user_data = .{ .value = .{
            ._maximum = @intCast(data.qos.user_data.len),
            ._length = @intCast(data.qos.user_data.len),
            ._buffer = @constCast(data.qos.user_data.ptr),
            ._release = false,
        } },
    };
    DDS.SubscriptionBuiltinTopicData.serialize(&w, v) catch return;
    var key_hash: [16]u8 = undefined;
    @memcpy(&key_hash, std.mem.asBytes(&data.guid));
    dr.pushBuiltinCdr(buf.items, key_hash, .alive);
}

fn pushBuiltinEndpointDisposed(dr: *reader_mod.DataReaderImpl, guid: Guid) void {
    var key_hash: [16]u8 = undefined;
    @memcpy(&key_hash, std.mem.asBytes(&guid));
    dr.pushBuiltinCdr(&.{}, key_hash, .not_alive_disposed);
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
///
/// quiesce_acquire/quiesce_release let checkTimers() hold the entity's
/// EntityQuiesce reference across its own unlock-then-dispatch window, not
/// just the acquire/release `check` itself takes internally. Without this,
/// `ctx` -- a raw pointer copied out of the participant's map while `mu` is
/// held -- has no protection against becoming dangling in the window
/// between releasing `mu` and `check` actually running: EntityQuiesce can't
/// protect a pointer that was already invalid before acquire() was called
/// on it (see entity_quiesce.zig's module doc comment). Calling
/// quiesce_acquire while `mu` is still held (so the entity is provably
/// still live at that point) and holding the reference until after `check`
/// returns closes that gap.
const TimerNotify = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, now_ns: i64) void,
    quiesce_acquire: *const fn (ctx: *anyopaque) bool,
    quiesce_release: *const fn (ctx: *anyopaque) void,
};

/// Callback registered by DataReaderImpl so that registerTypeSupport()'s
/// replacement path can push a freshly-registered get_field getter into a
/// reader that cached the old one -- see reader.zig's refreshGetFieldFn.
const RefreshGetField = struct {
    ctx: *anyopaque,
    refresh: *const fn (ctx: *anyopaque, new_get_field: ?filter_mod.CdrFieldGetter) void,
};

/// Callback registered by DataWriterImpl so that the participant can assert
/// liveliness on all relevant writers via vtAssertLiveliness().
const AssertNotify = struct {
    ctx: *anyopaque,
    assert_fn: *const fn (ctx: *anyopaque) void,
};

/// Callback registered by DataWriterImpl so that checkTimers()'s WLP driver
/// (RTPS §8.7.2.2.3) can read a writer's last-assertion timestamp without
/// reaching into its private state -- see writer.zig's livelinessLastNsFn.
const LivelinessQuery = struct {
    ctx: *anyopaque,
    last_assert_ns: *const fn (ctx: *anyopaque) i64,
};

/// Callback registered by DataReaderImpl so the participant can forward an
/// incoming WLP ParticipantMessageData (see wlpAliveFromDiscovery) straight
/// into DataReaderImpl.onParticipantAliveCb.
const WlpAliveNotify = struct {
    ctx: *anyopaque,
    notify_fn: *const fn (ctx: *anyopaque, prefix: GuidPrefix, kind: u8) void,
};

const DiscoveredParticipant = struct {
    guid: Guid,
    handle: DDS.InstanceHandle_t,
    /// VendorId from this participant's SPDP announcement. Used to work around
    /// known per-vendor RTPS wire-format quirks (see header_mod.needsPidCoherentSetMarker).
    vendor_id: header_mod.VendorId,
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

/// Persistent record of a remote writer discovered via SEDP, kept independent
/// of whether any local DataReader for the topic exists yet.  Lets a
/// DataReader created *after* the writer was discovered still be matched
/// immediately at creation time, instead of only reacting to (and possibly
/// missing) the one-shot onWriterDiscovered callback.  All slices owned.
///
/// Per RTPS 2.5 Table 8.78, individual SEDP endpoints carry no lease of their
/// own; entries are removed on individual retraction (onWriterLost) or when
/// the owning participant's SPDP lease expires (onParticipantLost).
const DiscoveredWriter = struct {
    guid: Guid,
    topic_name: []const u8, // owned
    type_name: []const u8, // owned
    qos: disc.QosSnapshot, // qos.partition_names owned via dupePartitionNames
    unicast_locators: []const Locator, // owned
    multicast_locators: []const Locator, // owned

    fn deinit(self: DiscoveredWriter, alloc: std.mem.Allocator) void {
        alloc.free(self.topic_name);
        alloc.free(self.type_name);
        DomainParticipantImpl.freePartitionNames(alloc, self.qos.partition_names);
        if (self.qos.user_data.len != 0) alloc.free(self.qos.user_data);
        alloc.free(self.unicast_locators);
        alloc.free(self.multicast_locators);
    }
};

/// Persistent record of a remote reader discovered via SEDP.  See
/// DiscoveredWriter for rationale and lifetime semantics.
const DiscoveredReader = struct {
    guid: Guid,
    topic_name: []const u8, // owned
    type_name: []const u8, // owned
    qos: disc.QosSnapshot, // qos.partition_names owned via dupePartitionNames
    unicast_locators: []const Locator, // owned
    multicast_locators: []const Locator, // owned

    fn deinit(self: DiscoveredReader, alloc: std.mem.Allocator) void {
        alloc.free(self.topic_name);
        alloc.free(self.type_name);
        DomainParticipantImpl.freePartitionNames(alloc, self.qos.partition_names);
        if (self.qos.user_data.len != 0) alloc.free(self.qos.user_data);
        alloc.free(self.unicast_locators);
        alloc.free(self.multicast_locators);
    }
};

/// Callback table registered per type name via registerTypeSupport().
/// Used to compute key hashes from CDR payloads when a received change
/// carries no inline-QoS key_hash.  Keyed types should register this to
/// enable per-instance OWNERSHIP, TIME_BASED_FILTER, and SampleInfo tracking.
pub const TypeSupport = struct {
    /// Opaque context passed as the first argument to all function pointers.
    /// Follows the same convention as Transport and Security plugin vtables.
    /// Zig-native implementations that need no state may pass `undefined`.
    ctx: *anyopaque,
    /// Compute the 16-byte DDS key hash from a CDR-encoded payload.
    /// `payload` includes the 4-byte encapsulation header (as received from
    /// the wire).  Return `zeroes([16]u8)` for keyless types.
    compute_key_hash: *const fn (ctx: *anyopaque, payload: []const u8) [16]u8,
    /// Optional: extract a named field value from a raw CDR payload.
    /// Used to evaluate ContentFilteredTopic expressions at delivery time.
    /// null = CFT evaluation deferred to the typed DataReader layer.
    /// Receives the same `ctx` as `compute_key_hash` above (one shared
    /// per-registration context, not a second one) — see the C-ABI's
    /// `zzdds_register_type_support_ctx`/Java's `zzdds_java_ts_ctx` for the
    /// two callbacks sharing one adapter object. `scratch` is caller-owned
    /// storage for a returned string value — see `filter_mod.CdrFieldGetter`'s
    /// doc comment for why a returned string must be copied there rather
    /// than pointing into this function's own locals.
    get_field: ?*const fn (ctx: *anyopaque, payload: []const u8, field: []const u8, scratch: []u8) ?filter_mod.FilterValue = null,
    /// Optional cleanup called when the participant deinits this TypeSupport entry.
    /// Use to free any ctx allocation.  null = no cleanup needed (e.g. ctx = undefined).
    deinit: ?*const fn (ctx: *anyopaque) void = null,
};

const ActiveWriter = struct {
    handle: DDS.InstanceHandle_t,
    guid: Guid,
    proto: proto.ProtocolWriter,
    topic_name: []const u8, // borrowed from topic_name slice in active list
    type_name: []const u8,
    // qos.data_representation.value must be zzdds-owned (cloned by
    // pubCreateProtoWriter before storing here, freed by
    // pubDestroyProtoWriter/deinit) -- the caller only guarantees its buffer
    // valid for the duration of the create_datawriter call, same class of
    // bug dupePartitionNames already exists to avoid for partition_names.
    qos: DDS.DataWriterQos,
    partition_names: []const []const u8 = &.{}, // heap-owned copy via dupePartitionNames
    presentation: DDS.PresentationQosPolicy = .{},
    incompat_qos: ?IncompatQosNotify = null,
    matched_notify: ?MatchedNotify = null,
    timer_check: ?TimerNotify = null,
    liveliness_assert: ?AssertNotify = null,
    liveliness_query: ?LivelinessQuery = null,
};

const ActiveReader = struct {
    handle: DDS.InstanceHandle_t,
    guid: Guid,
    proto: proto.ProtocolReader,
    topic_name: []const u8,
    type_name: []const u8,
    // See ActiveWriter.qos's matching comment: data_representation.value
    // must be zzdds-owned, cloned by subCreateProtoReader.
    qos: DDS.DataReaderQos,
    partition_names: []const []const u8 = &.{}, // heap-owned copy via dupePartitionNames
    presentation: DDS.PresentationQosPolicy = .{},
    incompat_qos: ?IncompatQosNotify = null,
    matched_notify: ?MatchedNotify = null,
    timer_check: ?TimerNotify = null,
    key_hash_ctx: *anyopaque = undefined,
    key_hash_fn: ?*const fn (*anyopaque, []const u8) [16]u8 = null,
    refresh_get_field: ?RefreshGetField = null,
    wlp_alive: ?WlpAliveNotify = null,
};

fn cloneUserData(
    alloc: std.mem.Allocator,
    source: DDS.UserDataQosPolicy,
) !DDS.UserDataQosPolicy {
    var result = source;
    const len = source.value._length;
    if (len == 0) {
        result.value = .{};
        return result;
    }
    const buffer = try alloc.alloc(u8, len);
    @memcpy(buffer, source.value._buffer.?[0..len]);
    result.value = .{
        ._maximum = len,
        ._length = len,
        ._buffer = buffer.ptr,
        ._release = true,
    };
    return result;
}

fn freeUserData(alloc: std.mem.Allocator, value: DDS.UserDataQosPolicy) void {
    if (value.value._release and value.value._buffer != null) {
        alloc.free(value.value._buffer.?[0..value.value._maximum]);
    }
}

// ── DomainParticipantImpl ────────────────────────────────────────────────────

pub const DomainParticipantImpl = struct {
    alloc: std.mem.Allocator,
    domain_id: DDS.DomainId_t,
    guid: Guid,
    qos: DDS.DomainParticipantQos,
    listener_box: *ListenerBox(DDS.DomainParticipantListener),
    /// Guards `listener_box` swaps/acquires only — never held across a
    /// dispatch or any other call (see listener_box.zig).
    listener_mu: Mutex = .{},
    listener_mask: DDS.StatusMask,
    instance_handle: DDS.InstanceHandle_t,
    status_changes: DDS.StatusMask,
    status_cond: ?*waitset.StatusConditionImpl,
    /// User-data (DataWriter/DataReader) transport. Normally the same handle as
    /// discovery_transport; when config.transport.tcp.enabled, this is instead
    /// a privately-owned TcpTransport (see owned_tcp_transport) so user data
    /// rides TCP while SPDP/SEDP keep using UDP unconditionally.
    transport: Transport,
    /// The shared UDP transport passed in at construction, always used for
    /// deriving this participant's metatraffic_unicast_locators in start().
    /// Distinct from `transport` only when TCP user-data is enabled.
    discovery_transport: Transport,
    /// Non-null when `transport` above is a TcpTransport this participant
    /// privately constructed and must deinit() itself. Null when `transport`
    /// is just the shared, externally-owned discovery_transport (the default).
    owned_tcp_transport: ?*TcpTransport,
    discovery: Discovery,
    security: SecurityPlugins,
    config: config_mod.Config,
    config_deinit_allocator: ?std.mem.Allocator,

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

    /// Remote writers/readers discovered via SEDP, kept independent of
    /// currently-active local entities so a DataReader/DataWriter created
    /// after the remote endpoint was discovered can still be matched
    /// immediately.  Deduped/updated by GUID.  Guarded by mu.
    discovered_writers: std.ArrayListUnmanaged(DiscoveredWriter),
    discovered_readers: std.ArrayListUnmanaged(DiscoveredReader),

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

    /// Background thread periodically calling checkTimers() to enforce
    /// DEADLINE and LIVELINESS QoS -- previously nothing called checkTimers()
    /// at all, so those statuses only ever fired under a test's ManualClock.
    /// Spawned once at the end of start(), stopped as the very first step of
    /// deinit() (before anything else is torn down) so it can never observe
    /// partially-destroyed participant state -- same lifetime discipline as
    /// writer_sm.zig's per-writer heartbeat thread and spdp.zig's
    /// per-participant announcement timer (thread lifetime strictly bounded
    /// by the owning object's own init/deinit, never reaching across
    /// objects -- see docs/roadmap.md's "Background thread usage" entry for
    /// why that matters here specifically).
    timer_thread: ?std.Thread = null,
    /// Set by timerThreadFn as its first action, read by deinit() to detect
    /// a self-join (see deinit()'s doc comment). 0 = not yet set; real
    /// std.Thread.Id values are never 0 in practice on any supported
    /// platform, so it doubles as the "unset" sentinel.
    timer_thread_id: std.atomic.Value(std.Thread.Id) = .init(0),
    timer_stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by deinit() instead of freeing `self` immediately, when deinit()
    /// is reached reentrantly from the timer thread itself (see deinit()'s
    /// doc comment). Only ever written and read from that same thread, so
    /// a plain bool is fine -- no cross-thread visibility is needed for it.
    pending_self_destroy: bool = false,

    /// One box for the whole object, shared across every interface view
    /// (DomainParticipant, Entity, and ZZDDS.DomainParticipant — see
    /// src/c_abi/extensions.zig) — see `views` below and
    /// zidl/docs/roadmap.md "Binding design review: decision".
    c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    /// Interval between periodic DEADLINE/LIVELINESS timer checks.
    const TIMER_CHECK_INTERVAL_MS: u64 = 100;

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
        // When TCP user-data is enabled, construct a dedicated TcpTransport for
        // this participant's DataWriter/DataReader traffic. SPDP/SEDP keep using
        // `transport` (renamed discovery_transport below) unconditionally.
        var owned_tcp: ?*TcpTransport = null;
        errdefer if (owned_tcp) |t| t.deinit();
        const data_transport: Transport = if (config.transport.tcp.enabled) blk: {
            const tcp = try TcpTransport.init(alloc, config.transport.tcp);
            owned_tcp = tcp;
            break :blk tcp.transport();
        } else transport;

        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .domain_id = domain_id,
            .guid = guid,
            .qos = .{},
            .listener_box = undefined,
            .listener_mask = mask,
            .instance_handle = handle,
            .status_changes = 0,
            .status_cond = null,
            .transport = data_transport,
            .discovery_transport = transport,
            .owned_tcp_transport = owned_tcp,
            .discovery = discovery,
            .security = security,
            .config = config,
            .config_deinit_allocator = null,
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
            .discovered_writers = .empty,
            .discovered_readers = .empty,
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
                .on_wlp_alive = wlpAliveFromDiscovery,
            },
            .data_listen_port = 0,
            .tracer = tracer,
            .timer_clock = timer_clock,
            .mu = .{},
        };
        errdefer alloc.destroy(self);
        self.listener_box = try ListenerBox(DDS.DomainParticipantListener).create(alloc, listener);
        errdefer alloc.destroy(self.listener_box);
        self.qos = try qos.clone(alloc);
        errdefer self.qos.deinit(alloc);
        const sc = try waitset.StatusConditionImpl.init(alloc, self.toEntity(), getStatusFn);
        self.status_cond = sc;
        // Seed default_topic_qos's durability/reliability/history from the
        // resolved config's QosDefaults -- previously computed by
        // toRuntimeConfig and stored on self.config, but never read again by
        // any entity-creation path (see config/schema.zig's QosDefaults doc).
        generated_config_mod.applyQosDefaults(&self.default_topic_qos, &self.config.qos);
        self.builtin_sub = BuiltinSubscriberState.init(alloc, self) catch null;
        return self;
    }

    /// Start discovery. Call once after init(). The discovery plugin begins
    /// announcing the participant and delivering remote-endpoint callbacks.
    pub fn start(self: *Self) !void {
        const udp_cfg = &self.config.transport.udp;
        const part_cfg = &self.config.participant;

        // Metatraffic unicast locators always come from discovery_transport (UDP)
        // regardless of the user-data transport in use — SPDP/SEDP are unaffected
        // by config.transport.tcp.enabled.
        var meta_locators: std.ArrayListUnmanaged(Locator) = .empty;
        defer meta_locators.deinit(self.alloc);
        try self.discovery_transport.unicastLocators(&meta_locators, self.alloc);

        // Data (user-data) unicast locators, and this participant's data-listen
        // port. Two shapes, mutually exclusive:
        //   TCP enabled → bind self.transport (a TcpTransport) directly and
        //     announce whatever real address/port it resolves to; the UDP
        //     meta-port formula below doesn't apply to a connection-oriented
        //     transport with no port-formula concept.
        //   UDP (default) → data_unicast_port override, or meta port + (D3 - D1)
        //     offset, exactly as before.
        var data_locators: std.ArrayListUnmanaged(Locator) = .empty;
        defer data_locators.deinit(self.alloc);
        var mc_locs_buf: [1]Locator = undefined;
        var mc_locs: []const Locator = &.{};
        if (self.config.transport.tcp.enabled) {
            const tcp_cfg = &self.config.transport.tcp;
            const bind_addr = if (tcp_cfg.bind_address.len > 0)
                try parseIpv4(tcp_cfg.bind_address)
            else
                [4]u8{ 0, 0, 0, 0 };
            const ephemeral = Locator.tcp4(bind_addr, 0);
            // Bind now (rather than in the generic listen block below) so the
            // real, OS-assigned address/port is known in time to announce it.
            try self.transport.listen(&ephemeral, transport_if.ReceiveHandler{
                .ctx = self,
                .on_receive = userDataOnReceive,
            });
            var tcp_locs: std.ArrayListUnmanaged(Locator) = .empty;
            defer tcp_locs.deinit(self.alloc);
            try self.transport.unicastLocators(&tcp_locs, self.alloc);
            for (tcp_locs.items) |loc| {
                try data_locators.append(self.alloc, loc);
                if (self.data_listen_port == 0) {
                    self.data_listen_port = switch (loc) {
                        .tcp_v4 => |t| t.port,
                        .tcp_v6 => |t| t.port,
                        else => 0,
                    };
                }
            }
            // No multicast over TCP; mc_locs stays empty.
        } else if (udp_cfg.data_unicast_port) |dp| {
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

        // SPDP metatraffic multicast locator derived from config. Always
        // computed regardless of config.transport.tcp.enabled — this is
        // SPDP's own rendezvous group (discovery is always UDP); it has
        // nothing to do with which transport user-data traffic uses.
        {
            const mc_port = config_mod.metatrafficMulticastPort(udp_cfg, self.domain_id);
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
        }

        // All six SPDP + SEDP built-in endpoints (RTPS §8.5.4.2 Table 8.58)
        // plus WLP's Participant Message writer/reader (§8.4.13.2).
        const BUILTIN_ENDPOINTS: u32 =
            0x00000001 | // DISC_BUILTIN_ENDPOINT_PARTICIPANT_ANNOUNCER
            0x00000002 | // DISC_BUILTIN_ENDPOINT_PARTICIPANT_DETECTOR
            0x00000004 | // DISC_BUILTIN_ENDPOINT_PUBLICATIONS_ANNOUNCER
            0x00000008 | // DISC_BUILTIN_ENDPOINT_PUBLICATIONS_DETECTOR
            0x00000010 | // DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_ANNOUNCER
            0x00000020 | // DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_DETECTOR
            0x00000400 | // BUILTIN_ENDPOINT_PARTICIPANT_MESSAGE_DATA_WRITER
            0x00000800; // BUILTIN_ENDPOINT_PARTICIPANT_MESSAGE_DATA_READER

        // When TCP user-data is enabled, give discovery a way to ask "is this
        // locator reachable by the participant's data transport" without
        // discovery ever holding that transport itself — see the
        // DataLocatorReachability doc comment. &self.transport is stable for
        // the participant's lifetime, well past this start() call.
        const data_reachable: ?disc.DataLocatorReachability = if (self.config.transport.tcp.enabled)
            .{ .ctx = &self.transport, .can_reach = dataTransportCanReach }
        else
            null;

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
            .data_reachable = data_reachable,
        };
        try self.discovery.start(&ann, &self.disc_callbacks);

        // Listen on the data unicast port for user DataWriter traffic. When TCP
        // user-data is enabled this already happened above (binding was needed
        // early, to learn the real address/port before announcing it).
        if (!self.config.transport.tcp.enabled and self.data_listen_port != 0) {
            const listen_loc = Locator.udp4(.{ 0, 0, 0, 0 }, self.data_listen_port);
            try self.transport.listen(&listen_loc, transport_if.ReceiveHandler{
                .ctx = self,
                .on_receive = userDataOnReceive,
            });
        }

        // Last step, deliberately: no thread exists yet at this point, so a
        // spawn failure here needs no stop/join cleanup of its own. Without
        // this thread, DEADLINE/LIVELINESS enforcement never fires with
        // nothing to explain why -- too severe to degrade silently, so this
        // is propagated as a start() error like every other setup failure
        // above. factory.zig's create_participant() already handles a
        // start() error by calling p.deinit() (which tolerates a null
        // timer_thread) and returning null, so no new cleanup path is
        // needed here.
        self.timer_thread = std.Thread.spawn(.{}, timerThreadFn, .{self}) catch |err| {
            log_mod.dcps.warn("participant: failed to spawn timer thread ({s}) -- DEADLINE/LIVELINESS QoS will not be enforced for this participant", .{@errorName(err)});
            return err;
        };
    }

    /// Periodically calls checkTimers() to enforce DEADLINE/LIVELINESS QoS.
    /// Stopped by setting timer_stopping before calling timer_thread.join()
    /// (see deinit()) -- same shape as writer_sm.zig's heartbeatThread.
    fn timerThreadFn(self: *Self) void {
        // Captured before the loop, and used only after the loop below has
        // genuinely exited -- see the pending_self_destroy branch at the
        // end of this function and deinit()'s matching comment. Reading
        // self.alloc directly at that point would also be safe (self isn't
        // freed until this exact line runs), but capturing it up front
        // keeps that safety argument local to this function instead of
        // depending on deinit() never having touched the field.
        const alloc = self.alloc;
        self.timer_thread_id.store(std.Thread.getCurrentId(), .release);
        while (!self.timer_stopping.load(.acquire)) {
            var slept_ms: u64 = 0;
            while (slept_ms < TIMER_CHECK_INTERVAL_MS and !self.timer_stopping.load(.acquire)) {
                time_mod.sleepNs(50 * std.time.ns_per_ms);
                slept_ms += 50;
            }
            if (self.timer_stopping.load(.acquire)) break;
            self.checkTimers();
        }
        // A reentrant deinit() (see its doc comment) deferred the actual
        // free to here, since it couldn't safely free `self` out from
        // under this still-running function. The loop above has now
        // genuinely exited (timer_stopping is true either way), so it's
        // safe to do now -- nothing below touches `self` again.
        if (self.pending_self_destroy) alloc.destroy(self);
    }

    pub fn deinit(self: *Self) void {
        // Stop and join the timer thread before anything else -- it calls
        // checkTimers(), which touches self.mu and self.active_writers/
        // active_readers; nothing past this point may run concurrently with
        // it. See timer_thread's field doc comment for why this has to be
        // the very first thing deinit() does.
        self.timer_stopping.store(true, .release);
        // deinit() can be reached from the timer thread itself:
        // checkTimers() -> a DEADLINE/LIVELINESS notification -> a user
        // listener that (spec-legally) reentrantly deletes every child
        // entity and then the participant itself, synchronously, from
        // inside the callback. Detected once, used below both to avoid
        // joining the calling thread from itself (deadlock) and to avoid
        // freeing `self` while checkTimers()/timerThreadFn are still
        // executing further up this very call stack (see the
        // pending_self_destroy branch at the end of this function).
        const self_reentrant = std.Thread.getCurrentId() == self.timer_thread_id.load(.acquire);
        if (self.timer_thread) |t| {
            if (self_reentrant) {
                // A thread joining itself deadlocks, so detach instead --
                // timer_stopping is already set above, so once this call
                // unwinds back up to timerThreadFn's loop condition it
                // exits on its own, and a detached thread's resources are
                // reclaimed by the OS without a join.
                t.detach();
            } else {
                t.join();
            }
            self.timer_thread = null;
        }
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
        self.c_abi.free(self.alloc);

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

        // Drop the "installed" listener_box reference only now that every
        // caller reaching it via dispatchFallback()/acquireListener() -- the
        // UDP receive path (unlistened above) and every contained
        // reader/writer's own fallback dispatch (drained just above) -- is
        // fully torn down. This call doesn't take listener_mu (unlike
        // acquireListener()), so releasing any earlier left a window where a
        // still-running receive-thread dispatch could acquire this exact box
        // concurrently with this thread freeing it -- a cross-thread
        // double-free/use-after-free with no lock to serialize the two.
        self.listener_box.releaseRef(self.alloc);

        self.type_info_registry.deinit(self.alloc);
        var ts_it = self.type_support_registry.iterator();
        while (ts_it.next()) |entry| {
            if (entry.value_ptr.deinit) |f| f(entry.value_ptr.ctx);
            self.alloc.free(entry.key_ptr.*);
        }
        self.type_support_registry.deinit(self.alloc);

        // Any remaining active writers/readers (normally all removed by pub/sub deinit).
        var wit = self.active_writers.valueIterator();
        while (wit.next()) |aw| {
            aw.proto.deinit();
            freePartitionNames(self.alloc, aw.partition_names);
            aw.qos.data_representation.value.deinit(self.alloc);
            freeUserData(self.alloc, aw.qos.user_data);
        }
        self.active_writers.deinit(self.alloc);
        var rit = self.active_readers.valueIterator();
        while (rit.next()) |ar| {
            ar.proto.deinit();
            freePartitionNames(self.alloc, ar.partition_names);
            ar.qos.data_representation.value.deinit(self.alloc);
            freeUserData(self.alloc, ar.qos.user_data);
        }
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
        for (self.discovered_writers.items) |dw| dw.deinit(self.alloc);
        self.discovered_writers.deinit(self.alloc);
        for (self.discovered_readers.items) |dr| dr.deinit(self.alloc);
        self.discovered_readers.deinit(self.alloc);

        self.qos.deinit(self.alloc);
        self.default_pub_qos.deinit(self.alloc);
        self.default_sub_qos.deinit(self.alloc);
        self.default_topic_qos.deinit(self.alloc);
        if (self.config_deinit_allocator) |cfg_alloc| {
            generated_config_mod.deinitRuntimeConfig(cfg_alloc, &self.config);
        }

        // Torn down last: writers/readers above may still hold and use
        // self.transport (e.g. sending final BYE/unregister traffic) during
        // their own deinit.
        if (self.owned_tcp_transport) |t| t.deinit();

        // Every step above only touches self's own fields and owned
        // sub-resources, so it's safe to run reentrantly regardless of
        // which thread called deinit(). Freeing `self` itself is the one
        // exception: checkTimers() and timerThreadFn are still executing
        // further up this exact call stack when self_reentrant is true,
        // and still need `self` (e.g. to read timer_stopping, already true
        // above) to unwind safely. Defer the actual free to timerThreadFn,
        // which performs it as the very last thing it does once its own
        // loop has genuinely exited -- see timerThreadFn.
        if (self_reentrant) {
            self.pending_self_destroy = true;
        } else {
            self.alloc.destroy(self);
        }
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
    pub fn registerTypeSupport(self: *Self, type_name: []const u8, ts: TypeSupport) bool {
        // Heap-copy the key so the map owns it regardless of caller lifetime.
        const owned_key = self.alloc.dupe(u8, type_name) catch {
            if (ts.deinit) |f| f(ts.ctx);
            return false;
        };
        self.mu.lock();
        defer self.mu.unlock();
        const gop = self.type_support_registry.getOrPut(self.alloc, owned_key) catch {
            self.alloc.free(owned_key);
            if (ts.deinit) |f| f(ts.ctx);
            return false;
        };
        if (gop.found_existing) {
            // Replacing: propagate new ctx/fn to active readers that cached
            // the old pointers BEFORE freeing the old TypeSupport's ctx
            // below -- this must run first. refresh_get_field's swap is
            // synchronized by the reader's own mu, not participant.mu, so a
            // concurrent QueryCondition/CFT evaluation (which only takes
            // reader.mu, never participant.mu) can run at any point during
            // this whole function; freeing the old ctx before every reader
            // has been refreshed would leave that evaluation free to read
            // the still-old cached getter and invoke it with already-freed
            // ctx.
            var ar_it = self.active_readers.valueIterator();
            while (ar_it.next()) |ar| {
                if (std.mem.eql(u8, ar.type_name, type_name)) {
                    ar.key_hash_ctx = ts.ctx;
                    ar.key_hash_fn = ts.compute_key_hash;
                    // Also refresh whatever the reader itself cached at
                    // creation time (get_field_fn, and cft_filter.get_field_fn
                    // if it was created against a ContentFilteredTopic) --
                    // otherwise it keeps pointing at the old TypeSupport's
                    // ctx until the next reader/filter is created, and a
                    // CFT/QueryCondition evaluation in between dereferences
                    // freed memory once the deinit below runs.
                    if (ar.refresh_get_field) |rf| {
                        const new_get_field: ?filter_mod.CdrFieldGetter = if (ts.get_field) |f|
                            .{ .ctx = ts.ctx, .func = f }
                        else
                            null;
                        rf.refresh(rf.ctx, new_get_field);
                    }
                }
            }
            // Now safe: every active reader for this type has been
            // refreshed off the old ctx (refresh_get_field's internal
            // reader.mu lock/unlock happened-before this point, so any
            // subsequent reader.mu-protected read observes the new getter,
            // never the old one), so it can be freed and swapped in.
            if (gop.value_ptr.deinit) |f| f(gop.value_ptr.ctx);
            self.alloc.free(gop.key_ptr.*);
            gop.key_ptr.* = owned_key;
        }
        gop.value_ptr.* = ts;
        return true;
    }

    pub fn registerTypeInfo(self: *Self, type_name: []const u8, cdr: []const u8) void {
        if (!build_opts.xtypes) return;
        self.type_info_registry.put(self.alloc, type_name, cdr) catch {};
    }

    pub fn toEntity(self: *Self) DDS.Entity {
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
        presentation: DDS.PresentationQosPolicy,
        publication_handle: *DDS.InstanceHandle_t,
        guid_out: *Guid,
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
        guid_out.* = guid;
        publication_handle.* = writer_mod.guidToHandle(guid);

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
        // {0,0} from codegen means unset → infinite (no lifespan enforcement),
        // matching the convention used by writerQosSnapshot for SEDP announcement.
        const ls_zero = qos.lifespan.duration.sec == 0 and qos.lifespan.duration.nanosec == 0;
        adapter.setLifespan(if (ls_zero) null else time_mod.RtpsDuration.fromDuration(.{
            .sec = qos.lifespan.duration.sec,
            .nanosec = qos.lifespan.duration.nanosec,
        }));

        const pw = adapter.toProtocolWriter();

        // qos.data_representation.value._buffer, as received here, borrows
        // storage the caller only guarantees valid for the duration of this
        // call (e.g. the C++ binding's create_datawriter passes qos by value
        // through a chain of stack-local copies that get destroyed once this
        // whole call returns -- see ActiveWriter.qos's doc comment). Clone it
        // the same way dupePartitionNames already does for partition_names,
        // or writerQosSnapshot() re-reads this later (at match time, against
        // a newly-discovered remote reader) and gets garbage -- confirmed via
        // a real repro: -x 2 matching flakiness traced to exactly this.
        var owned_qos = qos;
        owned_qos.data_representation.value = try qos.data_representation.value.clone(self.alloc);
        errdefer owned_qos.data_representation.value.deinit(self.alloc);
        owned_qos.user_data = try cloneUserData(self.alloc, qos.user_data);
        errdefer freeUserData(self.alloc, owned_qos.user_data);

        {
            self.mu.lock();
            defer self.mu.unlock();
            try self.active_writers.put(self.alloc, entityIdKey(guid.entity_id), .{
                .handle = publication_handle.*,
                .guid = guid,
                .proto = pw,
                .topic_name = topic_name,
                .type_name = type_name,
                .qos = owned_qos,
                .presentation = presentation,
            });
        }

        return pw;
    }

    fn pubDestroyProtoWriter(ctx: *anyopaque, handle: DDS.InstanceHandle_t) void {
        const self = cast(ctx);
        var found_guid: ?Guid = null;
        var found_proto: ?proto.ProtocolWriter = null;
        var found_parts: []const []const u8 = &.{};
        var found_repr: DDS.DataRepresentationIdSeq = .{};
        var found_user_data: DDS.UserDataQosPolicy = .{};

        self.mu.lock();
        var writ = self.active_writers.valueIterator();
        while (writ.next()) |aw| {
            if (aw.handle == handle) {
                found_guid = aw.guid;
                found_proto = aw.proto;
                found_parts = aw.partition_names;
                found_repr = aw.qos.data_representation.value;
                found_user_data = aw.qos.user_data;
                break;
            }
        }
        if (found_guid) |g| _ = self.active_writers.remove(entityIdKey(g.entity_id));
        self.mu.unlock();

        freePartitionNames(self.alloc, found_parts);
        found_repr.deinit(self.alloc);
        freeUserData(self.alloc, found_user_data);
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
        presentation: DDS.PresentationQosPolicy,
        guid_out: *Guid,
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
        guid_out.* = guid;

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

        // See pubCreateProtoWriter's matching comment: qos.data_representation
        // .value must be cloned into zzdds-owned storage before being stashed
        // in ActiveReader, or a later readerQosSnapshot() call reads a
        // dangling buffer.
        var owned_qos = qos;
        owned_qos.data_representation.value = try qos.data_representation.value.clone(self.alloc);
        errdefer owned_qos.data_representation.value.deinit(self.alloc);
        owned_qos.user_data = try cloneUserData(self.alloc, qos.user_data);
        errdefer freeUserData(self.alloc, owned_qos.user_data);

        {
            self.mu.lock();
            defer self.mu.unlock();
            try self.active_readers.put(self.alloc, entityIdKey(guid.entity_id), .{
                .handle = handle,
                .guid = guid,
                .proto = pr,
                .topic_name = topic_name,
                .type_name = type_name,
                .qos = owned_qos,
                .presentation = presentation,
                .key_hash_ctx = if (self.type_support_registry.get(type_name)) |ts| ts.ctx else undefined,
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
        var found_parts: []const []const u8 = &.{};
        var found_repr: DDS.DataRepresentationIdSeq = .{};
        var found_user_data: DDS.UserDataQosPolicy = .{};

        self.mu.lock();
        var rrit = self.active_readers.valueIterator();
        while (rrit.next()) |ar| {
            if (ar.handle == handle) {
                found_guid = ar.guid;
                found_proto = ar.proto;
                found_parts = ar.partition_names;
                found_repr = ar.qos.data_representation.value;
                found_user_data = ar.qos.user_data;
                break;
            }
        }
        if (found_guid) |g| _ = self.active_readers.remove(entityIdKey(g.entity_id));
        self.mu.unlock();

        freePartitionNames(self.alloc, found_parts);
        found_repr.deinit(self.alloc);
        freeUserData(self.alloc, found_user_data);
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
        // Lifespan: {0,0} from codegen means unset → treat as infinite.
        const ls_zero_w = qos.lifespan.duration.sec == 0 and qos.lifespan.duration.nanosec == 0;
        return .{
            .reliability_kind = if (qos.reliability.kind == .RELIABLE_RELIABILITY_QOS) @as(u8, 1) else 0,
            .durability_kind = @as(u8, @truncate(@intFromEnum(qos.durability.kind))),
            .history_kind = if (qos.history.kind == .KEEP_ALL_HISTORY_QOS) @as(u8, 1) else 0,
            // DDS spec: KEEP_LAST depth must be >= 1; default 0 from codegen → clamp to 1.
            .history_depth = if (keep_last and qos.history.depth < 1) 1 else qos.history.depth,
            .liveliness_kind = @as(u8, @truncate(@intFromEnum(qos.liveliness.kind))),
            .liveliness_lease_sec = if (ll_zero_w) 0x7fff_ffff else qos.liveliness.lease_duration.sec,
            .liveliness_lease_nanosec = if (ll_zero_w) 0xffff_ffff else qos.liveliness.lease_duration.nanosec,
            .ownership_kind = if (qos.ownership.kind == .EXCLUSIVE_OWNERSHIP_QOS) @as(u8, 1) else 0,
            .ownership_strength = qos.ownership_strength.value,
            .destination_order_kind = if (qos.destination_order.kind == .BY_SOURCE_TIMESTAMP_DESTINATIONORDER_QOS) @as(u8, 1) else 0,
            .data_representation = if (comptime build_opts.xtypes)
                reprFromQos(if (qos.data_representation.value._buffer) |b| b[0..qos.data_representation.value._length] else &.{})
            else
                1,
            .deadline_sec = if (dl_zero_w) 0x7fff_ffff else qos.deadline.period.sec,
            .deadline_nanosec = if (dl_zero_w) 0xffff_ffff else qos.deadline.period.nanosec,
            .presentation_access_scope = @as(u8, @intCast(@intFromEnum(presentation.access_scope))),
            .coherent_access = presentation.coherent_access,
            .ordered_access = presentation.ordered_access,
            .user_data = if (qos.user_data.value._buffer) |buffer|
                buffer[0..qos.user_data.value._length]
            else
                &.{},
            .lifespan_sec = if (ls_zero_w) 0x7fff_ffff else qos.lifespan.duration.sec,
            .lifespan_nanosec = if (ls_zero_w) 0xffff_ffff else qos.lifespan.duration.nanosec,
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
                reprFromQos(if (qos.data_representation.value._buffer) |b| b[0..qos.data_representation.value._length] else &.{})
            else
                2, // Advertise XCDR2 acceptance so XCDR2-capable writers (OpenDDS) match.
            // zzdds stores raw CDR bytes and interop programs parse both XCDR1/2.
            .deadline_sec = if (dl_zero_r) 0x7fff_ffff else qos.deadline.period.sec,
            .deadline_nanosec = if (dl_zero_r) 0xffff_ffff else qos.deadline.period.nanosec,
            .presentation_access_scope = @as(u8, @intCast(@intFromEnum(presentation.access_scope))),
            .coherent_access = presentation.coherent_access,
            .ordered_access = presentation.ordered_access,
            .user_data = if (qos.user_data.value._buffer) |buffer|
                buffer[0..qos.user_data.value._length]
            else
                &.{},
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
                    // RTPS §8.6.3.5: NOT_ALIVE_DISPOSED_UNREGISTERED (0x3, both bits) is
                    // treated as NOT_ALIVE_UNREGISTERED on the subscriber side — the writer
                    // has departed, so instance_state = NOT_ALIVE_NO_WRITERS_INSTANCE_STATE.
                    // Check UNREGISTERED first so that 0x3 maps to not_alive_unregistered.
                    if (v & 0x2 != 0) return .not_alive_unregistered;
                    if (v & 0x1 != 0) return .not_alive_disposed;
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

    fn decodeCoherentSetSn(iq: ?submsg_mod.InlineQos, little_endian: bool) ?history_mod.SequenceNumber {
        if (iq) |q| {
            if (q.get(.coherent_set)) |cs| {
                if (cs.len >= 8) {
                    const order: std.builtin.Endian = if (little_endian) .little else .big;
                    const high = std.mem.readInt(i32, cs[0..4], order);
                    const low = std.mem.readInt(u32, cs[4..8], order);
                    const h: i64 = @as(i64, high) << 32;
                    const l: i64 = @as(i64, low);
                    const sn = h | l;
                    // Valid RTPS SNs start at 1.  SEQUENCENUMBER_UNKNOWN ({high=-1,low=MAX})
                    // and any other non-positive value are end-of-coherent-set signals
                    // (RTPS §9.6.4.2 Table 9.22 Example 2) — treat as non-coherent DATA.
                    if (sn < 1) return null;
                    return sn;
                }
            }
        }
        return null;
    }

    fn decodeGroupSeqNum(iq: ?submsg_mod.InlineQos, little_endian: bool) ?history_mod.SequenceNumber {
        if (iq) |q| {
            if (q.get(.group_seq_num)) |gs| {
                if (gs.len >= 8) {
                    const order: std.builtin.Endian = if (little_endian) .little else .big;
                    const high = std.mem.readInt(i32, gs[0..4], order);
                    const low = std.mem.readInt(u32, gs[4..8], order);
                    const h: i64 = @as(i64, high) << 32;
                    const l: i64 = @as(i64, low);
                    return h | l;
                }
            }
        }
        return null;
    }

    /// Decode this sample's PID_LIFESPAN inline QoS (RTPS §8.7.2 Table 8.85), if
    /// the writer sent one. Returns the duration in nanoseconds, or null if absent
    /// or DURATION_INFINITE — the caller falls back to the SEDP-discovered writer
    /// duration in that case.
    fn decodeLifespan(iq: ?submsg_mod.InlineQos, little_endian: bool) ?i64 {
        if (iq) |q| {
            if (q.get(.lifespan)) |ls| {
                if (ls.len >= 8) {
                    const order: std.builtin.Endian = if (little_endian) .little else .big;
                    const seconds = std.mem.readInt(i32, ls[0..4], order);
                    const fraction = std.mem.readInt(u32, ls[4..8], order);
                    const rd = time_mod.RtpsDuration{ .seconds = seconds, .fraction = fraction };
                    if (rd.isInfinite()) return null;
                    return rd.toDuration().toNs();
                }
            }
        }
        return null;
    }

    fn resolveKeyHash(kh: [16]u8, ar: *ActiveReader, payload: []const u8) [16]u8 {
        if (!std.mem.eql(u8, &kh, &std.mem.zeroes([16]u8))) return kh;
        if (ar.key_hash_fn) |f| return f(ar.key_hash_ctx, payload);
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
        coherent_set_sn: ?history_mod.SequenceNumber,
        group_seq_num: ?history_mod.SequenceNumber,
        lifespan_ns: ?i64,
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
                ar.proto.handleIncomingChange(writer_guid, sn, ts, kh, payload, kind, coherent_set_sn, group_seq_num, lifespan_ns);
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
                    const key_hash = decodeKeyHash(d.inline_qos);
                    const coherent_set_sn = decodeCoherentSetSn(d.inline_qos, d.isLittleEndian());
                    const group_seq_num = decodeGroupSeqNum(d.inline_qos, d.isLittleEndian());
                    const lifespan_ns = decodeLifespan(d.inline_qos, d.isLittleEndian());

                    if (d.inline_qos) |iq| {
                        if (iq.get(.directed_write)) |dw_bytes| {
                            dispatchDirectedWrite(self, dw_bytes, d.isLittleEndian(), writer_guid, d.writer_sn, current_ts, key_hash, d.serialized_payload, kind, coherent_set_sn, group_seq_num, lifespan_ns);
                            continue;
                        }
                    }

                    self.mu.lock();
                    if (d.reader_entity_id.eql(EntityIds.unknown)) {
                        var fan_it = self.active_readers.valueIterator();
                        while (fan_it.next()) |ar| {
                            const kh = resolveKeyHash(key_hash, ar, d.serialized_payload);
                            ar.proto.handleIncomingChange(writer_guid, d.writer_sn, current_ts, kh, d.serialized_payload, kind, coherent_set_sn, group_seq_num, lifespan_ns);
                        }
                    } else {
                        const rkey = entityIdKey(d.reader_entity_id);
                        if (self.active_readers.getPtr(rkey)) |ar| {
                            const kh = resolveKeyHash(key_hash, ar, d.serialized_payload);
                            ar.proto.handleIncomingChange(writer_guid, d.writer_sn, current_ts, kh, d.serialized_payload, kind, coherent_set_sn, group_seq_num, lifespan_ns);
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
                            ar.proto.handleHeartbeat(writer_guid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal(), hb.isLiveliness());
                        }
                    } else {
                        const rkey = entityIdKey(hb.reader_entity_id);
                        if (self.active_readers.getPtr(rkey)) |ar| {
                            ar.proto.handleHeartbeat(writer_guid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal(), hb.isLiveliness());
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
                        while (fan_it.next()) |ar| ar.proto.handleDataFrag(writer_guid, current_ts, df);
                    } else {
                        const rkey = entityIdKey(df.reader_entity_id);
                        if (self.active_readers.getPtr(rkey)) |ar| ar.proto.handleDataFrag(writer_guid, current_ts, df);
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
                    .{ .guid = data.guid, .handle = handle, .vendor_id = data.vendor_id },
                ) catch {};
                if (self.builtin_sub) |bs| push_dr = bs.part_dr;
            }
        }
        self.mu.unlock();
        if (push_dr) |dr| pushBuiltinParticipantCdr(self.alloc, dr, data);
    }

    fn onParticipantLost(ctx: *anyopaque, guid: disc.Guid) void {
        const self = cast(ctx);
        var lost_writers: std.ArrayListUnmanaged(Guid) = .empty;
        defer lost_writers.deinit(self.alloc);
        var lost_readers: std.ArrayListUnmanaged(Guid) = .empty;
        defer lost_readers.deinit(self.alloc);
        var publication_dr: ?*reader_mod.DataReaderImpl = null;
        var subscription_dr: ?*reader_mod.DataReaderImpl = null;
        self.mu.lock();
        for (self.discovered_participants.items, 0..) |e, i| {
            if (e.guid.eql(guid)) {
                _ = self.discovered_participants.swapRemove(i);
                break;
            }
        }
        for (self.discovered_writers.items) |entry| {
            if (entry.guid.prefix.eql(guid.prefix)) lost_writers.append(self.alloc, entry.guid) catch {};
        }
        for (self.discovered_readers.items) |entry| {
            if (entry.guid.prefix.eql(guid.prefix)) lost_readers.append(self.alloc, entry.guid) catch {};
        }
        if (self.builtin_sub) |bs| {
            publication_dr = bs.pub_dr;
            subscription_dr = bs.sub_dr;
        }
        // Remove matched writers/readers belonging to this participant from all
        // local DataReaders so they can generate NOT_ALIVE_NO_WRITERS.
        // Uses the GUID prefix as the membership key (all endpoints of a
        // participant share its prefix).
        const prefix = guid.prefix;
        var ar_it = self.active_readers.valueIterator();
        while (ar_it.next()) |ar| {
            var guids: std.ArrayListUnmanaged(Guid) = .empty;
            ar.proto.listMatchedWriters(self.alloc, &guids) catch continue;
            defer guids.deinit(self.alloc);
            for (guids.items) |w_guid| {
                if (!w_guid.prefix.eql(prefix)) continue;
                const before = ar.proto.matchedWriterCount();
                ar.proto.removeMatchedWriter(w_guid);
                if (ar.proto.matchedWriterCount() < before) {
                    if (ar.matched_notify) |cb|
                        cb.notify(cb.ctx, writer_mod.guidToHandle(w_guid), false);
                }
            }
        }
        // Symmetric sweep: remove matched readers belonging to this participant
        // from all local DataWriters so they can generate on_publication_matched
        // (count decreasing) / update matched-subscription state.
        var aw_it = self.active_writers.valueIterator();
        while (aw_it.next()) |aw| {
            var r_guids: std.ArrayListUnmanaged(Guid) = .empty;
            aw.proto.listMatchedReaders(self.alloc, &r_guids) catch continue;
            defer r_guids.deinit(self.alloc);
            for (r_guids.items) |r_guid| {
                if (!r_guid.prefix.eql(prefix)) continue;
                const before = aw.proto.matchedReaderCount();
                aw.proto.removeMatchedReader(r_guid);
                if (aw.proto.matchedReaderCount() < before) {
                    if (aw.matched_notify) |cb|
                        cb.notify(cb.ctx, writer_mod.guidToHandle(r_guid), false);
                }
            }
        }
        removeDiscoveredEndpointsForPrefix(self, prefix);
        self.mu.unlock();
        if (publication_dr) |dr| for (lost_writers.items) |endpoint_guid|
            pushBuiltinEndpointDisposed(dr, endpoint_guid);
        if (subscription_dr) |dr| for (lost_readers.items) |endpoint_guid|
            pushBuiltinEndpointDisposed(dr, endpoint_guid);
    }

    /// WLP (RTPS §8.4.13): a remote participant's ParticipantMessageData
    /// arrived, asserting liveliness of `kind` for its whole participant
    /// (`prefix`) -- fan it out to every local DataReader that registered
    /// interest, mirroring checkTimers()'s "collect callbacks under `mu`,
    /// dispatch after releasing it" discipline (never call into a reader
    /// while holding participant.mu -- see the RTPS proto quiesce work this
    /// codebase already did for on_writer_alive/matched-writer dispatch).
    /// Each notify_fn (DataReaderImpl.onParticipantAliveCb) does its own
    /// EntityQuiesce acquire/release internally, so no separate quiesce pair
    /// is needed here the way TimerNotify needs one.
    fn wlpAliveFromDiscovery(ctx: *anyopaque, prefix: GuidPrefix, kind: u8) void {
        const self = cast(ctx);
        var due: std.ArrayListUnmanaged(WlpAliveNotify) = .empty;
        defer due.deinit(self.alloc);
        {
            self.mu.lock();
            defer self.mu.unlock();
            var ar_it = self.active_readers.valueIterator();
            while (ar_it.next()) |ar| {
                if (ar.wlp_alive) |cb| due.append(self.alloc, cb) catch {};
            }
        }
        for (due.items) |cb| cb.notify_fn(cb.ctx, prefix, kind);
    }

    fn buildMatchedWriterInfo(
        guid: Guid,
        qos: disc.QosSnapshot,
        unicast_locators: []const Locator,
        multicast_locators: []const Locator,
    ) proto.MatchedWriterInfo {
        const ll_sec = qos.liveliness_lease_sec;
        const ll_ns = qos.liveliness_lease_nanosec;
        const lease_ns: i64 = if (ll_sec == 0x7fff_ffff)
            0 // infinite — no expiry tracking
        else
            @as(i64, ll_sec) * std.time.ns_per_s + @as(i64, ll_ns);
        const ls_sec = qos.lifespan_sec;
        const ls_ns = qos.lifespan_nanosec;
        const lifespan_ns: i64 = if (ls_sec == 0x7fff_ffff)
            0 // infinite — no expiry
        else
            @as(i64, ls_sec) * std.time.ns_per_s + @as(i64, ls_ns);
        return .{
            .guid = guid,
            .unicast_locators = unicast_locators,
            .multicast_locators = multicast_locators,
            .reliability = if (qos.reliability_kind == 1) .reliable else .best_effort,
            .ownership_strength = qos.ownership_strength,
            .liveliness_lease_ns = lease_ns,
            .liveliness_kind = qos.liveliness_kind,
            .lifespan_ns = lifespan_ns,
            .history_expected = qos.durability_kind > 0 and qos.reliability_kind == 1,
        };
    }

    const MatchedWriterJob = struct {
        proto: proto.ProtocolReader,
        info: proto.MatchedWriterInfo,
        notify: ?MatchedNotify,
    };

    fn onWriterDiscovered(ctx: *anyopaque, data: *const disc.WriterData) void {
        const self = cast(ctx);
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        var jobs: std.ArrayListUnmanaged(MatchedWriterJob) = .empty;
        defer jobs.deinit(self.alloc);
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
            // Defer the actual addMatchedWriter (and its initial ACKNACK/
            // replay send) until after self.mu is released below: it
            // reenters into transport I/O, which can synchronously deliver
            // to a peer participant (see transport/memory.zig) and lock
            // that peer's own participant.mu -- doing that while still
            // holding this participant's self.mu is a genuine lock-order
            // hazard, not just a slow critical section. quiesceAcquire()
            // keeps ar.proto (and the StatefulReader it owns) alive across
            // that unlocked window even if a concurrent delete_datareader
            // races it; see protocol/interface.zig's quiesce_acquire doc.
            if (!ar.proto.quiesceAcquire()) continue;
            const info = buildMatchedWriterInfo(data.guid, data.qos, data.unicast_locators, data.multicast_locators);
            jobs.append(self.alloc, .{ .proto = ar.proto, .info = info, .notify = ar.matched_notify }) catch ar.proto.quiesceRelease();
        }
        upsertDiscoveredWriter(self, data);
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
        for (jobs.items) |job| {
            job.proto.addMatchedWriter(&job.info) catch {};
            if (job.notify) |cb| cb.notify(cb.ctx, writer_mod.guidToHandle(data.guid), true);
            job.proto.quiesceRelease();
        }
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
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        self.mu.lock();
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
        removeDiscoveredWriter(self, guid);
        if (self.builtin_sub) |bs| push_dr = bs.pub_dr;
        self.mu.unlock();
        if (push_dr) |dr| pushBuiltinEndpointDisposed(dr, guid);
    }

    /// Looks up the VendorId of a previously-discovered participant by GUID
    /// prefix. Caller must hold self.mu (reads discovered_participants).
    fn vendorIdForPrefixLocked(self: *Self, prefix: guid_mod.GuidPrefix) ?header_mod.VendorId {
        for (self.discovered_participants.items) |e| {
            if (e.guid.prefix.eql(prefix)) return e.vendor_id;
        }
        return null;
    }

    fn buildMatchedReaderInfo(
        self: *Self,
        guid: Guid,
        qos: disc.QosSnapshot,
        unicast_locators: []const Locator,
        multicast_locators: []const Locator,
    ) proto.MatchedReaderInfo {
        const needs_marker = if (self.vendorIdForPrefixLocked(guid.prefix)) |vid|
            header_mod.needsPidCoherentSetMarker(vid)
        else
            false;
        return .{
            .guid = guid,
            .unicast_locators = unicast_locators,
            .multicast_locators = multicast_locators,
            .expects_inline_qos = false,
            .reliability = if (qos.reliability_kind == 1) .reliable else .best_effort,
            .durability_kind = qos.durability_kind,
            .needs_pid_coherent_set_marker = needs_marker,
        };
    }

    const MatchedReaderJob = struct {
        proto: proto.ProtocolWriter,
        info: proto.MatchedReaderInfo,
        notify: ?MatchedNotify,
    };

    fn onReaderDiscovered(ctx: *anyopaque, data: *const disc.ReaderData) void {
        const self = cast(ctx);
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        var jobs: std.ArrayListUnmanaged(MatchedReaderJob) = .empty;
        defer jobs.deinit(self.alloc);
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
            // See onWriterDiscovered's matching comment: defer the actual
            // addMatchedReader (and its initial HEARTBEAT/replay send)
            // until after self.mu is released below.
            if (!aw.proto.quiesceAcquire()) continue;
            const info = self.buildMatchedReaderInfo(data.guid, data.qos, data.unicast_locators, data.multicast_locators);
            jobs.append(self.alloc, .{ .proto = aw.proto, .info = info, .notify = aw.matched_notify }) catch aw.proto.quiesceRelease();
        }
        upsertDiscoveredReader(self, data);
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
        for (jobs.items) |job| {
            job.proto.addMatchedReader(&job.info) catch {};
            if (job.notify) |cb| cb.notify(cb.ctx, writer_mod.guidToHandle(data.guid), true);
            job.proto.quiesceRelease();
        }
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
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        self.mu.lock();
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
        removeDiscoveredReader(self, guid);
        if (self.builtin_sub) |bs| push_dr = bs.sub_dr;
        self.mu.unlock();
        if (push_dr) |dr| pushBuiltinEndpointDisposed(dr, guid);
    }

    // ── Discovered writer/reader registry (retroactive matching) ─────────────

    fn dupeLocators(alloc: std.mem.Allocator, locs: []const Locator) []const Locator {
        if (locs.len == 0) return &.{};
        return alloc.dupe(Locator, locs) catch &.{};
    }

    fn makeDiscoveredWriter(alloc: std.mem.Allocator, data: *const disc.WriterData) ?DiscoveredWriter {
        const tn = alloc.dupe(u8, data.topic_name) catch return null;
        const tt = alloc.dupe(u8, data.type_name) catch {
            alloc.free(tn);
            return null;
        };
        var qos = data.qos;
        qos.partition_names = dupePartitionNames(alloc, data.qos.partition_names);
        qos.user_data = if (data.qos.user_data.len == 0) &.{} else alloc.dupe(u8, data.qos.user_data) catch {
            freePartitionNames(alloc, qos.partition_names);
            alloc.free(tt);
            alloc.free(tn);
            return null;
        };
        return .{
            .guid = data.guid,
            .topic_name = tn,
            .type_name = tt,
            .qos = qos,
            .unicast_locators = dupeLocators(alloc, data.unicast_locators),
            .multicast_locators = dupeLocators(alloc, data.multicast_locators),
        };
    }

    fn makeDiscoveredReader(alloc: std.mem.Allocator, data: *const disc.ReaderData) ?DiscoveredReader {
        const tn = alloc.dupe(u8, data.topic_name) catch return null;
        const tt = alloc.dupe(u8, data.type_name) catch {
            alloc.free(tn);
            return null;
        };
        var qos = data.qos;
        qos.partition_names = dupePartitionNames(alloc, data.qos.partition_names);
        qos.user_data = if (data.qos.user_data.len == 0) &.{} else alloc.dupe(u8, data.qos.user_data) catch {
            freePartitionNames(alloc, qos.partition_names);
            alloc.free(tt);
            alloc.free(tn);
            return null;
        };
        return .{
            .guid = data.guid,
            .topic_name = tn,
            .type_name = tt,
            .qos = qos,
            .unicast_locators = dupeLocators(alloc, data.unicast_locators),
            .multicast_locators = dupeLocators(alloc, data.multicast_locators),
        };
    }

    /// Insert or refresh the persistent record for a discovered remote writer.
    /// Called unconditionally from onWriterDiscovered, regardless of whether any
    /// currently-active local reader matched — a future DataReader created for
    /// this topic still needs to find it.  Must be called with self.mu held.
    fn upsertDiscoveredWriter(self: *Self, data: *const disc.WriterData) void {
        for (self.discovered_writers.items, 0..) |*dw, i| {
            if (dw.guid.eql(data.guid)) {
                if (makeDiscoveredWriter(self.alloc, data)) |fresh| {
                    dw.deinit(self.alloc);
                    self.discovered_writers.items[i] = fresh;
                }
                return;
            }
        }
        if (makeDiscoveredWriter(self.alloc, data)) |fresh| {
            self.discovered_writers.append(self.alloc, fresh) catch {
                var f = fresh;
                f.deinit(self.alloc);
            };
        }
    }

    fn upsertDiscoveredReader(self: *Self, data: *const disc.ReaderData) void {
        for (self.discovered_readers.items, 0..) |*dr, i| {
            if (dr.guid.eql(data.guid)) {
                if (makeDiscoveredReader(self.alloc, data)) |fresh| {
                    dr.deinit(self.alloc);
                    self.discovered_readers.items[i] = fresh;
                }
                return;
            }
        }
        if (makeDiscoveredReader(self.alloc, data)) |fresh| {
            self.discovered_readers.append(self.alloc, fresh) catch {
                var f = fresh;
                f.deinit(self.alloc);
            };
        }
    }

    /// Must be called with self.mu held.
    fn removeDiscoveredWriter(self: *Self, guid: Guid) void {
        for (self.discovered_writers.items, 0..) |dw, i| {
            if (dw.guid.eql(guid)) {
                dw.deinit(self.alloc);
                _ = self.discovered_writers.swapRemove(i);
                return;
            }
        }
    }

    /// Must be called with self.mu held.
    fn removeDiscoveredReader(self: *Self, guid: Guid) void {
        for (self.discovered_readers.items, 0..) |dr, i| {
            if (dr.guid.eql(guid)) {
                dr.deinit(self.alloc);
                _ = self.discovered_readers.swapRemove(i);
                return;
            }
        }
    }

    /// Must be called with self.mu held.
    fn removeDiscoveredEndpointsForPrefix(self: *Self, prefix: GuidPrefix) void {
        var i: usize = 0;
        while (i < self.discovered_writers.items.len) {
            if (self.discovered_writers.items[i].guid.prefix.eql(prefix)) {
                self.discovered_writers.items[i].deinit(self.alloc);
                _ = self.discovered_writers.swapRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < self.discovered_readers.items.len) {
            if (self.discovered_readers.items[i].guid.prefix.eql(prefix)) {
                self.discovered_readers.items[i].deinit(self.alloc);
                _ = self.discovered_readers.swapRemove(i);
            } else i += 1;
        }
    }

    // ── ParticipantCbs factory helpers ────────────────────────────────────────

    fn dupePartitionNames(alloc: std.mem.Allocator, names: []const []const u8) []const []const u8 {
        if (names.len == 0) return &.{};
        const copy = alloc.alloc([]const u8, names.len) catch return &.{};
        for (copy, names, 0..) |*dst, src, i| {
            dst.* = alloc.dupe(u8, src) catch {
                for (copy[0..i]) |s| alloc.free(s);
                alloc.free(copy);
                return &.{};
            };
        }
        return copy;
    }

    fn freePartitionNames(alloc: std.mem.Allocator, names: []const []const u8) void {
        for (names) |s| alloc.free(s);
        if (names.len > 0) alloc.free(names);
    }

    const AnnounceMatchedReaderJob = struct {
        proto: proto.ProtocolWriter,
        info: proto.MatchedReaderInfo,
        notify: ?MatchedNotify,
        remote_guid: Guid,
        unicast_locs: []const Locator,
        multicast_locs: []const Locator,
    };

    fn pubAnnounceProtoWriter(ctx: *anyopaque, handle: DDS.InstanceHandle_t, publisher_handle: DDS.InstanceHandle_t, partition_names: []const []const u8, presentation: DDS.PresentationQosPolicy) void {
        const self = cast(ctx);
        // Find the writer and snapshot its announcement fields outside the lock.
        var ann_opt: ?struct {
            guid: Guid,
            topic_name: []const u8,
            type_name: []const u8,
            qos: DDS.DataWriterQos,
            presentation: DDS.PresentationQosPolicy,
        } = null;
        const owned_names = dupePartitionNames(self.alloc, partition_names);
        var jobs: std.ArrayListUnmanaged(AnnounceMatchedReaderJob) = .empty;
        defer jobs.deinit(self.alloc);
        {
            self.mu.lock();
            defer self.mu.unlock();
            var aw_it3 = self.active_writers.valueIterator();
            while (aw_it3.next()) |aw| {
                if (aw.handle == handle) {
                    freePartitionNames(self.alloc, aw.partition_names);
                    aw.partition_names = owned_names;
                    aw.presentation = presentation;
                    ann_opt = .{
                        .guid = aw.guid,
                        .topic_name = aw.topic_name,
                        .type_name = aw.type_name,
                        .qos = aw.qos,
                        .presentation = presentation,
                    };
                    // Retroactively match against readers discovered before this
                    // writer existed (or before it announced final partition/
                    // presentation QoS) — onReaderDiscovered only scans writers
                    // that already exist at the moment a reader is discovered, so
                    // without this a reader discovered first would never be matched.
                    const local_snap = writerQosSnapshot(aw.qos, aw.presentation);
                    for (self.discovered_readers.items) |dr| {
                        if (!std.mem.eql(u8, dr.topic_name, aw.topic_name)) continue;
                        if (!std.mem.eql(u8, dr.type_name, aw.type_name)) continue;
                        const result = qm_mod.checkSnapshots(local_snap, dr.qos);
                        if (!result.isCompatible()) continue;
                        const part_result = qm_mod.checkPartition(
                            .{ .name = aw.partition_names },
                            .{ .name = dr.qos.partition_names },
                        );
                        if (!part_result.isCompatible()) continue;
                        // See onWriterDiscovered's matching comment: defer the
                        // actual addMatchedReader send until after self.mu is
                        // released below. dr.unicast_locators/multicast_locators
                        // are borrowed from self.discovered_readers, which a
                        // concurrent discovery callback could mutate/reallocate
                        // once unlocked -- dupe them into job-owned memory now,
                        // under the lock, rather than deferring that too.
                        if (!aw.proto.quiesceAcquire()) continue;
                        const uloc = dupeLocators(self.alloc, dr.unicast_locators);
                        const mloc = dupeLocators(self.alloc, dr.multicast_locators);
                        const info = self.buildMatchedReaderInfo(dr.guid, dr.qos, uloc, mloc);
                        jobs.append(self.alloc, .{
                            .proto = aw.proto,
                            .info = info,
                            .notify = aw.matched_notify,
                            .remote_guid = dr.guid,
                            .unicast_locs = uloc,
                            .multicast_locs = mloc,
                        }) catch {
                            aw.proto.quiesceRelease();
                            self.alloc.free(uloc);
                            self.alloc.free(mloc);
                        };
                    }
                    break;
                }
            }
        }
        for (jobs.items) |job| {
            job.proto.addMatchedReader(&job.info) catch {};
            if (job.notify) |cb| cb.notify(cb.ctx, writer_mod.guidToHandle(job.remote_guid), true);
            job.proto.quiesceRelease();
            self.alloc.free(job.unicast_locs);
            self.alloc.free(job.multicast_locs);
        }
        const ann = ann_opt orelse {
            freePartitionNames(self.alloc, owned_names);
            return;
        };
        // Derive group GUID for GROUP-scope coherent publishers (PID_GROUP_GUID).
        // All writers in the same publisher share this GUID so that remote GROUP
        // subscribers can associate them into the same coherent group.
        const group_guid: ?Guid = if (presentation.coherent_access and
            presentation.access_scope == .GROUP_PRESENTATION_QOS)
        blk: {
            const h: u32 = @bitCast(publisher_handle);
            break :blk Guid{
                .prefix = self.guid.prefix,
                .entity_id = .{
                    .entity_key = .{
                        @truncate(h >> 16),
                        @truncate(h >> 8),
                        @truncate(h),
                    },
                    .entity_kind = guid_mod.EntityKind.writer_group,
                },
            };
        } else null;
        const type_info_cdr = self.type_info_registry.get(ann.type_name) orelse &.{};
        var snap = writerQosSnapshot(ann.qos, ann.presentation);
        snap.partition_names = owned_names;
        self.discovery.announceWriter(&disc.WriterAnnouncement{
            .guid = ann.guid,
            .participant_guid = self.guid,
            .group_guid = group_guid,
            .topic_name = ann.topic_name,
            .type_name = ann.type_name,
            .qos = snap,
            .type_object = &.{},
            .type_info_cdr = type_info_cdr,
        }) catch |err| {
            log_mod.dcps.warn("participant: failed to announce writer through SEDP: {s}", .{@errorName(err)});
        };
    }

    const AnnounceMatchedWriterJob = struct {
        proto: proto.ProtocolReader,
        info: proto.MatchedWriterInfo,
        notify: ?MatchedNotify,
        remote_guid: Guid,
        unicast_locs: []const Locator,
        multicast_locs: []const Locator,
    };

    fn subAnnounceProtoReader(ctx: *anyopaque, handle: DDS.InstanceHandle_t, partition_names: []const []const u8, presentation: DDS.PresentationQosPolicy) void {
        const self = cast(ctx);
        var ann_opt: ?struct {
            guid: Guid,
            topic_name: []const u8,
            type_name: []const u8,
            qos: DDS.DataReaderQos,
            presentation: DDS.PresentationQosPolicy,
        } = null;
        const owned_names = dupePartitionNames(self.alloc, partition_names);
        var jobs: std.ArrayListUnmanaged(AnnounceMatchedWriterJob) = .empty;
        defer jobs.deinit(self.alloc);
        {
            self.mu.lock();
            defer self.mu.unlock();
            var ar_it3 = self.active_readers.valueIterator();
            while (ar_it3.next()) |ar| {
                if (ar.handle == handle) {
                    freePartitionNames(self.alloc, ar.partition_names);
                    ar.partition_names = owned_names;
                    ar.presentation = presentation;
                    ann_opt = .{
                        .guid = ar.guid,
                        .topic_name = ar.topic_name,
                        .type_name = ar.type_name,
                        .qos = ar.qos,
                        .presentation = presentation,
                    };
                    // Retroactively match against writers discovered before this
                    // reader existed (or before it announced final partition/
                    // presentation QoS) — onWriterDiscovered only scans readers
                    // that already exist at the moment a writer is discovered, so
                    // without this a writer discovered first would never be matched.
                    const local_snap = readerQosSnapshot(ar.qos, ar.presentation);
                    for (self.discovered_writers.items) |dw| {
                        if (!std.mem.eql(u8, dw.topic_name, ar.topic_name)) continue;
                        if (!std.mem.eql(u8, dw.type_name, ar.type_name)) continue;
                        const result = qm_mod.checkSnapshots(dw.qos, local_snap);
                        if (!result.isCompatible()) {
                            // Mirrors onWriterDiscovered's live-discovery path below --
                            // without this, a writer whose (incompatible) SEDP
                            // announcement won the race against this reader's own
                            // creation was silently skipped here with no
                            // REQUESTED_INCOMPATIBLE_QOS notification at all, ever
                            // (onWriterDiscovered never gets a second chance to see
                            // this reader, since it only scans readers that already
                            // exist at discovery time -- this retroactive path is the
                            // only place that ever looks at this pairing again).
                            if (ar.incompat_qos) |cb|
                                cb.notify(cb.ctx, @as(i32, @intCast(@intFromEnum(result.incompatible))));
                            continue;
                        }
                        const part_result = qm_mod.checkPartition(
                            .{ .name = dw.qos.partition_names },
                            .{ .name = ar.partition_names },
                        );
                        if (!part_result.isCompatible()) continue;
                        // See onWriterDiscovered's matching comment: defer the
                        // actual addMatchedWriter send until after self.mu is
                        // released below, duping dw's locators (borrowed from
                        // self.discovered_writers) into job-owned memory now.
                        if (!ar.proto.quiesceAcquire()) continue;
                        const uloc = dupeLocators(self.alloc, dw.unicast_locators);
                        const mloc = dupeLocators(self.alloc, dw.multicast_locators);
                        const info = buildMatchedWriterInfo(dw.guid, dw.qos, uloc, mloc);
                        jobs.append(self.alloc, .{
                            .proto = ar.proto,
                            .info = info,
                            .notify = ar.matched_notify,
                            .remote_guid = dw.guid,
                            .unicast_locs = uloc,
                            .multicast_locs = mloc,
                        }) catch {
                            ar.proto.quiesceRelease();
                            self.alloc.free(uloc);
                            self.alloc.free(mloc);
                        };
                    }
                    break;
                }
            }
        }
        for (jobs.items) |job| {
            job.proto.addMatchedWriter(&job.info) catch {};
            if (job.notify) |cb| cb.notify(cb.ctx, writer_mod.guidToHandle(job.remote_guid), true);
            job.proto.quiesceRelease();
            self.alloc.free(job.unicast_locs);
            self.alloc.free(job.multicast_locs);
        }
        const ann = ann_opt orelse {
            freePartitionNames(self.alloc, owned_names);
            return;
        };
        const type_info_cdr = self.type_info_registry.get(ann.type_name) orelse &.{};
        var snap = readerQosSnapshot(ann.qos, ann.presentation);
        snap.partition_names = owned_names;
        self.discovery.announceReader(&disc.ReaderAnnouncement{
            .guid = ann.guid,
            .participant_guid = self.guid,
            .topic_name = ann.topic_name,
            .type_name = ann.type_name,
            .qos = snap,
            .type_info_cdr = type_info_cdr,
        }) catch |err| {
            log_mod.dcps.warn("participant: failed to announce reader through SEDP: {s}", .{@errorName(err)});
        };
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
        quiesce_acquire: *const fn (*anyopaque) bool,
        quiesce_release: *const fn (*anyopaque) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it6 = self.active_writers.valueIterator();
        while (aw_it6.next()) |aw| {
            if (aw.handle == handle) {
                aw.timer_check = .{ .ctx = notify_ctx, .check = notify_fn, .quiesce_acquire = quiesce_acquire, .quiesce_release = quiesce_release };
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

    fn pubRegisterWriterLivelinessQuery(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        last_assert_ns: *const fn (*anyopaque) i64,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it7b = self.active_writers.valueIterator();
        while (aw_it7b.next()) |aw| {
            if (aw.handle == handle) {
                aw.liveliness_query = .{ .ctx = notify_ctx, .last_assert_ns = last_assert_ns };
                break;
            }
        }
    }

    fn subRegisterReaderTimerNotify(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (*anyopaque, i64) void,
        quiesce_acquire: *const fn (*anyopaque) bool,
        quiesce_release: *const fn (*anyopaque) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var ar_it6 = self.active_readers.valueIterator();
        while (ar_it6.next()) |ar| {
            if (ar.handle == handle) {
                ar.timer_check = .{ .ctx = notify_ctx, .check = notify_fn, .quiesce_acquire = quiesce_acquire, .quiesce_release = quiesce_release };
                break;
            }
        }
    }

    fn subRegisterReaderGetFieldRefresh(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        type_name: []const u8,
        notify_ctx: *anyopaque,
        refresh_fn: *const fn (*anyopaque, ?filter_mod.CdrFieldGetter) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var ar_it9 = self.active_readers.valueIterator();
        while (ar_it9.next()) |ar| {
            if (ar.handle == handle) {
                ar.refresh_get_field = .{ .ctx = notify_ctx, .refresh = refresh_fn };
                break;
            }
        }
        // Same critical section as the refresh_get_field registration above,
        // and invoked synchronously here rather than returned for the caller
        // to assign -- see ParticipantCbs.register_get_field_refresh's doc
        // comment for why these must not be two separate lock acquisitions,
        // and why this must not be a return value assigned outside them.
        const current: ?filter_mod.CdrFieldGetter = if (self.type_support_registry.get(type_name)) |ts|
            if (ts.get_field) |func| .{ .ctx = ts.ctx, .func = func } else null
        else
            null;
        refresh_fn(notify_ctx, current);
    }

    fn subRegisterReaderWlpAliveNotify(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (*anyopaque, GuidPrefix, u8) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var ar_it10 = self.active_readers.valueIterator();
        while (ar_it10.next()) |ar| {
            if (ar.handle == handle) {
                ar.wlp_alive = .{ .ctx = notify_ctx, .notify_fn = notify_fn };
                break;
            }
        }
    }

    fn makePubCbs(self: *Self) publisher_mod.ParticipantCbs {
        return .{
            .ctx = self,
            .create_proto_writer = pubCreateProtoWriter,
            .destroy_proto_writer = pubDestroyProtoWriter,
            .register_incompat_qos = pubRegisterWriterIncompatQos,
            .register_matched_notify = pubRegisterWriterMatchedNotify,
            .announce_writer = pubAnnounceProtoWriter,
            .timer_clock = self.timer_clock,
            .register_timer_notify = pubRegisterWriterTimerNotify,
            .register_liveliness_assert = pubRegisterWriterLivelinessAssert,
            .register_liveliness_query = pubRegisterWriterLivelinessQuery,
        };
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
            .register_get_field_refresh = subRegisterReaderGetFieldRefresh,
            .register_wlp_alive_notify = subRegisterReaderWlpAliveNotify,
        };
    }

    /// Check all active writer and reader deadline/liveliness timers and fire
    /// notifications for any that have expired.  Call from a timer thread or
    /// directly from tests (with a ManualClock) for deterministic control.
    ///
    /// Collects the callbacks to fire while `self.mu` is held (cheap: just
    /// copying `TimerNotify` pairs out of the map), then releases the lock
    /// *before* actually calling any of them. `cb.check` (DataWriterImpl/
    /// DataReaderImpl's `checkTimersFn`) may notify a user-supplied listener,
    /// and DDS listeners are allowed to call back into the participant --
    /// e.g. `delete_datawriter`/`delete_participant` from inside
    /// `on_offered_deadline_missed` is spec-legal application behavior, and
    /// that call needs `self.mu` too. Firing while still holding it would
    /// deadlock.
    ///
    /// A copied `cb.ctx` is NOT, on its own, safe to dereference later --
    /// `checkTimersFn`'s own internal `self.quiesce.acquire()` can't protect
    /// a pointer that's already dangling before it's even called (see
    /// entity_quiesce.zig's module doc comment; this file previously
    /// (wrongly) assumed it could). So `cb.quiesce_acquire(cb.ctx)` is
    /// called here, still under `self.mu`, at a point where the entity is
    /// provably still live (it's still in the map, so teardown hasn't
    /// removed it yet) -- and the reference is held until after `cb.check`
    /// returns, guaranteeing the entity can't be freed out from under the
    /// call. If acquire fails, teardown is already underway; skip it.
    pub fn checkTimers(self: *Self) void {
        const now_ns = self.timer_clock.nowNs();
        var due: std.ArrayListUnmanaged(TimerNotify) = .empty;
        defer due.deinit(self.alloc);
        // WLP driver input (RTPS §8.7.2.2.3), accumulated in the same
        // active_writers pass below rather than a second lock/iteration.
        var wlp_info = disc.WlpTickInfo{
            .has_automatic = false,
            .min_automatic_lease_ns = 0,
            .has_manual_by_participant = false,
            .min_manual_lease_ns = 0,
            .manual_asserted_since_ns = 0,
        };
        {
            self.mu.lock();
            defer self.mu.unlock();
            var aw_it8 = self.active_writers.valueIterator();
            while (aw_it8.next()) |aw| {
                if (aw.timer_check) |cb| {
                    if (cb.quiesce_acquire(cb.ctx)) {
                        due.append(self.alloc, cb) catch cb.quiesce_release(cb.ctx);
                    }
                }
                const ll = aw.qos.liveliness.lease_duration;
                const lease_active = !(ll.sec == 0 and ll.nanosec == 0) and
                    !(ll.sec == DDS.DURATION_INFINITE_SEC and ll.nanosec == DDS.DURATION_INFINITE_NSEC);
                if (lease_active) {
                    const lease_ns = @as(i64, ll.sec) * std.time.ns_per_s + @as(i64, ll.nanosec);
                    switch (aw.qos.liveliness.kind) {
                        .AUTOMATIC_LIVELINESS_QOS => {
                            if (!wlp_info.has_automatic or lease_ns < wlp_info.min_automatic_lease_ns) {
                                wlp_info.min_automatic_lease_ns = lease_ns;
                            }
                            wlp_info.has_automatic = true;
                        },
                        .MANUAL_BY_PARTICIPANT_LIVELINESS_QOS => {
                            if (!wlp_info.has_manual_by_participant or lease_ns < wlp_info.min_manual_lease_ns) {
                                wlp_info.min_manual_lease_ns = lease_ns;
                            }
                            wlp_info.has_manual_by_participant = true;
                            if (aw.liveliness_query) |lq| {
                                const asserted_ns = lq.last_assert_ns(lq.ctx);
                                if (asserted_ns > wlp_info.manual_asserted_since_ns) {
                                    wlp_info.manual_asserted_since_ns = asserted_ns;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
            var ar_it7 = self.active_readers.valueIterator();
            while (ar_it7.next()) |ar| {
                if (ar.timer_check) |cb| {
                    if (cb.quiesce_acquire(cb.ctx)) {
                        due.append(self.alloc, cb) catch cb.quiesce_release(cb.ctx);
                    }
                }
            }
        }
        self.discovery.wlpTick(now_ns, wlp_info);
        for (due.items) |cb| {
            cb.check(cb.ctx, now_ns);
            cb.quiesce_release(cb.ctx);
        }
    }

    // ── Entity vtable ─────────────────────────────────────────────────────────

    pub const entity_vtable = DDS.Entity.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
    };

    // ── DomainParticipant vtable ──────────────────────────────────────────────

    pub const vtable = DDS.DomainParticipant.Vtable{
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
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
        .as_Entity = vtAsEntity,
    };

    /// One `CAbiViews` value for the whole object, covering all three
    /// interface views it presents (Entity, DomainParticipant, and — via
    /// `extensions.zig`'s `participantGetCAbiHandleZzdds`, which shares this
    /// same `c_abi` field/`views` value — ZZDDS.DomainParticipant too). See
    /// `GuardConditionImpl.views`'s identical-shape doc comment.
    pub const views = ZZDDS.DomainParticipant.CAbiViews{
        .base = .{
            .base = .{ .flat_vtable = &entity_vtable },
            .flat_vtable = &vtable,
        },
        .flat_vtable = &extensions_mod.participant_vtable,
    };

    fn vtGetCAbiHandle(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.c_abi.get(self.alloc, ctx, &views);
    }

    fn vtGetAllocator(ctx: *anyopaque) std.mem.Allocator {
        return cast(ctx).alloc;
    }

    fn vtAsEntity(ctx: *anyopaque) DDS.Entity {
        return .{ .ptr = ctx, .vtable = &entity_vtable };
    }

    fn vtEnable(_: *anyopaque) DDS.ReturnCode_t {
        return DDS.RETCODE_OK;
    }

    fn vtGetStatusCond(ctx: *anyopaque) DDS.StatusCondition {
        const self = cast(ctx);
        if (self.status_cond) |sc| return sc.toDDSStatusCondition();
        return nil.nil_status_condition;
    }

    fn vtGetStatusChanges(ctx: *anyopaque) DDS.StatusMask {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        return self.status_changes;
    }

    fn vtGetHandle(ctx: *anyopaque) DDS.InstanceHandle_t {
        return cast(ctx).instance_handle;
    }

    fn vtCreatePublisher(
        ctx: *anyopaque,
        qos: *const DDS.PublisherQos,
        a_listener: ?*const DDS.PublisherListener,
        mask: DDS.StatusMask,
    ) DDS.Publisher {
        const self = cast(ctx);
        const handle = nextHandle(ctx);
        const p = publisher_mod.PublisherImpl.init(
            self.alloc,
            self.toDDSParticipant(),
            self.makePubCbs(),
            self.config.qos,
            qos.*,
            if (a_listener) |l| l.* else DDS.noop_PublisherListener,
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
        self.mu.lock();
        var found: ?*publisher_mod.PublisherImpl = null;
        for (self.publishers.items) |p| {
            if (p.toDDSPublisher().ptr == a_publisher.ptr) {
                found = p;
                break;
            }
        }
        self.mu.unlock();
        const p = found orelse return DDS.RETCODE_BAD_PARAMETER;
        // PRECONDITION_NOT_MET if any contained writer has outstanding
        // write-loans -- delete_datawriter/delete_contained_entities already
        // check this via checkDeleteContainedPrecondition(); direct
        // delete_publisher previously didn't, letting it destroy a protocol
        // writer a live loan still needed (Greptile PR #69 follow-up finding).
        const precondition = p.checkDeleteContainedPrecondition();
        if (precondition != DDS.RETCODE_OK) return precondition;
        self.mu.lock();
        for (self.publishers.items, 0..) |pp, i| {
            if (pp == p) {
                _ = self.publishers.swapRemove(i);
                break;
            }
        }
        self.mu.unlock();
        // Deinit outside lock: publisher.deinit() calls destroy_proto_writer which locks mu.
        p.deinit();
        return DDS.RETCODE_OK;
    }

    fn vtCreateSubscriber(
        ctx: *anyopaque,
        qos: *const DDS.SubscriberQos,
        a_listener: ?*const DDS.SubscriberListener,
        mask: DDS.StatusMask,
    ) DDS.Subscriber {
        const self = cast(ctx);
        const handle = nextHandle(ctx);
        const s = subscriber_mod.SubscriberImpl.init(
            self.alloc,
            self.toDDSParticipant(),
            self.makeSubCbs(),
            self.config.qos,
            qos.*,
            if (a_listener) |l| l.* else DDS.noop_SubscriberListener,
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
        self.mu.lock();
        var found: ?*subscriber_mod.SubscriberImpl = null;
        for (self.subscribers.items) |s| {
            if (s.toDDSSubscriber().ptr == a_subscriber.ptr) {
                found = s;
                break;
            }
        }
        self.mu.unlock();
        const s = found orelse return DDS.RETCODE_BAD_PARAMETER;
        // See vtDeletePublisher's identical guard -- same finding, read side.
        const precondition = s.checkDeleteContainedPrecondition();
        if (precondition != DDS.RETCODE_OK) return precondition;
        self.mu.lock();
        for (self.subscribers.items, 0..) |ss, i| {
            if (ss == s) {
                _ = self.subscribers.swapRemove(i);
                break;
            }
        }
        self.mu.unlock();
        // Deinit outside lock: subscriber.deinit() calls destroy_proto_reader which locks mu.
        s.deinit();
        return DDS.RETCODE_OK;
    }

    fn vtGetBuiltinSubscriber(ctx: *anyopaque) DDS.Subscriber {
        const self = cast(ctx);
        if (self.builtin_sub) |bs| return bs.sub.toDDSSubscriber();
        return nil.nil_subscriber;
    }

    fn vtCreateTopic(
        ctx: *anyopaque,
        topic_name: [*:0]const u8,
        type_name: [*:0]const u8,
        qos: *const DDS.TopicQos,
        a_listener: ?*const DDS.TopicListener,
        mask: DDS.StatusMask,
    ) DDS.Topic {
        const self = cast(ctx);
        const handle = nextHandle(ctx);
        const tn_s = std.mem.span(topic_name);
        const tt_s = std.mem.span(type_name);
        const t = topic_mod.TopicImpl.init(
            self.alloc,
            tn_s,
            tt_s,
            self,
            getDDSParticipant,
            qos.*,
            if (a_listener) |l| l.* else DDS.noop_TopicListener,
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
                if (std.mem.eql(u8, dt.topic_name, tn_s) and
                    std.mem.eql(u8, dt.type_name, tt_s)) break :new_dt;
            }
            const tn = self.alloc.dupe(u8, tn_s) catch break :new_dt;
            const tt = self.alloc.dupe(u8, tt_s) catch {
                self.alloc.free(tn);
                break :new_dt;
            };
            const dt = DiscoveredTopic{
                .topic_name = tn,
                .type_name = tt,
                .handle = topicToHandle(tn_s, tt_s),
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
            .key = topicNameToKey(tn_s),
            .name = tn_s,
            .type_name = tt_s,
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

    fn vtFindTopic(ctx: *anyopaque, topic_name: [*:0]const u8, _: *const DDS.Duration_t) DDS.Topic {
        const self = cast(ctx);
        const tn_s = std.mem.span(topic_name);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.topics.items) |t| {
            if (std.mem.eql(u8, t.topic_name, tn_s)) return t.toDDSTopic();
        }
        return nil.nil_topic;
    }

    fn vtLookupTopicDesc(ctx: *anyopaque, name: [*:0]const u8) DDS.TopicDescription {
        const self = cast(ctx);
        const name_s = std.mem.span(name);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.topics.items) |t| {
            if (std.mem.eql(u8, t.topic_name, name_s)) return t.toTopicDescription();
        }
        return nil.nil_topic_description;
    }

    fn vtCreateCFTopic(
        ctx: *anyopaque,
        name: [*:0]const u8,
        related_topic: DDS.Topic,
        filter_expression: [*:0]const u8,
        expression_parameters: ?*const DDS.StringSeq,
    ) DDS.ContentFilteredTopic {
        const self = cast(ctx);
        const name_s = std.mem.span(name);
        const filter_s = std.mem.span(filter_expression);
        const empty_seq = DDS.StringSeq{};
        const cft = topic_mod.ContentFilteredTopicImpl.init(
            self.alloc,
            name_s,
            related_topic,
            filter_s,
            if (expression_parameters) |p| p.* else empty_seq,
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
        _: [*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        _: ?*const DDS.StringSeq,
    ) DDS.MultiTopic {
        return nil.nil_multitopic;
    }

    fn vtDeleteMultiTopic(_: *anyopaque, _: DDS.MultiTopic) DDS.ReturnCode_t {
        return DDS.RETCODE_UNSUPPORTED;
    }

    fn vtDeleteContained(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        // Spec §2.2.2.2.1.18: PRECONDITION_NOT_MET propagates up from any
        // contained entity's own outstanding preconditions -- check every
        // subscriber (read-loans) and publisher (write-loans) before
        // touching anything. Topics have no loan-related precondition, so
        // that branch needs no check.
        self.mu.lock();
        for (self.subscribers.items) |s| {
            const precondition = s.checkDeleteContainedPrecondition();
            if (precondition != DDS.RETCODE_OK) {
                self.mu.unlock();
                return precondition;
            }
        }
        for (self.publishers.items) |p| {
            const precondition = p.checkDeleteContainedPrecondition();
            if (precondition != DDS.RETCODE_OK) {
                self.mu.unlock();
                return precondition;
            }
        }
        self.mu.unlock();
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

    fn vtSetQos(ctx: *anyopaque, qos: *const DDS.DomainParticipantQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.qos.deinit(self.alloc);
        self.qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetQos(ctx: *anyopaque, qos: *DDS.DomainParticipantQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        qos.* = self.qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtSetListener(
        ctx: *anyopaque,
        a_listener: ?*const DDS.DomainParticipantListener,
        mask: DDS.StatusMask,
    ) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.swapListener(if (a_listener) |l| l.* else DDS.noop_DomainParticipantListener);
        self.listener_mask = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.DomainParticipantListener {
        const self = cast(ctx);
        self.listener_mu.lock();
        defer self.listener_mu.unlock();
        return self.listener_box.listener;
    }

    /// Installs `new_listener`, releasing whatever it replaces. Safe against
    /// a concurrently in-flight dispatch acquired via `acquireListener`
    /// (see listener_box.zig).
    fn swapListener(self: *Self, new_listener: DDS.DomainParticipantListener) void {
        const new_box = ListenerBox(DDS.DomainParticipantListener).create(self.alloc, new_listener) catch
            @panic("zzdds: out of memory boxing listener");
        self.listener_mu.lock();
        const old_box = self.listener_box;
        self.listener_box = new_box;
        self.listener_mu.unlock();
        old_box.releaseRef(self.alloc);
    }

    /// Call with no lock held. Returns a box the caller may safely read/
    /// dispatch through with no lock held; must call `releaseRef` on it
    /// when done (see listener_box.zig). `pub`: also used by
    /// `subscriber.zig`/`publisher.zig`'s DDS 1.4 §2.2.4.1.5 "nearest
    /// enclosing non-null listener" fallback — the DomainParticipant is
    /// always the terminal link in that chain.
    pub fn acquireListener(self: *Self) *ListenerBox(DDS.DomainParticipantListener) {
        self.listener_mu.lock();
        defer self.listener_mu.unlock();
        return self.listener_box.acquireLocked();
    }

    /// Terminal link in the DDS 1.4 §2.2.4.1.5 "nearest enclosing non-null
    /// listener" fallback chain for both a Subscriber's contained
    /// DataReaders and a Publisher's contained DataWriters — the
    /// DomainParticipant's own `DomainParticipantListener` (widened over
    /// `TopicListener`/`PublisherListener`/`SubscriberListener` in
    /// `dcps.idl`) shares one box/mask for every status kind, so one
    /// function serves both chains. `handle` is always the entity whose
    /// status actually changed (the originating DataReader/DataWriter),
    /// never `self` — matches the spec's own framing: a "more specific"
    /// listener's absence doesn't change which entity the callback reports.
    /// If this level has no usable listener for `field` either, the event
    /// is simply not delivered (matches this codebase's pre-existing
    /// behavior for "nobody installed a listener for this status" at the
    /// origin entity) and `false` is returned so the caller knows not to
    /// reset its own change-counters (see `dispatchListener`'s doc comment
    /// in `reader.zig`/`writer.zig` for why that matters).
    pub fn dispatchFallback(self: *Self, comptime field: []const u8, bit: DDS.StatusMask, handle: anytype, args: anytype) bool {
        const box = self.acquireListener();
        defer box.releaseRef(self.alloc);
        return listener_fallback.tryDispatch(field, self.listener_mask, bit, box.listener, handle, args);
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

    fn vtSetDefaultPubQos(ctx: *anyopaque, qos: *const DDS.PublisherQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.default_pub_qos.deinit(self.alloc);
        self.default_pub_qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultPubQos(ctx: *anyopaque, qos: *DDS.PublisherQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        qos.* = self.default_pub_qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtSetDefaultSubQos(ctx: *anyopaque, qos: *const DDS.SubscriberQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.default_sub_qos.deinit(self.alloc);
        self.default_sub_qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultSubQos(ctx: *anyopaque, qos: *DDS.SubscriberQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        qos.* = self.default_sub_qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtSetDefaultTopicQos(ctx: *anyopaque, qos: *const DDS.TopicQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.default_topic_qos.deinit(self.alloc);
        self.default_topic_qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultTopicQos(ctx: *anyopaque, qos: *DDS.TopicQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        qos.* = self.default_topic_qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtGetDiscoveredParticipants(
        ctx: *anyopaque,
        handles: ?*DDS.InstanceHandleSeq,
    ) DDS.ReturnCode_t {
        const seq = handles orelse return DDS.RETCODE_BAD_PARAMETER;
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        if (seq._release) {
            if (seq._buffer) |ob| self.alloc.free(ob[0..seq._maximum]);
        }
        seq.* = .{};
        const n = self.discovered_participants.items.len;
        if (n == 0) return DDS.RETCODE_OK;
        const buf = self.alloc.alloc(DDS.InstanceHandle_t, n) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        for (self.discovered_participants.items, 0..) |e, i| buf[i] = e.handle;
        seq._buffer = buf.ptr;
        seq._length = @intCast(n);
        seq._maximum = @intCast(n);
        seq._release = true;
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
        handles: ?*DDS.InstanceHandleSeq,
    ) DDS.ReturnCode_t {
        const seq = handles orelse return DDS.RETCODE_BAD_PARAMETER;
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        if (seq._release) {
            if (seq._buffer) |ob| self.alloc.free(ob[0..seq._maximum]);
        }
        seq.* = .{};
        const n = self.discovered_topics.items.len;
        if (n == 0) return DDS.RETCODE_OK;
        const buf = self.alloc.alloc(DDS.InstanceHandle_t, n) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        for (self.discovered_topics.items, 0..) |dt, i| buf[i] = dt.handle;
        seq._buffer = buf.ptr;
        seq._length = @intCast(n);
        seq._maximum = @intCast(n);
        seq._release = true;
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
            // name/type_name must be duped into fresh, caller-owned storage here,
            // not aliased to dt.topic_name/dt.type_name directly: the C-ABI export
            // of this call (DDS_DomainParticipant_get_discovered_topic_data) always
            // frees whatever ends up in *data via std.heap.c_allocator (both the
            // generated wrapper's own cleanup and TopicBuiltinTopicData_free on the
            // caller side), and callers -- including this vtable's own pure-Zig
            // callers, see zig/discovery -- deinit() the result the same way. If
            // these fields aliased the DiscoveredTopic entry's storage instead,
            // that free would double-free memory the participant's own
            // discovered_topics list still owns and frees again at teardown.
            // Always c_allocator, decoupling this from self.alloc, matching
            // factoryGetDefaultParticipantConfig's identical reasoning.
            //
            // Duped into locals first, not directly into the struct literal
            // below: a struct literal only commits once every field has been
            // evaluated, so if the type_name dupe failed after the name dupe
            // already succeeded, returning from inside the literal would both
            // leak that first allocation and leave *data's old (about-to-be
            // freed) content undisturbed but never actually freed. Freeing
            // *data's prior content is deferred until both dupes have
            // succeeded, for the same reason: an early OOM return must leave
            // *data exactly as the caller last saw it, not half-freed.
            const name = std.heap.c_allocator.dupe(u8, dt.topic_name) catch return DDS.RETCODE_OUT_OF_RESOURCES;
            const type_name = std.heap.c_allocator.dupe(u8, dt.type_name) catch {
                std.heap.c_allocator.free(name);
                return DDS.RETCODE_OUT_OF_RESOURCES;
            };
            data.deinit(std.heap.c_allocator);
            data.* = .{
                .key = topicNameToKey(dt.topic_name),
                .name = name,
                .type_name = type_name,
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
        const self = cast(entity_ptr);
        self.mu.lock();
        defer self.mu.unlock();
        return self.status_changes;
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};
