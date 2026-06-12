//! IntraProcessDelivery DCPS integration tests.
//!
//! These tests use IntraProcessDelivery (MemoryTransport + DirectDiscovery) in
//! place of SpdpSedpDiscovery + MockTransport.  Benefits over mock_loopback_test:
//!   - No `deliverAll()` pump — data delivery is synchronous
//!   - No `sleepNs()` loops — endpoint matching is synchronous (no SPDP timer)
//!   - Tests are pure functional assertions with no timing dependencies
//!
//! These tests form the seed suite for Phase 30 (QoS runtime) and Phase 31
//! (instance lifecycle / read-take semantics).  MockTransport tests in
//! mock_loopback_test.zig are retained; they cover the RTPS protocol layer
//! (Heartbeat/AckNack, SPDP/SEDP sequences) not the DCPS API layer.
//!
//! Topology (two factories, shared IntraProcessDelivery):
//!   Writer factory: participant → publisher → DataWriter
//!   Reader factory: participant → subscriber → DataReader
//!   DirectDiscovery fires on_writer/reader_discovered synchronously.
//!   MemoryTransport delivers RTPS DATA synchronously on write().

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;

const testing = std.testing;

// CDR_LE encapsulation header + distinguishable payload byte.
const PAYLOAD_A = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAA };
const PAYLOAD_B = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xBB };
const PAYLOAD_C = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xCC };

// ── Test fixture ──────────────────────────────────────────────────────────────

/// Wires up two factory instances (writer side + reader side) sharing one
/// IntraProcessDelivery bundle. Endpoint matching and data delivery are both
/// synchronous — no pump or sleep required.
const Fixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,

    // Writer side
    t_w: *zzdds.intraprocess.MemoryTransport,
    d_w: *zzdds.intraprocess.DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    pub_w: DDS.Publisher,
    topic_w: DDS.Topic,

    // Reader side
    t_r: *zzdds.intraprocess.MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,

    fn init(
        alloc: std.mem.Allocator,
        topic_name: [:0]const u8,
        type_name: [:0]const u8,
    ) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();

        // Writer side.
        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(
            alloc,
            t_w.transport(),
            d_w.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory_w.deinit();
        const dpf_w = factory_w.toDDSFactory();
        const dp_w = dpf_w.create_participant(0, .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic(
            topic_name,
            type_name,
            .{},
            null,
            0,
        );

        // Reader side.
        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(
            alloc,
            t_r.transport(),
            d_r.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory_r.deinit();
        const dpf_r = factory_r.toDDSFactory();
        const dp_r = dpf_r.create_participant(0, .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic(
            topic_name,
            type_name,
            .{},
            null,
            0,
        );

        return .{
            .alloc = alloc,
            .delivery = delivery,
            .t_w = t_w,
            .d_w = d_w,
            .factory_w = factory_w,
            .dp_w = dp_w,
            .pub_w = pub_w,
            .topic_w = topic_w,
            .t_r = t_r,
            .d_r = d_r,
            .factory_r = factory_r,
            .dp_r = dp_r,
            .sub_r = sub_r,
            .topic_r = topic_r,
        };
    }

    fn deinit(self: *Fixture) void {
        _ = self.factory_w.toDDSFactory().delete_participant(self.dp_w);
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        self.factory_w.deinit();
        self.factory_r.deinit();
        self.d_w.deinit();
        self.d_r.deinit();
        self.t_w.deinit();
        self.t_r.deinit();
        self.delivery.deinit();
    }

    /// Create a matched writer+reader pair. Endpoint matching happens
    /// synchronously inside create_datawriter/create_datareader via
    /// DirectDiscovery — no pump needed.
    fn makeWriterReader(
        self: *Fixture,
        dw_qos: DDS.DataWriterQos,
        dr_qos: DDS.DataReaderQos,
    ) struct { dw: *DataWriterImpl, dr: *DataReaderImpl } {
        const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr = self.sub_r.create_datareader(
            topic_desc_r,
            dr_qos,
            null,
            0,
        );
        const dw = self.pub_w.create_datawriter(
            self.topic_w,
            dw_qos,
            null,
            0,
        );
        return .{
            .dw = @ptrCast(@alignCast(dw.ptr)),
            .dr = @ptrCast(@alignCast(dr.ptr)),
        };
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn writeRaw(dw: *DataWriterImpl, payload: []const u8) !void {
    _ = try dw.writeRaw(
        .alive,
        RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        payload,
    );
}

fn drainSamples(alloc: std.mem.Allocator, dr: *DataReaderImpl) ![][]u8 {
    var samples: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (samples.items) |s| alloc.free(s);
        samples.deinit(alloc);
    }
    while (dr.takeRaw()) |sample| try samples.append(alloc, sample.data);
    return samples.toOwnedSlice(alloc);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "intraprocess: BEST_EFFORT single sample delivered synchronously" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, "IPTopic", "IPType");
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    try writeRaw(pair.dw, &PAYLOAD_A);

    // No deliverAll(), no sleep — delivery is synchronous.
    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 1), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
}

test "intraprocess: BEST_EFFORT three samples in order" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, "IPTopic", "IPType");
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    try writeRaw(pair.dw, &PAYLOAD_A);
    try writeRaw(pair.dw, &PAYLOAD_B);
    try writeRaw(pair.dw, &PAYLOAD_C);

    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 3), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
    try testing.expectEqualSlices(u8, &PAYLOAD_B, samples[1]);
    try testing.expectEqualSlices(u8, &PAYLOAD_C, samples[2]);
}

