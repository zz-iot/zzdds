//! Listener identity exclusion
//! (docs/design/concurrency/listeners.md#canonical-identity-requirements):
//! automatic invocations of one application listener never overlap, across
//! the entities it is installed on and the runtimes they use.
//!
//! An identity is a registration's non-null `listener_data`, shared by every
//! registration passing the same pointer, or the registration itself when it
//! passes null. A binding makes the pointer consistent for one application
//! object; the core never looks past it.
//!
//! Each identity has one execution right. A turn that finds it taken queues
//! a `Waiter` and returns rather than blocking; the holder's release hands
//! the right to the oldest waiter, so a later arrival cannot overtake it.
//! Records are looked up when a registration first needs one, not on each
//! invocation.

const std = @import("std");
const Mutex = @import("mutex.zig").Mutex;

/// The process's registry: one identity domain per loaded core.
pub var global: Registry = .{};

pub const Key = struct {
    ptr: usize,
    kind: enum(u8) {
        /// An application's `listener_data`.
        context,
        /// A registration whose `listener_data` is null: never shared, so
        /// never in the table.
        registration,
    },
};

/// A queued claim on an identity's execution right.
pub const Waiter = struct {
    next: ?*Waiter = null,
    /// Called once the right is the waiter's, with no lock held.
    grant: *const fn (w: *Waiter) void,
};

pub const Identity = struct {
    key: Key,
    /// References from registrations, holders and waiters. Only a release
    /// holding the record's stripe lock takes it to zero.
    refs: std.atomic.Value(u32) = .init(1),
    mu: Mutex = .{},
    // Guarded by `mu`.
    held: bool = false,
    head: ?*Waiter = null,
    tail: ?*Waiter = null,
    /// Queued waiters; read by tests.
    waiters: u32 = 0,

    /// Adds a reference. The caller already holds one.
    pub fn retain(self: *Identity) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Takes the execution right if it is free. Otherwise queues `w`, which
    /// is granted it in arrival order, and returns false.
    pub fn tryAcquire(self: *Identity, w: *Waiter) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.held) {
            self.held = true;
            return true;
        }
        w.next = null;
        if (self.tail) |t| t.next = w else self.head = w;
        self.tail = w;
        self.waiters += 1;
        return false;
    }

    /// Takes the execution right if it is free, queueing nothing.
    pub fn tryTake(self: *Identity) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.held) return false;
        self.held = true;
        return true;
    }

    /// Gives up the execution right: to the oldest waiter, if any.
    pub fn releaseRight(self: *Identity) void {
        self.mu.lock();
        std.debug.assert(self.held);
        const w = self.head orelse {
            self.held = false;
            self.mu.unlock();
            return;
        };
        self.head = w.next;
        if (self.head == null) self.tail = null;
        w.next = null;
        self.waiters -= 1;
        self.mu.unlock();
        w.grant(w);
    }

    /// Removes `w` if it is still queued. False: it has been granted the
    /// right, or was never queued.
    pub fn cancel(self: *Identity, w: *Waiter) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var prev: ?*Waiter = null;
        var it = self.head;
        while (it) |x| : ({
            prev = x;
            it = x.next;
        }) {
            if (x != w) continue;
            if (prev) |p| p.next = x.next else self.head = x.next;
            if (self.tail == x) self.tail = prev;
            x.next = null;
            self.waiters -= 1;
            return true;
        }
        return false;
    }

    /// Queued waiters, for tests.
    pub fn waiting(self: *Identity) u32 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.waiters;
    }
};

