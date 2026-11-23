//! Unit tests for DataReader.wait_for_historical_data (DDS §2.2.2.5.2.13).
//!
//! Tests inject discovery events and protocol messages directly via the
//! disc_callbacks and proto_reader interfaces so no real UDP sockets or
//! background threads are needed.

const std = @import("std");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const dcps = zzdds.dcps;
const iface = zzdds.discovery;
const mock_tr = zzdds.mock_transport;
const noop_security = zzdds.noop_security.noop_security_plugins;

const DomainParticipantFactoryImpl = dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = dcps.DomainParticipantImpl;
const DataReaderImpl = dcps.DataReaderImpl;
const nil = dcps;

const Discovery = iface.Discovery;
const Callbacks = iface.Callbacks;
const Guid = iface.Guid;
const GuidPrefix = zzdds.rtps.GuidPrefix;
const EntityIds = zzdds.rtps.EntityIds;
const Locator = mock_tr.Locator;
const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;

const testing = std.testing;
const rt = zzdds.runtime;
const ManualRuntime = @import("manual_runtime").ManualRuntime;

const DURATION_ZERO: DDS.Duration_t = .{ .sec = 0, .nanosec = 0 };
const DURATION_INFINITE: DDS.Duration_t = .{
    .sec = DDS.DURATION_INFINITE_SEC,
    .nanosec = DDS.DURATION_INFINITE_NSEC,
};

// ── CapturingDisc ─────────────────────────────────────────────────────────────

const CapturingDisc = struct {
    callbacks: ?*const Callbacks = null,

    const vtable = Discovery.Vtable{
        .start = start,
        .stop = stop,
        .prepare_writer = noopAW,
        .announce_writer = noopRW,
        .retract_writer = noopRW,
        .prepare_reader = noopAR,
        .announce_reader = noopRR,
        .retract_reader = noopRR,
        .deinit = noopDeinit,
        .wlp_tick = noopWlpTick,
    };

    fn start(ctx: *anyopaque, _: *const iface.ParticipantAnnouncement, cbs: *const Callbacks) anyerror!void {
        const self: *CapturingDisc = @ptrCast(@alignCast(ctx));
        self.callbacks = cbs;
    }
    fn stop(_: *anyopaque) void {}
    fn noopAW(_: *anyopaque, _: *const iface.WriterAnnouncement) anyerror!void {}
    fn noopRW(_: *anyopaque, _: Guid) void {}
    fn noopAR(_: *anyopaque, _: *const iface.ReaderAnnouncement) anyerror!void {}
    fn noopRR(_: *anyopaque, _: Guid) void {}
    fn noopDeinit(_: *anyopaque) void {}
    fn noopWlpTick(_: *anyopaque, _: i64, _: iface.WlpTickInfo) void {}

    fn toDiscovery(self: *CapturingDisc) Discovery {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

// ── Harness ───────────────────────────────────────────────────────────────────

const Harness = struct {
    net: *MockNetwork,
    transport: *MockTransport,
    factory: *DomainParticipantFactoryImpl,
    /// On the heap: the factory keeps a pointer to it, and `init` returns
    /// the Harness by value.
    disc: *CapturingDisc,

    fn init() !Harness {
        var h: Harness = undefined;
        const alloc = testing.allocator;
        h.disc = try alloc.create(CapturingDisc);
        errdefer alloc.destroy(h.disc);
        h.disc.* = .{};
        h.net = try MockNetwork.init(alloc);
        errdefer h.net.deinit();
        h.transport = try MockTransport.init(alloc, h.net, &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7410)});
        errdefer h.transport.deinit();
        h.factory = try DomainParticipantFactoryImpl.init(
            alloc,
            h.transport.transport(),
            h.disc.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        return h;
    }

    fn deinit(self: *Harness) void {
        self.factory.deinit();
        self.transport.deinit();
        self.net.deinit();
        testing.allocator.destroy(self.disc);
    }

    /// Fire on_writer_discovered for a fake remote writer.
    /// durability_kind: 0=VOLATILE, 1=TRANSIENT_LOCAL.
    /// reliability_kind: 0=BEST_EFFORT, 1=RELIABLE.
    fn fireWriter(
        _: *Harness,
        dp_impl: *DomainParticipantImpl,
        prefix: GuidPrefix,
        topic: []const u8,
        durability_kind: u8,
        reliability_kind: u8,
    ) Guid {
        const writer_guid = Guid{
            .prefix = prefix,
            .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0x02 },
        };
        var repr = [_]i16{2}; // XCDR2 — matches reader's expected value
        var q = iface.DiscoveredWriterData{
            .reliability = .{ .kind = reliability_kind + 1, .max_blocking_time = .{} },
            .durabilityKind = durability_kind,
            .history = .{ .kind = 0, .depth = 1 },
            .dataRepresentation = .{ ._maximum = 1, ._length = 1, ._buffer = &repr, ._release = false },
        };
        const data = iface.WriterData{
            .guid = writer_guid,
            .participant_guid = Guid{ .prefix = prefix, .entity_id = EntityIds.participant },
            .topic_name = topic,
            .type_name = "TestType",
            .qos = &q,
            .unicast_locators = &.{},
            .multicast_locators = &.{},
            .type_object = &.{},
        };
        dp_impl.disc_callbacks.on_writer_discovered(dp_impl.disc_callbacks.ctx, &data);
        return writer_guid;
    }
};

