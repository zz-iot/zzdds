//! Backend interface and language mapping backends for zidl.
//!
//! Public API:
//!   - `interface`   — `Backend` vtable type, `Options`, `cNameFromQualified`
//!   - `c`           — C language mapping backend
//!   - `CBackend`    — re-export of `c.CBackend` for convenience
//!   - `findByLanguageId` — resolve `-b <lang>` to a backend factory

const std = @import("std");

pub const interface = @import("interface.zig");
pub const c = @import("c.zig");
pub const cpp = @import("cpp.zig");
pub const java = @import("java.zig");
pub const zig = @import("zig.zig");
pub const zig_typeobject_proto = @import("zig_typeobject_proto.zig");

pub const Backend = interface.Backend;
pub const Options = interface.Options;
pub const Profile = interface.Profile;
pub const ZigVersion = interface.ZigVersion;
pub const validateXrce = interface.validateXrce;
pub const CBackend = c.CBackend;
pub const CppBackend = cpp.CppBackend;
pub const JavaBackend = java.JavaBackend;
pub const ZigBackend = zig.ZigBackend;

/// Create a `Backend` by language identifier (e.g. `"c"`, `"cpp"`, `"java"`).
///
/// Returns `null` for unknown language IDs.
/// The caller is responsible for calling `backend.deinit()` when done.
pub fn findByLanguageId(
    alloc: std.mem.Allocator,
    language_id: []const u8,
) !?Backend {
    if (std.mem.eql(u8, language_id, "c")) {
        const be = try CBackend.create(alloc);
        return be.backend();
    }
    if (std.mem.eql(u8, language_id, "cpp")) {
        const be = try CppBackend.create(alloc);
        return be.backend();
    }
    if (std.mem.eql(u8, language_id, "java")) {
        const be = try JavaBackend.create(alloc);
        return be.backend();
    }
    if (std.mem.eql(u8, language_id, "zig")) {
        const be = try ZigBackend.create(alloc);
        return be.backend();
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
