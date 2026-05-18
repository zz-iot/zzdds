//! Backend interface — vtable abstraction for language-specific code generators.
//!
//! ## Adding a new backend
//!
//!   1. Create `src/backend/<lang>.zig` with a `CBackend`-style struct and a
//!      `vtable: Backend.Vtable` constant.
//!   2. Export `pub const vtable = ...` from that file.
//!   3. Register it in `root.zig`'s `findByLanguageId`.
//!
//! ## Vtable lifecycle
//!
//!   ```zig
//!   const be = try CBackend.create(alloc);
//!   defer be.deinit();
//!   try be.generate(&ir_spec, opts);
//!   ```

const std = @import("std");
const ir = @import("../ir/root.zig");

// ── Profile ───────────────────────────────────────────────────────────────────

/// Code-generation profile controlling which IDL features and runtime
/// capabilities are assumed to be available.
pub const Profile = enum {
    /// Full DDS profile: all extensibility kinds, unbounded sequences,
    /// TypeObject/TypeIdentifier, heap allocation.  Default.
    full,
    /// XRCE profile for bare-metal microcontrollers (DDS-XRCE v1.0):
    /// XCDR1 encoding only, @final types only, bounded sequences only,
    /// no TypeObject, no heap allocation in generated code.
    xrce,
};

pub const ZigVersion = enum {
    @"0.15.1",
    @"0.16.0",

    pub fn parse(s: []const u8) ?ZigVersion {
        if (std.mem.eql(u8, s, "0.15.1")) return .@"0.15.1";
        if (std.mem.eql(u8, s, "0.16.0")) return .@"0.16.0";
        return null;
    }

    pub fn label(self: ZigVersion) []const u8 {
        return switch (self) {
            .@"0.15.1" => "0.15.1",
            .@"0.16.0" => "0.16.0",
        };
    }
};

// ── Options ───────────────────────────────────────────────────────────────────

/// Options passed to every backend's `generate` call.
pub const Options = struct {
    /// Output directory path.  Backend creates files here.
    /// Empty string means current working directory.
    output_dir: []const u8 = "",
    /// Basename stem of the input file (e.g. `"foo"` from `"foo.idl"`).
    /// Used to derive output filenames such as `"foo.h"` or `"Foo.java"`.
    input_stem: []const u8,
    /// Suppress DDS DataWriter / DataReader / TypeSupport output.
    no_typesupport: bool = false,
    /// Suppress XTYPES TypeObject / TypeIdentifier output.
    no_typeobject_support: bool = false,
    /// Default extensibility when no `@extensibility` annotation is present.
    default_extensibility: ir.Extensibility = .final,
    /// Prefix for C/C++ include-guard macros (e.g. `"DDSC_"` → `"DDSC_FOO_H"`).
    header_guard_prefix: []const u8 = "",
    /// Prefix prepended to every generated user-defined type name.
    /// For example `"DDS_"` turns `MyStruct` into `DDS_MyStruct` and the
    /// CDR functions into `DDS_MyStruct_serialize`, etc.
    /// Empty string (default) preserves existing behaviour.
    type_prefix: []const u8 = "",
    /// Export macro placed before DDS topic descriptors in C/C++.
    export_macro: []const u8 = "",
    /// Java: top-level package prefix (e.g. `"com.example"`).
    java_package: []const u8 = "",
    /// Emit Zig fat-pointer vtable structs for IDL `interface` declarations.
    /// Without this flag, interfaces are emitted as comment placeholders.
    generate_interfaces: bool = false,
    /// Java: name passed to `System.loadLibrary()` in generated `*Impl` classes.
    /// Only used when `generate_interfaces` is true.
    jni_library: []const u8 = "zidl_dds_jni",
    /// Target profile.  Backends may use this to adjust output; the CLI
    /// calls `validateXrce` before invoking backends when profile is `.xrce`.
    profile: Profile = .full,
    /// Split output into one file per named type (C/C++) or one file per
    /// top-level IDL module (Zig), or one file per top-level named type (Java).
    /// When false (default), a single monolithic output file is generated.
    split_files: bool = false,
    /// C/C++: use `#pragma once` instead of `#ifndef`/`#define`/`#endif` include guards.
    pragma_once: bool = false,
    /// C only: wrap header content in `#ifdef __cplusplus` / `extern "C"` brackets.
    /// Lets the generated `.h` be safely included from C++ translation units without
    /// manual wrapping.
    extern_c: bool = false,
    /// C++ only: outer namespace to wrap all generated declarations in.
    /// For example `"dds"` produces `namespace dds { … }` around every type.
    /// Empty string (default) adds no extra namespace layer.
    cpp_namespace: []const u8 = "",
    /// Generate additional `serializePlCdr` / `deserializeFromPlCdr` methods
    /// (Zig) or `Foo_serialize_pl_cdr` / `Foo_deserialize_pl_cdr` functions
    /// (C/C++) for `@mutable` types.  Enables RTPS ParameterList wire format
    /// for DDS discovery types.  Requires `no_typesupport == false`.
    pl_cdr: bool = false,
    /// Zig backend only: generated source compatibility target. zidl itself may
    /// run on a newer Zig toolchain while emitting code for MicroZig-era Zig.
    zig_version: ZigVersion = .@"0.16.0",
};

