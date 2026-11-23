//! zig/wait-for-historical-data -- subscriber (the late joiner). Talks to
//! zzdds's native Zig API directly. See docs/design/integration-test-tier.md
//! for the full scenario spec. This is the entity under test, and goes
//! further than examples/zig/catchup/subscriber.zig's demonstration in two
//! ways:
//!
//! The harness starts this process only once the publisher has written its
//! whole historical batch (see
//! interop/wait_for_historical_data_cross_binding_test.py), so the reader
//! below always joins late and the batch can only reach it by
//! TRANSIENT_LOCAL replay.
//!
//! 1. Unmatched case first: a TRANSIENT_LOCAL reader on UNPUBLISHED_TOPIC,
//!    which no process ever writes, calls wait_for_historical_data() with a
//!    short, non-zero max_wait and requires RETCODE_OK. With no writer matched,
//!    nothing owes the reader history, so the call returns OK at once
//!    (docs/design/concurrency/operations.md#historical-wait-compatibility). An
//!    earlier version waited for a first writer to match instead, and returned
//!    TIMEOUT here.
//! 2. Then the reader under test, on HistoryEvent, waits for the publisher's
//!    writer to match, then makes a generous-timeout wait_for_historical_data()
//!    call and confirms the full historical batch actually landed by the time it
//!    returns -- unblocking only once durable replay has actually happened,
//!    rather than on its own timer. It takes from the reader itself to
//!    confirm that, before any listener is attached: see
//!    c/wait-for-historical-data/src/subscriber.c.
//!
//! Required stdout markers: "Create topic:", "Subscriber: unmatched check (no
//! writer on its topic) returned OK at once.", "Create reader for topic:",
//! "Subscriber: wait_for_historical_data() returned", "HISTORICAL BATCH
//! COMPLETE (8 samples)", "LIVE SAMPLE seq_num=", "Subscriber: observed
//! historical batch then live batch correctly." Any failure path prints a
//! line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const history_event_gen = @import("history_event_gen");

const HISTORICAL_COUNT: i32 = 8;
const LIVE_COUNT: i32 = 4;
const UNMATCHED_WAIT_NS: u32 = 300 * std.time.ns_per_ms;
const HISTORICAL_WAIT_TIMEOUT_S: i32 = 15;
const RECEIVE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;
/// A topic of the same type that no process ever writes, for the unmatched case.
const UNPUBLISHED_TOPIC = "HistoryEventUnpublished";

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const State = struct {
    historical_received: [8]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
    live_received: [4]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
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
    takeAvailable(state);
}

/// Takes everything the reader holds, recording each seq_num.
fn takeAvailable(state: *State) void {
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

fn parseDomain(process_args: std.process.Args, arena: std.mem.Allocator) u32 {
    var it = std.process.Args.Iterator.initAllocator(process_args, arena) catch return 0;
    defer it.deinit();
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            const v = it.next() orelse continue;
            return std.fmt.parseInt(u32, v, 10) catch 0;
        }
    }
    return 0;
}

/// A reader's current matched count, for saying which endpoint a timeout is about.
/// Polls until a writer matches `dr`, for up to HISTORICAL_WAIT_TIMEOUT_S.
fn waitForMatch(dr: DDS.DataReader, io: std.Io) bool {
    var waited: u64 = 0;
    while (waited < @as(u64, HISTORICAL_WAIT_TIMEOUT_S) * std.time.ns_per_s) : (waited += POLL_PERIOD_NS) {
        if (readerMatched(dr) > 0) return true;
        sleepNs(io, POLL_PERIOD_NS);
    }
    return false;
}

fn readerMatched(dr: anytype) i32 {
    var status: DDS.SubscriptionMatchedStatus = undefined;
    return if (dr.get_subscription_matched_status(&status) == DDS.RETCODE_OK) status.current_count else -1;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const domain_id = parseDomain(init.minimal.args, init.arena.allocator());

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
        .key_projection = .{ .ctx = undefined, .project = history_event_gen.HistoryEvent.projectKeyFromCdr },
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

    // Unmatched case -- see this file's header comment. No process writes
    // UNPUBLISHED_TOPIC, so nothing owes this reader history: a non-zero
    // max_wait returns OK at once.
    const unpublished = dp.create_topic(UNPUBLISHED_TOPIC, "HistoryEvent", .{}, null, 0);
    if (unpublished.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(" ++ UNPUBLISHED_TOPIC ++ ") failed\n", .{});
        std.process.exit(1);
    }
    const unmatched_dr = subscriber.create_datareader(dp.lookup_topicdescription(UNPUBLISHED_TOPIC), dr_qos, null, 0);
    if (unmatched_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(" ++ UNPUBLISHED_TOPIC ++ ") failed\n", .{});
        std.process.exit(1);
    }
    const unmatched_wait = DDS.Duration_t{ .sec = 0, .nanosec = UNMATCHED_WAIT_NS };
    const unmatched_rc = unmatched_dr.wait_for_historical_data(unmatched_wait);
    if (unmatched_rc != DDS.RETCODE_OK) {
        std.debug.print("FAIL: wait_for_historical_data() with no writer matched returned {d}, expected RETCODE_OK\n", .{unmatched_rc});
        std.process.exit(1);
    }
    _ = subscriber.delete_datareader(unmatched_dr);
    std.debug.print("Subscriber: unmatched check (no writer on its topic) returned OK at once.\n", .{});

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

    // The positive case: wait for the publisher's writer to match, then
    // block until its TRANSIENT_LOCAL historical replay has actually landed,
    // before taking anything. wait_for_historical_data() waits for the
    // writers matched when it is called, so the match comes first.
    if (!waitForMatch(dr, io)) {
        std.debug.print("FAIL: no writer matched within {d} s\n", .{HISTORICAL_WAIT_TIMEOUT_S});
        std.process.exit(1);
    }
    const max_wait = DDS.Duration_t{ .sec = HISTORICAL_WAIT_TIMEOUT_S, .nanosec = 0 };
    const rc = dr.wait_for_historical_data(max_wait);
    if (rc != DDS.RETCODE_OK) {
        std.debug.print("FAIL: wait_for_historical_data() returned {d}\n", .{rc});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: wait_for_historical_data() returned\n", .{});

    // Confirm the real guarantee, not just the return code: every
    // historical sample must already be in the reader.
    takeAvailable(&state);
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
    } else {
        // The rest of the live batch; set_listener() fires at once for
        // anything that arrived meanwhile.
        const set_rc = dr.set_listener(dr_listener, DDS.DATA_AVAILABLE_STATUS);
        if (set_rc != DDS.RETCODE_OK) {
            std.debug.print("FAIL: set_listener() returned {d}\n", .{set_rc});
            std.process.exit(1);
        }
    }

    const deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (!state.all_done.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("  matched: reader={d}\n", .{readerMatched(dr)});
            std.debug.print("FAIL: did not observe the full live batch within 30s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    _ = subscriber.delete_datareader(dr);

    std.debug.print("Subscriber: observed historical batch then live batch correctly.\n", .{});
}
