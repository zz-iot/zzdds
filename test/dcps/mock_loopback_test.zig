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
        .spec_random,
        .{},
    );
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }

    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, null, 0);
    defer _ = dpf_r.delete_participant(dp_r);

    const sub_r = dp_r.create_subscriber(.{}, null, 0);
    const topic_r = dp_r.create_topic(
        "MockTopic",
        "MockType",
        .{},
        null,
        0,
    );
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    const dr = sub_r.create_datareader(
        topic_desc_r,
        dr_qos,
        null,
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
        .spec_random,
        .{},
    );
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }

    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, null, 0);
    defer _ = dpf_w.delete_participant(dp_w);

    const pub_w = dp_w.create_publisher(.{}, null, 0);
    const topic_w = dp_w.create_topic(
        "MockTopic",
        "MockType",
        .{},
        null,
        0,
    );
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
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
    // Reader must request TRANSIENT_LOCAL+ to receive the pre-match replay
    // below; a VOLATILE-requesting reader is not entitled to historical data
    // regardless of what durability the writer offers.
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const p: []const u8 = &PAYLOAD_A;
    try runMockLoopback(std.testing.allocator, dw_qos, dr_qos, &.{p}, &.{p});
}

test "mock_loopback: RELIABLE single sample" {
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    // Reader must request TRANSIENT_LOCAL+ to receive the pre-match replay
    // below; a VOLATILE-requesting reader is not entitled to historical data
    // regardless of what durability the writer offers.
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
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
    // Reader must request TRANSIENT_LOCAL+ to receive the pre-match replay
    // below; a VOLATILE-requesting reader is not entitled to historical data
    // regardless of what durability the writer offers.
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
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
        .spec_random,
        .{},
    );
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, null, 0);
    defer _ = dpf_r.delete_participant(dp_r);
    const sub_r = dp_r.create_subscriber(.{}, null, 0);
    const topic_r = dp_r.create_topic(
        "IncompatTopic",
        "IncompatType",
        .{},
        null,
        0,
    );
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    const dr = sub_r.create_datareader(
        topic_desc_r,
        dr_qos,
        null,
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
        .spec_random,
        .{},
    );
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, null, 0);
    defer _ = dpf_w.delete_participant(dp_w);
    const pub_w = dp_w.create_publisher(.{}, null, 0);
    const topic_w = dp_w.create_topic(
        "IncompatTopic",
        "IncompatType",
        .{},
        null,
        0,
    );
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
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

test "mock_loopback: suspend_publications holds writes across end_coherent_changes" {
    // Regression for the suspend_active fix.  Without it, end_coherent_changes
    // cleared coherent_active on the writer and write B bypassed suspension,
    // arriving at the reader before resume_publications was called.
    const alloc = std.testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mock_r = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_R, PORT_META_R)});
    defer mock_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, mock_r.transport(), 0, 100);
    var factory_r = try DomainParticipantFactoryImpl.init(alloc, mock_r.transport(), disc_r.toDiscovery(), noop_security, .spec_random, .{});
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, null, 0);
    defer _ = dpf_r.delete_participant(dp_r);
    const sub_r = dp_r.create_subscriber(.{}, null, 0);
    const topic_r = dp_r.create_topic("SuspendTopic", "MockType", .{}, null, 0);
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const dr = sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    const mock_w = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_W, PORT_META_W)});
    defer mock_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, mock_w.transport(), 0, 100);
    var factory_w = try DomainParticipantFactoryImpl.init(alloc, mock_w.transport(), disc_w.toDiscovery(), noop_security, .spec_random, .{});
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, null, 0);
    defer _ = dpf_w.delete_participant(dp_w);
    const pub_w = dp_w.create_publisher(.{}, null, 0);
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const topic_w = dp_w.create_topic("SuspendTopic", "MockType", .{}, null, 0);
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    // Drive discovery.
    const disc_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < disc_deadline) {
        net.deliverAll();
        if (dw_impl.matchedReaderCount() > 0) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(dw_impl.matchedReaderCount() > 0);

    // suspend → begin_coherent → write A → end_coherent → write B
    // A is flushed (and re-suspension engaged) by end_coherent_changes.
    // B must stay in the writer's pending buffer until resume_publications.
    _ = pub_w.vtable.suspend_publications(pub_w.ptr);
    _ = pub_w.vtable.begin_coherent_changes(pub_w.ptr);
    _ = try dw_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_A);
    _ = pub_w.vtable.end_coherent_changes(pub_w.ptr); // flushes A, re-engages suspension
    _ = try dw_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_B);

    // Deliver A to the reader.  B is still deferred in the writer's coherent buffer.
    net.deliverAll();
    const deliver_a_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deliver_a_deadline) {
        dr_impl.mu.lock();
        const n = dr_impl.pending.items.len;
        dr_impl.mu.unlock();
        if (n >= 1) break;
        net.deliverAll();
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    // A has arrived.  B must not have arrived yet.
    dr_impl.mu.lock();
    const pending_before_resume = dr_impl.pending.items.len;
    dr_impl.mu.unlock();
    try std.testing.expectEqual(@as(usize, 1), pending_before_resume);
    const sample_a = dr_impl.takeRaw().?;
    try std.testing.expectEqualSlices(u8, &PAYLOAD_A, sample_a.data);
    alloc.free(sample_a.data);

    // resume_publications flushes B.
    _ = pub_w.vtable.resume_publications(pub_w.ptr);
    const deliver_b_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deliver_b_deadline) {
        net.deliverAll();
        dr_impl.mu.lock();
        const n = dr_impl.pending.items.len;
        dr_impl.mu.unlock();
        if (n >= 1) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }
    const sample_b = dr_impl.takeRaw().?;
    try std.testing.expectEqualSlices(u8, &PAYLOAD_B, sample_b.data);
    alloc.free(sample_b.data);
}

