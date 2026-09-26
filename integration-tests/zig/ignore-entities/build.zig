const std = @import("std");

// zig/ignore-entities -- ignore_participant()/ignore_topic()/
// ignore_publication()/ignore_subscription() integration test, talking to
// zzdds's native Zig API directly. See docs/design/integration-test-tier.md
// for the full scenario spec. Three separate binaries (ignorer/peer/
// bystander), matching the two-binary convention every other scenario here
// uses, extended by one role -- see the scenario doc for why
// ignore_participant specifically needs a third, dedicated participant.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdds_dep = b.dependency("zzdds", .{ .target = target, .optimize = optimize });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");

    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    const gen_ignore_event = b.addRunArtifact(zidl_exe);
    gen_ignore_event.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const ignore_event_gen_dir = gen_ignore_event.addOutputDirectoryArg("ignore-event-generated");
    gen_ignore_event.addFileArg(b.path("idl/ignore_event.idl"));

    const ignore_event_gen_mod = b.createModule(.{
        .root_source_file = ignore_event_gen_dir.path(b, "ignore_event.zig"),
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
        .{ .name = "ignore_event_gen", .module = ignore_event_gen_mod },
        .{ .name = "zidl_rt", .module = zidl_rt_mod },
    };

    const ignorer_exe = b.addExecutable(.{
        .name = "ignore_entities_ignorer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ignorer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    ignorer_exe.root_module.link_libc = true;
    b.installArtifact(ignorer_exe);

    const peer_exe = b.addExecutable(.{
        .name = "ignore_entities_peer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("peer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    peer_exe.root_module.link_libc = true;
    b.installArtifact(peer_exe);

    const bystander_exe = b.addExecutable(.{
        .name = "ignore_entities_bystander",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bystander.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    bystander_exe.root_module.link_libc = true;
    b.installArtifact(bystander_exe);

    const run_ignorer_step = b.step("run-ignorer", "Run ignore_entities_ignorer (pass extra flags via -- ...)");
    const run_ignorer_cmd = b.addRunArtifact(ignorer_exe);
    if (b.args) |args| run_ignorer_cmd.addArgs(args);
    run_ignorer_step.dependOn(&run_ignorer_cmd.step);

    const run_peer_step = b.step("run-peer", "Run ignore_entities_peer (pass extra flags via -- ...)");
    const run_peer_cmd = b.addRunArtifact(peer_exe);
    if (b.args) |args| run_peer_cmd.addArgs(args);
    run_peer_step.dependOn(&run_peer_cmd.step);

    const run_bystander_step = b.step("run-bystander", "Run ignore_entities_bystander (pass extra flags via -- ...)");
    const run_bystander_cmd = b.addRunArtifact(bystander_exe);
    if (b.args) |args| run_bystander_cmd.addArgs(args);
    run_bystander_step.dependOn(&run_bystander_cmd.step);
}
