const std = @import("std");

// zig/delete-contained-entities -- bulk-teardown-cascade integration test,
// talking to zzdds's native Zig API directly. See
// docs/design/integration-test-tier.md for the full scenario spec. Two
// separate binaries (session/peer), matching zig/coherent-sets's convention.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdds_dep = b.dependency("zzdds", .{ .target = target, .optimize = optimize });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");
    const zzdds_ext_gen = zzdds_dep.module("zzdds_ext_generated");

    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    const gen_session_event = b.addRunArtifact(zidl_exe);
    gen_session_event.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const session_event_gen_dir = gen_session_event.addOutputDirectoryArg("session-event-generated");
    gen_session_event.addFileArg(b.path("idl/session_event.idl"));

    const session_event_gen_mod = b.createModule(.{
        .root_source_file = session_event_gen_dir.path(b, "session_event.zig"),
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
        .{ .name = "session_event_gen", .module = session_event_gen_mod },
        .{ .name = "zidl_rt", .module = zidl_rt_mod },
    };

    const session_exe = b.addExecutable(.{
        .name = "delete_contained_entities_session",
        .root_module = b.createModule(.{
            .root_source_file = b.path("session.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    session_exe.root_module.link_libc = true;
    b.installArtifact(session_exe);

    const peer_exe = b.addExecutable(.{
        .name = "delete_contained_entities_peer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("peer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    peer_exe.root_module.link_libc = true;
    b.installArtifact(peer_exe);

    const run_session_step = b.step("run-session", "Run delete_contained_entities_session (pass extra flags via -- ...)");
    const run_session_cmd = b.addRunArtifact(session_exe);
    if (b.args) |args| run_session_cmd.addArgs(args);
    run_session_step.dependOn(&run_session_cmd.step);

    const run_peer_step = b.step("run-peer", "Run delete_contained_entities_peer (pass extra flags via -- ...)");
    const run_peer_cmd = b.addRunArtifact(peer_exe);
    if (b.args) |args| run_peer_cmd.addArgs(args);
    run_peer_step.dependOn(&run_peer_cmd.step);
}
