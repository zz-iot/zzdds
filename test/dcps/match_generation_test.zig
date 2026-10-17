//! A remote endpoint's match is installed only while the discovery
//! generation it was decided under is current
//! (docs/design/concurrency/architecture.md#remote-endpoint-match-and-loss):
//! a loss, or a newer announcement, that comes between deciding a match and
//! installing it wins.
//!
//! The participant decides matches under its lock and installs them after
//! releasing it, raising incompatible-QoS listeners in between. Each test
//! has an incompatible endpoint whose listener reports the loss (or a newer
//! announcement) in that window. Discovery events are fired directly (a
//! discovery plugin that only captures its callbacks), DATA is injected as
//! raw RTPS from a second MockTransport, and time is a ManualClock.

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
const DataWriterImpl = dcps.DataWriterImpl;
const TopicImpl = dcps.TopicImpl;
const ManualClock = zzdds.util.time.ManualClock;

const Discovery = iface.Discovery;
const Guid = iface.Guid;
const GuidPrefix = zzdds.rtps.GuidPrefix;
const EntityIds = zzdds.rtps.EntityIds;
const Locator = mock_tr.Locator;
const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;

const testing = std.testing;

// ── Discovery that only captures its callbacks ────────────────────────────────

const CapturingDisc = struct {
    const vtable = Discovery.Vtable{
        .start = start,
        .stop = noop,
        .announce_writer = noopAW,
        .retract_writer = noopGuid,
        .announce_reader = noopAR,
        .retract_reader = noopGuid,
        .deinit = noop,
        .wlp_tick = noopWlpTick,
    };

    fn start(_: *anyopaque, _: *const iface.ParticipantAnnouncement, _: *const iface.Callbacks) anyerror!void {}
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

fn rtpsData(buf: *std.ArrayListUnmanaged(u8), src: GuidPrefix, writer_eid: [4]u8, sn: u32) !void {
    const alloc = testing.allocator;
    try buf.appendSlice(alloc, "RTPS");
    try buf.appendSlice(alloc, &[_]u8{ 2, 3, 0x01, 0x10 });
    try buf.appendSlice(alloc, &src.bytes);
    // Little-endian, data present, to every reader.
    var smh = [_]u8{ 0x15, 0x05, 0, 0 };
    std.mem.writeInt(u16, smh[2..4], 20 + PAYLOAD.len, .little);
    try buf.appendSlice(alloc, &smh);
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0x10, 0 });
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });
    try buf.appendSlice(alloc, &writer_eid);
    var sn_bytes: [8]u8 = undefined;
    std.mem.writeInt(i32, sn_bytes[0..4], 0, .little);
    std.mem.writeInt(u32, sn_bytes[4..8], sn, .little);
    try buf.appendSlice(alloc, &sn_bytes);
    try buf.appendSlice(alloc, &PAYLOAD);
}

// ── Harness ───────────────────────────────────────────────────────────────────

const TOPIC = "Matched";

/// Announced QoS: wire reliability kind 2 is RELIABLE, 1 BEST_EFFORT;
/// ownership kind 1 is EXCLUSIVE.
const Remote = struct {
    reliability: u32 = 2,
    ownership_kind: u32 = 0,
    ownership_strength: ?i32 = null,
    /// Finite liveliness lease, in seconds; null for infinite.
    lease_s: ?i32 = null,
};

