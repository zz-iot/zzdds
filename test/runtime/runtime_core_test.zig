//! Shared runtime core: take-turns contexts, ready-queue order, waits, timers,
//! the manual driver and retirement
//! (docs/design/concurrency/architecture.md#admission-and-request-state-transitions,
//! docs/design/concurrency/runtime.md#manual-runtime-driving-and-external-loop-integration).
//!
//! Manual tests use the scripted backend: a wait with a deadline advances its
//! clock instead of sleeping. Hosted tests use `std.Io.Threaded` workers and
//! finish by retiring the runtime, never by sleeping.

const std = @import("std");
const zzdds = @import("zzdds");
const rt = zzdds.runtime;

const testing = std.testing;

// ── Helpers ───────────────────────────────────────────────────────────────────

const Log = struct {
    items: [64]u32 = undefined,
    n: usize = 0,

    fn add(self: *Log, v: u32) void {
        self.items[self.n] = v;
        self.n += 1;
    }

    fn slice(self: *const Log) []const u32 {
        return self.items[0..self.n];
    }
};

/// Records its id each turn and follows a script of outcomes, then `.done`.
const Step = struct {
    req: rt.Request = rt.Request.init(run),
    id: u32,
    log: *Log,
    script: []const rt.Outcome = &.{},
    turns: usize = 0,
    token: ?rt.WaitToken = null,

    fn run(req: *rt.Request, turn: *rt.Turn) rt.Outcome {
        const self: *Step = @fieldParentPtr("req", req);
        self.log.add(self.id);
        const outcome = if (self.turns < self.script.len) self.script[self.turns] else .done;
        self.turns += 1;
        if (outcome == .wait) self.token = turn.prepareWait();
        return outcome;
    }
};

/// A manual runtime over the scripted backend. Must not move after `init`.
const Manual = struct {
    sb: rt.ScriptedBackend,
    runtime: rt.Runtime,

    fn init(self: *Manual, options: rt.Options) void {
        self.sb = rt.ScriptedBackend.init(1_000);
        self.runtime = rt.Runtime.init(self.sb.clock(), self.sb.backend(), options);
    }

    fn now(self: *Manual) i64 {
        return self.runtime.clock.nowNs();
    }

    /// Releases the creator's ownership and drives the runtime to a stop.
    fn retire(self: *Manual) !void {
        if (self.runtime.getState() == .running) self.runtime.releaseOwner();
        const r = try self.runtime.drive(1000, 0);
        try testing.expectEqual(rt.State.backend_stopped, r.state);
        self.runtime.deinit();
    }
};

// ── Order and admission ───────────────────────────────────────────────────────

test "a context runs its requests one turn at a time, oldest first" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var s1 = Step{ .id = 1, .log = &log };
    var s2 = Step{ .id = 2, .log = &log };
    var s3 = Step{ .id = 3, .log = &log };
    try m.runtime.submit(null, &ctx, &s1.req);
    try m.runtime.submit(null, &ctx, &s2.req);
    try m.runtime.submit(null, &ctx, &s3.req);
    try testing.expectEqual(@as(usize, 0), log.n);

    const r = try m.runtime.drive(10, 0);
    try testing.expectEqual(@as(u32, 3), r.turns);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, log.slice());
    ctx.deinit();
    try m.retire();
}

test "ready contexts are served round robin, one turn per claim" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var a = rt.Context.init(&m.runtime, 16);
    var b = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var a1 = Step{ .id = 11, .log = &log };
    var a2 = Step{ .id = 12, .log = &log };
    var a3 = Step{ .id = 13, .log = &log };
    var b1 = Step{ .id = 21, .log = &log };
    try m.runtime.submit(null, &a, &a1.req);
    try m.runtime.submit(null, &a, &a2.req);
    try m.runtime.submit(null, &a, &a3.req);
    try m.runtime.submit(null, &b, &b1.req);

    _ = try m.runtime.drive(10, 0);
    try testing.expectEqualSlices(u32, &.{ 11, 21, 12, 13 }, log.slice());
    a.deinit();
    b.deinit();
    try m.retire();
}

test "a yielding request rejoins its context behind newer requests" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var s1 = Step{ .id = 1, .log = &log, .script = &.{.yield} };
    var s2 = Step{ .id = 2, .log = &log };
    try m.runtime.submit(null, &ctx, &s1.req);
    try m.runtime.submit(null, &ctx, &s2.req);
    _ = try m.runtime.drive(10, 0);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 1 }, log.slice());
    ctx.deinit();
    try m.retire();
}

