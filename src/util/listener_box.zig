//! Refcounted listener registrations: replacement safe against a
//! concurrently in-flight callback dispatch, and a setter that can wait for
//! the callbacks of the registrations it retired
//! (docs/design/concurrency/listeners.md#replacement-completion).
//!
//! Dispatch sites read the listener struct *without* holding the entity's
//! mutex (to avoid holding a lock across a possibly slow/reentrant user
//! callback). Each dispatch is a *use* of the registration's box, taken with
//! `acquireLocked` under the entity's listener lock (the lock a replacement
//! swaps under, so a box observed there is alive long enough to take) and
//! ended with `releaseRef`. The entity's installed reference, a retired
//! registration's place on its entity's `Retired` list and a waiting
//! setter's reference are *holds*: they keep the box allocated without
//! counting as callbacks in progress.
//!
//! A registration's native context is released (`listener_lifecycle.release`)
//! once nothing can call it again: when its last use ends after it is
//! retired, or when the last reference of any kind goes. The box itself is
//! freed with its last reference.
const std = @import("std");
const listener_lifecycle = @import("listener_lifecycle.zig");
const listener_identity = @import("listener_identity.zig");
const Mutex = @import("mutex.zig").Mutex;
const Condvar = @import("condvar.zig").Condvar;

/// What a `get_listener` returns for the installed `listener`: the same
/// registration, retained for the caller when it asks for that
/// (`retain_listener_data`). The caller then owns that reference and drops it
/// with `release_listener_data`, so a concurrent replacement releasing the
/// installed reference cannot free the registration under it. Call while
/// holding the entity's listener lock, so `listener` is still installed.
pub fn handOut(listener: anytype) @TypeOf(listener) {
    if (listener.retain_listener_data) |retain| {
        if (listener.listener_data != null) retain(listener.listener_data);
    }
    return listener;
}

// ── Callback chains ──────────────────────────────────────────────────────────

/// Listener calls on this thread's stack. The shared runtime also counts its
/// turns (dcps/listener_lane.zig's `inCallbackChain`); this covers the
/// threaded runtime, which calls listeners inline.
threadlocal var calls: u32 = 0;

/// Around every call into an application listener.
pub fn enterCall() void {
    calls += 1;
}

pub fn leaveCall() void {
    calls -= 1;
}

/// Whether this thread is inside a listener call.
pub fn inCall() bool {
    return calls > 0;
}

// ── Waiting for a retired registration's callbacks ───────────────────────────

// One lock and condition for every box: replacement is rare, and a broadcast
// wakes every waiter to check its own box.
var wait_mu: Mutex = .{};
var wait_cv: Condvar = .{};
var waiters: std.atomic.Value(u32) = .init(0);

/// Setters waiting for a retired registration's callbacks, for tests that
/// release a callback only once a setter waits for it.
pub fn waitingSetters() u32 {
    return waiters.load(.seq_cst);
}

fn wakeWaiters() void {
    if (waiters.load(.seq_cst) == 0) return;
    wait_mu.lock();
    wait_cv.broadcast();
    wait_mu.unlock();
}

// A box's state, one word so it is read as a consistent whole: uses in the
// low bits, holds above them, then two flags.
const USE: u64 = 1;
const HOLD: u64 = 1 << 32;
const COUNT_MASK: u64 = (1 << 30) - 1;
/// Replaced: no dispatch can take a new use.
const RETIRED: u64 = 1 << 62;
/// The native context is released.
const RELEASED: u64 = 1 << 63;

fn usesOf(s: u64) u64 {
    return s & COUNT_MASK;
}

fn holdsOf(s: u64) u64 {
    return (s >> 32) & COUNT_MASK;
}

