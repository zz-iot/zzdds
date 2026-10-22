const std = @import("std");

// Called from the repository build: use the host's existing runtime module.
pub fn addExample(b: *std.Build, host: *std.Build.Module, dds: *std.Build.Module, ext: *std.Build.Module, rt: *std.Build.Module, abi: *std.Build.Module, generator: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const step = b.step("typesupport-example", "Build the loadable typesupport inspection/pub/sub example and two providers");
    for ([_][]const u8{ "sensors", "control" }) |stem| {
        const gen = std.Build.Step.Run.create(b, "generate example provider");
        gen.addFileArg(generator);
        gen.addArgs(&.{ "-b", "zig", "--experimental-typesupport-library", "-o" });
        const out = gen.addOutputDirectoryArg(stem);
        gen.addFileArg(b.path(b.fmt("examples/zig/typesupport-library/{s}.idl", .{stem})));
        const types = b.createModule(.{ .root_source_file = out.path(b, b.fmt("{s}.zig", .{stem})), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zidl_rt", .module = rt }} });
        const provider = b.createModule(.{
            .root_source_file = out.path(b, b.fmt("{s}_typesupport.zig", .{stem})),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "types", .module = types }, .{ .name = "zidl_rt", .module = rt }, .{ .name = "zidl_typesupport", .module = abi } },
        });
        const lib = b.addLibrary(.{ .name = b.fmt("demo_{s}", .{stem}), .linkage = .dynamic, .root_module = provider });
        step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    }
    const exe = b.addExecutable(.{ .name = "typesupport-demo", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/typesupport-library/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "zzdds", .module = host }, .{ .name = "zzdds_generated", .module = dds }, .{ .name = "zzdds_ext_generated", .module = ext } },
    }) });
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);
}
