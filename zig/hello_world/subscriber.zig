//! zig/hello_world -- subscriber.
//!
//! Minimal reliable DDS subscriber, talking to zzdds's native Zig API
//! directly. See docs/design/hello-world-reference-app.md at the repo root
//! for the full spec. Demonstrates `DataReaderListener::on_data_available`:
//! every sample is checked against the next expected `count` (fail fast --
//! any gap or reorder is a hard error, not something to tolerate and
//! report later), and once all 10 arrive in order this process tears its
//! reader down immediately, which is what lets the publisher's matched
//! reader count drop back to zero and exit.
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! reader for topic:", "Subscriber: received count=", "Subscriber: received
//! all 10 samples in order." Any failure path prints a line starting
//! "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const hello_gen = @import("hello_world_gen");

const EXPECTED_SAMPLES: i32 = 10;
const RECEIVE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

// ── Time helpers (std.Io.Clock -- portable across Linux/macOS/Windows,
// unlike the std.os.linux-specific syscalls this used to hand-roll) ─────────

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// ── Listener state and callback ──────────────────────────────────────────────

const State = struct {
    expected_next: i32 = 0,
    all_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,
};

fn onDataAvailable(state: *State, dr: DDS.DataReader) void {
    var reader = hello_gen.HelloWorldDataReader.init(dr, state.alloc);
    while (true) {
        var value: hello_gen.HelloWorld = .{};
        var info: DDS.SampleInfo = .{};
        const got = reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample() CDR error\n", .{});
            std.process.exit(1);
        };
        if (!got) break;
        if (!info.valid_data) continue;

        // Called from zzdds's own network thread; state.expected_next is
        // only ever touched here (single dispatch thread per reader), so no
        // lock is needed for it -- only all_received needs to be atomic,
        // since main() polls it from a different thread.
        if (value.count != state.expected_next) {
            std.debug.print("FAIL: expected count={d} but got count={d}\n", .{ state.expected_next, value.count });
            std.process.exit(1);
        }

        std.debug.print("Subscriber: received count={d} message=\"{s}\"\n", .{ value.count, value.message.slice() });
        state.expected_next += 1;

        if (state.expected_next == EXPECTED_SAMPLES) {
            state.all_received.store(true, .release);
        }
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

    // computeKeyHashFromCdr's ctx is a *const std.mem.Allocator (zidl's Zig
    // backend keeps the rest of the runtime's explicit-allocator idiom rather
    // than the C backend's global-allocator-override equivalent) -- HelloWorld
    // is keyless so it's never actually dereferenced here, but a real example
    // should still pass a real one rather than `undefined`.
    var ts_alloc = alloc;
    if (!zzdds.registerTypeSupport(dp, "HelloWorld", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = hello_gen.HelloWorld.computeKeyHashFromCdr,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("HelloWorld", "HelloWorld", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: HelloWorld\n", .{});

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

    const topic_desc = dp.lookup_topicdescription("HelloWorld");
    const dr = subscriber.create_datareader(topic_desc, dr_qos, dr_listener, DDS.DATA_AVAILABLE_STATUS);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: HelloWorld\n", .{});

    std.debug.print("Subscriber: waiting for {d} samples...\n", .{EXPECTED_SAMPLES});
    const deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (!state.all_received.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: only received {d}/{d} samples within 30s\n", .{ state.expected_next, EXPECTED_SAMPLES });
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    // Tear the reader down immediately -- the publisher is blocked waiting
    // for our matched-reader count to drop back to zero, and delete_reader
    // (not delete_participant, further below) is what actually triggers
    // that transition.
    _ = subscriber.delete_datareader(dr);

    std.debug.print("Subscriber: received all {d} samples in order.\n", .{EXPECTED_SAMPLES});
}