pub fn ListenerBox(comptime T: type) type {
    return struct {
        const Self = @This();

        listener: T,
        state: std.atomic.Value(u64),
        /// Created at first use (see `identity`).
        ident: std.atomic.Value(?*listener_identity.Identity) = .init(null),
        /// The next older registration on the entity's `Retired` list,
        /// guarded by the entity's listener lock.
        next_retired: ?*Self = null,
        /// Its place in the entity's retirement order, set when retired.
        retired_seq: u64 = 0,

        /// Starts with one hold: the owning entity's installed reference.
        pub fn create(alloc: std.mem.Allocator, listener: T) !*Self {
            const self = try alloc.create(Self);
            self.* = .{ .listener = listener, .state = .init(HOLD) };
            return self;
        }

        /// Takes a use: a dispatch through `.listener`, ended with
        /// `releaseRef`. Call while holding the owning entity's listener
        /// lock, with this box installed. Returns `self` for convenience.
        pub fn acquireLocked(self: *Self) *Self {
            _ = self.state.fetchAdd(USE, .monotonic);
            return self;
        }

        /// The listener's exclusion identity (listener_identity.zig): its
        /// `listener_identity`, else its `listener_data`, else this
        /// registration. Null without memory to record it. Call while
        /// holding a reference.
        pub fn identity(self: *Self) ?*listener_identity.Identity {
            if (self.ident.load(.acquire)) |id| return id;
            const explicit: ?*anyopaque = if (@hasField(T, "listener_identity")) self.listener.listener_identity else null;
            const data: ?*anyopaque = explicit orelse self.listener.listener_data;
            const key: listener_identity.Key = if (data) |d|
                .{ .ptr = @intFromPtr(d), .kind = .context }
            else
                .{ .ptr = @intFromPtr(self), .kind = .registration };
            const id = listener_identity.global.retain(key) catch return null;
            if (self.ident.cmpxchgStrong(null, id, .acq_rel, .acquire)) |won| {
                listener_identity.global.release(id);
                return won;
            }
            return id;
        }

        /// Ends a use taken with `acquireLocked`. Call with no lock held.
        pub fn releaseRef(self: *Self, alloc: std.mem.Allocator) void {
            var s = self.state.load(.seq_cst);
            const prev = while (true) {
                std.debug.assert(usesOf(s) > 0);
                if (s & RETIRED != 0 and s & RELEASED == 0 and usesOf(s) == 1) {
                    // The last use of a retired registration releases its
                    // context while it still holds that use, so the box
                    // outlives the hook. A retired box takes no new use.
                    if (self.state.cmpxchgWeak(s, s | RELEASED, .seq_cst, .seq_cst)) |cur| {
                        s = cur;
                        continue;
                    }
                    releaseContext(self.listener);
                    break self.state.fetchSub(USE, .seq_cst);
                }
                // Decrementing in the step that saw the count keeps two last
                // uses from each leaving the release to the other.
                s = self.state.cmpxchgWeak(s, s - USE, .seq_cst, .seq_cst) orelse break s;
            };
            if (usesOf(prev) != 1) return;
            if (holdsOf(prev) == 0) return self.destroy(alloc, prev);
            // Not the last reference: someone else frees the box, and this
            // touches only the shared wait state.
            wakeWaiters();
        }

        /// Takes a hold. Call while holding the owning entity's listener
        /// lock, with this box installed or on its `Retired` list.
        pub fn retainHold(self: *Self) void {
            _ = self.state.fetchAdd(HOLD, .monotonic);
        }

        /// Drops a hold: the installed reference at the entity's teardown,
        /// a `Retired` entry, or a waiter's. Call with no lock held.
        pub fn releaseHold(self: *Self, alloc: std.mem.Allocator) void {
            const prev = self.state.fetchSub(HOLD, .acq_rel);
            std.debug.assert(holdsOf(prev) > 0);
            if (holdsOf(prev) == 1 and usesOf(prev) == 0) self.destroy(alloc, prev);
        }

        /// Whether no dispatch is using it.
        pub fn idle(self: *Self) bool {
            return usesOf(self.state.load(.acquire)) == 0;
        }

        /// Blocks until no dispatch is using it. Call with a hold and no
        /// lock held, outside every callback chain.
        fn awaitIdle(self: *Self) void {
            if (self.idle()) return;
            _ = waiters.fetchAdd(1, .seq_cst);
            defer _ = waiters.fetchSub(1, .seq_cst);
            wait_mu.lock();
            defer wait_mu.unlock();
            while (usesOf(self.state.load(.seq_cst)) > 0) wait_cv.wait(&wait_mu);
        }

        /// Runs the release hook as a listener call: it is application
        /// code, and a setter it calls must not wait, for instance for the
        /// use whose end is running it.
        fn releaseContext(listener: T) void {
            enterCall();
            defer leaveCall();
            listener_lifecycle.release(listener);
        }

        fn destroy(self: *Self, alloc: std.mem.Allocator, last: u64) void {
            if (last & RELEASED == 0) releaseContext(self.listener);
            if (self.ident.load(.acquire)) |id| listener_identity.global.release(id);
            alloc.destroy(self);
        }
    };
}

