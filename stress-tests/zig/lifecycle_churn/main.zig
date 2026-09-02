//! stress-tests/zig/lifecycle_churn -- in-process, N-thread entity /
//! listener / lifecycle churn. Generalizes the single hand-built scenario
//! in zzdds/test/dcps/participant_vtable_test.zig ("reentrant
//! delete_participant from a timer-driven listener") into a load test.
//!
//! `DebugAllocator` is *the* allocator: any leak / double-free / UAF in
//! churned teardown fails the process at exit. Runs standalone; run.py
//! sweeps scenarios and (in CI) also builds it once under
//! `-Dsanitize-thread` for the data-race lane.
//!
//! Scenarios:
//!   entities   -- N threads create -> use -> delete DataWriter/DataReader/
//!                 Publisher/Subscriber on a shared participant while SEDP
//!                 matching is active, for --duration seconds.
//!   reentrant  -- N threads, --iterations each: stand up participant +
//!                 publisher + datawriter whose DEADLINE listener (fired
//!                 from the participant's own timer thread) reentrantly
//!                 deletes the whole graph including the participant.
//!   waitset    -- one shared reader + WaitSet; a waiter thread parked in
//!                 wait(), a waker thread flipping a GuardCondition, and N
//!                 threads creating/attaching/detaching/deleting Read- and
//!                 QueryConditions on that WaitSet for --duration seconds.
//!   listener   -- listeners installed at participant + publisher +
//!                 subscriber level (the full DDS 1.4 s2.2.4.1.5 fallback
//!                 chain); N threads create a DataWriter+DataReader with
//!                 their own listeners, swap those listeners (incl. to
//!                 null), write, then delete both while matched/removed
//!                 events are still in flight -- the load regression for
//!                 the #77 discovery/teardown UAF fix.
//!   cft        -- a writer streams samples across a range of `count`; N
//!                 threads churn ContentFilteredTopic + reader lifecycle
//!                 (unique names) while also hammering
//!                 set_expression_parameters() on one shared long-lived
//!                 CFT whose reader is being drained concurrently -- the
//!                 runtime CFT-reconfiguration path the API audit flags as
//!                 untested.
//!   participants -- N threads each stand up a whole participant (factory ->
//!                 participant -> pub+writer or sub+reader, listeners at
//!                 every level), exchange a few samples on one shared
//!                 domain, then delete the participant while peers are
//!                 still (un)matching. Concurrent SPDP/SEDP join/leave with
//!                 writer/reader fan-in/fan-out, and the participant level
//!                 of the s2.2.4.1.5 fallback chain under teardown.
//!   instance   -- one shared writer + reader; N threads churn
//!                 register_instance / write / dispose / unregister_instance
//!                 / get_key_value / lookup_instance across a small keyspace
//!                 while a drainer empties the reader.
//!
//! Ends with `SUMMARY: OK scenario=<s> ops=<n>` or a `FAIL:`/panic + exit 1.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const gen = @import("messenger_gen");

const TYPE_NAME = "Message";

fn sleepMs(io: std.Io, ms: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ms * std.time.ns_per_ms) }, .clock = .awake }).sleep(io) catch {};
}
fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

const Scenario = enum { entities, reentrant, waitset, listener, cft, participants, instance };

// zidl's Zig backend emits only the `as_{Base}` vtable slot, not a
// convenience wrapper method (see examples/zig/waitset/subscriber.zig).
fn gcAsCond(gc: DDS.GuardCondition) DDS.Condition {
    return gc.vtable.as_Condition(gc.ptr);
}
fn rcAsCond(rc: DDS.ReadCondition) DDS.Condition {
    return rc.vtable.as_Condition(rc.ptr);
}
fn qcAsRc(qc: DDS.QueryCondition) DDS.ReadCondition {
    return qc.vtable.as_ReadCondition(qc.ptr);
}

const Config = struct {
    scenario: Scenario,
    threads: u32 = 6,
    iterations: u32 = 40,
    duration_s: u32 = 8,
    domain: u32 = 71,
    seed: u64 = 0,
};

fn usage() noreturn {
    std.debug.print(
        \\usage: churn_stress --scenario entities|reentrant|waitset|listener|cft|participants|instance [options]
        \\  --threads N       concurrent churn threads (default 6)
        \\  --iterations N    reentrant: cycles per thread (default 40)
        \\  --duration N      entities/waitset/listener/cft/participants/instance: seconds (default 8)
        \\  --domain N        DDS domain id (default 71)
        \\  --seed N          RNG seed
        \\
    , .{});
    std.process.exit(2);
}

fn parseArgs(raw: std.process.Args) Config {
    var it = std.process.Args.Iterator.init(raw);
    _ = it.skip();
    var scenario: ?Scenario = null;
    var cfg = Config{ .scenario = undefined };
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--scenario")) {
            const v = it.next() orelse usage();
            scenario = if (std.mem.eql(u8, v, "entities")) .entities else if (std.mem.eql(u8, v, "reentrant")) .reentrant else if (std.mem.eql(u8, v, "waitset")) .waitset else if (std.mem.eql(u8, v, "listener")) .listener else if (std.mem.eql(u8, v, "cft")) .cft else if (std.mem.eql(u8, v, "participants")) .participants else if (std.mem.eql(u8, v, "instance")) .instance else usage();
        } else if (std.mem.eql(u8, a, "--threads")) {
            cfg.threads = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--iterations")) {
            cfg.iterations = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--duration")) {
            cfg.duration_s = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--domain")) {
            cfg.domain = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--seed")) {
            cfg.seed = std.fmt.parseInt(u64, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
        } else {
            std.debug.print("FAIL: unknown argument '{s}'\n", .{a});
            usage();
        }
    }
    cfg.scenario = scenario orelse usage();
    return cfg;
}

var g_alloc: std.mem.Allocator = undefined;
var g_ts_alloc: std.mem.Allocator = undefined;
var g_ops = std.atomic.Value(u64).init(0);
var g_fail = std.atomic.Value(bool).init(false);

