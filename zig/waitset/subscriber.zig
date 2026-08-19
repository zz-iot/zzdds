//! zig/waitset -- subscriber.
//!
//! One WaitSet, four conditions attached simultaneously (this is the point
//! of the example -- see docs/design/waitset-reference-app.md at the repo
//! root for the full spec):
//!
//!   - StatusCondition (SUBSCRIPTION_MATCHED_STATUS) -- logs when the writer
//!     matches.
//!   - QueryCondition ("priority > %0", param "4") -- the writer sends
//!     `priority = count` for count 0..9, so this selects exactly the
//!     high-priority half (5..9). Drained via the generated
//!     `WaitsetSampleDataReader.take_w_condition` (what the OMG spec calls
//!     `take_w_condition`, and part of the typed DataReader's implicit IDL
//!     on every binding -- see zidl's roadmap for the fuller writeup on
//!     closing this gap).
//!   - ReadCondition (any sample/view/instance state) -- catches whatever
//!     the QueryCondition pass didn't take (the low-priority half).
//!     Together, ReadCondition + QueryCondition partition every sample that
//!     arrives into exactly two streams each cycle.
//!   - GuardCondition -- same watchdog-thread pattern as the publisher; the
//!     concurrency exercise (background thread + main thread's wait() loop
//!     both touching the same WaitSet) is identical on this side too.
//!
//! Required stdout markers: "Create topic:", "Create reader for topic:",
//! "Subscriber: writer matched", "Subscriber: high-priority count=",
//! "Subscriber: low-priority count=", "Subscriber: received all 10 samples.",
//! "Subscriber: done." Any failure path prints a line starting "FAIL:" and
//! exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const sample_gen = @import("waitset_sample_gen");

const EXPECTED_SAMPLES: i32 = 10;
const HIGH_PRIORITY_THRESHOLD = "4"; // priority > 4 => count 5..9
const WAIT_STEP: DDS.Duration_t = .{ .sec = 1, .nanosec = 0 };
const OVERALL_DEADLINE_NS: i64 = 30 * std.time.ns_per_s;
const WATCHDOG_POLL_NS: u64 = 50 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// See publisher.zig's identical comment: zidl's Zig backend doesn't emit a
// convenience `as_{Base}` wrapper method, only the vtable slot.
fn statusAsCondition(sc: DDS.StatusCondition) DDS.Condition {
    return sc.vtable.as_Condition(sc.ptr);
}
fn guardAsCondition(gc: DDS.GuardCondition) DDS.Condition {
    return gc.vtable.as_Condition(gc.ptr);
}
fn readAsCondition(rc: DDS.ReadCondition) DDS.Condition {
    return rc.vtable.as_Condition(rc.ptr);
}
fn queryAsCondition(qc: DDS.QueryCondition) DDS.Condition {
    const as_rc = qc.vtable.as_ReadCondition(qc.ptr);
    return as_rc.vtable.as_Condition(as_rc.ptr);
}

fn conditionsContain(active: DDS.ConditionSeq, target: DDS.Condition) bool {
    const buf = active._buffer orelse return false;
    for (buf[0..active._length]) |c| {
        if (c.ptr == target.ptr) return true;
    }
    return false;
}

