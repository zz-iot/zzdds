const std = @import("std");

// zig/wait-for-historical-data -- wait_for_historical_data() integration
// test, talking to zzdds's native Zig API directly. See
// docs/design/integration-test-tier.md for the full scenario spec. Two
// separate binaries (publisher/subscriber), matching zig/enable-defer's and
// zig/coherent-sets's convention.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdds_dep = b.dependency("zzdds", .{ .target = target, .optimize = optimize });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");

    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    const gen_history_event = b.addRunArtifact(zidl_exe);
    gen_history_event.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const history_event_gen_dir = gen_history_event.addOutputDirectoryArg("history-event-generated");
    gen_history_event.addFileArg(b.path("idl/history_event.idl"));

    const history_event_gen_mod = b.createModule(.{
        .root_source_file = history_event_gen_dir.path(b, "history_event.zig"),
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
        .{ .name = "history_event_gen", .module = history_event_gen_mod },
        .{ .name = "zidl_rt", .module = zidl_rt_mod },
    };

    const publisher_exe = b.addExecutable(.{
        .name = "wait_for_historical_data_publisher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("publisher.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    publisher_exe.root_module.link_libc = true;
    b.installArtifact(publisher_exe);

    const subscriber_exe = b.addExecutable(.{
        .name = "wait_for_historical_data_subscriber",
        .root_module = b.createModule(.{
            .root_source_file = b.path("subscriber.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    subscriber_exe.root_module.link_libc = true;
    b.installArtifact(subscriber_exe);

    const run_publisher_step = b.step("run-publisher", "Run wait_for_historical_data_publisher (pass extra flags via -- ...)");
    const run_publisher_cmd = b.addRunArtifact(publisher_exe);
    if (b.args) |args| run_publisher_cmd.addArgs(args);
    run_publisher_step.dependOn(&run_publisher_cmd.step);

    const run_subscriber_step = b.step("run-subscriber", "Run wait_for_historical_data_subscriber (pass extra flags via -- ...)");
    const run_subscriber_cmd = b.addRunArtifact(subscriber_exe);
    if (b.args) |args| run_subscriber_cmd.addArgs(args);
    run_subscriber_step.dependOn(&run_subscriber_cmd.step);
}