fn fail(comptime msg: []const u8) void {
    std.debug.print("FAIL: " ++ msg ++ "\n", .{});
    g_fail.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("FAIL: DebugAllocator detected a leak at exit\n", .{});
            std.process.exit(1);
        }
    }
    g_alloc = gpa.allocator();
    g_ts_alloc = g_alloc;

    const cfg = parseArgs(init.minimal.args);

    switch (cfg.scenario) {
        .entities => try runEntities(io, cfg),
        .reentrant => try runReentrant(io, cfg),
        .waitset => try runWaitset(io, cfg),
        .listener => try runListener(io, cfg),
        .cft => try runCft(io, cfg),
        .participants => try runParticipants(io, cfg),
        .instance => try runInstance(io, cfg),
    }

    if (g_fail.load(.acquire)) std.process.exit(1);
    std.debug.print("SUMMARY: OK scenario={s} ops={d}\n", .{ @tagName(cfg.scenario), g_ops.load(.monotonic) });
}

// ── scenario: entities ─────────────────────────────────────────────────────
//
// One shared participant + topic. N threads each spin create -> delete of a
// Publisher+DataWriter or Subscriber+DataReader while the others do the
// same, so SEDP is continuously (un)matching. A leak or UAF in any teardown
// path shows up as a DebugAllocator failure or a crash.

const EntitiesCtx = struct {
    io: std.Io,
    dp: DDS.DomainParticipant,
    topic: DDS.Topic,
    td: DDS.TopicDescription,
    deadline_ns: i64,
    idx: u32,
};

fn entitiesThread(ctx: EntitiesCtx) void {
    var local: u64 = 0;
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        if (ctx.idx % 2 == 0) {
            const p = ctx.dp.create_publisher(.{}, null, 0);
            if (p.ptr == zzdds.dcps.NIL_PTR) {
                fail("create_publisher returned nil under churn");
                return;
            }
            var qos = DDS.DataWriterQos{};
            qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
            const w = p.create_datawriter(ctx.topic, qos, null, 0);
            if (w.ptr != zzdds.dcps.NIL_PTR) _ = p.delete_datawriter(w);
            _ = ctx.dp.delete_publisher(p);
        } else {
            const sub = ctx.dp.create_subscriber(.{}, null, 0);
            if (sub.ptr == zzdds.dcps.NIL_PTR) {
                fail("create_subscriber returned nil under churn");
                return;
            }
            var qos = DDS.DataReaderQos{};
            qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
            const r = sub.create_datareader(ctx.td, qos, null, 0);
            if (r.ptr != zzdds.dcps.NIL_PTR) _ = sub.delete_datareader(r);
            _ = ctx.dp.delete_subscriber(sub);
        }
        local += 1;
        sleepMs(ctx.io, 1);
    }
    _ = g_ops.fetchAdd(local, .monotonic);
}

fn runEntities(io: std.Io, cfg: Config) !void {
    var factory = zzdds.createFactory() catch {
        fail("createFactory");
        return;
    };
    defer factory.deinit();
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(cfg.domain, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_participant");
        return;
    }
    defer _ = dpf.delete_participant(dp);

    if (!zzdds.registerTypeSupport(dp, TYPE_NAME, .{
        .ctx = @ptrCast(&g_ts_alloc),
        .compute_key_hash = gen.Message.computeKeyHashFromCdr,
        .has_key = gen.Message.has_key,
    })) {
        fail("registerTypeSupport");
        return;
    }

    const topic = dp.create_topic("ChurnTopic", TYPE_NAME, .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_topic");
        return;
    }
    defer _ = dp.delete_topic(topic);
    const td = dp.lookup_topicdescription("ChurnTopic");

    const deadline_ns = monoNs(io) + @as(i64, cfg.duration_s) * std.time.ns_per_s;

    const threads = try g_alloc.alloc(std.Thread, cfg.threads);
    defer g_alloc.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, entitiesThread, .{EntitiesCtx{
            .io = io,
            .dp = dp,
            .topic = topic,
            .td = td,
            .deadline_ns = deadline_ns,
            .idx = @intCast(i),
        }});
    }
    for (threads) |t| t.join();
}

// ── scenario: reentrant ────────────────────────────────────────────────────
//
// The seed test, run --threads-wide and --iterations-deep. Each cycle: a
// DEADLINE listener fired from the participant's own timer thread reentrantly
// deletes datawriter -> publisher -> topic -> participant. The teardown
// therefore runs *on the timer thread deinit() is trying to stop* -- the
// exact self-join / self-free hazard.

