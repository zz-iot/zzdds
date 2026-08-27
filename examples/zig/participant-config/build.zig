const std = @import("std");

// zig/participant-config -- exercises zzdds's `create_participant_ex`/
// `set_default_participant_config`/`get_default_participant_config`
// extension operations (programmatic mode) and `zzdds_process_configure_
// from_file` (file mode), talking to zzdds's native Zig API directly (no
// vendor-neutral "dds" shim, matching zig/hello_world's convention). See
// docs/design/participant-config-reference-app.md at the repo root for the
// full spec. Two separate binaries (publisher/subscriber), matching
// zig/hello_world's convention.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdds_dep = b.dependency("zzdds", .{ .target = target, .optimize = optimize });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");
    const zzdds_ext_gen = zzdds_dep.module("zzdds_ext_generated");

    // Get zidl's executable and zidl_rt module *through* zzdds (which
    // re-exposes both) rather than declaring our own separate dependency on
    // zidl -- see hello_world/presence's build.zig for the full "why"
    // (avoids a duplicate-module build failure when zidl is a `.path`
    // dependency during zidl+zzdds co-development).
    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    // Generate ConfigPing Zig bindings from idl/config_ping.idl.
    const gen_ping = b.addRunArtifact(zidl_exe);
    gen_ping.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const ping_gen_dir = gen_ping.addOutputDirectoryArg("participant-config-generated");
    gen_ping.addFileArg(b.path("idl/config_ping.idl"));

    const ping_gen_mod = b.createModule(.{
        .root_source_file = ping_gen_dir.path(b, "config_ping.zig"),
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
        .{ .name = "config_ping_gen", .module = ping_gen_mod },
        .{ .name = "zidl_rt", .module = zidl_rt_mod },
    };

    const pub_exe = b.addExecutable(.{
        .name = "participant_config_pub",
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
        .name = "participant_config_sub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("subscriber.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    sub_exe.root_module.link_libc = true;
    b.installArtifact(sub_exe);

    const run_pub_step = b.step("run-pub", "Run participant_config_pub (pass extra flags via -- ...)");
    const run_pub_cmd = b.addRunArtifact(pub_exe);
    if (b.args) |args| run_pub_cmd.addArgs(args);
    run_pub_step.dependOn(&run_pub_cmd.step);

    const run_sub_step = b.step("run-sub", "Run participant_config_sub (pass extra flags via -- ...)");
    const run_sub_cmd = b.addRunArtifact(sub_exe);
    if (b.args) |args| run_sub_cmd.addArgs(args);
    run_sub_step.dependOn(&run_sub_cmd.step);
}
