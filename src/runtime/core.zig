//! Shared runtime core: execution contexts with take-turns admission, the
//! runtime ready queue, timers, retirement and the manual driver.
//!
//! Specified by docs/design/concurrency/architecture.md
//! (#admission-and-request-state-transitions, and #ready-queue-publication for
//! the gate handshake) and docs/design/concurrency/runtime.md
//! (#manual-runtime-driving-and-external-loop-integration,
//! #runtime-retirement-progress-and-backend-shutdown).
//!
//! Nothing allocates: requests, timers and contexts embed their queue links,
//! and their storage belongs to whoever created them.

const std = @import("std");
const builtin = @import("builtin");
const Mutex = @import("../util/mutex.zig").Mutex;
const Clock = @import("../util/time.zig").Clock;
const ProgressBackend = @import("backend.zig").ProgressBackend;

// ── Requests ──────────────────────────────────────────────────────────────────

pub const Placement = enum { new, ready, running, waiting, done };

/// What a turn did with its request.
pub const Outcome = enum {
    /// Finished; the request leaves the runtime and may be submitted again.
    done,
    /// More work; the request rejoins its context's FIFO at the tail.
    yield,
    /// Waits for `Runtime.wakeRequest` with the token from `Turn.prepareWait`.
    wait,
};

/// A unit of work run under its context's execution rights, one turn at a
/// time. Owned by its submitter, which keeps it alive until it is done.
pub const Request = struct {
    run: *const fn (req: *Request, turn: *Turn) Outcome,
    // Guarded by the context gate of `context`.
    placement: Placement = .new,
    next: ?*Request = null,
    context: ?*Context = null,
    wait_gen: u32 = 0,
    wake_pending: bool = false,
    /// Admitted with reserved internal credit rather than pending credit.
    internal: bool = false,
    /// Runs once the runtime is finished with a turn that ended `.done`, so
    /// it may free the request.
    on_done: ?*const fn (req: *Request) void = null,

    pub fn init(run: *const fn (req: *Request, turn: *Turn) Outcome) Request {
        return .{ .run = run };
    }
};

/// Identifies one wait of one request. A wake with an older token is ignored.
pub const WaitToken = struct {
    request: *Request,
    gen: u32,
};

/// The executing turn, passed to `Request.run`.
pub const Turn = struct {
    runtime: *Runtime,
    context: *Context,
    request: *Request,
    /// The runtime clock when the turn started.
    now_ns: i64,

    /// Starts a wait. Register the token wherever the wake will come from, then
    /// return `.wait`; a wake that arrives before the turn returns is kept.
    pub fn prepareWait(self: *Turn) WaitToken {
        const ctx = self.context;
        ctx.gate.lock();
        defer ctx.gate.unlock();
        self.request.wait_gen +%= 1;
        self.request.wake_pending = false;
        return .{ .request = self.request, .gen = self.request.wait_gen };
    }
};

// ── Contexts ──────────────────────────────────────────────────────────────────

pub const Lifecycle = enum { open, draining, closed };
pub const Execution = enum { idle, scheduled, running };

/// Whether a context's turns may run application listeners. A wait that helps
/// with work runs internal turns only
/// (docs/design/concurrency/runtime.md#simple-driver-operation).
pub const Lane = enum { internal, listener };

/// The context whose turn this thread is running, if any.
threadlocal var running_context: ?*Context = null;

/// Whether this thread is running a turn of any context.
pub fn inTurn() bool {
    return running_context != null;
}

/// A callback with its state.
pub const Hook = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

/// Requests taken out of a closing context, unrun.
pub const Discarded = struct {
    /// Linked through `Request.next`; each is DONE and back with its owner.
    requests: ?*Request,
    /// The context is CLOSED. Otherwise a turn is still ending, and
    /// `Context.on_closed` runs when it does.
    closed: bool,
};