const ReentrantCtx = struct {
    factory: DDS.DomainParticipantFactory,
    dp: DDS.DomainParticipant,
    pub_: DDS.Publisher,
    topic: DDS.Topic,
    dw: DDS.DataWriter,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onDeadlineMissed(_: *anyopaque, _: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
    const ctx: *ReentrantCtx = @ptrCast(@alignCast(ld));
    if (!ctx.ready.load(.acquire)) return;
    if (ctx.fired.swap(true, .acq_rel)) return;
    _ = ctx.pub_.delete_datawriter(ctx.dw);
    _ = ctx.dp.delete_publisher(ctx.pub_);
    _ = ctx.dp.delete_topic(ctx.topic);
    _ = ctx.factory.delete_participant(ctx.dp);
    ctx.done.store(true, .release);
}

fn reentrantThread(io: std.Io, cfg: Config) void {
    var it: u32 = 0;
    while (it < cfg.iterations and !g_fail.load(.acquire)) : (it += 1) {
        var factory = zzdds.createFactory() catch {
            fail("reentrant: createFactory");
            return;
        };
        const dpf = factory.toDDSFactory();
        const dp = dpf.create_participant(cfg.domain, .{}, null, 0);
        if (dp.ptr == zzdds.dcps.NIL_PTR) {
            fail("reentrant: create_participant");
            factory.deinit();
            return;
        }
        const pub_ = dp.create_publisher(.{}, null, 0);
        const topic = dp.create_topic("ReentrantTopic", TYPE_NAME, .{}, null, 0);

        var ctx = ReentrantCtx{ .factory = dpf, .dp = dp, .pub_ = pub_, .topic = topic, .dw = undefined };
        var dw_qos = DDS.DataWriterQos{};
        dw_qos.deadline.period = .{ .sec = 0, .nanosec = 50_000_000 }; // 50ms
        const dw = pub_.create_datawriter(topic, dw_qos, DDS.DataWriterListener{
            .listener_data = &ctx,
            .on_offered_deadline_missed = onDeadlineMissed,
        }, DDS.OFFERED_DEADLINE_MISSED_STATUS);
        ctx.dw = dw;
        ctx.ready.store(true, .release);

        const deadline = monoNs(io) + 5 * std.time.ns_per_s;
        while (!ctx.done.load(.acquire)) {
            if (monoNs(io) >= deadline) {
                fail("reentrant: listener never fired within 5s (self-join deadlock?)");
                return;
            }
            sleepMs(io, 10);
        }
        // The detached timer thread still has a little unwinding + its own
        // alloc.destroy(self) to do after ctx.done flips; give it room so
        // the next iteration doesn't race it on the shared DebugAllocator.
        // Generous, not tight.
        sleepMs(io, 50);
        // The listener deleted the participant; this destroys the now-empty
        // FactoryOwner. (In the seed unit test this is `defer factory.deinit()`.)
        factory.deinit();
        _ = g_ops.fetchAdd(1, .monotonic);
    }
}

fn runReentrant(io: std.Io, cfg: Config) !void {
    const threads = try g_alloc.alloc(std.Thread, cfg.threads);
    defer g_alloc.free(threads);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, reentrantThread, .{ io, cfg });
    for (threads) |t| t.join();
}

// ── scenario: waitset ──────────────────────────────────────────────────────
//
// One shared reader + WaitSet + a long-lived GuardCondition. A `waiter`
// thread is parked in ws.wait() for the whole run; a `waker` thread flips
// the GuardCondition's trigger to keep pulling it out of wait(); N churn
// threads create ReadCondition / QueryCondition on the shared reader, then
// attach_condition -> (brief) -> detach_condition -> delete_readcondition,
// hammering the WaitSet's attached-condition list concurrently with
// wait() and get_conditions(). Every 16th cycle a churn thread deletes a
// condition *without* detaching it first -- the dangling-attached-condition
// hazard the zig/waitset example's publisher comment calls out; the WaitSet
// must not later dereference the freed condition from wait() or deinit().

const WaitsetCtx = struct {
    io: std.Io,
    ws: DDS.WaitSet,
    dr: DDS.DataReader,
    guard: DDS.GuardCondition,
    deadline_ns: i64,
    idx: u32,
};

fn freeCondSeq(seq: *DDS.ConditionSeq) void {
    if (seq._release) {
        if (seq._buffer) |b| g_alloc.free(b[0..seq._maximum]);
    }
}

fn waitsetWaiter(ctx: WaitsetCtx) void {
    const step: DDS.Duration_t = .{ .sec = 0, .nanosec = 50 * std.time.ns_per_ms };
    var local: u64 = 0;
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        var active = DDS.ConditionSeq{};
        const wr = ctx.ws.wait(&active, step);
        freeCondSeq(&active);
        if (wr != DDS.RETCODE_OK and wr != DDS.RETCODE_TIMEOUT) {
            fail("waitset: wait() returned an unexpected retcode");
            return;
        }
        local += 1;
    }
    _ = g_ops.fetchAdd(local, .monotonic);
}

fn waitsetWaker(ctx: WaitsetCtx) void {
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        _ = ctx.guard.set_trigger_value(true);
        sleepMs(ctx.io, 2);
        _ = ctx.guard.set_trigger_value(false);
        sleepMs(ctx.io, 2);
    }
}

fn waitsetChurn(ctx: WaitsetCtx) void {
    var local: u64 = 0;
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        // Alternate ReadCondition / QueryCondition. `rc_handle` is what
        // delete_readcondition takes for both (a QueryCondition is deleted
        // via its ReadCondition view).
        var rc_handle: DDS.ReadCondition = undefined;
        if (local % 2 == 0) {
            var params = [_][*:0]const u8{"5"};
            var params_seq = DDS.StringSeq{ ._buffer = &params, ._length = 1, ._maximum = 1, ._release = false };
            const qc = ctx.dr.create_querycondition(
                DDS.ANY_SAMPLE_STATE,
                DDS.ANY_VIEW_STATE,
                DDS.ANY_INSTANCE_STATE,
                "count > %0",
                &params_seq,
            );
            if (qc.ptr == zzdds.dcps.NIL_PTR) {
                fail("waitset: create_querycondition returned nil under churn");
                return;
            }
            rc_handle = qcAsRc(qc);
        } else {
            const rc = ctx.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
            if (rc.ptr == zzdds.dcps.NIL_PTR) {
                fail("waitset: create_readcondition returned nil under churn");
                return;
            }
            rc_handle = rc;
        }
        const cond = rcAsCond(rc_handle);

        _ = ctx.ws.attach_condition(cond);

        // Snapshot the attached set concurrently with everyone else's
        // attach/detach -- exercises get_conditions()'s locking, not its
        // contents (which are racing by construction).
        if (local % 8 == 0) {
            var attached = DDS.ConditionSeq{};
            _ = ctx.ws.get_conditions(&attached);
            freeCondSeq(&attached);
        }

        sleepMs(ctx.io, 1);

        // 1-in-16: delete while still attached (see the scenario comment).
        if (local % 16 != 15) _ = ctx.ws.detach_condition(cond);
        _ = ctx.dr.delete_readcondition(rc_handle);
        local += 1;
    }
    _ = g_ops.fetchAdd(local, .monotonic);
}

