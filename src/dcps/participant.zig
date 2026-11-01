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
const unmatched_mod = @import("../rtps/unmatched_cache.zig");
const disc = @import("../discovery/interface.zig");
const transport_if = @import("../transport/interface.zig");
const IngressBudget = @import("../transport/ingress_budget.zig").IngressBudget;
const TcpTransport = @import("../transport/tcp.zig").TcpTransport;
const security_if = @import("../security/interface.zig");
const parser_mod = @import("../rtps/message/parser.zig");
const submsg_mod = @import("../rtps/message/submessage.zig");
const time_mod = @import("../util/time.zig");
const header_mod = @import("../rtps/message/header.zig");
const build_opts = @import("build_options");
const qm_mod = @import("qos_match.zig");
const disc_adapter = @import("../discovery/qos_adapter.zig");
const reader_mod = @import("reader.zig");
const writer_mod = @import("writer.zig");
const runtime_mod = @import("../runtime/core.zig");
const CloseLatch = @import("../runtime/close_latch.zig").CloseLatch;
const listener_lane = @import("listener_lane.zig");
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
        fn f(_: *anyopaque, _: *const proto.MatchedWriterInfo) anyerror!bool {
            return false;
        }
    }.f,
    .remove_matched_writer = struct {
        fn f(_: *anyopaque, _: proto.Guid) void {}
    }.f,
    .remove_matched_writer_deferred = struct {
        fn f(_: *anyopaque, _: proto.Guid) proto.DeferredUnmatchCallbacks {
            return .{};
        }
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
        fn f(_: *anyopaque, _: proto.Guid, _: proto.SequenceNumber, _: proto.RtpsTimestamp, _: [16]u8, _: []const u8, _: proto.ChangeKind, _: ?proto.SequenceNumber, _: ?proto.SequenceNumber, _: ?proto.SequenceNumber, _: ?i64) void {}
    }.f,
    .handle_heartbeat = struct {
        fn f(_: *anyopaque, _: proto.Guid, _: proto.EntityId, _: proto.SequenceNumber, _: proto.SequenceNumber, _: i32, _: bool, _: bool) void {}
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
    .set_protocol_ready_callback = struct {
        fn f(_: *anyopaque, _: proto.ProtocolReadyCallback) void {}
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
            .is_participant_enabled = DomainParticipantImpl.participantIsEnabledCb,
            .create_proto_reader = struct {
                fn f(_: *anyopaque, _: []const u8, _: []const u8, _: DDS.DataReaderQos, _: DDS.PresentationQosPolicy, handle: *DDS.InstanceHandle_t, guid: *Guid) anyerror!proto.ProtocolReader {
                    handle.* = DDS.HANDLE_NIL;
                    guid.* = std.mem.zeroes(Guid);
                    return noopProtocolReader();
                }
            }.f,
            .destroy_proto_reader = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t) void {}
            }.f,
            .register_incompat_qos = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, i32) void) void {}
            }.f,
            .register_matched_notify = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, DDS.InstanceHandle_t, bool) void) void {}
            }.f,
            .prepare_readers = struct {
                fn f(_: *anyopaque, _: []const DDS.InstanceHandle_t, _: []const []const u8, _: DDS.PresentationQosPolicy) anyerror!void {}
            }.f,
            .prepare_reader_qos = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: *const DDS.DataReaderQos) anyerror!void {}
            }.f,
            .announce_reader = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t) void {}
            }.f,
            .timer_clock = participant.timer_clock,
            .register_timer_notify = struct {
                fn f(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, i64) void, _: *const fn (*anyopaque) ?i64, _: *const fn (*anyopaque) bool, _: *const fn (*anyopaque) void) void {}
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
            reader_mod.listenerExFromBase(nil.nil_dr_listener),
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
            std.mem.zeroes(Guid),
            participant.timer_clock,
            .{},
        );
        n_ok = 1;
        readers[1] = try reader_mod.DataReaderImpl.init(
            alloc,
            self.topic_desc.toTopicDescription(),
            sub_dds,
            noopProtocolReader(),
            .{},
            reader_mod.listenerExFromBase(nil.nil_dr_listener),
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
            std.mem.zeroes(Guid),
            participant.timer_clock,
            .{},
        );
        n_ok = 2;
        readers[2] = try reader_mod.DataReaderImpl.init(
            alloc,
            self.pub_desc.toTopicDescription(),
            sub_dds,
            noopProtocolReader(),
            .{},
            reader_mod.listenerExFromBase(nil.nil_dr_listener),
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
            std.mem.zeroes(Guid),
            participant.timer_clock,
            .{},
        );
        n_ok = 3;
        readers[3] = try reader_mod.DataReaderImpl.init(
            alloc,
            self.sub_desc.toTopicDescription(),
            sub_dds,
            noopProtocolReader(),
            .{},
            reader_mod.listenerExFromBase(nil.nil_dr_listener),
            0,
            DomainParticipantImpl.nextHandle(@ptrCast(participant)),
            std.mem.zeroes(Guid),
            participant.timer_clock,
            .{},
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

    /// Runs the builtin readers' listeners in `group`, like any other
    /// reader's. Call before the participant starts.
    fn attachGroup(self: *@This(), group: *listener_lane.Group) void {
        for ([_]*reader_mod.DataReaderImpl{ self.part_dr, self.topic_dr, self.pub_dr, self.sub_dr }) |r| r.listeners.attach(group);
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
    return .{ .kind = @fromBackingInt(@intCast(kind)) };
}
fn qosLiveliness(kind: u8) DDS.LivelinessQosPolicy {
    return .{ .kind = @fromBackingInt(@intCast(kind)) };
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
        .reliability = qosReliability(disc.discReliabilityKind(data.qos)),
        .durability = qosDurability(disc.discDurabilityKind(data.qos)),
        .liveliness = qosLiveliness(disc.discLivelinessKind(data.qos)),
        .ownership = qosOwnership(disc.discOwnershipKind(data.qos)),
        .destination_order = qosDestOrder(disc.discDestOrderKind(data.qos)),
        .user_data = .{ .value = blk: {
            const _ud = disc.discUserData(data.qos);
            break :blk .{
                ._maximum = @intCast(_ud.len),
                ._length = @intCast(_ud.len),
                ._buffer = @constCast(_ud.ptr),
                ._release = false,
            };
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
        .reliability = qosReliability(disc.discReliabilityKind(data.qos)),
        .durability = qosDurability(disc.discDurabilityKind(data.qos)),
        .liveliness = qosLiveliness(disc.discLivelinessKind(data.qos)),
        .ownership = qosOwnership(disc.discOwnershipKind(data.qos)),
        .destination_order = qosDestOrder(disc.discDestOrderKind(data.qos)),
        .user_data = .{ .value = blk: {
            const _ud = disc.discUserData(data.qos);
            break :blk .{
                ._maximum = @intCast(_ud.len),
                ._length = @intCast(_ud.len),
                ._buffer = @constCast(_ud.ptr),
                ._release = false,
            };
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

/// Incompatible-QoS notifications for one local endpoint, recorded under
/// participant.mu and raised after it is released by
/// DomainParticipantImpl.raiseIncompatQos: they reach
/// on_requested/offered_incompatible_qos, application code. Kept on the
/// endpoint's own ActiveReader/ActiveWriter entry, so recording one needs no
/// memory and cannot fail. Each recorded incompatibility is raised once, with
/// its own policy, and the most recently recorded policy is raised last, so the
/// status read afterwards reports it as last_policy_id.
///
/// Counted per policy, over only the policies a compatibility check can fail
/// on (qos_match.IncompatiblePolicy), which keeps this small: it sits in every
/// ActiveReader/ActiveWriter, and the first allocation of those maps must fit
/// a 4 KiB block (see the size test at the end of this file). A count cannot
/// overflow: one discovery event records at most one incompatibility per
/// discovered remote endpoint.
const IncompatQosPending = struct {
    const Policy = qm_mod.IncompatiblePolicy;
    const policies = std.enums.values(Policy);

    counts: [policies.len]u32 = @splat(0),
    last: ?u8 = null,

    fn any(self: *const IncompatQosPending) bool {
        return self.last != null;
    }

    fn record(self: *IncompatQosPending, policy: Policy) void {
        const i: u8 = @intCast(std.mem.indexOfScalar(Policy, policies, policy).?);
        self.counts[i] += 1;
        self.last = i;
    }

    /// Calls `notify(ctx, policy_id)` once per recorded incompatibility, the
    /// most recently recorded policy last.
    fn raise(self: *const IncompatQosPending, n: IncompatQosNotify) void {
        const last = self.last orelse return;
        for (self.counts, policies, 0..) |count, policy, i| {
            if (i == last) continue;
            for (0..count) |_| n.notify(n.ctx, @intCast(@backingInt(policy)));
        }
        for (0..self.counts[last]) |_| n.notify(n.ctx, @intCast(@backingInt(policies[last])));
    }
};

/// Callback registered by DataWriterImpl / DataReaderImpl so that the participant
/// can fire on_publication_matched / on_subscription_matched when a remote entity
/// matches or unmatches.  `added` is true on match, false on unmatch.
const MatchedNotify = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque, remote_handle: DDS.InstanceHandle_t, added: bool) void,
    /// `ctx` is a `*DataReaderImpl` when true, a `*DataWriterImpl` when false —
    /// needed to reach the right `EntityQuiesce` from `onReaderDiscovered` /
    /// `onWriterDiscovered`, which release `participant.mu` before firing
    /// `notify` and so must pin the target entity themselves (a raw `ctx` is
    /// otherwise free to dangle in that window — see `entity_quiesce.zig`).
    is_reader: bool,

    /// Call while holding `participant.mu` (so `ctx` is provably still live);
    /// hold the reference until after `notify` returns, then `quiesceRelease`.
    /// False = the target entity is tearing down; skip the notify entirely.
    fn quiesceAcquire(self: MatchedNotify) bool {
        return if (self.is_reader)
            reader_mod.DataReaderImpl.quiesceAcquireFn(self.ctx)
        else
            writer_mod.DataWriterImpl.quiesceAcquireFn(self.ctx);
    }
    fn quiesceRelease(self: MatchedNotify) void {
        if (self.is_reader)
            reader_mod.DataReaderImpl.quiesceReleaseFn(self.ctx)
        else
            writer_mod.DataWriterImpl.quiesceReleaseFn(self.ctx);
    }
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
    /// The earliest time `check` has anything to do, or null.
    next_due: *const fn (ctx: *anyopaque) ?i64,
    quiesce_acquire: *const fn (ctx: *anyopaque) bool,
    quiesce_release: *const fn (ctx: *anyopaque) void,
};

/// The earlier of two times, either of which may be never (null).
fn earlier(a: ?i64, b: ?i64) ?i64 {
    const x = a orelse return b;
    const y = b orelse return x;
    return @min(x, y);
}

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
    /// Its lease duration, from its latest SPDP announcement.
    lease_ms: u32,
};

/// Bounds on the data the participant holds, for every local reader, from
/// writers no local reader has matched yet (see rtps/unmatched_cache.zig).
const UNMATCHED_LIMITS = unmatched_mod.Limits{
    .max_bytes = 16 * 1024 * 1024,
    .max_writers = 256,
    .max_samples_per_writer = 64,
    .max_partials_per_writer = 8,
};

/// The longest data from a writer discovery has not announced is held (see
/// unmatchedTtlNsLocked).
const UNMATCHED_MAX_TTL_NS: i64 = 300 * std.time.ns_per_s;

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
    /// Deep-cloned decoded wire QoS (retains unknown PIDs). Owned; freed with
    /// its generated `deinit`.
    qos: disc.DiscoveredWriterData,
    /// PARTITION names, owned copies (`dupePartitionNames`). `qos.partition`
    /// also holds them but as `[*:0]` pointers into the clone; this flat view
    /// is what `qm_mod.checkPartition` wants.
    partition_names: []const []const u8, // owned
    unicast_locators: []const Locator, // owned
    multicast_locators: []const Locator, // owned

    fn deinit(self: *DiscoveredWriter, alloc: std.mem.Allocator) void {
        alloc.free(self.topic_name);
        alloc.free(self.type_name);
        DomainParticipantImpl.freePartitionNames(alloc, self.partition_names);
        self.qos.deinit(alloc);
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
    qos: disc.DiscoveredReaderData, // owned (generated deinit)
    partition_names: []const []const u8, // owned
    unicast_locators: []const Locator, // owned
    multicast_locators: []const Locator, // owned

    fn deinit(self: *DiscoveredReader, alloc: std.mem.Allocator) void {
        alloc.free(self.topic_name);
        alloc.free(self.type_name);
        DomainParticipantImpl.freePartitionNames(alloc, self.partition_names);
        self.qos.deinit(alloc);
        alloc.free(self.unicast_locators);
        alloc.free(self.multicast_locators);
    }
};

/// Callback table registered per type name via registerTypeSupport().
/// Used to compute key hashes from CDR payloads when a received change
/// carries no inline-QoS key_hash.  Keyed types should register this to
/// enable per-instance OWNERSHIP, TIME_BASED_FILTER, and SampleInfo tracking.
pub const TypeSupport = struct {
    /// Optional immutable wire-library registration. Provider code is pinned until
    /// after every endpoint and its pending protocol work have been destroyed.
    provider_generation: u64 = 0,
    minimal_identifier: [15]u8 = @splat(0),
    sample_processor: ?@import("../rtps/reader_sm.zig").SampleProcessor = null,
    /// Opaque context passed as the first argument to all function pointers.
    /// Follows the same convention as Transport and Security plugin vtables.
    /// Zig-native implementations that need no state may pass `undefined`.
    ctx: *anyopaque,
    /// Compute the 16-byte DDS key hash from a **complete ALIVE sample's**
    /// CDR-encoded payload. `payload` includes the 4-byte encapsulation
    /// header (as received from the wire). Return `zeroes([16]u8)` for
    /// keyless types. See `resolveKeyHash`: this is the fallback used when a
    /// received ALIVE change carries no inline `PID_KEY_HASH`.
    compute_key_hash: *const fn (ctx: *anyopaque, payload: []const u8) [16]u8,
    /// Compute the 16-byte DDS key hash from a **genuine key-only** payload
    /// (RTPS DISPOSE/UNREGISTER: nothing but the `@key` members, back to
    /// back — not a full sample). Optional: `resolveKeyHash` falls back to
    /// `zeroes([16]u8)` rather than misapplying `compute_key_hash` (which
    /// expects a full sample and would misread a key-only one) when a
    /// registration leaves this unset — see zidl's
    /// `computeKeyHashFromCdrKeyOnly`/`_compute_key_hash_from_cdr_key_only`.
    /// Wired end to end: the native Zig path (a caller passes this field
    /// directly) and the C-ABI surface the C/C++/Java bindings register
    /// through (`zzdds_register_type_support`/`_ctx`'s
    /// `compute_key_hash_key_only_fn` parameter, `c_abi/typesupport.zig`).
    compute_key_hash_key_only: ?*const fn (ctx: *anyopaque, payload: []const u8) [16]u8 = null,
    /// True when the type has one or more `@key` members. Native registrations
    /// should use the generated type's `has_key` constant. Pinned providers use it
    /// for endpoint kinds; legacy registrations retain their previous wire kinds.
    /// A keyed writer emits inline `PID_KEY_HASH` on
    /// every sample (RTPS §8.7.9), including a zero-valued key — otherwise a
    /// subscriber would have to reconstruct the per-instance hash from the
    /// payload (see `resolveKeyHash`). Must be registered before the writer is
    /// created to take effect, same ordering constraint as `key_hash_fn` on
    /// readers. Defaults false; keyless types may leave it unset.
    has_key: bool = false,
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
    /// Discovery holds an announcement prepared with `qos`,
    /// `partition_names` and `presentation`.
    prepared: bool = false,
    /// Its announcement was committed: another is a refresh.
    announced: bool = false,
    incompat_qos: ?IncompatQosNotify = null,
    incompat_pending: IncompatQosPending = .{},
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
    /// Discovery holds an announcement prepared with `qos`,
    /// `partition_names` and `presentation`.
    prepared: bool = false,
    /// Its announcement was committed: another is a refresh.
    announced: bool = false,
    incompat_qos: ?IncompatQosNotify = null,
    incompat_pending: IncompatQosPending = .{},
    matched_notify: ?MatchedNotify = null,
    timer_check: ?TimerNotify = null,
    key_hash_ctx: *anyopaque = undefined,
    key_hash_fn: ?*const fn (*anyopaque, []const u8) [16]u8 = null,
    key_hash_only_fn: ?*const fn (*anyopaque, []const u8) [16]u8 = null,
    refresh_get_field: ?RefreshGetField = null,
    wlp_alive: ?WlpAliveNotify = null,
};

const cloneUserData = disc.cloneUserData;
const freeUserData = disc.freeUserData;

// ── DomainParticipantImpl ────────────────────────────────────────────────────

pub const DomainParticipantImpl = struct {
    alloc: std.mem.Allocator,
    domain_id: DDS.DomainId_t,
    guid: Guid,
    qos: DDS.DomainParticipantQos,
    /// Entity::enable() state (ENTITY_FACTORY QoS). Seeded from
    /// `qos.entity_factory.autoenable_created_entities` at construction; set
    /// true by `vtEnable` once `start()` has actually run. Atomic: read from
    /// arbitrary discovery/timer threads via the NOT_ENABLED precondition
    /// helper, written once from the application thread that calls enable().
    enabled: std.atomic.Value(bool),
    listener_box: *ListenerBox(DDS.DomainParticipantListener),
    /// Guards `listener_box` swaps/acquires only — never held across a
    /// dispatch or any other call (see listener_box.zig).
    listener_mu: Mutex = .{},
    /// See `writer.zig`'s matching field: `dispatchFallback` (the bottom
    /// of the s2.2.4.1.5 chain, run from discovery/timer threads) reads it
    /// while an application `set_listener` may write it, so both use
    /// `@atomicLoad`/`@atomicStore` `.monotonic`; initialisers stay plain.
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

    /// Data from writers that discovery has not yet announced and matched
    /// with local readers, held for each reader that then matches one (see
    /// holdIfUnmatchedLocked).  Has its own lock, taken under self.mu or a
    /// reader's.
    unmatched: unmatched_mod.UnmatchedCache,
    /// Writers whose announcement has been matched against every local
    /// reader (see settleWriterLocked), until they are lost: nothing from
    /// them is held.  Guarded by mu.
    settled_writers: std.AutoHashMapUnmanaged(Guid, void) = .empty,

    /// Each known remote endpoint's current discovery generation: a match
    /// decision for it is made only while the generation it carries is
    /// current (docs/design/concurrency/architecture.md#remote-endpoint-match-and-loss).
    /// Each local endpoint prepared has one too, renewed by each change
    /// committed to it (`renewLocalGenLocked`), so a match decided before
    /// the change is not made after it.
    /// Written under mu and discovery_gens_mu; read under either.
    /// discovery_gens_mu is a leaf lock, taken by a local endpoint under its
    /// protocol lock to check a match it is installing (isDiscoveryGenCurrent).
    discovery_gens: std.AutoHashMapUnmanaged(Guid, u64) = .empty,
    discovery_gens_mu: Mutex = .{},
    /// The last generation assigned.  Guarded by mu.
    last_discovery_gen: u64 = 0,

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
    /// `discovery.start()` succeeded: deinit stops it. A plugin serves one
    /// participant at a time, so one that never started must not stop
    /// another's.
    discovery_started: bool = false,

    /// Port on which we listen for user DataWriter traffic.
    /// 0 = not yet chosen (before start()).
    data_listen_port: u16,
    /// The listen on `data_listen_port` succeeded: deinit() unlistens it.
    /// A start() that failed first must not unlisten the port, which may
    /// be another participant's.
    data_listening: bool = false,

    /// Metatraffic port userDataOnReceive was *also* registered on as a
    /// robustness fallback (see start()), if any. 0 = not registered there
    /// (TCP, or meta_port == data_listen_port already). Used by deinit() to
    /// unlisten -- must mirror start()'s registration exactly, or a packet
    /// arriving after teardown calls userDataOnReceive with a freed `self`.
    meta_userdata_listen_port: u16,

    /// Wire tracer applied to all user-plane protocol adapters (zero-size when disabled).
    tracer: trace_mod.Tracer,

    /// Monotonic clock used for internal interval timers (deadline, liveliness).
    /// Resolved from the factory's ClockRegistry at participant creation time.
    timer_clock: time_mod.Clock,

    mu: Mutex,

    /// Serializes preparing local endpoints' announcements, so what discovery
    /// has prepared for an endpoint and the partitions and presentation
    /// recorded for it agree. Held across no call that delivers.
    prepare_mu: Mutex = .{},
    /// Guarded by `mu`: local endpoints whose announcement is being committed
    /// to discovery. Has room for one per local endpoint.
    announcing: std.ArrayListUnmanaged(Announcing) = .empty,

    /// Background thread periodically calling checkTimers() to enforce
    /// DEADLINE and LIVELINESS QoS -- previously nothing called checkTimers()
    /// at all, so those statuses only ever fired under a test's ManualClock.
    /// Spawned once at the end of start(), stopped as the very first step of
    /// deinit() (before anything else is torn down) so it can never observe
    /// partially-destroyed participant state -- same lifetime discipline as
    /// writer_sm.zig's per-writer heartbeat thread and spdp.zig's
    /// per-participant announcement timer (thread lifetime strictly bounded
    /// by the owning object's own init/deinit, never reaching across
    /// objects -- see docs/roadmap.md's "Concurrency model" design-task entry
    /// for why that matters here specifically).
    timer_thread: ?std.Thread = null,
    /// The shared runtime this participant holds an owner reference to, set
    /// by `attachRuntime` before `start` in a `-Dshared-runtime` build and
    /// released last in `deinit`
    /// (docs/design/concurrency/runtime.md#operational-ownership-versus-storage-retention).
    runtime: ?*runtime_mod.Runtime = null,
    /// With a runtime: the context that processes received datagrams, one
    /// at a time (docs/design/concurrency/runtime.md#ingress).
    ingress: runtime_mod.Context = undefined,
    ingress_latch: CloseLatch = .{},
    /// What is queued for ingress and not yet processed, bounded in
    /// aggregate and per peer; stream connections waiting for room wait on
    /// it.
    ingress_budget: IngressBudget = IngressBudget.init(ingress_record_limit, ingress_byte_limit),
    /// Datagrams dropped at ingress: a bound reached, or no memory.
    ingress_drops: std.atomic.Value(u64) = .init(0),
    /// With a runtime: `checkTimers` runs as one timer in this context,
    /// armed for the earliest time anything is due rather than polled by
    /// the timer thread.
    timers: runtime_mod.Context = undefined,
    timers_latch: CloseLatch = .{},
    check_timer: runtime_mod.Timer = undefined,
    /// Set by deinit under `check_mu`; nothing arms `check_timer` after.
    check_mu: Mutex = .{},
    check_stopping: bool = false,
    /// With a runtime: the contexts where this participant's readers and
    /// writers run their listeners, apart from the work that changed their
    /// statuses (listener_lane.zig).
    listener_group: listener_lane.Group = undefined,
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
    /// zidl/docs/design/binding-c-abi-identity.md.
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
            // Overridden by the factory right after this returns, from
            // self.factory_qos.entity_factory -- the true "parent" QoS for a
            // participant's own enable() state (see factory.zig's
            // createParticipantWithConfigOwned). `qos` here is the QoS being
            // applied TO this new participant, not the factory's own.
            .enabled = .init(true),
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
            .unmatched = unmatched_mod.UnmatchedCache.init(alloc, UNMATCHED_LIMITS),
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
            .meta_userdata_listen_port = 0,
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

    /// Bounds on the datagrams queued for ingress and not yet processed, by
    /// count and by bytes, in aggregate and, past half of either, per peer
    /// (IngressBudget). Past them a datagram is dropped, as a full socket
    /// receive buffer drops it, and a stream connection stops reading
    /// until there is room (docs/design/concurrency/runtime.md#ingress).
    /// Placeholders until measured and made configurable.
    pub const ingress_pending_limit: u32 = 256;
    pub const ingress_byte_limit: usize = 4 * 1024 * 1024;
    /// One under the context's limit: the context still counts the datagram
    /// its turn is processing once the budget has released it.
    pub const ingress_record_limit: u32 = ingress_pending_limit - 1;

    /// Puts the participant on `rt`, whose owner reference the caller has
    /// taken for it. Call once, before `start`.
    pub fn attachRuntime(self: *Self, rt: *runtime_mod.Runtime) void {
        self.runtime = rt;
        self.ingress = runtime_mod.Context.init(rt, ingress_pending_limit);
        self.ingress.on_closed = self.ingress_latch.hook();
        // Only timer fires run here, with internal credit.
        self.timers = runtime_mod.Context.init(rt, 0);
        self.timers.on_closed = self.timers_latch.hook();
        self.check_timer = runtime_mod.Timer.init(&self.timers, onCheckTimer);
        self.listener_group = listener_lane.Group.init(rt);
        // The builtin readers were made before the runtime was known.
        if (self.builtin_sub) |bs| bs.attachGroup(&self.listener_group);
    }

    fn listenerGroup(self: *Self) ?*listener_lane.Group {
        return if (self.runtime != null) &self.listener_group else null;
    }

    fn userDataHandler(self: *Self) transport_if.ReceiveHandler {
        return .{
            .ctx = self,
            .on_receive = if (self.runtime != null) ingressOnReceive else userDataOnReceive,
            .try_receive = if (self.runtime != null) ingressTryReceive else null,
            .notify_room = if (self.runtime != null) notifyRoom else null,
            .cancel_room = if (self.runtime != null) cancelRoom else null,
        };
    }

    /// A received datagram, copied and queued for the ingress context.
    const Ingress = struct {
        req: runtime_mod.Request = runtime_mod.Request.init(run),
        alloc: std.mem.Allocator,
        participant: *Self,
        src: Locator,
        data: []u8,
        admission: IngressBudget.Admission,

        fn of(req: *runtime_mod.Request) *Ingress {
            return @fieldParentPtr("req", req);
        }

        fn run(req: *runtime_mod.Request, _: *runtime_mod.Turn) runtime_mod.Outcome {
            const item = of(req);
            const p = item.participant;
            userDataOnReceive(p, item.data, item.src, transport_if.Channel.none);
            // Accounted while the participant is certainly alive; the buffer
            // itself is freed by `destroy` after the turn.
            p.ingress_budget.release(item.admission);
            return .done;
        }

        /// Does not touch the participant, which may already be gone.
        fn destroy(req: *runtime_mod.Request) void {
            const item = of(req);
            item.alloc.free(item.data);
            item.alloc.destroy(item);
        }

        /// Drops a datagram that was queued and never processed.
        fn discard(req: *runtime_mod.Request) void {
            const item = of(req);
            item.participant.ingress_budget.release(item.admission);
            destroy(req);
        }
    };

    /// Queues a copy of `raw` for the ingress context. Never processes it on
    /// the sender's stack: an in-process sender may hold its writer's lock.
    fn ingressOnReceive(ctx: *anyopaque, raw: []const u8, src: Locator, _: transport_if.Channel) void {
        const self = cast(ctx);
        const adm = self.ingress_budget.admit(IngressBudget.peerKey(raw, src), raw.len) orelse {
            _ = self.ingress_drops.fetchAdd(1, .monotonic);
            return;
        };
        self.queueIngress(raw, src, adm);
    }

    /// As `ingressOnReceive`, for a stream connection: returns false,
    /// keeping nothing, when ingress has no room for `raw`, rather than
    /// dropping it, so the connection holds it and stops reading.
    fn ingressTryReceive(ctx: *anyopaque, raw: []const u8, src: Locator, _: transport_if.Channel) bool {
        const self = cast(ctx);
        if (raw.len > self.ingress_budget.maxPeerBytes()) {
            // Never fits: dropped, as an oversized datagram would be.
            _ = self.ingress_drops.fetchAdd(1, .monotonic);
            return true;
        }
        const adm = self.ingress_budget.admit(IngressBudget.peerKey(raw, src), raw.len) orelse return false;
        self.queueIngress(raw, src, adm);
        return true;
    }

    fn notifyRoom(ctx: *anyopaque, waiter: *transport_if.RoomWaiter, raw: []const u8, src: Locator) void {
        const self = cast(ctx);
        waiter.len = raw.len;
        waiter.key = IngressBudget.peerKey(raw, src);
        self.ingress_budget.notifyRoom(waiter);
    }

    fn cancelRoom(ctx: *anyopaque, waiter: *transport_if.RoomWaiter) void {
        cast(ctx).ingress_budget.cancelRoom(waiter);
    }

    /// Queues a copy of `raw`, for which `adm` took room.
    fn queueIngress(self: *Self, raw: []const u8, src: Locator, adm: IngressBudget.Admission) void {
        const item = self.alloc.create(Ingress) catch return self.dropIngress(adm);
        const data = self.alloc.dupe(u8, raw) catch {
            self.alloc.destroy(item);
            return self.dropIngress(adm);
        };
        item.* = .{ .alloc = self.alloc, .participant = self, .src = src, .data = data, .admission = adm };
        item.req.on_done = Ingress.destroy;
        self.runtime.?.submit(null, &self.ingress, &item.req) catch {
            Ingress.discard(&item.req);
            _ = self.ingress_drops.fetchAdd(1, .monotonic);
        };
    }

    fn dropIngress(self: *Self, adm: IngressBudget.Admission) void {
        self.ingress_budget.release(adm);
        _ = self.ingress_drops.fetchAdd(1, .monotonic);
    }

    fn finishDestroyHook(ctx: *anyopaque) void {
        cast(ctx).finishDestroy();
    }

    /// The last of `deinit`: releases the runtime and frees the participant.
    fn finishDestroy(self: *Self) void {
        const alloc = self.alloc;
        if (self.runtime) |rt| {
            self.ingress.deinit();
            self.timers.deinit();
            self.listener_group.deinit();
            rt.releaseOwner();
        }
        self.ingress_budget.deinit();
        alloc.destroy(self);
    }

    /// Start discovery. Call after init(). The discovery plugin begins
    /// announcing the participant and delivering remote-endpoint callbacks.
    /// A failure leaves nothing started, so `enable` can call it again.
    pub fn start(self: *Self) !void {
        errdefer {
            self.stopReceiving();
            self.data_listen_port = 0;
        }
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
            // On a runtime, frames go through ingress as datagrams do.
            try self.transport.listen(&ephemeral, self.userDataHandler());
            self.data_listening = true;
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
        self.discovery_started = true;

        // Listen on the data unicast port for user DataWriter traffic. When TCP
        // user-data is enabled this already happened above (binding was needed
        // early, to learn the real address/port before announcing it).
        if (!self.config.transport.tcp.enabled and self.data_listen_port != 0) {
            const listen_loc = Locator.udp4(.{ 0, 0, 0, 0 }, self.data_listen_port);
            try self.transport.listen(&listen_loc, self.userDataHandler());
            self.data_listening = true;
        }

        // Also register userDataOnReceive on the metatraffic unicast port,
        // when it's a genuinely different port from the data-listen port
        // above (skip for TCP -- no shared-port concept there, and no
        // meta_locators to derive a port from).
        //
        // RTPS §8.5.4 gives a writer/reader with no explicit SEDP locator a
        // participant-level fallback: metatraffic_unicast_locator_list for
        // builtin SPDP/SEDP endpoints, default_unicast_locator_list for
        // everything else. zzdds advertises these correctly as distinct
        // locators (confirmed on the wire), but at least one real peer
        // (hdds, confirmed from its own source: resolve_metatraffic_dest in
        // dds/reader/heartbeat.rs) sends ACKNACK/HEARTBEAT/GAP for *any*
        // writer/reader -- builtin or not -- to metatraffic_unicast_locator
        // unconditionally. SEDP's onReceive (src/discovery/sedp.zig) only
        // recognizes builtin SPDP/SEDP/WLP entities, so without this,
        // protocol traffic for a user writer/reader that lands here is
        // silently dropped and reliable delivery stalls forever.
        //
        // This is deliberately a second transport-level listener, not a
        // callback threaded through SEDP: vtListen already supports two
        // listen() calls sharing one PortEntry via addHandler (see its own
        // doc comment) -- the same mechanism used internally for wildcard +
        // loopback sockets sharing a port. userDataOnReceive runs completely
        // unmodified and keeps deciding for itself, by entity ID, what it
        // owns; SEDP is untouched and still only knows about builtin
        // entities. The metatraffic port simply gets a second listener, the
        // same as any other locally-owned port would.
        if (!self.config.transport.tcp.enabled) {
            var meta_port: u16 = 0;
            for (meta_locators.items) |loc| {
                switch (loc) {
                    .udp_v4 => |u| {
                        meta_port = u.port;
                        break;
                    },
                    else => {},
                }
            }
            if (meta_port != 0 and meta_port != self.data_listen_port) {
                const meta_listen_loc = Locator.udp4(.{ 0, 0, 0, 0 }, meta_port);
                // Best-effort: this is a robustness addition (see the comment
                // above), not a hard requirement. UdpTransport supports a
                // second listen() call sharing one PortEntry via addHandler,
                // but MockTransport/MemoryTransport (test-only, used for fast
                // in-process integration tests) don't -- they return
                // error.PortAlreadyListening for any second listen() on a
                // port, since SEDP already listens on the metatraffic port
                // by this point. Failing participant start() over a transport
                // not supporting an extra safety net would be worse than not
                // having the safety net; just skip it.
                if (self.discovery_transport.listen(&meta_listen_loc, self.userDataHandler())) |_| {
                    // Only record success: deinit() unlistens iff this is
                    // nonzero, and must mirror exactly what got registered.
                    self.meta_userdata_listen_port = meta_port;
                } else |err| {
                    log_mod.dcps.debug("participant: could not also listen for user-data traffic on the metatraffic port ({s}) -- continuing without this fallback", .{@errorName(err)});
                }
            }
        }

        // On a runtime the checks are armed as they become due instead.
        if (self.runtime != null) return;

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

    /// Stops discovery and the receives `start` began, those it got to.
    fn stopReceiving(self: *Self) void {
        if (self.discovery_started) self.discovery.stop();
        self.discovery_started = false;
        if (self.data_listening and self.data_listen_port != 0) {
            const loc = Locator.udp4(.{ 0, 0, 0, 0 }, self.data_listen_port);
            self.transport.unlisten(&loc, self.userDataHandler());
        }
        self.data_listening = false;
        // Mirror start()'s metatraffic-port fallback registration, if any --
        // otherwise a packet arriving on that port after this point calls
        // userDataOnReceive with a freed `self` (SEDP's own registration on
        // the same PortEntry is unaffected; self.discovery.stop() above
        // handles that side).
        if (self.meta_userdata_listen_port != 0) {
            const meta_loc = Locator.udp4(.{ 0, 0, 0, 0 }, self.meta_userdata_listen_port);
            self.discovery_transport.unlisten(&meta_loc, self.userDataHandler());
        }
        self.meta_userdata_listen_port = 0;
    }

    /// Periodically calls checkTimers() to enforce DEADLINE/LIVELINESS QoS.
    /// Stopped by setting timer_stopping before calling timer_thread.join()
    /// (see deinit()) -- same shape as writer_sm.zig's heartbeatThread.
    fn timerThreadFn(self: *Self) void {
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
        if (self.pending_self_destroy) self.finishDestroy();
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
        // On a runtime: from inside a check, the participant is freed once
        // that turn ends instead.
        const timers_deferred = self.runtime != null and !self.stopCheckTimer();
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
        // Stop receiving user data before tearing down readers.
        self.stopReceiving();
        // Nothing is delivered after the unlistens above; what was is dropped,
        // and a turn processing it finishes before entities are torn down,
        // unless this is that turn: then the participant is freed after it.
        const ingress_deferred = self.runtime != null and
            !self.ingress_latch.close(&self.ingress, Ingress.discard);
        // Likewise for listeners: those queued or parked never start, and
        // those running elsewhere return before entities are torn down. From
        // inside one, the rest follows the last of them, so no listener of
        // this participant runs while its entities are torn down.
        if (self.runtime != null and !self.listener_group.close()) {
            self.listener_group.finishWith(.{ .ctx = self, .run = teardownHook });
            return;
        }
        self.teardown(.{ .timers = timers_deferred, .ingress = ingress_deferred, .self_reentrant = self_reentrant });
    }

    /// What `deinit` hands to a turn that will free the participant.
    const Deferred = struct {
        timers: bool = false,
        ingress: bool = false,
        self_reentrant: bool = false,
    };

    fn teardownHook(ctx: *anyopaque) void {
        cast(ctx).teardown(.{});
    }

    /// The rest of `deinit`, once no listener of this participant runs.
    fn teardown(self: *Self, deferred: Deferred) void {
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
        self.announcing.deinit(self.alloc);

        // Drop participant-owned provider pins outside the lock. Protocol
        // readers hold independent pins through deferred/quiescent teardown.
        var ts_it = self.type_support_registry.iterator();
        while (ts_it.next()) |entry| {
            if (entry.value_ptr.deinit) |f| f(entry.value_ptr.ctx);
            self.alloc.free(entry.key_ptr.*);
        }
        self.type_support_registry.deinit(self.alloc);
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
        for (self.discovered_writers.items) |*dw| dw.deinit(self.alloc);
        self.discovered_writers.deinit(self.alloc);
        for (self.discovered_readers.items) |*dr| dr.deinit(self.alloc);
        self.discovered_readers.deinit(self.alloc);
        self.unmatched.deinit();
        self.settled_writers.deinit(self.alloc);
        self.discovery_gens.deinit(self.alloc);

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

        // One thread runs one turn at a time: at most one of these is set.
        if (deferred.timers) {
            self.timers_latch.finishWith(.{ .ctx = self, .run = finishDestroyHook });
            return;
        }
        if (deferred.ingress) {
            self.ingress_latch.finishWith(.{ .ctx = self, .run = finishDestroyHook });
            return;
        }

        // Every step above only touches self's own fields and owned
        // sub-resources, so it's safe to run reentrantly regardless of
        // which thread called deinit(). Freeing `self` itself is the one
        // exception: checkTimers() and timerThreadFn are still executing
        // further up this exact call stack when self_reentrant is true,
        // and still need `self` (e.g. to read timer_stopping, already true
        // above) to unwind safely. Defer the actual free to timerThreadFn,
        // which performs it as the very last thing it does once its own
        // loop has genuinely exited -- see timerThreadFn.
        if (deferred.self_reentrant) {
            self.pending_self_destroy = true;
        } else {
            self.finishDestroy();
        }
    }

    pub fn toDDSParticipant(self: *Self) DDS.DomainParticipant {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Associate a CDR-encoded XTypes TypeInformation blob with a type name.
    /// The caller owns `cdr`; it must remain valid for the lifetime of the participant.
    /// Called before creating DataWriters/DataReaders for the type.
    /// Register TypeSupport callbacks for a type name.
    /// Call before creating DataReaders for the type. The registry owns a copy
    /// of `type_name`; this legacy API consumes the supplied support on every outcome.
    pub fn registerTypeSupport(self: *Self, type_name: []const u8, ts: TypeSupport) bool {
        // This legacy API consumes ts on every outcome. Cleanup after unlocking:
        // a provider's final release must not unload code under participant.mu.
        var cleanup: ?TypeSupport = null;
        defer if (cleanup) |old| if (old.deinit) |f| f(old.ctx);
        // Pinned/checked registrations must use the immutable install path.
        if (ts.provider_generation != 0 or ts.sample_processor != null) {
            cleanup = ts;
            return false;
        }
        // Heap-copy the key so the map owns it regardless of caller lifetime.
        const owned_key = self.alloc.dupe(u8, type_name) catch {
            cleanup = ts;
            return false;
        };
        self.mu.lock();
        defer self.mu.unlock();
        const gop = self.type_support_registry.getOrPut(self.alloc, owned_key) catch {
            self.alloc.free(owned_key);
            cleanup = ts;
            return false;
        };
        if (gop.found_existing) {
            if (gop.value_ptr.provider_generation != 0) {
                self.alloc.free(owned_key);
                cleanup = ts;
                return false;
            }
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
                    ar.key_hash_only_fn = ts.compute_key_hash_key_only;
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
            cleanup = gop.value_ptr.*;
            self.alloc.free(gop.key_ptr.*);
            gop.key_ptr.* = owned_key;
        }
        gop.value_ptr.* = ts;
        return true;
    }

    /// New immutable registration. Transfers ts only when true is returned;
    /// false means the same generation/type is already installed. Failures and
    /// false leave cleanup with the caller. Install before any topic of this type
    /// exists, which also closes the endpoint-construction snapshot race.
    pub fn installPinnedTypeSupport(self: *Self, type_name: []const u8, ts: TypeSupport) !bool {
        std.debug.assert(ts.provider_generation != 0 and ts.sample_processor != null);
        const owned_key = try self.alloc.dupe(u8, type_name);
        errdefer self.alloc.free(owned_key);
        self.mu.lock();
        defer self.mu.unlock();
        if (self.type_support_registry.get(type_name)) |old| {
            if (old.provider_generation == ts.provider_generation and std.mem.eql(u8, &old.minimal_identifier, &ts.minimal_identifier)) {
                self.alloc.free(owned_key);
                return false;
            }
            if (old.provider_generation == 0) return error.TypeAlreadyRegistered;
            if (std.mem.eql(u8, &old.minimal_identifier, &ts.minimal_identifier)) return error.EquivalentProviderAlreadyRegistered;
            return error.ConflictingTypeRegistration;
        }
        for (self.topics.items) |topic| if (std.mem.eql(u8, topic.type_name, type_name)) return error.TypeInUse;
        const entry = try self.type_support_registry.getOrPut(self.alloc, owned_key);
        std.debug.assert(!entry.found_existing);
        entry.value_ptr.* = ts;
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
        const support = self.type_support_registry.get(type_name);
        const registered_keyed: ?bool = if (support) |s| s.has_key else null;
        // Legacy native callers may leave has_key at its historical default,
        // even for keyed types (including the pinned dds-rtps adapter). Only a
        // checked provider registration guarantees explicit endpoint keyedness.
        const endpoint_keyed = if (support) |s| s.provider_generation == 0 or s.has_key else true;
        self.mu.unlock();

        const guid = Guid{
            .prefix = self.guid.prefix,
            .entity_id = .{
                .entity_key = key,
                .entity_kind = if (endpoint_keyed) EntityKind.user_writer_with_key else EntityKind.user_writer_no_key,
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
        if (self.runtime) |rt| adapter.attachRuntime(rt);
        adapter.setDropAcked(qos.reliability.kind == .RELIABLE_RELIABILITY_QOS and !replay_on_match);
        // {0,0} from codegen means unset → infinite (no lifespan enforcement),
        // matching the convention used by discovery/qos_adapter.zig for SEDP announcement.
        const ls_zero = qos.lifespan.duration.sec == 0 and qos.lifespan.duration.nanosec == 0;
        adapter.setLifespan(if (ls_zero) null else time_mod.RtpsDuration.fromDuration(.{
            .sec = qos.lifespan.duration.sec,
            .nanosec = qos.lifespan.duration.nanosec,
        }));

        // Keyed writers must send inline PID_KEY_HASH on every sample so the
        // subscriber never reconstructs a per-instance hash from the payload
        // (RTPS §8.7.9; see resolveKeyHash). Requires the type's TypeSupport to
        // be registered before this writer is created — the same ordering
        // constraint readers already have for key_hash_fn.
        adapter.setKeyed(registered_keyed orelse false);

        const pw = adapter.toProtocolWriter();

        // qos.data_representation.value._buffer, as received here, borrows
        // storage the caller only guarantees valid for the duration of this
        // call (e.g. the C++ binding's create_datawriter passes qos by value
        // through a chain of stack-local copies that get destroyed once this
        // whole call returns -- see ActiveWriter.qos's doc comment). Clone it
        // the same way dupePartitionNames already does for partition_names,
        // or discovery/qos_adapter.zig re-reads this later (at match time, against
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
        var handed_off = false;
        if (found_guid) |g| {
            _ = self.active_writers.remove(entityIdKey(g.entity_id));
            self.withdrawDiscoveryGenLocked(g);
            handed_off = self.handOffDisposalLocked(g);
        }
        self.mu.unlock();

        freePartitionNames(self.alloc, found_parts);
        found_repr.deinit(self.alloc);
        freeUserData(self.alloc, found_user_data);
        if (found_guid) |g| if (!handed_off) self.retractDeleted(.writer, g);
        if (found_proto) |p| p.deinit();
    }

    // ── SubscriberImpl callbacks ──────────────────────────────────────────────

    fn subCreateProtoReader(
        ctx: *anyopaque,
        topic_name: []const u8,
        type_name: []const u8,
        qos: DDS.DataReaderQos,
        presentation: DDS.PresentationQosPolicy,
        subscription_handle: *DDS.InstanceHandle_t,
        guid_out: *Guid,
    ) anyerror!proto.ProtocolReader {
        const self = cast(ctx);

        self.mu.lock();
        const key = self.nextEntityKeyLocked();
        const is_keyed = if (self.type_support_registry.get(type_name)) |support| support.provider_generation == 0 or support.has_key else true;
        self.mu.unlock();

        const guid = Guid{
            .prefix = self.guid.prefix,
            .entity_id = .{
                .entity_key = key,
                .entity_kind = if (is_keyed) EntityKind.user_reader_with_key else EntityKind.user_reader_no_key,
            },
        };
        guid_out.* = guid;
        subscription_handle.* = writer_mod.guidToHandle(guid);

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
        // in ActiveReader, or a later discovery/qos_adapter.zig call reads a
        // dangling buffer.
        var owned_qos = qos;
        owned_qos.data_representation.value = try qos.data_representation.value.clone(self.alloc);
        errdefer owned_qos.data_representation.value.deinit(self.alloc);
        owned_qos.user_data = try cloneUserData(self.alloc, qos.user_data);
        errdefer freeUserData(self.alloc, owned_qos.user_data);

        {
            self.mu.lock();
            defer self.mu.unlock();
            // Not yet published/matched, so no reader lock is needed here.
            if (self.type_support_registry.get(type_name)) |support| adapter.reader.setSampleProcessor(support.sample_processor);
            try self.active_readers.put(self.alloc, entityIdKey(guid.entity_id), .{
                .handle = subscription_handle.*,
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
                .key_hash_only_fn = if (self.type_support_registry.get(type_name)) |ts|
                    ts.compute_key_hash_key_only
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
        var handed_off = false;
        if (found_guid) |g| {
            _ = self.active_readers.remove(entityIdKey(g.entity_id));
            self.withdrawDiscoveryGenLocked(g);
            handed_off = self.handOffDisposalLocked(g);
        }
        self.mu.unlock();

        freePartitionNames(self.alloc, found_parts);
        found_repr.deinit(self.alloc);
        freeUserData(self.alloc, found_user_data);
        if (found_guid) |g| if (!handed_off) self.retractDeleted(.reader, g);
        if (found_proto) |p| p.deinit();
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

    /// Decode the inline `PID_KEY_HASH` (RTPS §9.6.4.8), if the writer sent one.
    /// Returns `null` when the parameter is absent (or malformed) — distinct from
    /// a *present* all-zero hash, which `resolveKeyHash` must honour verbatim
    /// rather than treating as "recompute from payload".
    fn decodeKeyHash(iq: ?submsg_mod.InlineQos) ?[16]u8 {
        if (iq) |q| {
            if (q.get(.key_hash)) |kh| {
                if (kh.len >= 16) {
                    var h: [16]u8 = undefined;
                    @memcpy(&h, kh[0..16]);
                    return h;
                }
            }
        }
        return null;
    }

    fn decodeCoherentSetSn(iq: ?submsg_mod.InlineQos, little_endian: bool) ?history_mod.SequenceNumber {
        const sn = (iq orelse return null).getSequenceNumber(.coherent_set, little_endian) orelse return null;
        // Valid RTPS SNs start at 1.  SEQUENCENUMBER_UNKNOWN ({high=-1,low=MAX})
        // and any other non-positive value are end-of-coherent-set signals
        // (RTPS §9.6.4.2 Table 9.22 Example 2) — treat as non-coherent DATA.
        if (sn < 1) return null;
        return sn;
    }

    fn decodeGroupSeqNum(iq: ?submsg_mod.InlineQos, little_endian: bool) ?history_mod.SequenceNumber {
        return (iq orelse return null).getSequenceNumber(.group_seq_num, little_endian);
    }

    /// PID_GROUP_COHERENT_SET: the group sequence number of the first sample
    /// in the group coherent set, which identifies the set (RTPS 2.5 §8.7.6).
    fn decodeGroupCoherentSn(iq: ?submsg_mod.InlineQos, little_endian: bool) ?history_mod.SequenceNumber {
        const sn = (iq orelse return null).getSequenceNumber(.group_coherent_set, little_endian) orelse return null;
        if (sn < 1) return null;
        return sn;
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

    /// Resolve the effective 16-byte key hash for a received change.
    ///
    /// A *present* inline `PID_KEY_HASH` (`maybe_kh != null`) always wins — even
    /// if it is all-zeros. An all-zero hash is a legitimate value (a zero-valued
    /// key, or a keyless topic), distinct from the parameter being *absent*;
    /// treating "present, all-zero" as "recompute" (the old behaviour) discarded
    /// a hash the writer deliberately sent. This is the common path: RTPS §8.7.9
    /// says a keyed writer SHOULD send it, and zzdds's own writer does whenever
    /// the computed hash is non-zero.
    ///
    /// With no inline hash we fall back to the type's `key_hash_fn`/
    /// `key_hash_only_fn` (`TypeSupport.compute_key_hash`/
    /// `compute_key_hash_key_only`), picked by `kind`: an ALIVE change's
    /// `payload` is a complete sample (`key_hash_fn`, backed by zidl's
    /// `computeKeyHashFromCdr` — `deserializeSelected`-based, so a
    /// non-leading `@key` member is read correctly regardless of what
    /// precedes it); a DISPOSE/UNREGISTER change's `payload` is a genuine
    /// key-only wire payload per RTPS §8.7.9's K-flag convention
    /// (`key_hash_only_fn`, backed by `computeKeyHashFromCdrKeyOnly`) —
    /// calling the ALIVE-shaped function on that would misread it (missing
    /// non-key member bytes to "skip"), not just misread a non-leading key.
    ///
    /// `key_hash_only_fn` is optional: a `TypeSupport` registered without it
    /// falls back to `zeroes([16]u8)` rather than risk that misread — a
    /// known, deliberately incomplete instance handle for that registration
    /// rather than a confidently wrong non-zero one. This stays reachable in
    /// practice, independent of binding: a hand-written `TypeSupport`, or a
    /// generated class predating `computeKeyHashFromCdrKeyOnly`
    /// (Java resolves it by reflection and tolerates it being absent), or a
    /// keyless type (no key-only payload ever needs one), all leave it null
    /// legitimately.
    fn resolveKeyHash(maybe_kh: ?[16]u8, ar: *ActiveReader, payload: []const u8, kind: history_mod.ChangeKind) [16]u8 {
        if (maybe_kh) |kh| return kh;
        if (kind == .alive) {
            if (ar.key_hash_fn) |f| return f(ar.key_hash_ctx, payload);
        } else if (ar.key_hash_only_fn) |f| {
            return f(ar.key_hash_ctx, payload);
        }
        return std.mem.zeroes([16]u8);
    }

    /// Raises the incompatible-QoS notifications recorded on local readers or
    /// writers (see IncompatQosPending), with self.mu released. Each endpoint
    /// is pinned under self.mu by its matched_notify (registered alongside
    /// incompat_qos) so a concurrent delete cannot free it meanwhile. Batches
    /// are fixed-size, so raising them needs no memory either.
    fn raiseIncompatQos(self: *Self, comptime which: enum { readers, writers }) void {
        const Job = struct { notify: IncompatQosNotify, pin: MatchedNotify, pending: IncompatQosPending };
        while (true) {
            var jobs: [16]Job = undefined;
            var n: usize = 0;
            var more = false;
            self.mu.lock();
            var it = switch (which) {
                .readers => self.active_readers.valueIterator(),
                .writers => self.active_writers.valueIterator(),
            };
            while (it.next()) |e| {
                if (!e.incompat_pending.any()) continue;
                if (n == jobs.len) {
                    more = true;
                    break;
                }
                const pending = e.incompat_pending;
                e.incompat_pending = .{};
                const notify = e.incompat_qos orelse continue;
                const pin = e.matched_notify orelse continue;
                if (!pin.quiesceAcquire()) continue;
                jobs[n] = .{ .notify = notify, .pin = pin, .pending = pending };
                n += 1;
            }
            self.mu.unlock();
            for (jobs[0..n]) |job| {
                job.pending.raise(job.notify);
                job.pin.quiesceRelease();
            }
            if (!more) return;
        }
    }

    /// A protocol reader pinned under self.mu for dispatch after it is
    /// released; see dispatchToReaders.
    pub const PinnedReader = struct {
        proto: proto.ProtocolReader,
        key_hash: [16]u8 = std.mem.zeroes([16]u8),
    };

    /// What dispatchToReaders needs to resolve each reader's key hash for a DATA.
    pub const DataKeyArgs = struct {
        key_hash: ?[16]u8,
        payload: []const u8,
        kind: history_mod.ChangeKind,
    };

    /// Fan-out readers pinned in one go before a heap allocation is needed.
    const FANOUT_STACK = 16;
    /// Fan-out batch size when even that allocation fails.
    const FANOUT_BATCH = 16;

    /// Calls `ctx.deliver(reader)` for each reader a submessage addressed to
    /// `reader_entity_id` reaches (every active reader for ENTITYID_UNKNOWN),
    /// with self.mu released: protocol readers raise application listeners
    /// (on_data_available, on_sample_lost, on_liveliness_changed, ...). Each
    /// reader is pinned with quiesceAcquire under self.mu so a concurrent
    /// delete cannot free it meanwhile; a reader already tearing down is
    /// skipped. With `data`, also resolves each reader's key hash, which needs
    /// its type support. No reader is ever skipped for lack of memory: when the
    /// fan-out list cannot be allocated, readers go in fixed-size batches in
    /// entity-key order (see nextFanoutBatch).
    ///
    /// Data (a `ctx` with `hold`) from a writer not matched yet is held for
    /// the readers first (see holdIfUnmatchedLocked).
    fn dispatchToReaders(self: *Self, reader_entity_id: EntityId, data: ?DataKeyArgs, ctx: anytype) void {
        if (!reader_entity_id.eql(EntityIds.unknown)) {
            self.mu.lock();
            const target = if (self.active_readers.getPtr(entityIdKey(reader_entity_id))) |ar| pinReaderLocked(ar, data) else null;
            if (target != null) self.holdIfUnmatchedLocked(reader_entity_id, ctx);
            self.mu.unlock();
            if (target) |t| {
                ctx.deliver(t);
                t.proto.quiesceRelease();
            }
            return;
        }

        var stack_buf: [FANOUT_STACK]PinnedReader = undefined;
        var sfa = std.heap.BufferFirstAllocator.init(std.mem.sliceAsBytes(&stack_buf), self.alloc);
        const a = sfa.allocator();
        var targets: std.ArrayListUnmanaged(PinnedReader) = .empty;
        defer targets.deinit(a);
        self.mu.lock();
        if (self.active_readers.count() > 0) self.holdIfUnmatchedLocked(reader_entity_id, ctx);
        if (targets.ensureTotalCapacityPrecise(a, self.active_readers.count())) |_| {
            var it = self.active_readers.valueIterator();
            while (it.next()) |ar| if (pinReaderLocked(ar, data)) |t| targets.appendAssumeCapacity(t);
            self.mu.unlock();
            for (targets.items) |t| {
                ctx.deliver(t);
                t.proto.quiesceRelease();
            }
            return;
        } else |_| {}
        self.mu.unlock();
        self.dispatchToReadersBatched(data, ctx);
    }

    /// Holds `ctx`'s sample or fragment, sent to `target` (ENTITYID_UNKNOWN
    /// for every reader), when its writer is not settled: discovery has not
    /// yet announced it and matched it against local readers.  A reader
    /// that then matches the writer takes it (see onWriterDiscovered's
    /// prematch).  Held before any reader sees it, so a reader matching the
    /// writer meanwhile gets it from one or the other.  Nothing is held from
    /// a writer once settled: a reader that has not matched it by then never
    /// will on that announcement.  Caller holds self.mu.
    fn holdIfUnmatchedLocked(self: *Self, target: EntityId, ctx: anytype) void {
        if (!@hasDecl(@TypeOf(ctx), "hold")) return;
        const writer = ctx.writer_guid;
        // Only a user-defined writer can match a DataReader: not a built-in
        // or vendor-specific one, whose entityKind's top two bits are not 00
        // (RTPS 2.5 §9.3.1.2), and which discovery never announces as one.
        if (writer.entity_id.entity_kind & 0xC0 != 0) return;
        if (self.settled_writers.contains(writer)) return;
        for (self.ignored_prefixes.items) |p| {
            if (p.eql(writer.prefix)) return;
        }
        const handle = writer_mod.guidToHandle(writer);
        for (self.ignored_publication_handles.items) |h| {
            if (h == handle) return;
        }
        const now_ns = self.timer_clock.nowNs();
        const ttl_ns = self.unmatchedTtlNsLocked(writer.prefix);
        ctx.hold(&self.unmatched, target, now_ns, ttl_ns);
        self.armCheck(now_ns + ttl_ns);
    }

    /// How long data from a writer of participant `prefix` is held for a
    /// match: one lease duration of that participant (of this one, while
    /// that one is undiscovered), at most UNMATCHED_MAX_TTL_NS.  A live
    /// participant announces itself at least once per lease, and announces
    /// its endpoints reliably, so a writer still unannounced after a lease
    /// is not about to be.  Caller holds self.mu.
    fn unmatchedTtlNsLocked(self: *Self, prefix: GuidPrefix) i64 {
        var lease_ms = self.config.participant.lease_duration_ms;
        for (self.discovered_participants.items) |e| {
            if (e.guid.prefix.eql(prefix)) {
                if (e.lease_ms != 0) lease_ms = e.lease_ms;
                break;
            }
        }
        return @min(@as(i64, lease_ms) * std.time.ns_per_ms, UNMATCHED_MAX_TTL_NS);
    }

    /// dispatchToReaders' fan-out to every active reader when its list cannot
    /// be allocated: FANOUT_BATCH readers at a time, in entity-key order, with
    /// no allocation. Public only so tests can drive it directly.
    pub fn dispatchToReadersBatched(self: *Self, data: ?DataKeyArgs, ctx: anytype) void {
        var after: ?u32 = null;
        while (true) {
            var keys: [FANOUT_BATCH]u32 = undefined;
            self.mu.lock();
            const sel = nextFanoutBatch(&self.active_readers, after, &keys);
            var batch: [FANOUT_BATCH]PinnedReader = undefined;
            var n: usize = 0;
            for (keys[0..sel.len]) |k| {
                if (pinReaderLocked(self.active_readers.getPtr(k).?, data)) |t| {
                    batch[n] = t;
                    n += 1;
                }
            }
            self.mu.unlock();
            for (batch[0..n]) |t| {
                ctx.deliver(t);
                t.proto.quiesceRelease();
            }
            if (!sel.more) return;
            after = keys[sel.len - 1];
        }
    }

    /// Fills `out` with the smallest keys of `map` greater than `after`, in
    /// ascending order, and reports whether larger ones remain. Repeated with
    /// `after` set to the last key returned, it visits every key once without
    /// allocating, even if the map changes between calls (a key added below
    /// `after` meanwhile is not visited).
    fn nextFanoutBatch(map: anytype, after: ?u32, out: []u32) struct { len: usize, more: bool } {
        var n: usize = 0;
        var more = false;
        var it = map.keyIterator();
        while (it.next()) |kp| {
            const k = kp.*;
            if (after) |lo| if (k <= lo) continue;
            if (n == out.len) {
                more = true;
                if (k > out[n - 1]) continue;
                n -= 1;
            }
            var i = n;
            while (i > 0 and out[i - 1] > k) : (i -= 1) out[i] = out[i - 1];
            out[i] = k;
            n += 1;
        }
        return .{ .len = n, .more = more };
    }

    fn pinReaderLocked(ar: *ActiveReader, data: ?DataKeyArgs) ?PinnedReader {
        if (!ar.proto.quiesceAcquire()) return null;
        const kh = if (data) |d| resolveKeyHash(d.key_hash, ar, d.payload, d.kind) else std.mem.zeroes([16]u8);
        return .{ .proto = ar.proto, .key_hash = kh };
    }

    /// Under self.mu: the active writer with `writer_entity_id`, pinned for
    /// dispatch after self.mu is released (handleAckNack can raise
    /// on_reliable_reader_ready). The caller releases the pin.
    fn pinWriterLocked(self: *Self, writer_entity_id: EntityId) ?proto.ProtocolWriter {
        const aw = self.active_writers.getPtr(entityIdKey(writer_entity_id)) orelse return null;
        return if (aw.proto.quiesceAcquire()) aw.proto else null;
    }

    /// The `hold` of a DATA's dispatchToReaders context (see
    /// holdIfUnmatchedLocked): its fields, as protocol_adapters makes them
    /// into a CacheChange.
    fn holdData(c: anytype, cache: *unmatched_mod.UnmatchedCache, target: EntityId, now_ns: i64, ttl_ns: i64) void {
        const change = history_mod.CacheChange{
            .kind = c.kind,
            .writer_guid = c.writer_guid,
            .sequence_number = c.sn,
            .source_timestamp = c.ts,
            .instance_handle = history_mod.INSTANCE_HANDLE_NIL,
            .key_hash = c.key_hash orelse std.mem.zeroes([16]u8),
            .data = c.payload,
            .coherent_set_sn = c.coherent_set_sn,
            .group_seq_num = c.group_seq_num,
            .group_coherent_sn = c.group_coherent_sn,
            .inline_lifespan_ns = c.lifespan_ns,
        };
        cache.put(c.writer_guid, target, &change, c.key_hash != null, now_ns, ttl_ns);
    }

    fn dispatchDirectedWrite(
        self: *DomainParticipantImpl,
        dw_bytes: []const u8,
        little_endian: bool,
        writer_guid: Guid,
        sn: anytype,
        ts: time_mod.RtpsTimestamp,
        key_hash: ?[16]u8,
        payload: []const u8,
        kind: history_mod.ChangeKind,
        coherent_set_sn: ?history_mod.SequenceNumber,
        group_seq_num: ?history_mod.SequenceNumber,
        group_coherent_sn: ?history_mod.SequenceNumber,
        lifespan_ns: ?i64,
    ) void {
        if (dw_bytes.len < 4) return;
        const endian: std.builtin.Endian = if (little_endian) .little else .big;
        const count = std.mem.readInt(u32, dw_bytes[0..4], endian);
        const Deliver = struct {
            writer_guid: Guid,
            sn: @TypeOf(sn),
            ts: time_mod.RtpsTimestamp,
            payload: []const u8,
            kind: history_mod.ChangeKind,
            coherent_set_sn: ?history_mod.SequenceNumber,
            group_seq_num: ?history_mod.SequenceNumber,
            group_coherent_sn: ?history_mod.SequenceNumber,
            lifespan_ns: ?i64,
            key_hash: ?[16]u8,
            fn deliver(c: @This(), t: PinnedReader) void {
                t.proto.handleIncomingChange(c.writer_guid, c.sn, c.ts, t.key_hash, c.payload, c.kind, c.coherent_set_sn, c.group_seq_num, c.group_coherent_sn, c.lifespan_ns);
            }
            pub const hold = holdData;
        };
        const ctx = Deliver{ .writer_guid = writer_guid, .sn = sn, .ts = ts, .payload = payload, .kind = kind, .coherent_set_sn = coherent_set_sn, .group_seq_num = group_seq_num, .group_coherent_sn = group_coherent_sn, .lifespan_ns = lifespan_ns, .key_hash = key_hash };
        // One reader per entry, so nothing to collect (or allocate).
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
            if (eid.eql(EntityIds.unknown)) continue;
            self.dispatchToReaders(eid, .{ .key_hash = key_hash, .payload = payload, .kind = kind }, ctx);
        }
    }

    // Called from the transport's receive thread on the data unicast port.
    // Parses each RTPS message and delivers DATA submessages to all active
    // readers; each ProtocolReader filters internally via isWriterMatched().
    //
    // Lock order: participant.mu → StatefulReader.mu (correct order).

    fn userDataOnReceive(ctx: *anyopaque, raw: []const u8, _: Locator, _: transport_if.Channel) void {
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
                    const group_coherent_sn = decodeGroupCoherentSn(d.inline_qos, d.isLittleEndian());
                    const lifespan_ns = decodeLifespan(d.inline_qos, d.isLittleEndian());

                    if (d.inline_qos) |iq| {
                        if (iq.get(.directed_write)) |dw_bytes| {
                            dispatchDirectedWrite(self, dw_bytes, d.isLittleEndian(), writer_guid, d.writer_sn, current_ts, key_hash, d.serialized_payload, kind, coherent_set_sn, group_seq_num, group_coherent_sn, lifespan_ns);
                            continue;
                        }
                    }

                    // Delivery raises on_data_available and friends: dispatched
                    // after self.mu is released (see dispatchToReaders).
                    const Deliver = struct {
                        writer_guid: Guid,
                        sn: @TypeOf(d.writer_sn),
                        ts: time_mod.RtpsTimestamp,
                        payload: []const u8,
                        kind: history_mod.ChangeKind,
                        coherent_set_sn: ?history_mod.SequenceNumber,
                        group_seq_num: ?history_mod.SequenceNumber,
                        group_coherent_sn: ?history_mod.SequenceNumber,
                        lifespan_ns: ?i64,
                        key_hash: ?[16]u8,
                        fn deliver(c: @This(), t: PinnedReader) void {
                            t.proto.handleIncomingChange(c.writer_guid, c.sn, c.ts, t.key_hash, c.payload, c.kind, c.coherent_set_sn, c.group_seq_num, c.group_coherent_sn, c.lifespan_ns);
                        }
                        pub const hold = holdData;
                    };
                    self.dispatchToReaders(d.reader_entity_id, .{ .key_hash = key_hash, .payload = d.serialized_payload, .kind = kind }, Deliver{
                        .writer_guid = writer_guid,
                        .sn = d.writer_sn,
                        .ts = current_ts,
                        .payload = d.serialized_payload,
                        .kind = kind,
                        .coherent_set_sn = coherent_set_sn,
                        .group_seq_num = group_seq_num,
                        .group_coherent_sn = group_coherent_sn,
                        .lifespan_ns = lifespan_ns,
                        .key_hash = key_hash,
                    });
                },
                .heartbeat => |hb| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const writer_guid = Guid{ .prefix = src_prefix, .entity_id = hb.writer_entity_id };
                    // handleHeartbeat can fire on_reliable_writer_ready, which
                    // reaches arbitrary application listener code -- must not
                    // run while self.mu is held (a listener re-entering any
                    // participant API would deadlock). Mirrors onReaderDiscovered/
                    // onWriterDiscovered's quiesce-protected job-list pattern:
                    // pin under the lock, unlock, then dispatch (dispatchToReaders).
                    const Deliver = struct {
                        writer_guid: Guid,
                        hb: @TypeOf(hb),
                        fn deliver(c: @This(), t: PinnedReader) void {
                            t.proto.handleHeartbeat(c.writer_guid, c.hb.reader_entity_id, c.hb.first_sn, c.hb.last_sn, c.hb.count, c.hb.isFinal(), c.hb.isLiveliness());
                        }
                    };
                    self.dispatchToReaders(hb.reader_entity_id, null, Deliver{ .writer_guid = writer_guid, .hb = hb });
                },
                .acknack => |an| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const reader_guid = Guid{ .prefix = src_prefix, .entity_id = an.reader_entity_id };
                    // handleAckNack can raise on_reliable_reader_ready, which
                    // must not run under self.mu (see pinWriterLocked).
                    self.mu.lock();
                    const target = self.pinWriterLocked(an.writer_entity_id);
                    self.mu.unlock();
                    if (target) |w| {
                        w.handleAckNack(reader_guid, an.reader_sn_state.base - 1, an.reader_sn_state, an.count, an.isFinal());
                        w.quiesceRelease();
                    }
                },
                .data_frag => |df| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const writer_guid = Guid{ .prefix = src_prefix, .entity_id = df.writer_entity_id };
                    // A completed sample is delivered from handleDataFrag, so
                    // dispatch after self.mu is released (see dispatchToReaders).
                    const Deliver = struct {
                        writer_guid: Guid,
                        ts: time_mod.RtpsTimestamp,
                        df: @TypeOf(df),
                        fn deliver(c: @This(), t: PinnedReader) void {
                            t.proto.handleDataFrag(c.writer_guid, c.ts, c.df);
                        }
                        pub fn hold(c: @This(), cache: *unmatched_mod.UnmatchedCache, target: EntityId, now_ns: i64, ttl_ns: i64) void {
                            cache.putFrag(c.writer_guid, target, c.df, c.ts, now_ns, ttl_ns);
                        }
                    };
                    self.dispatchToReaders(df.reader_entity_id, null, Deliver{ .writer_guid = writer_guid, .ts = current_ts, .df = df });
                },
                .heartbeat_frag => |hbf| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const writer_guid = Guid{ .prefix = src_prefix, .entity_id = hbf.writer_entity_id };
                    // No listener here, but the NACK_FRAG it can send is I/O:
                    // also dispatched after self.mu is released.
                    const Deliver = struct {
                        writer_guid: Guid,
                        hbf: @TypeOf(hbf),
                        fn deliver(c: @This(), t: PinnedReader) void {
                            t.proto.handleHeartbeatFrag(c.writer_guid, c.hbf.writer_sn, c.hbf.last_fragment_num, c.hbf.count);
                        }
                    };
                    self.dispatchToReaders(hbf.reader_entity_id, null, Deliver{ .writer_guid = writer_guid, .hbf = hbf });
                },
                .nack_frag => |nf| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const reader_guid = Guid{ .prefix = src_prefix, .entity_id = nf.reader_entity_id };
                    // No listener here, but the repair it sends is I/O: also
                    // dispatched after self.mu is released.
                    self.mu.lock();
                    const target = self.pinWriterLocked(nf.writer_entity_id);
                    self.mu.unlock();
                    if (target) |w| {
                        w.handleNackFrag(reader_guid, nf.writer_sn, nf.fragment_number_state, nf.count);
                        w.quiesceRelease();
                    }
                },
                .gap => |g| {
                    if (!dst_prefix.eql(GuidPrefix.unknown) and
                        !dst_prefix.eql(self.guid.prefix)) continue;
                    const writer_guid = Guid{ .prefix = src_prefix, .entity_id = g.writer_entity_id };
                    // handleGap can raise on_sample_lost and deliver buffered
                    // samples: dispatch after self.mu is released.
                    const Deliver = struct {
                        writer_guid: Guid,
                        g: @TypeOf(g),
                        fn deliver(c: @This(), t: PinnedReader) void {
                            t.proto.handleGap(c.writer_guid, c.g.gap_start, c.g.gap_list);
                        }
                    };
                    self.dispatchToReaders(g.reader_entity_id, null, Deliver{ .writer_guid = writer_guid, .g = g });
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
            for (self.discovered_participants.items) |*e| {
                if (e.guid.eql(data.guid)) {
                    e.lease_ms = data.lease_duration_ms;
                    is_dup = true;
                    break;
                }
            }
            if (!is_dup) {
                const handle = writer_mod.guidToHandle(data.guid);
                self.discovered_participants.append(
                    self.alloc,
                    .{ .guid = data.guid, .handle = handle, .vendor_id = data.vendor_id, .lease_ms = data.lease_duration_ms },
                ) catch {};
                if (self.builtin_sub) |bs| push_dr = bs.part_dr;
            }
        }
        self.mu.unlock();
        if (push_dr) |dr| pushBuiltinParticipantCdr(self.alloc, dr, data);
    }

    const ParticipantLostFire = struct {
        guid: Guid,
        ready_cb: ?proto.ProtocolReadyCallback,
        notify: ?MatchedNotify,
        notify_quiesced: bool = false,
        // Reader-sweep (writer removal) only -- see removeMatchedWriterDeferred's
        // doc comment. Always null for the writer-sweep (reader removal) side.
        unmatched_ctx: ?*anyopaque = null,
        unmatched_fn: ?*const fn (ctx: *anyopaque, guid: Guid) void = null,
        lost: ?proto.DeferredSampleLost = null,
        // Exactly one of these two is set (matching which sweep produced
        // this entry), held from collection (under self.mu) through firing
        // (after self.mu is released) so `ready_cb`/`unmatched_fn`'s ctx --
        // pinned to its owning proto's lifetime via ready_pin, see
        // protocol/interface.zig's ProtocolReadyCallback doc comment --
        // can't be freed out from under this loop. See RemovedWriterJob.
        // proto_quiesced's matching comment in onWriterLost.
        reader_proto_quiesced: ?proto.ProtocolReader = null,
        writer_proto_quiesced: ?proto.ProtocolWriter = null,
    };

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
        // As in onWriterLost and onReaderLost, for each of its endpoints.
        self.withdrawDiscoveryGensOfLocked(guid.prefix);
        while (true) {
            var sw_it = self.settled_writers.keyIterator();
            const settled = while (sw_it.next()) |k| {
                if (k.prefix.eql(guid.prefix)) break k.*;
            } else break;
            _ = self.settled_writers.remove(settled);
        }
        self.unmatched.dropPrefix(guid.prefix);
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
        // local DataReaders so they can generate NOT_ALIVE_NO_WRITERS, and the
        // symmetric sweep for local DataWriters. The protocol-level match
        // removal itself must stay serialized under self.mu -- otherwise a
        // concurrent rediscovery of one of these same endpoints (a fresh
        // SEDP announcement processed on another thread) could re-add the
        // match in the window between releasing this lock and a deferred
        // removal call actually running, and the stale removal would
        // wrongly undo the fresh match (PR #90 review). So remove
        // immediately via removeMatchedWriterDeferred/
        // removeMatchedReaderDeferred (still under the lock, exactly like
        // the pre-restructuring code did), and only defer the resulting
        // callbacks -- which reach arbitrary application listener code and
        // must not fire while self.mu is held -- to after unlocking. Uses
        // the GUID prefix as the membership key (all endpoints of a
        // participant share its prefix).
        const prefix = guid.prefix;
        // Gates removeDiscoveredEndpointsForPrefix and the lost_writers/
        // lost_readers disposal firing below: if any reader's or writer's
        // sweep couldn't run (listing failed, or its capacity reservation
        // failed), that entity's protocol match was NOT removed, so
        // discovery state must be preserved too -- otherwise discovery
        // would forget this participant's endpoints while local readers/
        // writers keep stale matched entries with no later loss event
        // guaranteed to clean them up (this is a one-shot event: SPDP has
        // already permanently forgotten the participant by the time this
        // fires). Reporting a not-actually-removed endpoint as disposed
        // via the built-in topic would be equally inconsistent (Greptile
        // review).
        var all_swept = true;
        var reader_fires: std.ArrayListUnmanaged(ParticipantLostFire) = .empty;
        defer reader_fires.deinit(self.alloc);
        var ar_it = self.active_readers.valueIterator();
        while (ar_it.next()) |ar| {
            var w_guids: std.ArrayListUnmanaged(Guid) = .empty;
            defer w_guids.deinit(self.alloc);
            ar.proto.listMatchedWriters(self.alloc, &w_guids) catch {
                all_swept = false;
                continue;
            };
            // Reserve capacity for this reader's worst case (every matched
            // writer, not just ones matching prefix) *before* mutating
            // anything below: removeMatchedWriterDeferred's removal is not
            // reversible, so an append failing partway through would
            // silently discard an already-decided callback for a match
            // that's already gone (Greptile review). If we can't even
            // guarantee that for this one reader, skip it entirely rather
            // than partially mutate with no way to notify.
            if (reader_fires.ensureUnusedCapacity(self.alloc, w_guids.items.len)) |_| {} else |_| {
                all_swept = false;
                continue;
            }
            for (w_guids.items) |w_guid| {
                if (!w_guid.prefix.eql(prefix)) continue;
                const before = ar.proto.matchedWriterCount();
                const deferred = ar.proto.removeMatchedWriterDeferred(w_guid);
                const matched_changed = ar.proto.matchedWriterCount() < before;
                if (deferred.ready == null and deferred.unmatched_fn == null and deferred.lost == null and !matched_changed) continue;
                const notify: ?MatchedNotify = if (matched_changed) ar.matched_notify else null;
                const nq = if (notify) |cb| cb.quiesceAcquire() else false;
                // See RemovedWriterJob.proto_quiesced's comment in onWriterLost.
                const pq = ar.proto.quiesceAcquire();
                reader_fires.appendAssumeCapacity(.{
                    .guid = w_guid,
                    .ready_cb = deferred.ready,
                    .notify = notify,
                    .notify_quiesced = nq,
                    .unmatched_ctx = deferred.unmatched_ctx,
                    .unmatched_fn = deferred.unmatched_fn,
                    .lost = deferred.lost,
                    .reader_proto_quiesced = if (pq) ar.proto else null,
                });
            }
        }
        // Symmetric sweep: remove matched readers belonging to this participant
        // from all local DataWriters so they can generate on_publication_matched
        // (count decreasing) / update matched-subscription state.
        var writer_fires: std.ArrayListUnmanaged(ParticipantLostFire) = .empty;
        defer writer_fires.deinit(self.alloc);
        var aw_it = self.active_writers.valueIterator();
        while (aw_it.next()) |aw| {
            var r_guids: std.ArrayListUnmanaged(Guid) = .empty;
            defer r_guids.deinit(self.alloc);
            aw.proto.listMatchedReaders(self.alloc, &r_guids) catch {
                all_swept = false;
                continue;
            };
            // See the reader-sweep's matching comment above.
            if (writer_fires.ensureUnusedCapacity(self.alloc, r_guids.items.len)) |_| {} else |_| {
                all_swept = false;
                continue;
            }
            for (r_guids.items) |r_guid| {
                if (!r_guid.prefix.eql(prefix)) continue;
                const before = aw.proto.matchedReaderCount();
                const ready_cb = aw.proto.removeMatchedReaderDeferred(r_guid);
                const matched_changed = aw.proto.matchedReaderCount() < before;
                if (ready_cb == null and !matched_changed) continue;
                const notify: ?MatchedNotify = if (matched_changed) aw.matched_notify else null;
                const nq = if (notify) |cb| cb.quiesceAcquire() else false;
                // See RemovedWriterJob.proto_quiesced's comment in onWriterLost.
                const pq = aw.proto.quiesceAcquire();
                writer_fires.appendAssumeCapacity(.{
                    .guid = r_guid,
                    .ready_cb = ready_cb,
                    .notify = notify,
                    .notify_quiesced = nq,
                    .writer_proto_quiesced = if (pq) aw.proto else null,
                });
            }
        }
        if (all_swept) removeDiscoveredEndpointsForPrefix(self, prefix);
        self.mu.unlock();

        for (reader_fires.items) |fire| {
            if (fire.lost) |l| l.on_lost(l.ctx, l.count);
            if (fire.ready_cb) |cb| cb.on_ready(cb.ctx, fire.guid, false);
            if (fire.unmatched_fn) |f| f(fire.unmatched_ctx.?, fire.guid);
            if (fire.notify) |cb| if (fire.notify_quiesced) cb.notify(cb.ctx, writer_mod.guidToHandle(fire.guid), false);
            if (fire.notify_quiesced) fire.notify.?.quiesceRelease();
            if (fire.reader_proto_quiesced) |p| p.quiesceRelease();
        }
        for (writer_fires.items) |fire| {
            if (fire.ready_cb) |cb| cb.on_ready(cb.ctx, fire.guid, false);
            if (fire.notify) |cb| if (fire.notify_quiesced) cb.notify(cb.ctx, writer_mod.guidToHandle(fire.guid), false);
            if (fire.notify_quiesced) fire.notify.?.quiesceRelease();
            if (fire.writer_proto_quiesced) |p| p.quiesceRelease();
        }
        if (all_swept) {
            if (publication_dr) |dr| for (lost_writers.items) |endpoint_guid|
                pushBuiltinEndpointDisposed(dr, endpoint_guid);
            if (subscription_dr) |dr| for (lost_readers.items) |endpoint_guid|
                pushBuiltinEndpointDisposed(dr, endpoint_guid);
        }
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

    /// RTPS wire `Duration_t` → nanoseconds; 0 for INFINITE / absent (the
    /// callers treat 0 as "no expiry tracking").
    fn wireDurExpiryNs(od: ?disc.wire.Duration_t) i64 {
        const d = od orelse return 0;
        const rd = time_mod.RtpsDuration{ .seconds = d.seconds, .fraction = d.fraction };
        if (rd.isInfinite()) return 0;
        const dd = rd.toDuration();
        return @as(i64, dd.sec) * std.time.ns_per_s + @as(i64, dd.nanosec);
    }

    fn buildMatchedWriterInfo(
        guid: Guid,
        qos: *const disc.DiscoveredWriterData,
        unicast_locators: []const Locator,
        multicast_locators: []const Locator,
    ) proto.MatchedWriterInfo {
        const lease_ns: i64 = if (qos.liveliness) |l| wireDurExpiryNs(l.lease_duration) else 0;
        const lifespan_ns: i64 = wireDurExpiryNs(qos.lifespan);
        // Wire reliability is 1-based: 2 = RELIABLE.
        const reliable = qos.reliability.kind >= 2;
        return .{
            .guid = guid,
            .unicast_locators = unicast_locators,
            .multicast_locators = multicast_locators,
            .reliability = if (reliable) .reliable else .best_effort,
            .ownership_strength = qos.ownershipStrength orelse 0,
            .liveliness_lease_ns = lease_ns,
            .liveliness_kind = if (qos.liveliness) |l| @intCast(l.kind) else 0,
            .lifespan_ns = lifespan_ns,
            .history_expected = qos.durabilityKind > 0 and reliable,
            .group_coherent = if (qos.presentation) |pr| pr.coherent_access and pr.access_scope == 2 else false,
            .publisher_guid = publisherGuid(guid, qos),
        };
    }

    /// See MatchedWriterInfo.publisher_guid.
    fn publisherGuid(writer: Guid, qos: *const disc.DiscoveredWriterData) Guid {
        if (qos.groupGuid) |gg| return .{
            .prefix = .{ .bytes = gg[0..12].* },
            .entity_id = .{ .entity_key = gg[12..15].*, .entity_kind = gg[15] },
        };
        var g = Guid{ .prefix = writer.prefix, .entity_id = std.mem.zeroes(guid_mod.EntityId) };
        if (qos.groupEntityId) |ge| g.entity_id = .{ .entity_key = ge[0..3].*, .entity_kind = ge[3] };
        return g;
    }

    const MatchedWriterJob = struct {
        proto: proto.ProtocolReader,
        info: proto.MatchedWriterInfo,
        notify: ?MatchedNotify,
        notify_quiesced: bool = false,
    };

    /// Assigns remote endpoint `guid` a new discovery generation, for the
    /// match decisions an announcement of it makes.  Null out of memory: it
    /// then has none, and no match of it is made until it is announced
    /// again.  Caller holds self.mu.
    fn newDiscoveryGenLocked(self: *Self, guid: Guid) ?u64 {
        self.last_discovery_gen += 1;
        const gen = self.last_discovery_gen;
        self.discovery_gens_mu.lock();
        defer self.discovery_gens_mu.unlock();
        self.discovery_gens.put(self.alloc, guid, gen) catch {
            _ = self.discovery_gens.remove(guid);
            return null;
        };
        return gen;
    }

    /// Withdraws the discovery generation of endpoint `guid`, a remote one
    /// lost or a local one deleted: a match of it decided before is not
    /// installed.  Caller holds self.mu.
    fn withdrawDiscoveryGenLocked(self: *Self, guid: Guid) void {
        self.discovery_gens_mu.lock();
        defer self.discovery_gens_mu.unlock();
        _ = self.discovery_gens.remove(guid);
    }

    /// withdrawDiscoveryGenLocked for every endpoint of participant `prefix`.
    fn withdrawDiscoveryGensOfLocked(self: *Self, prefix: GuidPrefix) void {
        self.discovery_gens_mu.lock();
        defer self.discovery_gens_mu.unlock();
        while (true) {
            var it = self.discovery_gens.keyIterator();
            const lost = while (it.next()) |k| {
                if (k.prefix.eql(prefix)) break k.*;
            } else break;
            _ = self.discovery_gens.remove(lost);
        }
    }

    /// Gives the local endpoint `guid` a generation, unless it has one.
    /// Caller holds self.mu.
    fn ensureLocalGenLocked(self: *Self, guid: Guid) !void {
        self.discovery_gens_mu.lock();
        defer self.discovery_gens_mu.unlock();
        const gop = try self.discovery_gens.getOrPut(self.alloc, guid);
        if (gop.found_existing) return;
        self.last_discovery_gen += 1;
        gop.value_ptr.* = self.last_discovery_gen;
    }

    /// Gives the local endpoint `guid` a new generation, in place of the
    /// one `ensureLocalGenLocked` gave it, for a change committed to it: a
    /// match decided before is not made. Caller holds self.mu.
    fn renewLocalGenLocked(self: *Self, guid: Guid) void {
        self.last_discovery_gen += 1;
        self.discovery_gens_mu.lock();
        defer self.discovery_gens_mu.unlock();
        if (self.discovery_gens.getPtr(guid)) |g| g.* = self.last_discovery_gen;
    }

    /// Endpoint `guid`'s current discovery generation, if any.
    /// Caller holds self.mu.
    fn currentDiscoveryGenLocked(self: *Self, guid: Guid) ?u64 {
        self.discovery_gens_mu.lock();
        defer self.discovery_gens_mu.unlock();
        return self.discovery_gens.get(guid);
    }

    fn isDiscoveryGenCurrent(ctx: *anyopaque, guid: Guid, gen: u64) bool {
        const self = cast(ctx);
        self.discovery_gens_mu.lock();
        defer self.discovery_gens_mu.unlock();
        return self.discovery_gens.get(guid) == gen;
    }

    /// A match decision's currency: made only while `gen`, the remote
    /// endpoint's, and the local endpoint `local`'s generation now are
    /// current. Caller holds self.mu.
    fn matchCurrency(self: *Self, gen: u64, local: Guid) proto.MatchCurrency {
        return .{
            .ctx = self,
            .generation = gen,
            .local = if (self.currentDiscoveryGenLocked(local)) |lg| .{ .guid = local, .generation = lg } else null,
            .is_current = isDiscoveryGenCurrent,
        };
    }

    /// `writer` is settled, if `gen` (its announcement's discovery
    /// generation; null when it decided no match) is still current:
    /// every local reader that matches it has, and has taken what was held
    /// from it, so that is dropped and nothing more is held.  An older
    /// announcement finishing after a newer one, or after the writer's loss,
    /// settles nothing: the newer one, or the writer's return, does.
    /// Caller holds self.mu.
    fn settleWriterLocked(self: *Self, writer: Guid, gen: ?u64) void {
        if (gen) |g| if (self.currentDiscoveryGenLocked(writer) != g) return;
        // Out of memory, it stays unsettled: what is held from it expires.
        self.settled_writers.put(self.alloc, writer, {}) catch {};
        self.unmatched.dropWriter(writer);
    }

    /// Whether a change was committed to the local endpoint of one of
    /// `jobs`' match decisions since it was decided (see
    /// `renewLocalGenLocked`): its match may then not have been made.
    /// Caller holds self.mu.
    fn localChangedSinceLocked(self: *Self, jobs: []const MatchedWriterJob) bool {
        for (jobs) |job| {
            const l = (job.info.currency orelse continue).local orelse continue;
            if (self.currentDiscoveryGenLocked(l.guid) != l.generation) return true;
        }
        return false;
    }

    /// Where `ar` takes what a writer it matches sent before the match.
    fn prematchFor(self: *Self, ar: *const ActiveReader) unmatched_mod.Prematch {
        return .{
            .cache = &self.unmatched,
            .key_hash_ctx = ar.key_hash_ctx,
            .key_hash_fn = ar.key_hash_fn,
            .key_hash_only_fn = ar.key_hash_only_fn,
        };
    }

    fn onWriterDiscovered(ctx: *anyopaque, data: *const disc.WriterData) void {
        const self = cast(ctx);
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        var jobs: std.ArrayListUnmanaged(MatchedWriterJob) = .empty;
        defer jobs.deinit(self.alloc);
        self.mu.lock();
        for (self.ignored_prefixes.items) |p| {
            if (p.eql(data.guid.prefix)) {
                self.settleWriterLocked(data.guid, null);
                self.mu.unlock();
                return;
            }
        }
        const pub_handle = writer_mod.guidToHandle(data.guid);
        for (self.ignored_publication_handles.items) |h| {
            if (h == pub_handle) {
                self.settleWriterLocked(data.guid, null);
                self.mu.unlock();
                return;
            }
        }
        for (self.ignored_topic_names.items) |n| {
            if (std.mem.eql(u8, n, data.topic_name)) {
                self.settleWriterLocked(data.guid, null);
                self.mu.unlock();
                return;
            }
        }
        // Each match below is installed only while this is the writer's
        // current generation. Unless settled already, data from the writer
        // is held until every match below is made (see settleWriterLocked).
        const gen = self.newDiscoveryGenLocked(data.guid);
        // A refresh a matched reader no longer matches unmatches it, as a
        // loss does for that reader. Room is made first, as in onWriterLost;
        // without it, no match is removed.
        var removed: std.ArrayListUnmanaged(RemovedWriterJob) = .empty;
        defer removed.deinit(self.alloc);
        const can_unmatch = if (removed.ensureTotalCapacityPrecise(self.alloc, self.active_readers.count())) |_| true else |_| false;
        var ar_it = self.active_readers.valueIterator();
        while (ar_it.next()) |ar| {
            if (!std.mem.eql(u8, ar.topic_name, data.topic_name)) continue;
            if (!std.mem.eql(u8, ar.type_name, data.type_name)) continue;
            // Entity::enable(): symmetric to onReaderDiscovered's identical
            // guard -- a reader created disabled never sent its own SEDP
            // announcement, so matching it against a discovered writer here
            // would be premature. A reader whose matched_notify is not yet
            // registered is still inside create_datareader: skip it too, as
            // its announce does the match once registered. Matching it here
            // would add the RTPS match with no notify, and the announce's
            // add would then be a refresh, so on_subscription_matched and
            // the matched count would never report it. matched_notify.ctx is
            // always a *DataReaderImpl (see subscriber.zig's
            // register_matched_notify call site).
            const reader_notify = ar.matched_notify orelse continue;
            const dr_ptr: *reader_mod.DataReaderImpl = @ptrCast(@alignCast(reader_notify.ctx));
            if (!dr_ptr.enabled.load(.acquire)) continue;
            const local_rd = disc_adapter.readerDiscoveredData(ar.qos, ar.presentation);
            const result = qm_mod.checkDiscovered(data.qos, &local_rd);
            if (!result.isCompatible()) {
                ar.incompat_pending.record(result.incompatible);
                if (can_unmatch) unmatchWriterLocked(ar, data.guid, &removed);
                continue;
            }
            const part_result = qm_mod.checkPartition(data.partition_names, ar.partition_names);
            if (!part_result.isCompatible()) {
                if (can_unmatch) unmatchWriterLocked(ar, data.guid, &removed);
                continue;
            }
            const g = gen orelse continue;
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
            var info = buildMatchedWriterInfo(data.guid, data.qos, data.unicast_locators, data.multicast_locators);
            info.prematch = self.prematchFor(ar);
            info.currency = self.matchCurrency(g, ar.guid);
            const nq = if (ar.matched_notify) |cb| cb.quiesceAcquire() else false;
            jobs.append(self.alloc, .{ .proto = ar.proto, .info = info, .notify = ar.matched_notify, .notify_quiesced = nq }) catch {
                ar.proto.quiesceRelease();
                if (nq) ar.matched_notify.?.quiesceRelease();
            };
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
                .reliability_kind = disc.discReliabilityKind(data.qos),
                .durability_kind = disc.discDurabilityKind(data.qos),
                .liveliness_kind = disc.discLivelinessKind(data.qos),
                .ownership_kind = disc.discOwnershipKind(data.qos),
                .dest_order_kind = disc.discDestOrderKind(data.qos),
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
        fireRemovedWriterJobs(removed.items, data.guid);
        self.raiseIncompatQos(.readers);
        for (jobs.items) |job| {
            // Only a new protocol-level match changes the matched status:
            // discovery can report an already matched pair again, which
            // just refreshes the proxy. A match superseded since (by the
            // writer's loss or a newer announcement) is not made.
            const added = job.proto.addMatchedWriter(&job.info) catch false;
            if (job.notify) |cb| if (job.notify_quiesced) {
                if (added) cb.notify(cb.ctx, writer_mod.guidToHandle(data.guid), true);
                cb.quiesceRelease();
            };
            job.proto.quiesceRelease();
        }
        self.mu.lock();
        // A match a change to its reader superseded took nothing: what is
        // held stays for the match the reader's own announcement makes in
        // its place, until it expires or the writer is announced again.
        if (!self.localChangedSinceLocked(jobs.items)) self.settleWriterLocked(data.guid, gen);
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

    const RemovedWriterJob = struct {
        ready_cb: ?proto.ProtocolReadyCallback,
        notify: ?MatchedNotify,
        notify_quiesced: bool = false,
        unmatched_ctx: ?*anyopaque = null,
        unmatched_fn: ?*const fn (ctx: *anyopaque, guid: Guid) void = null,
        lost: ?proto.DeferredSampleLost = null,
        /// Held from collection (still under self.mu, so `ar.proto` -- and,
        /// via its `ready_pin`, the DataReaderImpl `ready_cb`/`unmatched_fn`
        /// resolve into -- are both provably alive) through firing below
        /// (after self.mu is released, since firing can reach arbitrary
        /// application listener code). Only set when `ready_cb` or
        /// `unmatched_fn` is non-null; `notify`'s own DataReaderImpl/
        /// DataWriterImpl target is pinned separately via
        /// MatchedNotify.quiesceAcquire/notify_quiesced above. Mirrors
        /// onWriterDiscovered's existing `job.proto`/`quiesceRelease`
        /// pattern -- see protocol/interface.zig's ProtocolReadyCallback
        /// doc comment for why this is needed at all (a real
        /// heap-use-after-free, caught by TSan in the "listener" stress
        /// scenario).
        proto_quiesced: ?proto.ProtocolReader = null,
    };

    fn onWriterLost(ctx: *anyopaque, guid: disc.Guid) void {
        const self = cast(ctx);
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        // The protocol-level match removal itself must stay serialized
        // under self.mu -- otherwise a concurrent rediscovery of this same
        // writer (a fresh SEDP announcement processed on another thread)
        // could re-add the match in the window between releasing this lock
        // and a deferred removal call actually running, and the stale
        // removal would wrongly undo the fresh match (PR #90 review). So
        // remove immediately via removeMatchedWriterDeferred (still under
        // the lock, exactly like the pre-restructuring code did), and only
        // defer the resulting callbacks -- which reach arbitrary
        // application listener code and must not fire while self.mu is
        // held -- to after unlocking.
        var jobs: std.ArrayListUnmanaged(RemovedWriterJob) = .empty;
        defer jobs.deinit(self.alloc);
        self.mu.lock();
        // First, so a match of it made before but not yet installed is not.
        self.withdrawDiscoveryGenLocked(guid);
        // Reserve capacity for every possible job *before* mutating any
        // state below: removeMatchedWriterDeferred's removal is not
        // reversible, so an append failing partway through the loop would
        // silently discard an already-decided callback for a match that's
        // already gone (Greptile review) -- with capacity reserved
        // upfront, appendAssumeCapacity below cannot fail. Bounded by
        // active_readers.count() (every reader, not just ones matching
        // this guid, so always sufficient). On the (extremely unlikely)
        // reservation failure itself, skip the whole sweep rather than
        // partially mutate with no way to notify -- consistent with this
        // function's other OOM-tolerance fallbacks.
        //
        // `swept` additionally gates removeDiscoveredWriter/
        // pushBuiltinEndpointDisposed below: if the reservation failed, no
        // reader's protocol match was actually removed, so discovery
        // state must stay as-is too -- otherwise discovery would forget
        // this writer while every local reader keeps a stale matched-
        // writer entry that nothing will ever clean up (Greptile review).
        const swept = if (jobs.ensureTotalCapacityPrecise(self.alloc, self.active_readers.count())) |_| blk: {
            var ar_it2 = self.active_readers.valueIterator();
            while (ar_it2.next()) |ar| unmatchWriterLocked(ar, guid, &jobs);
            break :blk true;
        } else |_| false;
        if (swept) removeDiscoveredWriter(self, guid);
        // Should it come back, data from it is held again until it is
        // matched again.
        _ = self.settled_writers.remove(guid);
        self.unmatched.dropWriter(guid);
        if (self.builtin_sub) |bs| push_dr = bs.pub_dr;
        self.mu.unlock();

        fireRemovedWriterJobs(jobs.items, guid);
        if (swept) if (push_dr) |dr| pushBuiltinEndpointDisposed(dr, guid);
    }

    /// Removes the remote writer `guid`'s match from the local reader `ar`
    /// now, and adds the callbacks the removal produces to `jobs`, which has
    /// room, for `fireRemovedWriterJobs` once `mu` is released. With `mu`
    /// held.
    fn unmatchWriterLocked(ar: *ActiveReader, guid: Guid, jobs: *std.ArrayListUnmanaged(RemovedWriterJob)) void {
        const before = ar.proto.matchedWriterCount();
        const deferred = ar.proto.removeMatchedWriterDeferred(guid);
        const matched_changed = ar.proto.matchedWriterCount() < before;
        if (deferred.ready == null and deferred.unmatched_fn == null and deferred.lost == null and !matched_changed) return;
        const notify: ?MatchedNotify = if (matched_changed) ar.matched_notify else null;
        const nq = if (notify) |cb| cb.quiesceAcquire() else false;
        // ar.proto is provably still alive and not yet tearing
        // down here (its removal from active_readers requires
        // self.mu, which this thread holds), so this can't fail
        // in practice; still handled defensively rather than
        // asserted -- see RemovedWriterJob.proto_quiesced's doc
        // comment for why this is needed at all.
        const pq = ar.proto.quiesceAcquire();
        jobs.appendAssumeCapacity(.{
            .ready_cb = deferred.ready,
            .notify = notify,
            .notify_quiesced = nq,
            .unmatched_ctx = deferred.unmatched_ctx,
            .unmatched_fn = deferred.unmatched_fn,
            .lost = deferred.lost,
            .proto_quiesced = if (pq) ar.proto else null,
        });
    }

    /// Fires what `unmatchWriterLocked` collected, with `mu` released.
    fn fireRemovedWriterJobs(jobs: []const RemovedWriterJob, guid: Guid) void {
        const remote_handle = writer_mod.guidToHandle(guid);
        for (jobs) |job| {
            if (job.lost) |l| l.on_lost(l.ctx, l.count);
            if (job.ready_cb) |cb| cb.on_ready(cb.ctx, guid, false);
            if (job.unmatched_fn) |f| f(job.unmatched_ctx.?, guid);
            if (job.notify) |cb| if (job.notify_quiesced) cb.notify(cb.ctx, remote_handle, false);
            if (job.notify_quiesced) job.notify.?.quiesceRelease();
            if (job.proto_quiesced) |p| p.quiesceRelease();
        }
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
        qos: *const disc.DiscoveredReaderData,
        unicast_locators: []const Locator,
        multicast_locators: []const Locator,
    ) proto.MatchedReaderInfo {
        const vendor = self.vendorIdForPrefixLocked(guid.prefix);
        const needs_marker = if (vendor) |vid| header_mod.needsPidCoherentSetMarker(vid) else false;
        return .{
            .guid = guid,
            .unicast_locators = unicast_locators,
            .multicast_locators = multicast_locators,
            .expects_inline_qos = false,
            .reliability = if (qos.reliability.kind >= 2) .reliable else .best_effort,
            .durability_kind = @intCast(qos.durabilityKind),
            .needs_pid_coherent_set_marker = needs_marker,
        };
    }

    const MatchedReaderJob = struct {
        proto: proto.ProtocolWriter,
        info: proto.MatchedReaderInfo,
        notify: ?MatchedNotify,
        notify_quiesced: bool = false,
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
        // As in onWriterDiscovered.
        const gen = self.newDiscoveryGenLocked(data.guid);
        var removed: std.ArrayListUnmanaged(RemovedReaderJob) = .empty;
        defer removed.deinit(self.alloc);
        const can_unmatch = if (removed.ensureTotalCapacityPrecise(self.alloc, self.active_writers.count())) |_| true else |_| false;
        var aw_it = self.active_writers.valueIterator();
        while (aw_it.next()) |aw| {
            if (!std.mem.eql(u8, aw.topic_name, data.topic_name)) continue;
            if (!std.mem.eql(u8, aw.type_name, data.type_name)) continue;
            // Entity::enable(): a writer created disabled (ENTITY_FACTORY QoS)
            // never sent its own SEDP announcement, so a remote reader has no
            // way to know it exists -- matching against it here anyway would
            // fire on_publication_matched (and even addMatchedReader an RTPS
            // proxy) for a writer the peer can't possibly be aware of. The
            // writer's own deferred announce (see publisher.zig's
            // announceDataWriter, called from vtEnable) already does the
            // right retroactive match once actually enabled -- this is purely
            // a guard against matching too early, not a second matching path.
            // The same applies to a writer whose matched_notify is not yet
            // registered (still inside create_datawriter): matching it here
            // would add the RTPS match with no notify, and the announce's add
            // would then be a refresh, so on_publication_matched and the
            // matched count would never report it. matched_notify.ctx is
            // always a *DataWriterImpl (see publisher.zig's
            // register_matched_notify call site).
            const writer_notify = aw.matched_notify orelse continue;
            const dw_ptr: *writer_mod.DataWriterImpl = @ptrCast(@alignCast(writer_notify.ctx));
            if (!dw_ptr.enabled.load(.acquire)) continue;
            const local_wd = disc_adapter.writerDiscoveredData(aw.qos, aw.presentation);
            const result = qm_mod.checkDiscovered(&local_wd, data.qos);
            if (!result.isCompatible()) {
                aw.incompat_pending.record(result.incompatible);
                if (can_unmatch) unmatchReaderLocked(aw, data.guid, &removed);
                continue;
            }
            const part_result = qm_mod.checkPartition(aw.partition_names, data.partition_names);
            if (!part_result.isCompatible()) {
                if (can_unmatch) unmatchReaderLocked(aw, data.guid, &removed);
                continue;
            }
            const g = gen orelse continue;
            // See onWriterDiscovered's matching comment: defer the actual
            // addMatchedReader (and its initial HEARTBEAT/replay send)
            // until after self.mu is released below.
            if (!aw.proto.quiesceAcquire()) continue;
            var info = self.buildMatchedReaderInfo(data.guid, data.qos, data.unicast_locators, data.multicast_locators);
            info.currency = self.matchCurrency(g, aw.guid);
            const nq = if (aw.matched_notify) |cb| cb.quiesceAcquire() else false;
            jobs.append(self.alloc, .{ .proto = aw.proto, .info = info, .notify = aw.matched_notify, .notify_quiesced = nq }) catch {
                aw.proto.quiesceRelease();
                if (nq) aw.matched_notify.?.quiesceRelease();
            };
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
                .reliability_kind = disc.discReliabilityKind(data.qos),
                .durability_kind = disc.discDurabilityKind(data.qos),
                .liveliness_kind = disc.discLivelinessKind(data.qos),
                .ownership_kind = disc.discOwnershipKind(data.qos),
                .dest_order_kind = disc.discDestOrderKind(data.qos),
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
        fireRemovedReaderJobs(removed.items, data.guid);
        self.raiseIncompatQos(.writers);
        for (jobs.items) |job| {
            // Only a new protocol-level match changes the matched status:
            // discovery can report an already matched pair again, which
            // just refreshes the proxy.
            const added = job.proto.addMatchedReader(&job.info) catch false;
            if (job.notify) |cb| if (job.notify_quiesced) {
                if (added) cb.notify(cb.ctx, writer_mod.guidToHandle(data.guid), true);
                cb.quiesceRelease();
            };
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

    const RemovedReaderJob = struct {
        ready_cb: ?proto.ProtocolReadyCallback,
        notify: ?MatchedNotify,
        notify_quiesced: bool = false,
        /// See RemovedWriterJob.proto_quiesced.
        proto_quiesced: ?proto.ProtocolWriter = null,
    };

    fn onReaderLost(ctx: *anyopaque, guid: disc.Guid) void {
        const self = cast(ctx);
        var push_dr: ?*reader_mod.DataReaderImpl = null;
        // As onWriterLost: the protocol-level removal stays under self.mu,
        // and the callbacks it produces (on_publication_matched,
        // on_reliable_reader_ready), which reach application code, fire after
        // it is released. Capacity is reserved first so a decided callback is
        // never dropped; on that reservation failing nothing is removed.
        var jobs: std.ArrayListUnmanaged(RemovedReaderJob) = .empty;
        defer jobs.deinit(self.alloc);
        self.mu.lock();
        // As onWriterLost.
        self.withdrawDiscoveryGenLocked(guid);
        const swept = if (jobs.ensureTotalCapacityPrecise(self.alloc, self.active_writers.count())) |_| blk: {
            var aw_it = self.active_writers.valueIterator();
            while (aw_it.next()) |aw| unmatchReaderLocked(aw, guid, &jobs);
            break :blk true;
        } else |_| false;
        if (swept) removeDiscoveredReader(self, guid);
        if (self.builtin_sub) |bs| push_dr = bs.sub_dr;
        self.mu.unlock();

        fireRemovedReaderJobs(jobs.items, guid);
        if (swept) if (push_dr) |dr| pushBuiltinEndpointDisposed(dr, guid);
    }

    /// `unmatchWriterLocked`, for the remote reader `guid` and the local
    /// writer `aw`.
    fn unmatchReaderLocked(aw: *ActiveWriter, guid: Guid, jobs: *std.ArrayListUnmanaged(RemovedReaderJob)) void {
        const before = aw.proto.matchedReaderCount();
        const ready_cb = aw.proto.removeMatchedReaderDeferred(guid);
        const matched_changed = aw.proto.matchedReaderCount() < before;
        if (ready_cb == null and !matched_changed) return;
        const notify: ?MatchedNotify = if (matched_changed) aw.matched_notify else null;
        const nq = if (notify) |cb| cb.quiesceAcquire() else false;
        const pq = aw.proto.quiesceAcquire();
        jobs.appendAssumeCapacity(.{
            .ready_cb = ready_cb,
            .notify = notify,
            .notify_quiesced = nq,
            .proto_quiesced = if (pq) aw.proto else null,
        });
    }

    /// `fireRemovedWriterJobs`, for `unmatchReaderLocked`.
    fn fireRemovedReaderJobs(jobs: []const RemovedReaderJob, guid: Guid) void {
        const remote_handle = writer_mod.guidToHandle(guid);
        for (jobs) |job| {
            if (job.ready_cb) |cb| cb.on_ready(cb.ctx, guid, false);
            if (job.notify) |cb| if (job.notify_quiesced) cb.notify(cb.ctx, remote_handle, false);
            if (job.notify_quiesced) job.notify.?.quiesceRelease();
            if (job.proto_quiesced) |p| p.quiesceRelease();
        }
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
        const qos = data.qos.clone(alloc) catch {
            alloc.free(tt);
            alloc.free(tn);
            return null;
        };
        const pn = dupePartitionNames(alloc, data.partition_names);
        return .{
            .guid = data.guid,
            .topic_name = tn,
            .type_name = tt,
            .qos = qos,
            .partition_names = pn,
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
        const qos = data.qos.clone(alloc) catch {
            alloc.free(tt);
            alloc.free(tn);
            return null;
        };
        const pn = dupePartitionNames(alloc, data.partition_names);
        return .{
            .guid = data.guid,
            .topic_name = tn,
            .type_name = tt,
            .qos = qos,
            .partition_names = pn,
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
        for (self.discovered_writers.items, 0..) |*dw, i| {
            if (dw.guid.eql(guid)) {
                dw.deinit(self.alloc);
                _ = self.discovered_writers.swapRemove(i);
                return;
            }
        }
    }

    /// Must be called with self.mu held.
    fn removeDiscoveredReader(self: *Self, guid: Guid) void {
        for (self.discovered_readers.items, 0..) |*dr, i| {
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

    /// `dupePartitionNames`, failing rather than dropping the names.
    fn dupePartitionNamesOrFail(alloc: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
        if (names.len == 0) return &.{};
        const copy = try alloc.alloc([]const u8, names.len);
        for (copy, names, 0..) |*dst, src, i| {
            dst.* = alloc.dupe(u8, src) catch |err| {
                for (copy[0..i]) |s| alloc.free(s);
                alloc.free(copy);
                return err;
            };
        }
        return copy;
    }

    fn partitionNamesEql(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

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

    /// The matches a local endpoint's refresh removes, each with its remote
    /// endpoint, for firing their callbacks once `mu` is released.
    fn Removals(comptime Job: type) type {
        return struct {
            jobs: std.ArrayListUnmanaged(Job) = .empty,
            remotes: std.ArrayListUnmanaged(Guid) = .empty,

            /// Room for `n`; false without it.
            fn reserve(self: *@This(), alloc: std.mem.Allocator, n: usize) bool {
                self.jobs.ensureTotalCapacityPrecise(alloc, n) catch return false;
                self.remotes.ensureTotalCapacityPrecise(alloc, n) catch return false;
                return true;
            }

            /// Removes the remote reader `guid`'s match from `aw`. Returns
            /// whether there was one. With `mu` held.
            fn unmatchReaderLocked(self: *@This(), aw: *ActiveWriter, guid: Guid) bool {
                const before = self.jobs.items.len;
                Self.unmatchReaderLocked(aw, guid, &self.jobs);
                return self.recorded(before, guid);
            }

            /// `unmatchReaderLocked`, for the remote writer `guid` and `ar`.
            fn unmatchWriterLocked(self: *@This(), ar: *ActiveReader, guid: Guid) bool {
                const before = self.jobs.items.len;
                Self.unmatchWriterLocked(ar, guid, &self.jobs);
                return self.recorded(before, guid);
            }

            fn recorded(self: *@This(), before: usize, guid: Guid) bool {
                if (self.jobs.items.len == before) return false;
                self.remotes.appendAssumeCapacity(guid);
                return true;
            }

            fn fire(self: *@This(), comptime fireJobs: fn ([]const Job, Guid) void) void {
                for (self.jobs.items, self.remotes.items, 0..) |_, guid, i| fireJobs(self.jobs.items[i .. i + 1], guid);
            }

            fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
                self.jobs.deinit(alloc);
                self.remotes.deinit(alloc);
            }
        };
    }

    const AnnounceMatchedReaderJob = struct {
        proto: proto.ProtocolWriter,
        info: proto.MatchedReaderInfo,
        notify: ?MatchedNotify,
        notify_quiesced: bool = false,
        remote_guid: Guid,
        unicast_locs: []const Locator,
        multicast_locs: []const Locator,
    };

    /// A local endpoint whose announcement is being committed to discovery
    /// (docs/design/concurrency/architecture.md#local-endpoint-publication-announcement-and-disposal).
    const Announcing = struct {
        guid: Guid,
        count: u32,
        /// It was deleted meanwhile: the last commit disposes of it, after
        /// itself, so no announcement follows its disposal.
        dispose: bool = false,
        /// A commit is writing its announcement (`commitAnnouncement`).
        writing: bool = false,
        /// Another commit began meanwhile: the one writing writes again.
        again: bool = false,
    };

    /// Makes room in `announcing` for every local endpoint. With `mu` held.
    fn reserveAnnouncingLocked(self: *Self) !void {
        const n = self.announcing.items.len + self.active_writers.count() + self.active_readers.count();
        try self.announcing.ensureTotalCapacity(self.alloc, n);
    }

    /// Records a commit of `guid`'s announcement as under way. With `mu` held.
    fn beginAnnouncingLocked(self: *Self, guid: Guid) void {
        for (self.announcing.items) |*a| if (a.guid.eql(guid)) {
            a.count += 1;
            return;
        };
        self.announcing.appendAssumeCapacity(.{ .guid = guid, .count = 1 });
    }

    /// Ends a commit of `guid`'s announcement. Returns whether the endpoint
    /// was deleted meanwhile and its disposal now falls to the caller.
    fn finishAnnouncing(self: *Self, guid: Guid) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.announcing.items, 0..) |*a, i| if (a.guid.eql(guid)) {
            a.count -= 1;
            if (a.count > 0) return false;
            const dispose = a.dispose;
            _ = self.announcing.swapRemove(i);
            return dispose;
        };
        return false;
    }

    /// Has discovery write `guid`'s announcement, then ends the commit
    /// (`finishAnnouncing`). One commit of an endpoint writes at a time, so
    /// discovery writes what was adopted last, last: one begun while
    /// another writes leaves it to write again, once done, rather than wait,
    /// which a listener the write re-enters could not.
    fn commitAnnouncement(self: *Self, comptime kind: enum { writer, reader }, guid: Guid) void {
        if (self.claimWrite(guid)) while (true) {
            switch (kind) {
                .writer => self.discovery.announceWriter(guid),
                .reader => self.discovery.announceReader(guid),
            }
            if (!self.writeAgain(guid)) break;
        };
        if (self.finishAnnouncing(guid)) self.retractDeleted(switch (kind) {
            .writer => .writer,
            .reader => .reader,
        }, guid);
    }

    /// Whether this commit of `guid` writes its announcement; otherwise the
    /// one writing writes again.
    fn claimWrite(self: *Self, guid: Guid) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const a = self.announcingLocked(guid);
        if (a.writing) {
            a.again = true;
            return false;
        }
        a.writing = true;
        return true;
    }

    /// Whether a commit of `guid` began while this one wrote, which it then
    /// writes for; otherwise it is done writing.
    fn writeAgain(self: *Self, guid: Guid) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const a = self.announcingLocked(guid);
        if (a.again) {
            a.again = false;
            return true;
        }
        a.writing = false;
        return false;
    }

    /// The commit under way of `guid`'s announcement. With `mu` held.
    fn announcingLocked(self: *Self, guid: Guid) *Announcing {
        for (self.announcing.items) |*a| if (a.guid.eql(guid)) return a;
        unreachable;
    }

    /// For the deletion of `guid`: leaves its disposal to a commit of its
    /// announcement under way, if there is one. With `mu` held.
    fn handOffDisposalLocked(self: *Self, guid: Guid) bool {
        for (self.announcing.items) |*a| if (a.guid.eql(guid)) {
            a.dispose = true;
            return true;
        };
        return false;
    }

    /// Disposes of the deleted local endpoint `guid` once no preparation
    /// of its announcement is under way, so none is left behind.
    fn retractDeleted(self: *Self, comptime kind: enum { writer, reader }, guid: Guid) void {
        self.prepare_mu.lock();
        self.prepare_mu.unlock();
        switch (kind) {
            .writer => self.discovery.retractWriter(guid),
            .reader => self.discovery.retractReader(guid),
        }
    }

    const EndpointKind = enum { writer, reader };

    fn QosOf(comptime kind: EndpointKind) type {
        return switch (kind) {
            .writer => DDS.DataWriterQos,
            .reader => DDS.DataReaderQos,
        };
    }

    fn AnnouncementOf(comptime kind: EndpointKind) type {
        return switch (kind) {
            .writer => disc.WriterAnnouncement,
            .reader => disc.ReaderAnnouncement,
        };
    }

    /// What preparing endpoints' announcements changes; null keeps the
    /// endpoint's own.
    fn Change(comptime kind: EndpointKind) type {
        return struct {
            qos: ?*const QosOf(kind) = null,
            partition_names: ?[]const []const u8 = null,
            presentation: ?DDS.PresentationQosPolicy = null,
        };
    }

    /// An endpoint's announcement being prepared, with what the endpoint
    /// takes once it is.
    fn Staged(comptime kind: EndpointKind) type {
        return struct {
            guid: Guid,
            ann: AnnouncementOf(kind),
            partition_names: ?[]const []const u8,
            presentation: DDS.PresentationQosPolicy,
            qos: ?QosOf(kind),

            fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
                self.ann.deinit(alloc);
                if (self.partition_names) |n| freePartitionNames(alloc, n);
                if (self.qos) |*q| freeOwnedQos(alloc, q);
            }
        };
    }

    /// A copy of an endpoint's `qos` owning what the caller only lends.
    fn ownQos(alloc: std.mem.Allocator, qos: anytype) !@TypeOf(qos) {
        var owned = qos;
        owned.data_representation.value = try qos.data_representation.value.clone(alloc);
        errdefer owned.data_representation.value.deinit(alloc);
        owned.user_data = try cloneUserData(alloc, qos.user_data);
        return owned;
    }

    fn freeOwnedQos(alloc: std.mem.Allocator, qos: anytype) void {
        qos.data_representation.value.deinit(alloc);
        freeUserData(alloc, qos.user_data);
    }

    /// PID_GROUP_GUID of a GROUP-scope coherent Publisher's writers: all
    /// share it, so remote GROUP subscribers associate them into one
    /// coherent group.
    fn groupGuid(self: *Self, presentation: DDS.PresentationQosPolicy, publisher_handle: DDS.InstanceHandle_t) ?Guid {
        if (!presentation.coherent_access or presentation.access_scope != .GROUP_PRESENTATION_QOS) return null;
        const h: u32 = @bitCast(publisher_handle);
        return .{
            .prefix = self.guid.prefix,
            .entity_id = .{
                .entity_key = .{ @truncate(h >> 16), @truncate(h >> 8), @truncate(h) },
                .entity_kind = guid_mod.EntityKind.writer_group,
            },
        };
    }

    /// Has discovery prepare the announcements of the endpoints `handles`
    /// with `change`, skipping those that hold one with it already: all of
    /// them or, when discovery cannot reserve what announcing one and later
    /// disposing of it needs, none, changing nothing. An endpoint announced
    /// already keeps its announcement until announced again
    /// (docs/design/concurrency/architecture.md#local-endpoint-publication-announcement-and-disposal).
    /// `publisher_handle` is the writers' Publisher.
    fn prepareEndpoints(
        self: *Self,
        comptime kind: EndpointKind,
        handles: []const DDS.InstanceHandle_t,
        publisher_handle: DDS.InstanceHandle_t,
        change: Change(kind),
    ) !void {
        self.prepare_mu.lock();
        defer self.prepare_mu.unlock();
        var staged: std.ArrayListUnmanaged(Staged(kind)) = .empty;
        defer {
            for (staged.items) |*st| st.deinit(self.alloc);
            staged.deinit(self.alloc);
        }
        try staged.ensureTotalCapacityPrecise(self.alloc, handles.len);
        // Copied, for preparing after the lock is released: a deletion in
        // between frees the endpoint's own storage and can let its topic be
        // deleted.
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (handles) |h| {
                const ep = (switch (kind) {
                    .writer => self.findActiveWriterLocked(h),
                    .reader => self.findActiveReaderLocked(h),
                }) orelse continue;
                const presentation = change.presentation orelse ep.presentation;
                if (ep.prepared and change.qos == null and std.meta.eql(ep.presentation, presentation) and
                    (change.partition_names == null or partitionNamesEql(ep.partition_names, change.partition_names.?))) continue;
                if (staged.items.len == 0) try self.reserveAnnouncingLocked();
                try self.ensureLocalGenLocked(ep.guid);
                const names: ?[]const []const u8 = if (change.partition_names) |n| try dupePartitionNamesOrFail(self.alloc, n) else null;
                errdefer if (names) |n| freePartitionNames(self.alloc, n);
                var qos: ?QosOf(kind) = if (change.qos) |q| try ownQos(self.alloc, q.*) else null;
                errdefer if (qos) |*q| freeOwnedQos(self.alloc, q);
                const borrowed: AnnouncementOf(kind) = switch (kind) {
                    .writer => .{
                        .guid = ep.guid,
                        .participant_guid = self.guid,
                        .group_guid = self.groupGuid(presentation, publisher_handle),
                        .topic_name = ep.topic_name,
                        .type_name = ep.type_name,
                        .qos = if (qos) |q| q else ep.qos,
                        .presentation = presentation,
                        .partition_names = names orelse ep.partition_names,
                        .type_object = &.{},
                        .type_info_cdr = self.type_info_registry.get(ep.type_name) orelse &.{},
                    },
                    .reader => .{
                        .guid = ep.guid,
                        .participant_guid = self.guid,
                        .topic_name = ep.topic_name,
                        .type_name = ep.type_name,
                        .qos = if (qos) |q| q else ep.qos,
                        .presentation = presentation,
                        .partition_names = names orelse ep.partition_names,
                        .type_info_cdr = self.type_info_registry.get(ep.type_name) orelse &.{},
                    },
                };
                staged.appendAssumeCapacity(.{
                    .guid = ep.guid,
                    .ann = try borrowed.clone(self.alloc),
                    .partition_names = names,
                    .presentation = presentation,
                    .qos = qos,
                });
            }
        }
        for (staged.items, 0..) |*st, i| {
            const prepared = switch (kind) {
                .writer => self.discovery.prepareWriter(&st.ann),
                .reader => self.discovery.prepareReader(&st.ann),
            };
            prepared catch |err| {
                for (staged.items[0..i]) |done| switch (kind) {
                    .writer => self.discovery.abandonWriter(done.guid),
                    .reader => self.discovery.abandonReader(done.guid),
                };
                return err;
            };
        }
        for (staged.items) |st| switch (kind) {
            .writer => self.discovery.adoptWriter(st.guid),
            .reader => self.discovery.adoptReader(st.guid),
        };
        self.mu.lock();
        defer self.mu.unlock();
        for (staged.items) |*st| {
            // Deleted meanwhile: its deletion retracts what was prepared.
            const key = entityIdKey(st.guid.entity_id);
            const ep = (switch (kind) {
                .writer => self.active_writers.getPtr(key),
                .reader => self.active_readers.getPtr(key),
            }) orelse continue;
            if (st.partition_names) |n| {
                freePartitionNames(self.alloc, ep.partition_names);
                ep.partition_names = n;
                st.partition_names = null;
            }
            if (st.qos) |q| {
                freeOwnedQos(self.alloc, &ep.qos);
                ep.qos = q;
                st.qos = null;
            }
            ep.presentation = st.presentation;
            ep.prepared = true;
            // A match decided with what this replaced is not made.
            self.renewLocalGenLocked(st.guid);
        }
    }

    /// Has discovery prepare the announcements of the writers `handles`
    /// with their Publisher's `partition_names` and `presentation`: see
    /// `prepareEndpoints`.
    fn pubPrepareProtoWriters(ctx: *anyopaque, handles: []const DDS.InstanceHandle_t, publisher_handle: DDS.InstanceHandle_t, partition_names: []const []const u8, presentation: DDS.PresentationQosPolicy) anyerror!void {
        return cast(ctx).prepareEndpoints(.writer, handles, publisher_handle, .{ .partition_names = partition_names, .presentation = presentation });
    }

    /// Has discovery prepare the writer `handle`'s announcement with `qos`:
    /// see `prepareEndpoints`.
    fn pubPrepareProtoWriterQos(ctx: *anyopaque, handle: DDS.InstanceHandle_t, publisher_handle: DDS.InstanceHandle_t, qos: *const DDS.DataWriterQos) anyerror!void {
        return cast(ctx).prepareEndpoints(.writer, &.{handle}, publisher_handle, .{ .qos = qos });
    }

    fn findActiveWriterLocked(self: *Self, handle: DDS.InstanceHandle_t) ?*ActiveWriter {
        var it = self.active_writers.valueIterator();
        while (it.next()) |aw| if (aw.handle == handle) return aw;
        return null;
    }

    fn findActiveReaderLocked(self: *Self, handle: DDS.InstanceHandle_t) ?*ActiveReader {
        var it = self.active_readers.valueIterator();
        while (it.next()) |ar| if (ar.handle == handle) return ar;
        return null;
    }

    /// Announces the writer `handle`, prepared already, matching it with the
    /// readers discovered before it, and commits its announcement to
    /// discovery. A deletion while it is committed leaves the disposal to
    /// this, after the announcement. Announced already, it is a refresh,
    /// which also unmatches the readers it no longer matches, as a reader's
    /// own refresh does (onReaderDiscovered).
    fn pubAnnounceProtoWriter(ctx: *anyopaque, handle: DDS.InstanceHandle_t) void {
        const self = cast(ctx);
        var guid_opt: ?Guid = null;
        var jobs: std.ArrayListUnmanaged(AnnounceMatchedReaderJob) = .empty;
        defer jobs.deinit(self.alloc);
        var removed: Removals(RemovedReaderJob) = .{};
        defer removed.deinit(self.alloc);
        var incompat = false;
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.findActiveWriterLocked(handle)) |aw| {
                guid_opt = aw.guid;
                self.beginAnnouncingLocked(aw.guid);
                // Without room, nothing is unmatched (see the roadmap's
                // "A remote endpoint's discovery is handled best-effort
                // when out of memory").
                const can_unmatch = aw.announced and removed.reserve(self.alloc, self.discovered_readers.items.len);
                aw.announced = true;
                // Retroactively match against readers discovered before this
                // writer existed (or before it announced final partition/
                // presentation QoS) — onReaderDiscovered only scans writers
                // that already exist at the moment a reader is discovered, so
                // without this a reader discovered first would never be matched.
                const local_wd = disc_adapter.writerDiscoveredData(aw.qos, aw.presentation);
                reader_scan: for (self.discovered_readers.items) |*dr| {
                    // Mirrors onReaderDiscovered's own ignore-list guards (see that
                    // function, above) -- see subAnnounceProtoReader's matching
                    // comment (the symmetric fix on the reader side) for why this
                    // is needed: a reader ignored before this writer existed still
                    // sits in self.discovered_readers, and without these checks a
                    // writer created *after* the ignore call would retroactively
                    // re-match it here.
                    for (self.ignored_prefixes.items) |p| {
                        if (p.eql(dr.guid.prefix)) continue :reader_scan;
                    }
                    const dr_sub_handle = writer_mod.guidToHandle(dr.guid);
                    for (self.ignored_subscription_handles.items) |h| {
                        if (h == dr_sub_handle) continue :reader_scan;
                    }
                    for (self.ignored_topic_names.items) |n| {
                        if (std.mem.eql(u8, n, dr.topic_name)) continue :reader_scan;
                    }
                    if (!std.mem.eql(u8, dr.topic_name, aw.topic_name)) continue;
                    if (!std.mem.eql(u8, dr.type_name, aw.type_name)) continue;
                    const result = qm_mod.checkDiscovered(&local_wd, &dr.qos);
                    if (!result.isCompatible()) {
                        if (can_unmatch and removed.unmatchReaderLocked(aw, dr.guid)) {
                            aw.incompat_pending.record(result.incompatible);
                            incompat = true;
                        }
                        continue;
                    }
                    const part_result = qm_mod.checkPartition(aw.partition_names, dr.partition_names);
                    if (!part_result.isCompatible()) {
                        if (can_unmatch) _ = removed.unmatchReaderLocked(aw, dr.guid);
                        continue;
                    }
                    // Installed only while the reader's current generation
                    // is, as for a match made by its announcement.
                    const g = self.currentDiscoveryGenLocked(dr.guid) orelse continue;
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
                    var info = self.buildMatchedReaderInfo(dr.guid, &dr.qos, uloc, mloc);
                    info.currency = self.matchCurrency(g, aw.guid);
                    const nq = if (aw.matched_notify) |cb| cb.quiesceAcquire() else false;
                    jobs.append(self.alloc, .{
                        .proto = aw.proto,
                        .info = info,
                        .notify = aw.matched_notify,
                        .notify_quiesced = nq,
                        .remote_guid = dr.guid,
                        .unicast_locs = uloc,
                        .multicast_locs = mloc,
                    }) catch {
                        aw.proto.quiesceRelease();
                        if (nq) aw.matched_notify.?.quiesceRelease();
                        self.alloc.free(uloc);
                        self.alloc.free(mloc);
                    };
                }
            }
        }
        removed.fire(fireRemovedReaderJobs);
        if (incompat) self.raiseIncompatQos(.writers);
        for (jobs.items) |job| {
            // Only a new protocol-level match changes the matched status:
            // discovery can report an already matched pair again, which
            // just refreshes the proxy.
            const added = job.proto.addMatchedReader(&job.info) catch false;
            if (job.notify) |cb| if (job.notify_quiesced) {
                if (added) cb.notify(cb.ctx, writer_mod.guidToHandle(job.remote_guid), true);
                cb.quiesceRelease();
            };
            job.proto.quiesceRelease();
            self.alloc.free(job.unicast_locs);
            self.alloc.free(job.multicast_locs);
        }
        const guid = guid_opt orelse return;
        self.commitAnnouncement(.writer, guid);
    }

    const AnnounceMatchedWriterJob = struct {
        proto: proto.ProtocolReader,
        info: proto.MatchedWriterInfo,
        notify: ?MatchedNotify,
        notify_quiesced: bool = false,
        remote_guid: Guid,
        unicast_locs: []const Locator,
        multicast_locs: []const Locator,
    };

    /// `pubPrepareProtoWriters`, for readers and their Subscriber.
    fn subPrepareProtoReaders(ctx: *anyopaque, handles: []const DDS.InstanceHandle_t, partition_names: []const []const u8, presentation: DDS.PresentationQosPolicy) anyerror!void {
        return cast(ctx).prepareEndpoints(.reader, handles, DDS.HANDLE_NIL, .{ .partition_names = partition_names, .presentation = presentation });
    }

    /// `pubPrepareProtoWriterQos`, for a reader.
    fn subPrepareProtoReaderQos(ctx: *anyopaque, handle: DDS.InstanceHandle_t, qos: *const DDS.DataReaderQos) anyerror!void {
        return cast(ctx).prepareEndpoints(.reader, &.{handle}, DDS.HANDLE_NIL, .{ .qos = qos });
    }

    /// `pubAnnounceProtoWriter`, for the reader `handle`.
    fn subAnnounceProtoReader(ctx: *anyopaque, handle: DDS.InstanceHandle_t) void {
        const self = cast(ctx);
        var guid_opt: ?Guid = null;
        var jobs: std.ArrayListUnmanaged(AnnounceMatchedWriterJob) = .empty;
        defer jobs.deinit(self.alloc);
        var removed: Removals(RemovedWriterJob) = .{};
        defer removed.deinit(self.alloc);
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.findActiveReaderLocked(handle)) |ar| {
                guid_opt = ar.guid;
                self.beginAnnouncingLocked(ar.guid);
                const refresh = ar.announced;
                const can_unmatch = refresh and removed.reserve(self.alloc, self.discovered_writers.items.len);
                ar.announced = true;
                // Retroactively match against writers discovered before this
                // reader existed (or before it announced final partition/
                // presentation QoS) — onWriterDiscovered only scans readers
                // that already exist at the moment a writer is discovered, so
                // without this a writer discovered first would never be matched.
                const local_rd = disc_adapter.readerDiscoveredData(ar.qos, ar.presentation);
                writer_scan: for (self.discovered_writers.items) |*dw| {
                    // Mirrors onWriterDiscovered's own ignore-list guards (see that
                    // function, above): a writer ignored (by prefix, handle, or
                    // topic name) *before* this reader existed still sits in
                    // self.discovered_writers -- ignore_*() never retroactively
                    // purges the cache, only blocks future live discoveries -- so
                    // without these checks a reader created *after* the ignore
                    // call would retroactively re-match it here. Found building
                    // integration-tests/ignore-entities -- see
                    // docs/design/integration-test-tier.md.
                    for (self.ignored_prefixes.items) |p| {
                        if (p.eql(dw.guid.prefix)) continue :writer_scan;
                    }
                    const dw_pub_handle = writer_mod.guidToHandle(dw.guid);
                    for (self.ignored_publication_handles.items) |h| {
                        if (h == dw_pub_handle) continue :writer_scan;
                    }
                    for (self.ignored_topic_names.items) |n| {
                        if (std.mem.eql(u8, n, dw.topic_name)) continue :writer_scan;
                    }
                    if (!std.mem.eql(u8, dw.topic_name, ar.topic_name)) continue;
                    if (!std.mem.eql(u8, dw.type_name, ar.type_name)) continue;
                    const result = qm_mod.checkDiscovered(&dw.qos, &local_rd);
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
                        // A refresh counts only a match it removes: the
                        // first announcement counted the rest.
                        const unmatched = can_unmatch and removed.unmatchWriterLocked(ar, dw.guid);
                        if (!refresh or unmatched) ar.incompat_pending.record(result.incompatible);
                        continue;
                    }
                    const part_result = qm_mod.checkPartition(dw.partition_names, ar.partition_names);
                    if (!part_result.isCompatible()) {
                        if (can_unmatch) _ = removed.unmatchWriterLocked(ar, dw.guid);
                        continue;
                    }
                    // Installed only while the writer's current generation
                    // is, as for a match made by its announcement.
                    const g = self.currentDiscoveryGenLocked(dw.guid) orelse continue;
                    // See onWriterDiscovered's matching comment: defer the
                    // actual addMatchedWriter send until after self.mu is
                    // released below, duping dw's locators (borrowed from
                    // self.discovered_writers) into job-owned memory now.
                    if (!ar.proto.quiesceAcquire()) continue;
                    const uloc = dupeLocators(self.alloc, dw.unicast_locators);
                    const mloc = dupeLocators(self.alloc, dw.multicast_locators);
                    var info = buildMatchedWriterInfo(dw.guid, &dw.qos, uloc, mloc);
                    info.prematch = self.prematchFor(ar);
                    info.currency = self.matchCurrency(g, ar.guid);
                    const nq = if (ar.matched_notify) |cb| cb.quiesceAcquire() else false;
                    jobs.append(self.alloc, .{
                        .proto = ar.proto,
                        .info = info,
                        .notify = ar.matched_notify,
                        .notify_quiesced = nq,
                        .remote_guid = dw.guid,
                        .unicast_locs = uloc,
                        .multicast_locs = mloc,
                    }) catch {
                        ar.proto.quiesceRelease();
                        if (nq) ar.matched_notify.?.quiesceRelease();
                        self.alloc.free(uloc);
                        self.alloc.free(mloc);
                    };
                }
            }
        }
        removed.fire(fireRemovedWriterJobs);
        self.raiseIncompatQos(.readers);
        for (jobs.items) |job| {
            // Only a new protocol-level match changes the matched status:
            // discovery can report an already matched pair again, which
            // just refreshes the proxy.
            const added = job.proto.addMatchedWriter(&job.info) catch false;
            if (job.notify) |cb| if (job.notify_quiesced) {
                if (added) cb.notify(cb.ctx, writer_mod.guidToHandle(job.remote_guid), true);
                cb.quiesceRelease();
            };
            job.proto.quiesceRelease();
            self.alloc.free(job.unicast_locs);
            self.alloc.free(job.multicast_locs);
        }
        const guid = guid_opt orelse return;
        self.commitAnnouncement(.reader, guid);
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
                aw.matched_notify = .{ .ctx = notify_ctx, .notify = notify_fn, .is_reader = false };
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
                ar.matched_notify = .{ .ctx = notify_ctx, .notify = notify_fn, .is_reader = true };
                break;
            }
        }
    }

    fn pubRegisterWriterTimerNotify(
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (*anyopaque, i64) void,
        next_due_fn: *const fn (*anyopaque) ?i64,
        quiesce_acquire: *const fn (*anyopaque) bool,
        quiesce_release: *const fn (*anyopaque) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it6 = self.active_writers.valueIterator();
        while (aw_it6.next()) |aw| {
            if (aw.handle == handle) {
                aw.timer_check = .{ .ctx = notify_ctx, .check = notify_fn, .next_due = next_due_fn, .quiesce_acquire = quiesce_acquire, .quiesce_release = quiesce_release };
                break;
            }
        }
        timersChanged(self);
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
        next_due_fn: *const fn (*anyopaque) ?i64,
        quiesce_acquire: *const fn (*anyopaque) bool,
        quiesce_release: *const fn (*anyopaque) void,
    ) void {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var ar_it6 = self.active_readers.valueIterator();
        while (ar_it6.next()) |ar| {
            if (ar.handle == handle) {
                ar.timer_check = .{ .ctx = notify_ctx, .check = notify_fn, .next_due = next_due_fn, .quiesce_acquire = quiesce_acquire, .quiesce_release = quiesce_release };
                break;
            }
        }
        timersChanged(self);
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

    fn participantIsEnabledCb(ctx: *anyopaque) bool {
        return cast(ctx).enabled.load(.acquire);
    }

    fn makePubCbs(self: *Self) publisher_mod.ParticipantCbs {
        return .{
            .ctx = self,
            .is_participant_enabled = participantIsEnabledCb,
            .create_proto_writer = pubCreateProtoWriter,
            .destroy_proto_writer = pubDestroyProtoWriter,
            .register_incompat_qos = pubRegisterWriterIncompatQos,
            .register_matched_notify = pubRegisterWriterMatchedNotify,
            .prepare_writers = pubPrepareProtoWriters,
            .prepare_writer_qos = pubPrepareProtoWriterQos,
            .announce_writer = pubAnnounceProtoWriter,
            .timer_clock = self.timer_clock,
            .register_timer_notify = pubRegisterWriterTimerNotify,
            .timers_changed = .{ .ctx = self, .run = timersChanged },
            .listener_group = self.listenerGroup(),
            .register_liveliness_assert = pubRegisterWriterLivelinessAssert,
            .register_liveliness_query = pubRegisterWriterLivelinessQuery,
        };
    }

    fn makeSubCbs(self: *Self) subscriber_mod.ParticipantCbs {
        return .{
            .ctx = self,
            .is_participant_enabled = participantIsEnabledCb,
            .create_proto_reader = subCreateProtoReader,
            .destroy_proto_reader = subDestroyProtoReader,
            .register_incompat_qos = subRegisterReaderIncompatQos,
            .register_matched_notify = subRegisterReaderMatchedNotify,
            .prepare_readers = subPrepareProtoReaders,
            .prepare_reader_qos = subPrepareProtoReaderQos,
            .announce_reader = subAnnounceProtoReader,
            .timer_clock = self.timer_clock,
            .register_timer_notify = subRegisterReaderTimerNotify,
            .timers_changed = .{ .ctx = self, .run = timersChanged },
            .listener_group = self.listenerGroup(),
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
        _ = self.checkTimersAt(self.timer_clock.nowNs());
    }

    /// `checkTimers` at `now_ns`. Returns the earliest time anything checked
    /// here is next due, or null when nothing is timed.
    fn checkTimersAt(self: *Self, now_ns: i64) ?i64 {
        var due: std.ArrayListUnmanaged(TimerNotify) = .empty;
        defer due.deinit(self.alloc);
        // An endpoint left out for want of memory is checked again a poll
        // interval later.
        var skipped = false;
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
                        due.append(self.alloc, cb) catch {
                            cb.quiesce_release(cb.ctx);
                            skipped = true;
                        };
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
                        due.append(self.alloc, cb) catch {
                            cb.quiesce_release(cb.ctx);
                            skipped = true;
                        };
                    }
                }
            }
        }
        self.discovery.wlpTick(now_ns, wlp_info);
        self.unmatched.expire(now_ns);
        // Read before the checks: a listener they call may delete this
        // participant.
        var next = self.unmatched.nextExpiry();
        for (due.items) |cb| {
            cb.check(cb.ctx, now_ns);
            next = earlier(next, cb.next_due(cb.ctx));
            cb.quiesce_release(cb.ctx);
        }
        if (skipped) next = earlier(next, now_ns + @as(i64, TIMER_CHECK_INTERVAL_MS) * std.time.ns_per_ms);
        return next;
    }

    /// The runtime counterpart of `timerThreadFn`'s loop body.
    fn onCheckTimer(t: *runtime_mod.Timer, turn: *runtime_mod.Turn) void {
        const self: *Self = @fieldParentPtr("check_timer", t);
        if (self.checkTimersAt(turn.now_ns)) |due_ns| self.armCheck(due_ns);
    }

    /// Brings the checks forward to `due_ns`, unless they are armed for then
    /// or earlier. Without a runtime the timer thread polls instead.
    fn armCheck(self: *Self, due_ns: i64) void {
        const rt = self.runtime orelse return;
        self.check_mu.lock();
        defer self.check_mu.unlock();
        if (!self.check_stopping) _ = rt.armTimerNoLater(&self.check_timer, due_ns);
    }

    /// Something may now be due sooner than the checks are armed for: an
    /// endpoint created, a deadline changed, a writer's liveliness tracked
    /// again. Checks now, which arms them for whatever is due next.
    fn timersChanged(ctx: *anyopaque) void {
        const self = cast(ctx);
        if (self.runtime) |rt| self.armCheck(rt.clock.nowNs());
    }

    /// Stops the checks for good and closes their context. Returns false
    /// from inside a check: the context closes when that turn ends.
    fn stopCheckTimer(self: *Self) bool {
        self.check_mu.lock();
        self.check_stopping = true;
        self.check_mu.unlock();
        self.runtime.?.cancelTimer(&self.check_timer);
        return self.timers_latch.close(&self.timers, discardCheck);
    }

    /// A queued check is the timer's own embedded request: nothing to free.
    fn discardCheck(_: *runtime_mod.Request) void {}

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

    /// DomainParticipantFactory has no enable/disable state of its own (it is
    /// not an Entity per the DDS spec), so unlike every other type in this
    /// file, a participant's enable() has no "factory not enabled" precondition
    /// to check -- only the no-op-if-already-enabled case.
    fn vtEnable(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        if (self.enabled.load(.acquire)) return DDS.RETCODE_OK;
        self.start() catch return DDS.RETCODE_ERROR;
        self.enabled.store(true, .release);
        return DDS.RETCODE_OK;
    }

    /// NOT_ENABLED precondition, mirroring checkDeletePrecondition's shape
    /// elsewhere in this file. Called at the top of every non-exempt Entity
    /// operation (spec exempts set/get_qos, set/get_listener,
    /// get_statuscondition, get_status_changes, enable, get_instance_handle).
    fn checkEnabledPrecondition(self: *Self) DDS.ReturnCode_t {
        return if (self.enabled.load(.acquire)) DDS.RETCODE_OK else DDS.RETCODE_NOT_ENABLED;
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
        // NOT deliberately: create_publisher must work on a disabled
        // participant -- that's the whole point of autoenable_created_entities
        // =false (build the entire disabled tree, then enable() it top-down).
        // Only operations that need the participant to actually be *operating*
        // are gated; see checkEnabledPrecondition's call sites elsewhere in
        // this file for those.
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
        // Publisher's own enable() state comes from the PARTICIPANT's
        // entity_factory QoS -- distinct from this Publisher's own
        // qos.entity_factory, which instead governs its future DataWriters.
        // Also gated on THIS participant's own current enabled state (Greptile
        // PR #91 finding): autoenable_created_entities=true is "auto-call
        // enable() on creation," and enable() can never succeed while the
        // parent isn't enabled (see vtEnable's PRECONDITION_NOT_MET check) --
        // a disabled participant with the (spec-default) true QoS must not
        // silently produce an already-enabled child.
        p.enabled.store(self.enabled.load(.acquire) and self.qos.entity_factory.autoenable_created_entities, .release);
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        // See vtCreatePublisher's identical comment on why create_subscriber
        // is not gated by the participant's own enabled state.
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
        // See vtCreatePublisher's identical comment (including the
        // participant-enabled gate, PR #91 Greptile finding).
        s.enabled.store(self.enabled.load(.acquire) and self.qos.entity_factory.autoenable_created_entities, .release);
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return nil.nil_subscriber;
        }
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
        // See vtCreatePublisher's identical comment on why create_topic is
        // not gated by the participant's own enabled state.
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
            participantIsEnabledCb,
            qos.*,
            if (a_listener) |l| l.* else DDS.noop_TopicListener,
            mask,
            handle,
        ) catch return nil.nil_topic;
        // Gated on the participant's own enabled state too -- see
        // vtCreatePublisher's identical comment (PR #91 Greptile finding).
        t.enabled.store(self.enabled.load(.acquire) and self.qos.entity_factory.autoenable_created_entities, .release);
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
                .durability_kind = @as(u8, @intCast(@backingInt(qos.durability.kind))),
                .liveliness_kind = @as(u8, @intCast(@backingInt(qos.liveliness.kind))),
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return nil.nil_topic;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return nil.nil_topic_description;
        }
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
        // See vtCreatePublisher's identical comment. ContentFilteredTopic
        // isn't itself a spec Entity (no enable() of its own), but the same
        // "must be constructible on a disabled parent" reasoning applies to
        // this factory operation.
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
        const self = cast(ctx);
        // Spec §2.2.2.2.1.18: PRECONDITION_NOT_MET propagates up from any
        // contained entity's own outstanding preconditions -- check every
        // subscriber (read-loans) and publisher (write-loans) before
        // touching anything. Topics have no loan-related precondition, so
        // that branch needs no check. The lists are taken first, so no
        // concurrent delete frees one mid-check, and checked without `mu`:
        // a publisher's or subscriber's own mu comes before it
        // (delete_datawriter holds it while destroying the protocol writer).
        var pubs: std.ArrayListUnmanaged(*publisher_mod.PublisherImpl) = undefined;
        var subs: std.ArrayListUnmanaged(*subscriber_mod.SubscriberImpl) = undefined;
        self.mu.lock();
        pubs = self.publishers;
        self.publishers = .empty;
        subs = self.subscribers;
        self.subscribers = .empty;
        self.mu.unlock();
        const precondition = check: {
            for (subs.items) |s| {
                const rc = s.checkDeleteContainedPrecondition();
                if (rc != DDS.RETCODE_OK) break :check rc;
            }
            for (pubs.items) |p| {
                const rc = p.checkDeleteContainedPrecondition();
                if (rc != DDS.RETCODE_OK) break :check rc;
            }
            break :check DDS.RETCODE_OK;
        };
        if (precondition != DDS.RETCODE_OK) {
            self.mu.lock();
            defer self.mu.unlock();
            restoreTaken(*publisher_mod.PublisherImpl, self.alloc, &self.publishers, &pubs);
            restoreTaken(*subscriber_mod.SubscriberImpl, self.alloc, &self.subscribers, &subs);
            return precondition;
        }
        var tops: std.ArrayListUnmanaged(*topic_mod.TopicImpl) = undefined;
        var cfts: std.ArrayListUnmanaged(*topic_mod.ContentFilteredTopicImpl) = undefined;
        self.mu.lock();
        tops = self.topics;
        self.topics = .empty;
        // ContentFilteredTopics were never drained here (only by the
        // participant's own deinit()) -- delete_contained_entities()
        // reported RETCODE_OK while leaving cft_topics non-empty, so a
        // subsequent delete_participant() always failed with
        // PRECONDITION_NOT_MET (vtDeleteParticipant checks cft_topics.len)
        // whenever the app had created a ContentFilteredTopic. Found via
        // integration-tests/delete-contained-entities.
        cfts = self.cft_topics;
        self.cft_topics = .empty;
        self.mu.unlock();
        // Deinit outside lock to allow destroy_proto callbacks to re-lock mu.
        for (pubs.items) |p| p.deinit();
        pubs.deinit(self.alloc);
        for (subs.items) |s| s.deinit();
        subs.deinit(self.alloc);
        for (tops.items) |t| t.deinit();
        tops.deinit(self.alloc);
        for (cfts.items) |c| c.deinit();
        cfts.deinit(self.alloc);
        return DDS.RETCODE_OK;
    }

    /// Puts `taken` back into `list` under `mu`, keeping entities created
    /// since it was taken.
    fn restoreTaken(
        comptime T: type,
        alloc: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(T),
        taken: *std.ArrayListUnmanaged(T),
    ) void {
        taken.appendSlice(alloc, list.items) catch @panic("zzdds: out of memory restoring entity list");
        list.deinit(alloc);
        list.* = taken.*;
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
        @atomicStore(DDS.StatusMask, &self.listener_mask, mask, .monotonic);
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
    /// function serves both chains. The callback is always invoked with the
    /// entity whose status actually changed (the originating DataReader/DataWriter),
    /// never `self` — matches the spec's own framing: a "more specific"
    /// listener's absence doesn't change which entity the callback reports.
    /// If this level has no usable listener for `field` either, the event
    /// is simply not delivered (matches this codebase's pre-existing
    /// behavior for "nobody installed a listener for this status" at the
    /// origin entity): this returns null. Otherwise it returns this level's
    /// callback for `field`, not yet invoked (see `listener_fallback.Resolved`).
    pub fn resolveFallback(self: *Self, comptime Cb: type, comptime field: []const u8, bit: DDS.StatusMask) ?listener_fallback.Resolved(Cb) {
        const mask = @atomicLoad(DDS.StatusMask, &self.listener_mask, .monotonic);
        return listener_fallback.resolveBox(Cb, field, mask, bit, self.acquireListener(), self.alloc);
    }

    fn vtIgnoreParticipant(ctx: *anyopaque, handle: DDS.InstanceHandle_t) DDS.ReturnCode_t {
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        var aw_it9 = self.active_writers.valueIterator();
        while (aw_it9.next()) |aw| {
            if (aw.liveliness_assert) |cb| cb.assert_fn(cb.ctx);
        }
        return DDS.RETCODE_OK;
    }

    // None of the six set/get_default_*_qos operations below are gated on
    // enabled state -- see publisher.zig's vtSetDefaultDwQos/vtGetDefaultDwQos
    // comment for the empirically-confirmed reason
    // (integration-tests/zig/enable-defer): a disabled entity tree
    // legitimately needs to configure its own future children's default QoS
    // before enabling anything, exactly like create_publisher/
    // create_subscriber/create_topic themselves.
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
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
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return false;
        }
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