const Harness = struct {
    net: *MockNetwork,
    transport: *MockTransport,
    injector: *MockTransport,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,
    dp_impl: *DomainParticipantImpl,
    sub: DDS.Subscriber,
    pub_: DDS.Publisher,
    topic: DDS.Topic,

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
        h.pub_ = h.dp.create_publisher(.{}, null, 0);
        h.topic = h.dp.create_topic(TOPIC, "T", .{}, null, 0);
    }

    fn deinit(h: *Harness) void {
        _ = h.dp.vtable.delete_contained_entities(h.dp.ptr);
        _ = h.factory.toDDSFactory().delete_participant(h.dp);
        h.factory.deinit();
        h.injector.deinit();
        h.transport.deinit();
        h.net.deinit();
    }

    fn reader(h: *Harness, qos: DDS.DataReaderQos, listener: ?DDS.DataReaderListener) *DataReaderImpl {
        return h.readerMask(qos, listener, if (listener != null) DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS else 0);
    }

    fn readerMask(h: *Harness, qos: DDS.DataReaderQos, listener: ?DDS.DataReaderListener, mask: DDS.StatusMask) *DataReaderImpl {
        const desc = @as(*TopicImpl, @ptrCast(@alignCast(h.topic.ptr))).toTopicDescription();
        const dr = h.sub.create_datareader(desc, qos, listener, mask);
        return @ptrCast(@alignCast(dr.ptr));
    }

    fn writer(h: *Harness, qos: DDS.DataWriterQos, listener: ?DDS.DataWriterListener) *DataWriterImpl {
        const mask: DDS.StatusMask = if (listener != null) DDS.OFFERED_INCOMPATIBLE_QOS_STATUS else 0;
        const dw = h.pub_.create_datawriter(h.topic, qos, listener, mask);
        return @ptrCast(@alignCast(dw.ptr));
    }

    fn announceWriter(h: *Harness, guid: Guid, remote: Remote) void {
        var repr = [_]i16{2};
        var q = iface.DiscoveredWriterData{
            .reliability = .{ .kind = remote.reliability, .max_blocking_time = .{} },
            .history = .{ .kind = 0, .depth = 1 },
            .ownershipKind = remote.ownership_kind,
            .ownershipStrength = remote.ownership_strength,
            .liveliness = if (remote.lease_s) |l| .{ .kind = 0, .lease_duration = .{ .seconds = l, .fraction = 0 } } else null,
            .dataRepresentation = .{ ._maximum = 1, ._length = 1, ._buffer = &repr, ._release = false },
        };
        const data = iface.WriterData{
            .guid = guid,
            .participant_guid = .{ .prefix = guid.prefix, .entity_id = EntityIds.participant },
            .topic_name = TOPIC,
            .type_name = "T",
            .qos = &q,
            .unicast_locators = &.{},
            .multicast_locators = &.{},
            .type_object = &.{},
        };
        h.dp_impl.disc_callbacks.on_writer_discovered(h.dp_impl.disc_callbacks.ctx, &data);
    }

    fn announceReader(h: *Harness, guid: Guid) void {
        var repr = [_]i16{2};
        var q = iface.DiscoveredReaderData{
            .reliability = .{ .kind = 2, .max_blocking_time = .{} },
            .dataRepresentation = .{ ._maximum = 1, ._length = 1, ._buffer = &repr, ._release = false },
        };
        const data = iface.ReaderData{
            .guid = guid,
            .participant_guid = .{ .prefix = guid.prefix, .entity_id = EntityIds.participant },
            .topic_name = TOPIC,
            .type_name = "T",
            .qos = &q,
            .unicast_locators = &.{},
            .multicast_locators = &.{},
        };
        h.dp_impl.disc_callbacks.on_reader_discovered(h.dp_impl.disc_callbacks.ctx, &data);
    }

    fn loseWriter(h: *Harness, guid: Guid) void {
        h.dp_impl.disc_callbacks.on_writer_lost(h.dp_impl.disc_callbacks.ctx, guid);
    }

    fn loseReader(h: *Harness, guid: Guid) void {
        h.dp_impl.disc_callbacks.on_reader_lost(h.dp_impl.disc_callbacks.ctx, guid);
    }

    fn loseParticipant(h: *Harness, prefix: GuidPrefix) void {
        h.dp_impl.disc_callbacks.on_participant_lost(h.dp_impl.disc_callbacks.ctx, .{ .prefix = prefix, .entity_id = EntityIds.participant });
    }

    fn inject(h: *Harness, writer_guid: Guid, sn: u32) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(testing.allocator);
        const eid = writer_guid.entity_id.entity_key ++ [1]u8{writer_guid.entity_id.entity_kind};
        try rtpsData(&buf, writer_guid.prefix, eid, sn);
        try h.injector.transport().send(&Locator.udp4(.{ 127, 0, 0, 1 }, h.dp_impl.data_listen_port), buf.items);
        h.net.deliverAll();
    }

    fn held(h: *Harness) usize {
        return h.dp_impl.unmatched.byteCount();
    }
};

fn endpointGuid(seed: u8, key: u8, kind: u8) Guid {
    return .{ .prefix = .{ .bytes = @as([12]u8, @splat(seed)) }, .entity_id = .{ .entity_key = .{ 0, 0, key }, .entity_kind = kind } };
}

const WRITER_KIND: u8 = 0x02;
const READER_KIND: u8 = 0x07;

fn delivered(r: *DataReaderImpl) usize {
    r.mu.lock();
    defer r.mu.unlock();
    return r.pending.items.len;
}

fn subMatched(r: *DataReaderImpl) DDS.SubscriptionMatchedStatus {
    var s: DDS.SubscriptionMatchedStatus = .{};
    const dr = r.toDDSDataReader();
    _ = dr.vtable.get_subscription_matched_status(dr.ptr, &s);
    return s;
}

