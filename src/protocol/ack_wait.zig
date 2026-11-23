//! A wait_for_acknowledgments call: what its caller waits on, and each
//! writer's part of it
//! (docs/design/concurrency/operations.md#datawriter-acknowledgment-wait-frontier-and-completion-contract).
//!
//! A writer settles its captures under its own lock, at the change that
//! settles them: the last acknowledgment, the unmatch of the last reader
//! owing one, or the writer's close. The waiter keeps the first outcome it
//! is given, so a later acknowledgment, close or late wakeup cannot change
//! the call's result.

const std = @import("std");
const Mutex = @import("../util/mutex.zig").Mutex;
const Condvar = @import("../util/condvar.zig").Condvar;
const time_mod = @import("../util/time.zig");
const runtime_mod = @import("../runtime/core.zig");
const guid_mod = @import("../rtps/guid.zig");
const history_mod = @import("../rtps/history.zig");

const Guid = guid_mod.Guid;
const SequenceNumber = history_mod.SequenceNumber;

pub const Outcome = enum {
    /// Every capture was acknowledged before the deadline.
    acknowledged,
    timed_out,
    /// A writer closed before its capture was acknowledged.
    writer_closed,
    /// The Publisher waited on closed.
    closed,
};

/// What one call waits on. Lock order: a writer's lock, then this one.
pub const Waiter = struct {
    clock: time_mod.Clock,
    /// The manual runtime the wait helps, woken when the wait is settled.
    runtime: ?*runtime_mod.Runtime,
    deadline_ns: ?i64,
    mu: Mutex = .{},
    cond: Condvar = .{},
    // Guarded by `mu`.
    unacknowledged: u32 = 0,
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

    /// Counts a capture still to begin, so the wait cannot be settled
    /// acknowledged before every capture has.
    pub fn expect(self: *Waiter) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.unacknowledged += 1;
    }

    /// One capture has every acknowledgment it waited for.
    pub fn acknowledged(self: *Waiter) void {
        self.mu.lock();
        self.unacknowledged -= 1;
        if (self.unacknowledged == 0) self.settleLocked(.acknowledged);
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

    /// Settles the wait `outcome` as what it waits on closes, unless it is
    /// settled already, or timed out if the deadline has passed: a caller
    /// running late still sees its timeout.
    pub fn settleClose(self: *Waiter, outcome: Outcome) void {
        self.settle(if (self.expired()) .timed_out else outcome);
    }

    /// Whether a capture acknowledged now is late: at the deadline or past
    /// it, the wait times out.
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

/// One writer's part of a wait: the last sequence number it had committed
/// when the wait began, and the reliable readers then matched that had not
/// acknowledged it. Readers matched later do not join; one that unmatches
/// owes nothing more, and matching again is a new match that does not
/// either.
pub const Capture = struct {
    waiter: *Waiter,
    target_sn: SequenceNumber = 0,
    readers: []Reader = &.{},
    /// Whether the writer still holds the capture, to settle it.
    registered: bool = false,
    /// Whether the capture's DCPS writer pins its protocol writer for it.
    pinned: bool = false,

    pub const Reader = struct {
        guid: Guid,
        /// Which of the reader's matches it owes for.
        match_id: u64,
        /// Owes nothing more: it became best effort.
        retired: bool = false,
    };
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a waiter keeps its first outcome" {
    var w = Waiter.init(null, null);
    defer w.deinit();
    w.expect();
    w.settle(.writer_closed);
    w.acknowledged();
    w.settle(.closed);
    try testing.expectEqual(Outcome.writer_closed, w.wait());
}

test "a waiter is acknowledged once every capture is" {
    var w = Waiter.init(null, null);
    defer w.deinit();
    w.expect();
    w.expect();
    w.acknowledged();
    try testing.expectEqual(@as(?Outcome, null), w.outcome);
    w.acknowledged();
    try testing.expectEqual(Outcome.acknowledged, w.wait());
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
