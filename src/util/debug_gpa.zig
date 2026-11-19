//! The `-Ddebug-allocator` lane's allocator and its leak check. Only used
//! when `build_options.debug_allocator` is true.
//!
//! A DebugAllocator, unlike bare c_allocator, attributes double-free/UAF to
//! the actual call site instead of silently corrupting the heap -- this is
//! what the original zig/shape heap-corruption investigation had to fall
//! back to manual DebugAllocator wiring to get, before this flag existed.
//!
//! -Ddebug-allocator-stack-traces=false keeps every check but records no
//! stack traces, so reports name no allocation or free site. Recording one
//! holds the allocator's lock for the capture, which serializes every thread
//! in the process.
//!
//! A factory on this allocator also makes it the process-wide C ABI
//! allocator (`zidl_cdr_set_allocator`), unless the app registered one: the
//! sequences and strings an entity hands a C caller come from the entity's
//! allocator, and the generated `{Type}_free` functions free them through
//! the process-wide one. The leak check then also counts what C callers
//! still hold. A block allocated before then came from libc, and goes back
//! to it (`blocks`).

const std = @import("std");
const build_options = @import("build_options");
const zidl_bindings = @import("zidl_bindings");
const ZidlAllocator = zidl_bindings.ZidlAllocator;
const Mutex = @import("mutex.zig").Mutex;
const listener_lane = @import("../dcps/listener_lane.zig");

const config: std.heap.DebugAllocatorConfig = if (build_options.debug_allocator_stack_traces) .{} else .{ .stack_trace_frames = 0 };
var gpa: std.heap.DebugAllocator(config) = .{};
var leak_check: LeakCheck = .{};

/// Through the same C ABI adapter a generated C free uses, so a block passes
/// the same alignment wherever it is allocated or freed.
pub fn allocator() std.mem.Allocator {
    return zidl_bindings.toAllocator(&c_abi_allocator);
}

/// Whether `alloc` is this allocator.
pub fn owns(alloc: std.mem.Allocator) bool {
    return build_options.debug_allocator and alloc.ptr == @as(*anyopaque, @ptrCast(@constCast(&c_abi_allocator)));
}

/// Holds off the leak check: by a factory on this allocator, from before it
/// allocates anything, or by an entity freed after its factory.
pub fn retain() void {
    leak_check.retain();
}

/// Makes this the process-wide C ABI allocator, if the app has not
/// registered one. Called by each factory on this allocator, before it
/// allocates anything, and never undone: whatever was allocated through it
/// must be freed through it.
pub fn registerForCAbi() void {
    if (!build_options.c_abi) return;
    c_abi_mu.lock();
    defer c_abi_mu.unlock();
    if (c_abi_registered) return;
    c_abi_registered = true;
    if (zidl_cdr_get_allocator() == null) zidl_cdr_set_allocator(&c_abi_allocator);
}

extern fn zidl_cdr_get_allocator() callconv(.c) ?*const ZidlAllocator;
extern fn zidl_cdr_set_allocator(allocator: ?*const ZidlAllocator) callconv(.c) void;

var c_abi_mu: Mutex = .{};
var c_abi_registered = false;

const c_abi_allocator: ZidlAllocator = .{
    .ctx = null,
    .alloc = cAbiAlloc,
    .resize = cAbiResize,
    .free = cAbiFree,
};

// Every address this allocator handed out: true while the block is live.
// Before a factory registers it, a C ABI block comes from libc (zidl_cdr's
// default), and may be freed or resized through this allocator afterwards:
// its address is not in here, and it goes back to libc. A freed address
// stays, so freeing it again still reaches the DebugAllocator, which reports
// it. Kept on libc, outside the leak check.
var blocks: std.AutoHashMapUnmanaged(usize, bool) = .empty;
var blocks_mu: Mutex = .{};

const Provenance = enum { live, freed, libc };

fn provenance(p: [*]u8, comptime freeing: bool) Provenance {
    blocks_mu.lock();
    defer blocks_mu.unlock();
    const live = blocks.getPtr(@intFromPtr(p)) orelse return .libc;
    if (!live.*) return .freed;
    if (freeing) live.* = false;
    return .live;
}