test "direct submission runs inline only on an idle context with nothing queued" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var exec = m.runtime.executor();
    var s1 = Step{ .id = 1, .log = &log };
    var s2 = Step{ .id = 2, .log = &log };
    var s3 = Step{ .id = 3, .log = &log };

    try m.runtime.submit(&exec, &ctx, &s1.req);
    try testing.expectEqualSlices(u32, &.{1}, log.slice());

    // s2 queues, so the context is SCHEDULED: a newcomer queues behind it
    // rather than running ahead.
    try m.runtime.submit(null, &ctx, &s2.req);
    try m.runtime.submit(&exec, &ctx, &s3.req);
    try testing.expectEqualSlices(u32, &.{1}, log.slice());

    _ = try m.runtime.drive(10, 0);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, log.slice());
    ctx.deinit();
    try m.retire();
}

test "the inline budget limits direct execution" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual, .inline_turns = 2 });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var exec = m.runtime.executor();
    var steps = [_]Step{
        .{ .id = 1, .log = &log },
        .{ .id = 2, .log = &log },
        .{ .id = 3, .log = &log },
    };
    for (&steps) |*s| try m.runtime.submit(&exec, &ctx, &s.req);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, log.slice());
    _ = try m.runtime.drive(10, 0);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, log.slice());
    ctx.deinit();
    try m.retire();
}

test "the pending budget bounds external submissions, not internal ones" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 2);
    var log: Log = .{};
    var steps = [_]Step{
        .{ .id = 1, .log = &log },
        .{ .id = 2, .log = &log },
        .{ .id = 3, .log = &log },
    };
    try m.runtime.submit(null, &ctx, &steps[0].req);
    try m.runtime.submit(null, &ctx, &steps[1].req);
    try testing.expectError(error.PendingLimit, m.runtime.submit(null, &ctx, &steps[2].req));
    try m.runtime.submitInternal(&ctx, &steps[2].req);
    try testing.expectError(error.Busy, m.runtime.submit(null, &ctx, &steps[0].req));

    _ = try m.runtime.drive(10, 0);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, log.slice());
    // Done requests free their pending credit and may be submitted again.
    try m.runtime.submit(null, &ctx, &steps[0].req);
    try m.runtime.submit(null, &ctx, &steps[1].req);
    _ = try m.runtime.drive(10, 0);
    ctx.deinit();
    try m.retire();
}

// ── Waits ─────────────────────────────────────────────────────────────────────

test "a wake makes a waiting request ready, and a stale token is ignored" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var s = Step{ .id = 1, .log = &log, .script = &.{.wait} };
    try m.runtime.submit(null, &ctx, &s.req);
    _ = try m.runtime.drive(10, 0);
    try testing.expectEqual(rt.Placement.waiting, s.req.placement);

    const token = s.token.?;
    m.runtime.wakeRequest(.{ .request = token.request, .gen = token.gen -% 1 });
    try testing.expectEqual(@as(u32, 0), (try m.runtime.drive(10, 0)).turns);

    m.runtime.wakeRequest(token);
    m.runtime.wakeRequest(token);
    const r = try m.runtime.drive(10, 0);
    try testing.expectEqual(@as(u32, 1), r.turns);
    try testing.expectEqualSlices(u32, &.{ 1, 1 }, log.slice());
    ctx.deinit();
    try m.retire();
}

test "a wake that arrives before the waiting turn returns is kept" {
    const WakesItself = struct {
        req: rt.Request = rt.Request.init(run),
        turns: u32 = 0,

        fn run(req: *rt.Request, turn: *rt.Turn) rt.Outcome {
            const self: *@This() = @fieldParentPtr("req", req);
            self.turns += 1;
            if (self.turns > 1) return .done;
            const token = turn.prepareWait();
            // Another thread's wake landing between registration and return.
            turn.runtime.wakeRequest(token);
            return .wait;
        }
    };
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var w = WakesItself{};
    try m.runtime.submit(null, &ctx, &w.req);
    const r = try m.runtime.drive(10, 0);
    try testing.expectEqual(@as(u32, 2), r.turns);
    try testing.expectEqual(rt.Placement.done, w.req.placement);
    ctx.deinit();
    try m.retire();
}

