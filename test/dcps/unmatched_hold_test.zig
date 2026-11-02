//! Data from writers no local reader has matched yet: the participant holds
//! it once for all its readers, hands it to each reader that then matches
//! the writer, and drops it when discovery has matched the writer, when the
//! writer or its participant is lost, or when it expires.
//!
//! Discovery events are fired directly (a discovery plugin that only
//! captures its callbacks), DATA is injected as raw RTPS from a second
//! MockTransport, and time is a ManualClock.

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
const TopicImpl = dcps.TopicImpl;
const ManualClock = zzdds.util.time.ManualClock;

const Discovery = iface.Discovery;
const Callbacks = iface.Callbacks;
const Guid = iface.Guid;
const GuidPrefix = zzdds.rtps.GuidPrefix;
const EntityIds = zzdds.rtps.EntityIds;
const Locator = mock_tr.Locator;
const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;

const testing = std.testing;

const SEC: i64 = std.time.ns_per_s;
/// The lease this participant announces (config default), and so how long
/// data from an undiscovered participant's writer is held.
const OWN_LEASE_NS: i64 = 10 * SEC;
const REMOTE_LEASE_MS: u32 = 4_000;

// ── Discovery that only captures its callbacks ────────────────────────────────

const CapturingDisc = struct {
    const vtable = Discovery.Vtable{
        .start = start,
        .stop = noop,
        .prepare_writer = noopAW,
        .announce_writer = noopGuid,
        .retract_writer = noopGuid,
        .prepare_reader = noopAR,
        .announce_reader = noopGuid,
        .retract_reader = noopGuid,
        .deinit = noop,
        .wlp_tick = noopWlpTick,
    };

    fn start(_: *anyopaque, _: *const iface.ParticipantAnnouncement, _: *const Callbacks) anyerror!void {}
    fn noop(_: *anyopaque) void {}
    fn noopAW(_: *anyopaque, _: *const iface.WriterAnnouncement) anyerror!void {}
    fn noopAR(_: *anyopaque, _: *const iface.ReaderAnnouncement) anyerror!void {}
    fn noopGuid(_: *anyopaque, _: Guid) void {}
    fn noopWlpTick(_: *anyopaque, _: i64, _: iface.WlpTickInfo) void {}

    var sentinel: u8 = 0;
    fn discovery() Discovery {
        return .{ .ctx = &sentinel, .vtable = &vtable };
    }
};

// ── Raw RTPS ──────────────────────────────────────────────────────────────────

const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF };

fn rtpsData(buf: *std.ArrayListUnmanaged(u8), src: GuidPrefix, reader_eid: [4]u8, writer_eid: [4]u8, sns: []const u32) !void {
    const alloc = testing.allocator;
    try buf.appendSlice(alloc, "RTPS");
    try buf.appendSlice(alloc, &[_]u8{ 2, 3, 0x01, 0x10 });
    try buf.appendSlice(alloc, &src.bytes);
    for (sns) |sn| {
        // Little-endian, data present.
        var smh = [_]u8{ 0x15, 0x05, 0, 0 };
        std.mem.writeInt(u16, smh[2..4], 20 + PAYLOAD.len, .little);
        try buf.appendSlice(alloc, &smh);
        try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0x10, 0 });
        try buf.appendSlice(alloc, &reader_eid);
        try buf.appendSlice(alloc, &writer_eid);
        var sn_bytes: [8]u8 = undefined;
        std.mem.writeInt(i32, sn_bytes[0..4], 0, .little);
        std.mem.writeInt(u32, sn_bytes[4..8], sn, .little);
        try buf.appendSlice(alloc, &sn_bytes);
        try buf.appendSlice(alloc, &PAYLOAD);
    }
}

fn eidBytes(eid: zzdds.rtps.EntityId) [4]u8 {
    return eid.entity_key ++ [1]u8{eid.entity_kind};
}

const ANY_READER = [4]u8{ 0, 0, 0, 0 };

// ── Harness ───────────────────────────────────────────────────────────────────

