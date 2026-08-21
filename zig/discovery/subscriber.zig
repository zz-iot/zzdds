//! zig/discovery -- subscriber.
//!
//! Waits for a matched publication (polling `DataReader.get_matched_
//! publications`, bounded by a timeout, same convention as every other
//! "wait for X" loop in this example set), then calls
//! `DataReader.get_matched_publication_data` to look up the matched
//! writer's own topic/type name. Then runs the same minimal reliable read
//! loop (3 samples) as hello_world/participant-config, to prove the reader
//! still works normally.
//!
//! `publication_data` is a fresh, caller-owned copy, `.deinit(std.heap.
//! c_allocator)`'d after use (always c_allocator, regardless of this
//! process's own DebugAllocator: see `vtGetMatchedPubData`'s comment in
//! zzdds's `src/dcps/reader.zig` for why).
//!
//! Required stdout markers: "Create topic:", "Create reader for topic:",
//! "Discovery OK (reader):", "Subscriber: received count=", "Subscriber:
//! received all 3 samples in order." Any failure path prints a line
//! starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ping_gen = @import("discovery_ping_gen");

const EXPECTED_SAMPLES: i32 = 3;
const MATCH_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const RECEIVE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

const TOPIC_NAME = "DiscoveryPing";
const TYPE_NAME = "DiscoveryPing";

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const State = struct {
    expected_next: i32 = 0,
    all_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,
};

fn onDataAvailable(state: *State, dr: DDS.DataReader) void {
    var reader = ping_gen.DiscoveryPingDataReader.init(dr, state.alloc);
    while (true) {
        var value: ping_gen.DiscoveryPing = .{};
        var info: DDS.SampleInfo = .{};
        const got = reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample() CDR error\n", .{});
            std.process.exit(1);
        };
        if (!got) break;
        if (!info.valid_data) continue;

        if (value.count != state.expected_next) {
            std.debug.print("FAIL: expected count={d} but got count={d}\n", .{ state.expected_next, value.count });
            std.process.exit(1);
        }

        std.debug.print("Subscriber: received count={d}\n", .{value.count});
        state.expected_next += 1;

        if (state.expected_next == EXPECTED_SAMPLES) {
            state.all_received.store(true, .release);
        }
    }
}

const Options = struct {
    domain_id: u32 = 0,
};

fn parseArgs(process_args: std.process.Args) Options {
    var opts = Options{};
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            const v = it.next() orelse continue;
            opts.domain_id = std.fmt.parseInt(u32, v, 10) catch 0;
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const opts = parseArgs(init.minimal.args);

    var factory = zzdds.createFactory() catch {
        std.debug.print("FAIL: createFactory() failed\n", .{});
        std.process.exit(1);
    };
    defer factory.deinit();

    const dpf = factory.toDDSFactory();
    const dp = dpf.create_participant(opts.domain_id, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_participant() failed on domain {d}\n", .{opts.domain_id});
        std.process.exit(1);
    }
    defer _ = dpf.delete_participant(dp);

    var ts_alloc = alloc;
    if (!zzdds.registerTypeSupport(dp, TOPIC_NAME, .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = ping_gen.DiscoveryPing.computeKeyHashFromCdr,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic(TOPIC_NAME, TYPE_NAME, .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: {s}\n", .{TOPIC_NAME});

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    var state = State{ .alloc = alloc };
    const dr_listener = DDS.dataReaderListener(&state, .{
        .on_data_available = onDataAvailable,
    });

    const topic_desc = dp.lookup_topicdescription(TOPIC_NAME);
    const dr = subscriber.create_datareader(topic_desc, dr_qos, dr_listener, DDS.DATA_AVAILABLE_STATUS);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: {s}\n", .{TOPIC_NAME});

    // Reader-level discovery: wait for the remote publisher to match.
    var pub_handles: DDS.InstanceHandleSeq = .{};
    const match_deadline = monoNs(io) + MATCH_TIMEOUT_NS;
    while (true) {
        if (dr.get_matched_publications(&pub_handles) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: get_matched_publications() failed\n", .{});
            std.process.exit(1);
        }
        if (pub_handles._length > 0) break;
        if (monoNs(io) > match_deadline) {
            std.debug.print("FAIL: no matched publication within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }
    var pub_data: DDS.PublicationBuiltinTopicData = .{};
    defer pub_data.deinit(std.heap.c_allocator);
    if (dr.get_matched_publication_data(&pub_data, pub_handles._buffer.?[0]) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: get_matched_publication_data() failed\n", .{});
        std.process.exit(1);
    }
    if (!std.mem.eql(u8, pub_data.topic_name, TOPIC_NAME) or !std.mem.eql(u8, pub_data.type_name, TYPE_NAME)) {
        std.debug.print("FAIL: matched publication topic_name/type_name mismatch: got '{s}'/'{s}'\n", .{ pub_data.topic_name, pub_data.type_name });
        std.process.exit(1);
    }
    std.debug.print("Discovery OK (reader): matched_publication.topic_name='{s}' type_name='{s}'\n", .{ pub_data.topic_name, pub_data.type_name });

    std.debug.print("Subscriber: waiting for {d} samples...\n", .{EXPECTED_SAMPLES});
    const deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (!state.all_received.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: only received {d}/{d} samples within 30s\n", .{ state.expected_next, EXPECTED_SAMPLES });
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    _ = subscriber.delete_datareader(dr);

    std.debug.print("Subscriber: received all {d} samples in order.\n", .{EXPECTED_SAMPLES});
}