// ── Timers ────────────────────────────────────────────────────────────────────

const Tick = struct {
    timer: rt.Timer,
    id: u32,
    log: *Log,
    fired_at: i64 = 0,
    fires: u32 = 0,
    /// Re-arm this far ahead after each fire, if nonzero.
    period_ns: i64 = 0,

    fn init(ctx: *rt.Context, id: u32, log: *Log) Tick {
        return .{ .timer = rt.Timer.init(ctx, fire), .id = id, .log = log };
    }

    fn fire(timer: *rt.Timer, turn: *rt.Turn) void {
        const self: *Tick = @fieldParentPtr("timer", timer);
        self.log.add(self.id);
        self.fired_at = turn.now_ns;
        self.fires += 1;
        if (self.period_ns != 0) _ = turn.runtime.armTimer(timer, turn.now_ns + self.period_ns);
    }
};

test "timers fire at their deadlines, earliest first and in arming order on ties" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    const t0 = m.now();
    var t1 = Tick.init(&ctx, 1, &log);
    var t2 = Tick.init(&ctx, 2, &log);
    var t3 = Tick.init(&ctx, 3, &log);
    try testing.expect(m.runtime.armTimer(&t1.timer, t0 + 300));
    try testing.expect(m.runtime.armTimer(&t2.timer, t0 + 100));
    try testing.expect(m.runtime.armTimer(&t3.timer, t0 + 100));

    while (log.n < 3) _ = try m.runtime.drive(10, 1_000);
    try testing.expectEqualSlices(u32, &.{ 2, 3, 1 }, log.slice());
    try testing.expectEqual(t0 + 100, t2.fired_at);
    try testing.expectEqual(t0 + 100, t3.fired_at);
    try testing.expectEqual(t0 + 300, t1.fired_at);
    try testing.expectEqual(@as(u32, 0), m.sb.unbounded_waits);
    ctx.deinit();
    try m.retire();
}

test "cancelling or re-arming a timer makes a fire already queued stale" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    const t0 = m.now();
    var cancelled = Tick.init(&ctx, 1, &log);
    var rearmed = Tick.init(&ctx, 2, &log);
    _ = m.runtime.armTimer(&cancelled.timer, t0 + 100);
    _ = m.runtime.armTimer(&rearmed.timer, t0 + 100);

    // Both fires are queued to the context but have not run.
    m.sb.clock_state.advance(100);
    m.runtime.fireDueTimers(m.now());
    m.runtime.cancelTimer(&cancelled.timer);
    _ = m.runtime.armTimer(&rearmed.timer, t0 + 500);
    _ = try m.runtime.drive(10, 0);
    try testing.expectEqual(@as(usize, 0), log.n);

    while (log.n < 1) _ = try m.runtime.drive(10, 1_000);
    try testing.expectEqualSlices(u32, &.{2}, log.slice());
    try testing.expectEqual(t0 + 500, rearmed.fired_at);
    ctx.deinit();
    try m.retire();
}

test "a recurring timer re-arms itself until the runtime retires" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var t = Tick.init(&ctx, 1, &log);
    t.period_ns = 100;
    _ = m.runtime.armTimer(&t.timer, m.now() + 100);
    while (t.fires < 3) _ = try m.runtime.drive(10, 1_000);

    m.runtime.releaseOwner();
    try testing.expect(!m.runtime.armTimer(&t.timer, m.now() + 100));
    const r = try m.runtime.drive(10, 1_000);
    try testing.expectEqual(rt.State.backend_stopped, r.state);
    try testing.expectEqual(@as(u32, 3), t.fires);
    ctx.deinit();
    m.runtime.deinit();
}

// ── Driving ───────────────────────────────────────────────────────────────────

test "drive rejects a zero budget, nested driving and a hosted runtime" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    try testing.expectError(error.InvalidBudget, m.runtime.drive(0, 0));

    const Nested = struct {
        req: rt.Request = rt.Request.init(run),
        result: ?rt.DriveError = null,
        fn run(req: *rt.Request, turn: *rt.Turn) rt.Outcome {
            const self: *@This() = @fieldParentPtr("req", req);
            if (turn.runtime.drive(1, 0)) |_| {} else |err| self.result = err;
            return .done;
        }
    };
    var ctx = rt.Context.init(&m.runtime, 16);
    var nested = Nested{};
    try m.runtime.submit(null, &ctx, &nested.req);
    _ = try m.runtime.drive(10, 0);
    try testing.expectEqual(@as(?rt.DriveError, error.PreconditionNotMet), nested.result);
    ctx.deinit();
    try m.retire();

    var h: Manual = undefined;
    h.init(.{ .mode = .hosted });
    try testing.expectError(error.PreconditionNotMet, h.runtime.drive(1, 0));
    h.runtime.releaseOwner();
    h.runtime.deinit();
}

