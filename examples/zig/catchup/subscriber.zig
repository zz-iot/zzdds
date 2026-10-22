//! zig/catchup -- subscriber (the late joiner).
//!
//! Durability + wait_for_historical_data reference app, talking to zzdds's
//! native Zig API directly. See docs/design/catchup-reference-app.md at the
//! repo root for the full spec. Starts after the publisher has already
//! written its full historical batch (enforced by the harness, not this
//! app -- see the reference doc). Immediately after creating the reader,
//! calls wait_for_historical_data() -- the API this whole example exists
//! to exercise -- before taking anything, then takes and confirms the full
//! historical batch, then attaches a listener for the live samples.
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! reader for topic:", "Subscriber: wait_for_historical_data() returned",
//! "HISTORICAL BATCH COMPLETE (10 samples)", "LIVE SAMPLE seq_num=",
//! "Subscriber: observed historical batch then live batch correctly." Any
//! failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const catchup_gen = @import("catchup_gen");

const HISTORICAL_COUNT: i32 = 10;
const LIVE_COUNT: i32 = 5;
const HISTORICAL_WAIT_TIMEOUT_S: i32 = 10;
const RECEIVE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;
const SHORTFALL_RECHECK_NS: i64 = 2 * std.time.ns_per_s;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const State = struct {
    // Written by main() for the historical batch, then by the
    // listener-dispatch thread for the live batch, which main() polls.
    historical_received: [10]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    live_received: [5]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    all_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    historical_confirmed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,
    reader: catchup_gen.HistoryEventDataReader = undefined,
};

// Pure readiness check -- does NOT store all_done itself. Callers decide
// when it's safe to actually commit the flag: main() deletes the reader
// as soon as it observes state.all_done, so storing it while
// onDataAvailable is still inside its take loop would let
// delete_datareader() race that same invocation's next take_next_sample()
// call.
fn readyToFinish(state: *State) bool {
    if (!state.historical_confirmed.load(.acquire)) return false;
    for (&state.live_received) |*v| {
        if (!v.load(.acquire)) return false;
    }
    return true;
}

/// Takes every sample available now, recording each, and returns whether
/// this call saw the last live sample the subscriber was waiting for. Run
/// by main() to drain the historical batch before any listener is
/// attached, then by onDataAvailable for the live batch.
fn takeAvailable(state: *State) bool {
    var became_done = false;
    while (true) {
        var value: catchup_gen.HistoryEvent = .{};
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
    return became_done;
}

fn countHistorical(state: *State) i32 {
    var n: i32 = 0;
    for (&state.historical_received) |*v| {
        if (v.load(.acquire)) n += 1;
    }
    return n;
}

/// After a historical shortfall: prints what the reader reports, then keeps
/// taking for SHORTFALL_RECHECK_NS. Samples that turn up late mean the wait
/// returned too early; lost ones mean the writer never sent them.
fn reportShortfall(state: *State, dr: DDS.DataReader, io: std.Io) void {
    var matched: DDS.SubscriptionMatchedStatus = undefined;
    var lost: DDS.SampleLostStatus = undefined;
    var rejected: DDS.SampleRejectedStatus = undefined;
    _ = dr.get_subscription_matched_status(&matched);
    _ = dr.get_sample_lost_status(&lost);
    _ = dr.get_sample_rejected_status(&rejected);
    std.debug.print("DIAG: matched current={d} total={d}, lost={d}, rejected={d}\n", .{
        matched.current_count, matched.total_count, lost.total_count, rejected.total_count,
    });
    const before = countHistorical(state);
    const deadline = monoNs(io) + SHORTFALL_RECHECK_NS;
    while (monoNs(io) < deadline and countHistorical(state) < HISTORICAL_COUNT) {
        sleepNs(io, POLL_PERIOD_NS);
        _ = takeAvailable(state);
    }
    std.debug.print("DIAG: {d} more historical samples arrived after the wait returned\n", .{countHistorical(state) - before});
}

fn onDataAvailable(state: *State, dr: DDS.DataReader) void {
    _ = dr;
    // main() can also independently decide it's done (see readyToFinish()
    // right after set_listener() below) and call delete_datareader() while
    // this invocation is still draining. That's still fine: zzdds's core
    // EntityQuiesce mechanism (not anything in this file) guarantees a
    // delete_datareader() racing an in-flight take_next_sample() call is
    // memory-safe -- the racing call either completes normally (started
    // before teardown) or cleanly sees "no data" (started after), never a
    // crash or use-after-free.
    if (takeAvailable(state)) {
        state.all_done.store(true, .release);
    }
}

fn parseDomain(it: *std.process.Args.Iterator) u32 {
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
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    defer args.deinit();
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const domain_id = parseDomain(&args);

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
        .compute_key_hash = catchup_gen.HistoryEvent.computeKeyHashFromCdr,
        .has_key = catchup_gen.HistoryEvent.has_key,
        .compute_key_hash_key_only = catchup_gen.HistoryEvent.computeKeyHashFromCdrKeyOnly,
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

    // Create with no listener attached: the historical batch is taken
    // below, on this thread, after wait_for_historical_data() returns. A
    // listener attached now would take it on a zzdds receive thread
    // instead, and wait_for_historical_data() waits for the samples to
    // reach the reader, not for a listener to have taken them.
    const topic_desc = dp.lookup_topicdescription("HistoryEvent");
    const dr = subscriber.create_datareader(topic_desc, dr_qos, null, 0);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: HistoryEvent\n", .{});
    state.reader = catchup_gen.HistoryEventDataReader.init(dr, alloc);

    // The API this whole example exists to exercise: block until the
    // TRANSIENT_LOCAL historical replay has actually landed, before taking
    // anything.
    const max_wait = DDS.Duration_t{ .sec = HISTORICAL_WAIT_TIMEOUT_S, .nanosec = 0 };
    const rc = dr.wait_for_historical_data(max_wait);
    if (rc != DDS.RETCODE_OK) {
        std.debug.print("FAIL: wait_for_historical_data() returned {d}\n", .{rc});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: wait_for_historical_data() returned\n", .{});

    // Confirm the real guarantee, not just the return code: every
    // historical sample must be in the reader by now.
    _ = takeAvailable(&state);
    const historical_count = countHistorical(&state);
    if (historical_count != HISTORICAL_COUNT) {
        std.debug.print("FAIL: wait_for_historical_data() returned OK but only {d}/{d} historical samples were actually received\n", .{ historical_count, HISTORICAL_COUNT });
        reportShortfall(&state, dr, io);
        std.process.exit(1);
    }
    std.debug.print("HISTORICAL BATCH COMPLETE ({d} samples)\n", .{HISTORICAL_COUNT});
    state.historical_confirmed.store(true, .release);

    // The live batch arrives through the listener. A sample that arrived
    // since the take above is delivered by set_listener() itself.
    const set_rc = dr.set_listener(dr_listener, DDS.DATA_AVAILABLE_STATUS);
    if (set_rc != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener() returned {d}\n", .{set_rc});
        std.process.exit(1);
    }
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
