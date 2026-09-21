const std = @import("std");

// zig/enable-defer -- enable()/autoenable_created_entities integration test,
// talking to zzdds's native Zig API directly. See
// docs/design/integration-test-tier.md for the full scenario spec. Two
// separate binaries (configurer/peer), matching zig/coherent-sets's and
// zig/delete-contained-entities's convention.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdds_dep = b.dependency("zzdds", .{ .target = target, .optimize = optimize });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");
    const zzdds_ext_gen = zzdds_dep.module("zzdds_ext_generated");

    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    const gen_config_event = b.addRunArtifact(zidl_exe);
    gen_config_event.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const config_event_gen_dir = gen_config_event.addOutputDirectoryArg("config-event-generated");
    gen_config_event.addFileArg(b.path("idl/config_event.idl"));

    const config_event_gen_mod = b.createModule(.{
        .root_source_file = config_event_gen_dir.path(b, "config_event.zig"),
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
        .{ .name = "config_event_gen", .module = config_event_gen_mod },
        .{ .name = "zidl_rt", .module = zidl_rt_mod },
    };

    const configurer_exe = b.addExecutable(.{
        .name = "enable_defer_configurer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("configurer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    configurer_exe.root_module.link_libc = true;
    b.installArtifact(configurer_exe);

    const peer_exe = b.addExecutable(.{
        .name = "enable_defer_peer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("peer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    peer_exe.root_module.link_libc = true;
    b.installArtifact(peer_exe);

    const run_configurer_step = b.step("run-configurer", "Run enable_defer_configurer (pass extra flags via -- ...)");
    const run_configurer_cmd = b.addRunArtifact(configurer_exe);
    if (b.args) |args| run_configurer_cmd.addArgs(args);
    run_configurer_step.dependOn(&run_configurer_cmd.step);

    const run_peer_step = b.step("run-peer", "Run enable_defer_peer (pass extra flags via -- ...)");
    const run_peer_cmd = b.addRunArtifact(peer_exe);
    if (b.args) |args| run_peer_cmd.addArgs(args);
    run_peer_step.dependOn(&run_peer_cmd.step);
}
