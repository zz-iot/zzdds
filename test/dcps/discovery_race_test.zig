//! Full-DCPS-stack (mock transport) coverage for the discovery/write race
//! described in `docs/design/discovery-association-race-testing.md`.
//!
//! The core bug reproduction (a write made before `StatefulWriter.
//! addMatchedReader()` runs is silently excluded for a VOLATILE reader) is
//! deterministic at the RTPS layer and lives in `test/rtps/writer_sm_test.zig`
//! instead -- pinning the exact asymmetric SEDP interleaving via
//! `MockNetwork`/`MockTransport`'s per-transport delivery control turned out
//! to have more SPDP/SEDP-replay-timing layers than a clean, minimal
//! reproduction needs (see the design doc's own notes). What belongs here is
//! full-stack confidence that the DCPS layer's own behavior is otherwise
//! correct: a normal write-after-match round trip, and the "genuinely late
//! VOLATILE joiner" guard the eventual fix must not break.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const fixture = @import("mock_dcps_fixture");
const sample_sequence = @import("sample_sequence");

const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;
const time_mod = zzdds.util.time;

const IP_W: [4]u8 = .{ 127, 0, 0, 20 };
const IP_R: [4]u8 = .{ 127, 0, 0, 21 };
const PORT_META_W: u16 = 7410;
const PORT_META_R: u16 = 7412;

fn reliableVolatileKeepLastQos() struct { dw: DDS.DataWriterQos, dr: DDS.DataReaderQos } {
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    dr_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    // durability left at its VOLATILE default -- matches the real bug's QoS
    // shape (ROS2's rmw_qos_profile_services_default).
    return .{ .dw = dw_qos, .dr = dr_qos };
}

fn drainInto(alloc: std.mem.Allocator, dr_impl: *fixture.DataReaderImpl, out: *std.ArrayList(u32)) !void {
    while (dr_impl.takeRaw()) |sample| {
        defer alloc.free(sample.data);
        try out.append(alloc, try sample_sequence.Checker.counterOf(sample.data));
    }
}

test "discovery_race: write after both sides confirm match is always delivered (baseline)" {
    const alloc = std.testing.allocator;
    const qos = reliableVolatileKeepLastQos();

    const net = try fixture.MockNetwork.init(alloc);
    defer net.deinit();

    var reader = try fixture.createReaderSide(
        alloc,
        net,
        fixture.Locator.udp4(IP_R, PORT_META_R),
        0,
        "RaceTopic",
        "RaceType",
        qos.dr,
    );
    defer reader.deinit();
    var writer = try fixture.createWriterSide(
        alloc,
        net,
        fixture.Locator.udp4(IP_W, PORT_META_W),
        0,
        "RaceTopic",
        "RaceType",
        qos.dw,
    );
    defer writer.deinit();

    // Drive full discovery on both sides until the writer itself confirms
    // the match -- the strongest local signal available.
    const match_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (writer.dw_impl.matchedReaderCount() == 0 and time_mod.nanoTimestamp() < match_deadline) {
        net.deliverAll();
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(writer.dw_impl.matchedReaderCount() > 0);

    var payload_buf: [4]u8 = undefined;
    const payload = sample_sequence.payloadFor(&payload_buf, 0);
    _ = try writer.dw_impl.writeRaw(
        .alive,
        RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        payload,
    );

    var received: std.ArrayList(u32) = .empty;
    defer received.deinit(alloc);
    const deliver_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (received.items.len < 1 and time_mod.nanoTimestamp() < deliver_deadline) {
        net.deliverAll();
        try drainInto(alloc, reader.dr_impl, &received);
        if (received.items.len < 1) time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    var report = try sample_sequence.Checker.verify(alloc, received.items, 0, 1, &.{});
    defer report.deinit(alloc);
    try std.testing.expect(report.ok());
}

test "discovery_race: a genuinely late VOLATILE joiner does not receive earlier data" {
    const alloc = std.testing.allocator;
    const qos = reliableVolatileKeepLastQos();

    const net = try fixture.MockNetwork.init(alloc);
    defer net.deinit();

    // Writer only, fully settled, writes one sample before any reader exists.
    var writer = try fixture.createWriterSide(
        alloc,
        net,
        fixture.Locator.udp4(IP_W, PORT_META_W),
        0,
        "RaceTopic",
        "RaceType",
        qos.dw,
    );
    defer writer.deinit();

    var payload_buf: [4]u8 = undefined;
    const early_payload = sample_sequence.payloadFor(&payload_buf, 0);
    _ = try writer.dw_impl.writeRaw(
        .alive,
        RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        early_payload,
    );
    // Let the writer sit "settled" -- nothing to deliver to (no reader yet),
    // this just exercises a few idle rounds so the late join below is
    // genuinely late, not an artifact of test timing.
    var idle: usize = 0;
    while (idle < 5) : (idle += 1) {
        net.deliverAll();
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    var reader = try fixture.createReaderSide(
        alloc,
        net,
        fixture.Locator.udp4(IP_R, PORT_META_R),
        0,
        "RaceTopic",
        "RaceType",
        qos.dr,
    );
    defer reader.deinit();

    const match_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (writer.dw_impl.matchedReaderCount() == 0 and time_mod.nanoTimestamp() < match_deadline) {
        net.deliverAll();
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(writer.dw_impl.matchedReaderCount() > 0);

    // Write a second sample now that the late reader is matched, so there is
    // something the reader IS entitled to receive -- proving it's actively
    // participating, not just silent because nothing was ever sent to it.
    const later_payload = sample_sequence.payloadFor(&payload_buf, 1);
    _ = try writer.dw_impl.writeRaw(
        .alive,
        RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        later_payload,
    );

    var received: std.ArrayList(u32) = .empty;
    defer received.deinit(alloc);
    const deliver_deadline = time_mod.nanoTimestamp() + 3 * std.time.ns_per_s;
    while (received.items.len < 1 and time_mod.nanoTimestamp() < deliver_deadline) {
        net.deliverAll();
        try drainInto(alloc, reader.dr_impl, &received);
        if (received.items.len < 1) time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    // Must receive exactly the later sample (counter 1), never the earlier
    // one (counter 0) written before this VOLATILE reader existed.
    var report = try sample_sequence.Checker.verify(alloc, received.items, 1, 1, &.{});
    defer report.deinit(alloc);
    try std.testing.expect(report.ok());
}