fn makePrefix(seed: u8) GuidPrefix {
    return .{ .bytes = @splat(seed) };
}

/// Samples in the reader, ready to take.
fn available(dr: *DataReaderImpl) usize {
    dr.mu.lock();
    defer dr.mu.unlock();
    return dr.pending.items.len;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "wait_for_historical_data: VOLATILE returns OK immediately" {
    var h = try Harness.init();
    defer h.deinit();

    const alloc = testing.allocator;
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    // Default QoS: VOLATILE durability.
    const dr_raw = sub.create_datareader(td, .{}, null, 0);
    _ = alloc;

    const rc = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "wait_for_historical_data: TRANSIENT_LOCAL with no matched writers returns OK immediately" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);

    // No writers matched → nothing to wait for.
    const rc = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "wait_for_historical_data: with no matched writer, any max_wait returns OK at once" {
    // Nothing is owed (docs/design/concurrency/operations.md#historical-wait-compatibility):
    // an application that needs a writer to match first waits for that
    // match, not for historical data.
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);

    try testing.expectEqual(DDS.RETCODE_OK, dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_INFINITE));
}

test "wait_for_historical_data: a BEST_EFFORT reader returns OK at once" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);
    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);
    _ = h.fireWriter(dp_impl, makePrefix(0x51), "TestTopic", 1, 1);

    // Twice: it warns only once.
    try testing.expectEqual(DDS.RETCODE_OK, dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_INFINITE));
    try testing.expectEqual(DDS.RETCODE_OK, dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_INFINITE));
}

test "wait_for_historical_data: a negative or unnormalized max_wait is BAD_PARAMETER" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);
    const dr_raw = sub.create_datareader(td, .{}, null, 0);
    for ([_]DDS.Duration_t{ .{ .sec = -1, .nanosec = 0 }, .{ .sec = 0, .nanosec = 1_000_000_000 } }) |d| {
        try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &d));
    }
}

/// A participant on a manual runtime, with a transient-local reliable
/// reader matched to a writer that owes it history, and a runtime timer due
/// at once that changes something: the wait's help runs it, so it happens
/// during the wait.
const DuringWait = struct {
    mr: ManualRuntime,
    h: Harness,
    dp: DDS.DomainParticipant,
    dp_impl: *DomainParticipantImpl,
    sub: DDS.Subscriber,
    dr: DDS.DataReader,
    dr_impl: *DataReaderImpl,
    writer: Guid,
    context: rt.Context,
    timer: rt.Timer,
    action: enum { lose_writer, match_another, delete_reader },
    rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,

    /// Must not move afterwards.
    fn init(self: *DuringWait) !void {
        self.mr.init();
        self.h = try Harness.init();
        const dpf = self.h.factory.toDDSFactory();
        self.dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
        self.dp_impl = @ptrCast(@alignCast(self.dp.ptr));
        const topic = self.dp.create_topic("TestTopic", "TestType", .{}, null, 0);
        const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
        self.sub = self.dp.create_subscriber(.{}, null, 0);
        var dr_qos = DDS.DataReaderQos{};
        dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
        dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
        self.dr = self.sub.create_datareader(tp_impl.toTopicDescription(), dr_qos, null, 0);
        self.dr_impl = @ptrCast(@alignCast(self.dr.ptr));
        self.writer = self.h.fireWriter(self.dp_impl, makePrefix(0x70), "TestTopic", 1, 1);
        self.context = rt.Context.init(&self.mr.runtime, 4);
        self.timer = rt.Timer.init(&self.context, fire);
    }

    /// Runs `action` when the timer fires, due now.
    fn arm(self: *DuringWait, action: @TypeOf(self.action)) void {
        self.action = action;
        _ = self.mr.runtime.armTimer(&self.timer, self.mr.runtime.clock.nowNs());
    }

    fn fire(t: *rt.Timer, _: *rt.Turn) void {
        const self: *DuringWait = @fieldParentPtr("timer", t);
        switch (self.action) {
            .lose_writer => self.dp_impl.disc_callbacks.on_writer_lost(self.dp_impl.disc_callbacks.ctx, self.writer),
            .match_another => {
                _ = self.h.fireWriter(self.dp_impl, makePrefix(0x71), "TestTopic", 1, 1);
                self.dr_impl.proto_reader.handleHeartbeat(self.writer, EntityIds.unknown, 1, 0, 1, true, false);
            },
            .delete_reader => self.rc = self.sub.delete_datareader(self.dr),
        }
    }

    fn deinit(self: *DuringWait) void {
        self.context.deinit();
        _ = self.dp.delete_contained_entities();
        _ = self.h.factory.toDDSFactory().delete_participant(self.dp);
        self.h.deinit();
        self.mr.deinit();
    }
};