fn runWaitset(io: std.Io, cfg: Config) !void {
    var factory = zzdds.createFactory() catch {
        fail("createFactory");
        return;
    };
    defer factory.deinit();
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(cfg.domain, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_participant");
        return;
    }
    defer _ = dpf.delete_participant(dp);

    if (!zzdds.registerTypeSupport(dp, TYPE_NAME, .{
        .ctx = @ptrCast(&g_ts_alloc),
        .compute_key_hash = gen.Message.computeKeyHashFromCdr,
        .has_key = gen.Message.has_key,
        .get_field = gen.Message.getFieldFromCdr,
    })) {
        fail("registerTypeSupport");
        return;
    }

    const topic = dp.create_topic("WsChurnTopic", TYPE_NAME, .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_topic");
        return;
    }
    defer _ = dp.delete_topic(topic);
    const td = dp.lookup_topicdescription("WsChurnTopic");

    const sub = dp.create_subscriber(.{}, null, 0);
    if (sub.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_subscriber");
        return;
    }
    defer _ = dp.delete_subscriber(sub);

    const dr = sub.create_datareader(td, .{}, null, 0);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_datareader");
        return;
    }
    defer _ = sub.delete_datareader(dr);

    const ws = zzdds.createWaitSet(g_alloc) catch {
        fail("createWaitSet");
        return;
    };
    defer ws.deinit();

    const guard = zzdds.createGuardCondition(g_alloc) catch {
        fail("createGuardCondition");
        return;
    };
    defer guard.deinit();
    _ = ws.attach_condition(gcAsCond(guard));

    const deadline_ns = monoNs(io) + @as(i64, cfg.duration_s) * std.time.ns_per_s;
    const base = WaitsetCtx{ .io = io, .ws = ws, .dr = dr, .guard = guard, .deadline_ns = deadline_ns, .idx = 0 };

    // [0] waiter, [1] waker, [2..] churn.
    const threads = try g_alloc.alloc(std.Thread, cfg.threads + 2);
    defer g_alloc.free(threads);
    threads[0] = try std.Thread.spawn(.{}, waitsetWaiter, .{base});
    threads[1] = try std.Thread.spawn(.{}, waitsetWaker, .{base});
    for (threads[2..], 0..) |*t, i| {
        var c = base;
        c.idx = @intCast(i);
        t.* = try std.Thread.spawn(.{}, waitsetChurn, .{c});
    }
    for (threads) |t| t.join();

    _ = ws.detach_condition(gcAsCond(guard));
}

// ── scenario: listener ─────────────────────────────────────────────────────
//
// The load regression for the #77 discovery/teardown UAF fix. Listeners are
// installed at every level of the DDS 1.4 s2.2.4.1.5 fallback chain
// (participant, publisher, subscriber) and left there for the whole run, so
// every matched/removed/data event has a 2-3 level fallback to walk. N churn
// threads each: create a DataWriter (on the shared publisher) + DataReader
// (on the shared subscriber), each with its own listener; swap those
// listeners a couple of times including to `null` (the ListenerBox
// replacement path); write a few samples; then delete both entities while
// SEDP is still (un)matching them -- so `on_publication_matched` /
// `on_subscription_matched` / `on_data_available` fire from the participant's
// receive/timer threads against an entity another thread is tearing down,
// falling through to a parent that is deliberately kept alive.
//
// Callbacks only bump global atomics -- no per-entity ctx to dangle. The
// point here is the fallback walk + ListenerBox refcount under contention,
// not ctx lifetime (that is `entities`).

var g_cb_pub_matched = std.atomic.Value(u64).init(0);
var g_cb_sub_matched = std.atomic.Value(u64).init(0);
var g_cb_data = std.atomic.Value(u64).init(0);

fn cbPubMatched(_: *anyopaque, _: *const DDS.PublicationMatchedStatus, _: ?*anyopaque) callconv(.c) void {
    _ = g_cb_pub_matched.fetchAdd(1, .monotonic);
}
fn cbSubMatched(_: *anyopaque, _: *const DDS.SubscriptionMatchedStatus, _: ?*anyopaque) callconv(.c) void {
    _ = g_cb_sub_matched.fetchAdd(1, .monotonic);
}
fn cbDataAvail(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    _ = g_cb_data.fetchAdd(1, .monotonic);
}

const ListenerCtx = struct {
    io: std.Io,
    pub_: DDS.Publisher,
    sub: DDS.Subscriber,
    topic: DDS.Topic,
    td: DDS.TopicDescription,
    deadline_ns: i64,
    idx: u32,
};

fn dwListener() DDS.DataWriterListener {
    return .{ .on_publication_matched = cbPubMatched };
}
fn drListener() DDS.DataReaderListener {
    return .{ .on_subscription_matched = cbSubMatched, .on_data_available = cbDataAvail };
}