pub const Registry = struct {
    stripes: [stripe_count]Stripe = @splat(.{}),
    /// Allocates records: never an entity's allocator.
    alloc: std.mem.Allocator = std.heap.smp_allocator,
    /// Records alive; read by tests.
    live: std.atomic.Value(usize) = .init(0),

    const stripe_count = 64;

    const Stripe = struct {
        mu: Mutex = .{},
        map: std.AutoHashMapUnmanaged(Key, *Identity) = .empty,
    };

    /// For a registry other than `global` once its records are released.
    pub fn deinit(self: *Registry) void {
        std.debug.assert(self.live.load(.monotonic) == 0);
        for (&self.stripes) |*s| {
            s.map.deinit(self.alloc);
            s.mu.deinit();
        }
    }

    /// A reference to `key`'s record, created if it has none.
    pub fn retain(self: *Registry, key: Key) error{OutOfMemory}!*Identity {
        if (key.kind == .registration) return self.create(key);
        const s = self.stripe(key);
        s.mu.lock();
        defer s.mu.unlock();
        const gop = try s.map.getOrPut(self.alloc, key);
        if (gop.found_existing) {
            gop.value_ptr.*.retain();
            return gop.value_ptr.*;
        }
        gop.value_ptr.* = self.create(key) catch |err| {
            s.map.removeByPtr(gop.key_ptr);
            return err;
        };
        return gop.value_ptr.*;
    }

    /// Drops a reference, freeing the record with the last.
    pub fn release(self: *Registry, id: *Identity) void {
        if (id.key.kind == .registration) {
            if (id.refs.fetchSub(1, .acq_rel) == 1) self.destroy(id);
            return;
        }
        // Lock-free unless this may be the last: a lookup under the stripe
        // lock can then still revive it.
        var r = id.refs.load(.monotonic);
        while (r > 1) r = id.refs.cmpxchgWeak(r, r - 1, .acq_rel, .monotonic) orelse return;
        const s = self.stripe(id.key);
        s.mu.lock();
        if (id.refs.fetchSub(1, .acq_rel) != 1) {
            s.mu.unlock();
            return;
        }
        _ = s.map.remove(id.key);
        s.mu.unlock();
        self.destroy(id);
    }

    fn stripe(self: *Registry, key: Key) *Stripe {
        // Allocations are aligned: the low bits carry nothing.
        return &self.stripes[(key.ptr >> 4) % stripe_count];
    }

    fn create(self: *Registry, key: Key) error{OutOfMemory}!*Identity {
        const id = try self.alloc.create(Identity);
        id.* = .{ .key = key };
        _ = self.live.fetchAdd(1, .monotonic);
        return id;
    }

    fn destroy(self: *Registry, id: *Identity) void {
        std.debug.assert(!id.held and id.head == null);
        id.mu.deinit();
        self.alloc.destroy(id);
        _ = self.live.fetchSub(1, .monotonic);
    }
};

const testing = std.testing;

const Probe = struct {
    w: Waiter = .{ .grant = grant },
    i: u8,
    log: *std.ArrayListUnmanaged(u8),

    fn grant(w: *Waiter) void {
        const self: *Probe = @fieldParentPtr("w", w);
        self.log.append(testing.allocator, self.i) catch unreachable;
    }
};

test "listener_identity: the same context shares a record; null registrations never do" {
    var reg: Registry = .{ .alloc = testing.allocator };
    defer reg.deinit();
    var data: u32 = 0;
    const a = try reg.retain(.{ .ptr = @intFromPtr(&data), .kind = .context });
    const b = try reg.retain(.{ .ptr = @intFromPtr(&data), .kind = .context });
    try testing.expectEqual(a, b);
    const c = try reg.retain(.{ .ptr = @intFromPtr(&data), .kind = .registration });
    try testing.expect(c != a);
    try testing.expectEqual(@as(usize, 2), reg.live.load(.monotonic));
    reg.release(a);
    reg.release(c);
    try testing.expectEqual(@as(usize, 1), reg.live.load(.monotonic));
    reg.release(b);
    try testing.expectEqual(@as(usize, 0), reg.live.load(.monotonic));
    // Freed with its last reference, a key starts a new record.
    const d = try reg.retain(.{ .ptr = @intFromPtr(&data), .kind = .context });
    reg.release(d);
    try testing.expectEqual(@as(usize, 0), reg.live.load(.monotonic));
}

test "listener_identity: the right passes to waiters in arrival order, skipping a cancelled one" {
    var reg: Registry = .{ .alloc = testing.allocator };
    defer reg.deinit();
    const id = try reg.retain(.{ .ptr = 0x1000, .kind = .context });
    defer reg.release(id);
    var log: std.ArrayListUnmanaged(u8) = .empty;
    defer log.deinit(testing.allocator);
    var holder: Probe = .{ .i = 9, .log = &log };
    var probes: [3]Probe = .{ .{ .i = 0, .log = &log }, .{ .i = 1, .log = &log }, .{ .i = 2, .log = &log } };

    try testing.expect(id.tryAcquire(&holder.w));
    for (&probes) |*p| try testing.expect(!id.tryAcquire(&p.w));
    try testing.expectEqual(@as(u32, 3), id.waiting());
    try testing.expect(id.cancel(&probes[1].w));
    try testing.expect(!id.cancel(&probes[1].w));

    id.releaseRight();
    try testing.expectEqualSlices(u8, &.{0}, log.items);
    id.releaseRight();
    try testing.expectEqualSlices(u8, &.{ 0, 2 }, log.items);
    id.releaseRight();
    try testing.expectEqual(@as(u32, 0), id.waiting());
    // Free again: the next caller takes it at once.
    try testing.expect(id.tryAcquire(&holder.w));
    id.releaseRight();
    try testing.expectEqualSlices(u8, &.{ 0, 2 }, log.items);
}