fn pubMatched(w: *DataWriterImpl) DDS.PublicationMatchedStatus {
    var s: DDS.PublicationMatchedStatus = .{};
    const dw = w.toDDSDataWriter();
    _ = dw.vtable.get_publication_matched_status(dw.ptr, &s);
    return s;
}

// ── An incompatible endpoint's listener, run between decision and install ────

/// Runs `then` once, from the first incompatible-QoS callback.
const Between = struct {
    h: *Harness,
    then: *const fn (*Between) void,
    guid: Guid = undefined,
    fired: bool = false,

    fn readerListener(self: *Between) DDS.DataReaderListener {
        return .{ .listener_data = self, .on_requested_incompatible_qos = onRequested };
    }

    fn writerListener(self: *Between) DDS.DataWriterListener {
        return .{ .listener_data = self, .on_offered_incompatible_qos = onOffered };
    }

    fn onRequested(_: *anyopaque, _: *const DDS.RequestedIncompatibleQosStatus, ld: ?*anyopaque) callconv(.c) void {
        run(ld);
    }

    fn onOffered(_: *anyopaque, _: *const DDS.OfferedIncompatibleQosStatus, ld: ?*anyopaque) callconv(.c) void {
        run(ld);
    }

    fn run(ld: ?*anyopaque) void {
        const self: *Between = @ptrCast(@alignCast(ld));
        if (self.fired) return;
        self.fired = true;
        self.then(self);
    }
};

/// Requests TRANSIENT_LOCAL durability, which an announced (VOLATILE)
/// writer does not offer.
fn incompatibleReaderQos() DDS.DataReaderQos {
    var qos = DDS.DataReaderQos{};
    qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    return qos;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "a writer lost before its match is installed is not matched, and is held for again" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const w = endpointGuid(0x61, 1, WRITER_KIND);
    var between = Between{ .h = &h, .guid = w, .then = struct {
        fn f(b: *Between) void {
            b.h.loseWriter(b.guid);
        }
    }.f };
    _ = h.reader(incompatibleReaderQos(), between.readerListener());
    const r = h.reader(.{}, null);

    h.announceWriter(w, .{});
    try testing.expect(between.fired);
    try testing.expectEqual(@as(usize, 0), r.proto_reader.matchedWriterCount());
    try testing.expectEqual(@as(i32, 0), subMatched(r).total_count);

    // Not settled: what it sends is held until it is matched again.
    try h.inject(w, 1);
    try testing.expectEqual(PAYLOAD.len, h.held());
    h.announceWriter(w, .{});
    try testing.expectEqual(@as(usize, 1), r.proto_reader.matchedWriterCount());
    try testing.expectEqual(@as(usize, 1), delivered(r));
    const s = subMatched(r);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.current_count);
}

test "an older announcement of a writer does not overwrite a newer one" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const w = endpointGuid(0x62, 1, WRITER_KIND);
    var between = Between{ .h = &h, .guid = w, .then = struct {
        fn f(b: *Between) void {
            b.h.announceWriter(b.guid, .{ .ownership_kind = 1, .ownership_strength = 9 });
        }
    }.f };
    _ = h.reader(incompatibleReaderQos(), between.readerListener());
    var qos = DDS.DataReaderQos{};
    qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    const r = h.reader(qos, null);

    h.announceWriter(w, .{ .ownership_kind = 1, .ownership_strength = 5 });
    try testing.expect(between.fired);
    try testing.expectEqual(@as(usize, 1), r.proto_reader.matchedWriterCount());
    try testing.expectEqual(@as(i32, 1), subMatched(r).total_count);
    r.mu.lock();
    defer r.mu.unlock();
    try testing.expectEqual(@as(?i32, 9), r.writer_strengths.get(w));
}

test "a reader lost before its match is installed is not matched" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const rd = endpointGuid(0x63, 1, READER_KIND);
    var between = Between{ .h = &h, .guid = rd, .then = struct {
        fn f(b: *Between) void {
            b.h.loseReader(b.guid);
        }
    }.f };
    // Offers BEST_EFFORT to a reader that requests RELIABLE.
    var best_effort = DDS.DataWriterQos{};
    best_effort.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    _ = h.writer(best_effort, between.writerListener());
    var reliable = DDS.DataWriterQos{};
    reliable.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const w = h.writer(reliable, null);

    h.announceReader(rd);
    try testing.expect(between.fired);
    try testing.expectEqual(@as(usize, 0), w.proto_writer.matchedReaderCount());
    try testing.expectEqual(@as(i32, 0), pubMatched(w).total_count);

    h.announceReader(rd);
    try testing.expectEqual(@as(usize, 1), w.proto_writer.matchedReaderCount());
    const s = pubMatched(w);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.current_count);
}

