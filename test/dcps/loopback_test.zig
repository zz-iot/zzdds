//! Phase 16: ZZDDS-to-ZZDDS loopback integration test.
//!
//! Two DomainParticipants in the same process communicate via loopback UDP.
//! Exercises the full stack: SPDP → SEDP → DataWriter → transport → DataReader.
//! No external dependencies; runs under `zig build test`.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const UdpTransport = zzdds.udp_transport.UdpTransport;
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

// CDR_LE payloads: 4-byte encapsulation header + one distinguishable byte.
const PAYLOAD_1 = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x11 };
const PAYLOAD_2 = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x22 };
const PAYLOAD_3 = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x33 };

// Poll a DataReader until `expected_n` samples arrive or `timeout_ns` elapses.
// Returns owned slice of received payloads (each element owned by allocator).
fn collectSamples(
    alloc: std.mem.Allocator,
    dr_impl: *DataReaderImpl,
    expected_n: usize,
    timeout_ns: u64,
) ![][]u8 {
    var results: std.ArrayList([]u8) = .empty;
    errdefer {
        for (results.items) |s| alloc.free(s);
        results.deinit(alloc);
    }
    const deadline = time_mod.nanoTimestamp() + @as(i64, @intCast(timeout_ns));
    while (results.items.len < expected_n and time_mod.nanoTimestamp() < deadline) {
        // Drain all currently available samples before sleeping.
        while (dr_impl.takeRaw()) |sample| {
            try results.append(alloc, sample.data);
            if (results.items.len >= expected_n) break;
        }
        if (results.items.len < expected_n)
            time_mod.sleepNs(10 * std.time.ns_per_ms);
    }
    return results.toOwnedSlice(alloc);
}

fn runLoopback(
    alloc: std.mem.Allocator,
    w_pid: u32,
    r_pid: u32,
    dw_qos: DDS.DataWriterQos,
    dr_qos: DDS.DataReaderQos,
    payloads: []const []const u8,
    expected: []const []const u8,
) !void {
    // ── Writer participant ────────────────────────────────────────────────────
    // Explicit participant_ids prevent the TOCTOU race in autoAssignParticipantId:
    // both transports would otherwise see port 7410 as free (each test-binds and
    // immediately releases it) and both claim pid=0, causing a unicast port clash.
    // Each test uses distinct pids so that sequential tests never re-bind ports
    // that were just released by the previous test (avoids Windows port-reuse races).
    const udp_w = try UdpTransport.init(alloc, .{ .participant_id = w_pid }, 0, null);
    defer udp_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, udp_w.transport(), 0, 1_000);
    var factory_w = try DomainParticipantFactoryImpl.init(
        alloc,
        udp_w.transport(),
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
        "LoopbackTopic",
        "LoopbackType",
        .{},
        null,
        0,
    );
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    // ── Reader participant ────────────────────────────────────────────────────
    const udp_r = try UdpTransport.init(alloc, .{ .participant_id = r_pid }, 0, null);
    defer udp_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, udp_r.transport(), 0, 1_000);
    var factory_r = try DomainParticipantFactoryImpl.init(
        alloc,
        udp_r.transport(),
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
        "LoopbackTopic",
        "LoopbackType",
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

    // ── Write all payloads immediately (before discovery completes) ───────────
    // RELIABLE: samples sit in history cache and are replayed once the proxy
    // is established via SEDP.  BEST_EFFORT: same courtesy replay behaviour.
    for (payloads) |p| {
        _ = try dw_impl.writeRaw(
            .alive,
            RtpsTimestamp.now(),
            history_mod.INSTANCE_HANDLE_NIL,
            std.mem.zeroes([16]u8),
            p,
        );
    }

    // ── Collect and assert ────────────────────────────────────────────────────
    const received = try collectSamples(alloc, dr_impl, expected.len, 5 * std.time.ns_per_s);
    defer {
        for (received) |s| alloc.free(s);
        alloc.free(received);
    }

    try std.testing.expectEqual(expected.len, received.len);
    for (expected, received) |exp, got| {
        try std.testing.expectEqualSlices(u8, exp, got);
    }
}

test "loopback: BEST_EFFORT single sample" {
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    const p: []const u8 = &PAYLOAD_1;
    try runLoopback(std.testing.allocator, 0, 1, dw_qos, dr_qos, &.{p}, &.{p});
}

test "loopback: RELIABLE single sample" {
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const p: []const u8 = &PAYLOAD_1;
    try runLoopback(std.testing.allocator, 2, 3, dw_qos, dr_qos, &.{p}, &.{p});
}

test "loopback: RELIABLE KEEP_LAST depth=1" {
    // Write 3 samples before proxy established; cache evicts first two.
    // Reader should receive only the last sample (PAYLOAD_3).
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dw_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    dw_qos.history.depth = 1;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    dr_qos.history.depth = 1;
    try runLoopback(
        std.testing.allocator,
        4,
        5,
        dw_qos,
        dr_qos,
        &.{ &PAYLOAD_1, &PAYLOAD_2, &PAYLOAD_3 },
        &.{&PAYLOAD_3},
    );
}

test "loopback: RELIABLE KEEP_ALL" {
    // Write 3 samples before proxy established; all should arrive in order.
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    try runLoopback(
        std.testing.allocator,
        6,
        7,
        dw_qos,
        dr_qos,
        &.{ &PAYLOAD_1, &PAYLOAD_2, &PAYLOAD_3 },
        &.{ &PAYLOAD_1, &PAYLOAD_2, &PAYLOAD_3 },
    );
}

test "loopback: incompatible QoS — best_effort writer vs reliable reader" {
    // DDS v1.4 §2.2.3: a best_effort writer is incompatible with a reliable reader.
    // No proxy should be created; reader must receive no samples; both endpoints
    // must record an incompatible-QoS event.
    const alloc = std.testing.allocator;

    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;

    const udp_w = try UdpTransport.init(alloc, .{ .participant_id = 8 }, 0, null);
    defer udp_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, udp_w.transport(), 0, 1_000);
    var factory_w = try DomainParticipantFactoryImpl.init(
        alloc,
        udp_w.transport(),
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

    const udp_r = try UdpTransport.init(alloc, .{ .participant_id = 9 }, 0, null);
    defer udp_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, udp_r.transport(), 0, 1_000);
    var factory_r = try DomainParticipantFactoryImpl.init(
        alloc,
        udp_r.transport(),
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

    // Write a sample and wait for discovery to run (it will find incompatible QoS
    // and fire the notification instead of creating a proxy).
    _ = try dw_impl.writeRaw(
        .alive,
        RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        &PAYLOAD_1,
    );

    // Wait up to 3 s for the incompat event (same mechanism as sample polling).
    const deadline_ns = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (time_mod.nanoTimestamp() < deadline_ns) {
        if (dr_impl.incompat_total > 0 and dw_impl.incompat_total > 0) break;
        time_mod.sleepNs(10 * std.time.ns_per_ms);
    }

    // Both sides must have recorded the incompatibility.
    try std.testing.expect(dr_impl.incompat_total > 0);
    try std.testing.expect(dw_impl.incompat_total > 0);

    // No sample should have been delivered.
    const received = try collectSamples(alloc, dr_impl, 1, 200 * std.time.ns_per_ms);
    defer {
        for (received) |s| alloc.free(s);
        alloc.free(received);
    }
    try std.testing.expectEqual(@as(usize, 0), received.len);
}
