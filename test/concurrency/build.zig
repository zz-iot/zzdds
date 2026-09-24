//! Dependency-free entry point for the test-only prototype.
const std = @import("std");
const support = @import("build_support.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const normal = b.step("test", "Run deterministic and hosted concurrency prototype tests");
    for (support.tests(b, target, optimize, false, optimize == .ReleaseSmall, "../../")) |t|
        normal.dependOn(&b.addRunArtifact(t).step);
    const tsan = b.step("test-tsan", "Run prototype tests with LLVM ThreadSanitizer");
    for (support.tests(b, target, optimize, true, true, "../../")) |t|
        tsan.dependOn(&b.addRunArtifact(t).step);
    b.default_step.dependOn(normal);
}