/// An entity's retired registrations whose callbacks may still be running,
/// newest first, linked through `ListenerBox.next_retired` (no allocation).
/// Guarded by the entity's listener lock. Each entry holds its box.
pub fn Retired(comptime T: type) type {
    return struct {
        const Self = @This();
        const Box = ListenerBox(T);

        head: ?*Box = null,
        seq: u64 = 0,

        /// Installs `new_box` in `slot` under `mu` and retires the box it
        /// replaces, whose installed hold the list takes over. Returns the
        /// retirement's place in order, for `drain`.
        pub fn install(self: *Self, mu: *Mutex, slot: **Box, new_box: *Box) u64 {
            mu.lock();
            defer mu.unlock();
            const old = slot.*;
            slot.* = new_box;
            self.seq += 1;
            old.retired_seq = self.seq;
            _ = old.state.fetchOr(RETIRED, .acq_rel);
            old.next_retired = self.head;
            self.head = old;
            return self.seq;
        }

        /// Drops the retired registrations no dispatch is using. When
        /// `wait`, first waits until no dispatch uses any registration
        /// retired up to `upto`; registrations retired after it do not
        /// extend the wait. Pass `wait` only outside every callback chain,
        /// where waiting cannot wait on itself or on a callback waiting for
        /// it. Call with no lock held.
        pub fn drain(self: *Self, alloc: std.mem.Allocator, mu: *Mutex, upto: u64, wait: bool) void {
            while (true) {
                var done: ?*Box = null;
                var busy: ?*Box = null;
                mu.lock();
                var link: *?*Box = &self.head;
                while (link.*) |b| {
                    if (b.idle()) {
                        link.* = b.next_retired;
                        b.next_retired = done;
                        done = b;
                    } else {
                        if (busy == null and b.retired_seq <= upto) busy = b;
                        link = &b.next_retired;
                    }
                }
                if (!wait) busy = null;
                if (busy) |b| b.retainHold();
                mu.unlock();
                // Release hooks may run application code: no lock held.
                while (done) |b| {
                    done = b.next_retired;
                    b.releaseHold(alloc);
                }
                const b = busy orelse return;
                b.awaitIdle();
                b.releaseHold(alloc);
            }
        }

        /// For the entity's teardown: drops every entry.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            while (self.head) |b| {
                self.head = b.next_retired;
                b.releaseHold(alloc);
            }
        }
    };
}

const testing = std.testing;

