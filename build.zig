const std = @import("std");
const builtin = @import("builtin");

/// Directories containing `jni.h`/`jni_md.h` for the JDK backing `java_path`
/// (the `java` executable's own path, e.g. from `b.findProgram`). Resolves
/// symlink chains (PATH/update-alternatives-style) back to a real
/// `$JAVA_HOME/bin/java` first. Returns null if not found (e.g. a JRE-only
/// install with no JNI headers) — callers should skip the Java native build,
/// not fail it.
const JniIncludeDirs = struct { base: []const u8, platform: []const u8 };

fn findJniIncludeDir(b: *std.Build, java_path: []const u8) ?JniIncludeDirs {
    const io = b.graph.io;
    const resolved = std.Io.Dir.realPathFileAbsoluteAlloc(io, java_path, b.allocator) catch
        (b.allocator.dupeZ(u8, java_path) catch return null);
    const bin_dir = std.fs.path.dirname(resolved) orelse return null;
    const java_home = std.fs.path.dirname(bin_dir) orelse return null;
    const base = std.fs.path.join(b.allocator, &.{ java_home, "include" }) catch return null;
    const platform_name = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "win32",
        else => return null,
    };
    const platform = std.fs.path.join(b.allocator, &.{ base, platform_name }) catch return null;
    const jni_h = std.fs.path.join(b.allocator, &.{ base, "jni.h" }) catch return null;
    std.Io.Dir.cwd().access(io, jni_h, .{}) catch return null;
    return .{ .base = base, .platform = platform };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;
    const debug_allocator = b.option(bool, "debug-allocator", "Route the default (allocator=NULL) factory allocation path through std.heap.DebugAllocator instead of std.heap.c_allocator, for fast attributable double-free/UAF diagnostics") orelse false;

    const zzdds_version = "0.1.1-zig.0.16.0-dev";

    // ── Dependencies ──────────────────────────────────────────────────────────

    const zidl_dep = b.dependency("zidl", .{
        .target = target,
        .optimize = optimize,
        .@"sanitize-thread" = sanitize_thread,
    });
    const zidl_exe = zidl_dep.artifact("zidl");
    const zidl_rt_mod = zidl_dep.module("zidl_rt");

    // Re-expose zidl's own executable and `zidl_rt` module as zzdds's own, so
    // a downstream Zig consumer (e.g. a zzdds-examples zig/* example) can get
    // both *through* zzdds (`zzdds_dep.artifact("zidl")` /
    // `zzdds_dep.module("zidl_rt")`) instead of declaring its own separate
    // top-level dependency on zidl. That matters specifically when zidl is a
    // `.path` dependency (as it is while developing zidl and zzdds together,
    // pre-release): Zig's package manager doesn't deduplicate two independent
    // `.path` dependencies on the same directory declared by two different
    // build.zig files, even though they resolve to the identical files —
    // each gets instantiated as its own module, and the build then fails
    // outright ("file exists in modules 'zidl_rt' and 'zidl_rt0'") the moment
    // any single compilation unit ends up importing both. Unconditional
    // (not gated behind `need_c_abi` like the artifact install below used to
    // be) because a pure-Zig consumer needing only `zidl_rt` + the `zidl`
    // binary for its own IDL codegen shouldn't have to opt into the C/C++/Java
    // binding pipeline just to get them.
    b.modules.put(b.graph.arena, b.dupe("zidl_rt"), zidl_rt_mod) catch @panic("OOM");
    b.installArtifact(zidl_exe);

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

    // C ABI layer is a shared prerequisite for C, C++, Java, Python, .NET, Rust zig-ffi
    // — Java's JNI bridge links against libzzdds/dcps.h the same way C/C++ do.
    const need_c_abi = c_binding or cpp_binding or java_binding;

    // Hoisted out of the `if (need_c_abi)` block below so the Java binding
    // section (which needs `need_c_abi` too, but is declared later in this
    // file) can reuse the same generated dcps.h dir and libzzdds Compile step
    // instead of stamping out its own redundant copies.
    var gen_c_dir_for_reuse: ?std.Build.LazyPath = null;
    var gen_zzdds_c_dir_for_reuse: ?std.Build.LazyPath = null;
    var zzdds_lib_for_reuse: ?*std.Build.Step.Compile = null;
    // The Java binding smoke test (below) needs to wait for libzzdds itself
    // to actually be installed next to libzzdds_jni -- see that step's own
    // comment for why.
    var zzdds_lib_install_step: ?*std.Build.Step = null;

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
    //
    // --zig-generate-c-api-cdr-allocator: opt-in companion flag (default off
    // in zidl, since plain --zig-generate-c-api must stay dependency-free for
    // consumers that only link zidl_rt — see zidl PR #45's Greptile finding).
    // zzdds always passes it alongside --zig-generate-c-api because it
    // already links libzidl_cdr unconditionally in this same need_c_abi
    // block (see zidl_cdr_lib below) for C/C++ CDR decode, so there's no
    // added dependency cost here — only the correctness fix (generated
    // frees route through the same registered allocator instead of a
    // hardcoded default).
    if (need_c_abi) gen_dcps.addArgs(&.{ "--zig-generate-c-api", "--zig-generate-c-api-cdr-allocator" });
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
        .sanitize_thread = sanitize_thread,
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
        "-b",                         "zig",
        "--generate-interfaces",      "--single-file",
        "--no-typesupport",           "--no-typeobject-support",
        "--zig-generate-toml-config",
    });
    // See the matching comment on gen_dcps's --zig-generate-c-api above.
    if (need_c_abi) gen_zzdds_vendor.addArgs(&.{ "--zig-generate-c-api", "--zig-generate-c-api-cdr-allocator" });
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
        \\pub const DurabilityQosPolicyKind_fromString = Generated.DurabilityQosPolicyKind_fromString;
        \\pub const HistoryQosPolicyKind = Generated.HistoryQosPolicyKind;
        \\pub const HistoryQosPolicyKind_fromString = Generated.HistoryQosPolicyKind_fromString;
        \\pub const InstanceHandle_t = Generated.InstanceHandle_t;
        \\pub const LivelinessLostStatus = Generated.LivelinessLostStatus;
        \\pub const OfferedDeadlineMissedStatus = Generated.OfferedDeadlineMissedStatus;
        \\pub const OfferedIncompatibleQosStatus = Generated.OfferedIncompatibleQosStatus;
        \\pub const PublicationMatchedStatus = Generated.PublicationMatchedStatus;
        \\pub const ReliabilityQosPolicyKind = Generated.ReliabilityQosPolicyKind;
        \\pub const ReliabilityQosPolicyKind_fromString = Generated.ReliabilityQosPolicyKind_fromString;
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
        .sanitize_thread = sanitize_thread,
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
        .sanitize_thread = sanitize_thread,
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
    build_options.addOption(bool, "debug_allocator", debug_allocator);
    // Pass ZZDDS_XTYPES preprocessor define to zidl so dcps.idl gates XTypes
    // content (DataRepresentationQosPolicy and its uses) at code-generation time.
    if (xtypes) gen_dcps.addArgs(&.{ "-D", "ZZDDS_XTYPES" });

    // ── Zenzen DDS library ──────────────────────────────────────────────────────

    const zzdds_mod = b.addModule("zzdds", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "zzdds_generated", .module = generated_dcps_mod },
            .{ .name = "zzdds_ext_generated", .module = generated_zzdds_mod },
            .{ .name = "zzdds_disc_generated", .module = generated_rtps_disc_mod },
        },
    });
    zzdds_mod.addOptions("build_options", build_options);
    zzdds_mod.link_libc = true;
    if (need_c_abi) {
        zzdds_mod.addCSourceFile(.{
            .file = zidl_dep.path("packages/zidl-cdr/src/zidl_cdr.c"),
            .flags = &.{"-std=c99"},
        });
        zzdds_mod.addIncludePath(zidl_dep.path("packages/zidl-cdr/include"));
    }
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
        gen_c_dir_for_reuse = gen_c_dir;
        if (xtypes) gen_dcps_c.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
        gen_dcps_c.addFileArg(dcps_idl);

        gen_only_step.dependOn(&gen_dcps_c.step);

        const gen_zzdds_c = b.addRunArtifact(zidl_exe);
        gen_zzdds_c.addArgs(&.{ "-b", "c", "--generate-interfaces", "-o" });
        const gen_zzdds_c_dir = gen_zzdds_c.addOutputDirectoryArg("zzdds-c-ext-binding");
        gen_zzdds_c_dir_for_reuse = gen_zzdds_c_dir;
        gen_zzdds_c.addFileArg(b.path("idl/zzdds.idl"));
        gen_only_step.dependOn(&gen_zzdds_c.step);

        // Second, separate generation pass over the same two IDL files, this
        // time with --c-no-free: its .c output (dcps_cdr.c / zzdds_cdr.c)
        // is what actually gets compiled into zzdds_lib below, alongside
        // libzzdds's own native --zig-generate-c-api exports. The two can't
        // share one generation run: dcps.h/zzdds.h (installed above, for
        // every C/C++ consumer) must still *declare* _free -- it's a real,
        // available function, just implemented natively in Zig -- but the
        // .c file compiled in here must not *define* it a second time.
        // Confirmed by hitting this directly, not by inspection: compiling
        // the --c-no-free=false dcps_cdr.c into zzdds_lib produces 25
        // duplicate-symbol link errors, one per QoS/status/config struct
        // with a sequence field, all already exported via the native path.
        const gen_dcps_c_lib = b.addRunArtifact(zidl_exe);
        gen_dcps_c_lib.addArgs(&.{ "-b", "c", "--generate-interfaces", "--c-no-free", "-o" });
        const gen_c_lib_dir = gen_dcps_c_lib.addOutputDirectoryArg("zzdds-c-binding-lib");
        if (xtypes) gen_dcps_c_lib.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
        gen_dcps_c_lib.addFileArg(dcps_idl);
        gen_only_step.dependOn(&gen_dcps_c_lib.step);

        const gen_zzdds_c_lib = b.addRunArtifact(zidl_exe);
        gen_zzdds_c_lib.addArgs(&.{ "-b", "c", "--generate-interfaces", "--c-no-free", "-o" });
        const gen_zzdds_c_lib_dir = gen_zzdds_c_lib.addOutputDirectoryArg("zzdds-c-ext-binding-lib");
        gen_zzdds_c_lib.addFileArg(b.path("idl/zzdds.idl"));
        gen_only_step.dependOn(&gen_zzdds_c_lib.step);

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

        // zidl_exe is now installed unconditionally near the top of this
        // function (see the comment there) — no longer gated on need_c_abi.

        // Build and install the CDR runtime as a pre-compiled static library.
        // C/C++ users link against libzidl_cdr.a rather than compiling zidl_cdr.c
        // from source; the header-only interface (zidl_cdr.h) is already installed above.
        const zidl_cdr_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = sanitize_thread,
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
            // -Dsanitize-thread=true silently no-ops on Zig 0.16's default
            // self-hosted x86_64 backend for Debug builds -- it accepts
            // -fsanitize-thread but doesn't actually instrument anything.
            // Real TSan requires the LLVM backend. Confirmed empirically: a
            // deliberate unsynchronized two-thread race went undetected
            // without this, and was caught immediately with it.
            .use_llvm = if (sanitize_thread) true else null,
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
                .sanitize_thread = sanitize_thread,
                .imports = &.{
                    .{ .name = "zidl_rt", .module = zidl_rt_mod },
                    .{ .name = "zzdds_generated", .module = generated_dcps_mod },
                    .{ .name = "zzdds_ext_generated", .module = generated_zzdds_mod },
                    .{ .name = "zzdds_disc_generated", .module = generated_rtps_disc_mod },
                },
            }),
            // See zidl_cdr_lib's matching comment: -Dsanitize-thread=true
            // needs the LLVM backend forced to actually instrument anything.
            .use_llvm = if (sanitize_thread) true else null,
        });
        zzdds_lib.root_module.addOptions("build_options", build_options);
        zzdds_lib.root_module.link_libc = true;
        if (target.result.os.tag == .windows) {
            zzdds_lib.root_module.linkSystemLibrary("ws2_32", .{});
        }

        // Compile in the plain-struct CDR functions (serialize/deserialize/
        // skip/default/key -- see the --c-no-free generation pass above for
        // why _free is excluded here even though it's fully declared in the
        // installed dcps.h/zzdds.h) that the C ABI header promises but,
        // until now, nothing ever linked: the entity/vtable half of the C
        // ABI (create_topic, create_datawriter, ...) has always come from
        // the native --zig-generate-c-api path below, which made it easy to
        // assume the plain-struct half worked the same way. It didn't --
        // DDS_DataWriterQos_default and friends were declared in dcps.h with
        // no body anywhere in libzzdds.so. Found via zzdds-examples'
        // hello_world C port; see docs/roadmap.md.
        zzdds_lib.root_module.addCSourceFile(.{
            .file = gen_c_lib_dir.path(b, "dcps_cdr.c"),
            .flags = &.{"-std=c99"},
        });
        zzdds_lib.root_module.addCSourceFile(.{
            .file = gen_zzdds_c_lib_dir.path(b, "zzdds_cdr.c"),
            .flags = &.{"-std=c99"},
        });
        zzdds_lib.root_module.addIncludePath(gen_c_lib_dir);
        zzdds_lib.root_module.addIncludePath(gen_zzdds_c_lib_dir);
        zzdds_lib.root_module.addIncludePath(zidl_dep.path("packages/zidl-cdr/include"));
        zzdds_lib.root_module.addIncludePath(b.path("include"));
        zzdds_lib.root_module.linkLibrary(zidl_cdr_lib);

        const install_zzdds_lib = b.addInstallArtifact(zzdds_lib, .{});
        b.getInstallStep().dependOn(&install_zzdds_lib.step);
        zzdds_lib_for_reuse = zzdds_lib;
        zzdds_lib_install_step = &install_zzdds_lib.step;

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

        // Plain-C counterpart to cpp_allocator_smoke.cpp below: proves
        // zzdds_create_factory_with_allocator's C-ABI allocator injection
        // reaches every downstream allocation. No generated per-sample-type
        // CDR code needed (unlike c_smoke above) -- this only exercises
        // factory/participant lifecycle, not serialization.
        const c_alloc_smoke_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        });
        c_alloc_smoke_mod.addCSourceFiles(.{
            .files = &.{"test/bindings/smoke/c_allocator_smoke.c"},
            .flags = &.{ "-std=c99", "-Wall" },
        });
        c_alloc_smoke_mod.addIncludePath(gen_c_dir);
        c_alloc_smoke_mod.addIncludePath(gen_zzdds_c_dir);
        c_alloc_smoke_mod.addIncludePath(zidl_dep.path("packages/zidl-cdr/include"));
        c_alloc_smoke_mod.addIncludePath(b.path("include"));
        c_alloc_smoke_mod.linkLibrary(zzdds_lib);
        const c_alloc_smoke = b.addExecutable(.{ .name = "zzdds_c_allocator_smoke", .root_module = c_alloc_smoke_mod });
        binding_smoke_step.dependOn(&b.addRunArtifact(c_alloc_smoke).step);

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

            // Binding smoke test for zzdds_cpp.hpp's allocator-injection surfaces
            // (factory bootstrap + C++ wrapper-object PMR allocation), including
            // the PMR-exhaustion-must-not-leak-the-factory regression. Needs real
            // DCPS entities (DomainParticipantFactory/DomainParticipant), so it
            // generates its own --cpp-generate-impl output from the full dcps.idl
            // rather than reusing binding_smoke.idl's minimal CDR-only types.
            // dcps.hpp includes the plain-C "dcps.h", so this also needs its own
            // local -b c --generate-interfaces run -- reusing the outer gen_c_dir
            // (a separate zidl invocation) produces two independently-generated
            // copies of the same C-ABI declarations in one translation unit,
            // which clang rejects as conflicting redeclarations.
            const gen_alloc_smoke_c = b.addRunArtifact(zidl_exe);
            gen_alloc_smoke_c.addArgs(&.{ "-b", "c", "--generate-interfaces", "-o" });
            const gen_alloc_smoke_c_dir = gen_alloc_smoke_c.addOutputDirectoryArg("zzdds-binding-smoke-c-alloc");
            if (xtypes) gen_alloc_smoke_c.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
            gen_alloc_smoke_c.addFileArg(dcps_idl);

            const gen_alloc_smoke_zzdds_c = b.addRunArtifact(zidl_exe);
            gen_alloc_smoke_zzdds_c.addArgs(&.{ "-b", "c", "--generate-interfaces", "-o" });
            const gen_alloc_smoke_zzdds_c_dir = gen_alloc_smoke_zzdds_c.addOutputDirectoryArg("zzdds-binding-smoke-c-ext-alloc");
            gen_alloc_smoke_zzdds_c.addFileArg(b.path("idl/zzdds.idl"));

            const gen_alloc_smoke_cpp = b.addRunArtifact(zidl_exe);
            gen_alloc_smoke_cpp.addArgs(&.{ "-b", "cpp", "--generate-interfaces", "-o" });
            const gen_alloc_smoke_cpp_dir = gen_alloc_smoke_cpp.addOutputDirectoryArg("zzdds-binding-smoke-cpp-alloc");
            if (xtypes) gen_alloc_smoke_cpp.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
            gen_alloc_smoke_cpp.addFileArg(dcps_idl);

            const gen_alloc_smoke_cpp_impl = b.addRunArtifact(zidl_exe);
            gen_alloc_smoke_cpp_impl.addArgs(&.{ "-b", "cpp", "--cpp-generate-impl", "-o" });
            const gen_alloc_smoke_cpp_impl_dir = gen_alloc_smoke_cpp_impl.addOutputDirectoryArg("zzdds-binding-smoke-cpp-alloc-impl");
            if (xtypes) gen_alloc_smoke_cpp_impl.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
            gen_alloc_smoke_cpp_impl.addFileArg(dcps_idl);

            const gen_alloc_smoke_zzdds_cpp = b.addRunArtifact(zidl_exe);
            gen_alloc_smoke_zzdds_cpp.addArgs(&.{ "-b", "cpp", "--generate-interfaces", "-o" });
            const gen_alloc_smoke_zzdds_cpp_dir = gen_alloc_smoke_zzdds_cpp.addOutputDirectoryArg("zzdds-binding-smoke-cpp-ext-alloc");
            gen_alloc_smoke_zzdds_cpp.addFileArg(b.path("idl/zzdds.idl"));

            const gen_alloc_smoke_zzdds_cpp_impl = b.addRunArtifact(zidl_exe);
            gen_alloc_smoke_zzdds_cpp_impl.addArgs(&.{ "-b", "cpp", "--cpp-generate-impl", "-o" });
            const gen_alloc_smoke_zzdds_cpp_impl_dir = gen_alloc_smoke_zzdds_cpp_impl.addOutputDirectoryArg("zzdds-binding-smoke-cpp-ext-alloc-impl");
            gen_alloc_smoke_zzdds_cpp_impl.addFileArg(b.path("idl/zzdds.idl"));

            // --cpp-generate-impl redundantly regenerates its own copy of
            // dcps.hpp/zzdds.hpp alongside dcps_impl.hpp/zzdds_impl.hpp (a
            // second, independent zidl invocation on the same input, not
            // guaranteed byte-identical to --generate-interfaces's copy).
            // dcps_impl.hpp's own `#include "dcps.hpp"` is a quoted include,
            // which searches its own directory before any -I path, so simply
            // adding both generated dirs to the include path picks up TWO
            // different copies of the same declarations in one translation
            // unit. Fixed the way the real zig-build-install step already
            // avoids this for real consumers: copy only the needed files into
            // one merged directory, so every quoted #include resolves to a
            // single, deduplicated copy.
            const alloc_smoke_merged = b.addWriteFiles();
            _ = alloc_smoke_merged.addCopyFile(gen_alloc_smoke_cpp_dir.path(b, "dcps.hpp"), "dcps.hpp");
            _ = alloc_smoke_merged.addCopyFile(gen_alloc_smoke_c_dir.path(b, "dcps.h"), "dcps.h");
            _ = alloc_smoke_merged.addCopyFile(gen_alloc_smoke_cpp_impl_dir.path(b, "dcps_impl.hpp"), "dcps_impl.hpp");
            const alloc_smoke_dcps_impl_cpp = alloc_smoke_merged.addCopyFile(gen_alloc_smoke_cpp_impl_dir.path(b, "dcps_impl.cpp"), "dcps_impl.cpp");
            _ = alloc_smoke_merged.addCopyFile(gen_alloc_smoke_zzdds_cpp_dir.path(b, "zzdds.hpp"), "zzdds.hpp");
            _ = alloc_smoke_merged.addCopyFile(gen_alloc_smoke_zzdds_c_dir.path(b, "zzdds.h"), "zzdds.h");
            _ = alloc_smoke_merged.addCopyFile(gen_alloc_smoke_zzdds_cpp_impl_dir.path(b, "zzdds_impl.hpp"), "zzdds_impl.hpp");
            const alloc_smoke_zzdds_impl_cpp = alloc_smoke_merged.addCopyFile(gen_alloc_smoke_zzdds_cpp_impl_dir.path(b, "zzdds_impl.cpp"), "zzdds_impl.cpp");

            const cpp_alloc_smoke_mod = b.createModule(.{
                .root_source_file = null,
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .link_libcpp = true,
            });
            cpp_alloc_smoke_mod.addCSourceFiles(.{
                .files = &.{"test/bindings/smoke/cpp_allocator_smoke.cpp"},
                .flags = &.{ "-std=c++17", "-Wall", "-Wextra" },
            });
            cpp_alloc_smoke_mod.addCSourceFile(.{
                .file = alloc_smoke_dcps_impl_cpp,
                .flags = &.{ "-std=c++17", "-Wall" },
            });
            cpp_alloc_smoke_mod.addCSourceFile(.{
                .file = alloc_smoke_zzdds_impl_cpp,
                .flags = &.{ "-std=c++17", "-Wall" },
            });
            cpp_alloc_smoke_mod.addIncludePath(alloc_smoke_merged.getDirectory());
            cpp_alloc_smoke_mod.addIncludePath(zidl_dep.path("packages/zidl-cdr/include"));
            cpp_alloc_smoke_mod.addIncludePath(b.path("include"));
            cpp_alloc_smoke_mod.linkLibrary(zzdds_lib);
            const cpp_alloc_smoke = b.addExecutable(.{ .name = "zzdds_cpp_allocator_smoke", .root_module = cpp_alloc_smoke_mod });
            binding_smoke_step.dependOn(&b.addRunArtifact(cpp_alloc_smoke).step);
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
        //
        // --cpp-impl-override x4 + --cpp-impl-include: dcps.idl's own generation
        // pass has no visibility into zzdds.idl's separately-generated
        // zzdds::TopicImpl/DataWriterImpl/DataReaderImpl/DomainParticipantImpl --
        // without this, PublisherImpl::create_datawriter/DomainParticipantImpl::
        // create_topic/etc. always construct the base DDS::*Impl, and the
        // natural C++ idiom for reaching set_listener_ex/as_topic_description
        // (static_pointer_cast<zzdds::DataWriterImpl>(dw)) is undefined
        // behavior -- confirmed directly as a real segfault through a
        // corrupted vtable, not just by inspection. Found via zzdds-examples'
        // cpp/hello_world port; see docs/roadmap.md.
        //
        // The override targets aren't the raw generated zzdds::*Impl classes
        // (those are abstract -- entity interfaces don't get cross-module
        // operation flattening, so they only implement the *new* zzdds
        // methods, not the inherited DDS::* base ones) but the hand-written
        // *Support classes in zzdds_cpp.hpp that compose a full DDS::*Impl
        // and delegate every base method to it, same shape as the existing
        // DomainParticipantFactorySupport (which doesn't need this flag --
        // it's a bootstrap singleton, never constructed via another entity's
        // factory method).
        const gen_dcps_cpp_impl = b.addRunArtifact(zidl_exe);
        gen_dcps_cpp_impl.addArgs(&.{
            "-b",                                                               "cpp",
            "--cpp-generate-impl",                                              "--cpp-impl-override",
            "DDS::Topic=::zzdds::detail::TopicSupport",                         "--cpp-impl-override",
            "DDS::DataWriter=::zzdds::detail::DataWriterSupport",               "--cpp-impl-override",
            "DDS::DataReader=::zzdds::detail::DataReaderSupport",               "--cpp-impl-override",
            "DDS::DomainParticipant=::zzdds::detail::DomainParticipantSupport", "--cpp-impl-include",
            "zzdds_cpp.hpp",                                                    "-o",
        });
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
        // dcps.idl and zzdds.idl's Java ext-binding are generated with
        // different --java-package values (io.zzdds.dcps / io.zzdds.ext):
        // several ext-binding interfaces share a simple name with a
        // dcps.idl one (e.g. `DomainParticipantFactory`), so both would
        // clobber the same *Impl.java filename if installed into the same
        // flat directory — separate packages (and therefore separate
        // install subdirectories) avoid that collision entirely. Java
        // forbids a named package from referencing the unnamed one, which
        // is why dcps.idl gets a real package too, not just the extension.
        const gen_dcps_java = b.addRunArtifact(zidl_exe);
        gen_dcps_java.addArgs(&.{ "-b", "java", "--generate-interfaces", "--java-jni-library", "zzdds_jni", "--java-package", "io.zzdds.dcps", "-o" });
        const gen_java_dir = gen_dcps_java.addOutputDirectoryArg("zzdds-java-binding");
        if (xtypes) gen_dcps_java.addArgs(&.{ "-D", "ZZDDS_XTYPES" });
        gen_dcps_java.addFileArg(dcps_idl);

        gen_only_step.dependOn(&gen_dcps_java.step);

        // idl/zzdds.idl's Java "ext binding" (create_participant_ex,
        // DataWriterListenerEx, …) — needs zidl's cross-file Java type
        // support (--java-import-package tells it dcps.idl's own output
        // lives in a different package than this one) to correctly resolve
        // its `DDS::*` references instead of a bare (nonexistent) `DDS.Foo`.
        const gen_zzdds_ext_java = b.addRunArtifact(zidl_exe);
        gen_zzdds_ext_java.addArgs(&.{
            "-b",                    "java",
            "--generate-interfaces", "--java-jni-library",
            "zzdds_jni",             "--java-package",
            "io.zzdds.ext",          "--java-import-package",
            "DDS=io.zzdds.dcps",     "-o",
        });
        const gen_zzdds_ext_java_dir = gen_zzdds_ext_java.addOutputDirectoryArg("zzdds-ext-java-binding");
        gen_zzdds_ext_java.addFileArg(b.path("idl/zzdds.idl"));

        gen_only_step.dependOn(&gen_zzdds_ext_java.step);

        // Install generated Java sources → zig-out/java/io/zzdds/{dcps,ext}/
        // — matching each file's own --java-package so a plain `javac`/`java`
        // run against zig-out/java (as the classpath root) resolves them.
        const install_java = b.addInstallDirectory(.{
            .source_dir = gen_java_dir,
            .install_dir = .{ .custom = "java" },
            .install_subdir = "io/zzdds/dcps",
        });
        b.getInstallStep().dependOn(&install_java.step);

        const install_zzdds_ext_java = b.addInstallDirectory(.{
            .source_dir = gen_zzdds_ext_java_dir,
            .install_dir = .{ .custom = "java" },
            .install_subdir = "io/zzdds/ext",
        });
        b.getInstallStep().dependOn(&install_zzdds_ext_java.step);

        // Install the hand-written io.zzdds.runtime.ZzddsRuntime.java — the
        // small fixed contract the generated --generate-zzdds-wrappers Java
        // output calls into (see java_runtime/ZzddsRuntime.java's javadoc).
        // Must land at the path matching its package for a plain `javac`
        // over zig-out/java/ to find it.
        const install_zzdds_runtime_java = b.addInstallFileWithDir(
            b.path("java_runtime/ZzddsRuntime.java"),
            .{ .custom = "java/io/zzdds/runtime" },
            "ZzddsRuntime.java",
        );
        b.getInstallStep().dependOn(&install_zzdds_runtime_java.step);

        // Compile the generated entity JNI bridge (dcps_jni.c) + the
        // hand-written ZzddsRuntime native implementation into one shared
        // library, linked against libzzdds. Needs a real JDK (for jni.h) —
        // skipped with a warning if one isn't found, same as zidl's own
        // Java JNI integration test.
        const maybe_java_for_jni = b.findProgram(&.{"java"}, &.{}) catch null;
        const jni_include = if (maybe_java_for_jni) |java_path| findJniIncludeDir(b, java_path) else null;
        if (jni_include) |jni_inc| {
            const zzdds_jni_mod = b.createModule(.{
                .root_source_file = null,
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            zzdds_jni_mod.addCSourceFile(.{
                .file = gen_java_dir.path(b, "dcps_jni.c"),
                .flags = &.{"-std=c99"},
            });
            zzdds_jni_mod.addCSourceFile(.{
                .file = gen_zzdds_ext_java_dir.path(b, "zzdds_jni.c"),
                .flags = &.{"-std=c99"},
            });
            zzdds_jni_mod.addCSourceFile(.{
                .file = b.path("java_runtime/zzdds_java_runtime.c"),
                .flags = &.{"-std=c99"},
            });
            zzdds_jni_mod.addIncludePath(gen_c_dir_for_reuse.?);
            zzdds_jni_mod.addIncludePath(gen_zzdds_c_dir_for_reuse.?);
            zzdds_jni_mod.addIncludePath(b.path("include"));
            zzdds_jni_mod.addIncludePath(zidl_dep.path("packages/zidl-cdr/include"));
            zzdds_jni_mod.addIncludePath(.{ .cwd_relative = jni_inc.base });
            zzdds_jni_mod.addIncludePath(.{ .cwd_relative = jni_inc.platform });
            zzdds_jni_mod.linkLibrary(zzdds_lib_for_reuse.?);
            const zzdds_jni_lib = b.addLibrary(.{
                .name = "zzdds_jni",
                .linkage = .dynamic,
                .root_module = zzdds_jni_mod,
            });
            const install_zzdds_jni_lib = b.addInstallArtifact(zzdds_jni_lib, .{});
            b.getInstallStep().dependOn(&install_zzdds_jni_lib.step);

            // Java binding smoke test — see JavaSmoke.java's own doc comment
            // for why this one is a real end-to-end run (two participants,
            // real discovery, a firing listener) rather than the shallow
            // CDR-only check the other languages' smoke tests do.
            if (b.findProgram(&.{"javac"}, &.{}) catch null) |javac| {
                const gen_smoke_java = b.addRunArtifact(zidl_exe);
                gen_smoke_java.addArgs(&.{ "-b", "java", "--generate-zzdds-wrappers", "--java-import-package", "DDS=io.zzdds.dcps", "-o" });
                const gen_smoke_java_dir = gen_smoke_java.addOutputDirectoryArg("zzdds-java-binding-smoke");
                gen_smoke_java.addFileArg(smoke_idl);

                const compile_java_smoke = b.addSystemCommand(&.{ javac, "-d", "build-tmp/java-binding-smoke" });
                compile_java_smoke.addArgs(&.{"test/bindings/smoke/JavaSmoke.java"});
                for (&[_][]const u8{ "Binding_smoke.java", "BindingSmokeStatusTypeSupport.java", "BindingSmokeStatusDataWriter.java", "BindingSmokeStatusDataReader.java" }) |f| {
                    compile_java_smoke.addFileArg(gen_smoke_java_dir.path(b, f));
                }
                for (&[_][]const u8{
                    "Dcps.java",                     "ConditionImpl.java",
                    "ContentFilteredTopicImpl.java", "DataReaderImpl.java",
                    "DataReaderListenerImpl.java",   "DataWriterImpl.java",
                    "DataWriterListenerImpl.java",   "DomainParticipantFactoryImpl.java",
                    "DomainParticipantImpl.java",    "DomainParticipantListenerImpl.java",
                    "EntityImpl.java",               "GuardConditionImpl.java",
                    "ListenerImpl.java",             "MultiTopicImpl.java",
                    "PublisherImpl.java",            "PublisherListenerImpl.java",
                    "QueryConditionImpl.java",       "ReadConditionImpl.java",
                    "StatusConditionImpl.java",      "SubscriberImpl.java",
                    "SubscriberListenerImpl.java",   "TopicDescriptionImpl.java",
                    "TopicImpl.java",                "TopicListenerImpl.java",
                    "TypeSupportImpl.java",          "WaitSetImpl.java",
                }) |f| {
                    compile_java_smoke.addFileArg(gen_java_dir.path(b, f));
                }
                // idl/zzdds.idl's ext binding (DataWriterListenerEx /
                // on_reliable_reader_ready, …) — see JavaSmoke.java's use of
                // ZzddsRuntime.asZzddsDataWriter/set_listener_ex.
                for (&[_][]const u8{
                    "Zzdds.java",
                    "DataReaderImpl.java",
                    "DataWriterImpl.java",
                    "DataWriterListenerExImpl.java",
                    "DomainParticipantFactoryImpl.java",
                    "DomainParticipantImpl.java",
                    "TopicImpl.java",
                }) |f| {
                    compile_java_smoke.addFileArg(gen_zzdds_ext_java_dir.path(b, f));
                }
                compile_java_smoke.addFileArg(b.path("java_runtime/ZzddsRuntime.java"));

                // Both libzzdds and libzzdds_jni need to live in the SAME
                // directory the JVM loads from -- not just libzzdds_jni's
                // own build-cache emit dir (which is all -Djava.library.path
                // pointed at before). On Linux/macOS this was moot: Zig
                // auto-adds an rpath from libzzdds_jni to libzzdds's build
                // output when one links the other in the same graph, so the
                // dependency resolved regardless of directory layout. PE/COFF
                // (Windows) has no rpath equivalent -- confirmed the hard way
                // (PR #65 CI): the JVM loaded zzdds_jni.dll fine via
                // java.library.path, but then failed with
                // "UnsatisfiedLinkError: ... Can't find dependent libraries"
                // because zzdds.dll (its dependency) wasn't anywhere Windows'
                // DLL search order looks. Using the real install directory
                // (both libraries install to the same dest_dir -- `bin` on
                // Windows since .dll counts as isDll(), `lib` elsewhere, see
                // InstallArtifact's own default dest_dir logic) and adding it
                // to PATH via addPathDir fixes this on Windows and is a
                // harmless no-op on Linux/macOS (their loader never
                // consults PATH for this).
                const zzdds_dll_install_dir: std.Build.InstallDir = if (target.result.os.tag == .windows) .bin else .lib;
                const zzdds_dll_install_path = b.getInstallPath(zzdds_dll_install_dir, "");

                // -Xss8m: PR #65 CI hit an immediate EXCEPTION_STACK_OVERFLOW
                // inside libzzdds, crashing right as JavaSmoke's very first
                // native call (createFactory()) enters the JNI bridge --
                // despite that same native factory/participant bootstrap
                // running clean under the plain (non-JNI) Windows test suite
                // moments earlier in the same job. The JVM's default native
                // thread stack (~1MB) is the prime suspect: it's the one
                // thing genuinely smaller on Windows than the pthread
                // defaults this call path apparently fits under on
                // Linux/macOS (both closer to 8MB). 8MB matches that
                // headroom; harmless to set on every platform.
                const run_java_smoke = b.addSystemCommand(&.{ maybe_java_for_jni.?, "-Xss8m", "-cp", "build-tmp/java-binding-smoke" });
                run_java_smoke.addArg(b.fmt("-Djava.library.path={s}", .{zzdds_dll_install_path}));
                run_java_smoke.addPathDir(zzdds_dll_install_path);
                run_java_smoke.addArg("JavaSmoke");
                run_java_smoke.step.dependOn(&compile_java_smoke.step);
                run_java_smoke.step.dependOn(&install_zzdds_jni_lib.step);
                run_java_smoke.step.dependOn(zzdds_lib_install_step.?);
                binding_smoke_step.dependOn(&run_java_smoke.step);
            } else {
                std.log.warn("javac not found — skipping Java binding smoke test", .{});
            }
        } else {
            std.log.warn("jni.h not found under the detected JAVA_HOME — skipping libzzdds_jni.so (Java entity/runtime JNI bridge)", .{});
        }
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
        "test/dcps/wlp_loopback_test.zig",
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
        "test/dcps/listener_fallback_test.zig",
        "test/dcps/sample_rejected_test.zig",
        "test/dcps/type_support_test.zig",
        "test/dcps/get_field_refresh_test.zig",
        "test/c_abi/typesupport_test.zig",
        "test/c_abi/bootstrap_test.zig",
        "test/dcps/entity_routing_test.zig",
        "test/dcps/wait_for_historical_test.zig",
        "test/dcps/waitset_test.zig",
        "test/dcps/waitset_lifecycle_test.zig",
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

    // `zig build emit-tests-llvm` — like emit-tests above, but every binary
    // is forced onto the LLVM backend (see the identical .use_llvm = true
    // rationale on zzdds_tests_tsan below: Zig 0.16's self-hosted backend
    // for Debug/x86_64 emits DWARF that external tools misparse). Confirmed
    // empirically for Valgrind specifically: a self-hosted-backend
    // api_test binary produced 250k+ "DWARF2 reader: Badly formed extended
    // line op" warning lines under `valgrind --quiet`; the identical
    // source rebuilt with use_llvm=true produced zero. This is the same
    // root cause the coverage job's kcov step already works around by
    // patching elfutils from source (see that job's comments) -- rebuilding
    // with LLVM instead is the fix at the source for tools that read this
    // step's binaries directly, which is Valgrind's case. Kept as a
    // separate step (not applied to emit_tests_step itself) rather than
    // switching that shared step wholesale: emit_tests_step also feeds the
    // already-working, separately-tuned kcov pipeline, and changing what it
    // produces was not what this step was added to fix. Installs to
    // zig-out/tests-llvm/ (not tests/) so it can't collide with a
    // previously-run emit-tests' self-hosted-backend binaries.
    //
    // Also uses a "baseline" CPU model, not the plain `target` (native) used
    // everywhere else -- confirmed empirically that LLVM's default
    // -mcpu=native codegen for this host emits SIMD instructions Valgrind's
    // synthetic CPU cannot execute (SIGILL, illegal instruction), hit deep
    // inside Zig's *own* stdlib (debug.SelfInfo.Elf / Io.Threaded.pathToPosix
    // -- the panic/stack-trace-printing machinery linked into every binary,
    // not zzdds's own code), across ~10 of the 47 test binaries. The
    // self-hosted backend never hit this because it's deliberately more
    // conservative about which CPU features it targets even for "native".
    // A parallel module graph (mirroring zzdds_mod_tsan et al. below, same
    // reason: a module's target can't be swapped after construction) rebuilds
    // zidl_rt/generated code/zzdds itself against this safer target -- the
    // *codegen outputs* (gen_output_dir, generated_zzdds_root,
    // gen_rtps_disc_dir) are reused unchanged; only recompilation differs.
    const target_llvm_safe = b.resolveTargetQuery(.{ .cpu_model = .baseline });

    const zidl_dep_llvm_safe = b.dependency("zidl", .{
        .target = target_llvm_safe,
        .optimize = optimize,
    });
    const zidl_rt_mod_llvm_safe = zidl_dep_llvm_safe.module("zidl_rt");

    const generated_dcps_mod_llvm_safe = b.createModule(.{
        .root_source_file = gen_output_dir.path(b, "dcps.zig"),
        .target = target_llvm_safe,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod_llvm_safe },
        },
    });

    const generated_zzdds_mod_llvm_safe = b.createModule(.{
        .root_source_file = generated_zzdds_root,
        .target = target_llvm_safe,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod_llvm_safe },
            .{ .name = "zzdds_generated", .module = generated_dcps_mod_llvm_safe },
        },
    });

    const generated_rtps_disc_mod_llvm_safe = b.createModule(.{
        .root_source_file = gen_rtps_disc_dir.path(b, "rtps_discovery.zig"),
        .target = target_llvm_safe,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod_llvm_safe },
        },
    });

    const zzdds_mod_llvm_safe = b.addModule("zzdds_llvm_safe", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target_llvm_safe,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod_llvm_safe },
            .{ .name = "zzdds_generated", .module = generated_dcps_mod_llvm_safe },
            .{ .name = "zzdds_ext_generated", .module = generated_zzdds_mod_llvm_safe },
            .{ .name = "zzdds_disc_generated", .module = generated_rtps_disc_mod_llvm_safe },
        },
    });
    zzdds_mod_llvm_safe.addOptions("build_options", build_options);
    zzdds_mod_llvm_safe.link_libc = true;
    if (target_llvm_safe.result.os.tag == .windows) {
        zzdds_mod_llvm_safe.linkSystemLibrary("ws2_32", .{});
    }

    const emit_tests_llvm_step = b.step("emit-tests-llvm", "Build test binaries (LLVM backend, baseline CPU) for external DWARF-reading tools like Valgrind");

    const zzdds_tests_llvm = b.addTest(.{
        .name = "zzdds_lib",
        .root_module = zzdds_mod_llvm_safe,
        .use_llvm = true,
    });
    emit_tests_llvm_step.dependOn(&b.addInstallArtifact(zzdds_tests_llvm, .{
        .dest_dir = .{ .override = .{ .custom = "tests-llvm" } },
    }).step);

    for (fuzz_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target_llvm_safe,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod_llvm_safe },
                },
            }),
        });
        t.root_module.link_libc = true;
        emit_tests_llvm_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests-llvm" } },
        }).step);
    }

    for (transport_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target_llvm_safe,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod_llvm_safe },
                },
            }),
        });
        t.root_module.link_libc = true;
        emit_tests_llvm_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests-llvm" } },
        }).step);
    }

    for (discovery_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target_llvm_safe,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod_llvm_safe },
                },
            }),
        });
        t.root_module.link_libc = true;
        emit_tests_llvm_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests-llvm" } },
        }).step);
    }

    for (rtps_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target_llvm_safe,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod_llvm_safe },
                },
            }),
        });
        t.root_module.link_libc = true;
        emit_tests_llvm_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests-llvm" } },
        }).step);
    }

    for (dcps_test_files) |src| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(src),
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target_llvm_safe,
                .imports = &.{
                    .{ .name = "zzdds", .module = zzdds_mod_llvm_safe },
                    .{ .name = "zzdds_generated", .module = generated_dcps_mod_llvm_safe },
                    .{ .name = "zidl_rt", .module = zidl_rt_mod_llvm_safe },
                },
            }),
        });
        t.root_module.link_libc = true;
        emit_tests_llvm_step.dependOn(&b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "tests-llvm" } },
        }).step);
    }

    // ── TSan test step ────────────────────────────────────────────────────────
    // `zig build test-tsan` — compile and run tests with ThreadSanitizer enabled.
    // Covers concurrency in state machines, WaitSet, and discovery code.

    const tsan_step = b.step("test-tsan", "Run Zenzen DDS tests under ThreadSanitizer");

    const zidl_dep_tsan = b.dependency("zidl", .{
        .target = target,
        .optimize = optimize,
        .@"sanitize-thread" = true,
    });
    const zidl_rt_mod_tsan = zidl_dep_tsan.module("zidl_rt");

    const generated_dcps_mod_tsan = b.createModule(.{
        .root_source_file = gen_output_dir.path(b, "dcps.zig"),
        .target = target,
        .sanitize_thread = true,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod_tsan },
        },
    });

    const generated_zzdds_mod_tsan = b.createModule(.{
        .root_source_file = generated_zzdds_root,
        .target = target,
        .sanitize_thread = true,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod_tsan },
            .{ .name = "zzdds_generated", .module = generated_dcps_mod_tsan },
        },
    });

    const generated_rtps_disc_mod_tsan = b.createModule(.{
        .root_source_file = gen_rtps_disc_dir.path(b, "rtps_discovery.zig"),
        .target = target,
        .sanitize_thread = true,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod_tsan },
        },
    });

    const zzdds_mod_tsan = b.addModule("zzdds_tsan", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = true,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod_tsan },
            .{ .name = "zzdds_generated", .module = generated_dcps_mod_tsan },
            .{ .name = "zzdds_ext_generated", .module = generated_zzdds_mod_tsan },
            .{ .name = "zzdds_disc_generated", .module = generated_rtps_disc_mod_tsan },
        },
    });
    zzdds_mod_tsan.addOptions("build_options", build_options);
    zzdds_mod_tsan.link_libc = true;

    // Library self-tests (TSan)
    //
    // .use_llvm = true is required on every Compile step below: Zig 0.16's
    // default self-hosted backend for Debug/x86_64 accepts sanitize_thread
    // but doesn't actually instrument anything under it (confirmed
    // empirically -- a deliberate unsynchronized two-thread race went
    // completely undetected without this, and was caught immediately with
    // it). This whole block only exists for the test-tsan step, so forcing
    // LLVM here unconditionally (no flag gating needed) is correct.
    const zzdds_tests_tsan = b.addTest(.{ .root_module = zzdds_mod_tsan, .use_llvm = true });
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
        }), .use_llvm = true });
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
                .{ .name = "zzdds_generated", .module = generated_dcps_mod_tsan },
                .{ .name = "zidl_rt", .module = zidl_rt_mod_tsan },
            },
        }), .use_llvm = true });
        t.root_module.link_libc = true;
        tsan_step.dependOn(&b.addRunArtifact(t).step);
    }

    // `zig build test-tsan-self-check` — regression guard proving TSan
    // instrumentation can still fail. See test/tsan_self_check.zig and the
    // long comment on zzdds_tests_tsan above for why this matters: Zig
    // 0.16's self-hosted backend once silently no-op'd sanitize_thread, and
    // every TSan job in this repo gave false confidence until that was
    // caught. This binary has a deliberate, blatant, unsynchronized data
    // race that TSan must catch every run; if it ever again goes
    // undetected, this step fails loudly instead of the job quietly
    // degrading back to zero real coverage.
    const tsan_self_check_step = b.step("test-tsan-self-check", "Prove ThreadSanitizer can still catch a real data race (regression guard)");
    const tsan_self_check_exe = b.addExecutable(.{
        .name = "tsan_self_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tsan_self_check.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = true,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    const run_tsan_self_check = b.addRunArtifact(tsan_self_check_exe);
    // halt_on_error=1 is required: TSan's default behavior is to report a
    // race and keep running, so without it the process reaches its own
    // normal (0) exit code regardless of detection, defeating this check.
    // exitcode=66 is an arbitrary but specific marker: it lets this step
    // distinguish "TSan caught the race" (success) from either a clean
    // exit (TSan silently failed to instrument -- the exact regression
    // this step exists to catch) or some unrelated crash.
    run_tsan_self_check.setEnvironmentVariable("TSAN_OPTIONS", "halt_on_error=1:exitcode=66");
    run_tsan_self_check.expectExitCode(66);
    tsan_self_check_step.dependOn(&run_tsan_self_check.step);
}
