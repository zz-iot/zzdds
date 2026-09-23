//! zig/wait-for-historical-data -- subscriber (the late joiner). Talks to
//! zzdds's native Zig API directly. See docs/design/integration-test-tier.md
//! for the full scenario spec. This is the entity under test, and goes
//! further than examples/zig/catchup/subscriber.zig's demonstration in two
//! ways:
//!
//! 1. Negative case first: immediately after creating the reader -- while
//!    the harness guarantees no publisher process exists anywhere on this
//!    domain yet (see interop/wait_for_historical_data_cross_binding_test.py)
//!    -- calls wait_for_historical_data() with a short, non-zero max_wait
//!    and requires RETCODE_TIMEOUT. This is deterministic, not a timing
//!    race: with genuinely zero writers in the whole domain, the call
//!    cannot return OK no matter how long it's given, so the exact
//!    duration only bounds how long the check takes, not whether it's
//!    correct. This is what proves the call is a real bounded wait and not
//!    something that always reports success (regression covered natively in
//!    test/dcps/wait_for_historical_test.zig's "non-zero max_wait with no
//!    matched writer times out" test, itself written after this same
//!    false-OK bug was found building the catchup example -- see that
//!    test's comment).
//! 2. Only after printing the "ready for publisher" marker below (which the
//!    harness waits on before starting the publisher) does this app make its
//!    real, generous-timeout wait_for_historical_data() call and confirm the
//!    full historical batch actually landed by the time it returns -- the
//!    positive counterpart, unblocking only once durable replay has
//!    actually happened rather than on its own timer.
//!
//! Required stdout markers: "Create topic:", "Create reader for topic:",
//! "Subscriber: negative check (no writer yet) correctly returned TIMEOUT.",
//! "Subscriber: ready for publisher.", "Subscriber:
//! wait_for_historical_data() returned", "HISTORICAL BATCH COMPLETE (8
//! samples)", "LIVE SAMPLE seq_num=", "Subscriber: observed historical
//! batch then live batch correctly." Any failure path prints a line
//! starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const history_event_gen = @import("history_event_gen");

const HISTORICAL_COUNT: i32 = 8;
const LIVE_COUNT: i32 = 4;
const NEGATIVE_WAIT_NS: u32 = 300 * std.time.ns_per_ms;
const HISTORICAL_WAIT_TIMEOUT_S: i32 = 15;
const RECEIVE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const State = struct {
    historical_received: [8]std.atomic.Value(bool) = .{std.atomic.Value(bool).init(false)} ** 8,
    live_received: [4]std.atomic.Value(bool) = .{std.atomic.Value(bool).init(false)} ** 4,
    all_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    historical_confirmed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,
    reader: history_event_gen.HistoryEventDataReader = undefined,
};

// Pure readiness check -- does NOT store all_done itself. See
// c/wait-for-historical-data/src/subscriber.c's matching comment.
fn readyToFinish(state: *State) bool {
    if (!state.historical_confirmed.load(.acquire)) return false;
    for (&state.live_received) |*v| {
        if (!v.load(.acquire)) return false;
    }
    return true;
}

fn onDataAvailable(state: *State, dr: DDS.DataReader) void {
    _ = dr;
    var became_done = false;
    while (true) {
        var value: history_event_gen.HistoryEvent = .{};
        var info: DDS.SampleInfo = .{};
        const got = state.reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample() CDR error\n", .{});
            std.process.exit(1);
        };
        if (!got) break;
        if (!info.valid_data) continue;

        if (value.seq_num >= 0 and value.seq_num < HISTORICAL_COUNT) {
            state.historical_received[@intCast(value.seq_num)].store(true, .release);
        } else if (value.seq_num >= HISTORICAL_COUNT and value.seq_num < HISTORICAL_COUNT + LIVE_COUNT) {
            std.debug.print("LIVE SAMPLE seq_num={d}\n", .{value.seq_num});
            state.live_received[@intCast(value.seq_num - HISTORICAL_COUNT)].store(true, .release);
            if (!state.all_done.load(.acquire) and !became_done and readyToFinish(state)) {
                became_done = true;
            }
        } else {
            std.debug.print("FAIL: unexpected seq_num={d}\n", .{value.seq_num});
            std.process.exit(1);
        }
    }

    if (became_done) {
        state.all_done.store(true, .release);
    }
}