const TestListener = struct {
    listener_data: ?*anyopaque = null,
    release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

/// Counts `release_listener_data` calls on a `u32` passed as `listener_data`.
fn countRelease(data: ?*anyopaque) callconv(.c) void {
    const n: *std.atomic.Value(u32) = @ptrCast(@alignCast(data.?));
    _ = n.fetchAdd(1, .seq_cst);
}

test "ListenerBox: single installed reference releases immediately" {
    var released: std.atomic.Value(u32) = .init(0);
    const box = try ListenerBox(TestListener).create(testing.allocator, .{
        .listener_data = &released,
        .release_listener_data = countRelease,
    });
    box.releaseHold(testing.allocator);
    try testing.expectEqual(@as(u32, 1), released.load(.seq_cst));
}

test "ListenerBox: release only fires once, after the last outstanding acquire" {
    var released: std.atomic.Value(u32) = .init(0);
    const box = try ListenerBox(TestListener).create(testing.allocator, .{
        .listener_data = &released,
        .release_listener_data = countRelease,
    });
    // A dispatch that acquired a use before the installed hold was dropped.
    _ = box.acquireLocked();
    box.releaseHold(testing.allocator); // the entity's teardown: not last
    try testing.expectEqual(@as(u32, 0), released.load(.seq_cst));
    box.releaseRef(testing.allocator); // the dispatch finishing: last
    try testing.expectEqual(@as(u32, 1), released.load(.seq_cst));
}

test "Retired: an idle replaced registration is released by the replacement" {
    var mu: Mutex = .{};
    var released: std.atomic.Value(u32) = .init(0);
    var slot = try ListenerBox(TestListener).create(testing.allocator, .{
        .listener_data = &released,
        .release_listener_data = countRelease,
    });
    var retired: Retired(TestListener) = .{};
    const upto = retired.install(&mu, &slot, try ListenerBox(TestListener).create(testing.allocator, .{}));
    retired.drain(testing.allocator, &mu, upto, true);
    try testing.expectEqual(@as(u32, 1), released.load(.seq_cst));
    try testing.expect(retired.head == null);
    slot.releaseHold(testing.allocator);
}

test "Retired: a busy replaced registration is released by its last use, not the list" {
    var mu: Mutex = .{};
    var released: std.atomic.Value(u32) = .init(0);
    var slot = try ListenerBox(TestListener).create(testing.allocator, .{
        .listener_data = &released,
        .release_listener_data = countRelease,
    });
    const old = slot;
    mu.lock();
    _ = old.acquireLocked();
    mu.unlock();
    var retired: Retired(TestListener) = .{};
    const upto = retired.install(&mu, &slot, try ListenerBox(TestListener).create(testing.allocator, .{}));
    // From a callback chain: no wait, and the busy entry stays listed.
    retired.drain(testing.allocator, &mu, upto, false);
    try testing.expect(retired.head == old);
    try testing.expectEqual(@as(u32, 0), released.load(.seq_cst));
    // Its last use releases the context at once; the list frees the box.
    old.releaseRef(testing.allocator);
    try testing.expectEqual(@as(u32, 1), released.load(.seq_cst));
    retired.drain(testing.allocator, &mu, upto, false);
    try testing.expect(retired.head == null);
    try testing.expectEqual(@as(u32, 1), released.load(.seq_cst));
    slot.releaseHold(testing.allocator);
}

test "Retired: of two uses of a replaced registration, the last releases the context" {
    var mu: Mutex = .{};
    var released: std.atomic.Value(u32) = .init(0);
    var slot = try ListenerBox(TestListener).create(testing.allocator, .{
        .listener_data = &released,
        .release_listener_data = countRelease,
    });
    const old = slot;
    mu.lock();
    _ = old.acquireLocked();
    _ = old.acquireLocked();
    mu.unlock();
    var retired: Retired(TestListener) = .{};
    _ = retired.install(&mu, &slot, try ListenerBox(TestListener).create(testing.allocator, .{}));
    old.releaseRef(testing.allocator);
    try testing.expectEqual(@as(u32, 0), released.load(.seq_cst));
    // Released by the last use, not left for the list to drop.
    old.releaseRef(testing.allocator);
    try testing.expectEqual(@as(u32, 1), released.load(.seq_cst));
    retired.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), released.load(.seq_cst));
    slot.releaseHold(testing.allocator);
}

test "ListenerBox: a release hook runs as a listener call" {
    const S = struct {
        var in_call: bool = false;
        fn release(_: ?*anyopaque) callconv(.c) void {
            in_call = inCall();
        }
    };
    var mu: Mutex = .{};
    var slot = try ListenerBox(TestListener).create(testing.allocator, .{ .release_listener_data = S.release });
    const old = slot;
    mu.lock();
    _ = old.acquireLocked();
    mu.unlock();
    var retired: Retired(TestListener) = .{};
    _ = retired.install(&mu, &slot, try ListenerBox(TestListener).create(testing.allocator, .{}));
    // The last use's release, from no callback: the hook is in one.
    try testing.expect(!inCall());
    old.releaseRef(testing.allocator);
    try testing.expect(S.in_call);
    try testing.expect(!inCall());
    retired.deinit(testing.allocator);
    slot.releaseHold(testing.allocator);
}

/// Until a `drain` on another thread waits for a use to end.
fn awaitWaitingSetter() void {
    while (waitingSetters() == 0) std.Thread.yield() catch {};
}

test "Retired: drain waits for a use of a replaced registration to end" {
    var mu: Mutex = .{};
    var released: std.atomic.Value(u32) = .init(0);
    var slot = try ListenerBox(TestListener).create(testing.allocator, .{
        .listener_data = &released,
        .release_listener_data = countRelease,
    });
    const old = slot;
    mu.lock();
    _ = old.acquireLocked();
    mu.unlock();
    var retired: Retired(TestListener) = .{};
    const upto = retired.install(&mu, &slot, try ListenerBox(TestListener).create(testing.allocator, .{}));

    const Ender = struct {
        fn run(box: *ListenerBox(TestListener), rel: *std.atomic.Value(u32)) void {
            awaitWaitingSetter();
            // drain waits: the context is not released yet.
            std.debug.assert(rel.load(.seq_cst) == 0);
            box.releaseRef(testing.allocator);
        }
    };
    const t = try std.Thread.spawn(.{}, Ender.run, .{ old, &released });
    retired.drain(testing.allocator, &mu, upto, true);
    try testing.expectEqual(@as(u32, 1), released.load(.seq_cst));
    try testing.expect(retired.head == null);
    t.join();
    slot.releaseHold(testing.allocator);
}

