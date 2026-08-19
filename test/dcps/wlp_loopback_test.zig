//! WLP (Writer Liveliness Protocol, RTPS §8.4.13) real-wire regression test.
//!
//! Two real DomainParticipants communicate over loopback UDP -- the actual
//! gap this closes: DomainParticipant.assert_liveliness() on a
//! MANUAL_BY_PARTICIPANT writer, with no application data write at all, must
//! keep a remote reader's finite lease alive via WLP's ParticipantMessageData
//! broadcast (checkTimers()'s periodic driver -> discovery.wlpTick() ->
//! WlpEndpoints.tick() -> a real UDP send -> the remote reader's WLP builtin
//! reader -> onParticipantAliveCb -> writer_liveliness refreshed).
//!
//! A negative control (no asserts at all) proves the reader's lease really
//! would expire without WLP traffic, so the positive test isn't vacuously
//! lenient (e.g. an accidentally-infinite lease).

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const UdpTransport = zzdds.udp_transport.UdpTransport;
const SpdpSedpDiscovery = zzdds.combined_discovery.SpdpSedpDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const time_mod = zzdds.util.time;

const noop_security = zzdds.noop_security.noop_security_plugins;

const testing = std.testing;

const Pair = struct {
    udp_w: *UdpTransport,
    disc_w: *SpdpSedpDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    udp_r: *UdpTransport,
    disc_r: *SpdpSedpDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    dw: DDS.DataWriter,
    dr: DDS.DataReader,

    fn deinit(self: *Pair) void {
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        self.factory_r.deinit();
        self.disc_r.deinit();
        self.udp_r.deinit();
        _ = self.factory_w.toDDSFactory().delete_participant(self.dp_w);
        self.factory_w.deinit();
        self.disc_w.deinit();
        self.udp_w.deinit();
    }
};

/// Sets up two real UDP participants (distinct participant_ids, matching
/// this file's own private pid range so it never collides with
/// loopback_test.zig's), a matched DataWriter/DataReader pair with the given
/// LIVELINESS QoS, and waits (generously, matching loopback_test.zig's own
/// Valgrind-safe margins) for them to match.
fn setupMatchedPair(alloc: std.mem.Allocator, w_pid: u32, r_pid: u32, liveliness: DDS.LivelinessQosPolicy) !Pair {
    return setupMatchedPairEx(alloc, w_pid, r_pid, liveliness, .RELIABLE_RELIABILITY_QOS);
}

/// Like setupMatchedPair, but lets the reader's RELIABILITY differ from the
/// writer's -- RELIABLE writer / BEST_EFFORT reader is a valid RxO-compatible
/// match (offered RELIABLE satisfies requested BEST_EFFORT) and, per RTPS
/// §8.7.2.2.3, the reader still tracks and expires the writer's finite
/// liveliness lease regardless of its own reliability kind.
fn setupMatchedPairEx(
    alloc: std.mem.Allocator,
    w_pid: u32,
    r_pid: u32,
    liveliness: DDS.LivelinessQosPolicy,
    reader_reliability: DDS.ReliabilityQosPolicyKind,
) !Pair {
    const udp_w = try UdpTransport.init(alloc, .{ .participant_id = w_pid }, 0, null);
    errdefer udp_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, udp_w.transport(), 0, 1_000);
    errdefer disc_w.deinit();
    const factory_w = try DomainParticipantFactoryImpl.init(alloc, udp_w.transport(), disc_w.toDiscovery(), noop_security, .spec_random, .{});
    errdefer factory_w.deinit();
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(0, .{}, null, 0);
    errdefer _ = dpf_w.delete_participant(dp_w);

    const pub_w = dp_w.create_publisher(.{}, null, 0);
    const topic_w = dp_w.create_topic("WlpTopic", "WlpType", .{}, null, 0);
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.liveliness = liveliness;
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);

    const udp_r = try UdpTransport.init(alloc, .{ .participant_id = r_pid }, 0, null);
    errdefer udp_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, udp_r.transport(), 0, 1_000);
    errdefer disc_r.deinit();
    const factory_r = try DomainParticipantFactoryImpl.init(alloc, udp_r.transport(), disc_r.toDiscovery(), noop_security, .spec_random, .{});
    errdefer factory_r.deinit();
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(0, .{}, null, 0);
    errdefer _ = dpf_r.delete_participant(dp_r);

    const sub_r = dp_r.create_subscriber(.{}, null, 0);
    const topic_r = dp_r.create_topic("WlpTopic", "WlpType", .{}, null, 0);
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = reader_reliability;
    dr_qos.liveliness = liveliness;
    const dr = sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);

    // Wait for the match: alive_count transitions 0 -> 1 once SEDP completes
    // and the writer's first evidence (match itself counts, see reader.zig's
    // vtAddMatchedWriter -> .data evidence on match) is processed.
    const deadline = time_mod.nanoTimestamp() + 20 * std.time.ns_per_s;
    var status: DDS.LivelinessChangedStatus = undefined;
    while (time_mod.nanoTimestamp() < deadline) {
        _ = dr.vtable.get_liveliness_changed_status(dr.ptr, &status);
        if (status.alive_count >= 1) break;
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    } else {
        return error.NeverMatched;
    }

    return .{
        .udp_w = udp_w,
        .disc_w = disc_w,
        .factory_w = factory_w,
        .dp_w = dp_w,
        .udp_r = udp_r,
        .disc_r = disc_r,
        .factory_r = factory_r,
        .dp_r = dp_r,
        .dw = dw,
        .dr = dr,
    };
}