test "mock_loopback: coherent sets from two writers are buffered independently" {
    // Regression for the per-writer coherent_wip keying.  Without the fix,
    // a single flat wip list caused writer B's end-marker to commit a mixed
    // set containing writer A's in-progress samples alongside B's own.
    //
    // Setup: two publishers on the writer side, each with coherent_access=true.
    // Publisher A writes A1+A2 as one coherent set (coherent_set_sn=2).
    // Publisher B writes B1 as a separate coherent set (coherent_set_sn=1).
    // The subscriber must receive two independent, non-mixed sets.
    const alloc = std.testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mock_r = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_R, PORT_META_R)});
    defer mock_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, mock_r.transport(), 0, 100);
    var factory_r = try DomainParticipantFactoryImpl.init(alloc, mock_r.transport(), disc_r.toDiscovery(), noop_security, .spec_random, .{});
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, null, 0);
    defer _ = dpf_r.delete_participant(dp_r);

    var sub_qos = DDS.SubscriberQos{};
    sub_qos.presentation.coherent_access = true;
    sub_qos.presentation.access_scope = .TOPIC_PRESENTATION_QOS;
    const sub_r = dp_r.create_subscriber(sub_qos, null, 0);
    const topic_r = dp_r.create_topic("TwoWriterTopic", "MockType", .{}, null, 0);
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const dr = sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    const mock_w = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_W, PORT_META_W)});
    defer mock_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, mock_w.transport(), 0, 100);
    var factory_w = try DomainParticipantFactoryImpl.init(alloc, mock_w.transport(), disc_w.toDiscovery(), noop_security, .spec_random, .{});
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, null, 0);
    defer _ = dpf_w.delete_participant(dp_w);

    var pub_qos = DDS.PublisherQos{};
    pub_qos.presentation.coherent_access = true;
    pub_qos.presentation.access_scope = .TOPIC_PRESENTATION_QOS;
    const pub_a = dp_w.create_publisher(pub_qos, null, 0);
    const pub_b = dp_w.create_publisher(pub_qos, null, 0);

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const topic_w = dp_w.create_topic("TwoWriterTopic", "MockType", .{}, null, 0);
    const dw_a = pub_a.create_datawriter(topic_w, dw_qos, null, 0);
    const dw_b = pub_b.create_datawriter(topic_w, dw_qos, null, 0);
    const dw_a_impl: *DataWriterImpl = @ptrCast(@alignCast(dw_a.ptr));
    const dw_b_impl: *DataWriterImpl = @ptrCast(@alignCast(dw_b.ptr));

    // Drive discovery until the reader matches both writers.
    const disc_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < disc_deadline) {
        net.deliverAll();
        if (dw_a_impl.matchedReaderCount() > 0 and dw_b_impl.matchedReaderCount() > 0) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(dw_a_impl.matchedReaderCount() > 0);
    try std.testing.expect(dw_b_impl.matchedReaderCount() > 0);

    // Publisher A: coherent set with 2 samples (A1=PAYLOAD_A, A2=PAYLOAD_C).
    _ = pub_a.vtable.begin_coherent_changes(pub_a.ptr);
    _ = try dw_a_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_A);
    _ = try dw_a_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_C);
    _ = pub_a.vtable.end_coherent_changes(pub_a.ptr);

    // Publisher B: coherent set with 1 sample (B1=PAYLOAD_B).
    _ = pub_b.vtable.begin_coherent_changes(pub_b.ptr);
    _ = try dw_b_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_B);
    _ = pub_b.vtable.end_coherent_changes(pub_b.ptr);

    // Deliver until the reader has two complete independent sets.
    const deliver_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deliver_deadline) {
        net.deliverAll();
        dr_impl.mu.lock();
        const n = dr_impl.coherent_committed.items.len;
        dr_impl.mu.unlock();
        if (n >= 2) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }
    dr_impl.mu.lock();
    const committed_count = dr_impl.coherent_committed.items.len;
    dr_impl.mu.unlock();
    try std.testing.expectEqual(@as(usize, 2), committed_count);

    // Collect both sets.  Each begin_access delivers exactly one committed set.
    var set1: std.ArrayList([]u8) = .empty;
    var set2: std.ArrayList([]u8) = .empty;
    defer {
        for (set1.items) |s| alloc.free(s);
        set1.deinit(alloc);
        for (set2.items) |s| alloc.free(s);
        set2.deinit(alloc);
    }

    _ = sub_r.vtable.begin_access(sub_r.ptr);
    _ = sub_r.vtable.end_access(sub_r.ptr);
    while (dr_impl.takeRaw()) |s| try set1.append(alloc, s.data);

    _ = sub_r.vtable.begin_access(sub_r.ptr);
    _ = sub_r.vtable.end_access(sub_r.ptr);
    while (dr_impl.takeRaw()) |s| try set2.append(alloc, s.data);

    // One set must have exactly 2 samples (A1, A2) and the other exactly 1 (B1).
    // Identify which is which by total size and verify no mixing.
    const two_sample_set = if (set1.items.len == 2) set1.items else set2.items;
    const one_sample_set = if (set1.items.len == 1) set1.items else set2.items;
    try std.testing.expectEqual(@as(usize, 2), two_sample_set.len);
    try std.testing.expectEqual(@as(usize, 1), one_sample_set.len);

    // The 2-sample set must contain exactly PAYLOAD_A and PAYLOAD_C (writer A's samples).
    // The 1-sample set must contain exactly PAYLOAD_B (writer B's sample).
    // Verify by checking that the 1-sample set is PAYLOAD_B (writer B's only sample).
    try std.testing.expectEqualSlices(u8, &PAYLOAD_B, one_sample_set[0]);
    // The 2-sample set should be A then C (in write order).
    try std.testing.expectEqualSlices(u8, &PAYLOAD_A, two_sample_set[0]);
    try std.testing.expectEqualSlices(u8, &PAYLOAD_C, two_sample_set[1]);
}

