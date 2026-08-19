//! zig/hello_world -- publisher.
//!
//! Minimal reliable DDS publisher, talking to zzdds's native Zig API
//! directly (no C ABI, no vendor-neutral shim). See
//! docs/design/hello-world-reference-app.md at the repo root for the full
//! spec. Demonstrates two things:
//!
//!   1. zzdds's `DataWriterListenerEx::on_reliable_reader_ready` extension --
//!      fires once a matched RELIABLE reader has actually completed the
//!      AckNack/Heartbeat handshake (not just SEDP discovery), so a write
//!      issued right after is guaranteed deliverable. We wait for it before
//!      writing anything.
//!   2. Clean shutdown gated on `PublicationMatchedStatus.current_count`
//!      returning to zero -- i.e. waiting for the subscriber to actually
//!      tear its reader down, not just for our own writes to finish.
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! writer for topic:", "on_reliable_reader_ready", "Publisher: wrote
//! count=", "on_publication_matched", "Publisher: done." Any failure path
//! prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const hello_gen = @import("hello_world_gen");

const SAMPLE_COUNT: i32 = 10;
const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

// ── Time helpers (std.time.sleep/nanoTimestamp don't exist in this Zig --
// std.Io.Clock is the portable replacement, correct on Linux/macOS/Windows
// alike, unlike the std.os.linux-specific syscalls this used to hand-roll).

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// ── Listener state, shared between the network thread (callbacks) and main ──

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
    std.debug.print("Create writer for topic: HelloWorld\n", .{});

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

    const writer = hello_gen.HelloWorldDataWriter.init(dw, alloc);

    // Wait for a reliable reader to complete the AckNack/Heartbeat handshake
    // before writing anything -- this is the whole point of the extension.
    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!state.reader_ready.load(.acquire)) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    var i: i32 = 0;
    while (i < SAMPLE_COUNT) : (i += 1) {
        var sample = hello_gen.HelloWorld{ .count = i };
        sample.message = @TypeOf(sample.message).fromSlice("Hello world!") catch .{};
        writer.write(sample, 0) catch {
            std.debug.print("FAIL: write() failed at count={d}\n", .{i});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote count={d} message=\"Hello world!\"\n", .{i});
    }

    // Wait for the subscriber to tear its reader down (current_count back to
    // zero) before exiting -- proves the write actually made it and was
    // acknowledged as far as match bookkeeping is concerned, not just that
    // write() returned locally.
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