test "nextFanoutBatch visits every key once, in order, with a fixed buffer" {
    const testing = std.testing;
    var map: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer map.deinit(testing.allocator);
    // 37 keys inserted out of order: more than two full batches of 16.
    var k: u32 = 0;
    while (k < 37) : (k += 1) try map.put(testing.allocator, (k * 23) % 37 + 100, {});

    var seen: [40]u32 = undefined;
    var n_seen: usize = 0;
    var batches: usize = 0;
    var after: ?u32 = null;
    while (true) {
        var keys: [DomainParticipantImpl.FANOUT_BATCH]u32 = undefined;
        const sel = DomainParticipantImpl.nextFanoutBatch(&map, after, &keys);
        batches += 1;
        for (keys[0..sel.len]) |key| {
            seen[n_seen] = key;
            n_seen += 1;
        }
        if (batches == 2) {
            // Keys added meanwhile: one above the last visited, one below.
            try map.put(testing.allocator, 1000, {});
            try map.put(testing.allocator, 50, {});
        }
        if (!sel.more) break;
        after = keys[sel.len - 1];
    }
    try testing.expectEqual(@as(usize, 3), batches);
    // All 37 original keys once, in ascending order, then the key added
    // above the last visited one; the one added below is not visited.
    try testing.expectEqual(@as(usize, 38), n_seen);
    for (seen[0..37], 0..) |key, i| try testing.expectEqual(@as(u32, @intCast(100 + i)), key);
    try testing.expectEqual(@as(u32, 1000), seen[37]);
}