/// An execution context: at most one executor runs its requests at a time,
/// oldest ready request first.
pub const Context = struct {
    runtime: *Runtime,
    gate: Mutex = .{},
    // Guarded by `gate`.
    lifecycle: Lifecycle = .open,
    execution: Execution = .idle,
    head: ?*Request = null,
    tail: ?*Request = null,
    waiting: u32 = 0,
    /// External requests admitted and not yet done.
    pending: u32 = 0,
    pending_limit: u32,
    /// Set before the context is used.
    lane: Lane = .internal,
    // Guarded by the runtime gate: the embedded ready-queue node.
    ready_next: ?*Context = null,
    /// Runs when the end of a turn closes the context. The runtime does not
    /// touch the context afterwards, so the hook may free it; its owner must
    /// still hold a runtime owner reference. Set before the context is used.
    on_closed: ?Hook = null,

    pub fn init(runtime: *Runtime, pending_limit: u32) Context {
        return .{ .runtime = runtime, .pending_limit = pending_limit };
    }

    pub fn deinit(self: *Context) void {
        self.gate.lock();
        std.debug.assert(self.execution == .idle and self.head == null and self.waiting == 0);
        self.gate.unlock();
        self.gate.deinit();
    }

    /// Closes external admission. Admitted work, including internal
    /// continuations, still runs; the context is CLOSED once none remains.
    pub fn close(self: *Context) void {
        self.gate.lock();
        defer self.gate.unlock();
        if (self.lifecycle == .open) self.lifecycle = .draining;
        _ = self.closeIfDrainedLocked();
    }

    /// Closes external admission and takes every queued request out unrun,
    /// for work its owner may drop, such as datagrams. Waiting requests stay.
    pub fn closeDiscarding(self: *Context) Discarded {
        const rt = self.runtime;
        _ = rt.busy.fetchAdd(1, .seq_cst);
        defer rt.endBusy();
        self.gate.lock();
        defer self.gate.unlock();
        if (self.lifecycle == .open) self.lifecycle = .draining;
        const list = self.head;
        var it = self.head;
        while (it) |req| : (it = req.next) {
            req.placement = .done;
            req.wake_pending = false;
            if (!req.internal) self.pending -= 1;
        }
        self.head = null;
        self.tail = null;
        // A claim already in flight finds nothing to run and releases it.
        if (self.execution == .scheduled and rt.unlinkReady(self)) self.execution = .idle;
        _ = self.closeIfDrainedLocked();
        return .{ .requests = list, .closed = self.lifecycle == .closed };
    }

    /// Whether this thread is running one of the context's turns.
    pub fn isRunningHere(self: *const Context) bool {
        return running_context == self;
    }

    pub fn getLifecycle(self: *Context) Lifecycle {
        self.gate.lock();
        defer self.gate.unlock();
        return self.lifecycle;
    }

    /// Returns whether this closed it.
    fn closeIfDrainedLocked(self: *Context) bool {
        if (self.lifecycle == .draining and self.execution == .idle and
            self.head == null and self.waiting == 0)
        {
            self.lifecycle = .closed;
            return true;
        }
        return false;
    }

    fn appendLocked(self: *Context, req: *Request) void {
        req.placement = .ready;
        req.next = null;
        if (self.tail) |t| t.next = req else self.head = req;
        self.tail = req;
    }

    fn popLocked(self: *Context) ?*Request {
        const req = self.head orelse return null;
        self.head = req.next;
        if (self.head == null) self.tail = null;
        req.next = null;
        return req;
    }

    /// IDLE with work queued becomes SCHEDULED and is published to the runtime
    /// ready queue before the context gate is released. Returns whether it was.
    fn scheduleIfIdleLocked(self: *Context) bool {
        if (self.execution != .idle or self.head == null) return false;
        self.execution = .scheduled;
        self.runtime.linkReady(self);
        return true;
    }
};

// ── Timers ────────────────────────────────────────────────────────────────────

/// A one-shot timer whose callback runs as a turn of `context`. A callback may
/// re-arm its own timer for recurrence. Arming or cancelling makes any fire
/// already queued stale, and a stale fire does nothing.
pub const Timer = struct {
    request: Request = Request.init(timerRun),
    context: *Context,
    callback: *const fn (timer: *Timer, turn: *Turn) void,
    // Guarded by the runtime gate.
    deadline_ns: i64 = 0,
    order: u64 = 0,
    gen: u32 = 0,
    fire_gen: u32 = 0,
    armed: bool = false,
    /// A fire has been submitted and has not started.
    fire_pending: bool = false,
    heap_child: ?*Timer = null,
    heap_sibling: ?*Timer = null,
    heap_prev: ?*Timer = null,

    pub fn init(context: *Context, callback: *const fn (timer: *Timer, turn: *Turn) void) Timer {
        return .{ .context = context, .callback = callback };
    }

    fn timerRun(req: *Request, turn: *Turn) Outcome {
        const self: *Timer = @fieldParentPtr("request", req);
        const rt = turn.runtime;
        rt.gate.lock();
        const current = self.gen == self.fire_gen;
        self.fire_pending = false;
        rt.gate.unlock();
        if (current) self.callback(self, turn);
        // Fired again during this turn, finding its request busy: run again.
        rt.gate.lock();
        defer rt.gate.unlock();
        return if (self.fire_pending) .yield else .done;
    }
};

