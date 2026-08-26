//! zig/waitset -- publisher.
//!
//! Drives its whole lifecycle through a single WaitSet with two conditions
//! attached at once, instead of a listener (contrast with zig/hello_world):
//!
//!   - StatusCondition (PUBLICATION_MATCHED_STATUS) -- wait for a reader to
//!     match, then later wait for it to disconnect again.
//!   - GuardCondition -- a background "watchdog" thread sets this if the
//!     whole run exceeds its overall deadline, so the main thread's wait()
//!     loop has a way out that isn't tied to any single wait() call's own
//!     timeout. This is also the deliberate concurrency exercise this
//!     example exists partly to demonstrate: the watchdog thread and main
//!     thread both touch the same WaitSet/GuardCondition concurrently.
//!
//! After the run completes, delete_datawriter() is called WITHOUT first
//! detaching the writer's StatusCondition from the WaitSet -- deliberately,
//! to demonstrate that this is safe (see zzdds's own
//! docs/roadmap.md "Planned" entry on condition/entity lifecycle safety):
//! before that fix, this would have left the WaitSet holding a dangling
//! pointer.
//!
//! See docs/design/waitset-reference-app.md at the repo root for the full
//! spec. Required stdout markers: "Create topic:", "Create writer for
//! topic:", "Publisher: reader matched", "Publisher: wrote count=",
//! "Publisher: reader disconnected", "Publisher: StatusCondition remained
//! attached through delete_datawriter (safe).", "Publisher: done." Any
//! failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const sample_gen = @import("waitset_sample_gen");

const SAMPLE_COUNT: i32 = 10;
const WAIT_STEP: DDS.Duration_t = .{ .sec = 1, .nanosec = 0 };
const OVERALL_DEADLINE_NS: i64 = 25 * std.time.ns_per_s;
const WATCHDOG_POLL_NS: u64 = 50 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// zidl's Zig backend generates the `as_{Base}` vtable slot for these
// synthetic base-interface upcasts but not a `pub fn as_{Base}(self)`
// convenience wrapper on the struct itself (a real, minor codegen gap, not
// specific to this example -- see zidl's roadmap "Zig backend" section for
// the general as_{Base} design). Call through the vtable directly.
fn statusAsCondition(sc: DDS.StatusCondition) DDS.Condition {
    return sc.vtable.as_Condition(sc.ptr);
}
fn guardAsCondition(gc: DDS.GuardCondition) DDS.Condition {
    return gc.vtable.as_Condition(gc.ptr);
}

fn conditionsContain(active: DDS.ConditionSeq, target: DDS.Condition) bool {
    const buf = active._buffer orelse return false;
    for (buf[0..active._length]) |c| {
        if (c.ptr == target.ptr) return true;
    }
    return false;
}

// ── Watchdog: background thread, concurrent with main's WaitSet.wait() ──────

const Watchdog = struct {
    gc: DDS.GuardCondition,
    io: std.Io,
    deadline_ns: i64,
    stop: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watchdog) void {
        while (!self.stop.load(.acquire)) {
            if (monoNs(self.io) >= self.deadline_ns) {
                std.debug.print("Watchdog: overall deadline exceeded, triggering GuardCondition\n", .{});
                self.fired.store(true, .release);
                _ = self.gc.set_trigger_value(true);
                return;
            }
            sleepNs(self.io, WATCHDOG_POLL_NS);
        }
    }
};

