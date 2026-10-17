//! Shared "nearest enclosing non-null listener" dispatch (DDS 1.4
//! §2.2.4.1.5, "Listener Access to Plain Communication Status").
//!
//! Every entity's own listener dispatch already gates on
//! `self.listener_mask & bit != 0` before even considering the callback
//! field; this generalizes that exact check into a reusable comptime-over-
//! field-name helper so a caller walking reader -> subscriber -> participant
//! (or writer -> publisher -> participant) doesn't have to hand-write the
//! same two-part check at every level for every status.
//!
//! Kept generic over the concrete Listener struct type (and therefore free
//! of any `zzdds_generated` import) since DataReaderListener/
//! SubscriberListener/DomainParticipantListener are three distinct types
//! that merely happen to share field names/signatures for a given status —
//! see dcps.idl's widening chain (SubscriberListener : DataReaderListener,
//! DomainParticipantListener : ... SubscriberListener, ...).
const std = @import("std");

/// If `mask & bit != 0` and `listener`'s `field` is a non-null callback,
/// invokes it as `cb(handle, args..., listener.listener_data)` — matching
/// every generated Listener struct's own calling convention (the trailing
/// `listener_data` is never part of `args`; it's read from `listener`
/// itself since it belongs to whichever level's listener actually fires) —
/// and returns `true`. Returns `false`, with no side effects, if this level
/// has no usable listener for `field`, signaling the caller to fall back to
/// the next-enclosing entity.
pub fn tryDispatch(
    comptime field: []const u8,
    mask: anytype,
    bit: @TypeOf(mask),
    listener: anytype,
    handle: anytype,
    args: anytype,
) bool {
    if (mask & bit == 0) return false;
    if (@field(listener, field)) |cb| {
        @call(.auto, cb, .{handle} ++ args ++ .{listener.listener_data});
        return true;
    }
    return false;
}

/// Same gating as `tryDispatch` but returns the callback instead of
/// invoking it, for callers that must resolve which level's listener wins
/// while a lock is held and defer the actual call until after releasing it
/// (see `subscriber.zig`'s coherent-access batch dispatch). Returns `null`
/// if this level has no usable listener for `field`.
pub fn peek(
    comptime field: []const u8,
    mask: anytype,
    bit: @TypeOf(mask),
    listener: anytype,
) @TypeOf(@field(listener, field)) {
    if (mask & bit == 0) return null;
    return @field(listener, field);
}

/// The callback type of `Listener`'s `field`.
pub fn Callback(comptime Listener: type, comptime field: []const u8) type {
    return @typeInfo(@FieldType(Listener, field)).optional.child;
}

/// One level's callback, resolved from the fallback chain but not invoked,
/// so a status can be claimed (snapshotted and reset) under the entity's
/// lock and the callback run after releasing it (see
/// `docs/design/concurrency/listeners.md#status-ordering-requirements`).
/// Holds a reference on the winning level's listener box, and optionally a
/// pin on a parent entity's lifetime, until `release`. Call `release` with
/// no lock held: dropping the last box reference runs the listener's
/// release hook.
pub fn Resolved(comptime Cb: type) type {
    return struct {
        const Self = @This();

        cb: Cb,
        listener_data: ?*anyopaque,
        box: *anyopaque,
        box_alloc: std.mem.Allocator,
        box_release: *const fn (box: *anyopaque, alloc: std.mem.Allocator) void,
        pin_ctx: ?*anyopaque = null,
        pin_release: ?*const fn (ctx: *anyopaque) void = null,

        /// Invokes the callback as `cb(handle, args..., listener_data)`, as
        /// `tryDispatch` does.
        pub fn invoke(self: Self, handle: anytype, args: anytype) void {
            @call(.auto, self.cb, .{handle} ++ args ++ .{self.listener_data});
        }

        pub fn release(self: Self) void {
            self.box_release(self.box, self.box_alloc);
            if (self.pin_release) |f| f(self.pin_ctx.?);
        }

        /// This resolution, additionally pinning a parent's lifetime that
        /// `pin_release(ctx)` drops.
        pub fn pinned(self: Self, ctx: *anyopaque, pin_release: *const fn (ctx: *anyopaque) void) Self {
            std.debug.assert(self.pin_release == null);
            var out = self;
            out.pin_ctx = ctx;
            out.pin_release = pin_release;
            return out;
        }
    };
}

/// `box`'s (an acquired `*ListenerBox(T)`) callback for `field` as a
/// `Resolved(Cb)`, keeping the box reference, if `mask & bit != 0` and the
/// callback is set. Otherwise releases the box and returns null, signaling
/// the caller to try the next-enclosing entity.
pub fn resolveBox(
    comptime Cb: type,
    comptime field: []const u8,
    mask: anytype,
    bit: @TypeOf(mask),
    box: anytype,
    alloc: std.mem.Allocator,
) ?Resolved(Cb) {
    const Box = @TypeOf(box);
    const cb: Cb = peek(field, mask, bit, box.listener) orelse {
        box.releaseRef(alloc);
        return null;
    };
    return .{
        .cb = cb,
        .listener_data = box.listener.listener_data,
        .box = box,
        .box_alloc = alloc,
        .box_release = struct {
            fn f(b: *anyopaque, a: std.mem.Allocator) void {
                const typed: Box = @ptrCast(@alignCast(b));
                typed.releaseRef(a);
            }
        }.f,
    };
}