test "mock_loopback: coherent set delivered atomically via begin_access" {
    const alloc = std.testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    // ── Reader side ───────────────────────────────────────────────────────────
    const mock_r = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_R, PORT_META_R)});
    defer mock_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, mock_r.transport(), 0, 100);
    var factory_r = try DomainParticipantFactoryImpl.init(
        alloc,
        mock_r.transport(),
        disc_r.toDiscovery(),
        noop_security,
        .spec_random,
        .{},
    );
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, null, 0);
    defer _ = dpf_r.delete_participant(dp_r);

    var sub_qos = DDS.SubscriberQos{};
    sub_qos.presentation.coherent_access = true;
    sub_qos.presentation.access_scope = .TOPIC_PRESENTATION_QOS;
    const sub_r = dp_r.create_subscriber(sub_qos, null, 0);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;

    const topic_r = dp_r.create_topic("CoherentTopic", "MockType", .{}, null, 0);
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    const dr = sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);
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
        .spec_random,
        .{},
    );
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, null, 0);
    defer _ = dpf_w.delete_participant(dp_w);

    var pub_qos = DDS.PublisherQos{};
    pub_qos.presentation.coherent_access = true;
    pub_qos.presentation.access_scope = .TOPIC_PRESENTATION_QOS;
    const pub_w = dp_w.create_publisher(pub_qos, null, 0);

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;

    const topic_w = dp_w.create_topic("CoherentTopic", "MockType", .{}, null, 0);
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    // ── Drive discovery ───────────────────────────────────────────────────────
    const deadline_ns = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deadline_ns) {
        net.deliverAll();
        if (dw_impl.matchedReaderCount() > 0) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(dw_impl.matchedReaderCount() > 0);

    // ── Write coherent set ────────────────────────────────────────────────────
    _ = pub_w.vtable.begin_coherent_changes(pub_w.ptr);
    _ = try dw_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_A);
    _ = try dw_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_B);
    _ = pub_w.vtable.end_coherent_changes(pub_w.ptr);

    // Deliver the coherent DATA packets.
    const deliver_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deliver_deadline) {
        net.deliverAll();
        // Both samples should arrive and be buffered in coherent_wip/committed.
        dr_impl.mu.lock();
        const ready = dr_impl.coherent_committed_ready;
        dr_impl.mu.unlock();
        if (ready) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    // Before begin_access: samples are in coherent buffer, not yet in pending.
    try std.testing.expect(dr_impl.takeRaw() == null);

    // begin_access commits the coherent set atomically.
    _ = sub_r.vtable.begin_access(sub_r.ptr);
    _ = sub_r.vtable.end_access(sub_r.ptr);

    // Now both samples should be in pending and takeable.
    var samples: std.ArrayList([]u8) = .empty;
    defer {
        for (samples.items) |s| alloc.free(s);
        samples.deinit(alloc);
    }
    while (dr_impl.takeRaw()) |s| try samples.append(alloc, s.data);
    try std.testing.expectEqual(@as(usize, 2), samples.items.len);
    try std.testing.expectEqualSlices(u8, &PAYLOAD_A, samples.items[0]);
    try std.testing.expectEqualSlices(u8, &PAYLOAD_B, samples.items[1]);
}