fn listenerChurn(ctx: ListenerCtx) void {
    var local: u64 = 0;
    const DW_MASK = DDS.PUBLICATION_MATCHED_STATUS;
    const DR_MASK = DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.DATA_AVAILABLE_STATUS;
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        var w_qos = DDS.DataWriterQos{};
        w_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
        const w = ctx.pub_.create_datawriter(ctx.topic, w_qos, dwListener(), DW_MASK);
        if (w.ptr == zzdds.dcps.NIL_PTR) {
            fail("listener: create_datawriter returned nil under churn");
            return;
        }
        var r_qos = DDS.DataReaderQos{};
        r_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
        const r = ctx.sub.create_datareader(ctx.td, r_qos, drListener(), DR_MASK);
        if (r.ptr == zzdds.dcps.NIL_PTR) {
            fail("listener: create_datareader returned nil under churn");
            _ = ctx.pub_.delete_datawriter(w);
            return;
        }

        // ListenerBox replacement: install -> replace -> clear, on both
        // sides, while matched events for this pair are in flight.
        _ = w.set_listener(dwListener(), DW_MASK);
        _ = r.set_listener(drListener(), DR_MASK);
        _ = w.set_listener(null, 0);
        _ = r.set_listener(null, 0);

        // A few writes so on_data_available has something to deliver
        // (races teardown -- most will land after the reader is gone).
        const writer = gen.MessageDataWriter.init(w, g_alloc);
        var msg = gen.Message{ .subject_id = @intCast(ctx.idx + 1), .count = 0 };
        const handle = writer.register_instance(msg);
        var s: u32 = 0;
        while (s < 3) : (s += 1) {
            msg.count += 1;
            writer.write(msg, handle) catch break;
        }

        // Alternate teardown order so both fallback directions are hit:
        // reader-first leaves the writer to take on_publication_matched(-1)
        // (writer -> publisher -> participant); writer-first is the mirror.
        if (local % 2 == 0) {
            _ = ctx.sub.delete_datareader(r);
            _ = ctx.pub_.delete_datawriter(w);
        } else {
            _ = ctx.pub_.delete_datawriter(w);
            _ = ctx.sub.delete_datareader(r);
        }
        local += 1;
    }
    _ = g_ops.fetchAdd(local, .monotonic);
}

fn runListener(io: std.Io, cfg: Config) !void {
    var factory = zzdds.createFactory() catch {
        fail("createFactory");
        return;
    };
    defer factory.deinit();
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(cfg.domain, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_participant");
        return;
    }
    defer _ = dpf.delete_participant(dp);

    // Participant-level listener: the bottom of the fallback chain, always
    // present.
    _ = dp.set_listener(DDS.DomainParticipantListener{
        .on_publication_matched = cbPubMatched,
        .on_subscription_matched = cbSubMatched,
        .on_data_available = cbDataAvail,
    }, DDS.PUBLICATION_MATCHED_STATUS | DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.DATA_AVAILABLE_STATUS);

    if (!zzdds.registerTypeSupport(dp, TYPE_NAME, .{
        .ctx = @ptrCast(&g_ts_alloc),
        .compute_key_hash = gen.Message.computeKeyHashFromCdr,
        .has_key = gen.Message.has_key,
    })) {
        fail("registerTypeSupport");
        return;
    }

    const topic = dp.create_topic("LsnChurnTopic", TYPE_NAME, .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_topic");
        return;
    }
    defer _ = dp.delete_topic(topic);
    const td = dp.lookup_topicdescription("LsnChurnTopic");

    // Mid-chain listeners: publisher and subscriber, also always present.
    const pub_ = dp.create_publisher(.{}, DDS.PublisherListener{
        .on_publication_matched = cbPubMatched,
    }, DDS.PUBLICATION_MATCHED_STATUS);
    if (pub_.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_publisher");
        return;
    }
    defer _ = dp.delete_publisher(pub_);

    const sub = dp.create_subscriber(.{}, DDS.SubscriberListener{
        .on_subscription_matched = cbSubMatched,
        .on_data_available = cbDataAvail,
    }, DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.DATA_AVAILABLE_STATUS);
    if (sub.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_subscriber");
        return;
    }
    defer _ = dp.delete_subscriber(sub);

    const deadline_ns = monoNs(io) + @as(i64, cfg.duration_s) * std.time.ns_per_s;
    const base = ListenerCtx{ .io = io, .pub_ = pub_, .sub = sub, .topic = topic, .td = td, .deadline_ns = deadline_ns, .idx = 0 };

    const threads = try g_alloc.alloc(std.Thread, cfg.threads);
    defer g_alloc.free(threads);
    for (threads, 0..) |*t, i| {
        var c = base;
        c.idx = @intCast(i);
        t.* = try std.Thread.spawn(.{}, listenerChurn, .{c});
    }
    for (threads) |t| t.join();

    // Sanity: if not a single matched callback fired, the scenario built the
    // graph but never actually exercised event delivery -- treat that as a
    // failure, not a silent pass.
    if (g_cb_pub_matched.load(.monotonic) + g_cb_sub_matched.load(.monotonic) == 0) {
        fail("listener: no matched callbacks ever fired -- delivery not exercised");
    }
}

// ── scenario: cft ──────────────────────────────────────────────────────────
//
// The API audit calls runtime `set_expression_parameters` "fully untested,
// and CFT has an established bug". Here: a writer streams `Message` samples
// with `count` sweeping 0..99 so a "count > N" filter genuinely re-evaluates
// as N moves. One shared long-lived CFT (`g_cft`) + reader is drained by a
// dedicated thread while N churn threads both (a) rotate `g_cft`'s parameter
// through a small set via set_expression_parameters, and (b) create/use/
// delete their own uniquely-named CFT + reader. DebugAllocator catches any
// leak/UAF in the param-vector swap or the CFT/reader teardown cascade.

const CFT_THRESHOLDS = [_][*:0]const u8{ "0", "25", "50", "75", "90" };

const CftCtx = struct {
    io: std.Io,
    dp: DDS.DomainParticipant,
    sub: DDS.Subscriber,
    topic: DDS.Topic,
    g_cft: DDS.ContentFilteredTopic,
    g_dr: DDS.DataReader,
    deadline_ns: i64,
    idx: u32,
};

fn cftWriter(ctx: CftCtx, dw: DDS.DataWriter) void {
    const writer = gen.MessageDataWriter.init(dw, g_alloc);
    var msg = gen.Message{ .subject_id = 1, .count = 0 };
    const handle = writer.register_instance(msg);
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        msg.count = @mod(msg.count + 1, 100);
        writer.write(msg, handle) catch {};
        sleepMs(ctx.io, 2);
    }
}

