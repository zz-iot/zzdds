//! zig/source-timestamp -- subscriber (the entity under test). Talks to
//! zzdds's native Zig API directly. Direct Zig port of
//! c/source-timestamp/src/subscriber.c -- see that file's header comment
//! for the full scenario rationale and docs/design/integration-test-tier.md
//! for the scenario spec.
//!
//! Required stdout markers: "Create topic:", "Create reader for topic:",
//! "Subscriber: ready.", "Subscriber: received seq=... with source_timestamp
//! sec=... matching the explicit write timestamp.", "Subscriber: received
//! disposed instance with source_timestamp matching the explicit dispose
//! timestamp.", "Subscriber: done." Any failure path prints a line starting
//! "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const timestamp_event_gen = @import("timestamp_event_gen");

const SAMPLE_COUNT: i32 = 5;
const WRITE_BASE_SEC: i32 = 1000000;
const DISPOSE_SEC: i32 = 2000000;
const DISPOSE_NSEC: u32 = 123456789;
const RECEIVE_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const SubState = struct {
    reader: timestamp_event_gen.TimestampEventDataReader = undefined,
    alive_received: [SAMPLE_COUNT]std.atomic.Value(bool) = .{std.atomic.Value(bool).init(false)} ** SAMPLE_COUNT,
    alive_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    dispose_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dispose_timestamp_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onDataAvailable(state: *SubState, dr: DDS.DataReader) void {
    _ = dr;
    while (true) {
        var value: timestamp_event_gen.TimestampEvent = .{};
        var info: DDS.SampleInfo = .{};
        const got = state.reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample() CDR error\n", .{});
            std.process.exit(1);
        };
        if (!got) break;

        if (info.valid_data) {
            if (value.seq < 0 or value.seq >= SAMPLE_COUNT) {
                std.debug.print("FAIL: unexpected seq={d}\n", .{value.seq});
                std.process.exit(1);
            }
            if (info.source_timestamp.sec != WRITE_BASE_SEC + value.seq or info.source_timestamp.nanosec != 0) {
                std.debug.print("FAIL: seq={d} source_timestamp sec={d} nanosec={d} does not match expected sec={d} nanosec=0\n", .{ value.seq, info.source_timestamp.sec, info.source_timestamp.nanosec, WRITE_BASE_SEC + value.seq });
                std.process.exit(1);
            }
            std.debug.print("Subscriber: received seq={d} with source_timestamp sec={d} matching the explicit write timestamp.\n", .{ value.seq, info.source_timestamp.sec });
            const idx: usize = @intCast(value.seq);
            if (!state.alive_received[idx].load(.acquire)) {
                state.alive_received[idx].store(true, .release);
                _ = state.alive_count.fetchAdd(1, .acq_rel);
            }
        } else if (info.instance_state == DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE) {
            state.dispose_received.store(true, .release);
            if (info.source_timestamp.sec == DISPOSE_SEC and info.source_timestamp.nanosec == DISPOSE_NSEC) {
                state.dispose_timestamp_ok.store(true, .release);
            } else {
                std.debug.print("FAIL: disposed-instance source_timestamp sec={d} nanosec={d} does not match expected sec={d} nanosec={d}\n", .{ info.source_timestamp.sec, info.source_timestamp.nanosec, DISPOSE_SEC, DISPOSE_NSEC });
                std.process.exit(1);
            }
        }
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

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const topic_desc = topic.vtable.as_TopicDescription(topic.ptr);
    const dr = subscriber.create_datareader(topic_desc, dr_qos, null, 0);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: TimestampEvent\n", .{});

    var state = SubState{};
    state.reader = timestamp_event_gen.TimestampEventDataReader.init(dr, alloc);

    const dr_listener = DDS.dataReaderListener(&state, .{ .on_data_available = onDataAvailable });
    if (dr.set_listener(dr_listener, DDS.DATA_AVAILABLE_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener() failed\n", .{});
        std.process.exit(1);
    }

    std.debug.print("Subscriber: ready.\n", .{});

    const deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (state.alive_count.load(.acquire) < SAMPLE_COUNT or !state.dispose_received.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: only received {d}/{d} alive samples and dispose_received={} within 20s\n", .{ state.alive_count.load(.acquire), SAMPLE_COUNT, state.dispose_received.load(.acquire) });
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    if (!state.dispose_timestamp_ok.load(.acquire)) {
        std.debug.print("FAIL: dispose sample was received but its timestamp never matched (should have exited already)\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: received disposed instance with source_timestamp matching the explicit dispose timestamp.\n", .{});

    std.debug.print("Subscriber: done.\n", .{});
}