test "drive waits only while nothing has run, and never past max_wait" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};

    // Zero max_wait is a poll.
    const t0 = m.now();
    var r = try m.runtime.drive(10, 0);
    try testing.expectEqual(@as(u32, 0), r.turns);
    try testing.expectEqual(t0, m.now());

    // Nothing to do: waits out max_wait, and returns OK with no turns.
    r = try m.runtime.drive(10, 1_000);
    try testing.expectEqual(@as(u32, 0), r.turns);
    try testing.expectEqual(t0 + 1_000, m.now());

    // Ready work runs without waiting for a later timer.
    var tick = Tick.init(&ctx, 9, &log);
    _ = m.runtime.armTimer(&tick.timer, m.now() + 500);
    var s = Step{ .id = 1, .log = &log };
    try m.runtime.submit(null, &ctx, &s.req);
    const before = m.now();
    r = try m.runtime.drive(10, 10_000);
    try testing.expectEqual(@as(u32, 1), r.turns);
    try testing.expectEqual(before, m.now());

    // With nothing ready, it waits for the timer, runs it, and returns.
    r = try m.runtime.drive(10, 10_000);
    try testing.expectEqual(@as(u32, 1), r.turns);
    try testing.expectEqual(before + 500, m.now());
    try testing.expectEqualSlices(u32, &.{ 1, 9 }, log.slice());
    try testing.expectEqual(@as(u32, 0), m.sb.unbounded_waits);
    ctx.deinit();
    try m.retire();
}

test "the budget bounds the turns of one drive and reports remaining work" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var steps: [5]Step = undefined;
    for (&steps, 0..) |*s, i| {
        s.* = .{ .id = @intCast(i), .log = &log };
        try m.runtime.submit(null, &ctx, &s.req);
    }
    var r = try m.runtime.drive(2, 0);
    try testing.expectEqual(@as(u32, 2), r.turns);
    try testing.expect(r.immediate_work);
    r = try m.runtime.drive(10, 0);
    try testing.expectEqual(@as(u32, 3), r.turns);
    try testing.expect(!r.immediate_work);
    ctx.deinit();
    try m.retire();
}

// ── Closing and retirement ────────────────────────────────────────────────────

test "a draining context finishes admitted work, refuses new work, then closes" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var waiting = Step{ .id = 1, .log = &log, .script = &.{.wait} };
    var refused = Step{ .id = 2, .log = &log };
    var internal = Step{ .id = 3, .log = &log };
    try m.runtime.submit(null, &ctx, &waiting.req);
    _ = try m.runtime.drive(10, 0);

    ctx.close();
    try testing.expectEqual(rt.Lifecycle.draining, ctx.getLifecycle());
    try testing.expectError(error.Closed, m.runtime.submit(null, &ctx, &refused.req));
    try m.runtime.submitInternal(&ctx, &internal.req);
    _ = try m.runtime.drive(10, 0);
    try testing.expectEqual(rt.Lifecycle.draining, ctx.getLifecycle());

    m.runtime.wakeRequest(waiting.token.?);
    _ = try m.runtime.drive(10, 0);
    try testing.expectEqual(rt.Lifecycle.closed, ctx.getLifecycle());
    try testing.expectEqualSlices(u32, &.{ 1, 3, 1 }, log.slice());
    ctx.deinit();
    try m.retire();
}