fn cftDrainer(ctx: CftCtx) void {
    var reader = gen.MessageDataReader.init(ctx.g_dr, g_alloc);
    var local: u64 = 0;
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        while (true) {
            var value: gen.Message = .{};
            var info: DDS.SampleInfo = .{};
            const got = reader.take_next_sample(&value, &info) catch break;
            if (!got) break;
            local += 1;
        }
        sleepMs(ctx.io, 1);
    }
    _ = g_ops.fetchAdd(local, .monotonic);
}

fn cftChurn(ctx: CftCtx) void {
    var local: u64 = 0;
    var name_buf: [48]u8 = undefined;
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        // (a) rotate the shared CFT's parameter -- the runtime
        // reconfiguration path.
        {
            var p = [_][*:0]const u8{CFT_THRESHOLDS[local % CFT_THRESHOLDS.len]};
            var seq = DDS.StringSeq{ ._buffer = &p, ._length = 1, ._maximum = 1, ._release = false };
            _ = ctx.g_cft.set_expression_parameters(&seq);
        }

        // (b) full CFT + reader lifecycle, uniquely named.
        const name = std.fmt.bufPrintZ(&name_buf, "cft_{d}_{d}", .{ ctx.idx, local }) catch {
            fail("cft: name format");
            return;
        };
        var p0 = [_][*:0]const u8{CFT_THRESHOLDS[(local + 1) % CFT_THRESHOLDS.len]};
        var seq0 = DDS.StringSeq{ ._buffer = &p0, ._length = 1, ._maximum = 1, ._release = false };
        const cft = ctx.dp.create_contentfilteredtopic(name, ctx.topic, "count > %0", &seq0);
        if (cft.ptr == zzdds.dcps.NIL_PTR) {
            fail("cft: create_contentfilteredtopic returned nil under churn");
            return;
        }
        const dr = ctx.sub.create_datareader(cft.as_TopicDescription(), .{}, null, 0);
        if (dr.ptr != zzdds.dcps.NIL_PTR) {
            var reader = gen.MessageDataReader.init(dr, g_alloc);
            var drained: u32 = 0;
            while (drained < 8) : (drained += 1) {
                var value: gen.Message = .{};
                var info: DDS.SampleInfo = .{};
                const got = reader.take_next_sample(&value, &info) catch break;
                if (!got) break;
            }
            _ = ctx.sub.delete_datareader(dr);
        }
        _ = ctx.dp.delete_contentfilteredtopic(cft);
        local += 1;
    }
    _ = g_ops.fetchAdd(local, .monotonic);
}

fn runCft(io: std.Io, cfg: Config) !void {
    var factory = zzdds.createFactory() catch {
        fail("createFactory");
        return;
    };
    defer factory.deinit();
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(cfg.domain, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_participant");
        return;
    }
    defer _ = dpf.delete_participant(dp);

    if (!zzdds.registerTypeSupport(dp, TYPE_NAME, .{
        .ctx = @ptrCast(&g_ts_alloc),
        .compute_key_hash = gen.Message.computeKeyHashFromCdr,
        .has_key = gen.Message.has_key,
        .get_field = gen.Message.getFieldFromCdr,
    })) {
        fail("registerTypeSupport");
        return;
    }

    const topic = dp.create_topic("CftChurnTopic", TYPE_NAME, .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_topic");
        return;
    }
    defer _ = dp.delete_topic(topic);

    const pub_ = dp.create_publisher(.{}, null, 0);
    if (pub_.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_publisher");
        return;
    }
    defer _ = dp.delete_publisher(pub_);
    var w_qos = DDS.DataWriterQos{};
    w_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dw = pub_.create_datawriter(topic, w_qos, null, 0);
    if (dw.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_datawriter");
        return;
    }
    defer _ = pub_.delete_datawriter(dw);

    const sub = dp.create_subscriber(.{}, null, 0);
    if (sub.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_subscriber");
        return;
    }
    defer _ = dp.delete_subscriber(sub);

    // The shared, long-lived CFT + reader the churn threads reconfigure and
    // the drainer thread empties.
    var gp = [_][*:0]const u8{"50"};
    var gseq = DDS.StringSeq{ ._buffer = &gp, ._length = 1, ._maximum = 1, ._release = false };
    const g_cft = dp.create_contentfilteredtopic("CftShared", topic, "count > %0", &gseq);
    if (g_cft.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_contentfilteredtopic (shared)");
        return;
    }
    const g_dr = sub.create_datareader(g_cft.as_TopicDescription(), .{}, null, 0);
    if (g_dr.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_datareader (shared CFT)");
        _ = dp.delete_contentfilteredtopic(g_cft);
        return;
    }

    const deadline_ns = monoNs(io) + @as(i64, cfg.duration_s) * std.time.ns_per_s;
    const base = CftCtx{
        .io = io,
        .dp = dp,
        .sub = sub,
        .topic = topic,
        .g_cft = g_cft,
        .g_dr = g_dr,
        .deadline_ns = deadline_ns,
        .idx = 0,
    };

    // [0] writer, [1] drainer, [2..] churn.
    const threads = try g_alloc.alloc(std.Thread, cfg.threads + 2);
    defer g_alloc.free(threads);
    threads[0] = try std.Thread.spawn(.{}, cftWriter, .{ base, dw });
    threads[1] = try std.Thread.spawn(.{}, cftDrainer, .{base});
    for (threads[2..], 0..) |*t, i| {
        var c = base;
        c.idx = @intCast(i);
        t.* = try std.Thread.spawn(.{}, cftChurn, .{c});
    }
    for (threads) |t| t.join();

    // Ordered teardown of the shared pair (reader before its CFT).
    _ = sub.delete_datareader(g_dr);
    _ = dp.delete_contentfilteredtopic(g_cft);
}

