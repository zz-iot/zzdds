//! Refcounted wrapper making listener replacement safe against a concurrently
//! in-flight callback dispatch.
//!
//! `vtSetListener`/`deinit` release a listener's native context (via
//! `listener_lifecycle.release`) the moment it's replaced or its owning
//! entity is destroyed. Dispatch sites read the listener struct *without*
//! holding the entity's mutex (to avoid holding a lock across a possibly
//! slow/reentrant user callback) — so without this, a replace/delete
//! concurrent with an in-flight dispatch can free a context (e.g. a JNI
//! global ref) the dispatch is still using.
//!
//! `ListenerBox(T)` fixes this with a small refcount: `acquireLocked` is
//! only ever called while already holding the entity's own mutex (the same
//! mutex that performs the swap on replace/delete), so there is no
//! ABA/use-after-free hazard from loading a box pointer and separately
//! trying to bump its refcount — if you observed the box under that lock,
//! it is still alive long enough to acquire it, full stop. This sidesteps
//! needing real lock-free reclamation (hazard pointers / atomic
//! `shared_ptr`) for what is a low-frequency operation (listener
//! replacement), while still never holding a lock across the callback
//! itself or across `listener_lifecycle.release`.
const std = @import("std");
const listener_lifecycle = @import("listener_lifecycle.zig");

pub fn ListenerBox(comptime T: type) type {
    return struct {
        const Self = @This();

        listener: T,
        refcount: std.atomic.Value(usize),

        /// Refcount starts at 1: the "installed" reference held by the
        /// owning entity's own `listener_box` field.
        pub fn create(alloc: std.mem.Allocator, listener: T) !*Self {
            const self = try alloc.create(Self);
            self.* = .{ .listener = listener, .refcount = .init(1) };
            return self;
        }

        /// Call while holding the owning entity's `mu`. Returns `self` for
        /// convenience; the caller may then release `mu` and safely read/
        /// dispatch through `.listener` until it calls `releaseRef`.
        pub fn acquireLocked(self: *Self) *Self {
            _ = self.refcount.fetchAdd(1, .monotonic);
            return self;
        }

        /// Call with no lock held: after finishing a dispatch acquired via
        /// `acquireLocked`, or to drop the "installed" reference during a
        /// swap/teardown. Frees the box — calling
        /// `listener_lifecycle.release` on its listener first — iff this was
        /// the last outstanding reference.
        pub fn releaseRef(self: *Self, alloc: std.mem.Allocator) void {
            if (self.refcount.fetchSub(1, .acq_rel) == 1) {
                listener_lifecycle.release(self.listener);
                alloc.destroy(self);
            }
        }
    };
}

const testing = std.testing;

test "ListenerBox: single installed reference releases immediately" {
    const Listener = struct {
        listener_data: ?*anyopaque = null,
        release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
    };
    var released: u32 = 0;
    const Static = struct {
        var counter: *u32 = undefined;
        fn release(_: ?*anyopaque) callconv(.c) void {
            counter.* += 1;
        }
    };
    Static.counter = &released;

    const box = try ListenerBox(Listener).create(testing.allocator, .{
        .release_listener_data = Static.release,
    });
    box.releaseRef(testing.allocator);
    try testing.expectEqual(@as(u32, 1), released);
}

test "ListenerBox: release only fires once, after the last outstanding acquire" {
    const Listener = struct {
        listener_data: ?*anyopaque = null,
        release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
    };
    var released: u32 = 0;
    const Static = struct {
        var counter: *u32 = undefined;
        fn release(_: ?*anyopaque) callconv(.c) void {
            counter.* += 1;
        }
    };
    Static.counter = &released;

    const box = try ListenerBox(Listener).create(testing.allocator, .{
        .release_listener_data = Static.release,
    });
    // Simulate a concurrently in-flight dispatch that acquired a ref before
    // the "installed" reference was dropped by a replace/delete.
    _ = box.acquireLocked();
    box.releaseRef(testing.allocator); // drops the "installed" ref -- not last
    try testing.expectEqual(@as(u32, 0), released);
    box.releaseRef(testing.allocator); // the in-flight dispatch finishing -- last
    try testing.expectEqual(@as(u32, 1), released);
}

test "ListenerBox: a null release_listener_data is a no-op, not a crash" {
    const Listener = struct {
        listener_data: ?*anyopaque = null,
        release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
    };
    const box = try ListenerBox(Listener).create(testing.allocator, .{});
    box.releaseRef(testing.allocator);
}
