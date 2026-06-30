//! Idiomatic Zig bootstrap helpers for the generated zzdds factory interface.

const std = @import("std");

const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;

const extensions = @import("c_abi/extensions.zig");
const nil = @import("dcps/nil.zig");

pub const CreateFactoryError = error{
    FactoryCreateFailed,
};

pub const DomainParticipantFactory = struct {
    handle: ZZDDS.DomainParticipantFactory,
    active: bool = true,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (!@atomicRmw(bool, &self.active, .Xchg, false, .acq_rel)) return;
        extensions.zzdds_destroy_factory(self.handle);
    }

    pub fn toZZDDSFactory(self: *const Self) ZZDDS.DomainParticipantFactory {
        return self.handle;
    }

    pub fn toDDSFactory(self: *const Self) DDS.DomainParticipantFactory {
        return extensions.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(self.handle);
    }
};

pub fn createFactory() CreateFactoryError!DomainParticipantFactory {
    const handle = extensions.zzdds_create_factory();
    if (nil.isNil(handle)) return error.FactoryCreateFailed;
    return .{ .handle = handle };
}

test "createFactory returns an owned generated factory handle" {
    var factory = try createFactory();
    defer factory.deinit();

    try std.testing.expect(!nil.isNil(factory.toZZDDSFactory()));
    try std.testing.expect(!nil.isNil(factory.toDDSFactory()));
}
