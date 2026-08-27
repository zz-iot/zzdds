//! zig/presence -- subscriber.
//!
//! LIVELINESS QoS reference app, talking to zzdds's native Zig API directly.
//! See docs/design/presence-reference-app.md at the repo root for the full
//! spec. Demonstrates DataReaderListener::on_liveliness_changed: the reader
//! observes the writer's lease expiring (going OFFLINE) and later recovering
//! (going back ONLINE) after an explicit assert_liveliness() call, and
//! asserts that it saw the full online -> offline -> online cycle in order.
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! reader for topic:", "ONLINE alive_count=", "OFFLINE alive_count=",
//! "Subscriber: observed full online -> offline -> online cycle." Any
//! failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const presence_gen = @import("presence_gen");

const CYCLE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

// ── Time helpers (std.Io.Clock -- portable across Linux/macOS/Windows) ──────

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// ── Listener state and callbacks ─────────────────────────────────────────────

const Phase = enum { waiting_first_online, waiting_offline, waiting_second_online, done };

const State = struct {
    // Only ever written by the listener-dispatch thread (both callbacks are
    // dispatched serially per reader, same assumption zig/hello_world's
    // on_data_available makes about its own single-threaded field access) --
    // but main() polls `step` for its FAIL-path diagnostic from a different
    // thread, so that one field needs to be atomic even though `phase`
    // itself doesn't strictly need to be.
    phase: Phase = .waiting_first_online,
    step: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    cycle_complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,
};

fn onLivelinessChanged(state: *State, dr: DDS.DataReader, status: DDS.LivelinessChangedStatus) void {
    _ = dr;
    const online = status.alive_count > 0;
    if (online) {
        std.debug.print("ONLINE alive_count={d} not_alive_count={d}\n", .{ status.alive_count, status.not_alive_count });
    } else {
        std.debug.print("OFFLINE alive_count={d} not_alive_count={d}\n", .{ status.alive_count, status.not_alive_count });
    }

    switch (state.phase) {
        .waiting_first_online => if (online) {
            state.phase = .waiting_offline;
            state.step.store(1, .release);
        },
        .waiting_offline => if (!online) {
            state.phase = .waiting_second_online;
            state.step.store(2, .release);
        },
        .waiting_second_online => if (online) {
            state.phase = .done;
            state.step.store(3, .release);
            state.cycle_complete.store(true, .release);
        },
        .done => {},
    }
}

fn onDataAvailable(state: *State, dr: DDS.DataReader) void {
    var reader = presence_gen.PresenceBeaconDataReader.init(dr, state.alloc);
    while (true) {
        var value: presence_gen.PresenceBeacon = .{};
        var info: DDS.SampleInfo = .{};
        const got = reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample() CDR error\n", .{});
            std.process.exit(1);
        };
        if (!got) break;
        if (!info.valid_data) continue;
        std.debug.print("Subscriber: received sequence={d}\n", .{value.seq_num});
    }
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

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    dr_qos.history.depth = 1;
    dr_qos.liveliness.kind = .MANUAL_BY_TOPIC_LIVELINESS_QOS;
    dr_qos.liveliness.lease_duration = .{ .sec = 2, .nanosec = 0 };

    var state = State{ .alloc = alloc };
    const dr_listener = DDS.dataReaderListener(&state, .{
        .on_data_available = onDataAvailable,
        .on_liveliness_changed = onLivelinessChanged,
    });

    const topic_desc = dp.lookup_topicdescription("PresenceBeacon");
    const dr = subscriber.create_datareader(topic_desc, dr_qos, dr_listener, DDS.DATA_AVAILABLE_STATUS | DDS.LIVELINESS_CHANGED_STATUS);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: PresenceBeacon\n", .{});

    std.debug.print("Subscriber: waiting for online -> offline -> online cycle...\n", .{});
    const deadline = monoNs(io) + CYCLE_TIMEOUT_NS;
    while (!state.cycle_complete.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: did not observe the full cycle within 30s (stuck at step={d})\n", .{state.step.load(.acquire)});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    _ = subscriber.delete_datareader(dr);

    std.debug.print("Subscriber: observed full online -> offline -> online cycle.\n", .{});
}