test "mock_loopback: ordered access sorts pending queue via begin_access" {
    // Covers vtBeginAccess ordered_access block (lines 424-446) and both
    // comparators (pendingLessThan 464-468, pendingInstanceLessThan 470-475).
    //
    // Strategy: subscriber with INSTANCE ordered_access and no coherent_access.
    // Writer sends two samples in separate ordered groups (each via its own
    // begin/end_coherent_changes call) so they get distinct group_seq_nums.
    // Both samples go directly to pending (no coherent buffering since
    // coherent_access=false).  begin_access sorts by instance then group_seq_num,
    // which exercises pendingInstanceLessThan on equal instance handles.
    const alloc = std.testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    // ── Reader side ───────────────────────────────────────────────────────────
    const mock_r = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_R, PORT_META_R)});
    defer mock_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, mock_r.transport(), 0, 100);
    var factory_r = try DomainParticipantFactoryImpl.init(
        alloc,
        mock_r.transport(),
        disc_r.toDiscovery(),
        noop_security,
        .spec_random,
        .{},
    );
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, null, 0);
    defer _ = dpf_r.delete_participant(dp_r);

    var sub_qos = DDS.SubscriberQos{};
    sub_qos.presentation.ordered_access = true;
    sub_qos.presentation.access_scope = .INSTANCE_PRESENTATION_QOS;
    const sub_r = dp_r.create_subscriber(sub_qos, null, 0);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;

    const topic_r = dp_r.create_topic("OrderedTopic", "MockType", .{}, null, 0);
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    const dr = sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);
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
        .spec_random,
        .{},
    );
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, null, 0);
    defer _ = dpf_w.delete_participant(dp_w);

    var pub_qos = DDS.PublisherQos{};
    pub_qos.presentation.ordered_access = true;
    pub_qos.presentation.access_scope = .INSTANCE_PRESENTATION_QOS;
    const pub_w = dp_w.create_publisher(pub_qos, null, 0);

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;

    const topic_w = dp_w.create_topic("OrderedTopic", "MockType", .{}, null, 0);
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    // ── Drive discovery ───────────────────────────────────────────────────────
    const deadline_ns = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deadline_ns) {
        net.deliverAll();
        if (dw_impl.matchedReaderCount() > 0) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(dw_impl.matchedReaderCount() > 0);

    // ── Write two samples in separate ordered groups ──────────────────────────
    // Each begin/end_coherent_changes call flushes with mode=.group_seq_only
    // (ordered_access=true, coherent_access=false), assigning distinct group_seq_nums.
    // Samples arrive at the reader as plain pending changes, not coherent-buffered.
    _ = pub_w.vtable.begin_coherent_changes(pub_w.ptr);
    _ = try dw_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_A);
    _ = pub_w.vtable.end_coherent_changes(pub_w.ptr); // GSN=1 for PAYLOAD_A

    _ = pub_w.vtable.begin_coherent_changes(pub_w.ptr);
    _ = try dw_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_B);
    _ = pub_w.vtable.end_coherent_changes(pub_w.ptr); // GSN=2 for PAYLOAD_B

    // Wait until both samples land in the reader's pending queue.
    const deliver_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deliver_deadline) {
        net.deliverAll();
        dr_impl.mu.lock();
        const n = dr_impl.pending.items.len;
        dr_impl.mu.unlock();
        if (n >= 2) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    // begin_access with INSTANCE scope: sorts pending by (instance_handle, group_seq_num).
    // Both samples share the same instance handle (NIL), so the comparator falls
    // through to group_seq_num — exercising pendingInstanceLessThan lines 473-475.
    _ = sub_r.vtable.begin_access(sub_r.ptr);
    _ = sub_r.vtable.end_access(sub_r.ptr);

    var samples: std.ArrayList([]u8) = .empty;
    defer {
        for (samples.items) |s| alloc.free(s);
        samples.deinit(alloc);
    }
    while (dr_impl.takeRaw()) |s| try samples.append(alloc, s.data);
    try std.testing.expectEqual(@as(usize, 2), samples.items.len);
    // GSN order: PAYLOAD_A (1) before PAYLOAD_B (2).
    try std.testing.expectEqualSlices(u8, &PAYLOAD_A, samples.items[0]);
    try std.testing.expectEqualSlices(u8, &PAYLOAD_B, samples.items[1]);
}