// ── scenario: participants ─────────────────────────────────────────────────
//
// Covers two API-audit stress items at once: "many-participant SPDP/SEDP
// fan-in/fan-out" and "participant-churning listener-fallback". N threads
// each run a full participant lifecycle on one shared domain -- factory ->
// participant (with a participant-level listener) -> registerTypeSupport ->
// topic -> either publisher+writer or subscriber+reader (listeners at those
// levels too) -> a few sample exchanges -> delete_participant ->
// factory.deinit(). Because every thread is on the same domain, at any
// instant there are ~N participants concurrently joining, matching and
// leaving, with writers fanning out to multiple readers and readers fanning
// in from multiple writers. Deleting a participant while its peers are still
// matched drives matched/removed events onto entities whose whole graph --
// participant included -- is tearing down, exercising the participant level
// of the s2.2.4.1.5 fallback chain that the `listener` scenario (stable
// participant) can't reach.

const ParticipantsCtx = struct {
    io: std.Io,
    domain: u32,
    deadline_ns: i64,
    idx: u32,
};

fn participantsThread(ctx: ParticipantsCtx) void {
    var local: u64 = 0;
    const is_writer = ctx.idx % 2 == 0;
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        var factory = zzdds.createFactory() catch {
            fail("participants: createFactory");
            return;
        };
        const dpf = factory.toDDSFactory();
        const dp = dpf.create_participant(ctx.domain, .{}, null, 0);
        if (dp.ptr == zzdds.dcps.NIL_PTR) {
            fail("participants: create_participant returned nil under churn");
            factory.deinit();
            return;
        }

        _ = dp.set_listener(DDS.DomainParticipantListener{
            .on_publication_matched = cbPubMatched,
            .on_subscription_matched = cbSubMatched,
            .on_data_available = cbDataAvail,
        }, DDS.PUBLICATION_MATCHED_STATUS | DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.DATA_AVAILABLE_STATUS);

        if (!zzdds.registerTypeSupport(dp, TYPE_NAME, .{
            .ctx = @ptrCast(&g_ts_alloc),
            .compute_key_hash = gen.Message.computeKeyHashFromCdr,
            .has_key = gen.Message.has_key,
        })) {
            fail("participants: registerTypeSupport");
            _ = dpf.delete_participant(dp);
            factory.deinit();
            return;
        }

        const topic = dp.create_topic("PartChurnTopic", TYPE_NAME, .{}, null, 0);
        if (topic.ptr == zzdds.dcps.NIL_PTR) {
            fail("participants: create_topic");
            _ = dpf.delete_participant(dp);
            factory.deinit();
            return;
        }

        if (is_writer) {
            const p = dp.create_publisher(.{}, DDS.PublisherListener{ .on_publication_matched = cbPubMatched }, DDS.PUBLICATION_MATCHED_STATUS);
            if (p.ptr != zzdds.dcps.NIL_PTR) {
                var qos = DDS.DataWriterQos{};
                qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
                const w = p.create_datawriter(topic, qos, DDS.DataWriterListener{ .on_publication_matched = cbPubMatched }, DDS.PUBLICATION_MATCHED_STATUS);
                if (w.ptr != zzdds.dcps.NIL_PTR) {
                    const writer = gen.MessageDataWriter.init(w, g_alloc);
                    var msg = gen.Message{ .subject_id = @intCast(ctx.idx + 1), .count = 0 };
                    const handle = writer.register_instance(msg);
                    var s: u32 = 0;
                    while (s < 5) : (s += 1) {
                        msg.count += 1;
                        writer.write(msg, handle) catch break;
                        sleepMs(ctx.io, 2);
                    }
                }
            }
        } else {
            const s = dp.create_subscriber(.{}, DDS.SubscriberListener{
                .on_subscription_matched = cbSubMatched,
                .on_data_available = cbDataAvail,
            }, DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.DATA_AVAILABLE_STATUS);
            if (s.ptr != zzdds.dcps.NIL_PTR) {
                const td = dp.lookup_topicdescription("PartChurnTopic");
                var qos = DDS.DataReaderQos{};
                qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
                const r = s.create_datareader(td, qos, DDS.DataReaderListener{
                    .on_subscription_matched = cbSubMatched,
                    .on_data_available = cbDataAvail,
                }, DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.DATA_AVAILABLE_STATUS);
                if (r.ptr != zzdds.dcps.NIL_PTR) {
                    var reader = gen.MessageDataReader.init(r, g_alloc);
                    var polls: u32 = 0;
                    while (polls < 10) : (polls += 1) {
                        var value: gen.Message = .{};
                        var info: DDS.SampleInfo = .{};
                        _ = reader.take_next_sample(&value, &info) catch break;
                        sleepMs(ctx.io, 3);
                    }
                }
            }
        }

        // Tear the whole graph down via the participant -- no explicit child
        // deletes -- so delete_contained_entities runs while peers on the
        // domain are still matched to these endpoints.
        _ = dpf.delete_participant(dp);
        factory.deinit();
        local += 1;
    }
    _ = g_ops.fetchAdd(local, .monotonic);
}

fn runParticipants(io: std.Io, cfg: Config) !void {
    const deadline_ns = monoNs(io) + @as(i64, cfg.duration_s) * std.time.ns_per_s;
    const threads = try g_alloc.alloc(std.Thread, cfg.threads);
    defer g_alloc.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, participantsThread, .{ParticipantsCtx{
            .io = io,
            .domain = cfg.domain,
            .deadline_ns = deadline_ns,
            .idx = @intCast(i),
        }});
    }
    for (threads) |t| t.join();

    if (g_cb_pub_matched.load(.monotonic) + g_cb_sub_matched.load(.monotonic) == 0) {
        fail("participants: no matched callbacks ever fired -- discovery not exercised");
    }
}

// ── scenario: instance ────────────────────────────────────────────────────
//
// Each churn thread owns its own Publisher + DataWriter on a shared
// participant/topic (deliberately *not* one shared writer -- concurrent
// write() on a single DataWriter races on unprotected writer state, a
// separate zzdds gap noted in stress-tests/README.md). Every thread then
// hammers the instance-lifecycle API across a small keyspace:
// register_instance -> write x2 -> lookup_instance check -> get_key_value
// (value asserted: round-trips `Message`'s non-leading @key `subject_id`) ->
// periodically dispose / unregister_instance.
// One shared reader + drainer fans in from every writer and round-trips
// take_next_sample / get_key_value / lookup_instance on the read side.
// DebugAllocator + TSan cover the writer-side key registry, the reader-side
// per-instance tracking (view/generation state, dispose transitions), and
// the register/dispose/unregister lifecycle bookkeeping.

