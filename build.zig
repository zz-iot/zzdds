const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzdds_version = "0.1.1-zig.0.16.0-dev";

    // ── Dependencies ──────────────────────────────────────────────────────────

    const zidl_dep = b.dependency("zidl", .{ .target = target, .optimize = optimize });
    const zidl_exe = zidl_dep.artifact("zidl");
    const zidl_rt_mod = zidl_dep.module("zidl_rt");

    // ── Language binding flags ────────────────────────────────────────────────
    //
    // Declared early because they affect what gets generated for dcps.idl.
    // Zig is always generated (it is the native runtime, not a binding).
    // Other bindings are opt-in.  Python, .NET, and Rust zig-ffi are not yet
    // implemented; their flags are noted here for when they arrive — each will
    // also set need_c_abi since they call into the C ABI layer.

    const c_binding = b.option(bool, "c-binding", "Generate C language binding (dcps.h + libzzdds)") orelse false;
    const cpp_binding = b.option(bool, "cpp-binding", "Generate C++ language binding (implies -Dc-binding)") orelse false;
    const java_binding = b.option(bool, "java-binding", "Generate Java language binding") orelse false;
    // const python_binding = b.option(bool, "python-binding", ...) orelse false;  // TODO
    // const dotnet_binding = b.option(bool, "dotnet-binding", ...) orelse false;  // TODO
    // const rust_binding   = b.option(bool, "rust-binding",   ...) orelse false;  // TODO

    // C ABI layer is a shared prerequisite for C, C++, Python, .NET, Rust zig-ffi.
    const need_c_abi = c_binding or cpp_binding;

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
    });
    // pub export fn callconv(.c) wrappers are only needed when building a C-ABI
    // binding; skip them for pure-Zig builds to avoid unused symbol overhead.
    if (need_c_abi) gen_dcps.addArg("--zig-generate-c-api");
    gen_dcps.addArg("-o");
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

    // ── Code generation: idl/zzdds.idl → generated/zzdds.zig ─────────────────
    //
    // Generates vendor-extension types (DomainParticipantConfig, etc.).
    // --single-file: avoids root/module filename collision (stem == module == "zzdds")
    // --no-typesupport/--no-typeobject-support: vendor structs need no DDS scaffolding
    // Output goes into its own directory; a build-generated DDS.zig shim below
    // resolves @import("DDS.zig") back to the generated DCPS module.

    const gen_zzdds_vendor = b.addRunArtifact(zidl_exe);
    gen_zzdds_vendor.addArgs(&.{
        "-b",                    "zig",
        "--generate-interfaces", "--single-file",
        "--no-typesupport",      "--no-typeobject-support",
    });
    if (need_c_abi) gen_zzdds_vendor.addArg("--zig-generate-c-api");
    gen_zzdds_vendor.addArg("-o");
    const gen_zzdds_output_dir = gen_zzdds_vendor.addOutputDirectoryArg("zzdds-generated-ext");
    gen_zzdds_vendor.addFileArg(b.path("idl/zzdds.idl"));

    const gen_zzdds_module_files = b.addWriteFiles();
    const generated_zzdds_root = gen_zzdds_module_files.addCopyFile(
        gen_zzdds_output_dir.path(b, "zzdds.zig"),
        "zzdds.zig",
    );
    // DDS.zig shim: re-exports the subset of DDS types referenced by idl/zzdds.idl.
    // When a new DDS type is added to the extension IDL, add it here too or the
    // generated zzdds.zig will fail to compile with an opaque "unknown identifier"
    // error rather than a diagnostic pointing to this file.
    _ = gen_zzdds_module_files.add("DDS.zig",
        \\const Generated = @import("zzdds_generated").DDS;
        \\
        \\pub const DataReader = Generated.DataReader;
        \\pub const DataWriter = Generated.DataWriter;
        \\pub const DataWriterListener = Generated.DataWriterListener;
        \\pub const DomainId_t = Generated.DomainId_t;
        \\pub const DomainParticipant = Generated.DomainParticipant;
        \\pub const DomainParticipantListener = Generated.DomainParticipantListener;
        \\pub const DomainParticipantFactory = Generated.DomainParticipantFactory;
        \\pub const DomainParticipantQos = Generated.DomainParticipantQos;
        \\pub const DomainParticipantFactoryQos = Generated.DomainParticipantFactoryQos;
        \\pub const DurabilityQosPolicyKind = Generated.DurabilityQosPolicyKind;
        \\pub const HistoryQosPolicyKind = Generated.HistoryQosPolicyKind;
        \\pub const InstanceHandle_t = Generated.InstanceHandle_t;
        \\pub const LivelinessLostStatus = Generated.LivelinessLostStatus;
        \\pub const OfferedDeadlineMissedStatus = Generated.OfferedDeadlineMissedStatus;
        \\pub const OfferedIncompatibleQosStatus = Generated.OfferedIncompatibleQosStatus;
        \\pub const PublicationMatchedStatus = Generated.PublicationMatchedStatus;
        \\pub const ReliabilityQosPolicyKind = Generated.ReliabilityQosPolicyKind;
        \\pub const ReturnCode_t = Generated.ReturnCode_t;
        \\pub const StatusCondition = Generated.StatusCondition;
        \\pub const StatusMask = Generated.StatusMask;
        \\pub const Topic = Generated.Topic;
        \\pub const TopicDescription = Generated.TopicDescription;
        \\
    );
    const generated_zzdds_mod = b.addModule("zzdds_ext_generated", .{
        .root_source_file = generated_zzdds_root,
        .target = target,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds_generated", .module = generated_dcps_mod },
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
            .{ .name = "zzdds_ext_generated", .module = generated_zzdds_mod },
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
    gen_only_step.dependOn(&gen_zzdds_vendor.step);
    gen_only_step.dependOn(&gen_rtps_disc.step);

    // ── C language binding ────────────────────────────────────────────────────

    const binding_smoke_step = b.step("test-bindings", "Compile and run Zig/C/C++ binding smoke tests");
    const smoke_idl = b.path("test/bindings/smoke/binding_smoke.idl");

    const dds_adapter_mod = b.createModule(.{
        .root_source_file = b.path("test/bindings/smoke/zig_dds_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gen_smoke_zig = b.addRunArtifact(zidl_exe);
    gen_smoke_zig.addArgs(&.{ "-b", "zig", "--generate-zzdds-wrappers", "-o" });
    const gen_smoke_zig_dir = gen_smoke_zig.addOutputDirectoryArg("zzdds-binding-smoke-zig");
    gen_smoke_zig.addFileArg(smoke_idl);

    const generated_smoke_mod = b.createModule(.{
        .root_source_file = gen_smoke_zig_dir.path(b, "binding_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds", .module = dds_adapter_mod },
        },
    });

    const zig_smoke_mod = b.createModule(.{
        .root_source_file = b.path("test/bindings/smoke/zig_smoke.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds", .module = dds_adapter_mod },
            .{ .name = "binding_smoke", .module = generated_smoke_mod },
        },
    });
    const zig_smoke = b.addExecutable(.{ .name = "zzdds_zig_binding_smoke", .root_module = zig_smoke_mod });
    binding_smoke_step.dependOn(&b.addRunArtifact(zig_smoke).step);

    if (need_c_abi) {
        // Generate dcps.h and dcps_cdr.c from dcps.idl.
        // (dcps_iface.c no longer generated; free function impls come from
        // --generate-c-api in Phase 3)
        const gen_dcps_c = b.addRunArtifact(zidl_exe);
        gen_dcps_c.addArgs(&.{ "-b", "c", "--generate-interfaces", "-o" });
        const gen_c_dir = gen_dcps_c.addOutputDirectoryArg("zzdds-c-binding");
        if (xtypes) gen_dcps_c.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
        gen_dcps_c.addFileArg(dcps_idl);

        gen_only_step.dependOn(&gen_dcps_c.step);

        const gen_zzdds_c = b.addRunArtifact(zidl_exe);
        gen_zzdds_c.addArgs(&.{ "-b", "c", "--generate-interfaces", "-o" });
        const gen_zzdds_c_dir = gen_zzdds_c.addOutputDirectoryArg("zzdds-c-ext-binding");
        gen_zzdds_c.addFileArg(b.path("idl/zzdds.idl"));
        gen_only_step.dependOn(&gen_zzdds_c.step);

        // Install dcps.h → zig-out/include/
        const install_dcps_h = b.addInstallFileWithDir(
            gen_c_dir.path(b, "dcps.h"),
            .header,
            "dcps.h",
        );
        b.getInstallStep().dependOn(&install_dcps_h.step);

        const install_zzdds_h = b.addInstallFileWithDir(
            gen_zzdds_c_dir.path(b, "zzdds.h"),
            .header,
            "zzdds.h",
        );
        b.getInstallStep().dependOn(&install_zzdds_h.step);

        // Install zidl_cdr.h → zig-out/include/  (C users need it; dcps.h includes it)
        const install_zidl_cdr_h = b.addInstallFileWithDir(
            zidl_dep.path("packages/zidl-cdr/include/zidl_cdr.h"),
            .header,
            "zidl_cdr.h",
        );
        b.getInstallStep().dependOn(&install_zidl_cdr_h.step);

        // Install zidl_allocator.h → zig-out/include/  (C/C++ users need it; zzdds_c.h includes it)
        const install_zidl_allocator_h = b.addInstallFileWithDir(
            zidl_dep.path("packages/zidl-cdr/include/zidl_allocator.h"),
            .header,
            "zidl_allocator.h",
        );
        b.getInstallStep().dependOn(&install_zidl_allocator_h.step);

        // Install zidl_allocator_pmr.hpp → zig-out/include/  (C++ users need it;
        // generated _getOrCreate and zzdds_cpp.hpp both include it — cpp-binding only,
        // it's a C++ header)
        if (cpp_binding) {
            const install_zidl_allocator_pmr_hpp = b.addInstallFileWithDir(
                zidl_dep.path("packages/zidl-cdr/include/zidl_allocator_pmr.hpp"),
                .header,
                "zidl_allocator_pmr.hpp",
            );
            b.getInstallStep().dependOn(&install_zidl_allocator_pmr_hpp.step);
        }

        const install_zzdds_c_h = b.addInstallFileWithDir(
            b.path("include/zzdds_c.h"),
            .header,
            "zzdds_c.h",
        );
        b.getInstallStep().dependOn(&install_zzdds_c_h.step);

        // Install the zidl code-generator binary → bin/zidl.
        // Consumers use it to regenerate typed wrappers for their own IDL.
        b.installArtifact(zidl_exe);

        // Build and install the CDR runtime as a pre-compiled static library.
        // C/C++ users link against libzidl_cdr.a rather than compiling zidl_cdr.c
        // from source; the header-only interface (zidl_cdr.h) is already installed above.
        const zidl_cdr_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        zidl_cdr_mod.addCSourceFile(.{
            .file = zidl_dep.path("packages/zidl-cdr/src/zidl_cdr.c"),
            .flags = &.{"-std=c99"},
        });
        zidl_cdr_mod.addIncludePath(zidl_dep.path("packages/zidl-cdr/include"));
        const zidl_cdr_lib = b.addLibrary(.{
            .name = "zidl_cdr",
            .linkage = .static,
            .root_module = zidl_cdr_mod,
        });
        b.installArtifact(zidl_cdr_lib);

        // Build libzzdds as a shared library exposing the C ABI surface.
        const zzdds_lib = b.addLibrary(.{
            .name = "zzdds",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zidl_rt", .module = zidl_rt_mod },
                    .{ .name = "zzdds_generated", .module = generated_dcps_mod },
                    .{ .name = "zzdds_ext_generated", .module = generated_zzdds_mod },
                    .{ .name = "zzdds_disc_generated", .module = generated_rtps_disc_mod },
                },
            }),
        });
        zzdds_lib.root_module.addOptions("build_options", build_options);
        zzdds_lib.root_module.link_libc = true;
        if (target.result.os.tag == .windows) {
            zzdds_lib.root_module.linkSystemLibrary("ws2_32", .{});
        }
        b.installArtifact(zzdds_lib);

        const gen_smoke_c = b.addRunArtifact(zidl_exe);
        gen_smoke_c.addArgs(&.{ "-b", "c", "--generate-zzdds-wrappers", "-o" });
        const gen_smoke_c_dir = gen_smoke_c.addOutputDirectoryArg("zzdds-binding-smoke-c");
        gen_smoke_c.addFileArg(smoke_idl);

        const c_smoke_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        });
        c_smoke_mod.addCSourceFiles(.{
            .files = &.{"test/bindings/smoke/c_smoke.c"},
            .flags = &.{ "-std=c99", "-Wall" },
        });
        c_smoke_mod.addCSourceFile(.{
            .file = gen_smoke_c_dir.path(b, "binding_smoke_cdr.c"),
            .flags = &.{ "-std=c99", "-Wall" },
        });
        c_smoke_mod.addCSourceFile(.{
            .file = zidl_dep.path("packages/zidl-cdr/src/zidl_cdr.c"),
            .flags = &.{ "-std=c99", "-Wall" },
        });
        c_smoke_mod.addIncludePath(gen_smoke_c_dir);
        c_smoke_mod.addIncludePath(gen_c_dir);
        c_smoke_mod.addIncludePath(gen_zzdds_c_dir);
        c_smoke_mod.addIncludePath(zidl_dep.path("packages/zidl-cdr/include"));
        c_smoke_mod.addIncludePath(b.path("include"));
        c_smoke_mod.linkLibrary(zzdds_lib);
        const c_smoke = b.addExecutable(.{ .name = "zzdds_c_binding_smoke", .root_module = c_smoke_mod });
        binding_smoke_step.dependOn(&b.addRunArtifact(c_smoke).step);

        if (cpp_binding) {
            const gen_smoke_cpp = b.addRunArtifact(zidl_exe);
            gen_smoke_cpp.addArgs(&.{ "-b", "cpp", "--generate-zzdds-wrappers", "-o" });
            const gen_smoke_cpp_dir = gen_smoke_cpp.addOutputDirectoryArg("zzdds-binding-smoke-cpp");
            gen_smoke_cpp.addFileArg(smoke_idl);

            const cpp_smoke_mod = b.createModule(.{
                .root_source_file = null,
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .link_libcpp = true,
            });
            cpp_smoke_mod.addCSourceFiles(.{
                .files = &.{"test/bindings/smoke/cpp_smoke.cpp"},
                .flags = &.{ "-std=c++17", "-Wall" },
            });
            cpp_smoke_mod.addCSourceFile(.{
                .file = gen_smoke_cpp_dir.path(b, "binding_smoke_cdr.cpp"),
                .flags = &.{ "-std=c++17", "-Wall" },
            });
            cpp_smoke_mod.addCSourceFile(.{
                .file = zidl_dep.path("packages/zidl-cdr/src/zidl_cdr.c"),
                .flags = &.{ "-std=c99", "-Wall" },
            });
            cpp_smoke_mod.addIncludePath(gen_smoke_cpp_dir);
            cpp_smoke_mod.addIncludePath(gen_c_dir);
            cpp_smoke_mod.addIncludePath(gen_zzdds_c_dir);
            cpp_smoke_mod.addIncludePath(zidl_dep.path("packages/zidl-cdr/include"));
            cpp_smoke_mod.addIncludePath(b.path("include"));
            cpp_smoke_mod.linkLibrary(zzdds_lib);
            const cpp_smoke = b.addExecutable(.{ .name = "zzdds_cpp_binding_smoke", .root_module = cpp_smoke_mod });
            binding_smoke_step.dependOn(&b.addRunArtifact(cpp_smoke).step);
        }

        // Generate and install lib/pkgconfig/zzdds.pc.
        // The prefix is baked in at install time (matches --prefix, defaulting to zig-out/).
        const pc_content = b.fmt(
            \\prefix={s}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: zzdds
            \\Description: Zenzen DDS — DDS implementation for Zig/C/C++
            \\Version: {s}
            \\Libs: -L${{libdir}} -lzzdds -lzidl_cdr
            \\Cflags: -I${{includedir}}
            \\
        , .{ b.install_prefix, zzdds_version });
        const pc_wf = b.addWriteFiles();
        const pc_lp = pc_wf.add("zzdds.pc", pc_content);
        const install_pc = b.addInstallFileWithDir(pc_lp, .{ .custom = "lib/pkgconfig" }, "zzdds.pc");
        b.getInstallStep().dependOn(&install_pc.step);

        // Generate and install lib/cmake/ZZDDS/zzdds-config.cmake.
        // Uses get_filename_component to derive prefix relative to the config
        // file location, so the install tree is relocatable.
        const cmake_cfg_content = b.fmt(
            \\# Generated by the zzdds build system — do not edit.
            \\cmake_minimum_required(VERSION 3.14)
            \\
            \\get_filename_component(_ZZDDS_DIR "${{CMAKE_CURRENT_LIST_FILE}}" DIRECTORY)
            \\get_filename_component(_ZZDDS_PREFIX "${{_ZZDDS_DIR}}/../../.." ABSOLUTE)
            \\
            \\if(NOT TARGET ZZDDS::zzdds)
            \\    add_library(ZZDDS::zzdds SHARED IMPORTED)
            \\    find_library(_ZZDDS_SHLIB
            \\        NAMES zzdds
            \\        HINTS "${{_ZZDDS_PREFIX}}/lib"
            \\        NO_DEFAULT_PATH
            \\    )
            \\    if(NOT _ZZDDS_SHLIB)
            \\        message(FATAL_ERROR "ZZDDS: libzzdds not found under ${{_ZZDDS_PREFIX}}/lib")
            \\    endif()
            \\    set_target_properties(ZZDDS::zzdds PROPERTIES
            \\        IMPORTED_LOCATION "${{_ZZDDS_SHLIB}}"
            \\        INTERFACE_INCLUDE_DIRECTORIES "${{_ZZDDS_PREFIX}}/include"
            \\    )
            \\    unset(_ZZDDS_SHLIB CACHE)
            \\endif()
            \\
            \\if(NOT TARGET ZZDDS::zidl_cdr)
            \\    add_library(ZZDDS::zidl_cdr STATIC IMPORTED)
            \\    find_library(_ZZDDS_CDR_LIB
            \\        NAMES zidl_cdr
            \\        HINTS "${{_ZZDDS_PREFIX}}/lib"
            \\        NO_DEFAULT_PATH
            \\    )
            \\    if(NOT _ZZDDS_CDR_LIB)
            \\        message(FATAL_ERROR "ZZDDS: zidl_cdr library not found under ${{_ZZDDS_PREFIX}}/lib")
            \\    endif()
            \\    set_target_properties(ZZDDS::zidl_cdr PROPERTIES
            \\        IMPORTED_LOCATION "${{_ZZDDS_CDR_LIB}}"
            \\        INTERFACE_INCLUDE_DIRECTORIES "${{_ZZDDS_PREFIX}}/include"
            \\    )
            \\    unset(_ZZDDS_CDR_LIB CACHE)
            \\endif()
            \\
            \\set(ZZDDS_ZIDL_EXECUTABLE "${{_ZZDDS_PREFIX}}/bin/zidl")
            \\set(ZZDDS_DCPS_IMPL_CPP   "${{_ZZDDS_PREFIX}}/src/dcps_impl.cpp")
            \\set(ZZDDS_ZZDDS_IMPL_CPP  "${{_ZZDDS_PREFIX}}/src/zzdds_impl.cpp")
            \\set(ZZDDS_VERSION         "{s}")
            \\set(ZZDDS_FOUND           TRUE)
            \\
            \\unset(_ZZDDS_DIR)
            \\unset(_ZZDDS_PREFIX)
            \\
        , .{zzdds_version});
        const cmake_wf = b.addWriteFiles();
        const cmake_lp = cmake_wf.add("zzdds-config.cmake", cmake_cfg_content);
        const install_cmake = b.addInstallFileWithDir(cmake_lp, .{ .custom = "lib/cmake/ZZDDS" }, "zzdds-config.cmake");
        b.getInstallStep().dependOn(&install_cmake.step);
    }

    // ── C++ language binding ──────────────────────────────────────────────────

    if (cpp_binding) {
        const gen_dcps_cpp = b.addRunArtifact(zidl_exe);
        gen_dcps_cpp.addArgs(&.{ "-b", "cpp", "--generate-interfaces", "-o" });
        const gen_cpp_dir = gen_dcps_cpp.addOutputDirectoryArg("zzdds-cpp-binding");
        if (xtypes) gen_dcps_cpp.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
        gen_dcps_cpp.addFileArg(dcps_idl);

        gen_only_step.dependOn(&gen_dcps_cpp.step);

        const gen_zzdds_cpp = b.addRunArtifact(zidl_exe);
        gen_zzdds_cpp.addArgs(&.{ "-b", "cpp", "--generate-interfaces", "-o" });
        const gen_zzdds_cpp_dir = gen_zzdds_cpp.addOutputDirectoryArg("zzdds-cpp-ext-binding");
        gen_zzdds_cpp.addFileArg(b.path("idl/zzdds.idl"));
        gen_only_step.dependOn(&gen_zzdds_cpp.step);

        const install_dcps_hpp = b.addInstallFileWithDir(
            gen_cpp_dir.path(b, "dcps.hpp"),
            .header,
            "dcps.hpp",
        );
        b.getInstallStep().dependOn(&install_dcps_hpp.step);

        const install_zzdds_hpp = b.addInstallFileWithDir(
            gen_zzdds_cpp_dir.path(b, "zzdds.hpp"),
            .header,
            "zzdds.hpp",
        );
        b.getInstallStep().dependOn(&install_zzdds_hpp.step);

        // Generate dcps_impl.hpp + dcps_impl.cpp (B1+B3 concrete Impl + listener bridges).
        const gen_dcps_cpp_impl = b.addRunArtifact(zidl_exe);
        gen_dcps_cpp_impl.addArgs(&.{ "-b", "cpp", "--cpp-generate-impl", "-o" });
        const gen_cpp_impl_dir = gen_dcps_cpp_impl.addOutputDirectoryArg("zzdds-cpp-impl");
        if (xtypes) gen_dcps_cpp_impl.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
        gen_dcps_cpp_impl.addFileArg(dcps_idl);

        gen_only_step.dependOn(&gen_dcps_cpp_impl.step);

        const gen_zzdds_cpp_impl = b.addRunArtifact(zidl_exe);
        gen_zzdds_cpp_impl.addArgs(&.{ "-b", "cpp", "--cpp-generate-impl", "-o" });
        const gen_zzdds_cpp_impl_dir = gen_zzdds_cpp_impl.addOutputDirectoryArg("zzdds-cpp-ext-impl");
        gen_zzdds_cpp_impl.addFileArg(b.path("idl/zzdds.idl"));
        gen_only_step.dependOn(&gen_zzdds_cpp_impl.step);

        // Install dcps_impl.hpp → include/dcps_impl.hpp
        const install_dcps_impl_hpp = b.addInstallFileWithDir(
            gen_cpp_impl_dir.path(b, "dcps_impl.hpp"),
            .header,
            "dcps_impl.hpp",
        );
        b.getInstallStep().dependOn(&install_dcps_impl_hpp.step);

        const install_zzdds_impl_hpp = b.addInstallFileWithDir(
            gen_zzdds_cpp_impl_dir.path(b, "zzdds_impl.hpp"),
            .header,
            "zzdds_impl.hpp",
        );
        b.getInstallStep().dependOn(&install_zzdds_impl_hpp.step);

        const install_zzdds_cpp_hpp = b.addInstallFileWithDir(
            b.path("include/zzdds_cpp.hpp"),
            .header,
            "zzdds_cpp.hpp",
        );
        b.getInstallStep().dependOn(&install_zzdds_cpp_hpp.step);

        // Install dcps_impl.cpp → src/dcps_impl.cpp (source file for user compilation).
        // Users add this to their C++ build; it depends on dcps.hpp, dcps.h, zzdds_c.h.
        const install_dcps_impl_cpp = b.addInstallFileWithDir(
            gen_cpp_impl_dir.path(b, "dcps_impl.cpp"),
            .{ .custom = "src" },
            "dcps_impl.cpp",
        );
        b.getInstallStep().dependOn(&install_dcps_impl_cpp.step);

        const install_zzdds_impl_cpp = b.addInstallFileWithDir(
            gen_zzdds_cpp_impl_dir.path(b, "zzdds_impl.cpp"),
            .{ .custom = "src" },
            "zzdds_impl.cpp",
        );
        b.getInstallStep().dependOn(&install_zzdds_impl_cpp.step);
    }

    // ── Java language binding ─────────────────────────────────────────────────

    if (java_binding) {
        const gen_dcps_java = b.addRunArtifact(zidl_exe);
        gen_dcps_java.addArgs(&.{ "-b", "java", "--generate-interfaces", "-o" });
        const gen_java_dir = gen_dcps_java.addOutputDirectoryArg("zzdds-java-binding");
        if (xtypes) gen_dcps_java.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
        gen_dcps_java.addFileArg(dcps_idl);

        gen_only_step.dependOn(&gen_dcps_java.step);

        const gen_zzdds_java = b.addRunArtifact(zidl_exe);
        gen_zzdds_java.addArgs(&.{ "-b", "java", "--generate-interfaces", "-o" });
        const gen_zzdds_java_dir = gen_zzdds_java.addOutputDirectoryArg("zzdds-java-ext-binding");
        gen_zzdds_java.addFileArg(b.path("idl/zzdds.idl"));
        gen_only_step.dependOn(&gen_zzdds_java.step);

        // Install generated Java sources → zig-out/java/
        const install_java = b.addInstallDirectory(.{
            .source_dir = gen_java_dir,
            .install_dir = .{ .custom = "java" },
            .install_subdir = "",
        });
        b.getInstallStep().dependOn(&install_java.step);

        const install_zzdds_java = b.addInstallDirectory(.{
            .source_dir = gen_zzdds_java_dir,
            .install_dir = .{ .custom = "java" },
            .install_subdir = "",
        });
        b.getInstallStep().dependOn(&install_zzdds_java.step);
    }

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
        "test/rtps/stateless_writer_test.zig",
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
        "test/c_abi/typesupport_test.zig",
        "test/c_abi/bootstrap_test.zig",
        "test/dcps/entity_routing_test.zig",
        "test/dcps/wait_for_historical_test.zig",
        "test/dcps/waitset_test.zig",
        "test/dcps/pubsub_vtable_test.zig",
        "test/dcps/topic_vtable_test.zig",
        "test/dcps/reader_vtable_test.zig",
        "test/dcps/factory_vtable_test.zig",
        "test/dcps/participant_vtable_test.zig",
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
                    .{ .name = "zidl_rt", .module = zidl_rt_mod },
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
            .{ .name = "zzdds_ext_generated", .module = generated_zzdds_mod },
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
                .{ .name = "zidl_rt", .module = zidl_rt_mod },
            },
        }) });
        t.root_module.link_libc = true;
        tsan_step.dependOn(&b.addRunArtifact(t).step);
    }
}
