// zidl-xtypes build script — skeleton for phase 5.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    _ = b.addModule("zidl-xtypes", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
}
