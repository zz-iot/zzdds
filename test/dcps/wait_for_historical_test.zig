//! Unit tests for DataReader.wait_for_historical_data (DDS §2.2.2.5.2.13).
//!
//! Tests inject discovery events and protocol messages directly via the
//! disc_callbacks and proto_reader interfaces so no real UDP sockets or
//! background threads are needed.

const std = @import("std");
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
        .announce_writer = noopAW,
        .retract_writer = noopRW,
        .announce_reader = noopAR,
        .retract_reader = noopRR,
        .deinit = noopDeinit,
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

    fn toDiscovery(self: *CapturingDisc) Discovery {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

// ── Harness ───────────────────────────────────────────────────────────────────

const Harness = struct {
    net: *MockNetwork,
    transport: *MockTransport,
    factory: *DomainParticipantFactoryImpl,
    disc: CapturingDisc,

    fn init() !Harness {
        var h: Harness = undefined;
        h.disc = .{};
        const alloc = testing.allocator;
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
        const data = iface.WriterData{
            .guid = writer_guid,
            .participant_guid = Guid{ .prefix = prefix, .entity_id = EntityIds.participant },
            .topic_name = topic,
            .type_name = "TestType",
            .qos = .{
                .durability_kind = durability_kind,
                .reliability_kind = reliability_kind,
                .data_representation = 2, // XCDR2 — matches reader's expected value
            },
            .unicast_locators = &.{},
            .multicast_locators = &.{},
            .type_object = &.{},
        };
        dp_impl.disc_callbacks.on_writer_discovered(dp_impl.disc_callbacks.ctx, &data);
        return writer_guid;
    }
};

fn makePrefix(seed: u8) GuidPrefix {
    return .{ .bytes = .{seed} ** 12 };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "wait_for_historical_data: VOLATILE returns OK immediately" {
    var h = try Harness.init();
    defer h.deinit();

    const alloc = testing.allocator;
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
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
    const dp = dpf.create_participant(0, .{}, null, 0);
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

test "wait_for_historical_data: non-zero max_wait with no matched writer times out, doesn't return OK instantly" {
    // Regression test: historicalDelivered() alone can't tell "genuinely
    // nothing to wait for" apart from "no writer has matched *yet*" -- both
    // look like an empty writer_proxies list. Previously this made a
    // *non-zero* max_wait return RETCODE_OK on the very first poll purely
    // because discovery hadn't matched a writer yet, defeating the whole
    // point of a bounded wait. Found building zzdds-examples' `catchup`
    // example: a real subscriber calling this immediately after creating
    // its reader (the single most common real call pattern) got an instant
    // false "OK" with zero historical samples actually delivered. Unlike
    // the DURATION_ZERO test above (a deliberate "check current state,
    // don't block" query, unaffected by this fix), a real max_wait must
    // still time out here since no writer ever matches in this test.
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
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

    // No writer is ever matched in this test -- a real (short, but non-zero)
    // max_wait must time out, not return OK on the first poll.
    const short_wait: DDS.Duration_t = .{ .sec = 0, .nanosec = 50 * std.time.ns_per_ms };
    const rc = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &short_wait);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc);
}

test "wait_for_historical_data: matches and delivers *during* the wait, not before it starts" {
    // The positive-path counterpart to the test above: a writer that
    // matches (and finishes delivering history) *while* wait_for_historical_data
    // is already blocked must still be observed as a real success, not
    // just "doesn't false-positive on nothing". Mirrors `catchup`'s actual
    // runtime shape (reader created, wait_for_historical_data called
    // immediately, writer discovered moments later) using a real background
    // thread rather than pre-arranging the match before the call.
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
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

    // Real thread-to-thread synchronization, not a guessed sleep duration:
    // about_to_wait is set right before this thread calls
    // wait_for_historical_data() below; the background thread spins on it
    // (std.Thread.Mutex/Condition/ResetEvent don't exist in this Zig
    // version -- removed in 0.16 when threads moved to the async std.Io
    // model, see src/util/mutex.zig's own comment) before firing the
    // match. A tight spin, not a sleep-based backoff, is fine here: this is
    // a single one-shot wait for one flag, not a contested loop (contrast
    // waitset_lifecycle_test.zig's audited real backoff, needed there
    // specifically to avoid hammering a shared mutex under Valgrind).
    // Guarantees the ordering this test is actually about ("during the
    // wait", not "before it starts") without any flakiness risk from a
    // fixed-duration sleep being too short under load.
    var about_to_wait: std.atomic.Value(bool) = .init(false);

    const MatchLater = struct {
        fn run(event: *std.atomic.Value(bool), harness: *Harness, participant_impl: *DomainParticipantImpl, reader_impl: *DataReaderImpl) void {
            while (!event.load(.acquire)) std.atomic.spinLoopHint();
            const prefix = makePrefix(0x50);
            const writer_guid = harness.fireWriter(participant_impl, prefix, "TestTopic", 1, 1);
            // Empty history (first_sn=1, last_sn=0): floor=0, immediately satisfied
            // once history_established flips true -- see the "empty history"
            // test above for the same HEARTBEAT shape.
            reader_impl.proto_reader.handleHeartbeat(writer_guid, 1, 0, 1, true);
        }
    };
    const t = try std.Thread.spawn(.{}, MatchLater.run, .{ &about_to_wait, &h, dp_impl, dr_impl });
    defer t.join();

    const generous_wait: DDS.Duration_t = .{ .sec = 2, .nanosec = 0 };
    about_to_wait.store(true, .release);
    const rc = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &generous_wait);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "wait_for_historical_data: times out before first HEARTBEAT from transient-local writer" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
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
    const dp = dpf.create_participant(0, .{}, null, 0);
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
    dr_impl.proto_reader.handleHeartbeat(writer_guid, 1, 0, 1, true);

    const rc = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "wait_for_historical_data: returns OK after history fully delivered (data before HB)" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
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
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 1, ts, kh, &payload, .alive, null, null, null);
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 2, ts, kh, &payload, .alive, null, null, null);
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 3, ts, kh, &payload, .alive, null, null, null);

    // Before HB: history_established=false → timeout.
    const rc1 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc1);

    // First HEARTBEAT: sets floor=3; cumulativeAck=3 already satisfies the floor.
    dr_impl.proto_reader.handleHeartbeat(writer_guid, 1, 3, 1, true);

    const rc2 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc2);
}

test "wait_for_historical_data: returns OK once pending data fills history floor (HB before data)" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
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
    dr_impl.proto_reader.handleHeartbeat(writer_guid, 1, 2, 1, false);

    // History floor is established but no data yet → timeout.
    const rc1 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc1);

    // Deliver SN=1 only — still short of floor (2).
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 1, ts, kh, &payload, .alive, null, null, null);
    const rc2 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc2);

    // Deliver SN=2 — cumulativeAck=2 >= floor=2 → OK.
    dr_impl.proto_reader.handleIncomingChange(writer_guid, 2, ts, kh, &payload, .alive, null, null, null);
    const rc3 = dr_raw.vtable.wait_for_historical_data(dr_raw.ptr, &DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc3);
}
