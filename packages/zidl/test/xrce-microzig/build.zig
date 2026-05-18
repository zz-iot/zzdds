const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zidl_rt_dep = b.dependency("zidl_rt", .{
        .target = target,
        .optimize = optimize,
    });

    const types_mod = b.createModule(.{
        .root_source_file = b.path("generated/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_dep.module("zidl-rt") },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zidl_rt", .module = zidl_rt_dep.module("zidl-rt") },
                .{ .name = "types", .module = types_mod },
            },
        }),
    });

    const test_step = b.step("test", "Compile and run generated XRCE MicroZig-facing bindings");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