test "IncompatQosPending raises each recorded policy once, the latest last" {
    const testing = std.testing;
    const Rec = struct {
        ids: [8]i32 = undefined,
        n: usize = 0,
        fn notify(ctx: *anyopaque, policy_id: i32) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.ids[r.n] = policy_id;
            r.n += 1;
        }
    };
    var rec: Rec = .{};
    var p: IncompatQosPending = .{};
    p.raise(.{ .ctx = &rec, .notify = Rec.notify }); // nothing recorded
    try testing.expectEqual(@as(usize, 0), rec.n);

    p.record(.durability);
    p.record(.reliability);
    p.record(.durability);
    p.record(.deadline);
    p.record(.reliability);
    p.raise(.{ .ctx = &rec, .notify = Rec.notify });
    try testing.expectEqualSlices(i32, &.{ 2, 2, 4, 11, 11 }, rec.ids[0..rec.n]);
}

test "the active endpoint maps' first allocation fits a 4 KiB block" {
    // A fixed-block allocator (examples/*/custom-allocator use 4096-byte
    // blocks) cannot serve a larger request: create_datawriter/datareader
    // would fail to register the endpoint. Keep ActiveWriter/ActiveReader
    // small enough that the first growth of these maps stays within a block.
    const testing = std.testing;
    const Max = struct {
        child: std.mem.Allocator,
        max: usize = 0,
        fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.max = @max(self.max, len);
            return self.child.rawAlloc(len, al, ra);
        }
        fn free(ctx: *anyopaque, buf: []u8, al: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.child.rawFree(buf, al, ra);
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = free,
            } };
        }
    };
    inline for (.{ ActiveWriter, ActiveReader }) |T| {
        var m: Max = .{ .child = testing.allocator };
        var map: std.AutoHashMapUnmanaged(u32, T) = .empty;
        try map.ensureTotalCapacity(m.allocator(), 1);
        map.deinit(m.allocator());
        try testing.expect(m.max <= 4096);
    }
}

