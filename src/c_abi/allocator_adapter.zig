//! Bridges a caller-supplied `std.mem.Allocator` into the `ZidlAllocator`
//! C-ABI vtable — the reverse direction of `zidl_rt`'s own `toAllocator`
//! (`ZidlAllocator` -> `std.mem.Allocator`). Needed wherever zzdds-internal
//! Zig code wants to hand a real `std.mem.Allocator` (e.g. a
//! `std.heap.DebugAllocator` instance, or `std.testing.allocator`) into a
//! C-ABI entry point that only accepts a `*const ZidlAllocator` (e.g.
//! `zzdds_create_factory_with_allocator`).
//!
//! Kept zzdds-local rather than upstreamed into `zidl_rt` itself: `zidl` is
//! a pinned/versioned dependency, and upstreaming this would require a
//! release cycle before zzdds could consume it. Revisit later if other
//! zidl-based projects want the same adapter.
//!
//! Mirrors `zidl_rt.toAllocator`'s zero-allocation contract: `fromAllocator`
//! allocates nothing and returns a value whose `ctx` points directly at the
//! caller-owned `*const std.mem.Allocator` passed in — that pointer must
//! outlive the returned `ZidlAllocator`.

const std = @import("std");
const zidl_rt = @import("zidl_rt");

pub const ZidlAllocator = zidl_rt.ZidlAllocator;

fn asAllocator(ctx: ?*anyopaque) *const std.mem.Allocator {
    return @ptrCast(@alignCast(ctx.?));
}

fn vtAlloc(ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?[*]u8 {
    return asAllocator(ctx).rawAlloc(len, std.mem.Alignment.fromByteUnits(alignment), @returnAddress());
}

fn vtResize(ctx: ?*anyopaque, ptr: ?[*]u8, old_len: usize, new_len: usize, alignment: usize) callconv(.c) bool {
    return asAllocator(ctx).rawResize(ptr.?[0..old_len], std.mem.Alignment.fromByteUnits(alignment), new_len, @returnAddress());
}

fn vtFree(ctx: ?*anyopaque, ptr: ?[*]u8, len: usize, alignment: usize) callconv(.c) void {
    asAllocator(ctx).rawFree(ptr.?[0..len], std.mem.Alignment.fromByteUnits(alignment), @returnAddress());
}

/// Wrap a caller-owned `std.mem.Allocator` as a `ZidlAllocator`. Allocates
/// nothing; `alloc` must outlive the returned `ZidlAllocator`.
pub fn fromAllocator(alloc: *const std.mem.Allocator) ZidlAllocator {
    return .{
        .ctx = @ptrCast(@constCast(alloc)),
        .alloc = vtAlloc,
        .resize = vtResize,
        .free = vtFree,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "fromAllocator: alloc/resize/free round-trip through the ZidlAllocator vtable" {
    const alloc = testing.allocator;
    const c_alloc = fromAllocator(&alloc);

    const via_c = c_alloc.alloc(c_alloc.ctx, 32, 1) orelse return error.OutOfMemory;
    defer c_alloc.free(c_alloc.ctx, via_c, 32, 1);
    @memset(via_c[0..32], 0xCD);

    // A same-size "resize" is always a valid no-op resize for any conforming
    // allocator (unlike a real shrink/grow, whose success is allocator- and
    // size-class-dependent and not something this adapter should assert on).
    try testing.expect(c_alloc.resize(c_alloc.ctx, via_c, 32, 32, 1));
}

test "fromAllocator: round-trips through zidl_rt.toAllocator back to a working std.mem.Allocator" {
    const alloc = testing.allocator;
    const c_alloc = fromAllocator(&alloc);
    const roundtripped = zidl_rt.toAllocator(&c_alloc);

    const mem = try roundtripped.alloc(u8, 64);
    defer roundtripped.free(mem);
    try testing.expectEqual(@as(usize, 64), mem.len);
}

test "fromAllocator: OOM surfaces as a null alloc, not a crash" {
    var fba_buf: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const alloc = fba.allocator();
    const c_alloc = fromAllocator(&alloc);

    try testing.expect(c_alloc.alloc(c_alloc.ctx, 1024, 1) == null);
}
