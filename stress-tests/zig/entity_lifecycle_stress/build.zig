const std = @import("std");

// stress-tests/zig/entity_lifecycle_stress -- multi-process port of
// OpenDDS's tests/DCPS/EntityLifecycleStress. One binary, `elc_stress`,
// with --role pub|sub; run.py spawns N of each. Talks to zzdds's native
// Zig API directly (like examples/zig/hello_world). See ../../README.md.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;
    // Zig 0.16's self-hosted backend silently no-ops sanitize_thread without
    // this (confirmed upstream in zzdds's build.zig).
    const use_llvm: ?bool = if (sanitize_thread) true else null;

    const zzdds_dep = b.dependency("zzdds", .{
        .target = target,
        .optimize = optimize,
        .@"sanitize-thread" = sanitize_thread,
    });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");
    const zzdds_ext_gen = zzdds_dep.module("zzdds_ext_generated");

    // zidl executable + zidl_rt module come *through* zzdds (which re-exposes
    // both) -- a second independent dependency on zidl breaks the build when
    // zidl is a `.path` dep. See examples/zig/hello_world/build.zig.
    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    const gen = b.addRunArtifact(zidl_exe);
    gen.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const gen_dir = gen.addOutputDirectoryArg("messenger-generated");
    gen.addFileArg(b.path("idl/messenger.idl"));

    const gen_mod = b.createModule(.{
        .root_source_file = gen_dir.path(b, "messenger.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds", .module = zzdds_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "elc_stress",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod },
                .{ .name = "zzdds_generated", .module = zzdds_gen },
                .{ .name = "zzdds_ext_generated", .module = zzdds_ext_gen },
                .{ .name = "messenger_gen", .module = gen_mod },
                .{ .name = "zidl_rt", .module = zidl_rt_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_step = b.step("run", "Run elc_stress (pass flags via -- ...)");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}
