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

const std = @import("std");
const build_options = @import("build_options");
const Mutex = @import("mutex.zig").Mutex;
const listener_lane = @import("../dcps/listener_lane.zig");

const config: std.heap.DebugAllocatorConfig = if (build_options.debug_allocator_stack_traces) .{} else .{ .stack_trace_frames = 0 };
var gpa: std.heap.DebugAllocator(config) = .{};
var leak_check: LeakCheck = .{};

pub fn allocator() std.mem.Allocator {
    return gpa.allocator();
}

/// Whether `alloc` is this allocator.
pub fn owns(alloc: std.mem.Allocator) bool {
    return build_options.debug_allocator and alloc.ptr == @as(*anyopaque, @ptrCast(&gpa));
}

/// Holds off the leak check: by a factory on this allocator, from before it
/// allocates anything, or by an entity freed after its factory.
pub fn retain() void {
    leak_check.retain();
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
