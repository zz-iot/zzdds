//! Phase 24 item 8: MockTransport-based DCPS integration tests.
//!
//! Exercises the full DCPS stack (SPDP → SEDP → DataWriter → DataReader) using
//! MockTransport instead of real UDP sockets.  Tests pass in sandboxed CI
//! environments that have no network access.
//!
//! Mock topology (RTPS §9.6.1.1 formula: PB=7400, DG=250, PG=2, D1=10, D3=11):
//!   Writer: IP 127.0.0.10, meta-unicast 7410, data-unicast 7411
//!   Reader: IP 127.0.0.11, meta-unicast 7412, data-unicast 7413
//!
//! Driving delivery:
//!   `net.deliverAll()` flushes one round of queued packets synchronously.
//!   SPDP timer threads re-announce every 100 ms; 20 ms sleeps between rounds
//!   give the timer a chance to fire so both sides complete SPDP discovery within
//!   a few hundred milliseconds.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const MockNetwork = zzdds.mock_transport.MockNetwork;
const MockTransport = zzdds.mock_transport.MockTransport;
const Locator = zzdds.transport.Locator;
const SpdpSedpDiscovery = zzdds.combined_discovery.SpdpSedpDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const nil = zzdds.dcps;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;
const time_mod = zzdds.util.time;

const noop_security = zzdds.noop_security.noop_security_plugins;

const IP_W: [4]u8 = .{ 127, 0, 0, 10 };
const IP_R: [4]u8 = .{ 127, 0, 0, 11 };
const PORT_META_W: u16 = 7410;
const PORT_META_R: u16 = 7412;

const PAYLOAD_A = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAA };
const PAYLOAD_B = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xBB };
const PAYLOAD_C = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xCC };

