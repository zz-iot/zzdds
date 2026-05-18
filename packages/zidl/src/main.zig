//! zidl CLI — IDL 4.2 compiler driver.
//!
//! Usage:
//!   zidl [options] <file.idl> [<file.idl>…]
//!
//! Options:
//!   -b <lang>     Backend language: c (default), cpp, cpp, java, zig
//!   -o <dir>      Output directory (default: .)
//!   -I <dir>      Add include search path (repeatable)
//!   -D <M>[=V]    Define preprocessor macro (repeatable)
//!   -E            Preprocess only; print expanded IDL, no code gen
//!   --no-typesupport         Suppress DataWriter/DataReader/TypeSupport
//!   --no-typeobject-support  Suppress XTYPES TypeObject/TypeIdentifier
//!   --header-guard-prefix <pfx>  Prefix for C/C++ include guard macros
//!   --export-macro <macro>       C/C++ DLL export macro for topic descriptors
//!   --profile <full|xrce>    Target profile (default: full)
//!   --zig-version <0.16.0|0.15.1>  Zig backend output compatibility target
//!   -h / --help   Show this help
//!   -v / --version  Show version
//!
//! Drives the full pipeline per input file:
//!   preprocessor → lexer → parser → semantic analysis → IR → backend

const std = @import("std");
const Io = std.Io;
const zidl = @import("zidl");

const version_string = "zidl 0.1.0-dev";

// ── CLI ───────────────────────────────────────────────────────────────────────