const testing = std.testing;

test "tryDispatch: masked out does not invoke and returns false" {
    const Listener = struct {
        on_x: ?*const fn (i32, ?*anyopaque) callconv(.c) void = null,
        listener_data: ?*anyopaque = null,
    };
    const Static = struct {
        fn cb(_: i32, _: ?*anyopaque) callconv(.c) void {
            @panic("must not be called");
        }
    };
    const listener = Listener{ .on_x = Static.cb };
    const fired = tryDispatch("on_x", @as(u32, 0), @as(u32, 1), listener, @as(i32, 42), .{});
    try testing.expect(!fired);
}

test "tryDispatch: mask set but field null returns false" {
    const Listener = struct {
        on_x: ?*const fn (i32, ?*anyopaque) callconv(.c) void = null,
        listener_data: ?*anyopaque = null,
    };
    const listener = Listener{};
    const fired = tryDispatch("on_x", @as(u32, 1), @as(u32, 1), listener, @as(i32, 42), .{});
    try testing.expect(!fired);
}

test "tryDispatch: mask set and field non-null invokes with args and listener_data" {
    const Listener = struct {
        on_x: ?*const fn (i32, i32, ?*anyopaque) callconv(.c) void = null,
        listener_data: ?*anyopaque = null,
    };
    var seen_handle: i32 = 0;
    var seen_status: i32 = 0;
    var seen_data: ?*anyopaque = null;
    const Static = struct {
        var handle_ptr: *i32 = undefined;
        var status_ptr: *i32 = undefined;
        var data_ptr: *?*anyopaque = undefined;
        fn cb(handle: i32, status: i32, data: ?*anyopaque) callconv(.c) void {
            handle_ptr.* = handle;
            status_ptr.* = status;
            data_ptr.* = data;
        }
    };
    Static.handle_ptr = &seen_handle;
    Static.status_ptr = &seen_status;
    Static.data_ptr = &seen_data;
    var marker: u8 = 0;
    const listener = Listener{ .on_x = Static.cb, .listener_data = &marker };
    const fired = tryDispatch("on_x", @as(u32, 1), @as(u32, 1), listener, @as(i32, 42), .{@as(i32, 7)});
    try testing.expect(fired);
    try testing.expectEqual(@as(i32, 42), seen_handle);
    try testing.expectEqual(@as(i32, 7), seen_status);
    try testing.expectEqual(@as(?*anyopaque, &marker), seen_data);
}

test "peek: mirrors tryDispatch's gating without invoking" {
    const Listener = struct {
        on_x: ?*const fn (i32, ?*anyopaque) callconv(.c) void = null,
        listener_data: ?*anyopaque = null,
    };
    const Static = struct {
        fn cb(_: i32, _: ?*anyopaque) callconv(.c) void {}
    };
    try testing.expect(peek("on_x", @as(u32, 0), @as(u32, 1), Listener{ .on_x = Static.cb }) == null);
    try testing.expect(peek("on_x", @as(u32, 1), @as(u32, 1), Listener{}) == null);
    try testing.expect(peek("on_x", @as(u32, 1), @as(u32, 1), Listener{ .on_x = Static.cb }) != null);
}

test "resolveBox: keeps the box reference until release, drops it when unresolved" {
    const ListenerBox = @import("listener_box.zig").ListenerBox;
    const Listener = struct {
        on_x: ?*const fn (i32, ?*anyopaque) callconv(.c) void = null,
        listener_data: ?*anyopaque = null,
        release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
    };
    const Static = struct {
        var seen: i32 = 0;
        fn cb(handle: i32, _: ?*anyopaque) callconv(.c) void {
            seen = handle;
        }
    };
    const Cb = Callback(Listener, "on_x");

    const box = try ListenerBox(Listener).create(testing.allocator, .{ .on_x = Static.cb });
    defer box.releaseRef(testing.allocator);

    try testing.expect(resolveBox(Cb, "on_x", @as(u32, 0), @as(u32, 1), box.acquireLocked(), testing.allocator) == null);
    try testing.expectEqual(@as(usize, 1), box.refcount.load(.monotonic));

    const r = resolveBox(Cb, "on_x", @as(u32, 1), @as(u32, 1), box.acquireLocked(), testing.allocator).?;
    try testing.expectEqual(@as(usize, 2), box.refcount.load(.monotonic));
    r.invoke(@as(i32, 42), .{});
    try testing.expectEqual(@as(i32, 42), Static.seen);
    r.release();
    try testing.expectEqual(@as(usize, 1), box.refcount.load(.monotonic));
}
