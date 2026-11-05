//! Shared helper implementing the cache-and-reuse pattern for zidl's
//! `get_c_abi_handle` vtable slot: lazily box a (ptr, vtable) pair on first
//! request, reuse the same boxed handle on every subsequent call, free it
//! once after native references drain. `retire` invalidates binding wrappers
//! earlier, when logical deletion completes.
//!
//! This is what makes a C-ABI handle returned from an accessor operation
//! identity-stable across repeated calls (e.g. `get_topic()` called twice
//! returns the same handle) and prevents a widened-view accessor
//! (`get_entity()`, `get_topicdescription()`) from leaking a fresh box on
//! every call — see `zidl/docs/design/binding-c-abi-identity.md`.
//!
//! A concrete impl that presents more than one distinct (ptr, vtable) view of
//! itself — e.g. `TopicImpl` implements `Topic`, `Entity`, and
//! `TopicDescription` vtables from the same object — needs one
//! `CachedCAbiHandle` field per view, since each is a genuinely different
//! boxed value even though `ptr` is the same.

const std = @import("std");
const zidl_rt = @import("zidl_rt");

pub const CachedCAbiHandle = struct {
    handle: std.atomic.Value(?*anyopaque) = std.atomic.Value(?*anyopaque).init(null),
    retired: std.atomic.Value(bool) = .init(false),

    /// Return the cached handle, boxing `(ptr, vtable)` on first call.
    ///
    /// Listener callbacks can fire on different threads for the same entity
    /// (e.g. a data-available callback and a subscription-matched callback
    /// racing after the entity mutex is released), so a plain check-then-write
    /// here would let two threads both box and one leak. Resolved via CAS:
    /// the loser frees its box and reuses whichever one won.
    pub fn get(self: *CachedCAbiHandle, alloc: std.mem.Allocator, ptr: *anyopaque, vtable: *const anyopaque) *anyopaque {
        if (self.handle.load(.acquire)) |h| return self.exportHandle(h);
        // get_c_abi_handle's vtable signature can't express allocation
        // failure (no error union, no optional) — the box is small, so
        // treat OOM here the same as any other unrecoverable allocation
        // failure in zzdds.
        const h = zidl_rt.boxEntity(alloc, ptr, vtable) catch @panic("zzdds: out of memory boxing C-ABI entity handle");
        if (self.handle.cmpxchgStrong(null, h, .acq_rel, .acquire)) |existing| {
            zidl_rt.freeEntityBox(alloc, h);
            return self.exportHandle(existing.?);
        }
        return self.exportHandle(h);
    }

    fn exportHandle(self: *CachedCAbiHandle, h: *anyopaque) *anyopaque {
        // A pinned callback can first request its handle after deletion.
        // Export such a box already retired, so bindings refuse to wrap it.
        // This also closes the race where retire observed an empty cache
        // immediately before get installed the box.
        if (self.retired.load(.acquire)) zidl_rt.retireEntityBox(h);
        return h;
    }

    /// Invalidate binding wrappers at logical deletion, without releasing the
    /// box while an in-flight native operation still holds the entity alive.
    /// Close callback admission before calling. Admitted callbacks must pin
    /// native storage until they finish exporting and using its handle.
    pub fn retire(self: *CachedCAbiHandle) void {
        if (self.retired.swap(true, .acq_rel)) return;
        if (self.handle.load(.acquire)) |h| zidl_rt.retireEntityBox(h);
    }

    /// Free storage once no native references remain. Retirement may already
    /// have happened on the deleting thread; report each handle only once.
    pub fn free(self: *CachedCAbiHandle, alloc: std.mem.Allocator) void {
        self.retire();
        if (self.handle.swap(null, .acq_rel)) |h| zidl_rt.freeEntityBox(alloc, h);
    }
};

test "cached and first-time exports after deletion stay retired until free" {
    const Observer = struct {
        ptr: *anyopaque,
        calls: usize = 0,
        fn on(ctx: ?*anyopaque, h: *anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (zidl_rt.unboxEntity(h).ptr == self.ptr) self.calls += 1;
        }
    };
    for ([_]bool{ false, true }) |boxed_before_delete| {
        var value: u8 = 0;
        var observed: Observer = .{ .ptr = &value };
        try std.testing.expect(zidl_rt.observeHandleRetire(Observer.on, &observed));
        defer _ = zidl_rt.unobserveHandleRetire(Observer.on, &observed);
        var cache: CachedCAbiHandle = .{};
        if (boxed_before_delete) {
            const h = cache.get(std.testing.allocator, &value, &value);
            try std.testing.expect(!zidl_rt.isEntityBoxRetired(h));
        }
        cache.retire();
        const h = cache.get(std.testing.allocator, &value, &value);
        try std.testing.expect(zidl_rt.isEntityBoxRetired(h));
        try std.testing.expectEqual(h, cache.get(std.testing.allocator, &value, &value));
        try std.testing.expectEqual(@as(usize, 1), observed.calls);
        cache.free(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), observed.calls);
    }
}