const Harness = struct {
    net: *MockNetwork,
    transport: *MockTransport,
    injector: *MockTransport,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,
    dp_impl: *DomainParticipantImpl,
    sub: DDS.Subscriber,

    fn init(h: *Harness, clock: *ManualClock) !void {
        const alloc = testing.allocator;
        h.net = try MockNetwork.init(alloc);
        errdefer h.net.deinit();
        h.transport = try MockTransport.init(alloc, h.net, &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7410)});
        errdefer h.transport.deinit();
        h.injector = try MockTransport.init(alloc, h.net, &.{Locator.udp4(.{ 127, 0, 0, 2 }, 7410)});
        errdefer h.injector.deinit();
        var config = zzdds.config.Config{};
        config.participant.timer_clock_name = "manual";
        h.factory = try DomainParticipantFactoryImpl.init(alloc, h.transport.transport(), CapturingDisc.discovery(), noop_security, .spec_random, config);
        errdefer h.factory.deinit();
        try h.factory.clock_registry.register("manual", clock.clock());
        h.dp = h.factory.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        h.dp_impl = @ptrCast(@alignCast(h.dp.ptr));
        h.sub = h.dp.create_subscriber(.{}, null, 0);
    }

    fn deinit(h: *Harness) void {
        _ = h.dp.vtable.delete_contained_entities(h.dp.ptr);
        _ = h.factory.toDDSFactory().delete_participant(h.dp);
        h.factory.deinit();
        h.injector.deinit();
        h.transport.deinit();
        h.net.deinit();
    }

    fn reader(h: *Harness, topic_name: [:0]const u8, kind: DDS.ReliabilityQosPolicyKind) *DataReaderImpl {
        return h.readerWith(topic_name, kind, .VOLATILE_DURABILITY_QOS);
    }

    fn readerWith(h: *Harness, topic_name: [:0]const u8, kind: DDS.ReliabilityQosPolicyKind, durability: DDS.DurabilityQosPolicyKind) *DataReaderImpl {
        const topic = h.dp.create_topic(topic_name, "T", .{}, null, 0);
        const desc = @as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();
        var qos = DDS.DataReaderQos{};
        qos.reliability.kind = kind;
        qos.durability.kind = durability;
        // Every sample stays to be counted: the type is keyless, so all are
        // of one instance.
        qos.history.kind = .KEEP_ALL_HISTORY_QOS;
        const dr = h.sub.create_datareader(desc, qos, null, 0);
        return @ptrCast(@alignCast(dr.ptr));
    }

    /// Sends DATA for `sns` from `writer` to `reader_eid` (ANY_READER for all).
    fn inject(h: *Harness, writer: Guid, reader_eid: [4]u8, sns: []const u32) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(testing.allocator);
        try rtpsData(&buf, writer.prefix, reader_eid, eidBytes(writer.entity_id), sns);
        try h.injector.transport().send(&Locator.udp4(.{ 127, 0, 0, 1 }, h.dp_impl.data_listen_port), buf.items);
        h.net.deliverAll();
    }

    fn announceParticipant(h: *Harness, prefix: GuidPrefix) void {
        const data = iface.ParticipantData{
            .guid = .{ .prefix = prefix, .entity_id = EntityIds.participant },
            .domain_id = 0,
            .name = "",
            .metatraffic_unicast_locators = &.{},
            .metatraffic_multicast_locators = &.{},
            .default_unicast_locators = &.{},
            .default_multicast_locators = &.{},
            .lease_duration_ms = REMOTE_LEASE_MS,
            .builtin_endpoint_set = 0,
            .vendor_id = .{ .bytes = .{ 0x00, 0x00 } },
        };
        h.dp_impl.disc_callbacks.on_participant_discovered(h.dp_impl.disc_callbacks.ctx, &data);
    }

    fn announceWriter(h: *Harness, writer: Guid, topic_name: []const u8) void {
        h.announceWriterWith(writer, topic_name, 0);
    }

    /// durability_kind: 0 = VOLATILE, 1 = TRANSIENT_LOCAL.
    fn announceWriterWith(h: *Harness, writer: Guid, topic_name: []const u8, durability_kind: u8) void {
        var repr = [_]i16{2};
        var q = iface.DiscoveredWriterData{
            .reliability = .{ .kind = 2, .max_blocking_time = .{} },
            .durabilityKind = durability_kind,
            .history = .{ .kind = 0, .depth = 1 },
            .dataRepresentation = .{ ._maximum = 1, ._length = 1, ._buffer = &repr, ._release = false },
        };
        const data = iface.WriterData{
            .guid = writer,
            .participant_guid = .{ .prefix = writer.prefix, .entity_id = EntityIds.participant },
            .topic_name = topic_name,
            .type_name = "T",
            .qos = &q,
            .unicast_locators = &.{},
            .multicast_locators = &.{},
            .type_object = &.{},
        };
        h.dp_impl.disc_callbacks.on_writer_discovered(h.dp_impl.disc_callbacks.ctx, &data);
    }

    fn held(h: *Harness) usize {
        return h.dp_impl.unmatched.byteCount();
    }
};