const Watchdog = struct {
    gc: DDS.GuardCondition,
    io: std.Io,
    deadline_ns: i64,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watchdog) void {
        while (!self.stop.load(.acquire)) {
            if (monoNs(self.io) >= self.deadline_ns) {
                std.debug.print("Watchdog: overall deadline exceeded, triggering GuardCondition\n", .{});
                _ = self.gc.set_trigger_value(true);
                return;
            }
            sleepNs(self.io, WATCHDOG_POLL_NS);
        }
    }
};

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

    // Unlike hello_world, this registration needs `get_field` too, not just
    // `compute_key_hash` -- the QueryCondition's "priority > %0" expression
    // needs field-level access to evaluate (see create_querycondition's own
    // precondition: a non-empty expression with no get_field returns NIL).
    var ts_alloc = alloc;
    _ = zzdds.registerTypeSupport(dp, "WaitsetSample", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = sample_gen.WaitsetSample.computeKeyHashFromCdr,
        .get_field = sample_gen.WaitsetSample.getFieldFromCdr,
    });

    const topic = dp.create_topic("WaitsetSample", "WaitsetSample", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: WaitsetSample\n", .{});

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const topic_desc = dp.lookup_topicdescription("WaitsetSample");
    const dr = subscriber.create_datareader(topic_desc, dr_qos, null, 0);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: WaitsetSample\n", .{});
    var typed_dr = sample_gen.WaitsetSampleDataReader.init(dr, alloc);

    // ── WaitSet setup: all four condition types on one WaitSet ──────────────

    const ws = zzdds.createWaitSet(alloc) catch {
        std.debug.print("FAIL: createWaitSet() failed\n", .{});
        std.process.exit(1);
    };
    defer ws.deinit();

    const sc = dr.get_statuscondition();
    if (sc.set_enabled_statuses(DDS.SUBSCRIPTION_MATCHED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_enabled_statuses() failed\n", .{});
        std.process.exit(1);
    }

    const rc = dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    if (rc.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_readcondition() failed\n", .{});
        std.process.exit(1);
    }

    var params = [_][*:0]const u8{HIGH_PRIORITY_THRESHOLD};
    var params_seq = DDS.StringSeq{
        ._buffer = &params,
        ._length = 1,
        ._maximum = 1,
        ._release = false,
    };
    const qc = dr.create_querycondition(
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        "priority > %0",
        &params_seq,
    );
    if (qc.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_querycondition() failed\n", .{});
        std.process.exit(1);
    }

    const gc = zzdds.createGuardCondition(alloc) catch {
        std.debug.print("FAIL: createGuardCondition() failed\n", .{});
        std.process.exit(1);
    };
    defer gc.deinit();

    if (ws.attach_condition(statusAsCondition(sc)) != DDS.RETCODE_OK or
        ws.attach_condition(readAsCondition(rc)) != DDS.RETCODE_OK or
        ws.attach_condition(queryAsCondition(qc)) != DDS.RETCODE_OK or
        ws.attach_condition(guardAsCondition(gc)) != DDS.RETCODE_OK)
    {
        std.debug.print("FAIL: attach_condition() failed\n", .{});
        std.process.exit(1);
    }

    // WaitSet.get_conditions() -- all four attached conditions, regardless of
    // trigger state, distinct from wait()'s own out-param (only the ones
    // that triggered *this* call). Otherwise unexercised anywhere in this
    // project; a real assertion here (not just a call) is nearly free given
    // this WaitSet's attached set is already known exactly.
    {
        var attached = DDS.ConditionSeq{};
        defer if (attached._release) {
            if (attached._buffer) |b| alloc.free(b[0..attached._maximum]);
        };
        if (ws.get_conditions(&attached) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: WaitSet.get_conditions() failed\n", .{});
            std.process.exit(1);
        }
        if (attached._length != 4) {
            std.debug.print("FAIL: WaitSet.get_conditions() returned {d} conditions, expected 4\n", .{attached._length});
            std.process.exit(1);
        }
    }

    var watchdog = Watchdog{ .gc = gc, .io = io, .deadline_ns = monoNs(io) + OVERALL_DEADLINE_NS };
    const watchdog_thread = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});

    // ── Main loop: wait, branch on which conditions triggered ───────────────

    var received: i32 = 0;
    var matched_logged = false;
    while (received < EXPECTED_SAMPLES) {
        var active = DDS.ConditionSeq{};
        const wr = ws.wait(&active, WAIT_STEP);
        defer if (active._release) {
            if (active._buffer) |b| alloc.free(b[0..active._maximum]);
        };
        if (wr == DDS.RETCODE_TIMEOUT) continue;
        if (wr != DDS.RETCODE_OK) {
            std.debug.print("FAIL: WaitSet.wait() returned {d}\n", .{wr});
            std.process.exit(1);
        }
        if (conditionsContain(active, guardAsCondition(gc))) {
            std.debug.print("FAIL: watchdog fired -- only received {d}/{d} samples\n", .{ received, EXPECTED_SAMPLES });
            std.process.exit(1);
        }
        if (!matched_logged and conditionsContain(active, statusAsCondition(sc))) {
            var status: DDS.SubscriptionMatchedStatus = undefined;
            _ = dr.get_subscription_matched_status(&status);
            if (status.current_count > 0) {
                std.debug.print("Subscriber: writer matched\n", .{});
                matched_logged = true;
            }
        }

        const query_triggered = conditionsContain(active, queryAsCondition(qc));
        const read_triggered = conditionsContain(active, readAsCondition(rc));
        if (!query_triggered and !read_triggered) continue;

        // Drain the high-priority subset first via the generated
        // take_w_condition, then whatever's left via a plain take. These are
        // two separate calls, each independently locking/unlocking the
        // reader -- a sample can arrive (from the RTPS receive thread) in the
        // gap between them, missing the first (query) take and getting swept
        // up by the second (unfiltered) one. Confirmed as a real,
        // reproducible race, not just in theory: seen both locally and in CI
        // as a high-priority sample occasionally printed as "low-priority"
        // (still correctly *received*, just mislabeled) despite
        // take_w_condition's own filtering being correct at the instant it
        // ran. So: still call both -- take_w_condition is still genuinely
        // exercised, and still does the real draining -- but decide the
        // *label* from each sample's own already-deserialized `priority`
        // field rather than trusting which bucket it happened to land in.
        var high: std.ArrayListUnmanaged(sample_gen.WaitsetSampleDataReader.SampledValue) = .empty;
        defer high.deinit(alloc);
        _ = try typed_dr.take_w_condition(&high, qc.vtable.as_ReadCondition(qc.ptr), -1);

        var low: std.ArrayListUnmanaged(sample_gen.WaitsetSampleDataReader.SampledValue) = .empty;
        defer low.deinit(alloc);
        _ = try typed_dr.take(&low, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);

        for (high.items) |sv| {
            if (sv.value.priority > 4) {
                std.debug.print("Subscriber: high-priority count={d} priority={d}\n", .{ sv.value.count, sv.value.priority });
            } else {
                std.debug.print("Subscriber: low-priority count={d} priority={d}\n", .{ sv.value.count, sv.value.priority });
            }
            received += 1;
        }
        for (low.items) |sv| {
            if (sv.value.priority > 4) {
                std.debug.print("Subscriber: high-priority count={d} priority={d}\n", .{ sv.value.count, sv.value.priority });
            } else {
                std.debug.print("Subscriber: low-priority count={d} priority={d}\n", .{ sv.value.count, sv.value.priority });
            }
            received += 1;
        }
    }

    std.debug.print("Subscriber: received all {d} samples.\n", .{EXPECTED_SAMPLES});

    watchdog.stop.store(true, .release);
    watchdog_thread.join();

    // Well-behaved cleanup: detach and delete every condition explicitly
    // before tearing the reader down (contrast with publisher.zig, which
    // deliberately does *not* do this for its StatusCondition -- see its own
    // comment for why both are legitimate, safe patterns).
    _ = ws.detach_condition(statusAsCondition(sc));
    _ = ws.detach_condition(readAsCondition(rc));
    _ = ws.detach_condition(queryAsCondition(qc));
    _ = ws.detach_condition(guardAsCondition(gc));
    _ = dr.delete_readcondition(rc);
    _ = dr.delete_readcondition(qc.vtable.as_ReadCondition(qc.ptr));
    _ = subscriber.delete_datareader(dr);

    std.debug.print("Subscriber: done.\n", .{});
}