const Opts = struct {
    backend: []const u8 = "c",
    output_dir: []const u8 = ".",
    include_paths: std.ArrayListUnmanaged([]const u8) = .empty,
    defines: std.ArrayListUnmanaged([]const u8) = .empty,
    preprocess_only: bool = false,
    no_typesupport: bool = false,
    no_typeobject_support: bool = false,
    generate_interfaces: bool = false,
    header_guard_prefix: []const u8 = "",
    type_prefix: []const u8 = "",
    export_macro: []const u8 = "",
    profile: zidl.backend.Profile = .full,
    zig_version: zidl.backend.ZigVersion = .@"0.16.0",
    java_package: []const u8 = "",
    default_extensibility: zidl.ir.Extensibility = .final,
    jni_library: []const u8 = "zidl_dds_jni",
    split_files: bool = false,
    pragma_once: bool = false,
    extern_c: bool = false,
    cpp_namespace: []const u8 = "",
    pl_cdr: bool = false,
    preprocess_timestamp_seconds: ?u64 = null,
    inputs: std.ArrayListUnmanaged([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    // Stdout writer for -E output.
    var out_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const stdout = &stdout_fw.interface;

    // Stderr writer for diagnostics.
    var err_buf: [256]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &stderr_fw.interface;

    if (args.len < 2) {
        try printUsage(stderr);
        std.process.exit(1);
    }

    var opts = Opts{};
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(stderr);
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try stdout.print("{s}\n", .{version_string});
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-E")) {
            opts.preprocess_only = true;
        } else if (std.mem.eql(u8, arg, "--no-typesupport")) {
            opts.no_typesupport = true;
        } else if (std.mem.eql(u8, arg, "--no-typeobject-support")) {
            opts.no_typeobject_support = true;
        } else if (std.mem.eql(u8, arg, "--generate-interfaces")) {
            opts.generate_interfaces = true;
        } else if (std.mem.eql(u8, arg, "-b")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: -b requires a language argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.backend = args[i];
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: -o requires a directory argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "-I")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: -I requires a directory argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            try opts.include_paths.append(arena, args[i]);
        } else if (std.mem.eql(u8, arg, "-D")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: -D requires a macro argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            try opts.defines.append(arena, args[i]);
        } else if (std.mem.startsWith(u8, arg, "-I")) {
            try opts.include_paths.append(arena, arg[2..]);
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            try opts.defines.append(arena, arg[2..]);
        } else if (std.mem.eql(u8, arg, "--header-guard-prefix")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --header-guard-prefix requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.header_guard_prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--type-prefix")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --type-prefix requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.type_prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--export-macro")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --export-macro requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.export_macro = args[i];
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --profile requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            const profile_name = args[i];
            if (std.mem.eql(u8, profile_name, "xrce")) {
                opts.profile = .xrce;
            } else if (std.mem.eql(u8, profile_name, "full")) {
                opts.profile = .full;
            } else {
                try stderr.print("error: unknown profile '{s}'; supported: full, xrce\n", .{profile_name});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--zig-version")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --zig-version requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.zig_version = zidl.backend.ZigVersion.parse(args[i]) orelse {
                try stderr.print("error: unknown Zig version '{s}'; supported: 0.16.0, 0.15.1\n", .{args[i]});
                try stderr.flush();
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--jni-library")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --jni-library requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.jni_library = args[i];
        } else if (std.mem.eql(u8, arg, "--java-package")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --java-package requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.java_package = args[i];
        } else if (std.mem.eql(u8, arg, "--split-files")) {
            opts.split_files = true;
        } else if (std.mem.eql(u8, arg, "--single-file")) {
            opts.split_files = false;
        } else if (std.mem.eql(u8, arg, "--pl-cdr")) {
            opts.pl_cdr = true;
        } else if (std.mem.eql(u8, arg, "--pragma-once")) {
            opts.pragma_once = true;
        } else if (std.mem.eql(u8, arg, "--extern-c")) {
            opts.extern_c = true;
        } else if (std.mem.eql(u8, arg, "--cpp-namespace")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --cpp-namespace requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.cpp_namespace = args[i];
        } else if (std.mem.eql(u8, arg, "--default-extensibility")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --default-extensibility requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            const ext_name = args[i];
            if (std.mem.eql(u8, ext_name, "final")) {
                opts.default_extensibility = .final;
            } else if (std.mem.eql(u8, ext_name, "appendable")) {
                opts.default_extensibility = .appendable;
            } else if (std.mem.eql(u8, ext_name, "mutable")) {
                opts.default_extensibility = .mutable;
            } else {
                try stderr.print(
                    "error: unknown extensibility '{s}'; supported: final, appendable, mutable\n",
                    .{ext_name},
                );
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("error: unknown option: {s}\n", .{arg});
            try stderr.flush();
            std.process.exit(1);
        } else {
            try opts.inputs.append(arena, arg);
        }
        i += 1;
    }

    if (opts.inputs.items.len == 0) {
        try stderr.print("error: no input files\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    opts.preprocess_timestamp_seconds = sourceDateEpochFromEnv(init.environ_map) catch {
        try stderr.print("error: SOURCE_DATE_EPOCH must be a non-negative decimal Unix timestamp\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // Resolve backend.
    const backend_opt = try zidl.backend.findByLanguageId(arena, opts.backend);
    if (backend_opt == null) {
        try stderr.print("error: unknown backend '{s}'; supported: c, cpp, java, zig\n", .{opts.backend});
        try stderr.flush();
        std.process.exit(1);
    }
    var be = backend_opt.?;
    defer be.deinit();

    // Process each input file.
    var had_error = false;
    for (opts.inputs.items) |input_path| {
        processFile(
            arena,
            input_path,
            &opts,
            &be,
            stdout,
            stderr,
        ) catch |err| {
            try stderr.print("error: {s}: {s}\n", .{ input_path, @errorName(err) });
            try stderr.flush();
            had_error = true;
        };
    }

    if (had_error) {
        std.process.exit(1);
    }
}

// ── Per-file pipeline ─────────────────────────────────────────────────────────

fn processFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    opts: *const Opts,
    be: *zidl.backend.Backend,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    // ── Phase 1: Preprocess ──────────────────────────────────────────────────
    var pp_diagnostics = zidl.preprocessor.Diagnostics.init(alloc);
    defer pp_diagnostics.deinit();

    var pp = zidl.preprocessor.Preprocessor.initWithOptions(
        alloc,
        zidl.preprocessor.FileLoader.fileSystem(),
        .{
            .diagnostics = &pp_diagnostics,
            .build_timestamp_seconds = opts.preprocess_timestamp_seconds,
        },
    );
    defer pp.deinit();

    // Apply -D defines.
    for (opts.defines.items) |def| {
        const eq = std.mem.indexOf(u8, def, "=");
        const name = if (eq) |e| def[0..e] else def;
        const value = if (eq) |e| def[e + 1 ..] else "1";
        try pp.predefine(name, value);
    }

    // Apply -I include paths.
    for (opts.include_paths.items) |inc| {
        try pp.addIncludePath(inc);
    }

    const pp_result = try pp.process(path);
    defer pp_result.deinit(alloc);

    for (pp_diagnostics.items.items) |diag| {
        try printPreprocessorDiagnostic(stderr, pp_result, diag);
    }

    if (pp.errors.items.len > 0) {
        for (pp.errors.items) |e| {
            try stderr.print("{s}\n", .{e});
        }
        return error.PreprocessorError;
    }

    if (opts.preprocess_only) {
        try stdout.print("{s}", .{pp_result.source});
        try stdout.flush();
        return;
    }

    // ── Phase 2: Parse ───────────────────────────────────────────────────────
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();

    var parser = zidl.parser.Parser.init(pp_result.source, ast_arena.allocator());
    const ast_spec = parser.parseSpecification() catch |err| {
        for (parser.diags.items) |d| {
            try stderr.print("{s}:{d}:{d}: error: {s}\n", .{
                path, d.span.start.line, d.span.start.column, d.message,
            });
        }
        try stderr.flush();
        return err;
    };

    // ── Phase 3: Semantic analysis ───────────────────────────────────────────
    var analyzer = try zidl.semantic.Analyzer.init(alloc);
    defer analyzer.deinit();
    try analyzer.analyze(&ast_spec);

    if (analyzer.diagnostics.items.len > 0) {
        for (analyzer.diagnostics.items) |diag| {
            try stderr.print("{s}\n", .{diag.message});
        }
        // Check for errors (not just warnings).
        for (analyzer.diagnostics.items) |diag| {
            if (diag.severity == .err) {
                return error.SemanticError;
            }
        }
    }

    // ── Phase 4: Build IR ────────────────────────────────────────────────────
    var ir_spec = try zidl.ir.build(alloc, &ast_spec, analyzer.global_scope);
    defer ir_spec.deinit();

    for (ir_spec.warnings) |w| {
        try stderr.print("{s}\n", .{w});
        try stderr.flush();
    }

    // ── Phase 4b: XRCE profile validation ───────────────────────────────────
    if (opts.profile == .xrce) {
        try zidl.backend.validateXrce(&ir_spec, stderr);
    }

    // ── Phase 5: Code generation ─────────────────────────────────────────────
    if (opts.output_dir.len > 0 and !std.mem.eql(u8, opts.output_dir, ".")) {
        const _io = std.Io.Threaded.global_single_threaded.io();
        try Io.Dir.cwd().createDirPath(_io, opts.output_dir);
    }
    const stem = std.fs.path.stem(path);
    const gen_opts = zidl.backend.Options{
        .output_dir = opts.output_dir,
        .input_stem = stem,
        .no_typesupport = opts.no_typesupport,
        .no_typeobject_support = opts.no_typeobject_support or opts.profile == .xrce,
        .generate_interfaces = opts.generate_interfaces,
        .header_guard_prefix = opts.header_guard_prefix,
        .type_prefix = opts.type_prefix,
        .export_macro = opts.export_macro,
        .profile = opts.profile,
        .java_package = opts.java_package,
        .default_extensibility = opts.default_extensibility,
        .jni_library = opts.jni_library,
        .split_files = opts.split_files,
        .pragma_once = opts.pragma_once,
        .extern_c = opts.extern_c,
        .cpp_namespace = opts.cpp_namespace,
        .pl_cdr = opts.pl_cdr,
        .zig_version = opts.zig_version,
    };
    try be.generate(&ir_spec, gen_opts);
}

fn printPreprocessorDiagnostic(
    stderr: *Io.Writer,
    result: zidl.preprocessor.Result,
    diag: zidl.preprocessor.Diagnostic,
) !void {
    const filename = if (diag.file_index < result.files.len)
        result.files[diag.file_index]
    else
        "<unknown>";
    const severity = switch (diag.severity) {
        .warning => "warning",
        .err => "error",
    };
    try stderr.print("{s}:{d}:{d}: {s}: {s}\n", .{
        filename,
        diag.line,
        diag.column,
        severity,
        diag.message,
    });
    try stderr.flush();
}

const SourceDateEpochError = error{
    InvalidSourceDateEpoch,
};

fn sourceDateEpochFromEnv(environ_map: *const std.process.Environ.Map) SourceDateEpochError!?u64 {
    const value = environ_map.get("SOURCE_DATE_EPOCH") orelse return null;
    return try parseSourceDateEpoch(value);
}

fn parseSourceDateEpoch(value: []const u8) SourceDateEpochError!u64 {
    if (value.len == 0) return error.InvalidSourceDateEpoch;
    const seconds = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidSourceDateEpoch;
    if (seconds > zidl.preprocessor.max_build_timestamp_seconds) return error.InvalidSourceDateEpoch;
    return seconds;
}

test "parse SOURCE_DATE_EPOCH" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 0), try parseSourceDateEpoch("0"));
    try testing.expectEqual(@as(u64, 1622924906), try parseSourceDateEpoch("1622924906"));
    try testing.expectError(error.InvalidSourceDateEpoch, parseSourceDateEpoch(""));
    try testing.expectError(error.InvalidSourceDateEpoch, parseSourceDateEpoch("-1"));
    try testing.expectError(error.InvalidSourceDateEpoch, parseSourceDateEpoch("123abc"));
    try testing.expectError(error.InvalidSourceDateEpoch, parseSourceDateEpoch("253402300800"));
}

