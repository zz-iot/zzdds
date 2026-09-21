const std = @import("std");

// zig/coherent-sets -- GROUP coherent/ordered access integration test,
// talking to zzdds's native Zig API directly. See
// docs/design/integration-test-tier.md for the full scenario spec. Two
// separate binaries (publisher/subscriber), matching zig/raw-loan's
// convention.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdds_dep = b.dependency("zzdds", .{ .target = target, .optimize = optimize });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");
    const zzdds_ext_gen = zzdds_dep.module("zzdds_ext_generated");

    // Get zidl's executable and zidl_rt module *through* zzdds (which
    // re-exposes both) -- see zig/raw-loan's build.zig for why.
    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    // Generate Position/Velocity Zig bindings from idl/pose_group.idl.
    const gen_pose_group = b.addRunArtifact(zidl_exe);
    gen_pose_group.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const pose_group_gen_dir = gen_pose_group.addOutputDirectoryArg("pose-group-generated");
    gen_pose_group.addFileArg(b.path("idl/pose_group.idl"));

    const pose_group_gen_mod = b.createModule(.{
        .root_source_file = pose_group_gen_dir.path(b, "pose_group.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds", .module = zzdds_mod },
        },
    });

    const common_imports = &[_]std.Build.Module.Import{
        .{ .name = "zzdds", .module = zzdds_mod },
        .{ .name = "zzdds_generated", .module = zzdds_gen },
        .{ .name = "zzdds_ext_generated", .module = zzdds_ext_gen },
        .{ .name = "pose_group_gen", .module = pose_group_gen_mod },
        .{ .name = "zidl_rt", .module = zidl_rt_mod },
    };

    const pub_exe = b.addExecutable(.{
        .name = "coherent_sets_pub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("publisher.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    pub_exe.root_module.link_libc = true;
    b.installArtifact(pub_exe);

    const sub_exe = b.addExecutable(.{
        .name = "coherent_sets_sub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("subscriber.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    sub_exe.root_module.link_libc = true;
    b.installArtifact(sub_exe);

    const run_pub_step = b.step("run-pub", "Run coherent_sets_pub (pass extra flags via -- ...)");
    const run_pub_cmd = b.addRunArtifact(pub_exe);
    if (b.args) |args| run_pub_cmd.addArgs(args);
    run_pub_step.dependOn(&run_pub_cmd.step);

    const run_sub_step = b.step("run-sub", "Run coherent_sets_sub (pass extra flags via -- ...)");
    const run_sub_cmd = b.addRunArtifact(sub_exe);
    if (b.args) |args| run_sub_cmd.addArgs(args);
    run_sub_step.dependOn(&run_sub_cmd.step);
}