// ── XRCE profile validation ───────────────────────────────────────────────────

/// Validate that `spec` conforms to the XRCE profile constraints:
///   - All structs and unions must be `@final` (no @appendable or @mutable).
///   - All sequence members must be bounded (`sequence<T, N>`).
///   - No `map<K,V>` members (no standard XCDR1 encoding for maps).
///
/// Returns `error.XrceProfileViolation` on the first violation found.
/// Diagnostic messages are written to `diag` when non-null.
pub fn validateXrce(spec: *const ir.Spec, diag: ?*std.Io.Writer) !void {
    for (spec.items) |item| {
        try validateXrceItem(item, diag);
    }
}

fn validateXrceItem(item: ir.ModuleItem, diag: ?*std.Io.Writer) !void {
    switch (item) {
        .module => |m| for (m.items) |sub| try validateXrceItem(sub, diag),
        .type_decl => |td| try validateXrceTypeDecl(td, diag),
        .const_ => {},
    }
}

fn validateXrceTypeDecl(td: ir.TypeDecl, diag: ?*std.Io.Writer) !void {
    switch (td) {
        .struct_ => |s| {
            if (s.annotations.extensibility != .final) {
                if (diag) |w| try w.print(
                    "zidl: xrce: struct '{s}' is @{s}; only @final is allowed in XRCE profile\n",
                    .{ s.name, @tagName(s.annotations.extensibility) },
                );
                return error.XrceProfileViolation;
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    if (diag) |w| try w.print(
                        "zidl: xrce: {s}.{s} is @optional; optional members require XCDR2 and are not supported in XRCE profile\n",
                        .{ s.name, m.name },
                    );
                    return error.XrceProfileViolation;
                }
                try validateXrceTypeRef(m.type_ref, s.name, m.name, diag);
            }
        },
        .union_ => |u| {
            if (u.annotations.extensibility != .final) {
                if (diag) |w| try w.print(
                    "zidl: xrce: union '{s}' is @{s}; only @final is allowed in XRCE profile\n",
                    .{ u.name, @tagName(u.annotations.extensibility) },
                );
                return error.XrceProfileViolation;
            }
            for (u.cases) |c| try validateXrceTypeRef(c.type_ref, u.name, c.name, diag);
        },
        else => {},
    }
}

fn validateXrceTypeRef(tr: ir.TypeRef, type_name: []const u8, member_name: []const u8, diag: ?*std.Io.Writer) !void {
    switch (tr) {
        .sequence => |s| {
            if (s.bound == null) {
                if (diag) |w| try w.print(
                    "zidl: xrce: {s}.{s} is an unbounded sequence; only bounded sequences are allowed in XRCE profile\n",
                    .{ type_name, member_name },
                );
                return error.XrceProfileViolation;
            }
            try validateXrceTypeRef(s.element.*, type_name, member_name, diag);
        },
        .string => |bound| {
            if (bound == null) {
                if (diag) |w| try w.print(
                    "zidl: xrce: {s}.{s} is an unbounded string; only bounded strings are allowed in XRCE profile\n",
                    .{ type_name, member_name },
                );
                return error.XrceProfileViolation;
            }
        },
        .wstring => {
            if (diag) |w| try w.print(
                "zidl: xrce: {s}.{s} uses wstring, which is not supported by the heap-free XRCE Zig output yet\n",
                .{ type_name, member_name },
            );
            return error.XrceProfileViolation;
        },
        .map => {
            if (diag) |w| try w.print(
                "zidl: xrce: {s}.{s} uses a map type which is not supported in XRCE profile\n",
                .{ type_name, member_name },
            );
            return error.XrceProfileViolation;
        },
        .named => |td| switch (td) {
            .typedef => |t| try validateXrceTypeRef(t.type_ref, type_name, member_name, diag),
            else => {},
        },
        else => {},
    }
}

// ── Backend vtable ────────────────────────────────────────────────────────────

