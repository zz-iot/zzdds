const std = @import("std");
pub fn addTests(b: *std.Build, zzdds: *std.Build.Module, dds: *std.Build.Module, rt: *std.Build.Module, ts: *std.Build.Module, generator: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, dynamic_enabled: bool, abi_package: std.Build.LazyPath) *std.Build.Step {
    const all = b.step("test-typesupport-platform", "Run linked and OS-loaded provider checks");
    const check = b.step("check-typesupport-library", "Compile provider libraries and host checks without running target code");
    const paths = b.addOptions();
    const root_path = b.root.joinString(b.allocator, ".") catch @panic("out of memory");
    const absolute_root = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, root_path, b.allocator) catch @panic("cannot resolve fixture root");
    paths.addOption([]const u8, "root", absolute_root);
    paths.addOption(bool, "dynamic_enabled", dynamic_enabled);
    for ([_][]const u8{ "a", "b", "conflict" }) |stem| {
        const gen = std.Build.Step.Run.create(b, "generate provider fixture");
        gen.addFileArg(generator);
        gen.addArgs(&.{ "-b", "zig", "--experimental-typesupport-library", "-o" });
        const out = gen.addOutputDirectoryArg(stem);
        gen.addFileArg(b.path(b.fmt("test/typesupport/{s}.idl", .{stem})));
        const types = b.createModule(.{ .root_source_file = out.path(b, b.fmt("{s}.zig", .{stem})), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zidl_rt", .module = rt }} });
        const provider = b.createModule(.{
            .root_source_file = out.path(b, b.fmt("{s}_typesupport.zig", .{stem})),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "types", .module = types }, .{ .name = "zidl_rt", .module = rt }, .{ .name = "zidl_typesupport", .module = ts } },
        });
        if (std.mem.eql(u8, stem, "a")) {
            const static_test = b.addTest(.{ .name = "typesupport-static", .root_module = b.createModule(.{
                .root_source_file = b.path("test/typesupport/static_test.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{ .{ .name = "zzdds", .module = zzdds }, .{ .name = "static_provider", .module = provider } },
            }) });
            const options = b.addOptions();
            options.addOption(bool, "dynamic_enabled", dynamic_enabled);
            static_test.root_module.addOptions("provider_options", options);
            static_test.root_module.addIncludePath(abi_package.path(b, "include"));
            static_test.root_module.addCSourceFile(.{ .file = b.path("test/typesupport/c_abi_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
            check.dependOn(&static_test.step);
            const run_static = b.addRunArtifact(static_test);
            b.step("test-typesupport-static", "Run linked provider registration and C ABI checks").dependOn(&run_static.step);
            all.dependOn(&run_static.step);
        }
        if (!dynamic_enabled) continue;
        const lib = b.addLibrary(.{ .name = b.fmt("provider_{s}", .{stem}), .linkage = .dynamic, .root_module = provider });
        paths.addOptionPath(stem, lib.getEmittedBin());
        check.dependOn(&lib.step);
    }
    if (!dynamic_enabled) return all;
    const bad = b.addLibrary(.{
        .name = "provider_bad_abi",
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .root_source_file = b.path("test/typesupport/bad_abi.zig"), .target = target, .optimize = optimize }),
    });
    paths.addOptionPath("bad_abi", bad.getEmittedBin());
    const t = b.addTest(.{ .name = "typesupport-library", .root_module = b.createModule(.{
        .root_source_file = b.path("test/typesupport/library_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "zzdds", .module = zzdds }, .{ .name = "zzdds_generated", .module = dds }, .{ .name = "zidl_rt", .module = rt } },
    }) });
    t.root_module.addOptions("library_paths", paths);
    t.root_module.addIncludePath(abi_package.path(b, "include"));
    t.root_module.addCSourceFile(.{ .file = b.path("test/typesupport/c_abi_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    t.root_module.addCSourceFile(.{ .file = b.path("test/typesupport/module_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    if (target.result.os.tag == .linux) t.root_module.linkSystemLibrary("dl", .{});
    check.dependOn(&bad.step);
    check.dependOn(&t.step);
    all.dependOn(&b.addRunArtifact(t).step);
    return all;
}