/// Intrusive pairing heap of armed timers, earliest deadline first and arming
/// order among equal deadlines.
const TimerHeap = struct {
    root: ?*Timer = null,

    fn less(a: *const Timer, b: *const Timer) bool {
        return a.deadline_ns < b.deadline_ns or (a.deadline_ns == b.deadline_ns and a.order < b.order);
    }

    fn meld(a: ?*Timer, b: ?*Timer) ?*Timer {
        const x = a orelse return b;
        const y = b orelse return x;
        const parent, const child = if (less(y, x)) .{ y, x } else .{ x, y };
        child.heap_prev = parent;
        child.heap_sibling = parent.heap_child;
        if (parent.heap_child) |c| c.heap_prev = child;
        parent.heap_child = child;
        parent.heap_prev = null;
        parent.heap_sibling = null;
        return parent;
    }

    /// Two-pass pairing of a sibling list, without recursion.
    fn mergePairs(first: ?*Timer) ?*Timer {
        var reversed: ?*Timer = null;
        var cur = first;
        while (cur) |a| {
            const b = a.heap_sibling;
            var next: ?*Timer = null;
            a.heap_sibling = null;
            const pair = if (b) |bb| blk: {
                next = bb.heap_sibling;
                bb.heap_sibling = null;
                break :blk meld(a, bb).?;
            } else blk: {
                a.heap_prev = null;
                break :blk a;
            };
            pair.heap_sibling = reversed;
            reversed = pair;
            cur = next;
        }
        var result: ?*Timer = null;
        while (reversed) |p| {
            reversed = p.heap_sibling;
            p.heap_sibling = null;
            result = meld(result, p);
        }
        return result;
    }

    fn insert(self: *TimerHeap, t: *Timer) void {
        t.heap_child = null;
        t.heap_sibling = null;
        t.heap_prev = null;
        self.root = meld(self.root, t);
    }

    fn peek(self: *const TimerHeap) ?*Timer {
        return self.root;
    }

    fn pop(self: *TimerHeap) ?*Timer {
        const r = self.root orelse return null;
        self.root = mergePairs(r.heap_child);
        r.heap_child = null;
        return r;
    }

    fn remove(self: *TimerHeap, t: *Timer) void {
        if (self.root == t) {
            _ = self.pop();
            return;
        }
        const prev = t.heap_prev.?;
        if (prev.heap_child == t) prev.heap_child = t.heap_sibling else prev.heap_sibling = t.heap_sibling;
        if (t.heap_sibling) |s| s.heap_prev = prev;
        t.heap_sibling = null;
        t.heap_prev = null;
        const sub = mergePairs(t.heap_child);
        t.heap_child = null;
        self.root = meld(self.root, sub);
    }
};

// ── Runtime ───────────────────────────────────────────────────────────────────

/// RUNNING -> RETIRING -> BACKEND_STOPPED
/// (docs/design/concurrency/runtime.md#state-and-retained-progress-obligation).
/// Reclamation of the runtime's own storage is its owner's, after BACKEND_STOPPED.
pub const State = enum(u8) { running, retiring, backend_stopped };

pub const Mode = enum { manual, hosted };

pub const Options = struct {
    mode: Mode,
    /// Turns an executor may run directly on a submitting thread before it
    /// must queue instead.
    inline_turns: u32 = 8,
};

pub const SubmitError = error{
    /// The context is not open to external submissions.
    Closed,
    /// The runtime is retiring or stopped.
    Retiring,
    /// The context's pending-request budget is used up.
    PendingLimit,
    /// The request is already queued, running or waiting.
    Busy,
};

/// Direct-execution budget of one submitting thread
/// (docs/design/concurrency/architecture.md#admission-policy). A caller without
/// one always queues.
pub const Executor = struct {
    inline_left: u32,
};

pub const DriveError = error{
    /// Zero turns were budgeted.
    InvalidBudget,
    /// Another outer drive is active, or the runtime is hosted.
    PreconditionNotMet,
};

pub const DriveResult = struct {
    turns: u32 = 0,
    /// Work was ready, or a timer due, when the drive returned.
    immediate_work: bool = false,
    state: State = .running,
    retirement_pending: bool = false,
};