fn delivered(r: *DataReaderImpl) usize {
    r.mu.lock();
    defer r.mu.unlock();
    return r.pending.items.len;
}

fn writerGuid(seed: u8, key: u8) Guid {
    return .{ .prefix = .{ .bytes = @splat(seed) }, .entity_id = .{ .entity_key = .{ 0, 0, key }, .entity_kind = 0x02 } };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "data from an unannounced writer is held once, taken by each reader that matches it, and dropped once matched" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const be = h.reader("Held", .BEST_EFFORT_RELIABILITY_QOS);
    const rel = h.reader("Held", .RELIABLE_RELIABILITY_QOS);
    const other = h.reader("Other", .BEST_EFFORT_RELIABILITY_QOS);

    const w = writerGuid(0x51, 1);
    try h.inject(w, ANY_READER, &.{ 2, 1 });
    // Sent to all three readers, held once.
    try testing.expectEqual(2 * PAYLOAD.len, h.held());
    try testing.expectEqual(@as(usize, 0), delivered(be));

    h.announceWriter(w, "Held");
    try testing.expectEqual(@as(usize, 2), delivered(be));
    try testing.expectEqual(@as(usize, 2), delivered(rel));
    try testing.expectEqual(@as(usize, 0), delivered(other));
    try testing.expectEqual(@as(usize, 0), h.held());

    // Matched now: delivered, not held.
    try h.inject(w, ANY_READER, &.{3});
    try testing.expectEqual(@as(usize, 3), delivered(be));
    try testing.expectEqual(@as(usize, 0), h.held());
}

