//! Shared helper for "standalone" entity types -- ones with no factory
//! operation in dcps.idl (currently `WaitSet`/`GuardCondition`, marked
//! `@standalone` there; see
//! zzdds/docs/design/generated-class-lifecycle-design.md). Collapses the
//! create-with-allocator boilerplate (resolve the allocator, construct, log
//! + fall back to a nil sentinel on failure, box via get_c_abi_handle) into
//! one place shared across every standalone type's `*_create_with_allocator`
//! export, instead of re-deriving the same ~10 lines per type.
//!
//! Deliberately hand-written, not zidl-generated: doing this via codegen
//! would require generated code to name a concrete Zig impl type (e.g.
//! `WaitSetImpl.init`), which no zidl-generated C-ABI export does anywhere
//! else -- every other generated export operates purely on abstract
//! vtable-boxed interface values, never a concrete impl type. Keeping the
//! impl-type reference in zzdds's own hand-written `construct` closure at
//! each call site (ordinary Zig, checked by the compiler like any other
//! call) keeps that boundary intact while still eliminating the actual
//! repeated logic.

const std = @import("std");
const zidl_rt = @import("zidl_rt");

/// `Iface` is a zidl-generated interface fat-pointer type (e.g. `DDS.WaitSet`)
/// with `.ptr`/`.vtable` fields, where `.vtable.get_c_abi_handle` is present
/// per the synthetic vtable slot every interface carries.
///
/// `construct` does both the real allocation (via a concrete impl type's own
/// `init`) and the conversion to `Iface` (via that impl's own `toDDS{Iface}`)
/// in one step, since the two are always used together at every existing
/// call site and there's no case where a caller wants one without the other.
pub fn createWithAllocator(
    comptime Iface: type,
    allocator: ?*const zidl_rt.ZidlAllocator,
    comptime log_name: []const u8,
    comptime construct: fn (std.mem.Allocator) anyerror!Iface,
    nil_value: Iface,
) *anyopaque {
    const alloc = if (allocator) |a| zidl_rt.toAllocator(a) else std.heap.c_allocator;
    const r = construct(alloc) catch |err| {
        std.log.err(log_name ++ ": {}", .{err});
        return nil_value.vtable.get_c_abi_handle(nil_value.ptr);
    };
    return r.vtable.get_c_abi_handle(r.ptr);
}
