const std = @import("std");

// zig/waitset -- WaitSet + all four condition types (GuardCondition,
// StatusCondition, ReadCondition, QueryCondition), talking to zzdds's
// native Zig API directly. See docs/design/waitset-reference-app.md at the
// repo root for the full spec. Two separate binaries (publisher/subscriber),
// matching zig/hello_world's convention.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Forwarded to zzdds so both the writer/subscriber's own conditions/
    // watchdog-thread code AND every zzdds internal thread (timer, SPDP,
    // heartbeat, UDP receive) run under ThreadSanitizer together -- this
    // example's whole point includes exercising real concurrency (app
    // threads and zzdds's own middleware threads touching the same
    // WaitSet/conditions), so both sides need the same instrumentation for
    // TSAN to see the full picture.
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;

    const zzdds_dep = b.dependency("zzdds", .{
        .target = target,
        .optimize = optimize,
        .@"sanitize-thread" = sanitize_thread,
    });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");
    const zzdds_ext_gen = zzdds_dep.module("zzdds_ext_generated");

    // See zig/hello_world's build.zig for why these come *through* zzdds
    // rather than as a second, independent zidl dependency.
    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    // Generate WaitsetSample's Zig bindings from idl/waitset_sample.idl.
    const gen_sample = b.addRunArtifact(zidl_exe);
    gen_sample.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const sample_gen_dir = gen_sample.addOutputDirectoryArg("waitset-generated");
    gen_sample.addFileArg(b.path("idl/waitset_sample.idl"));

    const sample_gen_mod = b.createModule(.{
        .root_source_file = sample_gen_dir.path(b, "waitset_sample.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds", .module = zzdds_mod },
        },
    });

    const common_imports = &[_]std.Build.Module.Import{
        .{ .name = "zzdds", .module = zzdds_mod },
        .{ .name = "zzdds_generated", .module = zzdds_gen },
        .{ .name = "zzdds_ext_generated", .module = zzdds_ext_gen },
        .{ .name = "waitset_sample_gen", .module = sample_gen_mod },
        .{ .name = "zidl_rt", .module = zidl_rt_mod },
    };

    // Zig 0.16's self-hosted backend silently no-ops sanitize_thread
    // without .use_llvm = true (confirmed empirically upstream in zzdds's
    // own build.zig) -- force the LLVM backend whenever TSan is requested,
    // on every TSan-tagged Compile step (each is its own independent
    // backend decision, regardless of what imported modules request).
    const use_llvm = if (sanitize_thread) true else null;

    const pub_exe = b.addExecutable(.{
        .name = "waitset_pub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("publisher.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .imports = common_imports,
        }),
        .use_llvm = use_llvm,
    });
    pub_exe.root_module.link_libc = true;
    b.installArtifact(pub_exe);

    const sub_exe = b.addExecutable(.{
        .name = "waitset_sub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("subscriber.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .imports = common_imports,
        }),
        .use_llvm = use_llvm,
    });
    sub_exe.root_module.link_libc = true;
    b.installArtifact(sub_exe);

    const run_pub_step = b.step("run-pub", "Run waitset_pub (pass extra flags via -- ...)");
    const run_pub_cmd = b.addRunArtifact(pub_exe);
    if (b.args) |args| run_pub_cmd.addArgs(args);
    run_pub_step.dependOn(&run_pub_cmd.step);

    const run_sub_step = b.step("run-sub", "Run waitset_sub (pass extra flags via -- ...)");
    const run_sub_cmd = b.addRunArtifact(sub_exe);
    if (b.args) |args| run_sub_cmd.addArgs(args);
    run_sub_step.dependOn(&run_sub_cmd.step);
}