test "mock_loopback: pre-coherent-window writes not tagged as part of coherent set" {
    // Regression for the coherent_window_start fix.  Without it, a write made
    // during suspend_publications *before* begin_coherent_changes shared the same
    // coherent_pending_sns buffer as the coherent-window write, so end_coherent_changes
    // incorrectly tagged both with PID_COHERENT_SET and delivered them as one set.
    //
    // With the fix, endCoherentSet splits the flush at coherent_window_start:
    //   - items before the window are sent as plain DATAs (no PID_COHERENT_SET)
    //   - items inside the window form the actual coherent set
    //
    // After end_coherent_changes + delivery the reader must see:
    //   - PAYLOAD_A in pending (plain write, not coherent-buffered)
    //   - PAYLOAD_B in coherent_committed (1-sample coherent set)
    const alloc = std.testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    // ── Reader side ───────────────────────────────────────────────────────────
    const mock_r = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_R, PORT_META_R)});
    defer mock_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, mock_r.transport(), 0, 100);
    var factory_r = try DomainParticipantFactoryImpl.init(alloc, mock_r.transport(), disc_r.toDiscovery(), noop_security, .spec_random, .{});
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, null, 0);
    defer _ = dpf_r.delete_participant(dp_r);

    var sub_qos = DDS.SubscriberQos{};
    sub_qos.presentation.coherent_access = true;
    sub_qos.presentation.access_scope = .TOPIC_PRESENTATION_QOS;
    const sub_r = dp_r.create_subscriber(sub_qos, null, 0);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const topic_r = dp_r.create_topic("PreCoherentTopic", "MockType", .{}, null, 0);
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    const dr = sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    // ── Writer side ───────────────────────────────────────────────────────────
    const mock_w = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_W, PORT_META_W)});
    defer mock_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, mock_w.transport(), 0, 100);
    var factory_w = try DomainParticipantFactoryImpl.init(alloc, mock_w.transport(), disc_w.toDiscovery(), noop_security, .spec_random, .{});
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, null, 0);
    defer _ = dpf_w.delete_participant(dp_w);

    var pub_qos = DDS.PublisherQos{};
    pub_qos.presentation.coherent_access = true;
    pub_qos.presentation.access_scope = .TOPIC_PRESENTATION_QOS;
    const pub_w = dp_w.create_publisher(pub_qos, null, 0);

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const topic_w = dp_w.create_topic("PreCoherentTopic", "MockType", .{}, null, 0);
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    // ── Drive discovery ───────────────────────────────────────────────────────
    const disc_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < disc_deadline) {
        net.deliverAll();
        if (dw_impl.matchedReaderCount() > 0) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(dw_impl.matchedReaderCount() > 0);

    // suspend → write A (pre-window) → begin_coherent → write B (in window) → end_coherent
    _ = pub_w.vtable.suspend_publications(pub_w.ptr);
    _ = try dw_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_A);
    _ = pub_w.vtable.begin_coherent_changes(pub_w.ptr);
    _ = try dw_impl.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &PAYLOAD_B);
    _ = pub_w.vtable.end_coherent_changes(pub_w.ptr);
    _ = pub_w.vtable.resume_publications(pub_w.ptr);

    // Deliver until both arrive.
    const deliver_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deliver_deadline) {
        net.deliverAll();
        dr_impl.mu.lock();
        const pending_n = dr_impl.pending.items.len;
        const committed = dr_impl.coherent_committed_ready;
        dr_impl.mu.unlock();
        if (pending_n >= 1 and committed) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    // PAYLOAD_A must be in pending as a plain write (not part of any coherent set).
    dr_impl.mu.lock();
    try std.testing.expectEqual(@as(usize, 1), dr_impl.pending.items.len);
    try std.testing.expect(dr_impl.coherent_committed_ready);
    dr_impl.mu.unlock();

    const sample_a = dr_impl.takeRaw().?;
    defer alloc.free(sample_a.data);
    try std.testing.expectEqualSlices(u8, &PAYLOAD_A, sample_a.data);

    // PAYLOAD_B must be in the coherent set, accessible only via begin_access.
    try std.testing.expect(dr_impl.takeRaw() == null);
    _ = sub_r.vtable.begin_access(sub_r.ptr);
    _ = sub_r.vtable.end_access(sub_r.ptr);
    const sample_b = dr_impl.takeRaw().?;
    defer alloc.free(sample_b.data);
    try std.testing.expectEqualSlices(u8, &PAYLOAD_B, sample_b.data);
}