test "intraprocess: incompatible QoS — no delivery, incompat counter incremented" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, "IPTopic", "IPType");
    defer fx.deinit();

    // BEST_EFFORT writer vs RELIABLE reader — incompatible by DDS spec.
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    try writeRaw(pair.dw, &PAYLOAD_A);

    // No sample delivered — proxies were never added due to QoS mismatch.
    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 0), samples.len);
    try testing.expect(pair.dr.incompat_total > 0);
    try testing.expect(pair.dw.incompat_total > 0);
}

test "intraprocess: writer created before reader — reader gets history via TRANSIENT_LOCAL" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, "IPTopic", "IPType");
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    // Write BEFORE creating the reader.
    const topic_w = fx.topic_w;
    const dw_raw = fx.pub_w.create_datawriter(
        topic_w,
        dw_qos,
        null,
        0,
    );
    const dw: *DataWriterImpl = @ptrCast(@alignCast(dw_raw.ptr));
    try writeRaw(dw, &PAYLOAD_A);
    try writeRaw(dw, &PAYLOAD_B);

    // Now create the reader — DirectDiscovery fires on_reader_discovered
    // synchronously, which triggers history replay via addMatchedReader.
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(fx.topic_r.ptr))).toTopicDescription();
    const dr_raw = fx.sub_r.create_datareader(
        topic_desc_r,
        dr_qos,
        null,
        0,
    );
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    const samples = try drainSamples(alloc, dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 2), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
    try testing.expectEqualSlices(u8, &PAYLOAD_B, samples[1]);
}

test "intraprocess: same-participant writer and reader — no self-delivery" {
    const alloc = testing.allocator;
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();

    // Single participant owns both writer and reader.
    const t = try delivery.newTransport();
    defer t.deinit();
    const d = try delivery.newDiscovery();
    defer d.deinit();
    var factory = try DomainParticipantFactoryImpl.init(
        alloc,
        t.transport(),
        d.toDiscovery(),
        noop_security,
        .spec_random,
        .{},
    );
    defer factory.deinit();
    const dpf = factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const publisher = dp.create_publisher(.{}, null, 0);
    const subscriber = dp.create_subscriber(.{}, null, 0);
    const topic = dp.create_topic(
        "SelfTopic",
        "SelfType",
        .{},
        null,
        0,
    );
    const topic_desc = @as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();

    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;

    const dr_raw = subscriber.create_datareader(topic_desc, dr_qos, null, 0);
    const dw_raw = publisher.create_datawriter(topic, dw_qos, null, 0);

    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));
    const dw: *DataWriterImpl = @ptrCast(@alignCast(dw_raw.ptr));

    try writeRaw(dw, &PAYLOAD_A);

    // DDS spec: a writer does not match its own reader on the same participant.
    // DirectDiscovery does not fire on_writer_discovered for the announcing participant's
    // own callbacks, so the reader proxy is never added — no sample delivered.
    const samples = try drainSamples(alloc, dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 0), samples.len);
}
