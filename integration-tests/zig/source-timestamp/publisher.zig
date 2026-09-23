//! zig/source-timestamp -- publisher. Talks to zzdds's native Zig API
//! directly. Direct Zig port of c/source-timestamp/src/publisher.c -- see
//! that file's header comment for the full scenario rationale and
//! docs/design/integration-test-tier.md for the scenario spec.
//!
//! Required stdout markers: "Create topic:", "Create writer for topic:",
//! "Publisher: wrote seq=... with explicit timestamp", "Publisher: disposed
//! instance with explicit timestamp", "Publisher: done." Any failure path
//! prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const timestamp_event_gen = @import("timestamp_event_gen");

const SAMPLE_COUNT: i32 = 5;
const WRITE_BASE_SEC: i32 = 1000000;
const DISPOSE_SEC: i32 = 2000000;
const DISPOSE_NSEC: u32 = 123456789;
const MATCH_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const PubState = struct {
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
};

fn onPublicationMatched(state: *PubState, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
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
    if (!zzdds.registerTypeSupport(dp, "TimestampEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = timestamp_event_gen.TimestampEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = timestamp_event_gen.TimestampEvent.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("TimestampEvent", "TimestampEvent", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: TimestampEvent\n", .{});

    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const dw = publisher.create_datawriter(topic, dw_qos, null, 0);
    if (dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: TimestampEvent\n", .{});

    var state = PubState{};
    const dw_listener = DDS.dataWriterListener(&state, .{
        .on_publication_matched = onPublicationMatched,
    });
    if (dw.set_listener(dw_listener, DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener failed\n", .{});
        std.process.exit(1);
    }

    const writer = timestamp_event_gen.TimestampEventDataWriter.init(dw, alloc);

    const match_deadline = monoNs(io) + MATCH_TIMEOUT_NS;
    while (state.matched_current_count.load(.acquire) < 1) {
        if (monoNs(io) > match_deadline) {
            std.debug.print("FAIL: no reader matched within 20s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    var seq: i32 = 0;
    while (seq < SAMPLE_COUNT) : (seq += 1) {
        const ts = DDS.Time_t{ .sec = WRITE_BASE_SEC + seq, .nanosec = 0 };
        writer.write_w_timestamp(.{ .id = 0, .seq = seq }, 0, ts) catch {
            std.debug.print("FAIL: write_w_timestamp() failed at seq={d}\n", .{seq});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote seq={d} with explicit timestamp sec={d}\n", .{ seq, ts.sec });
    }

    const dispose_ts = DDS.Time_t{ .sec = DISPOSE_SEC, .nanosec = DISPOSE_NSEC };
    writer.dispose_w_timestamp(.{ .id = 0, .seq = 0 }, 0, dispose_ts) catch {
        std.debug.print("FAIL: dispose_w_timestamp() failed\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Publisher: disposed instance with explicit timestamp sec={d} nanosec={d}\n", .{ dispose_ts.sec, dispose_ts.nanosec });

    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (state.matched_current_count.load(.acquire) != 0) {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Publisher: done.\n", .{});
}
