//! zig/registry -- subscriber.
//!
//! Keyed instance lifecycle reference app, talking to zzdds's native Zig
//! API directly. See docs/design/registry-reference-app.md at the repo
//! root for the full spec. Tracks each of the publisher's three instances'
//! observed SampleInfo.instance_state sequence (fail fast on an unexpected
//! transition), and once all three have reached their expected outcome,
//! calls lookup_instance() to confirm the key-to-handle direction matches
//! what the publisher's own samples for that instance carried.
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! reader for topic:", "Subscriber: sensor_id=... instance_state=...",
//! "Subscriber: lookup_instance round-trip OK for sensor_id=",
//! "Subscriber: all three instance lifecycles observed correctly." Any
//! failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const registry_gen = @import("registry_gen");

const RECEIVE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

fn stateName(s: DDS.InstanceStateKind) []const u8 {
    return switch (s) {
        DDS.ALIVE_INSTANCE_STATE => "ALIVE",
        DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE => "NOT_ALIVE_DISPOSED",
        DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE => "NOT_ALIVE_NO_WRITERS",
        else => "UNKNOWN",
    };
}

const InstanceTrack = struct {
    sensor_id: i32,
    seen_alive: bool = false,
    reached_terminal: bool = false,
    handle: DDS.InstanceHandle_t = 0,
};

const State = struct {
    reader: registry_gen.SensorReadingDataReader = undefined,
    alloc: std.mem.Allocator,
    tracks: [3]InstanceTrack = .{
        .{ .sensor_id = 1 },
        .{ .sensor_id = 2 },
        .{ .sensor_id = 3 },
    },
    lookup_checked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    all_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fail_msg_printed: bool = false,
};

fn trackFor(state: *State, sensor_id: i32) *InstanceTrack {
    for (&state.tracks) |*t| {
        if (t.sensor_id == sensor_id) return t;
    }
    std.debug.print("FAIL: unexpected sensor_id={d}\n", .{sensor_id});
    std.process.exit(1);
}

fn allInstancesDone(state: *State) bool {
    for (state.tracks) |t| {
        if (!t.reached_terminal) return false;
    }
    return true;
}

fn onDataAvailable(state: *State, dr: DDS.DataReader) void {
    _ = dr;
    // Deferred, not stored directly inside the loop below: main() deletes
    // the reader as soon as it observes state.all_done, so storing it
    // mid-loop would let main()'s delete_datareader() race this same
    // invocation's next take_next_sample() call. Only commit the flag once
    // this invocation's take loop has fully drained and won't touch the
    // reader again.
    var became_done = false;
    while (true) {
        var value: registry_gen.SensorReading = .{};
        var info: DDS.SampleInfo = .{};
        const got = state.reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample() CDR error\n", .{});
            std.process.exit(1);
        };
        if (!got) break;

        const track = trackFor(state, value.sensor_id);
        std.debug.print("Subscriber: sensor_id={d} instance_state={s}\n", .{ value.sensor_id, stateName(info.instance_state) });
        track.handle = info.instance_handle;

        switch (info.instance_state) {
            DDS.ALIVE_INSTANCE_STATE => {
                track.seen_alive = true;
                // Instance C (sensor_id=3) is left alive forever -- one ALIVE
                // sample is all it ever gets, so it's "done" the moment we've
                // seen it, not waiting for a terminal state that never comes.
                if (track.sensor_id == 3) track.reached_terminal = true;
            },
            DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE => {
                if (track.sensor_id != 1) {
                    std.debug.print("FAIL: unexpected NOT_ALIVE_DISPOSED for sensor_id={d}\n", .{track.sensor_id});
                    std.process.exit(1);
                }
                if (!track.seen_alive) {
                    std.debug.print("FAIL: sensor_id=1 reached NOT_ALIVE_DISPOSED without ever being ALIVE\n", .{});
                    std.process.exit(1);
                }
                track.reached_terminal = true;
            },
            DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE => {
                if (track.sensor_id != 2) {
                    std.debug.print("FAIL: unexpected NOT_ALIVE_NO_WRITERS for sensor_id={d}\n", .{track.sensor_id});
                    std.process.exit(1);
                }
                if (!track.seen_alive) {
                    std.debug.print("FAIL: sensor_id=2 reached NOT_ALIVE_NO_WRITERS without ever being ALIVE\n", .{});
                    std.process.exit(1);
                }
                track.reached_terminal = true;
            },
            else => {
                std.debug.print("FAIL: unknown instance_state={d} for sensor_id={d}\n", .{ info.instance_state, track.sensor_id });
                std.process.exit(1);
            },
        }

        if (allInstancesDone(state) and !state.lookup_checked.load(.acquire)) {
            const c_track = trackFor(state, 3);
            const looked_up = state.reader.lookup_instance(.{ .sensor_id = 3, .value = 0 });
            if (looked_up == null or looked_up.? != c_track.handle) {
                std.debug.print("FAIL: lookup_instance() round-trip mismatch for sensor_id=3\n", .{});
                std.process.exit(1);
            }
            std.debug.print("Subscriber: lookup_instance round-trip OK for sensor_id=3\n", .{});
            state.lookup_checked.store(true, .release);
            became_done = true;
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

    // Create with no listener attached yet: on_data_available fires on a
    // zzdds-internal dispatch thread as soon as the reader matches, which
    // can race state.reader's own initialization below. Attach the listener
    // only once state.reader is set, via set_listener() below, closing the
    // window entirely.
    const topic_desc = dp.lookup_topicdescription("SensorReading");
    const dr = subscriber.create_datareader(topic_desc, dr_qos, null, 0);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: SensorReading\n", .{});
    state.reader = registry_gen.SensorReadingDataReader.init(dr, alloc);
    const set_rc = dr.set_listener(dr_listener, DDS.DATA_AVAILABLE_STATUS);
    if (set_rc != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener() returned {d}\n", .{set_rc});
        std.process.exit(1);
    }

    std.debug.print("Subscriber: waiting for all three instance lifecycles...\n", .{});
    const deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (!state.all_done.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: did not observe all three instance lifecycles within 30s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    _ = subscriber.delete_datareader(dr);

    std.debug.print("Subscriber: all three instance lifecycles observed correctly.\n", .{});
}