pub const Runtime = struct {
    clock: Clock,
    backend: ProgressBackend,
    options: Options,
    gate: Mutex = .{},
    // Guarded by `gate`.
    ready_head: ?*Context = null,
    ready_tail: ?*Context = null,
    timers: TimerHeap = .{},
    armed_timers: u32 = 0,
    timer_order: u64 = 0,
    /// Blocking calls in `helpUntil`.
    helpers: u32 = 0,
    /// Admissions and turns in progress. Incremented before the lifecycle
    /// state is read, so retirement cannot miss an admission.
    busy: std.atomic.Value(u32) = .init(0),
    /// Requests in WAITING across all contexts.
    waiting: std.atomic.Value(u32) = .init(0),
    owners: std.atomic.Value(u32) = .init(1),
    state: std.atomic.Value(State) = .init(.running),
    driving: std.atomic.Value(bool) = .init(false),
    test_hooks: if (builtin.is_test) TestHooks else void = if (builtin.is_test) .{} else {},

    /// Seams for deterministic tests of races; absent outside test builds.
    pub const TestHooks = struct {
        /// Runs once in `submit`, after the lifecycle state is read and before
        /// the request is published.
        after_state_check: ?*const fn (runtime: *Runtime) void = null,
        /// Runs once in `runNext`, after a context is unlinked from the ready
        /// queue and before it is claimed RUNNING.
        after_unlink: ?*const fn (runtime: *Runtime, ctx: *Context) void = null,
    };

    /// The creator holds the first operational-owner reference.
    pub fn init(clock: Clock, backend: ProgressBackend, options: Options) Runtime {
        return .{ .clock = clock, .backend = backend, .options = options };
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(self.state.load(.acquire) == .backend_stopped);
        self.gate.deinit();
    }

    pub fn getState(self: *Runtime) State {
        return self.state.load(.acquire);
    }

    pub fn executor(self: *const Runtime) Executor {
        return .{ .inline_left = self.options.inline_turns };
    }

    // ── Ownership and retirement ─────────────────────────────────────────────

    pub fn retainOwner(self: *Runtime) void {
        const prev = self.owners.fetchAdd(1, .acq_rel);
        std.debug.assert(prev > 0 and self.state.load(.acquire) == .running);
    }

    /// Takes another owner reference unless the final one is already gone:
    /// once retirement begins, nothing attaches to this runtime again.
    pub fn tryRetainOwner(self: *Runtime) bool {
        var n = self.owners.load(.acquire);
        while (n != 0) n = self.owners.cmpxchgWeak(n, n + 1, .acq_rel, .acquire) orelse return true;
        return false;
    }

    /// Releasing the final owner retires the runtime: ordinary admission
    /// closes, armed timers are cancelled, and admitted work drains.
    pub fn releaseOwner(self: *Runtime) void {
        if (self.owners.fetchSub(1, .acq_rel) != 1) return;
        self.gate.lock();
        self.state.store(.retiring, .seq_cst);
        while (self.timers.pop()) |t| {
            t.armed = false;
            t.gen +%= 1;
        }
        self.armed_timers = 0;
        self.gate.unlock();
        self.tryStop();
        self.backend.wakeAll();
    }

    /// Enters BACKEND_STOPPED once retiring and nothing remains: no admission
    /// or turn in progress, no waiting request, nothing ready.
    fn tryStop(self: *Runtime) void {
        if (self.state.load(.seq_cst) != .retiring) return;
        if (self.busy.load(.seq_cst) != 0) return;
        if (self.waiting.load(.seq_cst) != 0) return;
        self.gate.lock();
        const stop = self.ready_head == null and self.state.load(.seq_cst) == .retiring;
        if (stop) self.state.store(.backend_stopped, .seq_cst);
        self.gate.unlock();
        if (stop) self.backend.wakeAll();
    }

    // ── Admission ────────────────────────────────────────────────────────────

    /// Submits an external request. With an executor that has inline budget
    /// left, an idle context with nothing queued runs it directly on this
    /// thread; otherwise it is queued. Do not pass an executor from inside a
    /// turn: a turn keeps its own context's rights.
    pub fn submit(self: *Runtime, exec: ?*Executor, ctx: *Context, req: *Request) SubmitError!void {
        _ = self.busy.fetchAdd(1, .seq_cst);
        defer self.endBusy();
        if (self.state.load(.seq_cst) != .running) return error.Retiring;
        if (builtin.is_test) {
            if (self.test_hooks.after_state_check) |hook| {
                self.test_hooks.after_state_check = null;
                hook(self);
            }
        }

        ctx.gate.lock();
        if (ctx.lifecycle != .open) {
            ctx.gate.unlock();
            return error.Closed;
        }
        if (req.placement != .new and req.placement != .done) {
            ctx.gate.unlock();
            return error.Busy;
        }
        if (ctx.pending >= ctx.pending_limit) {
            ctx.gate.unlock();
            return error.PendingLimit;
        }
        ctx.pending += 1;
        req.internal = false;
        req.context = ctx;
        req.wake_pending = false;

        if (exec) |e| {
            if (e.inline_left > 0 and ctx.execution == .idle and ctx.head == null) {
                e.inline_left -= 1;
                ctx.execution = .running;
                req.placement = .running;
                ctx.gate.unlock();
                _ = self.busy.fetchAdd(1, .seq_cst);
                self.runTurn(ctx, req);
                return;
            }
        }
        ctx.appendLocked(req);
        const scheduled = ctx.scheduleIfIdleLocked();
        ctx.gate.unlock();
        if (scheduled) self.backend.wake();
    }

    /// Submits work that continues an already admitted operation, using
    /// reserved internal credit: accepted while the context drains and the
    /// runtime retires. Always queued.
    pub fn submitInternal(self: *Runtime, ctx: *Context, req: *Request) error{ Busy, Closed }!void {
        _ = self.busy.fetchAdd(1, .seq_cst);
        defer self.endBusy();
        ctx.gate.lock();
        if (ctx.lifecycle == .closed) {
            ctx.gate.unlock();
            return error.Closed;
        }
        if (req.placement != .new and req.placement != .done) {
            ctx.gate.unlock();
            return error.Busy;
        }
        req.internal = true;
        req.context = ctx;
        req.wake_pending = false;
        ctx.appendLocked(req);
        const scheduled = ctx.scheduleIfIdleLocked();
        ctx.gate.unlock();
        if (scheduled) self.backend.wake();
    }

    /// Makes a waiting request ready. A token from an older wait is ignored.
    pub fn wakeRequest(self: *Runtime, token: WaitToken) void {
        const req = token.request;
        const ctx = req.context.?;
        _ = self.busy.fetchAdd(1, .seq_cst);
        defer self.endBusy();
        ctx.gate.lock();
        if (token.gen != req.wait_gen) {
            ctx.gate.unlock();
            return;
        }
        var scheduled = false;
        switch (req.placement) {
            .running => req.wake_pending = true,
            .waiting => {
                req.wait_gen +%= 1;
                ctx.waiting -= 1;
                ctx.appendLocked(req);
                scheduled = ctx.scheduleIfIdleLocked();
                _ = self.waiting.fetchSub(1, .seq_cst);
            },
            else => {},
        }
        ctx.gate.unlock();
        if (scheduled) self.backend.wake();
    }

    /// Ends an admission or turn. Everything that lets a retiring runtime stop
    /// (the ready queue emptying, a waiting request finishing, an admission
    /// being refused) happens inside one of these, so the last to end checks
    /// again: an earlier `tryStop` saw it in progress and gave up.
    fn endBusy(self: *Runtime) void {
        if (self.busy.fetchSub(1, .seq_cst) == 1 and self.state.load(.seq_cst) == .retiring) self.tryStop();
    }

    /// Links an unlinked SCHEDULED context at the tail of the ready queue.
    /// Called with its context gate held.
    fn linkReady(self: *Runtime, ctx: *Context) void {
        self.gate.lock();
        defer self.gate.unlock();
        ctx.ready_next = null;
        if (self.ready_tail) |t| t.ready_next = ctx else self.ready_head = ctx;
        self.ready_tail = ctx;
    }

    /// Unlinks a SCHEDULED context from the ready queue, if no claim has
    /// unlinked it already. Called with its context gate held.
    fn unlinkReady(self: *Runtime, ctx: *Context) bool {
        self.gate.lock();
        defer self.gate.unlock();
        var prev: ?*Context = null;
        var it = self.ready_head;
        while (it) |c| : ({
            prev = c;
            it = c.ready_next;
        }) {
            if (c != ctx) continue;
            if (prev) |p| p.ready_next = c.ready_next else self.ready_head = c.ready_next;
            if (self.ready_tail == c) self.ready_tail = prev;
            c.ready_next = null;
            return true;
        }
        return false;
    }

    /// Unlinks the oldest ready context in `lane` (any lane when null).
    /// Called with the runtime gate held.
    fn takeReadyLocked(self: *Runtime, lane: ?Lane) ?*Context {
        var prev: ?*Context = null;
        var it = self.ready_head;
        while (it) |c| : ({
            prev = c;
            it = c.ready_next;
        }) {
            if (lane) |l| if (c.lane != l) continue;
            if (prev) |p| p.ready_next = c.ready_next else self.ready_head = c.ready_next;
            if (self.ready_tail == c) self.ready_tail = prev;
            c.ready_next = null;
            return c;
        }
        return null;
    }

    // ── Execution ────────────────────────────────────────────────────────────

    /// Claims the oldest scheduled context and runs one turn of its oldest
    /// ready request. Returns false when nothing was ready.
    pub fn runNext(self: *Runtime) bool {
        return self.runNextIn(null);
    }

    /// Like `runNext`, but claims only internal-lane contexts, leaving
    /// listener work queued in its place: for a wait that helps.
    pub fn runNextInternal(self: *Runtime) bool {
        return self.runNextIn(.internal);
    }

    fn runNextIn(self: *Runtime, lane: ?Lane) bool {
        while (true) {
            _ = self.busy.fetchAdd(1, .seq_cst);
            self.gate.lock();
            const ctx = self.takeReadyLocked(lane) orelse {
                self.gate.unlock();
                self.endBusy();
                return false;
            };
            self.gate.unlock();
            if (builtin.is_test) {
                if (self.test_hooks.after_unlink) |hook| {
                    self.test_hooks.after_unlink = null;
                    hook(self, ctx);
                }
            }

            ctx.gate.lock();
            std.debug.assert(ctx.execution == .scheduled);
            const req = ctx.popLocked() orelse {
                // Its queued work was discarded while this claim was in flight.
                ctx.execution = .idle;
                const hook = if (ctx.closeIfDrainedLocked()) ctx.on_closed else null;
                ctx.gate.unlock();
                self.endBusy();
                if (hook) |h| h.run(h.ctx);
                continue;
            };
            ctx.execution = .running;
            req.placement = .running;
            ctx.gate.unlock();
            self.runTurn(ctx, req);
            return true;
        }
    }

    /// Runs one turn of `req`, which the caller has claimed RUNNING and counted
    /// busy, then finishes the turn and releases the context.
    fn runTurn(self: *Runtime, ctx: *Context, req: *Request) void {
        var turn = Turn{ .runtime = self, .context = ctx, .request = req, .now_ns = self.clock.nowNs() };
        const outer = running_context;
        running_context = ctx;
        const outcome = req.run(req, &turn);
        running_context = outer;

        var on_done: ?*const fn (req: *Request) void = null;
        ctx.gate.lock();
        switch (outcome) {
            .done => {
                req.placement = .done;
                req.wake_pending = false;
                if (!req.internal) ctx.pending -= 1;
                on_done = req.on_done;
            },
            .yield => ctx.appendLocked(req),
            .wait => if (req.wake_pending) {
                req.wake_pending = false;
                req.wait_gen +%= 1;
                ctx.appendLocked(req);
            } else {
                req.placement = .waiting;
                ctx.waiting += 1;
                _ = self.waiting.fetchAdd(1, .seq_cst);
            },
        }
        ctx.execution = .idle;
        const scheduled = ctx.scheduleIfIdleLocked();
        const on_closed = if (ctx.closeIfDrainedLocked()) ctx.on_closed else null;
        ctx.gate.unlock();
        self.endBusy();
        if (scheduled) self.backend.wake();
        // What the turn changed may end a helper's wait.
        if (self.options.mode == .manual) self.wakeHelpers();
        // Neither the request nor the context is touched after these.
        if (on_done) |f| f(req);
        if (on_closed) |h| h.run(h.ctx);
    }

    // ── Timers ───────────────────────────────────────────────────────────────

    /// Arms `t` for `deadline_ns` on the runtime clock, replacing any earlier
    /// arming. Returns false once the runtime is retiring: recurrence stops.
    pub fn armTimer(self: *Runtime, t: *Timer, deadline_ns: i64) bool {
        return self.arm(t, deadline_ns, false);
    }

    /// Like `armTimer`, but leaves `t` alone when it is already armed for
    /// `deadline_ns` or earlier, or has a current fire queued: for a timer
    /// that several events may each need to bring forward.
    pub fn armTimerNoLater(self: *Runtime, t: *Timer, deadline_ns: i64) bool {
        return self.arm(t, deadline_ns, true);
    }

    fn arm(self: *Runtime, t: *Timer, deadline_ns: i64, no_later: bool) bool {
        self.gate.lock();
        if (self.state.load(.seq_cst) != .running) {
            self.gate.unlock();
            return false;
        }
        if (no_later) {
            const queued = t.fire_pending and t.gen == t.fire_gen;
            if (queued or (t.armed and t.deadline_ns <= deadline_ns)) {
                self.gate.unlock();
                return true;
            }
        }
        if (t.armed) self.timers.remove(t) else self.armed_timers += 1;
        t.gen +%= 1;
        t.deadline_ns = deadline_ns;
        t.order = self.timer_order;
        self.timer_order += 1;
        t.armed = true;
        self.timers.insert(t);
        const earliest = self.timers.peek() == t;
        self.gate.unlock();
        // A waiter may be sleeping toward a later deadline.
        if (earliest) self.backend.wakeAll();
        return true;
    }

    /// Disarms `t`; a fire already queued becomes stale.
    pub fn cancelTimer(self: *Runtime, t: *Timer) void {
        self.gate.lock();
        defer self.gate.unlock();
        if (t.armed) {
            self.timers.remove(t);
            t.armed = false;
            self.armed_timers -= 1;
        }
        t.gen +%= 1;
    }

    /// Submits every timer due at `now_ns` to its context. A timer whose
    /// previous fire has not run yet coalesces into it.
    pub fn fireDueTimers(self: *Runtime, now_ns: i64) void {
        _ = self.busy.fetchAdd(1, .seq_cst);
        defer self.endBusy();
        while (true) {
            self.gate.lock();
            const t = self.timers.peek() orelse {
                self.gate.unlock();
                return;
            };
            if (t.deadline_ns > now_ns) {
                self.gate.unlock();
                return;
            }
            _ = self.timers.pop();
            t.armed = false;
            self.armed_timers -= 1;
            t.fire_gen = t.gen;
            t.fire_pending = true;
            self.gate.unlock();
            self.submitInternal(t.context, &t.request) catch |err| switch (err) {
                // Its request is queued, or running a turn that runs it again.
                error.Busy => {},
                error.Closed => {
                    self.gate.lock();
                    t.fire_pending = false;
                    self.gate.unlock();
                },
            };
        }
    }

    /// The earliest armed deadline, if any.
    pub fn nextDeadline(self: *Runtime) ?i64 {
        self.gate.lock();
        defer self.gate.unlock();
        return if (self.timers.peek()) |t| t.deadline_ns else null;
    }

    fn hasReady(self: *Runtime) bool {
        self.gate.lock();
        defer self.gate.unlock();
        return self.ready_head != null;
    }

    fn hasReadyInternal(self: *Runtime) bool {
        self.gate.lock();
        defer self.gate.unlock();
        var it = self.ready_head;
        while (it) |c| : (it = c.ready_next) {
            if (c.lane == .internal) return true;
        }
        return false;
    }

    fn workDue(self: *Runtime, now_ns: i64) bool {
        if (self.hasReady()) return true;
        const d = self.nextDeadline() orelse return false;
        return d <= now_ns;
    }

    // ── Driving ──────────────────────────────────────────────────────────────

    /// Runs up to `max_turns` turns. When nothing is runnable, waits up to
    /// `max_wait_ns` for work, then returns; once a turn has run it does not
    /// wait again to fill the budget
    /// (docs/design/concurrency/runtime.md#simple-driver-operation).
    pub fn drive(self: *Runtime, max_turns: u32, max_wait_ns: i64) DriveError!DriveResult {
        if (max_turns == 0) return error.InvalidBudget;
        if (self.options.mode != .manual) return error.PreconditionNotMet;
        if (self.driving.swap(true, .acq_rel)) return error.PreconditionNotMet;
        defer self.driving.store(false, .release);

        var now = self.clock.nowNs();
        const wait_deadline = now +| @max(max_wait_ns, 0);
        var result: DriveResult = .{};
        while (true) {
            self.fireDueTimers(now);
            _ = self.backend.service(max_turns - result.turns);
            while (result.turns < max_turns and self.runNext()) result.turns += 1;
            if (result.turns > 0) break;
            self.tryStop();
            if (self.state.load(.acquire) == .backend_stopped) break;

            const token = self.backend.prepareWait();
            now = self.clock.nowNs();
            if (self.workDue(now)) continue;
            if (now >= wait_deadline) break;
            const deadline = if (self.nextDeadline()) |d| @min(d, wait_deadline) else wait_deadline;
            self.backend.wait(deadline, token);
            now = self.clock.nowNs();
        }
        self.tryStop();
        result.immediate_work = self.workDue(self.clock.nowNs());
        result.state = self.state.load(.acquire);
        result.retirement_pending = result.state == .retiring;
        return result;
    }

    // ── Helping ──────────────────────────────────────────────────────────────

    /// Whether a blocking call may help this runtime. Hosted workers supply
    /// progress, so callers on a hosted runtime only observe
    /// (docs/design/concurrency/operations.md#stable-helping-policy).
    pub fn canHelp(self: *const Runtime) bool {
        return self.options.mode == .manual;
    }

    /// For a blocking call on a manual runtime: waits until `done(ctx)` or
    /// until the runtime clock reaches `deadline_ns` (null: no deadline),
    /// running due timers and internal turns meanwhile, never listener turns
    /// (docs/design/concurrency/runtime.md#simple-driver-operation). Unlike
    /// `drive`, any number of callers may help at once, alongside a driver.
    /// A turn of this runtime ends the wait to recheck `done`; whatever else
    /// can make it true calls `wakeHelpers`. Returns `done`'s last result.
    pub fn helpUntil(self: *Runtime, deadline_ns: ?i64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) bool {
        std.debug.assert(self.canHelp());
        // Counted before `done` is first checked, under `gate` as
        // `wakeHelpers` reads it: a change made before a waker's check is
        // seen by that first check.
        self.gate.lock();
        self.helpers += 1;
        self.gate.unlock();
        defer {
            self.gate.lock();
            self.helpers -= 1;
            self.gate.unlock();
        }
        while (true) {
            if (done(ctx)) return true;
            self.fireDueTimers(self.clock.nowNs());
            _ = self.backend.service(self.options.inline_turns);
            var turns: u32 = 0;
            while (turns < self.options.inline_turns and self.runNextInternal()) turns += 1;
            if (turns > 0) continue;

            const token = self.backend.prepareWait();
            if (done(ctx)) return true;
            const now = self.clock.nowNs();
            if (self.hasReadyInternal()) continue;
            if (deadline_ns) |d| if (now >= d) return false;
            const timer = self.nextDeadline();
            if (timer) |t| if (t <= now) continue;
            const until = if (timer) |t| (if (deadline_ns) |d| @min(t, d) else t) else deadline_ns;
            self.backend.wait(until, token);
        }
    }

    /// Ends the waits of callers in `helpUntil`, for a change made outside
    /// this runtime's turns that may satisfy one.
    pub fn wakeHelpers(self: *Runtime) void {
        self.gate.lock();
        const helping = self.helpers > 0;
        self.gate.unlock();
        if (helping) self.backend.wakeAll();
    }

    /// One hosted worker's loop: run ready work, otherwise wait for it, until
    /// the runtime stops.
    pub fn serveUntilStopped(self: *Runtime) void {
        std.debug.assert(self.options.mode == .hosted);
        while (true) {
            const now = self.clock.nowNs();
            self.fireDueTimers(now);
            _ = self.backend.service(self.options.inline_turns);
            if (self.runNext()) continue;
            self.tryStop();
            if (self.state.load(.acquire) == .backend_stopped) return;
            const token = self.backend.prepareWait();
            if (self.workDue(self.clock.nowNs())) continue;
            if (self.state.load(.acquire) == .backend_stopped) return;
            self.backend.wait(self.nextDeadline(), token);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "timer heap pops in deadline then arming order under random insert and remove" {
    const n = 200;
    var timers: [n]Timer = undefined;
    var in_heap: [n]bool = @splat(false);
    var heap: TimerHeap = .{};
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var order: u64 = 0;

    for (0..4000) |_| {
        const i = rand.uintLessThan(usize, n);
        if (in_heap[i] and rand.boolean()) {
            heap.remove(&timers[i]);
            in_heap[i] = false;
        } else if (!in_heap[i]) {
            timers[i] = .{ .context = undefined, .callback = undefined };
            timers[i].deadline_ns = rand.intRangeAtMost(i64, 0, 50);
            timers[i].order = order;
            order += 1;
            heap.insert(&timers[i]);
            in_heap[i] = true;
        }
    }

    var popped: usize = 0;
    var last_deadline: i64 = std.math.minInt(i64);
    var last_order: u64 = 0;
    while (heap.pop()) |t| {
        const idx = (@intFromPtr(t) - @intFromPtr(&timers[0])) / @sizeOf(Timer);
        try std.testing.expect(in_heap[idx]);
        in_heap[idx] = false;
        try std.testing.expect(t.deadline_ns > last_deadline or
            (t.deadline_ns == last_deadline and t.order > last_order));
        last_deadline = t.deadline_ns;
        last_order = t.order;
        popped += 1;
    }
    for (in_heap) |still| try std.testing.expect(!still);
    try std.testing.expect(popped > 0);
}