test "a reader created as its writers' participant is lost does not match them" {
    // A new reader matches writers discovered before it (its announcement's
    // own matches), after the participant releases its lock, as discovery's
    // matches are.
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const good = endpointGuid(0x64, 1, WRITER_KIND);
    const bad = endpointGuid(0x64, 2, WRITER_KIND);
    h.announceWriter(good, .{});
    // Offers BEST_EFFORT to the RELIABLE reader below.
    h.announceWriter(bad, .{ .reliability = 1 });
    var between = Between{ .h = &h, .guid = good, .then = struct {
        fn f(b: *Between) void {
            b.h.loseParticipant(b.guid.prefix);
        }
    }.f };
    var qos = DDS.DataReaderQos{};
    qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const r = h.reader(qos, between.readerListener());
    try testing.expect(between.fired);
    try testing.expectEqual(@as(usize, 0), r.proto_reader.matchedWriterCount());
    try testing.expectEqual(@as(i32, 0), subMatched(r).total_count);
}

test "a writer lost after its match is installed is unmatched, with its state" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    var qos = DDS.DataReaderQos{};
    qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    const r = h.reader(qos, null);
    const w = endpointGuid(0x65, 1, WRITER_KIND);

    h.announceWriter(w, .{ .ownership_kind = 1, .ownership_strength = 3 });
    try testing.expectEqual(@as(usize, 1), r.proto_reader.matchedWriterCount());
    h.loseWriter(w);
    try testing.expectEqual(@as(usize, 0), r.proto_reader.matchedWriterCount());
    const s = subMatched(r);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.current_count);
    r.mu.lock();
    defer r.mu.unlock();
    try testing.expectEqual(@as(?i32, null), r.writer_strengths.get(w));
}

test "a live writer's loss raises on_liveliness_changed" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    const Seen = struct {
        calls: u32 = 0,
        last: DDS.LivelinessChangedStatus = .{},
        fn cb(_: *anyopaque, st: *const DDS.LivelinessChangedStatus, ld: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ld));
            self.calls += 1;
            self.last = st.*;
        }
    };
    var seen: Seen = .{};
    _ = h.readerMask(.{}, .{ .listener_data = &seen, .on_liveliness_changed = Seen.cb }, DDS.LIVELINESS_CHANGED_STATUS);
    const w = endpointGuid(0x66, 1, WRITER_KIND);

    h.announceWriter(w, .{ .lease_s = 10 });
    try testing.expectEqual(@as(u32, 1), seen.calls);
    try testing.expectEqual(@as(i32, 1), seen.last.alive_count);

    h.loseWriter(w);
    try testing.expectEqual(@as(u32, 2), seen.calls);
    try testing.expectEqual(@as(i32, 0), seen.last.alive_count);
    try testing.expectEqual(@as(i32, -1), seen.last.alive_count_change);
}

test "a reader discovered while its writer is being created is counted" {
    var clock = ManualClock.init(0);
    var h: Harness = undefined;
    try h.init(&clock);
    defer h.deinit();
    // Discovery can match a writer from the moment the publisher registers
    // its matched notify, before create_datawriter returns: announce a
    // reader right then.
    const Window = struct {
        const Cbs = @FieldType(dcps.PublisherImpl, "cbs");
        var harness: *Harness = undefined;
        var original: @FieldType(Cbs, "register_matched_notify") = undefined;
        var reader_guid: Guid = undefined;

        fn registerMatchedNotify(
            ctx: *anyopaque,
            handle: DDS.InstanceHandle_t,
            notify_ctx: *anyopaque,
            notify_fn: *const fn (*anyopaque, DDS.InstanceHandle_t, bool) void,
        ) void {
            original(ctx, handle, notify_ctx, notify_fn);
            harness.announceReader(reader_guid);
        }
    };
    const pub_impl: *dcps.PublisherImpl = @ptrCast(@alignCast(h.pub_.ptr));
    const rd = endpointGuid(0x67, 1, READER_KIND);
    Window.harness = &h;
    Window.original = pub_impl.cbs.register_matched_notify;
    Window.reader_guid = rd;
    pub_impl.cbs.register_matched_notify = Window.registerMatchedNotify;
    var reliable = DDS.DataWriterQos{};
    reliable.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const w = h.writer(reliable, null);
    pub_impl.cbs.register_matched_notify = Window.original;

    try testing.expectEqual(@as(usize, 1), w.proto_writer.matchedReaderCount());
    var s = pubMatched(w);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.current_count);

    h.loseReader(rd);
    s = pubMatched(w);
    try testing.expectEqual(@as(i32, 0), s.current_count);
}
