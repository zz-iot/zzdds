//! Listener separation on a shared runtime
//! (docs/design/concurrency/listeners.md#inline-path-and-pending-work): a
//! reader or writer records which of its statuses changed and queues one
//! request on its own listener context. Its listener runs as a turn of that
//! context, never on the stack that changed the status, and a wait that
//! helps with internal work never runs it.
//!
//! One entity's listeners run one at a time, and different entities' may
//! run at once on a hosted runtime, except that one listener identity
//! (util/listener_identity.zig) runs one invocation at a time wherever it is
//! installed (docs/design/concurrency/listeners.md#default-behavior). A turn
//! whose listener is running elsewhere parks instead of blocking: its
//! request leaves the runtime, queued on the identity, and is submitted
//! again once the identity is handed to it. Its status stays unclaimed
//! meanwhile.
//!
//! Each status kind has at most one pending opportunity, ordered by when it
//! first became pending
//! (docs/design/concurrency/listeners.md#status-ordering-requirements). The
//! listener claims the status when its turn runs, so a getter called in
//! between consumes the change instead. Reliable-ready events carry
//! arguments, so they are kept in order as one pending kind.
//!
//! Deleting the owner from ordinary application code waits for a listener
//! running through it to return; deleting it from any callback chain does
//! not wait
//! (docs/design/concurrency/listeners.md#datareader-deletion-callback-and-return-boundary).
//! A participant's entities form a `Group`, which deleting the participant
//! closes: nothing queued or parked starts, and the rest of the deletion
//! waits for the turns in flight or, from inside one, follows the last.

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const proto = @import("../protocol/interface.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const Condvar = @import("../util/condvar.zig").Condvar;
const listener_identity = @import("../util/listener_identity.zig");
const runtime = @import("../runtime/core.zig");

const Guid = proto.Guid;
const Identity = listener_identity.Identity;

/// The pending kind for reliable-ready events; not a DDS status bit.
pub const READY: DDS.StatusMask = 1 << 31;

pub const ReadyEvent = struct { guid: Guid, ready: bool };

/// Listener invocations tracked here on this thread's stack.
threadlocal var invoking: u32 = 0;

/// The entity whose turn is resolving a listener on this thread.
threadlocal var admitting: ?*PendingListeners = null;

/// The group whose member's turn this thread is running.
threadlocal var current_group: ?*Group = null;

/// Whether this thread is inside a callback chain: a tracked listener
/// invocation or any runtime turn, which runs no application code otherwise.
pub fn inCallbackChain() bool {
    return invoking > 0 or runtime.inTurn();
}

/// For a listener resolved to run on this thread: whether it may run now.
/// `source` (a resolution or listener box) has `identity() ?*Identity`. In
/// an entity's turn, takes the identity's execution right for the turn, or
/// parks the turn on it and returns false, and the caller releases what it
/// resolved without claiming the status. Elsewhere it is always true: inline
/// dispatch, or a call nested in a listener, which runs under that
/// listener's rights. An identity there is no memory to record runs
/// unexcluded.
pub fn admit(source: anytype) bool {
    const self = admitting orelse return true;
    admitting = null;
    return self.take(source.identity() orelse return true);
}

/// A participant's listener contexts, closed together by its deletion.
pub const Group = struct {
    runtime: *runtime.Runtime,
    /// Set under `mu`; read without it by turns deciding whether to go on.
    closed: std.atomic.Value(bool) = .init(false),
    mu: Mutex = .{},
    cv: Condvar = .{},
    // Guarded by `mu`.
    /// Requests between submission and the end of their last turn.
    inflight: u32 = 0,
    members: ?*PendingListeners = null,
    rest: ?runtime.Hook = null,
    /// Runs `rest` on the runtime, after the runtime is done with `ctx`.
    ctx: runtime.Context,
    final: runtime.Request = runtime.Request.init(finalRun),

    pub fn init(rt: *runtime.Runtime) Group {
        return .{ .runtime = rt, .ctx = runtime.Context.init(rt, 0) };
    }

    /// Call once every member is freed.
    pub fn deinit(self: *Group) void {
        std.debug.assert(self.members == null and self.inflight == 0);
        self.ctx.deinit();
        self.mu.deinit();
    }

    /// For the participant's deletion: nothing queued or parked starts, and
    /// no listener starts afterwards. Returns true once no turn is in
    /// flight. Returns false when this thread is inside one: the caller
    /// passes the rest of its deletion to `finishWith`.
    pub fn close(self: *Group) bool {
        self.mu.lock();
        self.closed.store(true, .seq_cst);
        var drops: ?*PendingListeners = null;
        var it = self.members;
        while (it) |p| : (it = p.member_next) {
            if (p.shutdown()) {
                p.drop_next = drops;
                drops = p;
            }
        }
        self.mu.unlock();
        // Each holds an owner reference until dropped.
        while (drops) |p| {
            drops = p.drop_next;
            p.drop();
        }
        if (current_group == self) return false;
        self.mu.lock();
        defer self.mu.unlock();
        while (self.inflight > 0) self.cv.wait(&self.mu);
        return true;
    }

    /// Runs `rest` once the last turn in flight ends, as a turn of the
    /// group's own context, so it may free the group.
    pub fn finishWith(self: *Group, rest: runtime.Hook) void {
        self.ctx.on_closed = .{ .ctx = self, .run = onClosed };
        self.mu.lock();
        self.rest = rest;
        const now = self.inflight == 0;
        self.mu.unlock();
        if (now) self.submitFinal();
    }

    fn add(self: *Group, p: *PendingListeners) void {
        self.mu.lock();
        defer self.mu.unlock();
        p.member_prev = null;
        p.member_next = self.members;
        if (self.members) |m| m.member_prev = p;
        self.members = p;
    }

    fn remove(self: *Group, p: *PendingListeners) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (p.member_prev) |prev| prev.member_next = p.member_next else self.members = p.member_next;
        if (p.member_next) |next| next.member_prev = p.member_prev;
    }

    /// Counts a request about to be submitted. False once the group is
    /// closed: it must not be.
    fn begin(self: *Group) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.closed.load(.monotonic)) return false;
        self.inflight += 1;
        return true;
    }

    /// Under `mu` throughout: `close` may free the group once it sees the
    /// last end.
    fn end(self: *Group) void {
        self.mu.lock();
        self.inflight -= 1;
        const last = self.inflight == 0 and self.closed.load(.monotonic);
        const deferred = last and self.rest != null;
        if (last) self.cv.broadcast();
        self.mu.unlock();
        if (deferred) self.submitFinal();
    }

    fn submitFinal(self: *Group) void {
        // Never from the thread that ended the last turn, which may be any.
        self.runtime.submitInternal(&self.ctx, &self.final) catch {};
    }

    fn finalRun(req: *runtime.Request, _: *runtime.Turn) runtime.Outcome {
        const self: *Group = @fieldParentPtr("final", req);
        self.ctx.close();
        return .done;
    }

    fn onClosed(ctx: *anyopaque) void {
        const self: *Group = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        const rest = self.rest.?;
        self.rest = null;
        self.mu.unlock();
        rest.run(rest.ctx);
    }

    fn isClosed(self: *Group) bool {
        return self.closed.load(.seq_cst);
    }
};

