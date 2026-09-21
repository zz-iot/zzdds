//! zig/enable-defer -- peer. Simple counterpart to configurer.zig: creates a
//! normal, fully-enabled DataReader on ConfigTopic immediately, then spends
//! ~3 seconds (comfortably inside the configurer's own ~4s pre-enable delay)
//! proving it observes ZERO matching -- direct evidence the deferred SEDP
//! announcement genuinely never went out while the configurer's writer was
//! disabled. After that window, waits normally for matching and 5 samples.
//! See docs/design/integration-test-tier.md for the full scenario spec.
//!
//! Required stdout markers: "Create topic: ConfigTopic", "Create reader for
//! topic: ConfigTopic", "Peer: no premature match during Ns window.", "Peer:
//! no premature match; matched and received cleanly after enable()." Any
//! failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const config_event_gen = @import("config_event_gen");

const SAMPLE_TARGET: i32 = 5;
const PREMATURE_CHECK_WINDOW_NS: i64 = 3 * std.time.ns_per_s;
const MATCH_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const RECEIVE_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
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
    if (!zzdds.registerTypeSupport(dp, "ConfigEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = config_event_gen.ConfigEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = config_event_gen.ConfigEvent.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport(ConfigEvent) failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("ConfigTopic", "ConfigEvent", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(ConfigTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: ConfigTopic\n", .{});

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const dr = subscriber.create_datareader(topic.vtable.as_TopicDescription(topic.ptr), dr_qos, null, 0);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(ConfigTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: ConfigTopic\n", .{});

    var reader = config_event_gen.ConfigEventDataReader.init(dr, alloc);

    // Core assertion: for a window comfortably inside the configurer's own
    // pre-enable delay, matched-current-count must stay exactly 0 -- direct
    // proof the deferred SEDP announcement genuinely never went out while
    // the configurer's writer was disabled.
    {
        var status: DDS.SubscriptionMatchedStatus = undefined;
        const deadline = monoNs(io) + PREMATURE_CHECK_WINDOW_NS;
        while (monoNs(io) < deadline) {
            if (dr.get_subscription_matched_status(&status) != DDS.RETCODE_OK) {
                std.debug.print("FAIL: get_subscription_matched_status() failed\n", .{});
                std.process.exit(1);
            }
            if (status.current_count != 0) {
                std.debug.print("FAIL: matched before enable() was called -- deferred SEDP announcement isn't working (current_count={d})\n", .{status.current_count});
                std.process.exit(1);
            }
            sleepNs(io, POLL_PERIOD_NS);
        }
    }
    std.debug.print("Peer: no premature match during {d}s window.\n", .{@divTrunc(PREMATURE_CHECK_WINDOW_NS, std.time.ns_per_s)});

    // Now wait normally for the real match, once the configurer enables.
    {
        var status: DDS.SubscriptionMatchedStatus = undefined;
        const deadline = monoNs(io) + MATCH_TIMEOUT_NS;
        var matched = false;
        while (!matched) {
            if (monoNs(io) > deadline) {
                std.debug.print("FAIL: never matched within 30s of the premature-match window ending\n", .{});
                std.process.exit(1);
            }
            if (dr.get_subscription_matched_status(&status) != DDS.RETCODE_OK) {
                std.debug.print("FAIL: get_subscription_matched_status() failed\n", .{});
                std.process.exit(1);
            }
            if (status.current_count > 0) matched = true else sleepNs(io, POLL_PERIOD_NS);
        }
    }

    var received: i32 = 0;
    var last_seq: i32 = -1;
    const receive_deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (received < SAMPLE_TARGET) {
        if (monoNs(io) > receive_deadline) {
            std.debug.print("FAIL: did not receive all {d} samples within 20s (got {d})\n", .{ SAMPLE_TARGET, received });
            std.process.exit(1);
        }
        var taken: std.ArrayListUnmanaged(config_event_gen.ConfigEventDataReader.SampledValue) = .empty;
        defer taken.deinit(alloc);
        _ = try reader.take(&taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
        for (taken.items) |sv| {
            if (sv.value.seq != last_seq + 1) {
                std.debug.print("FAIL: out-of-order sample, expected seq={d} got seq={d}\n", .{ last_seq + 1, sv.value.seq });
                std.process.exit(1);
            }
            last_seq = sv.value.seq;
            received += 1;
        }
        if (received < SAMPLE_TARGET) sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Peer: no premature match; matched and received cleanly after enable().\n", .{});
}