test "Retired: drain waits for earlier retirements, not later ones" {
    var mu: Mutex = .{};
    var slot = try ListenerBox(TestListener).create(testing.allocator, .{});
    const a = slot;
    mu.lock();
    _ = a.acquireLocked();
    mu.unlock();
    var retired: Retired(TestListener) = .{};
    // A is replaced by B (say from A's own callback), and A keeps running.
    _ = retired.install(&mu, &slot, try ListenerBox(TestListener).create(testing.allocator, .{}));
    const b = slot;
    mu.lock();
    _ = b.acquireLocked();
    mu.unlock();
    // Another thread clears B: its wait covers A too.
    const upto = retired.install(&mu, &slot, try ListenerBox(TestListener).create(testing.allocator, .{}));
    // C, installed after that clear, is replaced and busy: no wait for it.
    const c = slot;
    mu.lock();
    _ = c.acquireLocked();
    mu.unlock();
    _ = retired.install(&mu, &slot, try ListenerBox(TestListener).create(testing.allocator, .{}));

    const Ender = struct {
        fn run(x: *ListenerBox(TestListener), y: *ListenerBox(TestListener)) void {
            awaitWaitingSetter();
            x.releaseRef(testing.allocator);
            y.releaseRef(testing.allocator);
        }
    };
    const t = try std.Thread.spawn(.{}, Ender.run, .{ b, a });
    retired.drain(testing.allocator, &mu, upto, true);
    // Only C is left, still busy.
    try testing.expect(retired.head == c and c.next_retired == null);
    t.join();
    c.releaseRef(testing.allocator);
    retired.deinit(testing.allocator);
    slot.releaseHold(testing.allocator);
}

test "handOut retains a registration that asks for it, and only one that does" {
    const S = struct {
        var retained: u32 = 0;
        fn retain(_: ?*anyopaque) callconv(.c) void {
            retained += 1;
        }
    };
    const Listener = struct {
        listener_data: ?*anyopaque = null,
        retain_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
    };
    var reg: u8 = 0;
    const out = handOut(Listener{ .listener_data = &reg, .retain_listener_data = S.retain });
    try testing.expect(out.listener_data == @as(?*anyopaque, &reg));
    try testing.expectEqual(@as(u32, 1), S.retained);
    // No hook (a raw C/Zig registration), or no listener: nothing to retain.
    _ = handOut(Listener{ .listener_data = &reg });
    _ = handOut(Listener{ .retain_listener_data = S.retain });
    try testing.expectEqual(@as(u32, 1), S.retained);
}

test "ListenerBox: a null release_listener_data is a no-op, not a crash" {
    const box = try ListenerBox(TestListener).create(testing.allocator, .{});
    box.releaseHold(testing.allocator);
}

test "ListenerBox: listener_identity, when set, names the identity rather than listener_data" {
    const Listener = struct {
        listener_data: ?*anyopaque = null,
        release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
        listener_identity: ?*anyopaque = null,
    };
    var object: u8 = 0;
    var reg_a: u8 = 0;
    var reg_b: u8 = 0;
    // Two registrations of one object, each with its own listener_data (as
    // the C++ binding's owning references are): one identity.
    const a = try ListenerBox(Listener).create(testing.allocator, .{ .listener_data = &reg_a, .listener_identity = &object });
    defer a.releaseHold(testing.allocator);
    const b = try ListenerBox(Listener).create(testing.allocator, .{ .listener_data = &reg_b, .listener_identity = &object });
    defer b.releaseHold(testing.allocator);
    try testing.expect(a.identity().? == b.identity().?);
    // Without listener_identity, listener_data still names it.
    const c = try ListenerBox(Listener).create(testing.allocator, .{ .listener_data = &reg_a });
    defer c.releaseHold(testing.allocator);
    try testing.expect(c.identity().? != a.identity().?);
    try testing.expect(c.identity().?.key.ptr == @intFromPtr(&reg_a));
}
