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

    /// Weaker than `acquire()`: succeeds as long as the entity hasn't been
    /// *fully* torn down yet (refcount != 0), even if teardown has already
    /// *started* (the tearing-down bit is set) -- unlike `acquire()`, which
    /// refuses the instant teardown starts, regardless of whether the
    /// entity is still transiently alive waiting on some other outstanding
    /// reference to release. Racing this against a concurrent `release()`
    /// that's dropping the last reference is safe for the same reason
    /// `acquire()`'s own CAS loop is: the two atomic RMWs on `state` are
    /// mutually exclusive, so either this call's CAS lands first (count
    /// goes N -> N+1, the later `release()` then only takes it back to N,
    /// `on_last` never fires) or `release()`'s `fetchSub` lands first (count
    /// hits 0, `on_last` fires synchronously on *that* thread), in which
    /// case this call's next loop iteration re-reads the now-zero count and
    /// correctly fails -- there is no window where both observe a state
    /// that lets them each believe they safely "own" the entity.
    ///
    /// Use this only for an operation that's *always* safe to perform on a
    /// live-but-tearing-down entity (e.g. removing yourself from a list it
    /// still owns, itself guarded by a mutex independent of this refcount)
    /// -- never for anything that assumes the entity is in a fully
    /// initialized, steady-state condition (that's what `acquire()` is
    /// for). Getting this wrong reintroduces exactly the class of bug this
    /// type exists to prevent elsewhere -- don't add a new caller without
    /// confirming the operation it guards is genuinely that narrow.
    pub fn acquireIfAlive(self: *EntityQuiesce) bool {
        while (true) {
            const cur = self.state.load(.acquire);
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

test "EntityQuiesce: acquireIfAlive succeeds after teardown starts, as long as another reference is still outstanding" {
    // Regression for a real race Greptile flagged on zzdds PR #60: WaitSet's
    // condition-invalidation callback used plain acquire() here, which
    // (correctly, by design) refuses the instant teardown starts -- but
    // that meant a *second* condition tearing down concurrently, after the
    // WaitSet's own deinit() had already set the tearing-down bit but
    // *before* refcount reached zero (a first, still-in-flight condition
    // holding the last reference), could never successfully invalidate
    // itself out of the WaitSet's tracking list, leaving a dangling entry
    // for reallyDeinit() to dereference later.
    var q = EntityQuiesce{};
    var calls: u32 = 0;
    const Static = struct {
        var counter: *u32 = undefined;
        fn onLast(_: *anyopaque) void {
            counter.* += 1;
        }
    };
    Static.counter = &calls;

    // Simulate the first, already-in-flight reference (e.g. condition A's
    // own drain() having already acquired).
    try testing.expect(q.acquire());
    // The entity's own deinit() begins teardown concurrently -- not the
    // last ref (A's callback still holds its own), so on_last doesn't fire.
    q.beginTeardown(&q, Static.onLast);
    try testing.expectEqual(@as(u32, 0), calls);

    // A late-arriving acquire() (condition B's own drain()) correctly fails
    // -- this is the existing, unchanged, stricter behavior.
    try testing.expect(!q.acquire());
    // But acquireIfAlive() succeeds: the entity is still alive (A's
    // reference proves it), even though teardown has started.
    try testing.expect(q.acquireIfAlive());
    try testing.expectEqual(@as(u32, 0), calls);

    // Both in-flight references release -- the second (acquireIfAlive's)
    // isn't last, the first (A's) is.
    q.release(&q, Static.onLast);
    try testing.expectEqual(@as(u32, 0), calls);
    q.release(&q, Static.onLast);
    try testing.expectEqual(@as(u32, 1), calls);
}

test "EntityQuiesce: acquireIfAlive fails once the entity is fully torn down" {
    var q = EntityQuiesce{};
    var calls: u32 = 0;
    const Static = struct {
        var counter: *u32 = undefined;
        fn onLast(_: *anyopaque) void {
            counter.* += 1;
        }
    };
    Static.counter = &calls;
    // Nothing in flight -- beginTeardown() drops the only reference itself,
    // running on_last synchronously right here.
    q.beginTeardown(&q, Static.onLast);
    try testing.expectEqual(@as(u32, 1), calls);
    // The entity is genuinely gone now (in a real caller, `q` itself would
    // have been freed by on_last) -- acquireIfAlive() must refuse just like
    // acquire() does, not just "as long as teardown hasn't started."
    try testing.expect(!q.acquireIfAlive());
}
