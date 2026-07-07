//! Shared helper implementing the cache-and-reuse pattern for zidl's
//! `get_c_abi_handle` vtable slot: lazily box a (ptr, vtable) pair on first
//! request, reuse the same boxed handle on every subsequent call, free it
//! once via `deinit`.
//!
//! This is what makes a C-ABI handle returned from an accessor operation
//! identity-stable across repeated calls (e.g. `get_topic()` called twice
//! returns the same handle) and prevents a widened-view accessor
//! (`get_entity()`, `get_topicdescription()`) from leaking a fresh box on
//! every call — see zidl's roadmap "Entity handle ABI: heap-boxing".
//!
//! A concrete impl that presents more than one distinct (ptr, vtable) view of
//! itself — e.g. `TopicImpl` implements `Topic`, `Entity`, and
//! `TopicDescription` vtables from the same object — needs one
//! `CachedCAbiHandle` field per view, since each is a genuinely different
//! boxed value even though `ptr` is the same.

const std = @import("std");
const zidl_rt = @import("zidl_rt");

pub const CachedCAbiHandle = struct {
    handle: ?*anyopaque = null,

    /// Return the cached handle, boxing `(ptr, vtable)` on first call.
    pub fn get(self: *CachedCAbiHandle, alloc: std.mem.Allocator, ptr: *anyopaque, vtable: *const anyopaque) *anyopaque {
        if (self.handle) |h| return h;
        // get_c_abi_handle's vtable signature can't express allocation
        // failure (no error union, no optional) — the box is two words, so
        // treat OOM here the same as any other unrecoverable allocation
        // failure in zzdds.
        const h = zidl_rt.boxEntity(alloc, ptr, vtable) catch @panic("zzdds: out of memory boxing C-ABI entity handle");
        self.handle = h;
        return h;
    }

    /// Free the cached handle, if one was ever created. Call from the owning
    /// object's `deinit`.
    pub fn free(self: *CachedCAbiHandle, alloc: std.mem.Allocator) void {
        if (self.handle) |h| zidl_rt.freeEntityBox(alloc, h);
        self.handle = null;
    }
};
