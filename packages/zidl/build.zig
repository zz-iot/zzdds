const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zidl_xtypes_mod = b.addModule("zidl_xtypes", .{
        .root_source_file = b.path("packages/zidl-xtypes/src/root.zig"),
        .target = target,
    });

    const mod = b.addModule("zidl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zidl_xtypes", .module = zidl_xtypes_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zidl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zidl", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    // ── run ───────────────────────────────────────────────────────────────────
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // ── unit tests ────────────────────────────────────────────────────────────
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests + Zig integration tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ── Zig integration tests ─────────────────────────────────────────────────
    // These use the committed golden types.zig and run CDR round-trip + vtable tests.
    const zidl_rt_mod = b.addModule("zidl_rt", .{
        .root_source_file = b.path("packages/zidl-rt/src/cdr.zig"),
        .target = target,
    });

    const golden_zig_mod = b.createModule(.{
        .root_source_file = b.path("test/golden/zig/types.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
        },
    });

    const stub_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/zig/stub_impl.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "types", .module = golden_zig_mod },
        },
    });

    const zig_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/zig/test.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "zidl_rt", .module = zidl_rt_mod },
                .{ .name = "types", .module = golden_zig_mod },
                .{ .name = "stub_impl", .module = stub_mod },
            },
        }),
    });
    const run_zig_integration = b.addRunArtifact(zig_integration_tests);
    test_step.dependOn(&run_zig_integration.step);

    // ── check_goldens tool ────────────────────────────────────────────────────
    // Bidirectional directory comparison; replaces `diff -rq` and works on all
    // platforms.  Always compiled for the host so it can run during the build.
    const check_goldens_exe = b.addExecutable(.{
        .name = "check_goldens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_goldens.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // ── golden output management ──────────────────────────────────────────────
    const golden_idl = "test/golden/types.idl";
    const golden_root = "test/golden";
    const check_root = "build-tmp/golden-check";

    const backends = [_][]const u8{ "zig", "c", "cpp", "java" };

    // regen-goldens: regenerate test/golden/<lang>/ and test/golden/<lang>-split/ in-place
    const regen_step = b.step("regen-goldens", "Regenerate test/golden/ from types.idl");
    for (backends) |lang| {
        const out_dir = b.fmt("{s}/{s}", .{ golden_root, lang });
        const regen_run = b.addRunArtifact(exe);
        regen_run.addArgs(&.{ "-b", lang, "--generate-interfaces", "-o", out_dir, golden_idl });
        regen_step.dependOn(&regen_run.step);

        const out_dir_split = b.fmt("{s}/{s}-split", .{ golden_root, lang });
        const regen_run_split = b.addRunArtifact(exe);
        regen_run_split.addArgs(&.{ "-b", lang, "--generate-interfaces", "--split-files", "-o", out_dir_split, golden_idl });
        regen_step.dependOn(&regen_run_split.step);
    }

    // check-goldens: regenerate to build-tmp/golden-check/ and compare against
    // test/golden/ using the check_goldens tool (bidirectional: missing files
    // and extra generated files both fail).  Integrated into `zig build test`.
    const check_goldens_step = b.step("check-goldens", "Verify golden files match current zidl output");
    for (backends) |lang| {
        // Single-file mode
        const gen_dir = b.fmt("{s}/{s}", .{ check_root, lang });
        const gold_dir = b.fmt("{s}/{s}", .{ golden_root, lang });
        const gen_run = b.addRunArtifact(exe);
        gen_run.addArgs(&.{ "-b", lang, "--generate-interfaces", "-o", gen_dir, golden_idl });
        const cmp = b.addRunArtifact(check_goldens_exe);
        cmp.addArg(gold_dir);
        cmp.addArg(gen_dir);
        cmp.step.dependOn(&gen_run.step);
        check_goldens_step.dependOn(&cmp.step);

        // Split-file mode
        const gen_dir_split = b.fmt("{s}/{s}-split", .{ check_root, lang });
        const gold_dir_split = b.fmt("{s}/{s}-split", .{ golden_root, lang });
        const gen_run_split = b.addRunArtifact(exe);
        gen_run_split.addArgs(&.{ "-b", lang, "--generate-interfaces", "--split-files", "-o", gen_dir_split, golden_idl });
        const cmp_split = b.addRunArtifact(check_goldens_exe);
        cmp_split.addArg(gold_dir_split);
        cmp_split.addArg(gen_dir_split);
        cmp_split.step.dependOn(&gen_run_split.step);
        check_goldens_step.dependOn(&cmp_split.step);
    }
    test_step.dependOn(check_goldens_step);

    // ── integration-test ──────────────────────────────────────────────────────
    const integ_step = b.step("integration-test", "Compile and run C/C++/Java integration tests");

    // C integration test — uses Zig's bundled clang; no external gcc needed
    {
        const c_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        });
        c_mod.addCSourceFiles(.{
            .files = &.{
                "test/integration/c/test.c",
                "test/golden/c/types_cdr.c",
                "packages/zidl-cdr/src/zidl_cdr.c",
            },
            .flags = &.{ "-std=c99", "-Wall", "-Werror" },
        });
        c_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        c_mod.addIncludePath(b.path("test/golden/c"));
        const c_exe = b.addExecutable(.{ .name = "test_c", .root_module = c_mod });
        integ_step.dependOn(&b.addRunArtifact(c_exe).step);
    }

    // C++ integration test — uses Zig's bundled clang++; no external g++ needed
    {
        const cpp_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .link_libcpp = true,
        });
        cpp_mod.addCSourceFiles(.{
            .files = &.{
                "test/integration/cpp/test.cpp",
                "test/golden/cpp/types_cdr.cpp",
            },
            .flags = &.{ "-std=c++17", "-Wall" },
        });
        cpp_mod.addCSourceFiles(.{
            .files = &.{"packages/zidl-cdr/src/zidl_cdr.c"},
            .flags = &.{ "-std=c99", "-Wall" },
        });
        cpp_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        cpp_mod.addIncludePath(b.path("test/golden/cpp"));
        const cpp_exe = b.addExecutable(.{ .name = "test_cpp", .root_module = cpp_mod });
        integ_step.dependOn(&b.addRunArtifact(cpp_exe).step);
    }

    // Java integration test — requires javac/java on PATH
    {
        const maybe_javac = b.findProgram(&.{"javac"}, &.{}) catch null;
        const maybe_java = b.findProgram(&.{"java"}, &.{}) catch null;
        if (maybe_javac != null and maybe_java != null) {
            const javac = maybe_javac.?;
            const java = maybe_java.?;
            const java_out = "build-tmp/integ-java";
            const compile_java = b.addSystemCommand(&.{
                javac,
                "-d",
                java_out,
                "test/golden/java/Types.java",
                "test/integration/java/Test.java",
            });
            const run_java = b.addSystemCommand(&.{ java, "-cp", java_out, "Test" });
            run_java.step.dependOn(&compile_java.step);
            integ_step.dependOn(&run_java.step);
        } else {
            std.log.warn("javac/java not found — skipping Java integration test", .{});
        }
    }

    // ── interop-test ──────────────────────────────────────────────────────────
    // Runs the Zig CDR interop tests against committed byte vectors.
    // Expected bytes are hardcoded in zig_interop_test.zig — no Cyclone DDS needed.
    // To regenerate the byte vectors after changing types.idl or cyclone_dump.c,
    // run: make -C interop regen CYCLONE=/path/to/cyclonedds
    const interop_step = b.step("interop-test", "Run Zig CDR interop tests (no Cyclone required)");
    const interop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("interop/zig_interop_test.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "zidl_rt", .module = zidl_rt_mod },
            },
        }),
    });
    interop_step.dependOn(&b.addRunArtifact(interop_tests).step);
}