test "releasing the final owner retires the runtime once admitted work drains" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var waiting = Step{ .id = 1, .log = &log, .script = &.{.wait} };
    var late = Step{ .id = 2, .log = &log };
    var tick = Tick.init(&ctx, 9, &log);
    try m.runtime.submit(null, &ctx, &waiting.req);
    _ = try m.runtime.drive(10, 0);
    _ = m.runtime.armTimer(&tick.timer, m.now() + 100);

    m.runtime.retainOwner();
    m.runtime.releaseOwner();
    try testing.expectEqual(rt.State.running, m.runtime.getState());
    m.runtime.releaseOwner();
    try testing.expectEqual(rt.State.retiring, m.runtime.getState());
    try testing.expectError(error.Retiring, m.runtime.submit(null, &ctx, &late.req));

    // The waiting request keeps the runtime retiring; the cancelled timer
    // never fires.
    var r = try m.runtime.drive(10, 1_000);
    try testing.expectEqual(rt.State.retiring, r.state);
    try testing.expect(r.retirement_pending);

    m.runtime.wakeRequest(waiting.token.?);
    r = try m.runtime.drive(10, 1_000);
    try testing.expectEqual(@as(u32, 1), r.turns);
    try testing.expectEqual(rt.State.backend_stopped, r.state);
    try testing.expect(!r.retirement_pending);
    try testing.expectEqualSlices(u32, &.{ 1, 1 }, log.slice());
    ctx.deinit();
    m.runtime.deinit();
}

// ── Hosted ────────────────────────────────────────────────────────────────────

const contexts_n = 8;
const per_context = 200;

/// Detects two executors in one context and records the order of its turns.
const Lane = struct {
    ctx: rt.Context,
    in_turn: std.atomic.Value(bool) = .init(false),
    overlaps: std.atomic.Value(u32) = .init(0),
    order: [per_context * 3]u32 = undefined,
    n: usize = 0,
};

const Job = struct {
    req: rt.Request = rt.Request.init(run),
    lane: *Lane,
    seq: u32,
    yields_left: u32,

    fn run(req: *rt.Request, _: *rt.Turn) rt.Outcome {
        const self: *Job = @fieldParentPtr("req", req);
        const lane = self.lane;
        if (lane.in_turn.swap(true, .acquire)) _ = lane.overlaps.fetchAdd(1, .monotonic);
        // Unsynchronized on purpose: the context's turns must be exclusive
        // and ordered by its gates, which TSan checks.
        lane.order[lane.n] = self.seq;
        lane.n += 1;
        lane.in_turn.store(false, .release);
        if (self.yields_left == 0) return .done;
        self.yields_left -= 1;
        return .yield;
    }
};

const Scenario = struct {
    lanes: [contexts_n]Lane,
    jobs: [contexts_n][per_context]Job,

    fn init(self: *Scenario, runtime: *rt.Runtime) void {
        for (&self.lanes, &self.jobs) |*lane, *jobs| {
            lane.* = .{ .ctx = rt.Context.init(runtime, per_context) };
            for (jobs, 0..) |*j, i| j.* = .{ .lane = lane, .seq = @intCast(i), .yields_left = @intCast(i % 3) };
        }
    }

    fn submitAll(self: *Scenario, runtime: *rt.Runtime) !void {
        for (&self.lanes, &self.jobs) |*lane, *jobs| {
            for (jobs) |*j| try runtime.submit(null, &lane.ctx, &j.req);
        }
    }

    fn deinit(self: *Scenario) void {
        for (&self.lanes) |*lane| lane.ctx.deinit();
    }
};

fn runManual(s: *Scenario) !void {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    s.init(&m.runtime);
    try s.submitAll(&m.runtime);
    while ((try m.runtime.drive(64, 0)).turns > 0) {}
    s.deinit();
    try m.retire();
}

fn runHosted(s: *Scenario, workers: u32) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var backend = rt.IoBackend.init(threaded.io());
    var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .hosted });
    s.init(&runtime);
    try s.submitAll(&runtime);
    var hosted = try rt.Hosted.init(testing.allocator, threaded.io(), &runtime, workers);
    hosted.start() catch |err| {
        runtime.releaseOwner();
        hosted.join();
        return err;
    };
    runtime.releaseOwner();
    hosted.join();
    try testing.expectEqual(rt.State.backend_stopped, runtime.getState());
    s.deinit();
    runtime.deinit();
}

test "manual and hosted drivers give each context the same turn order" {
    const manual = try testing.allocator.create(Scenario);
    defer testing.allocator.destroy(manual);
    const hosted = try testing.allocator.create(Scenario);
    defer testing.allocator.destroy(hosted);
    try runManual(manual);
    try runHosted(hosted, 4);
    for (&manual.lanes, &hosted.lanes) |*a, *b| {
        try testing.expectEqual(@as(u32, 0), b.overlaps.load(.monotonic));
        try testing.expectEqualSlices(u32, a.order[0..a.n], b.order[0..b.n]);
    }
}

