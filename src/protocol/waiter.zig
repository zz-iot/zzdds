//! What a blocking call waits on: its parts, each settled by the entity
//! that owns it, under that entity's lock, at the change that settles it
//! (docs/design/concurrency/operation-effects.md). The waiter keeps the
//! first outcome it is given, so a later change, close or late wakeup
//! cannot change the call's result.

const std = @import("std");
const Mutex = @import("../util/mutex.zig").Mutex;
const Condvar = @import("../util/condvar.zig").Condvar;
const time_mod = @import("../util/time.zig");
const runtime_mod = @import("../runtime/core.zig");

pub const Outcome = enum {
    /// Every part was satisfied before the deadline.
    satisfied,
    timed_out,
    /// A part ended unsatisfied: its writer closed, or its source went.
    part_failed,
    /// The entity the call was made on closed.
    closed,
};

/// What one call waits on: one or more parts, each settled by the entity
/// that owns it. Lock order: that entity's lock, then this one.
pub const Waiter = struct {
    clock: time_mod.Clock,
    /// The manual runtime the wait helps, woken when the wait is settled.
    runtime: ?*runtime_mod.Runtime,
    deadline_ns: ?i64,
    mu: Mutex = .{},
    cond: Condvar = .{},
    // Guarded by `mu`.
    unsatisfied: u32 = 0,
    outcome: ?Outcome = null,

    /// `timeout_ns` null waits indefinitely. On a manual `runtime` the wait
    /// helps it, on its clock.
    pub fn init(runtime: ?*runtime_mod.Runtime, timeout_ns: ?i64) Waiter {
        const clock = if (runtime) |rt| rt.clock else time_mod.monotonicClock();
        return .{
            .clock = clock,
            .runtime = runtime,
            .deadline_ns = if (timeout_ns) |t| clock.nowNs() +| t else null,
        };
    }

    pub fn deinit(self: *Waiter) void {
        self.mu.deinit();
    }

    /// Counts a part still to begin, so the wait cannot be settled
    /// satisfied before every part has.
    pub fn expect(self: *Waiter) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.unsatisfied += 1;
    }

    /// One part is satisfied.
    pub fn satisfied(self: *Waiter) void {
        self.mu.lock();
        self.unsatisfied -= 1;
        if (self.unsatisfied == 0) self.settleLocked(.satisfied);
        self.mu.unlock();
        self.wake();
    }

    /// Settles the wait `outcome`, unless it is settled already.
    pub fn settle(self: *Waiter, outcome: Outcome) void {
        self.mu.lock();
        self.settleLocked(outcome);
        self.mu.unlock();
        self.wake();
    }

    /// Settles the wait `outcome`, a failure or a close of what it waits on,
    /// unless it is settled already, or timed out if the deadline has passed:
    /// a caller running late still sees its timeout.
    pub fn settleFailure(self: *Waiter, outcome: Outcome) void {
        self.settle(if (self.expired()) .timed_out else outcome);
    }

    /// Whether a part satisfied now is late: at the deadline or past it, the
    /// wait times out.
    pub fn expired(self: *const Waiter) bool {
        const dl = self.deadline_ns orelse return false;
        return self.clock.nowNs() >= dl;
    }

    fn settleLocked(self: *Waiter, outcome: Outcome) void {
        if (self.outcome != null) return;
        self.outcome = outcome;
        self.cond.broadcast();
    }

    fn wake(self: *Waiter) void {
        if (self.runtime) |rt| rt.wakeHelpers();
    }

    /// The outcome, waiting for it until the deadline. On a manual runtime
    /// the wait runs its internal work meanwhile.
    pub fn wait(self: *Waiter) Outcome {
        // A zero max_wait only checks: it neither helps nor blocks.
        if (self.expired()) {
            self.settle(.timed_out);
            return self.outcomeNow();
        }
        if (self.runtime) |rt| if (rt.canHelp()) {
            _ = rt.helpUntil(self.deadline_ns, self, isSettled);
            self.mu.lock();
            defer self.mu.unlock();
            self.settleLocked(.timed_out);
            return self.outcome.?;
        };
        self.mu.lock();
        defer self.mu.unlock();
        while (self.outcome == null) {
            const dl = self.deadline_ns orelse {
                self.cond.wait(&self.mu);
                continue;
            };
            const now = self.clock.nowNs();
            if (now >= dl) {
                self.settleLocked(.timed_out);
                break;
            }
            self.cond.timedWaitNs(&self.mu, @intCast(dl - now)) catch {};
        }
        return self.outcome.?;
    }

    fn outcomeNow(self: *Waiter) Outcome {
        self.mu.lock();
        defer self.mu.unlock();
        return self.outcome.?;
    }

    fn isSettled(self: *Waiter) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.outcome != null;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a waiter keeps its first outcome" {
    var w = Waiter.init(null, null);
    defer w.deinit();
    w.expect();
    w.settle(.part_failed);
    w.satisfied();
    w.settle(.closed);
    try testing.expectEqual(Outcome.part_failed, w.wait());
}

test "a waiter is satisfied once every part is" {
    var w = Waiter.init(null, null);
    defer w.deinit();
    w.expect();
    w.expect();
    w.satisfied();
    try testing.expectEqual(@as(?Outcome, null), w.outcome);
    w.satisfied();
    try testing.expectEqual(Outcome.satisfied, w.wait());
}

test "an unsettled waiter times out at its deadline" {
    var w = Waiter.init(null, 0);
    defer w.deinit();
    w.expect();
    try testing.expect(w.expired());
    try testing.expectEqual(Outcome.timed_out, w.wait());
}

test "a waiter without a deadline never expires" {
    var w = Waiter.init(null, null);
    defer w.deinit();
    try testing.expect(!w.expired());
}