fn parseDomain(process_args: std.process.Args) u32 {
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            const v = it.next() orelse continue;
            return std.fmt.parseInt(u32, v, 10) catch 0;
        }
    }
    return 0;
}

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
    if (!zzdds.registerTypeSupport(dp, "HistoryEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = history_event_gen.HistoryEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = history_event_gen.HistoryEvent.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("HistoryEvent", "HistoryEvent", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: HistoryEvent\n", .{});

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    var state = State{ .alloc = alloc };
    const dr_listener = DDS.dataReaderListener(&state, .{
        .on_data_available = onDataAvailable,
    });

    // Create with no listener attached yet -- see this file's header
    // comment and c/wait-for-historical-data/src/subscriber.c's matching
    // comment for why.
    const topic_desc = dp.lookup_topicdescription("HistoryEvent");
    const dr = subscriber.create_datareader(topic_desc, dr_qos, null, 0);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: HistoryEvent\n", .{});
    state.reader = history_event_gen.HistoryEventDataReader.init(dr, alloc);
    const set_rc = dr.set_listener(dr_listener, DDS.DATA_AVAILABLE_STATUS);
    if (set_rc != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener() returned {d}\n", .{set_rc});
        std.process.exit(1);
    }

    // Negative case -- see this file's header comment. No writer exists
    // anywhere on this domain yet (the harness enforces that), so a short,
    // non-zero max_wait here is guaranteed to time out.
    const negative_wait = DDS.Duration_t{ .sec = 0, .nanosec = NEGATIVE_WAIT_NS };
    const neg_rc = dr.wait_for_historical_data(negative_wait);
    if (neg_rc != DDS.RETCODE_TIMEOUT) {
        std.debug.print("FAIL: wait_for_historical_data() with no writer matched returned {d}, expected RETCODE_TIMEOUT ({d})\n", .{ neg_rc, DDS.RETCODE_TIMEOUT });
        std.process.exit(1);
    }
    std.debug.print("Subscriber: negative check (no writer yet) correctly returned TIMEOUT.\n", .{});

    // Tells the harness it's now safe to start the publisher -- see this
    // file's header comment and the interop test's wait_for_marker().
    std.debug.print("Subscriber: ready for publisher.\n", .{});

    // The positive case: block until the TRANSIENT_LOCAL historical replay
    // has actually landed, before taking anything.
    const max_wait = DDS.Duration_t{ .sec = HISTORICAL_WAIT_TIMEOUT_S, .nanosec = 0 };
    const rc = dr.wait_for_historical_data(max_wait);
    if (rc != DDS.RETCODE_OK) {
        std.debug.print("FAIL: wait_for_historical_data() returned {d}\n", .{rc});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: wait_for_historical_data() returned\n", .{});

    // Confirm the real guarantee, not just the return code: every
    // historical sample must already have been delivered by now.
    var historical_count: i32 = 0;
    for (&state.historical_received) |*v| {
        if (v.load(.acquire)) historical_count += 1;
    }
    if (historical_count != HISTORICAL_COUNT) {
        std.debug.print("FAIL: wait_for_historical_data() returned OK but only {d}/{d} historical samples were actually received\n", .{ historical_count, HISTORICAL_COUNT });
        std.process.exit(1);
    }
    std.debug.print("HISTORICAL BATCH COMPLETE ({d} samples)\n", .{HISTORICAL_COUNT});
    state.historical_confirmed.store(true, .release);
    if (readyToFinish(&state)) {
        state.all_done.store(true, .release);
    }

    const deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (!state.all_done.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: did not observe the full live batch within 30s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    _ = subscriber.delete_datareader(dr);

    std.debug.print("Subscriber: observed historical batch then live batch correctly.\n", .{});
}