test "hosted workers keep each context's turns exclusive while threads submit" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var backend = rt.IoBackend.init(threaded.io());
    var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .hosted, .inline_turns = 4 });
    const s = try testing.allocator.create(Scenario);
    defer testing.allocator.destroy(s);
    s.init(&runtime);

    var hosted = try rt.Hosted.init(testing.allocator, threaded.io(), &runtime, 4);
    try hosted.start();

    // Application threads, outside the Io's pool, each own two contexts and
    // submit with a direct-execution budget.
    const Submitter = struct {
        fn run(sc: *Scenario, r: *rt.Runtime, first: usize) void {
            var exec = r.executor();
            for (first..first + 2) |c| {
                for (&sc.jobs[c]) |*j| {
                    if (exec.inline_left == 0) exec = r.executor();
                    r.submit(&exec, &sc.lanes[c].ctx, &j.req) catch unreachable;
                }
            }
        }
    };
    var threads: [contexts_n / 2]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Submitter.run, .{ s, &runtime, i * 2 });
    for (threads) |t| t.join();

    runtime.releaseOwner();
    hosted.join();
    try testing.expectEqual(rt.State.backend_stopped, runtime.getState());
    for (&s.lanes) |*lane| {
        try testing.expectEqual(@as(u32, 0), lane.overlaps.load(.monotonic));
        // Every job ran once per turn it took: 1 + yields.
        var expected: usize = 0;
        for (0..per_context) |i| expected += 1 + i % 3;
        try testing.expectEqual(expected, lane.n);
    }
    s.deinit();
    runtime.deinit();
}

test "a hosted timer fires on its context, and its callback may release the final owner" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var backend = rt.IoBackend.init(threaded.io());
    var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .hosted });
    var ctx = rt.Context.init(&runtime, 16);

    const Last = struct {
        timer: rt.Timer,
        fired: bool = false,
        fn fire(timer: *rt.Timer, turn: *rt.Turn) void {
            const self: *@This() = @fieldParentPtr("timer", timer);
            self.fired = true;
            turn.runtime.releaseOwner();
        }
    };
    var last = Last{ .timer = rt.Timer.init(&ctx, Last.fire) };
    try testing.expect(runtime.armTimer(&last.timer, runtime.clock.nowNs() + std.time.ns_per_ms));

    var hosted = try rt.Hosted.init(testing.allocator, threaded.io(), &runtime, 2);
    try hosted.start();
    hosted.join();
    try testing.expect(last.fired);
    try testing.expectEqual(rt.State.backend_stopped, runtime.getState());
    ctx.deinit();
    runtime.deinit();
}

// ── Retirement and timer races ────────────────────────────────────────────────

test "a submission admitted as retirement begins runs before the runtime stops" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    var log: Log = .{};
    var s = Step{ .id = 1, .log = &log };

    // The final owner is released after `submit` has read RUNNING and before
    // it publishes the request: retirement must wait for it.
    const Release = struct {
        fn hook(runtime: *rt.Runtime) void {
            runtime.releaseOwner();
        }
    };
    m.runtime.test_hooks.after_state_check = Release.hook;
    try m.runtime.submit(null, &ctx, &s.req);
    try testing.expectEqual(rt.State.retiring, m.runtime.getState());

    const r = try m.runtime.drive(10, 0);
    try testing.expectEqual(@as(u32, 1), r.turns);
    try testing.expectEqual(rt.State.backend_stopped, r.state);
    try testing.expectEqualSlices(u32, &.{1}, log.slice());
    ctx.deinit();
    m.runtime.deinit();
}

test "the last admission to end during retirement stops the runtime" {
    var m: Manual = undefined;
    m.init(.{ .mode = .manual });
    var ctx = rt.Context.init(&m.runtime, 16);
    ctx.close();
    var log: Log = .{};
    var s = Step{ .id = 1, .log = &log };

    // Retirement begins while this submission is in progress, so it cannot
    // stop then; the submission is refused, and nothing else is left to
    // check again. No drive follows, as no hosted worker would.
    const Release = struct {
        fn hook(runtime: *rt.Runtime) void {
            runtime.releaseOwner();
        }
    };
    m.runtime.test_hooks.after_state_check = Release.hook;
    try testing.expectError(error.Closed, m.runtime.submit(null, &ctx, &s.req));
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    ctx.deinit();
    m.runtime.deinit();
}

