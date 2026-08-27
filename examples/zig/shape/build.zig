const std = @import("std");

// zig/shape -- native-Zig port of dds-rtps's srcZig/shape_main.zig against a
// local zzdds checkout. See docs/design/shape-reference-app.md at the repo
// root for the full spec; this is step 1 (Zig first, the one real existing
// port, lowest risk, becomes the CLI/behavior reference C/C++/Java are built
// against).

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const LogLevel = enum { err, warn, info, debug };
    const default_log_level: LogLevel = switch (optimize) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
    };
    const log_level = b.option(LogLevel, "log-level", "shape_main std.log level: err, warn, info, debug (default matches Zig build mode)") orelse default_log_level;
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;

    const zzdds_dep = b.dependency("zzdds", .{ .target = target, .optimize = optimize, .@"sanitize-thread" = sanitize_thread });
    const zzdds_mod = zzdds_dep.module("zzdds");
    const zzdds_gen = zzdds_dep.module("zzdds_generated");

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

    // "dds" shim module (see dds_impl.zig) -- shape_main.zig's vendor-agnostic
    // interface contract, implemented here against zzdds directly.
    const dds_mod = b.createModule(.{
        .root_source_file = b.path("dds_impl.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zzdds", .module = zzdds_mod },
            .{ .name = "zzdds_generated", .module = zzdds_gen },
        },
    });

    // Generate ShapeType Zig bindings from idl/shape.idl. The generated
    // shape.zig's ShapeTypeDataWriter/ShapeTypeDataReader call into dds_mod
    // via @import("dds").
    const gen_shape = b.addRunArtifact(zidl_exe);
    gen_shape.addArgs(&.{ "-b", "zig", "--split-files", "--generate-zzdds-wrappers", "-o" });
    const shape_gen_dir = gen_shape.addOutputDirectoryArg("shape-generated");
    gen_shape.addFileArg(b.path("idl/shape.idl"));

    const shape_gen_mod = b.createModule(.{
        .root_source_file = shape_gen_dir.path(b, "shape.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds", .module = zzdds_mod },
        },
    });

    const shape_main_options = b.addOptions();
    shape_main_options.addOption([]const u8, "log_level", @tagName(log_level));

    const exe = b.addExecutable(.{
        .name = "shape_main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("shape_main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "dds", .module = dds_mod },
                .{ .name = "shape_gen", .module = shape_gen_mod },
                .{ .name = "shape_main_options", .module = shape_main_options.createModule() },
            },
        }),
        // Zig 0.16's self-hosted backend silently no-ops sanitize_thread
        // without this (confirmed empirically upstream in zzdds's own
        // build.zig) -- force the LLVM backend whenever TSan is requested.
        .use_llvm = if (sanitize_thread) true else null,
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_step = b.step("run", "Run shape_main (pass mode/flags via -- -P/-S ...)");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const run_pub_step = b.step("run-pub", "Run shape_main -P (pass extra flags via -- ...)");
    const run_pub_cmd = b.addRunArtifact(exe);
    run_pub_cmd.addArg("-P");
    if (b.args) |args| run_pub_cmd.addArgs(args);
    run_pub_step.dependOn(&run_pub_cmd.step);

    const run_sub_step = b.step("run-sub", "Run shape_main -S (pass extra flags via -- ...)");
    const run_sub_cmd = b.addRunArtifact(exe);
    run_sub_cmd.addArg("-S");
    if (b.args) |args| run_sub_cmd.addArgs(args);
    run_sub_step.dependOn(&run_sub_cmd.step);
}
