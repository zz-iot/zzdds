//! zig/registry -- publisher.
//!
//! Keyed instance lifecycle reference app, talking to zzdds's native Zig
//! API directly. See docs/design/registry-reference-app.md at the repo
//! root for the full spec. Walks three instances through three different
//! explicit lifecycles: register_instance() -> write() x2 -> dispose()
//! (instance A), register_instance() -> write_w_timestamp() ->
//! unregister_instance_w_timestamp() (instance B), register_instance() ->
//! write() left alive (instance C) -- then confirms get_key_value() rounds
//! the handle it got for instance A back to the right key.
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! writer for topic:", "Publisher: registered instance sensor_id=",
//! "Publisher: wrote sensor_id=", "Publisher: disposed sensor_id=",
//! "Publisher: unregistered sensor_id=", "Publisher: get_key_value
//! round-trip OK for sensor_id=", "Publisher: done." Any failure path
//! prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const registry_gen = @import("registry_gen");

const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

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
    if (!zzdds.registerTypeSupport(dp, "SensorReading", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = registry_gen.SensorReading.computeKeyHashFromCdr,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("SensorReading", "SensorReading", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: SensorReading\n", .{});

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
    std.debug.print("Create writer for topic: SensorReading\n", .{});

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

    const writer = registry_gen.SensorReadingDataWriter.init(dw, alloc);

    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!state.reader_ready.load(.acquire)) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    // ── Instance A (sensor_id=1): register -> write x2 -> dispose ────────
    const handle_a = writer.register_instance(.{ .sensor_id = 1, .value = 0 });
    std.debug.print("Publisher: registered instance sensor_id=1\n", .{});

    writer.write(.{ .sensor_id = 1, .value = 100 }, handle_a) catch {
        std.debug.print("FAIL: write() failed for sensor_id=1\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Publisher: wrote sensor_id=1 value=100\n", .{});

    writer.write(.{ .sensor_id = 1, .value = 101 }, handle_a) catch {
        std.debug.print("FAIL: write() failed for sensor_id=1\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Publisher: wrote sensor_id=1 value=101\n", .{});

    writer.dispose(.{ .sensor_id = 1, .value = 0 }, handle_a) catch {
        std.debug.print("FAIL: dispose() failed for sensor_id=1\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Publisher: disposed sensor_id=1\n", .{});

    // ── Instance B (sensor_id=2): register -> write_w_timestamp -> unregister_w_timestamp ──
    const handle_b = writer.register_instance(.{ .sensor_id = 2, .value = 0 });
    std.debug.print("Publisher: registered instance sensor_id=2\n", .{});

    const now_real_ns = std.Io.Clock.real.now(io).nanoseconds;
    const ts = DDS.Time_t{
        .sec = @intCast(@divTrunc(now_real_ns, std.time.ns_per_s)),
        .nanosec = @intCast(@mod(now_real_ns, std.time.ns_per_s)),
    };
    writer.write_w_timestamp(.{ .sensor_id = 2, .value = 200 }, handle_b, ts) catch {
        std.debug.print("FAIL: write_w_timestamp() failed for sensor_id=2\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Publisher: wrote sensor_id=2 value=200\n", .{});

    writer.unregister_instance_w_timestamp(.{ .sensor_id = 2, .value = 0 }, handle_b, ts) catch {
        std.debug.print("FAIL: unregister_instance_w_timestamp() failed for sensor_id=2\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Publisher: unregistered sensor_id=2\n", .{});

    // ── Instance C (sensor_id=3): register -> write, left alive ──────────
    const handle_c = writer.register_instance(.{ .sensor_id = 3, .value = 0 });
    std.debug.print("Publisher: registered instance sensor_id=3\n", .{});

    writer.write(.{ .sensor_id = 3, .value = 300 }, handle_c) catch {
        std.debug.print("FAIL: write() failed for sensor_id=3\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Publisher: wrote sensor_id=3 value=300\n", .{});

    // ── get_key_value() round-trip on instance A's handle ────────────────
    var key_holder: registry_gen.SensorReading = .{};
    writer.get_key_value(&key_holder, handle_a) catch {
        std.debug.print("FAIL: get_key_value() failed for sensor_id=1\n", .{});
        std.process.exit(1);
    };
    if (key_holder.sensor_id != 1) {
        std.debug.print("FAIL: get_key_value() round-trip mismatch: expected sensor_id=1, got sensor_id={d}\n", .{key_holder.sensor_id});
        std.process.exit(1);
    }
    std.debug.print("Publisher: get_key_value round-trip OK for sensor_id=1\n", .{});

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