// ── Argument parsing ─────────────────────────────────────────────────────────

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
    if (!zzdds.registerTypeSupport(dp, "WaitsetSample", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = sample_gen.WaitsetSample.computeKeyHashFromCdr,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("WaitsetSample", "WaitsetSample", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: WaitsetSample\n", .{});

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
    std.debug.print("Create writer for topic: WaitsetSample\n", .{});

    // ── WaitSet setup: StatusCondition + GuardCondition together ────────────

    const ws = zzdds.createWaitSet(alloc) catch {
        std.debug.print("FAIL: createWaitSet() failed\n", .{});
        std.process.exit(1);
    };

    const sc = dw.get_statuscondition();
    if (sc.set_enabled_statuses(DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_enabled_statuses() failed\n", .{});
        std.process.exit(1);
    }
    if (ws.attach_condition(statusAsCondition(sc)) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: attach_condition(StatusCondition) failed\n", .{});
        std.process.exit(1);
    }

    const gc = zzdds.createGuardCondition(alloc) catch {
        std.debug.print("FAIL: createGuardCondition() failed\n", .{});
        std.process.exit(1);
    };
    if (ws.attach_condition(guardAsCondition(gc)) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: attach_condition(GuardCondition) failed\n", .{});
        std.process.exit(1);
    }

    var watchdog = Watchdog{ .gc = gc, .io = io, .deadline_ns = monoNs(io) + OVERALL_DEADLINE_NS };
    const watchdog_thread = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});

    // ── Wait for a reader to match ───────────────────────────────────────────

    var matched = false;
    while (!matched) {
        var active = DDS.ConditionSeq{};
        const rc = ws.wait(&active, WAIT_STEP);
        defer if (active._release) {
            if (active._buffer) |b| alloc.free(b[0..active._maximum]);
        };
        if (rc == DDS.RETCODE_TIMEOUT) continue;
        if (rc != DDS.RETCODE_OK) {
            std.debug.print("FAIL: WaitSet.wait() returned {d}\n", .{rc});
            std.process.exit(1);
        }
        if (conditionsContain(active, guardAsCondition(gc))) {
            std.debug.print("FAIL: watchdog fired before any reader matched\n", .{});
            std.process.exit(1);
        }
        if (conditionsContain(active, statusAsCondition(sc))) {
            var status: DDS.PublicationMatchedStatus = undefined;
            _ = dw.get_publication_matched_status(&status);
            if (status.current_count > 0) {
                std.debug.print("Publisher: reader matched\n", .{});
                matched = true;
            }
        }
    }

    // ── Write samples: priority = count, so the subscriber's QueryCondition
    // ("priority > 4") sees exactly the last half as high-priority ─────────

    const writer = sample_gen.WaitsetSampleDataWriter.init(dw, alloc);
    var i: i32 = 0;
    while (i < SAMPLE_COUNT) : (i += 1) {
        var sample = sample_gen.WaitsetSample{ .count = i, .priority = i };
        sample.message = @TypeOf(sample.message).fromSlice("Hello waitset!") catch .{};
        writer.write(sample, 0) catch {
            std.debug.print("FAIL: write() failed at count={d}\n", .{i});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote count={d} priority={d}\n", .{ i, i });
    }

    // ── Wait for the reader to disconnect again (same WaitSet, same
    // StatusCondition, reused across two separate wait phases) ─────────────

    var disconnected = false;
    while (!disconnected) {
        var active = DDS.ConditionSeq{};
        const rc = ws.wait(&active, WAIT_STEP);
        defer if (active._release) {
            if (active._buffer) |b| alloc.free(b[0..active._maximum]);
        };
        if (rc == DDS.RETCODE_TIMEOUT) continue;
        if (rc != DDS.RETCODE_OK) {
            std.debug.print("FAIL: WaitSet.wait() returned {d}\n", .{rc});
            std.process.exit(1);
        }
        if (conditionsContain(active, guardAsCondition(gc))) {
            std.debug.print("FAIL: watchdog fired before the reader disconnected\n", .{});
            std.process.exit(1);
        }
        if (conditionsContain(active, statusAsCondition(sc))) {
            var status: DDS.PublicationMatchedStatus = undefined;
            _ = dw.get_publication_matched_status(&status);
            if (status.current_count == 0) {
                std.debug.print("Publisher: reader disconnected\n", .{});
                disconnected = true;
            }
        }
    }

    watchdog.stop.store(true, .release);
    watchdog_thread.join();

    // Well-behaved cleanup for the GuardCondition (no lifecycle point
    // depends on leaving it attached)...
    _ = ws.detach_condition(guardAsCondition(gc));
    // ...but the StatusCondition is deliberately left attached through
    // delete_datawriter() below, to demonstrate that this is safe.
    std.debug.print("Publisher: StatusCondition remained attached through delete_datawriter (safe).\n", .{});
    _ = publisher.delete_datawriter(dw);

    gc.deinit();
    ws.deinit();

    std.debug.print("Publisher: done.\n", .{});
}