fn printUsage(w: *Io.Writer) !void {
    try w.print(
        \\Usage: zidl [options] <file.idl> [<file.idl>…]
        \\
        \\Options:
        \\  -b <lang>     Backend language: c (default), cpp, java, zig
        \\  -o <dir>      Output directory (default: .)
        \\  -I <dir>      Add include search path (repeatable)
        \\  -D <M>[=V]    Define preprocessor macro (repeatable)
        \\  -E            Preprocess only; emit expanded IDL
        \\  --no-typesupport         Suppress DataWriter/DataReader/TypeSupport
        \\  --no-typeobject-support  Suppress XTYPES TypeObject/TypeIdentifier
        \\  --generate-interfaces    Emit vtable structs for IDL interface declarations
        \\  --header-guard-prefix <pfx>  Prefix for include guard macros (C/C++)
        \\  --type-prefix <pfx>          Prefix for all generated type names (all backends)
        \\  --export-macro <macro>       C/C++ DLL export macro
        \\  --profile <full|xrce>    Target profile (default: full)
        \\                             xrce: XCDR1 only, @final types, bounded sequences
        \\  --zig-version <ver>      Zig backend output target: 0.16.0 (default) or 0.15.1
        \\  --jni-library <name>     Java System.loadLibrary() name for JNI impls (default: zidl_dds_jni)
        \\  --java-package <pkg>     Java package prefix (e.g. com.example)
        \\  --split-files            Split output: one file per type (C/C++/Java) or per module (Zig)
        \\  --single-file            Single monolithic output file (default)
        \\  --pragma-once            C/C++: use #pragma once instead of #ifndef guards
        \\  --extern-c               C: wrap header in extern "C" {{}} for C++ inclusion
        \\  --cpp-namespace <ns>     C++: wrap all output in an outer namespace
        \\  --pl-cdr                 Generate PL_CDR serialize/deserialize for @mutable types
        \\  --default-extensibility <final|appendable|mutable>
        \\                           Default extensibility when no @extensibility present
        \\                           (default: final, per IDL4 §8.3.1)
        \\  -h / --help   Show this help
        \\  -v / --version  Show version
        \\
    , .{});
    try w.flush();
}
