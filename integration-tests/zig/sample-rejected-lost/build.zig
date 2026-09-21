const std = @import("std");

// zig/sample-rejected-lost -- SAMPLE_REJECTED/SAMPLE_LOST integration test,
// talking to zzdds's native Zig API directly. See
// docs/design/integration-test-tier.md for the full scenario spec. Two
// separate binaries (publisher/subscriber), matching zig/coherent-sets'
// convention.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdds_dep = b.dependency("zzdds", .{ .target = target, .optimize = optimize });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");
    const zzdds_ext_gen = zzdds_dep.module("zzdds_ext_generated");

    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    const gen_status_event = b.addRunArtifact(zidl_exe);
    gen_status_event.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const status_event_gen_dir = gen_status_event.addOutputDirectoryArg("status-event-generated");
    gen_status_event.addFileArg(b.path("idl/status_event.idl"));

    const status_event_gen_mod = b.createModule(.{
        .root_source_file = status_event_gen_dir.path(b, "status_event.zig"),
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
        .{ .name = "status_event_gen", .module = status_event_gen_mod },
        .{ .name = "zidl_rt", .module = zidl_rt_mod },
    };

    const pub_exe = b.addExecutable(.{
        .name = "sample_rejected_lost_pub",
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
        .name = "sample_rejected_lost_sub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("subscriber.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    sub_exe.root_module.link_libc = true;
    b.installArtifact(sub_exe);

    const run_pub_step = b.step("run-pub", "Run sample_rejected_lost_pub (pass extra flags via -- ...)");
    const run_pub_cmd = b.addRunArtifact(pub_exe);
    if (b.args) |args| run_pub_cmd.addArgs(args);
    run_pub_step.dependOn(&run_pub_cmd.step);

    const run_sub_step = b.step("run-sub", "Run sample_rejected_lost_sub (pass extra flags via -- ...)");
    const run_sub_cmd = b.addRunArtifact(sub_exe);
    if (b.args) |args| run_sub_cmd.addArgs(args);
    run_sub_step.dependOn(&run_sub_cmd.step);
}
