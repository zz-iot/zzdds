//! zig/presence -- publisher.
//!
//! LIVELINESS QoS reference app, talking to zzdds's native Zig API directly.
//! See docs/design/presence-reference-app.md at the repo root for the full
//! spec. Demonstrates MANUAL_BY_TOPIC_LIVELINESS_QOS: the writer writes for
//! a while, then deliberately goes quiet (no writes, no asserts) for longer
//! than its own lease_duration -- letting the lease actually expire -- then
//! calls DataWriter.assert_liveliness() explicitly before resuming.
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! writer for topic:", "Publisher: wrote sequence=", "Publisher: going
//! offline", "Publisher: asserting liveliness and resuming", "Publisher:
//! done." Any failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const presence_gen = @import("presence_gen");

const ONLINE_BEACON_COUNT: i32 = 8;
const BEACON_PERIOD_NS: u64 = 500 * std.time.ns_per_ms;
const LEASE_DURATION_S: i32 = 2;
const OFFLINE_DURATION_NS: u64 = 5 * std.time.ns_per_s; // > LEASE_DURATION_S
const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

// ── Time helpers (std.Io.Clock -- portable across Linux/macOS/Windows) ──────

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// ── Listener state, shared between the network thread (callbacks) and main ──

const State = struct {
    reader_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    ever_matched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onReliableReaderReady(state: *State, reader_handle: DDS.InstanceHandle_t, is_ready: bool) void {
    _ = reader_handle;
    if (is_ready) state.reader_ready.store(true, .release);
    std.debug.print("on_reliable_reader_ready() is_ready={}\n", .{is_ready});
}

fn onPublicationMatched(state: *State, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
    if (status.current_count > 0) state.ever_matched.store(true, .release);
    std.debug.print("on_publication_matched() current_count={d}\n", .{status.current_count});
}

// ── Argument parsing ─────────────────────────────────────────────────────────

fn parseDomain(process_args: std.process.Args) u32 {
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            const v = it.next() orelse continue;
            return std.fmt.parseInt(u32, v, 10) catch 0;
        }
    }
    return 0;
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const domain_id = parseDomain(init.minimal.args);

    var factory = zzdds.createFactory() catch {
        std.debug.print("FAIL: createFactory() failed\n", .{});
        std.process.exit(1);
    };
    defer factory.deinit();
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(domain_id, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_participant() failed on domain {d}\n", .{domain_id});
        std.process.exit(1);
    }
    defer _ = dpf.delete_participant(dp);

    var ts_alloc = alloc;
    if (!zzdds.registerTypeSupport(dp, "PresenceBeacon", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = presence_gen.PresenceBeacon.computeKeyHashFromCdr,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("PresenceBeacon", "PresenceBeacon", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: PresenceBeacon\n", .{});

    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    dw_qos.history.depth = 1;
    dw_qos.liveliness.kind = .MANUAL_BY_TOPIC_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration = .{ .sec = LEASE_DURATION_S, .nanosec = 0 };

    const dw = publisher.create_datawriter(topic, dw_qos, null, 0);
    if (dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: PresenceBeacon\n", .{});

    var state = State{};
    const zdw = zzdds.asZzddsDataWriter(dw) orelse {
        std.debug.print("FAIL: asZzddsDataWriter() failed\n", .{});
        std.process.exit(1);
    };
    if (zdw.set_listener_ex(ZZDDS.dataWriterListenerEx(&state, .{
        .on_publication_matched = onPublicationMatched,
        .on_reliable_reader_ready = onReliableReaderReady,
    }), DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener_ex failed\n", .{});
        std.process.exit(1);
    }

    const writer = presence_gen.PresenceBeaconDataWriter.init(dw, alloc);

    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!state.reader_ready.load(.acquire)) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    // ── Online phase ─────────────────────────────────────────────────────
    var seq: i32 = 0;
    while (seq < ONLINE_BEACON_COUNT) : (seq += 1) {
        writer.write(.{ .seq_num = seq }, 0) catch {
            std.debug.print("FAIL: write() failed at sequence={d}\n", .{seq});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote sequence={d}\n", .{seq});
        sleepNs(io, BEACON_PERIOD_NS);
    }

    // ── Offline phase -- no writes, no asserts, longer than the lease ──────
    std.debug.print("Publisher: going offline (no writes/asserts for {d}s, lease is {d}s)\n", .{ OFFLINE_DURATION_NS / std.time.ns_per_s, LEASE_DURATION_S });
    sleepNs(io, OFFLINE_DURATION_NS);

    // ── Recovery ─────────────────────────────────────────────────────────
    std.debug.print("Publisher: asserting liveliness and resuming\n", .{});
    if (dw.assert_liveliness() != DDS.RETCODE_OK) {
        std.debug.print("FAIL: assert_liveliness() failed\n", .{});
        std.process.exit(1);
    }

    while (seq < ONLINE_BEACON_COUNT * 2) : (seq += 1) {
        writer.write(.{ .seq_num = seq }, 0) catch {
            std.debug.print("FAIL: write() failed at sequence={d}\n", .{seq});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote sequence={d}\n", .{seq});
        sleepNs(io, BEACON_PERIOD_NS);
    }

    // Wait for the subscriber to tear its reader down before exiting.
    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (!(state.ever_matched.load(.acquire) and state.matched_current_count.load(.acquire) == 0)) {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Publisher: done.\n", .{});
}
