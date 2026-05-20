const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Dependencies ──────────────────────────────────────────────────────────

    const zidl_dep = b.dependency("zidl", .{ .target = target, .optimize = optimize });
    const zidl_exe = zidl_dep.artifact("zidl");
    const zidl_rt_mod = zidl_dep.module("zidl_rt");

    // ── Code generation: idl/dcps.idl → generated/dcps.zig ───────────────────

    const gen_dir = "zzdds-generated";
    const dcps_idl = b.path("idl/dcps.idl");

    // Run zidl to generate Zig bindings for the DCPS IDL.
    // Output goes into the build cache (not checked in).
    // Argument order: zidl -b zig ... -o <output_dir> <input.idl>
    const gen_dcps = b.addRunArtifact(zidl_exe);
    gen_dcps.addArgs(&.{
        "-b",                    "zig",
        "--generate-interfaces", "--split-files",
        "-o",
    });
    // addOutputDirectoryArg injects the cache-managed output path as the next arg.
    const gen_output_dir = gen_dcps.addOutputDirectoryArg(gen_dir);
    gen_dcps.addFileArg(dcps_idl);

    // Build a module from the generated root file (dcps.zig re-exports all modules).
    // Exposed as a public module so external packages (e.g. dds-rtps shape_main) can
    // import DDS QoS types without duplicating the IDL code-generation step.
    const generated_dcps_mod = b.addModule("zzdds_generated", .{
        .root_source_file = gen_output_dir.path(b, "dcps.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
        },
    });

    // ── Code generation: idl/rtps_discovery.idl → generated/rtps_discovery.zig ─
    //
    // Generates PL_CDR serialize/deserialize for SPDP/SEDP discovery types.
    // --zig-pl-cdr:             emit serializePlCdr / deserializeFromPlCdr
    // --no-typesupport:         omit DataWriter/DataReader/TypeSupport scaffolding
    // --no-typeobject-support:  omit XTypes TypeObject/TypeIdentifier constants
    // --split-files:            one file per top-level module (here: single flat file)

    const rtps_disc_idl = b.path("idl/rtps_discovery.idl");

    const gen_rtps_disc = b.addRunArtifact(zidl_exe);
    gen_rtps_disc.addArgs(&.{
        "-b",                      "zig",
        "--zig-pl-cdr",            "--no-typesupport",
        "--no-typeobject-support", "--split-files",
        "-o",
    });
    const gen_rtps_disc_dir = gen_rtps_disc.addOutputDirectoryArg("zzdds-generated-rtps-disc");
    gen_rtps_disc.addFileArg(rtps_disc_idl);

    const generated_rtps_disc_mod = b.createModule(.{
        .root_source_file = gen_rtps_disc_dir.path(b, "rtps_discovery.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
        },
    });

    // ── Build-time feature flags ──────────────────────────────────────────────

    const build_options = b.addOptions();
    build_options.addOption(
        bool,
        "ipv4",
        b.option(bool, "ipv4", "Include IPv4 UDP transport (default: true)") orelse true,
    );
    build_options.addOption(
        bool,
        "ipv6",
        b.option(bool, "ipv6", "Include IPv6 UDP transport (default: true)") orelse true,
    );
    build_options.addOption(
        bool,
        "interface_monitor",
        b.option(bool, "interface-monitor", "Include interface change monitoring; if false, interfaces are enumerated once at startup (default: true)") orelse true,
    );
    build_options.addOption(
        bool,
        "wire_trace",
        b.option(bool, "wire-trace", "Include RTPS wire trace subsystem (default: false)") orelse false,
    );
    build_options.addOption(
        bool,
        "guid_filter",
        b.option(bool, "guid-filter", "Include GUID-prefix filtering in wire trace (default: false; only meaningful with wire-trace)") orelse false,
    );
    const xtypes = b.option(bool, "xtypes", "Include partial DDS-XTypes support: DataRepresentationQosPolicy and optional PID_TYPE_INFORMATION in SEDP; no TypeLookup service (default: true)") orelse true;
    build_options.addOption(bool, "xtypes", xtypes);
    build_options.addOption(
        bool,
        "content_subscription_profile",
        b.option(bool, "content-subscription-profile", "Enable Content-Subscription profile parser/evaluator for ContentFilteredTopic and QueryCondition; MultiTopic not implemented (DDS v1.4 Annex A, default: true)") orelse true,
    );
    // Pass ZZDDS_XTYPES preprocessor define to zidl so dcps.idl gates XTypes
    // content (DataRepresentationQosPolicy and its uses) at code-generation time.
    if (xtypes) gen_dcps.addArgs(&.{ "-D", "ZZDDS_XTYPES" });

    // ── Zenzen DDS library ──────────────────────────────────────────────────────

    const zzdds_mod = b.addModule("zzdds", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds_generated", .module = generated_dcps_mod },
            .{ .name = "zzdds_disc_generated", .module = generated_rtps_disc_mod },
        },
    });
    zzdds_mod.addOptions("build_options", build_options);
    zzdds_mod.link_libc = true;
    if (target.result.os.tag == .windows) {
        zzdds_mod.linkSystemLibrary("ws2_32", .{});
    }

    // ── gen-only step (debug code generation output) ──────────────────────────

    const gen_only_step = b.step("gen-only", "Run zidl code generation only");
    gen_only_step.dependOn(&gen_dcps.step);
    gen_only_step.dependOn(&gen_rtps_disc.step);

    // ── Unit tests ────────────────────────────────────────────────────────────

    const test_step = b.step("test", "Run Zenzen DDS tests");

    // Library self-tests
    const zzdds_tests = b.addTest(.{
        .root_module = zzdds_mod,
    });
    const run_zzdds_tests = b.addRunArtifact(zzdds_tests);
    test_step.dependOn(&run_zzdds_tests.step);

    // Fuzz corpus regression tests (corpus cases run as ordinary Zig tests).
    // For libFuzzer use: zig build-obj the fuzz file, then link with
    //   clang -fsanitize=fuzzer,address <obj> -lc -o fuzz_<name>
    const fuzz_test_files = [_][]const u8{
        "test/fuzz/fuzz_rtps_parser.zig",
        "test/fuzz/fuzz_plcdr.zig",
    };
    for (fuzz_test_files) |src| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod },
            },
        }) });
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // `zig build test-fuzz` — compile-check fuzz targets. Corpus regression
    // runs under `zig build test` via ordinary Zig tests in test/fuzz/.
    // For actual fuzzing: take the .o produced by `zig build-obj` and link with
    //   clang -fsanitize=fuzzer,address <obj> -lc -o fuzz_<name>
    const fuzz_step = b.step("test-fuzz", "Compile-check fuzz targets (see test/fuzz/*.zig for libFuzzer usage)");
    for (fuzz_test_files) |src| {
        const fuzz_obj = b.addObject(.{
            .name = std.fs.path.stem(src),
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod },
                },
            }),
        });
        fuzz_obj.root_module.link_libc = true;
        fuzz_step.dependOn(&fuzz_obj.step); // just build; no install
    }

    // Discovery-layer tests.
    const discovery_test_files = [_][]const u8{
        "test/discovery/spdp_lease_test.zig",
        "test/discovery/sedp_test.zig",
    };
    for (discovery_test_files) |src| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod },
            },
        }) });
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Per-subsystem test runners.
    const rtps_test_files = [_][]const u8{
        "test/rtps/writer_sm_test.zig",
        "test/rtps/reader_sm_test.zig",
        "test/rtps/sequence_number_test.zig",
        "test/rtps/mock_transport_test.zig",
        "test/rtps/frag_roundtrip_test.zig",
        "test/rtps/rtps_integration_test.zig",
    };
    for (rtps_test_files) |src| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod },
            },
        }) });
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // DCPS-level integration tests (need both zzdds and zzdds_generated).
    const dcps_test_files = [_][]const u8{
        "test/dcps/loopback_test.zig",
        "test/dcps/api_test.zig",
        "test/dcps/mock_loopback_test.zig",
        "test/dcps/ignore_test.zig",
        "test/dcps/intraprocess_test.zig",
        "test/dcps/qos_runtime_test.zig",
        "test/dcps/instance_lifecycle_test.zig",
        "test/dcps/read_take_test.zig",
        "test/dcps/cft_test.zig",
        "test/dcps/matched_status_test.zig",
        "test/dcps/sample_rejected_test.zig",
    };
    for (dcps_test_files) |src| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod },
                .{ .name = "zzdds_generated", .module = generated_dcps_mod },
            },
        }) });
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ── TSan test step ────────────────────────────────────────────────────────
    // `zig build test-tsan` — compile and run tests with ThreadSanitizer enabled.
    // Covers concurrency in state machines, WaitSet, and discovery code.

    const tsan_step = b.step("test-tsan", "Run Zenzen DDS tests under ThreadSanitizer");

    const zzdds_mod_tsan = b.addModule("zzdds_tsan", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = true,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds_generated", .module = generated_dcps_mod },
            .{ .name = "zzdds_disc_generated", .module = generated_rtps_disc_mod },
        },
    });
    zzdds_mod_tsan.addOptions("build_options", build_options);
    zzdds_mod_tsan.link_libc = true;

    // Library self-tests (TSan)
    const zzdds_tests_tsan = b.addTest(.{ .root_module = zzdds_mod_tsan });
    tsan_step.dependOn(&b.addRunArtifact(zzdds_tests_tsan).step);

    // RTPS tests (TSan) — writer_sm, reader_sm exercise concurrent send/recv
    for (rtps_test_files) |src| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .sanitize_thread = true,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod_tsan },
            },
        }) });
        t.root_module.link_libc = true;
        tsan_step.dependOn(&b.addRunArtifact(t).step);
    }

    // DCPS tests (TSan) — WaitSet thread test, loopback
    for (dcps_test_files) |src| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .sanitize_thread = true,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod_tsan },
                .{ .name = "zzdds_generated", .module = generated_dcps_mod },
            },
        }) });
        t.root_module.link_libc = true;
        tsan_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ── Interop test executables ──────────────────────────────────────────────

    const zzdds_interop_pub = b.addExecutable(.{
        .name = "zzdds_interop_pub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/interop/zzdds_pub.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod },
                .{ .name = "zzdds_generated", .module = generated_dcps_mod },
            },
        }),
    });
    b.installArtifact(zzdds_interop_pub);

    const zzdds_interop_sub = b.addExecutable(.{
        .name = "zzdds_interop_sub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/interop/zzdds_sub.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod },
                .{ .name = "zzdds_generated", .module = generated_dcps_mod },
            },
        }),
    });
    b.installArtifact(zzdds_interop_sub);

    // DATA_FRAG interop publisher: fragment_size=512, ~2 KB payload.
    const zzdds_interop_pub_frag = b.addExecutable(.{
        .name = "zzdds_interop_pub_frag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/interop/zzdds_pub_frag.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zzdds", .module = zzdds_mod },
                .{ .name = "zzdds_generated", .module = generated_dcps_mod },
            },
        }),
    });
    b.installArtifact(zzdds_interop_pub_frag);

    // ── Interop tests (require external Cyclone DDS install) ──────────────────
    // Run with: zig build interop-test-cyclone
    // Builds Zenzen DDS interop executables and then invokes test/interop/Makefile.
    const interop_step = b.step("interop-test-cyclone", "Run wire interop tests vs Cyclone DDS");
    interop_step.dependOn(&zzdds_interop_pub.step);
    interop_step.dependOn(&zzdds_interop_sub.step);
    interop_step.dependOn(&zzdds_interop_pub_frag.step);
    const maybe_interop_make = b.findProgram(&.{"make"}, &.{}) catch null;
    if (maybe_interop_make) |make_bin| {
        const make = b.addSystemCommand(&.{ make_bin, "-C", "test/interop", "interop-test-cyclone" });
        make.step.dependOn(&zzdds_interop_pub.step);
        make.step.dependOn(&zzdds_interop_sub.step);
        make.step.dependOn(&zzdds_interop_pub_frag.step);
        interop_step.dependOn(&make.step);
    }

    // ── OpenDDS interop tests (require OpenDDS at OPENDDS_ROOT) ───────────────
    // Run with: zig build interop-test-opendds
    // Builds OpenDDS C++ pub/sub via make, then runs scenarios 3–6.
    const opendds_interop_step = b.step("interop-test-opendds", "Run wire interop tests vs OpenDDS 3.33");
    opendds_interop_step.dependOn(&zzdds_interop_pub.step);
    opendds_interop_step.dependOn(&zzdds_interop_sub.step);
    opendds_interop_step.dependOn(&zzdds_interop_pub_frag.step);
    if (maybe_interop_make) |make_bin| {
        const make_opendds = b.addSystemCommand(&.{ make_bin, "-C", "test/interop", "interop-test-opendds" });
        make_opendds.step.dependOn(&zzdds_interop_pub.step);
        make_opendds.step.dependOn(&zzdds_interop_sub.step);
        make_opendds.step.dependOn(&zzdds_interop_pub_frag.step);
        opendds_interop_step.dependOn(&make_opendds.step);
    }
}