// ── on_reliable_reader_ready extended listener ────────────────────────────────

const ReaderReadyState = struct {
    seq: usize = 0,
    matched_calls: usize = 0,
    matched_seq: ?usize = null,
    ready_calls: usize = 0,
    ready_seq: ?usize = null,
    last_ready: bool = false,
};

fn onPubMatchedForReadyTest(_: *anyopaque, _: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    const state: *ReaderReadyState = @ptrCast(@alignCast(ld.?));
    state.seq += 1;
    state.matched_calls += 1;
    if (state.matched_seq == null) state.matched_seq = state.seq;
}

fn onReaderReadyForReadyTest(_: DDS.InstanceHandle_t, ready: bool, ld: ?*anyopaque) callconv(.c) void {
    const state: *ReaderReadyState = @ptrCast(@alignCast(ld.?));
    state.seq += 1;
    state.ready_calls += 1;
    state.last_ready = ready;
    if (state.ready_seq == null) state.ready_seq = state.seq;
}

test "mock_loopback: on_reliable_reader_ready fires after AckNack handshake, strictly after on_publication_matched" {
    const alloc = std.testing.allocator;
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
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
        .spec_random,
        .{},
    );
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, null, 0);
    defer _ = dpf_r.delete_participant(dp_r);
    const sub_r = dp_r.create_subscriber(.{}, null, 0);
    const topic_r = dp_r.create_topic("MockTopic", "MockType", .{}, null, 0);
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    _ = sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);

    const mock_w = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_W, PORT_META_W)});
    defer mock_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, mock_w.transport(), 0, 100);
    var factory_w = try DomainParticipantFactoryImpl.init(
        alloc,
        mock_w.transport(),
        disc_w.toDiscovery(),
        noop_security,
        .spec_random,
        .{},
    );
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, null, 0);
    defer _ = dpf_w.delete_participant(dp_w);
    const pub_w = dp_w.create_publisher(.{}, null, 0);
    const topic_w = dp_w.create_topic("MockTopic", "MockType", .{}, null, 0);
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    var state = ReaderReadyState{};
    dw_impl.setListenerEx(.{
        .listener_data = &state,
        .on_publication_matched = onPubMatchedForReadyTest,
        .on_reliable_reader_ready = onReaderReadyForReadyTest,
    }, DDS.STATUS_MASK_ALL);

    // Drive discovery + the AckNack/Heartbeat handshake until both callbacks
    // have fired (or timeout).
    const deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while ((state.matched_calls == 0 or state.ready_calls == 0) and time_mod.nanoTimestamp() < deadline) {
        net.deliverAll();
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    try std.testing.expect(state.matched_calls > 0);
    try std.testing.expectEqual(@as(usize, 1), state.ready_calls);
    try std.testing.expect(state.last_ready == true);
    // The protocol-ready signal must never fire before (or in the same
    // "tick" as) the discovery-time match — it requires the real AckNack
    // round trip on top of SEDP matching, which on_publication_matched alone
    // does not wait for.
    try std.testing.expect(state.matched_seq.? < state.ready_seq.?);
}
