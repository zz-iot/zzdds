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