/// Embedded in its owner, which keeps it until the owner is freed.
pub const PendingListeners = struct {
    /// The participant's group. Null: the owner invokes its listeners
    /// inline.
    group: ?*Group = null,
    // Used only with a group.
    /// Runs this owner's listener turns.
    ctx: runtime.Context = undefined,
    alloc: std.mem.Allocator = undefined,
    owner: Owner = undefined,
    req: runtime.Request = runtime.Request.init(run),
    waiter: listener_identity.Waiter = .{ .grant = onGrant },
    mu: Mutex = .{},
    // Guarded by `mu`.
    /// Not idle: `req` holds an owner reference and counts in the group.
    state: State = .idle,
    /// The owner is deleted: nothing pending starts.
    closed: bool = false,
    kinds: [max_kinds]DDS.StatusMask = undefined,
    n_kinds: u8 = 0,
    events: std.ArrayListUnmanaged(ReadyEvent) = .empty,
    /// Invocations in progress through the owner, on any thread.
    active: u32 = 0,
    idle: Condvar = .{},
    /// Deletions waiting in `awaitIdle`; read by tests.
    waiting: std.atomic.Value(u32) = .init(0),
    /// Deletions waiting in `shutdown` for a worker's claim; read by tests.
    claim_waits: std.atomic.Value(u32) = .init(0),
    /// The identity whose right this turn holds, or was granted.
    held: ?*Identity = null,
    /// The identity this owner is parked on.
    parked_on: ?*Identity = null,
    /// The turn running now parked: its request leaves the runtime.
    parked_in_turn: bool = false,
    /// `parked_on` was granted before the turn that parked on it ended.
    granted_early: bool = false,
    // Guarded by the group's `mu`.
    member_next: ?*PendingListeners = null,
    member_prev: ?*PendingListeners = null,
    drop_next: ?*PendingListeners = null,

    const max_kinds = 16;

    const State = enum { idle, queued, running, parked };

    pub const Owner = struct {
        ctx: *anyopaque,
        /// Takes a reference that keeps the owner alive, unless it is
        /// being deleted.
        acquire: *const fn (ctx: *anyopaque) bool,
        release: *const fn (ctx: *anyopaque) void,
        /// Resolves, claims and invokes the listener for one status kind.
        status: *const fn (ctx: *anyopaque, kind: DDS.StatusMask) void,
        ready: *const fn (ctx: *anyopaque, event: ReadyEvent) void,
    };

    pub fn init(alloc: std.mem.Allocator, owner: Owner) PendingListeners {
        var self: PendingListeners = .{ .alloc = alloc, .owner = owner };
        self.req.on_done = onDone;
        return self;
    }

    /// Runs the owner's listeners as turns of its own context, a member of
    /// `group`. Call before anything is posted.
    pub fn attach(self: *PendingListeners, group: *Group) void {
        self.ctx = runtime.Context.init(group.runtime, 1);
        self.ctx.lane = .listener;
        self.group = group;
        group.add(self);
    }

    /// The owner is being freed, so nothing is queued.
    pub fn deinit(self: *PendingListeners) void {
        std.debug.assert(self.state == .idle and self.active == 0 and self.held == null and self.parked_on == null);
        if (self.group) |g| {
            g.remove(self);
            self.ctx.deinit();
        }
        self.events.deinit(self.alloc);
        self.mu.deinit();
    }

    /// The runtime this owner's listeners run on, if any.
    pub fn runtimeOf(self: *const PendingListeners) ?*runtime.Runtime {
        return if (self.group) |g| g.runtime else null;
    }

    /// Queues the listener for status `kind`, a single bit. Returns false
    /// without a group: the caller invokes it.
    pub fn post(self: *PendingListeners, kind: DDS.StatusMask) bool {
        if (self.group == null) return false;
        self.mu.lock();
        if (!self.closed) self.addKindLocked(kind);
        self.submitUnlock();
        return true;
    }

    /// Queues a reliable-ready event. Returns false without a group: the
    /// caller invokes the listener.
    pub fn postReady(self: *PendingListeners, event: ReadyEvent) bool {
        if (self.group == null) return false;
        self.mu.lock();
        // Dropped without memory, like a datagram.
        if (!self.closed) {
            if (self.events.append(self.alloc, event)) |_| self.addKindLocked(READY) else |_| {}
        }
        self.submitUnlock();
        return true;
    }

    /// For the owner's deletion: pending listeners never start. One already
    /// running finishes
    /// (docs/design/concurrency/listeners.md#datareader-deletion-callback-and-return-boundary).
    pub fn close(self: *PendingListeners) void {
        self.mu.lock();
        self.closed = true;
        self.n_kinds = 0;
        self.events.clearRetainingCapacity();
        self.mu.unlock();
        if (self.shutdown()) self.drop();
    }

    /// For the owner's deletion, after `close`: waits for invocations in
    /// progress to return, unless this thread is inside a callback chain,
    /// where waiting could wait on itself or on a listener waiting for it.
    /// Without a group, listeners run inline and nothing waits.
    pub fn awaitIdle(self: *PendingListeners) void {
        if (self.group == null or inCallbackChain()) return;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.active == 0) return;
        _ = self.waiting.fetchAdd(1, .seq_cst);
        while (self.active > 0) self.idle.wait(&self.mu);
        _ = self.waiting.fetchSub(1, .seq_cst);
    }

    /// Begins an invocation through the owner on this thread, outside its
    /// context. False once the owner is deleted: the invocation must not
    /// start.
    pub fn enter(self: *PendingListeners) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.closed) return false;
        self.active += 1;
        invoking += 1;
        return true;
    }

    /// Ends an invocation begun by `enter`.
    pub fn leave(self: *PendingListeners) void {
        invoking -= 1;
        self.mu.lock();
        defer self.mu.unlock();
        self.active -= 1;
        if (self.active == 0) self.idle.broadcast();
    }

    /// Whether this owner's turn is parked on an identity; for tests.
    pub fn isParked(self: *PendingListeners) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.state == .parked;
    }

    fn addKindLocked(self: *PendingListeners, kind: DDS.StatusMask) void {
        std.debug.assert(@popCount(kind) == 1);
        for (self.kinds[0..self.n_kinds]) |k| if (k == kind) return;
        self.kinds[self.n_kinds] = kind;
        self.n_kinds += 1;
    }

    fn popKindLocked(self: *PendingListeners) void {
        std.mem.copyForwards(DDS.StatusMask, self.kinds[0 .. self.n_kinds - 1], self.kinds[1..self.n_kinds]);
        self.n_kinds -= 1;
    }

    /// Puts a kind (and event) not invoked back at the front, ahead of
    /// anything posted since.
    fn unpopLocked(self: *PendingListeners, kind: DDS.StatusMask, event: ?ReadyEvent) void {
        if (event) |e| self.events.insert(self.alloc, 0, e) catch {};
        var i: usize = 0;
        while (i < self.n_kinds and self.kinds[i] != kind) i += 1;
        if (i == self.n_kinds) self.n_kinds += 1;
        std.mem.copyBackwards(DDS.StatusMask, self.kinds[1 .. i + 1], self.kinds[0..i]);
        self.kinds[0] = kind;
    }

    /// Submits `req` if something is pending and nothing is in flight.
    /// Releases `mu`.
    fn submitUnlock(self: *PendingListeners) void {
        if (self.state != .idle or self.n_kinds == 0 or self.group.?.isClosed() or
            !self.owner.acquire(self.owner.ctx))
        {
            self.mu.unlock();
            return;
        }
        self.state = .queued;
        self.mu.unlock();
        if (!self.group.?.begin()) {
            // Closed since the check above: never submitted, so not counted.
            self.mu.lock();
            self.state = .idle;
            self.mu.unlock();
            self.owner.release(self.owner.ctx);
            return;
        }
        self.submit();
    }

    fn submit(self: *PendingListeners) void {
        self.ctx.runtime.submit(null, &self.ctx, &self.req) catch self.drop();
    }

    /// Refuses later submissions and takes back a request queued or parked.
    /// Returns whether one was, for the caller to `drop`.
    fn shutdown(self: *PendingListeners) bool {
        if (self.group == null) return false;
        const d = self.ctx.closeDiscarding();
        if (d.requests) |req| {
            std.debug.assert(req == &self.req and req.next == null);
            // A worker that claimed the context before the discard still
            // takes its gate, finds nothing and closes it, which is all it
            // waits on. The drop may free the context: not before then.
            if (!d.closed) {
                _ = self.claim_waits.fetchAdd(1, .seq_cst);
                while (self.ctx.getLifecycle() != .closed) std.Thread.yield() catch {};
            }
            return true;
        }
        self.mu.lock();
        const id = self.parked_on orelse {
            self.mu.unlock();
            return false;
        };
        // Already granted: submitting it fails now the context is closed.
        if (!id.cancel(&self.waiter)) {
            self.mu.unlock();
            return false;
        }
        self.parked_on = null;
        self.parked_in_turn = false;
        const parked = self.state == .parked;
        self.mu.unlock();
        listener_identity.global.release(id);
        return parked;
    }

    /// Takes `id`'s execution right for this turn, or parks on it.
    fn take(self: *PendingListeners, id: *Identity) bool {
        self.mu.lock();
        if (self.held) |h| {
            if (h == id) {
                self.mu.unlock();
                return true;
            }
            // Granted while parked, but the listener has changed since.
            self.held = null;
            self.mu.unlock();
            giveUp(h);
            self.mu.lock();
        }
        id.retain();
        if (id.tryAcquire(&self.waiter)) {
            self.held = id;
        } else {
            self.parked_on = id;
            self.parked_in_turn = true;
        }
        const taken = self.held != null;
        self.mu.unlock();
        return taken;
    }

    fn giveUp(id: *Identity) void {
        id.releaseRight();
        listener_identity.global.release(id);
    }

    fn of(req: *runtime.Request) *PendingListeners {
        return @fieldParentPtr("req", req);
    }

    fn run(req: *runtime.Request, _: *runtime.Turn) runtime.Outcome {
        const self = of(req);
        const group = self.group.?;
        self.mu.lock();
        self.state = .running;
        // What is posted during the turn waits for the next.
        var left = self.n_kinds;
        self.active += 1;
        self.mu.unlock();
        invoking += 1;
        defer self.leave();
        const outer = current_group;
        current_group = group;
        defer current_group = outer;
        // A listener may delete the owner or its participant; what has not
        // started then never does.
        while (left > 0) {
            self.mu.lock();
            if (self.closed or self.n_kinds == 0 or group.isClosed()) {
                self.mu.unlock();
                break;
            }
            const kind = self.kinds[0];
            var event: ?ReadyEvent = null;
            if (kind == READY) {
                if (self.events.items.len > 0) event = self.events.orderedRemove(0);
                if (self.events.items.len == 0) {
                    self.popKindLocked();
                    left -= 1;
                }
            } else {
                self.popKindLocked();
                left -= 1;
            }
            self.mu.unlock();
            if (kind == READY and event == null) continue;

            admitting = self;
            if (event) |e| self.owner.ready(self.owner.ctx, e) else self.owner.status(self.owner.ctx, kind);
            admitting = null;

            self.mu.lock();
            if (self.parked_in_turn) {
                // Not invoked: it runs first once the identity is handed over.
                self.unpopLocked(kind, event);
                self.mu.unlock();
                break;
            }
            const held = self.held;
            self.held = null;
            self.mu.unlock();
            if (held) |h| giveUp(h);
        }
        return .done;
    }

    /// Runs once the runtime is finished with `req`: leaves it parked,
    /// queues it again for what was posted during its turn, or releases the
    /// owner.
    fn onDone(req: *runtime.Request) void {
        const self = of(req);
        self.mu.lock();
        if (self.parked_in_turn) {
            self.parked_in_turn = false;
            if (!self.granted_early) {
                self.state = .parked;
                self.mu.unlock();
                return;
            }
            self.granted_early = false;
            self.state = .queued;
            self.mu.unlock();
            self.submit();
            return;
        }
        if (!self.closed and self.n_kinds > 0) {
            self.state = .queued;
            self.mu.unlock();
            self.submit();
            return;
        }
        self.state = .idle;
        // Granted while parked, for a turn that then found the owner deleted.
        const held = self.held;
        self.held = null;
        const group = self.group.?;
        self.mu.unlock();
        if (held) |h| giveUp(h);
        self.owner.release(self.owner.ctx);
        group.end();
    }

    /// The identity this owner parked on is its: runs it again.
    fn onGrant(w: *listener_identity.Waiter) void {
        const self: *PendingListeners = @fieldParentPtr("waiter", w);
        self.mu.lock();
        self.held = self.parked_on;
        self.parked_on = null;
        switch (self.state) {
            .parked => {
                self.state = .queued;
                self.mu.unlock();
                self.submit();
            },
            // The turn that parked has not ended yet.
            .running => {
                self.granted_early = true;
                self.mu.unlock();
            },
            .idle, .queued => unreachable,
        }
    }

    /// Gives up what is pending, a right granted to it, and the owner
    /// reference `req` held.
    fn drop(self: *PendingListeners) void {
        self.mu.lock();
        self.state = .idle;
        self.n_kinds = 0;
        self.events.clearRetainingCapacity();
        const held = self.held;
        self.held = null;
        const group = self.group.?;
        self.mu.unlock();
        if (held) |h| giveUp(h);
        self.owner.release(self.owner.ctx);
        group.end();
    }
};