const Counted = struct {
    req: rt.Request = rt.Request.init(run),
    ran: *std.atomic.Value(u32),

    fn run(req: *rt.Request, _: *rt.Turn) rt.Outcome {
        const self: *Counted = @fieldParentPtr("req", req);
        _ = self.ran.fetchAdd(1, .monotonic);
        return .done;
    }
};

test "stress: every submission accepted while the final owner is released runs" {
    const submitters = 4;
    const per_submitter = 1000;
    const rounds = 20;
    var prng = std.Random.DefaultPrng.init(0xd1e);

    const Submitter = struct {
        ctx: rt.Context = undefined,
        jobs: [per_submitter]Counted = undefined,
        accepted: u32 = 0,

        fn run(self: *@This(), runtime: *rt.Runtime, total: *std.atomic.Value(u32)) void {
            var exec = runtime.executor();
            for (&self.jobs) |*j| {
                if (exec.inline_left == 0) exec = runtime.executor();
                runtime.submit(&exec, &self.ctx, &j.req) catch |err| {
                    std.debug.assert(err == error.Retiring);
                    return;
                };
                self.accepted += 1;
                _ = total.fetchAdd(1, .monotonic);
            }
        }
    };

    const subs = try testing.allocator.alloc(Submitter, submitters);
    defer testing.allocator.free(subs);

    for (0..rounds) |_| {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        var backend = rt.IoBackend.init(threaded.io());
        var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .hosted, .inline_turns = 2 });
        var ran = std.atomic.Value(u32).init(0);
        var total = std.atomic.Value(u32).init(0);
        for (subs) |*sub| {
            sub.* = .{ .ctx = rt.Context.init(&runtime, per_submitter) };
            for (&sub.jobs) |*j| j.* = .{ .ran = &ran };
        }

        var hosted = try rt.Hosted.init(testing.allocator, threaded.io(), &runtime, 3);
        try hosted.start();
        var threads: [submitters]std.Thread = undefined;
        for (&threads, subs) |*t, *sub| t.* = try std.Thread.spawn(.{}, Submitter.run, .{ sub, &runtime, &total });

        // Release the final owner at a different point in each round.
        const release_after = prng.random().uintLessThan(u32, submitters * per_submitter / 2);
        while (total.load(.monotonic) < release_after) std.Thread.yield() catch {};
        runtime.releaseOwner();
        for (threads) |t| t.join();
        hosted.join();

        try testing.expectEqual(rt.State.backend_stopped, runtime.getState());
        var accepted: u32 = 0;
        for (subs) |*sub| accepted += sub.accepted;
        try testing.expectEqual(accepted, ran.load(.monotonic));
        for (subs) |*sub| sub.ctx.deinit();
        runtime.deinit();
    }
}

test "arming an earlier timer wakes a hosted worker waiting for a later one" {
    const Fire = struct {
        timer: rt.Timer,
        fired: bool = false,
        fn fire(timer: *rt.Timer, turn: *rt.Turn) void {
            const self: *@This() = @fieldParentPtr("timer", timer);
            self.fired = true;
            // Whichever timer fires first retires the runtime, which cancels
            // the other.
            turn.runtime.releaseOwner();
        }
    };

    for (0..5) |_| {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        var backend = rt.IoBackend.init(threaded.io());
        var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .hosted });
        var ctx = rt.Context.init(&runtime, 16);
        var backstop = Fire{ .timer = rt.Timer.init(&ctx, Fire.fire) };
        var early = Fire{ .timer = rt.Timer.init(&ctx, Fire.fire) };

        _ = runtime.armTimer(&backstop.timer, runtime.clock.nowNs() + 2 * std.time.ns_per_s);
        var hosted = try rt.Hosted.init(testing.allocator, threaded.io(), &runtime, 1);
        try hosted.start();
        // Wait until the worker is blocked toward the backstop's deadline.
        while (backend.waiters.load(.seq_cst) == 0) std.Thread.yield() catch {};
        _ = runtime.armTimer(&early.timer, runtime.clock.nowNs() + std.time.ns_per_ms);
        hosted.join();

        try testing.expect(early.fired);
        try testing.expect(!backstop.fired);
        ctx.deinit();
        runtime.deinit();
    }
}