const INSTANCE_KEYS: i32 = 12;

const InstanceCtx = struct {
    io: std.Io,
    dp: DDS.DomainParticipant,
    topic: DDS.Topic,
    r: DDS.DataReader,
    deadline_ns: i64,
    idx: u32,
};

fn instanceChurn(ctx: InstanceCtx) void {
    const p = ctx.dp.create_publisher(.{}, null, 0);
    if (p.ptr == zzdds.dcps.NIL_PTR) {
        fail("instance: create_publisher under churn");
        return;
    }
    defer _ = ctx.dp.delete_publisher(p);
    var w_qos = DDS.DataWriterQos{};
    w_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    const w = p.create_datawriter(ctx.topic, w_qos, null, 0);
    if (w.ptr == zzdds.dcps.NIL_PTR) {
        fail("instance: create_datawriter under churn");
        return;
    }
    defer _ = p.delete_datawriter(w);
    const writer = gen.MessageDataWriter.init(w, g_alloc);

    var local: u64 = 0;
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        const key: i32 = @mod(@as(i32, @intCast(ctx.idx)) + @as(i32, @intCast(local)), INSTANCE_KEYS);
        var msg = gen.Message{ .subject_id = key, .count = @intCast(local & 0x7fff) };

        const h = writer.register_instance(msg);
        writer.write(msg, h) catch {};
        msg.count +%= 1;
        writer.write(msg, h) catch {};

        // lookup_instance is a pure hash→handle function; it must agree with
        // register_instance for the same key.
        if (writer.lookup_instance(msg) != h) {
            fail("instance: writer.lookup_instance != register_instance handle");
            return;
        }
        // get_key_value must round-trip `Message`'s @key `subject_id` -- its
        // 3rd member, the non-leading-key case that zidl's selective parse
        // (v0.3.12) fixed. The instance was just registered + written twice
        // above, so a failure here is a real bug, not an expected
        // "unregistered" error.
        var kh: gen.Message = .{};
        writer.get_key_value(&kh, h) catch {
            fail("instance: writer.get_key_value returned an error for a live instance");
            return;
        };
        if (kh.subject_id != key) {
            fail("instance: writer.get_key_value subject_id mismatch");
            return;
        }

        switch (local % 4) {
            0 => writer.dispose(msg, h) catch {},
            1 => writer.unregister_instance(msg, h) catch {},
            else => {}, // leave it registered/alive
        }
        local += 1;
    }
    _ = g_ops.fetchAdd(local, .monotonic);
}

fn instanceDrainer(ctx: InstanceCtx) void {
    var reader = gen.MessageDataReader.init(ctx.r, g_alloc);
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        while (true) {
            var value: gen.Message = .{};
            var info: DDS.SampleInfo = .{};
            const got = reader.take_next_sample(&value, &info) catch break;
            if (!got) break;
            // Gate on valid_data: an ALIVE sample has a populated `value` and a
            // live instance to look up. A dispose/unregister notification
            // (valid_data=false) may reference an instance the reader has
            // already purged, where get_key_value legitimately errors.
            if (info.valid_data and info.instance_handle != DDS.HANDLE_NIL) {
                var kh: gen.Message = .{};
                reader.get_key_value(&kh, info.instance_handle) catch {
                    fail("instance: reader.get_key_value returned an error for a live instance");
                    return;
                };
                if (kh.subject_id != value.subject_id) {
                    fail("instance: reader.get_key_value subject_id mismatch");
                    return;
                }
            }
            _ = reader.lookup_instance(value);
        }
        sleepMs(ctx.io, 1);
    }
}

fn runInstance(io: std.Io, cfg: Config) !void {
    var factory = zzdds.createFactory() catch {
        fail("createFactory");
        return;
    };
    defer factory.deinit();
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(cfg.domain, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_participant");
        return;
    }
    defer _ = dpf.delete_participant(dp);

    if (!zzdds.registerTypeSupport(dp, TYPE_NAME, .{
        .ctx = @ptrCast(&g_ts_alloc),
        .compute_key_hash = gen.Message.computeKeyHashFromCdr,
        .has_key = gen.Message.has_key,
    })) {
        fail("registerTypeSupport");
        return;
    }

    const topic = dp.create_topic("InstChurnTopic", TYPE_NAME, .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_topic");
        return;
    }
    defer _ = dp.delete_topic(topic);
    const td = dp.lookup_topicdescription("InstChurnTopic");

    const sub = dp.create_subscriber(.{}, null, 0);
    if (sub.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_subscriber");
        return;
    }
    defer _ = dp.delete_subscriber(sub);
    const r = sub.create_datareader(td, .{}, null, 0);
    if (r.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_datareader");
        return;
    }
    defer _ = sub.delete_datareader(r);

    const deadline_ns = monoNs(io) + @as(i64, cfg.duration_s) * std.time.ns_per_s;
    const base = InstanceCtx{ .io = io, .dp = dp, .topic = topic, .r = r, .deadline_ns = deadline_ns, .idx = 0 };

    // [0] drainer, [1..] churn.
    const threads = try g_alloc.alloc(std.Thread, cfg.threads + 1);
    defer g_alloc.free(threads);
    threads[0] = try std.Thread.spawn(.{}, instanceDrainer, .{base});
    for (threads[1..], 0..) |*t, i| {
        var c = base;
        c.idx = @intCast(i);
        t.* = try std.Thread.spawn(.{}, instanceChurn, .{c});
    }
    for (threads) |t| t.join();
}