fn runMockLoopback(
    alloc: std.mem.Allocator,
    dw_qos: DDS.DataWriterQos,
    dr_qos: DDS.DataReaderQos,
    payloads: []const []const u8,
    expected: []const []const u8,
) !void {
    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    // ── Reader side (created first so it joins multicast before writer announces) ──
    const mock_r = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_R, PORT_META_R)});
    defer mock_r.deinit();
    // 100 ms announcement period lets the SPDP timer fire during the poll loop.
    const disc_r = try SpdpSedpDiscovery.init(alloc, mock_r.transport(), 0, 100);
    var factory_r = try DomainParticipantFactoryImpl.init(
        alloc,
        mock_r.transport(),
        disc_r.toDiscovery(),
        noop_security,
        .random,
        .{},
    );
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }

    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf_r.delete_participant(dp_r);

    const sub_r = dp_r.vtable.create_subscriber(dp_r.ptr, .{}, nil.nil_sub_listener, 0);
    const topic_r = dp_r.vtable.create_topic(
        dp_r.ptr,
        "MockTopic",
        "MockType",
        .{},
        nil.nil_topic_listener,
        0,
    );
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    const dr = sub_r.vtable.create_datareader(
        sub_r.ptr,
        topic_desc_r,
        dr_qos,
        nil.nil_dr_listener,
        0,
    );
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    // ── Writer side ───────────────────────────────────────────────────────────
    const mock_w = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_W, PORT_META_W)});
    defer mock_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, mock_w.transport(), 0, 100);
    var factory_w = try DomainParticipantFactoryImpl.init(
        alloc,
        mock_w.transport(),
        disc_w.toDiscovery(),
        noop_security,
        .random,
        .{},
    );
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }

    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf_w.delete_participant(dp_w);

    const pub_w = dp_w.vtable.create_publisher(dp_w.ptr, .{}, nil.nil_pub_listener, 0);
    const topic_w = dp_w.vtable.create_topic(
        dp_w.ptr,
        "MockTopic",
        "MockType",
        .{},
        nil.nil_topic_listener,
        0,
    );
    const dw = pub_w.vtable.create_datawriter(pub_w.ptr, topic_w, dw_qos, nil.nil_dw_listener, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    // Write payloads before discovery.  The writer history cache holds them and
    // `replayHistoryToProxyLocked` sends them once the reader proxy is established.
    for (payloads) |p| {
        _ = try dw_impl.writeRaw(
            .alive,
            RtpsTimestamp.now(),
            history_mod.INSTANCE_HANDLE_NIL,
            std.mem.zeroes([16]u8),
            p,
        );
    }

    // ── Drive discovery + delivery ────────────────────────────────────────────
    // Pump the mock network until `expected.len` samples arrive or 3 s elapses.
    // deliverAll() flushes one round of queued packets; the 20 ms sleep gives the
    // SPDP timer thread (100 ms period) time to fire between rounds so both sides
    // complete SPDP discovery and SEDP endpoint matching.
    var samples: std.ArrayList([]u8) = .empty;
    defer {
        for (samples.items) |s| alloc.free(s);
        samples.deinit(alloc);
    }

    const deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (samples.items.len < expected.len and time_mod.nanoTimestamp() < deadline) {
        net.deliverAll();
        while (dr_impl.takeRaw()) |sample| {
            try samples.append(alloc, sample.data);
        }
        if (samples.items.len < expected.len)
            time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(expected.len, samples.items.len);
    for (expected, samples.items) |exp, got| {
        try std.testing.expectEqualSlices(u8, exp, got);
    }
}

test "mock_loopback: BEST_EFFORT single sample" {
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    const p: []const u8 = &PAYLOAD_A;
    try runMockLoopback(std.testing.allocator, dw_qos, dr_qos, &.{p}, &.{p});
}

test "mock_loopback: RELIABLE single sample" {
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const p: []const u8 = &PAYLOAD_A;
    try runMockLoopback(std.testing.allocator, dw_qos, dr_qos, &.{p}, &.{p});
}

test "mock_loopback: RELIABLE KEEP_ALL three samples" {
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    try runMockLoopback(
        std.testing.allocator,
        dw_qos,
        dr_qos,
        &.{ &PAYLOAD_A, &PAYLOAD_B, &PAYLOAD_C },
        &.{ &PAYLOAD_A, &PAYLOAD_B, &PAYLOAD_C },
    );
}

test "mock_loopback: incompatible QoS — best_effort writer vs reliable reader" {
    const alloc = std.testing.allocator;
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mock_r = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_R, PORT_META_R)});
    defer mock_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, mock_r.transport(), 0, 100);
    var factory_r = try DomainParticipantFactoryImpl.init(
        alloc,
        mock_r.transport(),
        disc_r.toDiscovery(),
        noop_security,
        .random,
        .{},
    );
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf_r.delete_participant(dp_r);
    const sub_r = dp_r.vtable.create_subscriber(dp_r.ptr, .{}, nil.nil_sub_listener, 0);
    const topic_r = dp_r.vtable.create_topic(
        dp_r.ptr,
        "IncompatTopic",
        "IncompatType",
        .{},
        nil.nil_topic_listener,
        0,
    );
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    const dr = sub_r.vtable.create_datareader(
        sub_r.ptr,
        topic_desc_r,
        dr_qos,
        nil.nil_dr_listener,
        0,
    );
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    const mock_w = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_W, PORT_META_W)});
    defer mock_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, mock_w.transport(), 0, 100);
    var factory_w = try DomainParticipantFactoryImpl.init(
        alloc,
        mock_w.transport(),
        disc_w.toDiscovery(),
        noop_security,
        .random,
        .{},
    );
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf_w.delete_participant(dp_w);
    const pub_w = dp_w.vtable.create_publisher(dp_w.ptr, .{}, nil.nil_pub_listener, 0);
    const topic_w = dp_w.vtable.create_topic(
        dp_w.ptr,
        "IncompatTopic",
        "IncompatType",
        .{},
        nil.nil_topic_listener,
        0,
    );
    const dw = pub_w.vtable.create_datawriter(pub_w.ptr, topic_w, dw_qos, nil.nil_dw_listener, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    _ = try dw_impl.writeRaw(
        .alive,
        RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        &PAYLOAD_A,
    );

    // Drive discovery until both sides register an incompatible-QoS event.
    const deadline_ns = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deadline_ns) {
        net.deliverAll();
        if (dr_impl.incompat_total > 0 and dw_impl.incompat_total > 0) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    try std.testing.expect(dr_impl.incompat_total > 0);
    try std.testing.expect(dw_impl.incompat_total > 0);

    // No sample should have been delivered.
    try std.testing.expect(dr_impl.takeRaw() == null);
}
