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
//!
//! `acquire()`/`release()`/`beginTeardown()` still can't protect a `ctx`
//! pointer that was already dangling *before* `acquire()` was ever called —
//! that guarantee has to come from whatever hands `ctx` to the callback in
//! the first place. What `EntityQuiesce` guarantees is that once a callback
//! has validly entered with a live `ctx`, the entity won't be freed out
//! from under it while it's still running, and any `acquire()` that starts
//! once teardown has begun is told no rather than silently touching torn-
//! down state.
const std = @import("std");

pub const EntityQuiesce = struct {
    /// High bit = tearing-down flag; remaining bits = refcount (1 = the
    /// entity's own "alive" reference, dropped by `beginTeardown()`).
    /// Packed into one word so `acquire()` reads "is tearing down" and "is
    /// refcount nonzero" as a single atomic snapshot and increments off
    /// that same snapshot with one CAS.
    ///
    /// An earlier version of this type kept those as two separate atomics
    /// (a `tearing_down` bool checked first, then a separate `refcount`
    /// CAS loop) — correctly flagged as racy: `beginTeardown()` could set
    /// the flag *and* drop the refcount to zero (freeing the entity, since
    /// nothing else held a reference) in the gap between the caller's two
    /// reads, so the caller's second operation touched already-freed
    /// memory. Packing both into one word closes that specific gap: there
    /// is no longer a "check the flag, then separately touch the count"
    /// window, since both are read and written together.
    ///
    /// This does not, on its own, make dereferencing a raw `ctx` pointer
    /// safe if that pointer could already be dangling *before* `acquire()`
    /// is even called — no per-entity refcount can protect against that,
    /// only the dispatch mechanism handing out `ctx` can (today, every
    /// dispatch path holds `participant.mu` across the full callback, so
    /// `ctx` is never resolved from a removed/deleted entity — see the
    /// module doc comment above).
    state: std.atomic.Value(usize) = .init(1),

    const tearing_down_bit: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const count_mask: usize = tearing_down_bit - 1;

    /// Call at the very top of any function invoked from a background
    /// thread (RTPS receive, timer, discovery), before touching any other
    /// field of the owning entity. False means teardown has already begun
    /// (or the entity's own reference has already been dropped) — the
    /// caller must return immediately without touching anything else.
    pub fn acquire(self: *EntityQuiesce) bool {
        while (true) {
            const cur = self.state.load(.acquire);
            if (cur & tearing_down_bit != 0) return false;
            if (cur & count_mask == 0) return false;
            if (self.state.cmpxchgWeak(cur, cur + 1, .acq_rel, .acquire) == null) return true;
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
        const prev = self.state.fetchSub(1, .acq_rel);
        if (prev & count_mask == 1) on_last(ctx);
    }

    /// Call once, from `deinit()`: marks the entity as no longer accepting
    /// new acquires, then drops its own "alive" reference exactly like
    /// `release()` would. The flag-set and the refcount-drop are still two
    /// separate atomic ops here, but that's fine — `acquire()` re-reads the
    /// *combined* word fresh each time through its loop, so it either sees
    /// the flag already set (and bails before touching the count at all)
    /// or sees the pre-teardown word and races the CAS normally, with no
    /// window where it inspects the flag and count from two different
    /// points in time.
    pub fn beginTeardown(self: *EntityQuiesce, ctx: *anyopaque, comptime on_last: fn (*anyopaque) void) void {
        _ = self.state.fetchOr(tearing_down_bit, .acq_rel);
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