test "data held for a reader whose match a change to it superseded is taken by the match made in its place" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const Probe = struct {
        var readers: [2]DDS.DataReader = undefined;
        var changed: ?DDS.DataReader = null;
        var rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR;
        fn matchedCount(dr: DDS.DataReader) i32 {
            var st: DDS.SubscriptionMatchedStatus = undefined;
            _ = dr.vtable.get_subscription_matched_status(dr.ptr, &st);
            return st.current_count;
        }
        /// On the first match, makes the reader not matched yet request a
        /// deadline the writer does not offer, before its match is made.
        fn onMatched(_: *anyopaque, _: *const DDS.SubscriptionMatchedStatus, _: ?*anyopaque) callconv(.c) void {
            if (changed != null) return;
            const other = for (readers) |dr| {
                if (matchedCount(dr) == 0) break dr;
            } else return;
            changed = other;
            var q = DDS.DataReaderQos{};
            if (other.vtable.get_qos(other.ptr, &q) != DDS.RETCODE_OK) return;
            defer q.deinit(testing.allocator);
            q.deadline.period = .{ .sec = 1, .nanosec = 0 };
            rc = other.vtable.set_qos(other.ptr, &q);
        }
    };
    const topic = h.dp.create_topic("Held", "T", .{}, null, 0);
    const desc = @as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();
    var qos = DDS.DataReaderQos{};
    qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    for (&Probe.readers) |*dr| {
        dr.* = h.sub.create_datareader(desc, qos, .{ .on_subscription_matched = Probe.onMatched }, DDS.SUBSCRIPTION_MATCHED_STATUS);
    }
    Probe.changed = null;
    Probe.rc = DDS.RETCODE_ERROR;

    const w = writerGuid(0x53, 1);
    try h.inject(w, ANY_READER, &.{ 1, 2 });
    h.announceWriter(w, "Held");
    const other = Probe.changed orelse return error.TestUnexpectedResult;
    try testing.expectEqual(DDS.RETCODE_OK, Probe.rc);
    try testing.expectEqual(@as(i32, 0), Probe.matchedCount(other));
    const other_impl: *DataReaderImpl = @ptrCast(@alignCast(other.ptr));
    try testing.expectEqual(@as(usize, 0), delivered(other_impl));

    // Back within what the writer offers: matched, with what was held.
    var q = DDS.DataReaderQos{};
    try testing.expectEqual(DDS.RETCODE_OK, other.vtable.get_qos(other.ptr, &q));
    defer q.deinit(testing.allocator);
    q.deadline = qos.deadline;
    try testing.expectEqual(DDS.RETCODE_OK, other.vtable.set_qos(other.ptr, &q));
    try testing.expectEqual(@as(i32, 1), Probe.matchedCount(other));
    try testing.expectEqual(@as(usize, 2), delivered(other_impl));
}

test "a historical-data wait satisfied by history held before the match finds it in the reader" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const r = h.readerWith("Held", .RELIABLE_RELIABILITY_QOS, .TRANSIENT_LOCAL_DURABILITY_QOS);
    const dr = r.toDDSDataReader();

    // A TRANSIENT_LOCAL writer that matched this reader first sends its
    // history before the reader has matched it.
    const w = writerGuid(0x52, 1);
    try h.inject(w, eidBytes(r.guid.entity_id), &.{ 1, 2, 3 });
    try testing.expectEqual(3 * PAYLOAD.len, h.held());

    h.announceWriterWith(w, "Held", 1);
    // No HEARTBEAT yet: the reader doesn't know how much history there is.
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, dr.vtable.wait_for_historical_data(dr.ptr, &.{ .sec = 0, .nanosec = 0 }));

    r.proto_reader.handleHeartbeat(w, r.guid.entity_id, 1, 3, 1, true, false);
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.wait_for_historical_data(dr.ptr, &.{ .sec = 0, .nanosec = 0 }));
    try testing.expectEqual(@as(usize, 3), delivered(r));
}

test "nothing is held from a writer once discovery has matched it, whether or not a reader did" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    _ = h.reader("Held", .BEST_EFFORT_RELIABILITY_QOS);

    const w = writerGuid(0x52, 1);
    h.announceWriter(w, "Elsewhere");
    try h.inject(w, ANY_READER, &.{1});
    try testing.expectEqual(@as(usize, 0), h.held());
}

test "data sent to one reader is taken only by that reader" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const a = h.reader("Held", .BEST_EFFORT_RELIABILITY_QOS);
    const b = h.reader("Held", .BEST_EFFORT_RELIABILITY_QOS);

    const w = writerGuid(0x53, 1);
    try h.inject(w, eidBytes(a.guid.entity_id), &.{1});
    try testing.expectEqual(PAYLOAD.len, h.held());
    h.announceWriter(w, "Held");
    try testing.expectEqual(@as(usize, 1), delivered(a));
    try testing.expectEqual(@as(usize, 0), delivered(b));
}

