// zidl-cdr build script.
//
// Outputs:
//   lib   — libzidl_cdr.a (static C99 CDR library)
//   test  — Zig roundtrip tests cross-validating C library against zidl-rt
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Library ────────────────────────────────────────────────────────────────

    const lib_mod = b.createModule(.{
        .root_source_file = null, // C-only module
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addCSourceFile(.{
        .file = b.path("src/zidl_cdr.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Wpedantic" },
    });
    lib_mod.addIncludePath(b.path("include"));

    const lib = b.addLibrary(.{
        .name = "zidl_cdr",
        .root_module = lib_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // ── Tests ──────────────────────────────────────────────────────────────────

    // Resolve zidl-rt (sibling package).
    const zidl_rt_dep = b.dependency("zidl_rt", .{
        .target = target,
        .optimize = optimize,
    });
    const zidl_rt_mod = zidl_rt_dep.module("zidl-rt");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/roundtrip.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
        },
    });
    test_mod.addIncludePath(b.path("include"));
    test_mod.linkLibrary(lib);

    const test_exe = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run zidl-cdr tests");
    test_step.dependOn(&run_tests.step);
}
