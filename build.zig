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

    // emit-tests: compile all test binaries to zig-out/tests/ for kcov coverage analysis.
    const emit_tests_step = b.step("emit-tests", "Build test binaries for kcov coverage analysis");

    // Library self-tests
    const zzdds_tests = b.addTest(.{
        .name = "zzdds_lib",
        .root_module = zzdds_mod,
    });
    const run_zzdds_tests = b.addRunArtifact(zzdds_tests);
    test_step.dependOn(&run_zzdds_tests.step);
    emit_tests_step.dependOn(&b.addInstallArtifact(zzdds_tests, .{
        .dest_dir = .{ .override = .{ .custom = "tests" } },
    }).step);

    // Fuzz corpus regression tests (corpus cases run as ordinary Zig tests).
    // For libFuzzer use: zig build-obj the fuzz file, then link with
    //   clang -fsanitize=fuzzer,address <obj> -lc -o fuzz_<name>
    const fuzz_test_files = [_][]const u8{
        "test/fuzz/fuzz_rtps_parser.zig",
        "test/fuzz/fuzz_plcdr.zig",
    };
    for (fuzz_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod },
                },
            }),
        });
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
        emit_tests_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests" } },
        }).step);
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

    // Transport-layer tests.
    const transport_test_files = [_][]const u8{
        "test/transport/transport_interface_test.zig",
        "test/transport/lossy_transport_test.zig",
        "test/transport/tcp_transport_test.zig",
    };
    for (transport_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod },
                },
            }),
        });
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
        emit_tests_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests" } },
        }).step);
    }

    // Discovery-layer tests.
    const discovery_test_files = [_][]const u8{
        "test/discovery/spdp_lease_test.zig",
        "test/discovery/sedp_test.zig",
        "test/discovery/discovery_interface_test.zig",
    };
    for (discovery_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod },
                },
            }),
        });
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
        emit_tests_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests" } },
        }).step);
    }

    // Per-subsystem test runners.
    const rtps_test_files = [_][]const u8{
        "test/rtps/writer_sm_test.zig",
        "test/rtps/writer_model_test.zig",
        "test/rtps/reader_sm_test.zig",
        "test/rtps/reader_model_test.zig",
        "test/rtps/sequence_number_test.zig",
        "test/rtps/mock_transport_test.zig",
        "test/rtps/frag_roundtrip_test.zig",
        "test/rtps/rtps_integration_test.zig",
    };
    for (rtps_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod },
                },
            }),
        });
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
        emit_tests_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests" } },
        }).step);
    }

    // DCPS-level integration tests (need both zzdds and zzdds_generated).
    const dcps_test_files = [_][]const u8{
        "test/dcps/loopback_test.zig",
        "test/dcps/api_test.zig",
        "test/dcps/mock_loopback_test.zig",
        "test/dcps/presentation_model_test.zig",
        "test/dcps/subscriber_model_test.zig",
        "test/dcps/ignore_test.zig",
        "test/dcps/intraprocess_test.zig",
        "test/dcps/qos_runtime_test.zig",
        "test/dcps/instance_lifecycle_test.zig",
        "test/dcps/read_take_test.zig",
        "test/dcps/cft_test.zig",
        "test/dcps/matched_status_test.zig",
        "test/dcps/sample_rejected_test.zig",
        "test/dcps/type_support_test.zig",
        "test/dcps/entity_routing_test.zig",
        "test/dcps/wait_for_historical_test.zig",
        "test/dcps/waitset_test.zig",
        "test/dcps/pubsub_vtable_test.zig",
        "test/dcps/topic_vtable_test.zig",
        "test/dcps/reader_vtable_test.zig",
        "test/dcps/factory_vtable_test.zig",
        "test/dcps/writer_vtable_test.zig",
    };
    for (dcps_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod },
                    .{ .name = "zzdds_generated", .module = generated_dcps_mod },
                },
            }),
        });
        t.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(t).step);
        emit_tests_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests" } },
        }).step);
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
}