// A C caller may ask for zero bytes, which a Zig allocator does not take;
// such a block is one byte here, the same on every call for it.
fn cAbiAlloc(_: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?[*]u8 {
    const p = gpa.allocator().rawAlloc(@max(len, 1), .fromByteUnits(alignment), @returnAddress()) orelse return null;
    blocks_mu.lock();
    defer blocks_mu.unlock();
    blocks.put(std.heap.c_allocator, @intFromPtr(p), true) catch {
        gpa.allocator().rawFree(p[0..@max(len, 1)], .fromByteUnits(alignment), @returnAddress());
        return null;
    };
    return p;
}

// A libc block is never resized in place: the caller moves it instead.
fn cAbiResize(_: ?*anyopaque, ptr: ?[*]u8, old_len: usize, new_len: usize, alignment: usize) callconv(.c) bool {
    const p = ptr orelse return false;
    if (provenance(p, false) == .libc) return false;
    return gpa.allocator().rawResize(p[0..@max(old_len, 1)], .fromByteUnits(alignment), @max(new_len, 1), @returnAddress());
}

fn cAbiFree(_: ?*anyopaque, ptr: ?[*]u8, len: usize, alignment: usize) callconv(.c) void {
    const p = ptr orelse return;
    switch (provenance(p, true)) {
        .libc => std.c.free(p),
        .live, .freed => gpa.allocator().rawFree(p[0..@max(len, 1)], .fromByteUnits(alignment), @returnAddress()),
    }
}

/// Checks for leaks if this was the last hold.
pub fn release() void {
    const leaks = leak_check.release(&gpa, !listener_lane.inCallbackChain());
    if (leaks > 0) std.debug.panic("-Ddebug-allocator: {d} allocation(s) still live after the last factory was destroyed", .{leaks});
}

// Counts the holders on one allocator, and checks it for leaks once the last
// goes. A holder is a factory, or a deleted reader or writer that an
// outstanding loan keeps allocated after its factory (see
// DataReaderImpl.retireHandles). A factory's allocator must outlive it and
// everything created through it, so by then nothing it allocated may still
// be live: what is, leaked or is freed late. The lock keeps a factory being
// created meanwhile from allocating during the check.
//
// Not when the last holder goes from a callback: an entity deleted there, by
// that callback or one further up its thread, is freed once its callback
// returns, so it is still live.
const LeakCheck = struct {
    holders: u32 = 0,
    mu: Mutex = .{},

    fn retain(self: *LeakCheck) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.holders += 1;
    }

    // Returns how many allocations are still live if this released the last
    // holder and `settled` (no frees are pending), else 0. `detector` is a
    // DebugAllocator, which also logs each one (with where it was made, given
    // stack traces).
    fn release(self: *LeakCheck, detector: anytype, settled: bool) usize {
        self.mu.lock();
        defer self.mu.unlock();
        self.holders -= 1;
        if (self.holders > 0 or !settled) return 0;
        return detector.detectLeaks();
    }
};

// Stands in for a DebugAllocator with `live` allocations, which would log
// each one as an error and so fail the test.
const FakeLeakDetector = struct {
    live: usize,
    checks: u32 = 0,

    fn detectLeaks(self: *FakeLeakDetector) usize {
        self.checks += 1;
        return self.live;
    }
};

test "LeakCheck checks for leaks only when the last holder is released" {
    var check: LeakCheck = .{};
    var detector: FakeLeakDetector = .{ .live = 3 };
    check.retain();
    check.retain();
    try std.testing.expectEqual(@as(usize, 0), check.release(&detector, true));
    try std.testing.expectEqual(@as(u32, 0), detector.checks);
    try std.testing.expectEqual(@as(usize, 3), check.release(&detector, true));
    try std.testing.expectEqual(@as(u32, 1), detector.checks);

    // A factory created after the last one was destroyed starts a new count.
    detector.live = 0;
    check.retain();
    try std.testing.expectEqual(@as(usize, 0), check.release(&detector, true));
    try std.testing.expectEqual(@as(u32, 2), detector.checks);
}

test "LeakCheck waits for an entity that outlives the last factory" {
    var check: LeakCheck = .{};
    var detector: FakeLeakDetector = .{ .live = 0 };
    check.retain(); // the factory
    check.retain(); // a deleted writer an outstanding loan keeps
    try std.testing.expectEqual(@as(usize, 0), check.release(&detector, true));
    try std.testing.expectEqual(@as(u32, 0), detector.checks);
    try std.testing.expectEqual(@as(usize, 0), check.release(&detector, true));
    try std.testing.expectEqual(@as(u32, 1), detector.checks);
}

test "LeakCheck does not check a last holder released while frees are pending" {
    var check: LeakCheck = .{};
    var detector: FakeLeakDetector = .{ .live = 1 };
    check.retain();
    try std.testing.expectEqual(@as(usize, 0), check.release(&detector, false));
    try std.testing.expectEqual(@as(u32, 0), detector.checks);

    // The count still dropped: the next factory is the only one.
    check.retain();
    try std.testing.expectEqual(@as(usize, 1), check.release(&detector, true));
    try std.testing.expectEqual(@as(u32, 1), detector.checks);
}

test "LeakCheck finds no leaks on a DebugAllocator whose allocations were freed" {
    var check: LeakCheck = .{};
    var real: std.heap.DebugAllocator(.{}) = .{};
    defer _ = real.deinit();
    check.retain();
    const buf = try real.allocator().alloc(u8, 64);
    real.allocator().free(buf);
    try std.testing.expectEqual(@as(usize, 0), check.release(&real, true));
}