test "held data is dropped when its writer or its participant is lost" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    _ = h.reader("Held", .BEST_EFFORT_RELIABILITY_QOS);

    const w1 = writerGuid(0x54, 1);
    const w2 = writerGuid(0x54, 2);
    const w3 = writerGuid(0x55, 1);
    try h.inject(w1, ANY_READER, &.{1});
    try h.inject(w2, ANY_READER, &.{1});
    try h.inject(w3, ANY_READER, &.{1});
    try testing.expectEqual(3 * PAYLOAD.len, h.held());

    h.dp_impl.disc_callbacks.on_writer_lost(h.dp_impl.disc_callbacks.ctx, w3);
    try testing.expectEqual(2 * PAYLOAD.len, h.held());
    h.dp_impl.disc_callbacks.on_participant_lost(h.dp_impl.disc_callbacks.ctx, .{ .prefix = w1.prefix, .entity_id = EntityIds.participant });
    try testing.expectEqual(@as(usize, 0), h.held());
}

test "a writer lost after it was matched is held for again if it comes back" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const r = h.reader("Held", .BEST_EFFORT_RELIABILITY_QOS);

    const w = writerGuid(0x56, 1);
    h.announceWriter(w, "Held");
    h.dp_impl.disc_callbacks.on_writer_lost(h.dp_impl.disc_callbacks.ctx, w);
    try h.inject(w, ANY_READER, &.{1});
    try testing.expectEqual(PAYLOAD.len, h.held());
    h.announceWriter(w, "Held");
    try testing.expectEqual(@as(usize, 1), delivered(r));
}

test "held data expires one lease after it arrived: the sender's, or this participant's until the sender is discovered" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    _ = h.reader("Held", .BEST_EFFORT_RELIABILITY_QOS);

    // An undiscovered participant's writer: this participant's lease.
    const unknown = writerGuid(0x57, 1);
    try h.inject(unknown, ANY_READER, &.{1});
    // A discovered participant's writer: its lease.
    const known = writerGuid(0x58, 1);
    h.announceParticipant(known.prefix);
    try h.inject(known, ANY_READER, &.{1});
    try testing.expectEqual(2 * PAYLOAD.len, h.held());

    clock.set(@as(i64, REMOTE_LEASE_MS) * std.time.ns_per_ms - 1);
    h.dp_impl.checkTimers();
    try testing.expectEqual(2 * PAYLOAD.len, h.held());
    clock.set(@as(i64, REMOTE_LEASE_MS) * std.time.ns_per_ms);
    h.dp_impl.checkTimers();
    try testing.expectEqual(PAYLOAD.len, h.held());

    clock.set(OWN_LEASE_NS - 1);
    h.dp_impl.checkTimers();
    try testing.expectEqual(PAYLOAD.len, h.held());
    clock.set(OWN_LEASE_NS);
    h.dp_impl.checkTimers();
    try testing.expectEqual(@as(usize, 0), h.held());
}

test "nothing is held from an ignored participant" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    _ = h.reader("Held", .BEST_EFFORT_RELIABILITY_QOS);

    const w = writerGuid(0x59, 1);
    h.announceParticipant(w.prefix);
    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| testing.allocator.free(b[0..handles._maximum]);
    };
    try testing.expectEqual(DDS.RETCODE_OK, h.dp.vtable.get_discovered_participants(h.dp.ptr, &handles));
    try testing.expectEqual(DDS.RETCODE_OK, h.dp.vtable.ignore_participant(h.dp.ptr, handles._buffer.?[0]));
    try h.inject(w, ANY_READER, &.{1});
    try testing.expectEqual(@as(usize, 0), h.held());
}

test "nothing is held from a built-in or vendor-specific writer" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    _ = h.reader("Held", .BEST_EFFORT_RELIABILITY_QOS);

    const prefix = GuidPrefix{ .bytes = @splat(0x5A) };
    try h.inject(.{ .prefix = prefix, .entity_id = EntityIds.sedp_builtin_publications_writer }, ANY_READER, &.{1});
    try h.inject(.{ .prefix = prefix, .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0x42 } }, ANY_READER, &.{1});
    try testing.expectEqual(@as(usize, 0), h.held());
    try h.inject(writerGuid(0x5A, 1), ANY_READER, &.{1});
    try testing.expectEqual(PAYLOAD.len, h.held());
}