test "IncompatQosPending reports every policy a check can fail on under its own ID" {
    const testing = std.testing;
    const Rec = struct {
        ids: [32]i32 = undefined,
        n: usize = 0,
        fn notify(ctx: *anyopaque, policy_id: i32) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.ids[r.n] = policy_id;
            r.n += 1;
        }
    };
    var p: IncompatQosPending = .{};
    // Each policy twice, in reverse order, so the last recorded is the first.
    const all = std.enums.values(qm_mod.IncompatiblePolicy);
    for (0..2) |_| {
        var i = all.len;
        while (i > 0) {
            i -= 1;
            p.record(all[i]);
        }
    }
    var rec: Rec = .{};
    p.raise(.{ .ctx = &rec, .notify = Rec.notify });
    try testing.expectEqual(2 * all.len, rec.n);
    // Ascending, except the last recorded (the first, durability) raised last.
    var expected: [32]i32 = undefined;
    var n: usize = 0;
    for (all[1..]) |pol| for (0..2) |_| {
        expected[n] = @intCast(@backingInt(pol));
        n += 1;
    };
    for (0..2) |_| {
        expected[n] = @intCast(@backingInt(all[0]));
        n += 1;
    }
    try testing.expectEqualSlices(i32, expected[0..n], rec.ids[0..rec.n]);
}