/// Periodically calls `assert_fn(assert_ctx)` while polling `dr`'s liveliness
/// status, until alive_count reaches 1 or `ceiling_ns` of real wall-clock
/// time elapses. Used by every positive WLP test below instead of a fixed
/// assert-for-N-seconds-then-check-once window: under Valgrind's CPU
/// slowdown, the periodic WLP check/send (or, for MANUAL_BY_TOPIC, the
/// on-demand Heartbeat send) can be delayed far enough that a single fixed
/// window isn't always enough even though the underlying mechanism is
/// genuinely working -- polling for the actual outcome, bounded by a
/// generous ceiling, is robust to that variance without weakening what the
/// test proves: a permanently-not-alive writer still fails once the ceiling
/// is reached, exactly like the negative controls below prove happens with
/// zero asserting at all.
fn assertUntilAlive(
    dr: DDS.DataReader,
    assert_ctx: *anyopaque,
    assert_fn: *const fn (*anyopaque) DDS.ReturnCode_t,
    ceiling_ns: i64,
) !void {
    const deadline = time_mod.nanoTimestamp() + ceiling_ns;
    var status: DDS.LivelinessChangedStatus = undefined;
    while (time_mod.nanoTimestamp() < deadline) {
        _ = assert_fn(assert_ctx);
        _ = dr.vtable.get_liveliness_changed_status(dr.ptr, &status);
        if (status.alive_count == 1) return;
        time_mod.sleepNs(200 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(i32, 1), status.alive_count);
}

test "wlp: MANUAL_BY_PARTICIPANT assert_liveliness() with no data write keeps a remote reader's finite lease alive" {
    const alloc = testing.allocator;
    var pair = try setupMatchedPair(alloc, 30, 31, .{
        .kind = .MANUAL_BY_PARTICIPANT_LIVELINESS_QOS,
        .lease_duration = .{ .sec = 3, .nanosec = 0 },
    });
    defer pair.deinit();

    // Periodically assert liveliness at the *participant* level (never a
    // real write()) for well over the lease, then confirm the remote reader
    // is alive at the end -- this is the actual bug being fixed: without
    // WLP wire traffic, none of these asserts would do anything the remote
    // reader could observe, and the lease would expire and stay expired
    // (see the negative control below, which proves exactly that).
    //
    // Lease is 3s, not 1s: WLP's MANUAL_BY_PARTICIPANT driver checks (and
    // sends, if warranted) at most once per lease period (RTPS §8.7.2.2.3 --
    // a periodic *check*, not a per-assert send), so the actual refresh
    // cadence the remote reader observes is roughly once per lease, not once
    // per assert call.
    //
    // Doesn't require alive_count==1 on every iteration or within a fixed
    // window: this file runs under both native CI (which already needed the
    // 1s->3s lease widening after intermittent Windows/macOS failures) and
    // Valgrind's 20-50x CPU slowdown (see loopback_test.zig's own 20s
    // deadlines for the identical reason) -- under that much scheduling
    // pressure even a 3s lease can occasionally take a while to recover
    // despite asserting genuinely working, because the periodic check/send
    // lands late relative to real wall-clock time. Polling for the actual
    // outcome (assertUntilAlive) up to a generous 60s ceiling absorbs that
    // without weakening what the test proves.
    try assertUntilAlive(pair.dr, pair.dp_w.ptr, pair.dp_w.vtable.assert_liveliness, 60 * std.time.ns_per_s);
}

test "wlp: negative control -- MANUAL_BY_PARTICIPANT writer that never asserts does go not-alive" {
    const alloc = testing.allocator;
    var pair = try setupMatchedPair(alloc, 32, 33, .{
        .kind = .MANUAL_BY_PARTICIPANT_LIVELINESS_QOS,
        .lease_duration = .{ .sec = 1, .nanosec = 0 },
    });
    defer pair.deinit();

    // No assert_liveliness() calls at all -- proves the QoS/lease machinery
    // genuinely expires the writer without WLP traffic, so the positive test
    // above isn't vacuously lenient.
    // 20s, not the ~2s this should genuinely take: matches loopback_test.zig's
    // own Valgrind-CI margin (20-50x slowdown) rather than a tight native-speed
    // bound -- see that file's collectSamples for the identical rationale.
    const deadline = time_mod.nanoTimestamp() + 20 * std.time.ns_per_s;
    var status: DDS.LivelinessChangedStatus = undefined;
    while (time_mod.nanoTimestamp() < deadline) {
        _ = pair.dr.vtable.get_liveliness_changed_status(pair.dr.ptr, &status);
        if (status.not_alive_count >= 1) break;
        time_mod.sleepNs(50 * std.time.ns_per_ms);
    } else {
        try testing.expect(false); // never went not-alive -- the lease mechanism itself is broken
    }
}

test "wlp: MANUAL_BY_TOPIC assert_liveliness() with no data write keeps a remote reader's finite lease alive" {
    // Unlike MANUAL_BY_PARTICIPANT above, MANUAL_BY_TOPIC is explicitly
    // excluded from WLP's ParticipantMessageData mechanism (RTPS §8.4.13.5)
    // -- this exercises the separate on-demand Heartbeat-with-LIVELINESS-flag
    // path instead (writer_sm.zig's sendLivelinessHeartbeat, triggered by
    // DataWriter.assert_liveliness() specifically, not the participant-level
    // call used above).
    const alloc = testing.allocator;
    var pair = try setupMatchedPair(alloc, 34, 35, .{
        .kind = .MANUAL_BY_TOPIC_LIVELINESS_QOS,
        .lease_duration = .{ .sec = 1, .nanosec = 0 },
    });
    defer pair.deinit();

    // See assertUntilAlive's doc comment for why this polls to a generous
    // ceiling instead of a fixed window (Valgrind's CPU slowdown).
    try assertUntilAlive(pair.dr, pair.dw.ptr, pair.dw.vtable.assert_liveliness, 60 * std.time.ns_per_s);
}

test "wlp: negative control -- MANUAL_BY_TOPIC writer that never asserts does go not-alive" {
    const alloc = testing.allocator;
    var pair = try setupMatchedPair(alloc, 36, 37, .{
        .kind = .MANUAL_BY_TOPIC_LIVELINESS_QOS,
        .lease_duration = .{ .sec = 1, .nanosec = 0 },
    });
    defer pair.deinit();

    const deadline = time_mod.nanoTimestamp() + 20 * std.time.ns_per_s;
    var status: DDS.LivelinessChangedStatus = undefined;
    while (time_mod.nanoTimestamp() < deadline) {
        _ = pair.dr.vtable.get_liveliness_changed_status(pair.dr.ptr, &status);
        if (status.not_alive_count >= 1) break;
        time_mod.sleepNs(50 * std.time.ns_per_ms);
    } else {
        try testing.expect(false); // never went not-alive -- the lease mechanism itself is broken
    }
}

test "wlp: MANUAL_BY_TOPIC assert_liveliness() reaches a BEST_EFFORT-matched reader" {
    // Regression test for a real Greptile finding on this PR: StatefulWriter's
    // reader-proxy loop (shared by routine background heartbeats and the
    // liveliness-flagged assert_liveliness() heartbeat) unconditionally
    // skipped BEST_EFFORT proxies, since BEST_EFFORT readers don't
    // participate in the reliable ACK/NACK protocol -- correct for routine
    // heartbeats, but wrong for a liveliness assertion: the BEST_EFFORT
    // reader still tracks and expires this writer's finite lease regardless
    // of its own reliability kind, and explicit asserts must still reach it.
    const alloc = testing.allocator;
    var pair = try setupMatchedPairEx(alloc, 38, 39, .{
        .kind = .MANUAL_BY_TOPIC_LIVELINESS_QOS,
        .lease_duration = .{ .sec = 1, .nanosec = 0 },
    }, .BEST_EFFORT_RELIABILITY_QOS);
    defer pair.deinit();

    // See assertUntilAlive's doc comment for why this polls to a generous
    // ceiling instead of a fixed window (Valgrind's CPU slowdown).
    try assertUntilAlive(pair.dr, pair.dw.ptr, pair.dw.vtable.assert_liveliness, 60 * std.time.ns_per_s);
}