/// A code-generation backend.  Stateless vtable + opaque context pointer.
///
/// The caller creates a concrete backend (e.g. `CBackend.create(alloc)`),
/// obtains a `Backend` value via `.backend()`, and drives it through
/// `generate` / `deinit`.
pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Language identifier, used to filter `@verbatim(language="…")` blocks.
        /// E.g. `"c"`, `"cpp"`, `"java"`, `"zig"`.
        language_id: []const u8,
        /// Generate output files for the given IR spec.
        generate: *const fn (ctx: *anyopaque, spec: *const ir.Spec, opts: Options) anyerror!void,
        /// Release backend-specific resources.
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn generate(self: Backend, spec: *const ir.Spec, opts: Options) anyerror!void {
        return self.vtable.generate(self.ctx, spec, opts);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ctx);
    }

    pub fn languageId(self: Backend) []const u8 {
        return self.vtable.language_id;
    }
};

// ── Name utilities ────────────────────────────────────────────────────────────

/// Convert a `"::"` -separated IDL qualified name into a `"_"` -separated C
/// identifier.
///
///   `"Foo::Bar::Baz"` → `"Foo_Bar_Baz"`
///   `"Simple"`        → `"Simple"`
///
/// Each `"::"` pair is collapsed to a single `'_'`.
/// Caller owns the returned slice (allocated with `alloc`).
pub fn cNameFromQualified(alloc: std.mem.Allocator, qname: []const u8) ![]u8 {
    // Worst case: no "::" — output length equals input length.
    var out = try alloc.alloc(u8, qname.len);
    var out_i: usize = 0;
    var i: usize = 0;
    while (i < qname.len) {
        if (i + 1 < qname.len and qname[i] == ':' and qname[i + 1] == ':') {
            out[out_i] = '_';
            out_i += 1;
            i += 2;
        } else {
            out[out_i] = qname[i];
            out_i += 1;
            i += 1;
        }
    }
    return alloc.realloc(out, out_i);
}

/// Like `cNameFromQualified`, but prepends `prefix` to the flattened result.
///
///   `"Foo::Bar"`, prefix `"DDS_"` → `"DDS_Foo_Bar"`
///   `"Simple"`,   prefix `""`     → `"Simple"` (no extra allocation)
///
/// Caller owns the returned slice (allocated with `alloc`).
pub fn prefixedCNameFromQualified(
    alloc: std.mem.Allocator,
    qname: []const u8,
    prefix: []const u8,
) ![]u8 {
    const flat = try cNameFromQualified(alloc, qname);
    if (prefix.len == 0) return flat;
    defer alloc.free(flat);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, flat });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "cNameFromQualified: nested" {
    const a = try cNameFromQualified(testing.allocator, "Foo::Bar::Baz");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("Foo_Bar_Baz", a);
}

test "cNameFromQualified: simple" {
    const b = try cNameFromQualified(testing.allocator, "Simple");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("Simple", b);
}

test "cNameFromQualified: empty" {
    const c = try cNameFromQualified(testing.allocator, "");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("", c);
}

test "cNameFromQualified: single level" {
    const d = try cNameFromQualified(testing.allocator, "Foo::Bar");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("Foo_Bar", d);
}

test "prefixedCNameFromQualified: with prefix" {
    const a = try prefixedCNameFromQualified(testing.allocator, "Foo::Bar", "DDS_");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("DDS_Foo_Bar", a);
}

test "prefixedCNameFromQualified: empty prefix matches cNameFromQualified" {
    const b = try prefixedCNameFromQualified(testing.allocator, "Foo::Bar", "");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("Foo_Bar", b);
}

test "prefixedCNameFromQualified: simple name with prefix" {
    const c = try prefixedCNameFromQualified(testing.allocator, "Simple", "NS_");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("NS_Simple", c);
}

// ── XRCE validation tests ─────────────────────────────────────────────────────

const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

fn buildTestIr(alloc: std.mem.Allocator, source: []const u8) !ir.Spec {
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    return ir.build(alloc, &spec, az.global_scope);
}

test "xrce validate: @final struct with bounded sequence passes" {
    var ir_spec = try buildTestIr(testing.allocator, "@final struct S { long x; sequence<long, 4> xs; };");
    defer ir_spec.deinit();
    try validateXrce(&ir_spec, null);
}

test "xrce validate: @appendable struct fails" {
    var ir_spec = try buildTestIr(testing.allocator, "@appendable struct S { long x; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: @mutable struct fails" {
    var ir_spec = try buildTestIr(testing.allocator, "@mutable struct S { long x; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: unbounded sequence fails" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { sequence<long> xs; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: bounded sequence passes" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { sequence<long, 8> xs; };");
    defer ir_spec.deinit();
    try validateXrce(&ir_spec, null);
}

test "xrce validate: unbounded string fails" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { string name; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: bounded string passes" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { string<16> name; };");
    defer ir_spec.deinit();
    try validateXrce(&ir_spec, null);
}

test "xrce validate: optional member fails" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { @optional long x; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: wstring fails" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { wstring<8> name; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: @appendable in nested module fails" {
    var ir_spec = try buildTestIr(testing.allocator, "module M { @appendable struct S { long x; }; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}
