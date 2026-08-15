//! Idiomatic Zig bootstrap helpers for the generated zzdds factory interface.

const std = @import("std");

const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;

const extensions = @import("c_abi/extensions.zig");
const nil = @import("dcps/nil.zig");
const zidl_rt = @import("zidl_rt");
const allocator_adapter = @import("c_abi/allocator_adapter.zig");

pub const CreateFactoryError = error{
    FactoryCreateFailed,
};

/// Single-owner factory wrapper. Must not be copied by value while active —
/// each copy holds an independent `active` field, so both copies would call
/// zzdds_destroy_factory on the same underlying FactoryOwner on deinit.
pub const DomainParticipantFactory = struct {
    handle: ZZDDS.DomainParticipantFactory,
    active: bool = true,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (!@atomicRmw(bool, &self.active, .Xchg, false, .acq_rel)) return;
        extensions.zzdds_destroy_factory(self.handle.vtable.get_c_abi_handle(self.handle.ptr));
    }

    pub fn toZZDDSFactory(self: *const Self) ZZDDS.DomainParticipantFactory {
        return self.handle;
    }

    pub fn toDDSFactory(self: *const Self) DDS.DomainParticipantFactory {
        return self.handle.vtable.as_DomainParticipantFactory(self.handle.ptr);
    }
};

pub fn createFactory() CreateFactoryError!DomainParticipantFactory {
    const boxed = extensions.zzdds_create_factory();
    const handle = zidl_rt.unboxAsView(ZZDDS.DomainParticipantFactory, boxed);
    if (nil.isNil(handle)) return error.FactoryCreateFailed;
    return .{ .handle = handle };
}

/// Same as `createFactory`, but every allocation the factory and everything
/// it creates (participants, topics, publishers/subscribers, readers/
/// writers, transport, discovery) makes is routed through `c_alloc` instead
/// of the default `std.heap.c_allocator`.
///
/// `c_alloc` must outlive the returned `DomainParticipantFactory` (and
/// everything created through it) -- zzdds never copies it, only ever
/// dereferences it, same contract as the raw C-ABI
/// `zzdds_create_factory_with_allocator` this wraps. Build `c_alloc` with
/// `allocator_adapter.fromAllocator(&my_stable_allocator)` and store the
/// result somewhere that outlives the factory (a module-level `var`, or a
/// field on whatever your own top-level "participant" struct is) -- NOT a
/// local temporary in the same function that calls this, which would leave
/// the factory holding a dangling pointer the moment this function returns
/// (confirmed the hard way: an earlier version of this function built
/// `c_alloc` as its own local and got exactly that crash on first
/// `deinit()`).
pub fn createFactoryWithAllocator(c_alloc: *const zidl_rt.ZidlAllocator) CreateFactoryError!DomainParticipantFactory {
    const boxed = extensions.zzdds_create_factory_with_allocator(c_alloc);
    const handle = zidl_rt.unboxAsView(ZZDDS.DomainParticipantFactory, boxed);
    if (nil.isNil(handle)) return error.FactoryCreateFailed;
    return .{ .handle = handle };
}

test "createFactory returns an owned generated factory handle" {
    var factory = try createFactory();
    defer factory.deinit();

    try std.testing.expect(!nil.isNil(factory.toZZDDSFactory()));
    try std.testing.expect(!nil.isNil(factory.toDDSFactory()));
}

test "createFactoryWithAllocator routes allocation through the caller's allocator" {
    // Both must live for the whole test, not just the createFactoryWithAllocator
    // call -- see that function's doc comment on why a temporary here would
    // leave the factory holding a dangling pointer.
    const alloc = std.testing.allocator;
    const c_alloc = allocator_adapter.fromAllocator(&alloc);

    var factory = try createFactoryWithAllocator(&c_alloc);
    defer factory.deinit();

    try std.testing.expect(!nil.isNil(factory.toZZDDSFactory()));
    try std.testing.expect(!nil.isNil(factory.toDDSFactory()));
}
