const std = @import("std");
pub fn addTests(b: *std.Build, zzdds: *std.Build.Module, dds: *std.Build.Module, rt: *std.Build.Module, ts: *std.Build.Module, generator: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, dynamic_enabled: bool, resources_enabled: bool, abi_package: std.Build.LazyPath, inspector: ?*std.Build.Step.Compile) *std.Build.Step {
    const all = b.step("test-typesupport-platform", "Run linked and OS-loaded provider checks");
    const check = b.step("check-typesupport-library", "Compile provider libraries and host checks without running target code");
    const fixtures = if (resources_enabled) b.step("resource-provider-fixtures", "Build example provider artifacts for resource-inspect") else null;
    if (!dynamic_enabled) if (fixtures) |step| step.dependOn(&b.addFail("Dynamic provider fixtures require -Dtypesupport-dynamic=true").step);
    const paths = b.addOptions();
    const root_path = b.root.joinString(b.allocator, ".") catch @panic("out of memory");
    const absolute_root = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, root_path, b.allocator) catch @panic("cannot resolve fixture root");
    paths.addOption([]const u8, "root", absolute_root);
    paths.addOption(bool, "dynamic_enabled", dynamic_enabled);
    // Zig bundles a second sanitizer runtime into instrumented DSOs, whose
    // initial-exec TLS cannot be allocated by dlopen. Instrument the host; keep
    // the immutable, synchronous generated wire-callback fixtures uninstrumented.
    const library_rt = if (zzdds.sanitize_thread orelse false) b.createModule(.{
        .root_source_file = rt.root_source_file,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = false,
    }) else rt;
    const library_abi = if (zzdds.sanitize_thread orelse false) b.createModule(.{
        .root_source_file = ts.root_source_file,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = false,
        .imports = &.{ .{ .name = "zidl_rt", .module = library_rt }, .{ .name = "zidl_typesupport_c", .module = ts.import_table.get("zidl_typesupport_c").? } },
    }) else ts;
    var libraries: [3]?std.Build.LazyPath = .{ null, null, null };
    var linked_provider: ?*std.Build.Module = null;
    for ([_][]const u8{ "a", "b", "conflict" }, 0..) |stem, i| {
        const gen = std.Build.Step.Run.create(b, "generate provider fixture");
        gen.addFileArg(generator);
        gen.addArgs(&.{ "-b", "zig", "--experimental-typesupport-library", "-o" });
        const out = gen.addOutputDirectoryArg(stem);
        gen.addFileArg(b.path(b.fmt("test/typesupport/{s}.idl", .{stem})));
        const types = b.createModule(.{ .root_source_file = out.path(b, b.fmt("{s}.zig", .{stem})), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zidl_rt", .module = rt }} });
        const provider = b.createModule(.{
            .sanitize_thread = zzdds.sanitize_thread,
            .root_source_file = out.path(b, b.fmt("{s}_typesupport.zig", .{stem})),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "types", .module = types }, .{ .name = "zidl_rt", .module = rt }, .{ .name = "zidl_typesupport", .module = ts } },
        });
        if (std.mem.eql(u8, stem, "a")) {
            linked_provider = provider;
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
        const library_types = b.createModule(.{ .root_source_file = out.path(b, b.fmt("{s}.zig", .{stem})), .target = target, .optimize = optimize, .sanitize_thread = false, .imports = &.{.{ .name = "zidl_rt", .module = library_rt }} });
        const library_provider = b.createModule(.{
            .root_source_file = out.path(b, b.fmt("{s}_typesupport.zig", .{stem})),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = false,
            .imports = &.{ .{ .name = "types", .module = library_types }, .{ .name = "zidl_rt", .module = library_rt }, .{ .name = "zidl_typesupport", .module = library_abi } },
        });
        const lib = b.addLibrary(.{ .name = b.fmt("provider_{s}", .{stem}), .use_llvm = true, .linkage = .dynamic, .root_module = library_provider });
        libraries[i] = lib.getEmittedBin();
        paths.addOptionPath(stem, lib.getEmittedBin());
        if (fixtures) |step| step.dependOn(&b.addInstallArtifact(lib, .{}).step);
        check.dependOn(&lib.step);
    }
    if (resources_enabled) {
        const t = b.addTest(.{ .name = "resource-providers", .use_llvm = true, .root_module = b.createModule(.{
            .root_source_file = b.path("test/resources/providers_test.zig"),
            .sanitize_thread = zzdds.sanitize_thread,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "zzdds", .module = zzdds }, .{ .name = "provider_a", .module = linked_provider.? } },
        }) });
        t.root_module.addOptions("library_paths", paths);
        b.step("emit-provider-tests", "Emit LLVM provider-binding test binary").dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "provider-tests" } } }).step);
        const run = b.addRunArtifact(t);
        run.setCwd(b.path("."));
        const prepared_tests = b.step("test-resource-providers", "Check pinned multi-provider resource bindings");
        prepared_tests.dependOn(&run.step);
        if (dynamic_enabled) if (inspector) |exe| {
            inline for (.{ false, true }) |wrong_hash| {
                const inspect = b.addRunArtifact(exe);
                inspect.step.name = if (wrong_hash) "reject a mismatched provider hash" else "inspect two explicit provider libraries";
                inspect.addArgs(&.{"inspect"});
                inspect.addFileArg(b.path("examples/zig/resource-inspect/reading.toml"));
                inspect.addArg("--library");
                inspect.addPrefixedFileArg("project_a=", libraries[0].?);
                inspect.addArg("--library");
                inspect.addPrefixedFileArg("project_b=", libraries[1].?);
                inspect.addArgs(&.{ "--bind", "main/LibraryTest::Reading=project_b/LibraryTest::Reading", "--bind", "main/LibraryTest::Pulse=project_a/LibraryTest::Pulse" });
                if (wrong_hash) inspect.addArgs(&.{ "--sha256", "project_a=0000000000000000000000000000000000000000000000000000000000000000" });
                inspect.expectExitCode(if (wrong_hash) 1 else 0);
                inspect.expectStdErrMatch(if (wrong_hash) "ArtifactHashMismatch" else "no DDS entities created");
                prepared_tests.dependOn(&inspect.step);
                all.dependOn(&inspect.step);
            }
            const too_many = b.addRunArtifact(exe);
            too_many.step.name = "offline validation enforces the loader provider limit";
            too_many.addArg("validate");
            too_many.addFileArg(b.path("examples/zig/resource-inspect/reading.toml"));
            too_many.addArgs(&.{ "--bind", "main/LibraryTest::Reading=p0/LibraryTest::Reading", "--bind", "main/LibraryTest::Pulse=p1/LibraryTest::Pulse" });
            for (0..33) |i| too_many.addArgs(&.{ "--library", b.fmt("p{d}=/no-such-provider", .{i}) });
            too_many.expectExitCode(1);
            too_many.expectStdErrMatch("ProviderLimit");
            prepared_tests.dependOn(&too_many.step);
            all.dependOn(&too_many.step);
        };
        check.dependOn(&t.step);
        all.dependOn(&run.step);
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