test "wait_for_historical_data: a writer matched after the wait began does not join it" {
    var d: DuringWait = undefined;
    try d.init();
    defer d.deinit();
    d.arm(.match_another);
    try testing.expectEqual(DDS.RETCODE_OK, d.dr.wait_for_historical_data(.{ .sec = 1, .nanosec = 0 }));
}

test "wait_for_historical_data: a writer lost before delivering its history fails the wait with ERROR" {
    var d: DuringWait = undefined;
    try d.init();
    defer d.deinit();
    d.arm(.lose_writer);
    try testing.expectEqual(DDS.RETCODE_ERROR, d.dr.wait_for_historical_data(.{ .sec = 1, .nanosec = 0 }));
}

test "wait_for_historical_data: deleting the reader ends its wait with ALREADY_DELETED" {
    var d: DuringWait = undefined;
    try d.init();
    defer d.deinit();
    d.arm(.delete_reader);
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, d.dr.wait_for_historical_data(.{ .sec = 1, .nanosec = 0 }));
    try testing.expectEqual(DDS.RETCODE_OK, d.rc);
}

test "wait_for_historical_data: times out before first HEARTBEAT from transient-local writer" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);

    // Match a TRANSIENT_LOCAL RELIABLE remote writer.
    const prefix = makePrefix(0x10);
    _ = h.fireWriter(dp_impl, prefix, "TestTopic", 1, 1);

    // No HEARTBEAT received yet → history_established=false → must timeout.
    const rc = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc);
}

test "wait_for_historical_data: returns OK after first HB with empty history (last_sn=0)" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    const prefix = makePrefix(0x20);
    const writer_guid = h.fireWriter(dp_impl, prefix, "TestTopic", 1, 1);

    // Deliver first HEARTBEAT with empty writer history (first_sn=1, last_sn=0).
    // Per RTPS §8.3.7.5.1 this signals an empty cache; floor_sn=0 → immediately satisfied.
    dr_impl.proto_reader.handleHeartbeat(writer_guid, EntityIds.unknown, 1, 0, 1, true, false);

    const rc = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "wait_for_historical_data: returns OK after history fully delivered (data before HB)" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    const prefix = makePrefix(0x30);
    const writer_guid = h.fireWriter(dp_impl, prefix, "TestTopic", 1, 1);

    const ts = zzdds.util.time.RtpsTimestamp.zero;
    const kh = std.mem.zeroes([16]u8);
    var payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAB, 0xCD };

    // Deliver SN=1,2,3 before the first HEARTBEAT arrives.
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 1, ts, kh, &payload, .alive, null, null, null, null);
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 2, ts, kh, &payload, .alive, null, null, null, null);
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 3, ts, kh, &payload, .alive, null, null, null, null);

    // Before HB: history_established=false → timeout.
    const rc1 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc1);

    // First HEARTBEAT: sets floor=3; cumulativeAck=3 already satisfies the floor.
    dr_impl.proto_reader.handleHeartbeat(writer_guid, EntityIds.unknown, 1, 3, 1, true, false);

    const rc2 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc2);
    try testing.expectEqual(@as(usize, 3), available(dr_impl));
}

test "wait_for_historical_data: returns OK once pending data fills history floor (HB before data)" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    const prefix = makePrefix(0x40);
    const writer_guid = h.fireWriter(dp_impl, prefix, "TestTopic", 1, 1);

    const ts = zzdds.util.time.RtpsTimestamp.zero;
    const kh = std.mem.zeroes([16]u8);
    var payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xEF, 0x01 };

    // HEARTBEAT arrives first: floor = 2.
    dr_impl.proto_reader.handleHeartbeat(writer_guid, EntityIds.unknown, 1, 2, 1, false, false);

    // History floor is established but no data yet → timeout.
    const rc1 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc1);

    // Deliver SN=1 only — still short of floor (2).
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 1, ts, kh, &payload, .alive, null, null, null, null);
    const rc2 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc2);

    // Deliver SN=2 — cumulativeAck=2 >= floor=2 → OK.
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 2, ts, kh, &payload, .alive, null, null, null, null);
    const rc3 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc3);
    try testing.expectEqual(@as(usize, 2), available(dr_impl));
}

