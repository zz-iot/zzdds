//! zig/catchup -- publisher.
//!
//! Durability + wait_for_historical_data reference app, talking to zzdds's
//! native Zig API directly. See docs/design/catchup-reference-app.md at the
//! repo root for the full spec. Writes a historical batch immediately, with
//! no reader matched yet, then -- once a reader does match -- writes a live
//! batch. TRANSIENT_LOCAL durability means zzdds's own writer-side cache
//! (not this app) is what makes the historical batch replayable to a late
//! joiner.
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! writer for topic:", "Publisher: wrote historical seq_num=", "Publisher:
//! reader matched, writing live batch", "Publisher: wrote live seq_num=",
//! "Publisher: done." Any failure path prints a line starting "FAIL:" and
//! exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const catchup_gen = @import("catchup_gen");

const HISTORICAL_COUNT: i32 = 10;
const LIVE_COUNT: i32 = 5;
const MATCH_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const State = struct {
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    ever_matched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onPublicationMatched(state: *State, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
    if (status.current_count > 0) state.ever_matched.store(true, .release);
    std.debug.print("on_publication_matched() current_count={d}\n", .{status.current_count});
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
        .compute_key_hash = catchup_gen.HistoryEvent.computeKeyHashFromCdr,
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

    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const dw = publisher.create_datawriter(topic, dw_qos, null, 0);
    if (dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: HistoryEvent\n", .{});

    var state = State{};
    const dw_listener = DDS.dataWriterListener(&state, .{
        .on_publication_matched = onPublicationMatched,
    });
    if (dw.set_listener(dw_listener, DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener failed\n", .{});
        std.process.exit(1);
    }

    const writer = catchup_gen.HistoryEventDataWriter.init(dw, alloc);

    // -- Historical batch: written immediately, no reader matched yet. --
    var seq: i32 = 0;
    while (seq < HISTORICAL_COUNT) : (seq += 1) {
        writer.write(.{ .seq_num = seq }, 0) catch {
            std.debug.print("FAIL: write() failed at seq_num={d}\n", .{seq});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote historical seq_num={d}\n", .{seq});
    }

    // -- Wait for the late-joining reader to match. --
    const match_deadline = monoNs(io) + MATCH_TIMEOUT_NS;
    while (!state.ever_matched.load(.acquire)) {
        if (monoNs(io) > match_deadline) {
            std.debug.print("FAIL: no reader matched within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }
    std.debug.print("Publisher: reader matched, writing live batch\n", .{});

    // -- Live batch. --
    while (seq < HISTORICAL_COUNT + LIVE_COUNT) : (seq += 1) {
        writer.write(.{ .seq_num = seq }, 0) catch {
            std.debug.print("FAIL: write() failed at seq_num={d}\n", .{seq});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote live seq_num={d}\n", .{seq});
    }

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
