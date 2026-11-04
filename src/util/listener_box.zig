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
const listener_identity = @import("listener_identity.zig");

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

pub fn ListenerBox(comptime T: type) type {
    return struct {
        const Self = @This();

        listener: T,
        refcount: std.atomic.Value(usize),
        /// Created at first use (see `identity`).
        ident: std.atomic.Value(?*listener_identity.Identity) = .init(null),

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

        /// Call with no lock held: after finishing a dispatch acquired via
        /// `acquireLocked`, or to drop the "installed" reference during a
        /// swap/teardown. Frees the box — calling
        /// `listener_lifecycle.release` on its listener first — iff this was
        /// the last outstanding reference.
        pub fn releaseRef(self: *Self, alloc: std.mem.Allocator) void {
            if (self.refcount.fetchSub(1, .acq_rel) == 1) {
                if (self.ident.load(.acquire)) |id| listener_identity.global.release(id);
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
    const Listener = struct {
        listener_data: ?*anyopaque = null,
        release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
    };
    const box = try ListenerBox(Listener).create(testing.allocator, .{});
    box.releaseRef(testing.allocator);
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
    defer a.releaseRef(testing.allocator);
    const b = try ListenerBox(Listener).create(testing.allocator, .{ .listener_data = &reg_b, .listener_identity = &object });
    defer b.releaseRef(testing.allocator);
    try testing.expect(a.identity().? == b.identity().?);
    // Without listener_identity, listener_data still names it.
    const c = try ListenerBox(Listener).create(testing.allocator, .{ .listener_data = &reg_a });
    defer c.releaseRef(testing.allocator);
    try testing.expect(c.identity().? != a.identity().?);
    try testing.expect(c.identity().?.key.ptr == @intFromPtr(&reg_a));
}