test "wait_for_historical_data: history the reader rejects for RESOURCE_LIMITS fails the wait with ERROR" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples = 1;
    dr_qos.resource_limits.max_samples_per_instance = 1;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    const prefix = makePrefix(0x41);
    const writer_guid = h.fireWriter(dp_impl, prefix, "TestTopic", 1, 1);

    const ts = zzdds.util.time.RtpsTimestamp.zero;
    const kh = std.mem.zeroes([16]u8);
    var payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xEF, 0x01 };

    // The writer's history is two samples; the reader has room for one.
    dr_impl.proto_reader.handleHeartbeat(writer_guid, EntityIds.unknown, 1, 2, 1, false, false);
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 1, ts, kh, &payload, .alive, null, null, null, null);
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 2, ts, kh, &payload, .alive, null, null, null, null);
    try testing.expectEqual(@as(usize, 1), available(dr_impl));

    // The second sample was rejected: that history cannot arrive complete.
    const rc = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_ERROR, rc);
}

test "wait_for_historical_data: history the writer no longer has is reported lost, not waited for" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    const writer_guid = h.fireWriter(dp_impl, makePrefix(0x60), "TestTopic", 1, 1);

    // The first HEARTBEAT offers nothing below SN 4: SNs 1-3 are gone.
    dr_impl.proto_reader.handleHeartbeat(writer_guid, EntityIds.unknown, 4, 3, 1, true, false);

    const rc = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(usize, 0), available(dr_impl));
    var lost: DDS.SampleLostStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr_raw.vtable.get_sample_lost_status(dr_raw.ptr, &lost));
    try testing.expectEqual(@as(i32, 3), lost.total_count);
}

test "wait_for_historical_data: a writer lost before delivering its history leaves the shortfall reported lost" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    const writer_guid = h.fireWriter(dp_impl, makePrefix(0x61), "TestTopic", 1, 1);

    const ts = zzdds.util.time.RtpsTimestamp.zero;
    const kh = std.mem.zeroes([16]u8);
    var payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAB, 0xCD };

    // History is SNs 1-4: 1 arrives, a GAP drops 3, 4 arrives out of
    // order, 2 never does.
    dr_impl.proto_reader.handleHeartbeat(writer_guid, EntityIds.unknown, 1, 4, 1, true, false);
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 1, ts, kh, &payload, .alive, null, null, null, null);
    dr_impl.proto_reader.handleGap(writer_guid, 3, .{ .base = 4, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) });
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 4, ts, kh, &payload, .alive, null, null, null, null);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO));
    var lost: DDS.SampleLostStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr_raw.vtable.get_sample_lost_status(dr_raw.ptr, &lost));
    try testing.expectEqual(@as(i32, 1), lost.total_count);

    dp_impl.disc_callbacks.on_writer_lost(dp_impl.disc_callbacks.ctx, writer_guid);

    try testing.expectEqual(DDS.RETCODE_OK, dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO));
    try testing.expectEqual(DDS.RETCODE_OK, dr_raw.vtable.get_sample_lost_status(dr_raw.ptr, &lost));
    // SN 2, and SN 4, held waiting for it; SN 3 was counted at the GAP.
    try testing.expectEqual(@as(i32, 2), lost.total_count_change);
    try testing.expectEqual(@as(i32, 3), lost.total_count);
}

test "wait_for_historical_data: a writer's participant lost before it delivers reports its history lost" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const tp_impl: *dcps.TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const td = tp_impl.toTopicDescription();

    const sub = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, sub);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const dr_raw = sub.create_datareader(td, dr_qos, null, 0);

    const prefix = makePrefix(0x62);
    const writer_guid = h.fireWriter(dp_impl, prefix, "TestTopic", 1, 1);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));
    dr_impl.proto_reader.handleHeartbeat(writer_guid, EntityIds.unknown, 1, 2, 1, true, false);

    dp_impl.disc_callbacks.on_participant_lost(dp_impl.disc_callbacks.ctx, .{ .prefix = prefix, .entity_id = EntityIds.participant });

    try testing.expectEqual(DDS.RETCODE_OK, dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO));
    try testing.expectEqual(@as(usize, 0), available(dr_impl));
    var lost: DDS.SampleLostStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr_raw.vtable.get_sample_lost_status(dr_raw.ptr, &lost));
    try testing.expectEqual(@as(i32, 2), lost.total_count);
}
