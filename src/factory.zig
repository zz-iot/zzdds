//! Idiomatic Zig bootstrap helpers for the generated zzdds factory interface.

const std = @import("std");

const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;

const extensions = @import("c_abi/extensions.zig");
const nil = @import("dcps/nil.zig");
const zidl_rt = @import("zidl_rt");

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
    const handle = zidl_rt.unboxAs(ZZDDS.DomainParticipantFactory, boxed);
    if (nil.isNil(handle)) return error.FactoryCreateFailed;
    return .{ .handle = handle };
}

test "createFactory returns an owned generated factory handle" {
    var factory = try createFactory();
    defer factory.deinit();

    try std.testing.expect(!nil.isNil(factory.toZZDDSFactory()));
    try std.testing.expect(!nil.isNil(factory.toDDSFactory()));
}
