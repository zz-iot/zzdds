//! Refcounted quiesce guard making entity teardown safe against a
//! concurrently in-flight background-thread callback.
//!
//! `deinit()` frees the whole entity struct (`DataReaderImpl`/
//! `DataWriterImpl`) with nothing waiting for an RTPS receive-thread,
//! timer-thread, or discovery-thread callback that's already dispatching
//! into it. Every current dispatch path happens to serialize against entity
//! deletion via `participant.mu` today, but that's an incidental side
//! effect of those paths holding `participant.mu` across the whole dispatch
//! (including firing the user's listener) — not a documented invariant,
//! and it would silently break if that locking were ever loosened to stop
//! blocking unrelated RTPS traffic during a slow listener callback.
//! `EntityQuiesce` makes entity lifetime safety independent of that.
const std = @import("std");

pub const EntityQuiesce = struct {
    /// 1 = the entity's own "alive" reference, dropped by `beginTeardown()`.
    refcount: std.atomic.Value(usize) = .init(1),
    /// Set once, by `beginTeardown()`. Belt-and-suspenders: every current
    /// dispatch path already can't reach a deleted entity at all (it's
    /// removed from `active_readers`/`active_writers` before `deinit()`
    /// runs), so `refcount` reaching zero is what actually matters — this
    /// flag just guarantees a *new* acquire can never succeed once teardown
    /// has begun even if some future dispatch path doesn't already gate on
    /// that removal, independent of how many references happen to still be
    /// outstanding at that moment.
    tearing_down: std.atomic.Value(bool) = .init(false),

    /// Call at the very top of any function invoked from a background
    /// thread (RTPS receive, timer, discovery), before touching any other
    /// field of the owning entity. False means teardown has already begun
    /// (or the entity's own reference has already been dropped) — the
    /// caller must return immediately without touching anything else.
    pub fn acquire(self: *EntityQuiesce) bool {
        if (self.tearing_down.load(.acquire)) return false;
        while (true) {
            const cur = self.refcount.load(.acquire);
            if (cur == 0) return false;
            if (self.refcount.cmpxchgWeak(cur, cur + 1, .acq_rel, .acquire) == null) return true;
        }
    }

    /// Pairs with a successful `acquire()`. Runs `on_last(ctx)` iff this was
    /// the last outstanding reference — synchronously, on whichever
    /// caller's release happens to be last (normally `beginTeardown()`'s
    /// own drop; occasionally a background callback that was still in
    /// flight when teardown began, in which case *that* callback's release
    /// is what actually tears the entity down, transparently to the
    /// deleting thread, which has already returned by then).
    pub fn release(self: *EntityQuiesce, ctx: *anyopaque, comptime on_last: fn (*anyopaque) void) void {
        if (self.refcount.fetchSub(1, .acq_rel) == 1) on_last(ctx);
    }

    /// Call once, from `deinit()`: marks the entity as no longer accepting
    /// new acquires, then drops its own "alive" reference exactly like
    /// `release()` would.
    pub fn beginTeardown(self: *EntityQuiesce, ctx: *anyopaque, comptime on_last: fn (*anyopaque) void) void {
        self.tearing_down.store(true, .release);
        self.release(ctx, on_last);
    }
};

const testing = std.testing;

test "EntityQuiesce: beginTeardown runs on_last immediately when nothing else holds a ref" {
    var q = EntityQuiesce{};
    var calls: u32 = 0;
    const Static = struct {
        var counter: *u32 = undefined;
        fn onLast(_: *anyopaque) void {
            counter.* += 1;
        }
    };
    Static.counter = &calls;
    q.beginTeardown(&q, Static.onLast);
    try testing.expectEqual(@as(u32, 1), calls);
}

test "EntityQuiesce: acquire fails once teardown has begun, even before refcount reaches zero" {
    var q = EntityQuiesce{};
    var calls: u32 = 0;
    const Static = struct {
        var counter: *u32 = undefined;
        fn onLast(_: *anyopaque) void {
            counter.* += 1;
        }
    };
    Static.counter = &calls;

    // Simulate a background callback that acquired before teardown began.
    try testing.expect(q.acquire());
    // deinit() begins teardown concurrently -- not the last ref (the
    // callback above still holds its own), so on_last doesn't fire yet.
    q.beginTeardown(&q, Static.onLast);
    try testing.expectEqual(@as(u32, 0), calls);
    // A late-arriving callback must not be able to acquire once teardown
    // has begun, regardless of the outstanding refcount.
    try testing.expect(!q.acquire());
    // The in-flight callback finishes and releases -- now it's the last ref.
    q.release(&q, Static.onLast);
    try testing.expectEqual(@as(u32, 1), calls);
}

test "EntityQuiesce: acquire fails after a plain teardown with nothing in flight" {
    var q = EntityQuiesce{};
    var calls: u32 = 0;
    const Static = struct {
        var counter: *u32 = undefined;
        fn onLast(_: *anyopaque) void {
            counter.* += 1;
        }
    };
    Static.counter = &calls;
    q.beginTeardown(&q, Static.onLast);
    try testing.expectEqual(@as(u32, 1), calls);
    try testing.expect(!q.acquire());
}
