const std = @import("std");

// zig/hello_world -- minimal reliable pub/sub reference app, talking to
// zzdds's native Zig API directly (no vendor-neutral "dds" shim, unlike
// zig/shape -- this example has no external CLI spec to mirror). See
// docs/design/hello-world-reference-app.md at the repo root for the full
// spec. Two separate binaries (publisher/subscriber), matching the
// c/custom-allocator and java/listener-pubsub convention rather than
// shape_main's single -P/-S flag.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdds_dep = b.dependency("zzdds", .{ .target = target, .optimize = optimize });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");
    const zzdds_ext_gen = zzdds_dep.module("zzdds_ext_generated");

    // Get zidl's executable and zidl_rt module *through* zzdds (which
    // re-exposes both) rather than declaring our own separate dependency on
    // zidl -- when zidl is a `.path` dependency (as it is during zidl+zzdds
    // co-development, pre-release), a second independent `.path` dependency
    // on the same directory doesn't get deduplicated by Zig's package
    // manager, and the build fails outright the moment one compilation unit
    // ends up importing both instances of the same file under two module
    // names ("file exists in modules 'zidl_rt' and 'zidl_rt0'"). See zzdds's
    // own build.zig for where these are re-exposed.
    const zidl_exe = zzdds_dep.artifact("zidl");
    const zidl_rt_mod = zzdds_dep.module("zidl_rt");

    // Generate HelloWorld Zig bindings from idl/hello_world.idl.
    const gen_hello = b.addRunArtifact(zidl_exe);
    gen_hello.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const hello_gen_dir = gen_hello.addOutputDirectoryArg("hello-world-generated");
    gen_hello.addFileArg(b.path("idl/hello_world.idl"));

    const hello_gen_mod = b.createModule(.{
        .root_source_file = hello_gen_dir.path(b, "hello_world.zig"),
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
        .{ .name = "hello_world_gen", .module = hello_gen_mod },
        .{ .name = "zidl_rt", .module = zidl_rt_mod },
    };

    const pub_exe = b.addExecutable(.{
        .name = "hello_world_pub",
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
        .name = "hello_world_sub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("subscriber.zig"),
            .target = target,
            .optimize = optimize,
            .imports = common_imports,
        }),
    });
    sub_exe.root_module.link_libc = true;
    b.installArtifact(sub_exe);

    const run_pub_step = b.step("run-pub", "Run hello_world_pub (pass extra flags via -- ...)");
    const run_pub_cmd = b.addRunArtifact(pub_exe);
    if (b.args) |args| run_pub_cmd.addArgs(args);
    run_pub_step.dependOn(&run_pub_cmd.step);

    const run_sub_step = b.step("run-sub", "Run hello_world_sub (pass extra flags via -- ...)");
    const run_sub_cmd = b.addRunArtifact(sub_exe);
    if (b.args) |args| run_sub_cmd.addArgs(args);
    run_sub_step.dependOn(&run_sub_cmd.step);
}
