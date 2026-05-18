//! C++ language mapping backend (OMG IDL4-native C++ v1.0, formal-25-03-03.pdf).
//!
//! Generates a single `.hpp` header per IDL spec containing:
//!   - Module → namespace (nested, no name-flattening)
//!   - Struct → struct with default-initialised members
//!   - Enum → enum class : uint32_t (or smaller per @bit_bound)
//!   - Union → class with _d() accessor + private anonymous union
//!   - Interface → abstract class with pure-virtual methods
//!   - Exception → struct inheriting std::exception
//!   - Bitmask → using alias + constexpr bit constants
//!   - Bitset → struct with bitfield members
//!   - Typedef → using alias (arrays use std::array<T,N>)
//!   - Native → forward-declared class
//!   - Const → constexpr constant
//!
//! ## Primitive type mapping
//!
//!   IDL short / long / long long       → int16_t / int32_t / int64_t
//!   IDL unsigned short / long / …      → uint16_t / uint32_t / uint64_t
//!   IDL float / double / long double   → float / double / long double
//!   IDL char / wchar                   → char / wchar_t
//!   IDL boolean / octet                → bool / uint8_t
//!   IDL int8 … uint64                  → int8_t … uint64_t
//!   IDL string / wstring               → std::string / std::wstring
//!   IDL sequence<T>                    → std::vector<T>
//!   IDL map<K,V>                       → std::map<K,V>
//!   IDL any / object / value_base      → void *
//!   IDL fixed<D,S>                     → double (approximate)
//!
//! ## Notes
//!
//! Named type references always use the `::` fully-qualified prefix so they
//! resolve unambiguously inside any namespace.  Example: a type `Foo::Bar::Baz`
//! is referenced as `::Foo::Bar::Baz`.
//!
//! Unions with members of non-trivially-constructible types (std::string,
//! std::vector, …) produce C++ that requires explicit constructor/destructor
//! definitions; the generator does not emit those.  Backends targeting complex
//! unions should use `std::variant` instead.

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir/root.zig");
const interface = @import("interface.zig");

// ── Public backend struct ─────────────────────────────────────────────────────

pub const CppBackend = struct {
    alloc: std.mem.Allocator,

    pub fn create(alloc: std.mem.Allocator) !*CppBackend {
        const self = try alloc.create(CppBackend);
        self.* = .{ .alloc = alloc };
        return self;
    }

    /// Return a `Backend` value that dispatches to this instance.
    pub fn backend(self: *CppBackend) interface.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = interface.Backend.Vtable{
        .language_id = "cpp",
        .generate = vtableGenerate,
        .deinit = vtableDeinit,
    };

    fn vtableGenerate(
        ctx: *anyopaque,
        spec: *const ir.Spec,
        opts: interface.Options,
    ) anyerror!void {
        const self: *CppBackend = @ptrCast(@alignCast(ctx));
        const io = std.Io.Threaded.global_single_threaded.io();

        if (opts.split_files) {
            try generateSplitFiles(self.alloc, io, spec, opts);
            return;
        }

        // ── <stem>.hpp ────────────────────────────────────────────────────────
        var header_content = std.ArrayList(u8).empty;
        defer header_content.deinit(self.alloc);
        try generateHeader(self.alloc, spec, opts, &header_content);
        const hpp_filename = try std.fmt.allocPrint(self.alloc, "{s}.hpp", .{opts.input_stem});
        defer self.alloc.free(hpp_filename);
        try writeOutputFile(self.alloc, io, opts, hpp_filename, header_content.items);

        // ── <stem>_cdr.cpp ───────────────────────────────────────────────────
        if (!opts.no_typesupport) {
            var cdr_content = std.ArrayList(u8).empty;
            defer cdr_content.deinit(self.alloc);
            try generateCdrSource(self.alloc, spec, opts, &cdr_content);
            const cpp_filename = try std.fmt.allocPrint(self.alloc, "{s}_cdr.cpp", .{opts.input_stem});
            defer self.alloc.free(cpp_filename);
            try writeOutputFile(self.alloc, io, opts, cpp_filename, cdr_content.items);
        }

        // ── <stem>_impl.cpp ──────────────────────────────────────────────────
        if (opts.generate_interfaces) {
            var impl_content = std.ArrayList(u8).empty;
            defer impl_content.deinit(self.alloc);
            try generateImplSource(self.alloc, spec, opts, &impl_content);
            const impl_filename = try std.fmt.allocPrint(self.alloc, "{s}_impl.cpp", .{opts.input_stem});
            defer self.alloc.free(impl_filename);
            try writeOutputFile(self.alloc, io, opts, impl_filename, impl_content.items);
        }
    }

    fn vtableDeinit(ctx: *anyopaque) void {
        const self: *CppBackend = @ptrCast(@alignCast(ctx));
        self.alloc.destroy(self);
    }
};

// ── Public entry point (testable) ─────────────────────────────────────────────

/// Generate C++ header content into `out`.
///
/// Exposed for unit testing without touching the filesystem.
/// The vtable's `vtableGenerate` calls this then writes the result to
/// `<opts.output_dir>/<opts.input_stem>.hpp`.
pub fn generateHeader(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.emitHeader(spec);
}

/// Generate C++ CDR serialization source content into `out`.
///
/// Exposed for unit testing without touching the filesystem.
/// The vtable's `vtableGenerate` calls this then writes the result to
/// `<opts.output_dir>/<opts.input_stem>_cdr.cpp`.
pub fn generateCdrSource(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = CdrGenerator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.emitSource(spec);
}

// ── Generator (private implementation) ───────────────────────────────────────

const Generator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),

    // ── Low-level output helpers ──────────────────────────────────────────────

    fn write(self: *Generator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *Generator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    // ── Top-level header emission ─────────────────────────────────────────────

    const IncludeNeeds = struct {
        map: bool = false,
        optional: bool = false,
        union_arrays: bool = false,
    };

    fn scanIncludes(items: []const ir.ModuleItem) IncludeNeeds {
        var needs = IncludeNeeds{};
        scanIncludesItems(items, &needs);
        return needs;
    }

    fn scanIncludesItems(items: []const ir.ModuleItem, needs: *IncludeNeeds) void {
        for (items) |item| {
            switch (item) {
                .module => |m| scanIncludesItems(m.items, needs),
                .type_decl => |td| switch (td) {
                    .struct_ => |s| {
                        for (s.members) |mem| {
                            if (mem.annotations.is_optional) needs.optional = true;
                            scanIncludesTypeRef(mem.type_ref, needs);
                        }
                    },
                    .union_ => |u| {
                        for (u.cases) |c| {
                            if (c.dimensions.len > 0) needs.union_arrays = true;
                            scanIncludesTypeRef(c.type_ref, needs);
                        }
                    },
                    .exception => |e| {
                        for (e.members) |mem| {
                            if (mem.annotations.is_optional) needs.optional = true;
                            scanIncludesTypeRef(mem.type_ref, needs);
                        }
                    },
                    else => {},
                },
                .const_ => {},
            }
        }
    }

    fn scanIncludesTypeRef(tr: ir.TypeRef, needs: *IncludeNeeds) void {
        switch (tr) {
            .map => needs.map = true,
            .sequence => |s| scanIncludesTypeRef(s.element.*, needs),
            .named => {},
            else => {},
        }
    }

    fn emitHeader(self: *Generator, spec: *const ir.Spec) !void {
        const guard = try self.headerGuard();
        defer self.alloc.free(guard);

        const needs = scanIncludes(spec.items);

        try self.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{self.opts.input_stem},
        );
        if (self.opts.pragma_once) {
            try self.write("#pragma once\n\n");
        } else {
            try self.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
        }
        try self.write("#include <cstdint>\n");
        try self.write("#include <string>\n");
        try self.write("#include <vector>\n");
        if (needs.map) try self.write("#include <map>\n");
        if (needs.optional) try self.write("#include <optional>\n");
        if (needs.union_arrays) try self.write("#include <cstring>\n");
        try self.write("#include <array>\n");
        try self.write("#include <stdexcept>\n");
        if (!self.opts.no_typesupport) {
            try self.write("#include \"zidl_cdr.h\"\n");
        }
        try self.write("\n");
        if (self.opts.cpp_namespace.len > 0) {
            try self.print("namespace {s} {{\n\n", .{self.opts.cpp_namespace});
        }

        try self.emitItems(spec.items);

        if (!self.opts.no_typesupport) {
            try self.emitCdrProtos(spec.items);
        }

        if (self.opts.cpp_namespace.len > 0) {
            try self.print("\n}} // namespace {s}\n", .{self.opts.cpp_namespace});
        }
        if (!self.opts.pragma_once) {
            try self.print("#endif // {s}\n", .{guard});
        }
    }

    fn emitCdrProtos(self: *Generator, items: []const ir.ModuleItem) anyerror!void {
        var any = false;
        try self.collectCdrProtos(items, &any);
    }

    fn collectCdrProtos(self: *Generator, items: []const ir.ModuleItem, any: *bool) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.collectCdrProtos(m.items, any),
                .type_decl => |td| switch (td) {
                    .struct_ => |s| {
                        if (!any.*) {
                            try self.write("// --- CDR type support ---\n\n");
                            any.* = true;
                        }
                        try self.emitStructCdrProtos(s);
                    },
                    .exception => |e| {
                        if (!any.*) {
                            try self.write("// --- CDR type support ---\n\n");
                            any.* = true;
                        }
                        try self.emitExceptionCdrProtos(e);
                    },
                    .union_ => |u| {
                        if (!any.*) {
                            try self.write("// --- CDR type support ---\n\n");
                            any.* = true;
                        }
                        try self.emitUnionCdrProtos(u);
                    },
                    else => {},
                },
                .const_ => {},
            }
        }
    }

    fn prefixedCName(self: *Generator, qname: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, self.opts.type_prefix);
    }

    fn emitStructCdrProtos(self: *Generator, s: *const ir.Struct) !void {
        const c_name = try self.prefixedCName(s.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{s.qualified_name});
        defer self.alloc.free(cpp_qname);

        const has_key = structHasKeyCpp(s);
        try self.print("#define {s}_has_key {d}\n", .{ c_name, @intFromBool(has_key) });
        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ c_name, cpp_qname });
        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ c_name, cpp_qname });
        try self.print("int {s}_skip(ZidlCdrReader *_r);\n", .{c_name});
        if (has_key) {
            try self.print("int {s}_serialize_key(ZidlCdrWriter *_w, const {s} *_v);\n", .{ c_name, cpp_qname });
            try self.print("int {s}_deserialize_key(ZidlCdrReader *_r, {s} *_v);\n", .{ c_name, cpp_qname });
            try self.print("int {s}_compute_key_hash(const {s} *_v, uint8_t _hash[16]);\n", .{ c_name, cpp_qname });
        }
        try self.write("\n");
    }

    fn emitExceptionCdrProtos(self: *Generator, e: *const ir.Exception) !void {
        const c_name = try self.prefixedCName(e.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
        defer self.alloc.free(cpp_qname);
        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ c_name, cpp_qname });
        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ c_name, cpp_qname });
        try self.write("\n");
    }

    fn emitUnionCdrProtos(self: *Generator, u: *const ir.Union) !void {
        const c_name = try self.prefixedCName(u.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{u.qualified_name});
        defer self.alloc.free(cpp_qname);
        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ c_name, cpp_qname });
        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ c_name, cpp_qname });
        try self.print("int {s}_skip(ZidlCdrReader *_r);\n", .{c_name});
        try self.write("\n");
    }

    fn headerGuard(self: *Generator) ![]u8 {
        const prefix = self.opts.header_guard_prefix;
        const stem = self.opts.input_stem;
        const g = try std.fmt.allocPrint(self.alloc, "{s}{s}_HPP", .{ prefix, stem });
        for (g) |*c| {
            c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';
        }
        return g;
    }

    // ── Item / declaration emission ───────────────────────────────────────────

    fn emitItems(self: *Generator, items: []const ir.ModuleItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.emitModule(m),
                .type_decl => |td| try self.emitTypeDecl(td),
                .const_ => |c| try self.emitConst(c),
            }
        }
    }

    fn emitModule(self: *Generator, m: *const ir.Module) anyerror!void {
        if (m.items.len == 0) return;
        try self.print("namespace {s} {{\n\n", .{m.name});
        try self.emitItems(m.items);
        try self.print("}} // namespace {s}\n\n", .{m.name});
    }

    fn emitTypeDecl(self: *Generator, td: ir.TypeDecl) anyerror!void {
        switch (td) {
            .struct_ => |s| try self.emitStruct(s),
            .union_ => |u| try self.emitUnion(u),
            .enum_ => |e| try self.emitEnum(e),
            .typedef => |t| try self.emitTypedef(t),
            .bitmask => |bm| try self.emitBitmask(bm),
            .bitset => |bs| try self.emitBitset(bs),
            .native => |n| try self.emitNative(n),
            .exception => |e| try self.emitException(e),
            .interface => |iface| try self.emitInterface(iface),
        }
    }

    // ── Struct ────────────────────────────────────────────────────────────────

    fn emitStruct(self: *Generator, s: *const ir.Struct) !void {
        try self.print("struct {s}", .{s.name});
        if (s.base) |base| {
            try self.print(" : ::{s}", .{ir.typeDeclQualifiedName(base)});
        }
        try self.write(" {\n");
        for (s.members) |m| {
            try self.emitMemberDecl(m.type_ref, m.name, m.dimensions, m.annotations.is_optional, "    ");
        }
        try self.print("}}; // struct {s}\n\n", .{s.name});
    }

    // ── Union ─────────────────────────────────────────────────────────────────

    fn emitUnion(self: *Generator, u: *const ir.Union) !void {
        const disc_cpp = try self.typeRefToCpp(u.discriminant);
        defer self.alloc.free(disc_cpp);

        try self.print("class {s} {{\npublic:\n", .{u.name});

        // Discriminant accessors.
        try self.print("    void _d({s} v) noexcept {{ _disc = v; }}\n", .{disc_cpp});
        try self.print("    {s} _d() const noexcept {{ return _disc; }}\n", .{disc_cpp});

        // Case accessors (setter + getter).
        for (u.cases) |cas| {
            const mem_cpp = try self.typeRefToCpp(cas.type_ref);
            defer self.alloc.free(mem_cpp);
            if (cas.dimensions.len > 0) {
                const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                defer self.alloc.free(dims_str);
                try self.print("    void {s}({s} const (&v){s}) noexcept {{ std::memcpy(_u._{s}, v, sizeof(_u._{s})); }}\n", .{ cas.name, mem_cpp, dims_str, cas.name, cas.name });
                try self.print("    auto {s}() const noexcept -> {s} const (&){s} {{ return _u._{s}; }}\n", .{ cas.name, mem_cpp, dims_str, cas.name });
            } else {
                try self.print("    void {s}({s} v) {{ _u._{s} = v; }}\n", .{ cas.name, mem_cpp, cas.name });
                try self.print("    {s} {s}() const {{ return _u._{s}; }}\n", .{ mem_cpp, cas.name, cas.name });
            }
        }

        try self.write("private:\n");
        try self.print("    {s} _disc{{}};\n", .{disc_cpp});
        try self.write("    union {\n");
        for (u.cases) |cas| {
            const mem_cpp = try self.typeRefToCpp(cas.type_ref);
            defer self.alloc.free(mem_cpp);
            if (cas.dimensions.len > 0) {
                const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                defer self.alloc.free(dims_str);
                try self.print("        {s} _{s}{s};\n", .{ mem_cpp, cas.name, dims_str });
            } else {
                try self.print("        {s} _{s};\n", .{ mem_cpp, cas.name });
            }
        }
        // NOTE: anonymous union with non-trivially-constructible members (e.g.
        // std::string) requires explicit constructors/destructors; not generated here.
        try self.write("    } _u;\n");
        try self.print("}}; // class {s}\n\n", .{u.name});

        if (!self.opts.no_typesupport) {
            const c_name = try self.prefixedCName(u.qualified_name);
            defer self.alloc.free(c_name);
            const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{u.qualified_name});
            defer self.alloc.free(cpp_qname);
            try self.print("#define {s}_has_key 0\n", .{c_name});
            try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ c_name, cpp_qname });
            try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ c_name, cpp_qname });
            try self.write("\n");
        }
    }

    // ── Enum ──────────────────────────────────────────────────────────────────

    fn emitEnum(self: *Generator, e: *const ir.Enum) !void {
        const storage = enumStorageType(e.annotations);
        try self.print("enum class {s} : {s} {{\n", .{ e.name, storage });
        for (e.enumerators, 0..) |en, i| {
            const comma = if (i + 1 < e.enumerators.len) "," else "";
            try self.print("    {s} = {d}{s}\n", .{ en.name, en.value, comma });
        }
        try self.print("}}; // enum class {s}\n\n", .{e.name});
    }

    // ── Bitmask ───────────────────────────────────────────────────────────────

    fn emitBitmask(self: *Generator, bm: *const ir.Bitmask) !void {
        const storage = bitmaskStorageType(bm.annotations);
        try self.print("using {s} = {s};\n", .{ bm.name, storage });
        for (bm.bits, 0..) |bit, i| {
            try self.print(
                "constexpr {s} {s}_{s}{{{s}(1u << {d})}};\n",
                .{ bm.name, bm.name, bit.name, bm.name, i },
            );
        }
        try self.write("\n");
    }

    // ── Bitset ────────────────────────────────────────────────────────────────

    fn emitBitset(self: *Generator, bs: *const ir.Bitset) !void {
        try self.print("struct {s} {{\n", .{bs.name});
        for (bs.fields) |field| {
            const field_cpp = if (field.type_ref) |tr| blk: {
                const s = try self.typeRefToCpp(tr);
                break :blk s;
            } else try self.alloc.dupe(u8, "unsigned int");
            defer self.alloc.free(field_cpp);

            for (field.names) |fname| {
                try self.print("    {s} {s} : {d};\n", .{ field_cpp, fname, field.bits });
            }
        }
        try self.print("}}; // struct {s}\n\n", .{bs.name});
    }

    // ── Typedef ───────────────────────────────────────────────────────────────

    fn emitTypedef(self: *Generator, t: *const ir.Typedef) !void {
        const cpp_type = try self.typeRefToCpp(t.type_ref);
        defer self.alloc.free(cpp_type);

        if (t.dimensions.len == 0) {
            try self.print("using {s} = {s};\n\n", .{ t.name, cpp_type });
        } else {
            // Array typedef: IDL `typedef long Matrix[2][4]`
            // → C++  `using Matrix = std::array<std::array<int32_t, 4>, 2>;`
            const arr_type = try self.makeArrayType(cpp_type, t.dimensions);
            defer self.alloc.free(arr_type);
            try self.print("using {s} = {s};\n\n", .{ t.name, arr_type });
        }
    }

    /// Build a nested `std::array<…>` type string for an IDL array declaration.
    ///
    /// IDL dimensions are in declaration order: `T[d0][d1]` → `T[d0][d1]`.
    /// C++ `std::array` nests from the inside out:
    ///   `std::array<std::array<T, d1>, d0>`
    ///
    /// Caller owns the returned slice.
    fn makeArrayType(self: *Generator, elem_type: []const u8, dims: []const u64) anyerror![]u8 {
        if (dims.len == 0) return self.alloc.dupe(u8, elem_type);
        const inner = try self.makeArrayType(elem_type, dims[1..]);
        defer self.alloc.free(inner);
        return std.fmt.allocPrint(self.alloc, "std::array<{s}, {d}>", .{ inner, dims[0] });
    }

    // ── Native ────────────────────────────────────────────────────────────────

    fn emitNative(self: *Generator, n: *const ir.Native) !void {
        try self.print("class {s}; // @native\n\n", .{n.name});
    }

    // ── Exception ─────────────────────────────────────────────────────────────

    fn emitException(self: *Generator, e: *const ir.Exception) !void {
        try self.print("struct {s} : std::exception {{\n", .{e.name});
        try self.print(
            "    const char* what() const noexcept override {{ return \"{s}\"; }}\n",
            .{e.name},
        );
        for (e.members) |m| {
            try self.emitMemberDecl(m.type_ref, m.name, m.dimensions, false, "    ");
        }
        try self.print("}}; // struct {s}\n\n", .{e.name});
    }

    // ── Interface ─────────────────────────────────────────────────────────────

    fn emitInterface(self: *Generator, iface: *const ir.Interface) anyerror!void {
        // Emit nested type declarations before the class body.
        for (iface.type_decls) |td| {
            try self.emitTypeDecl(td);
        }
        // Emit nested consts before the class body.
        for (iface.consts) |*c| {
            try self.emitConst(c);
        }

        try self.print("class {s}", .{iface.name});
        if (iface.bases.len > 0) {
            try self.write(" : ");
            for (iface.bases, 0..) |base, i| {
                if (i > 0) try self.write(", ");
                try self.print("public ::{s}", .{ir.typeDeclQualifiedName(base)});
            }
        }
        try self.write(" {\npublic:\n");
        try self.print("    virtual ~{s}() = default;\n", .{iface.name});

        for (iface.operations) |op| {
            try self.emitOperation(&op);
        }
        for (iface.attributes) |attr| {
            try self.emitAttribute(&attr);
        }
        try self.print("}}; // class {s}\n\n", .{iface.name});
    }

    fn emitOperation(self: *Generator, op: *const ir.Operation) !void {
        const ret = if (op.return_type) |rt| blk: {
            const s = try self.typeRefToCpp(rt);
            break :blk s;
        } else try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret);

        try self.print("    virtual {s} {s}(", .{ ret, op.name });
        for (op.params, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            const p_cpp = try self.typeRefToCpp(p.type_ref);
            defer self.alloc.free(p_cpp);
            switch (p.mode) {
                .in_ => try self.print("{s} {s}", .{ p_cpp, p.name }),
                .out, .inout => try self.print("{s}& {s}", .{ p_cpp, p.name }),
            }
        }
        try self.write(") = 0;\n");
    }

    fn emitAttribute(self: *Generator, attr: *const ir.Attribute) !void {
        const a_cpp = try self.typeRefToCpp(attr.type_ref);
        defer self.alloc.free(a_cpp);
        // Getter.
        try self.print("    virtual {s} {s}() const = 0;\n", .{ a_cpp, attr.name });
        // Setter (omitted for readonly).
        if (!attr.readonly) {
            try self.print("    virtual void {s}({s} value) = 0;\n", .{ attr.name, a_cpp });
        }
    }

    // ── Const ─────────────────────────────────────────────────────────────────

    fn emitConst(self: *Generator, c: *const ir.Const) !void {
        const cpp_type = try self.typeRefToCpp(c.type_ref);
        defer self.alloc.free(cpp_type);

        switch (c.value) {
            .integer => |v| try self.print("constexpr {s} {s}{{{d}}};\n", .{ cpp_type, c.name, v }),
            .float => |v| try self.print("constexpr {s} {s}{{{d}}};\n", .{ cpp_type, c.name, v }),
            .boolean => |v| try self.print(
                "constexpr bool {s}{{{s}}};\n",
                .{ c.name, if (v) "true" else "false" },
            ),
            .character => |ch| {
                if (std.ascii.isPrint(ch) and ch != '\'' and ch != '\\') {
                    try self.print("constexpr char {s}{{'{c}'}};\n", .{ c.name, ch });
                } else {
                    try self.print("constexpr char {s}{{char(0x{X:0>2})}};\n", .{ c.name, ch });
                }
            },
            .string => |s| {
                try self.print("constexpr const char* {s}{{\"", .{c.name});
                for (s) |ch| {
                    switch (ch) {
                        '"' => try self.write("\\\""),
                        '\\' => try self.write("\\\\"),
                        '\n' => try self.write("\\n"),
                        '\r' => try self.write("\\r"),
                        '\t' => try self.write("\\t"),
                        else => try self.print("{c}", .{ch}),
                    }
                }
                try self.write("\"};\n");
            },
            .wide_character => |wc| try self.print(
                "constexpr wchar_t {s}{{wchar_t(0x{X:0>4})}};\n",
                .{ c.name, wc },
            ),
            .wide_string => try self.print(
                "// {s}: wide string const — no constexpr wchar_t[] in C++11\n",
                .{c.name},
            ),
            .fixed_pt => |fp| try self.print(
                "// {s}: fixed-point const {s}\n",
                .{ c.name, fp },
            ),
        }
    }

    // ── Member declaration helper ─────────────────────────────────────────────

    /// Emit a single member/field declaration.
    /// Arrays use C-style `Type name[D1][D2];`.
    /// Optional (non-array) members use `std::optional<Type> name{};`.
    /// Plain scalar members use `Type name{};` for default-zero initialisation.
    fn emitMemberDecl(
        self: *Generator,
        type_ref: ir.TypeRef,
        name: []const u8,
        dims: []const u64,
        is_optional: bool,
        indent: []const u8,
    ) !void {
        const cpp_type = try self.typeRefToCpp(type_ref);
        defer self.alloc.free(cpp_type);

        if (dims.len > 0) {
            try self.print("{s}{s} {s}", .{ indent, cpp_type, name });
            for (dims) |d| {
                try self.print("[{d}]", .{d});
            }
            try self.write(";\n");
        } else if (is_optional) {
            try self.print("{s}std::optional<{s}> {s}{{}};\n", .{ indent, cpp_type, name });
        } else {
            try self.print("{s}{s} {s}{{}};\n", .{ indent, cpp_type, name });
        }
    }

    // ── Type-ref → C++ type string ────────────────────────────────────────────

    /// Convert a `TypeRef` to its C++ type expression string.
    /// Named types are emitted with a leading `::` for unambiguous resolution.
    /// Caller owns the returned slice.
    fn typeRefToCpp(self: *Generator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCppType(b)),
            .named => |td| std.fmt.allocPrint(
                self.alloc,
                "::{s}",
                .{ir.typeDeclQualifiedName(td)},
            ),
            .sequence => |seq| blk: {
                const elem = try self.typeRefToCpp(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "std::vector<{s}>", .{elem});
            },
            .string => self.alloc.dupe(u8, "std::string"),
            .wstring => self.alloc.dupe(u8, "std::wstring"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => |m| blk: {
                const key_s = try self.typeRefToCpp(m.key.*);
                defer self.alloc.free(key_s);
                const val_s = try self.typeRefToCpp(m.value.*);
                defer self.alloc.free(val_s);
                break :blk std.fmt.allocPrint(self.alloc, "std::map<{s}, {s}>", .{ key_s, val_s });
            },
        };
    }
};

// ── Static helpers ────────────────────────────────────────────────────────────

fn baseToCppType(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "float",
        .double => "double",
        .long_double => "long double",
        .short => "int16_t",
        .long => "int32_t",
        .long_long => "int64_t",
        .unsigned_short => "uint16_t",
        .unsigned_long => "uint32_t",
        .unsigned_long_long => "uint64_t",
        .char => "char",
        .wchar => "wchar_t",
        .boolean => "bool",
        .octet => "uint8_t",
        .int8 => "int8_t",
        .uint8 => "uint8_t",
        .int16 => "int16_t",
        .int32 => "int32_t",
        .int64 => "int64_t",
        .uint16 => "uint16_t",
        .uint32 => "uint32_t",
        .uint64 => "uint64_t",
        .any => "void *",
        .object => "void *",
        .value_base => "void *",
    };
}

fn enumStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "uint8_t" else if (bound <= 16) "uint16_t" else if (bound <= 32) "uint32_t" else "uint64_t";
}

fn bitmaskStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "uint8_t" else if (bound <= 16) "uint16_t" else if (bound <= 32) "uint32_t" else "uint64_t";
}

fn bitsetCdrStorageType(bs: *const ir.Bitset) []const u8 {
    var total: u32 = 0;
    for (bs.fields) |f| total += f.bits;
    return if (total <= 8) "uint8_t" else if (total <= 16) "uint16_t" else if (total <= 32) "uint32_t" else "uint64_t";
}

fn bitsetCdrFnSuffix(bs: *const ir.Bitset) []const u8 {
    var total: u32 = 0;
    for (bs.fields) |f| total += f.bits;
    return if (total <= 8) "u8" else if (total <= 16) "u16" else if (total <= 32) "u32" else "u64";
}

// ── CDR source generation ─────────────────────────────────────────────────────

const CdrGenerator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),
    /// Indentation depth within a function body.
    /// 1 = function body (4 sp), 2 = one block deep (8 sp), 3 = two deep (12 sp).
    indent_depth: u32 = 1,

    fn write(self: *CdrGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *CdrGenerator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    fn ind(self: *CdrGenerator) []const u8 {
        return switch (self.indent_depth) {
            1 => "    ",
            2 => "        ",
            3 => "            ",
            else => "                ",
        };
    }

    fn writeI(self: *CdrGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, self.ind());
        try self.out.appendSlice(self.alloc, s);
    }

    fn printI(self: *CdrGenerator, comptime fmt: []const u8, args: anytype) !void {
        try self.out.appendSlice(self.alloc, self.ind());
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    /// Return the C++ type string suitable for declaring a local variable of this type
    /// in the CDR source file (e.g. `"int32_t"`, `"std::string"`, `"::Ns::Foo"`).
    /// Caller owns the returned slice.
    fn cppTypeForLocal(self: *CdrGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCppType(b)),
            .string => self.alloc.dupe(u8, "std::string"),
            .wstring => self.alloc.dupe(u8, "std::wstring"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .named => |td| switch (td) {
                .enum_ => |e| std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name}),
                .bitmask => |bm| self.alloc.dupe(u8, enumCTypeName(bm.annotations)),
                else => std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
            },
            .sequence => |seq| blk: {
                const elem = try self.cppTypeForLocal(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "std::vector<{s}>", .{elem});
            },
            .map => |m| blk: {
                const k = try self.cppTypeForLocal(m.key.*);
                defer self.alloc.free(k);
                const v = try self.cppTypeForLocal(m.value.*);
                defer self.alloc.free(v);
                break :blk std.fmt.allocPrint(self.alloc, "std::map<{s}, {s}>", .{ k, v });
            },
        };
    }

    fn emitSource(self: *CdrGenerator, spec: *const ir.Spec) !void {
        try self.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{self.opts.input_stem},
        );
        try self.print("#include \"{s}.hpp\"\n", .{self.opts.input_stem});
        try self.write("#include \"zidl_cdr.h\"\n");
        try self.write("#include <cstring>\n\n");
        try self.emitItems(spec.items);
    }

    fn emitItems(self: *CdrGenerator, items: []const ir.ModuleItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.emitItems(m.items),
                .type_decl => |td| try self.emitTypeDecl(td),
                .const_ => {},
            }
        }
    }

    fn emitTypeDecl(self: *CdrGenerator, td: ir.TypeDecl) !void {
        switch (td) {
            .struct_ => |s| try self.emitStructFns(s),
            .exception => |e| try self.emitExceptionFns(e),
            .union_ => |u| try self.emitUnionFns(u),
            else => {},
        }
    }

    fn prefixedCName(self: *CdrGenerator, qname: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, self.opts.type_prefix);
    }

    // ── Struct / Exception ────────────────────────────────────────────────────

    fn emitStructFns(self: *CdrGenerator, s: *const ir.Struct) !void {
        const c_name = try self.prefixedCName(s.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{s.qualified_name});
        defer self.alloc.free(cpp_qname);

        const ext = s.annotations.extensibility;
        const appendable = (ext == .appendable or ext == .mutable);
        const mutable = (ext == .mutable);

        const has_key = structHasKeyCpp(s);

        // ── serialize ────────────────────────────────────────────────────────

        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, cpp_qname });
        try self.writeI("int _rc;\n");
        if (mutable) {
            // @mutable: outer DHEADER + per-member EMHEADER framing.
            try self.writeI("size_t _dh;\n");
            try self.writeI("_rc = zidl_cdr_reserve_dheader(_w, &_dh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAtCpp(m, idx);
                const mu: u8 = if (m.annotations.must_understand) 1 else 0;
                if (m.annotations.is_optional) {
                    try self.printI("if (_v->{s}.has_value()) {{\n", .{m.name});
                    self.indent_depth += 1;
                    const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
                    defer self.alloc.free(deref);
                    if (lcForCppTypeRef(m.type_ref, m.dimensions)) |lc| {
                        try self.printI("_rc = zidl_cdr_write_emheader(_w, {d}, {d}, {d});\n", .{ member_id, mu, lc });
                        try self.writeI("if (_rc) return _rc;\n");
                        if (m.dimensions.len > 0) {
                            try self.emitWriteArray(m.type_ref, deref, m.dimensions, 0);
                        } else {
                            try self.emitWriteForTypeRef(m.type_ref, m.name, deref);
                        }
                    } else {
                        try self.printI("{{ size_t _em{d} = 0, _es{d} = 0;\n", .{ idx, idx });
                        self.indent_depth += 1;
                        try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, {d}, &_em{d});\n", .{ member_id, mu, idx });
                        try self.writeI("if (_rc) return _rc;\n");
                        try self.printI("_es{d} = _w->len;\n", .{idx});
                        if (m.dimensions.len > 0) {
                            try self.emitWriteArray(m.type_ref, deref, m.dimensions, 0);
                        } else {
                            try self.emitWriteForTypeRef(m.type_ref, m.name, deref);
                        }
                        try self.printI("zidl_cdr_patch_emheader(_w, _em{d}, _es{d}); }}\n", .{ idx, idx });
                        self.indent_depth -= 1;
                    }
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                    continue;
                }
                const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                defer self.alloc.free(access);
                if (lcForCppTypeRef(m.type_ref, m.dimensions)) |lc| {
                    try self.printI("_rc = zidl_cdr_write_emheader(_w, {d}, {d}, {d});\n", .{ member_id, mu, lc });
                    try self.writeI("if (_rc) return _rc;\n");
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                    }
                } else {
                    try self.printI("{{ size_t _em{d} = 0, _es{d} = 0;\n", .{ idx, idx });
                    self.indent_depth += 1;
                    try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, {d}, &_em{d});\n", .{ member_id, mu, idx });
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("_es{d} = _w->len;\n", .{idx});
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                    }
                    try self.printI("zidl_cdr_patch_emheader(_w, _em{d}, _es{d}); }}\n", .{ idx, idx });
                    self.indent_depth -= 1;
                }
            }
            try self.writeI("zidl_cdr_patch_dheader(_w, _dh);\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        } else {
            if (appendable) {
                try self.writeI("size_t _dh;\n");
                try self.writeI("_rc = zidl_cdr_reserve_dheader_maybe(_w, &_dh);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            if (s.base) |base| {
                const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_c);
                const base_cpp = try std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(base)});
                defer self.alloc.free(base_cpp);
                try self.printI("_rc = {s}_serialize(_w, static_cast<const {s} *>(_v));\n", .{ base_c, base_cpp });
                try self.writeI("if (_rc) return _rc;\n");
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: write bool presence flag, then value if present (§12).
                    try self.printI("_rc = zidl_cdr_write_bool(_w, _v->{s}.has_value() ? 1 : 0);\n", .{m.name});
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("if (_v->{s}.has_value()) {{\n", .{m.name});
                    self.indent_depth += 1;
                    const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
                    defer self.alloc.free(deref);
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, deref, m.dimensions, 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, m.name, deref);
                    }
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                    continue;
                }
                const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                defer self.alloc.free(access);
                if (m.dimensions.len > 0) {
                    try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                } else {
                    try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                }
            }
            if (appendable) {
                try self.writeI("zidl_cdr_patch_dheader_maybe(_w, _dh);\n");
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        }

        // ── deserialize ──────────────────────────────────────────────────────

        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, cpp_qname });
        if (mutable) {
            try self.writeI("int _rc;\n");
            try self.writeI("size_t _em_end;\n");
            try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_em_end);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("while (zidl_cdr_mutable_has_more(_r, _em_end)) {\n");
            self.indent_depth += 1;
            try self.writeI("ZidlEmHeader _emh;\n");
            try self.writeI("_rc = zidl_cdr_read_emheader(_r, &_emh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("switch (_emh.member_id) {\n");
            self.indent_depth += 1;
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAtCpp(m, idx);
                try self.printI("case {d}: {{\n", .{member_id});
                self.indent_depth += 1;
                if (m.annotations.is_optional) {
                    try self.printI("_v->{s}.emplace();\n", .{m.name});
                    const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
                    defer self.alloc.free(deref);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, m.name, deref, m.dimensions, 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, m.name, deref);
                    }
                } else {
                    const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                    defer self.alloc.free(lval);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, m.name, lval);
                    }
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            try self.writeI("default:\n");
            self.indent_depth += 1;
            try self.writeI("if (_emh.must_understand) return ZIDL_CDR_INVALID;\n");
            try self.writeI("_rc = zidl_cdr_skip_emheader_payload(_r, &_emh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("break;\n");
            self.indent_depth -= 1;
            self.indent_depth -= 1;
            try self.writeI("}\n"); // switch
            self.indent_depth -= 1;
            try self.writeI("}\n"); // while
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        } else {
            try self.writeI("int _rc;\n");
            if (appendable) {
                try self.writeI("_rc = zidl_cdr_skip_dheader_if_xcdr2(_r);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            if (s.base) |base| {
                const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_c);
                const base_cpp = try std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(base)});
                defer self.alloc.free(base_cpp);
                try self.printI("_rc = {s}_deserialize(_r, static_cast<{s} *>(_v));\n", .{ base_c, base_cpp });
                try self.writeI("if (_rc) return _rc;\n");
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: read bool presence flag; emplace inner value if present.
                    const pvar = try std.fmt.allocPrint(self.alloc, "_ip_{s}", .{m.name});
                    defer self.alloc.free(pvar);
                    try self.printI("{{ int8_t {s};\n", .{pvar});
                    self.indent_depth += 1;
                    try self.printI("_rc = zidl_cdr_read_bool(_r, &{s});\n", .{pvar});
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("if ({s}) {{\n", .{pvar});
                    self.indent_depth += 1;
                    try self.printI("_v->{s}.emplace();\n", .{m.name});
                    const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
                    defer self.alloc.free(deref);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, m.name, deref, m.dimensions, 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, m.name, deref);
                    }
                    self.indent_depth -= 1;
                    try self.writeI("} else {{\n");
                    self.indent_depth += 1;
                    try self.printI("_v->{s} = std::nullopt;\n", .{m.name});
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                    continue;
                }
                const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                defer self.alloc.free(lval);
                if (m.dimensions.len > 0) {
                    try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
                } else {
                    try self.emitReadForTypeRef(m.type_ref, m.name, lval);
                }
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        }

        // ── skip ─────────────────────────────────────────────────────────────

        try self.print("int {s}_skip(ZidlCdrReader *_r) {{\n", .{c_name});
        try self.writeI("int _rc;\n");
        if (mutable) {
            try self.writeI("size_t _end;\n");
            try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_end);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("return zidl_cdr_seek_to(_r, _end);\n");
        } else {
            if (appendable) {
                try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
                self.indent_depth += 1;
                try self.writeI("uint32_t _size;\n");
                try self.writeI("_rc = zidl_cdr_read_dheader(_r, &_size);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("return zidl_cdr_skip(_r, _size);\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            if (s.base) |base| {
                const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_c);
                try self.printI("_rc = {s}_skip(_r);\n", .{base_c});
                try self.writeI("if (_rc) return _rc;\n");
            }
            for (s.members) |m| {
                try self.emitSkipMember(m);
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
        }
        try self.write("}\n\n");

        // ── serialize_key / deserialize_key / compute_key_hash ───────────────

        if (has_key) {
            try self.print("int {s}_serialize_key(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, cpp_qname });
            try self.writeI("int _rc;\n");
            if (s.base) |base| {
                if (typeDeclHasKeyCpp(base)) {
                    const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(base_c);
                    const base_cpp = try std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(base)});
                    defer self.alloc.free(base_cpp);
                    try self.printI("_rc = {s}_serialize_key(_w, static_cast<const {s} *>(_v));\n", .{ base_c, base_cpp });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            }
            for (s.members) |m| {
                if (!m.annotations.is_key) continue;
                const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                defer self.alloc.free(access);
                if (m.dimensions.len > 0) {
                    try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                } else {
                    try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                }
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");

            try self.print("int {s}_deserialize_key(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, cpp_qname });
            try self.writeI("int _rc;\n");
            if (mutable) {
                try self.writeI("size_t _em_end;\n");
                try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_em_end);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("while (zidl_cdr_mutable_has_more(_r, _em_end)) {\n");
                self.indent_depth += 1;
                try self.writeI("ZidlEmHeader _emh;\n");
                try self.writeI("_rc = zidl_cdr_read_emheader(_r, &_emh);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("switch (_emh.member_id) {\n");
                self.indent_depth += 1;
                for (s.members, 0..) |m, idx| {
                    if (!m.annotations.is_key) continue;
                    const member_id: u32 = memberIdAtCpp(m, idx);
                    try self.printI("case {d}: {{\n", .{member_id});
                    self.indent_depth += 1;
                    try self.emitReadPresentMember(m);
                    try self.writeI("break;\n");
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                }
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("if (_emh.must_understand) return ZIDL_CDR_INVALID;\n");
                try self.writeI("_rc = zidl_cdr_skip_emheader_payload(_r, &_emh);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("break;\n");
                self.indent_depth -= 1;
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            } else {
                if (appendable) {
                    try self.writeI("size_t _key_end = (size_t)-1;\n");
                    try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
                    self.indent_depth += 1;
                    try self.writeI("uint32_t _size;\n");
                    try self.writeI("_rc = zidl_cdr_read_dheader(_r, &_size);\n");
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.writeI("_key_end = _r->pos + (size_t)_size;\n");
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                }
                if (s.base) |base| {
                    const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(base_c);
                    const base_cpp = try std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(base)});
                    defer self.alloc.free(base_cpp);
                    if (typeDeclHasKeyCpp(base)) {
                        try self.printI("_rc = {s}_deserialize_key(_r, static_cast<{s} *>(_v));\n", .{ base_c, base_cpp });
                    } else {
                        try self.printI("_rc = {s}_skip(_r);\n", .{base_c});
                    }
                    try self.writeI("if (_rc) return _rc;\n");
                }
                for (s.members) |m| {
                    if (m.annotations.is_key) {
                        try self.emitReadMember(m);
                    } else {
                        try self.emitSkipMember(m);
                    }
                }
                if (appendable) {
                    try self.writeI("if (_key_end != (size_t)-1) { _rc = zidl_cdr_seek_to(_r, _key_end); if (_rc) return _rc; }\n");
                }
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");

            try self.print("int {s}_compute_key_hash(const {s} *_v, uint8_t _hash[16]) {{\n", .{ c_name, cpp_qname });
            try self.writeI("ZidlCdrWriter _w;\n");
            try self.writeI("int _rc = zidl_cdr_writer_init(&_w, ZIDL_XCDR2);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("zidl_cdr_writer_set_byte_order(&_w, ZIDL_CDR_BE);\n");
            try self.printI("_rc = {s}_serialize_key(&_w, _v);\n", .{c_name});
            try self.writeI("if (!_rc) zidl_cdr_compute_key_hash(_w.buf, _w.len, _hash);\n");
            try self.writeI("zidl_cdr_writer_deinit(&_w);\n");
            try self.writeI("return _rc;\n");
            try self.write("}\n\n");
        }
    }

    fn emitExceptionFns(self: *CdrGenerator, e: *const ir.Exception) !void {
        const c_name = try self.prefixedCName(e.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
        defer self.alloc.free(cpp_qname);

        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, cpp_qname });
        try self.writeI("int _rc;\n");
        for (e.members) |m| {
            const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
            defer self.alloc.free(access);
            if (m.dimensions.len > 0) {
                try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
            } else {
                try self.emitWriteForTypeRef(m.type_ref, m.name, access);
            }
        }
        try self.writeI("return ZIDL_CDR_OK;\n");
        try self.write("}\n\n");

        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, cpp_qname });
        try self.writeI("int _rc;\n");
        for (e.members) |m| {
            const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
            defer self.alloc.free(lval);
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, m.name, lval);
            }
        }
        try self.writeI("return ZIDL_CDR_OK;\n");
        try self.write("}\n\n");
    }

    // ── Union ─────────────────────────────────────────────────────────────────

    fn emitUnionFns(self: *CdrGenerator, u: *const ir.Union) anyerror!void {
        const c_name = try self.prefixedCName(u.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{u.qualified_name});
        defer self.alloc.free(cpp_qname);

        const ext = u.annotations.extensibility;
        const appendable = (ext == .appendable or ext == .mutable);
        const mutable = (ext == .mutable);

        // ── serialize ────────────────────────────────────────────────────────

        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, cpp_qname });
        if (mutable) {
            // @mutable union: DHEADER + EMHEADER(0)=discriminant + EMHEADER(N)=case value.
            try self.writeI("int _rc;\n");
            try self.writeI("size_t _dh;\n");
            try self.writeI("_rc = zidl_cdr_reserve_dheader(_w, &_dh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            if (lcForCppTypeRef(u.discriminant, &.{})) |lc| {
                try self.printI("_rc = zidl_cdr_write_emheader(_w, 0, 0, {d});\n", .{lc});
                try self.writeI("if (_rc) return _rc;\n");
                try self.emitDiscWriteCpp(u.discriminant, "_v->_d()");
            } else {
                try self.writeI("{ size_t _em_d = 0, _es_d = 0;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_reserve_emheader(_w, 0, 0, &_em_d);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("_es_d = _w->len;\n");
                try self.emitDiscWriteCpp(u.discriminant, "_v->_d()");
                try self.writeI("zidl_cdr_patch_emheader(_w, _em_d, _es_d); }\n");
                self.indent_depth -= 1;
            }
            try self.writeI("switch (_v->_d()) {\n");
            self.indent_depth += 1;
            var has_default_m = false;
            for (u.cases, 0..) |cas, cas_idx| {
                if (isDefaultUnionCase(cas)) {
                    has_default_m = true;
                    continue;
                }
                const case_member_id: u32 = if (cas.annotations.id) |id| id else @intCast(cas_idx + 1);
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const access = try std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name});
                    defer self.alloc.free(access);
                    try self.printI("{{ size_t _em_c{d} = 0, _es_c{d} = 0;\n", .{ cas_idx, cas_idx });
                    self.indent_depth += 1;
                    try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, 0, &_em_c{d});\n", .{ case_member_id, cas_idx });
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("_es_c{d} = _w->len;\n", .{cas_idx});
                    try self.emitWriteArray(cas.type_ref, access, cas.dimensions, 0);
                    try self.printI("zidl_cdr_patch_emheader(_w, _em_c{d}, _es_c{d}); }}\n", .{ cas_idx, cas_idx });
                    self.indent_depth -= 1;
                } else {
                    const access = try std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name});
                    defer self.alloc.free(access);
                    if (lcForCppTypeRef(cas.type_ref, cas.dimensions)) |lc| {
                        try self.printI("_rc = zidl_cdr_write_emheader(_w, {d}, 0, {d});\n", .{ case_member_id, lc });
                        try self.writeI("if (_rc) return _rc;\n");
                        try self.emitWriteForTypeRef(cas.type_ref, cas.name, access);
                    } else {
                        try self.printI("{{ size_t _em_c{d} = 0, _es_c{d} = 0;\n", .{ cas_idx, cas_idx });
                        self.indent_depth += 1;
                        try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, 0, &_em_c{d});\n", .{ case_member_id, cas_idx });
                        try self.writeI("if (_rc) return _rc;\n");
                        try self.printI("_es_c{d} = _w->len;\n", .{cas_idx});
                        try self.emitWriteForTypeRef(cas.type_ref, cas.name, access);
                        try self.printI("zidl_cdr_patch_emheader(_w, _em_c{d}, _es_c{d}); }}\n", .{ cas_idx, cas_idx });
                        self.indent_depth -= 1;
                    }
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            if (!has_default_m) {
                try self.writeI("default: break;\n");
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            try self.writeI("zidl_cdr_patch_dheader(_w, _dh);\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        } else {
            try self.writeI("int _rc;\n");
            if (appendable) {
                try self.writeI("size_t _dh;\n");
                try self.writeI("_rc = zidl_cdr_reserve_dheader_maybe(_w, &_dh);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            // Write discriminant via getter _v->_d()
            try self.emitDiscWriteCpp(u.discriminant, "_v->_d()");
            try self.writeI("switch (_v->_d()) {\n");
            self.indent_depth += 1;
            var has_default = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) has_default = true;
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const access = try std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name});
                    defer self.alloc.free(access);
                    try self.emitWriteArray(cas.type_ref, access, cas.dimensions, 0);
                } else {
                    const access = try std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name});
                    defer self.alloc.free(access);
                    try self.emitWriteForTypeRef(cas.type_ref, cas.name, access);
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            if (!has_default) {
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            if (appendable) {
                try self.writeI("zidl_cdr_patch_dheader_maybe(_w, _dh);\n");
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        }

        // ── deserialize ──────────────────────────────────────────────────────

        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, cpp_qname });
        if (mutable) {
            try self.writeI("int _rc;\n");
            try self.writeI("size_t _em_end;\n");
            try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_em_end);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("while (zidl_cdr_mutable_has_more(_r, _em_end)) {\n");
            self.indent_depth += 1;
            try self.writeI("ZidlEmHeader _emh;\n");
            try self.writeI("_rc = zidl_cdr_read_emheader(_r, &_emh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("if (_emh.member_id == 0) {\n");
            self.indent_depth += 1;
            try self.emitDiscReadCpp(u.discriminant, "_v");
            self.indent_depth -= 1;
            try self.writeI("} else {\n");
            self.indent_depth += 1;
            try self.writeI("switch (_v->_d()) {\n");
            self.indent_depth += 1;
            var has_default_d = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) {
                    has_default_d = true;
                    continue;
                }
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const cpp_type = try cppTypeStr(self.alloc, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                    defer self.alloc.free(dims_str);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{s}{{}};\n", .{ cpp_type, tmp_name, dims_str });
                    try self.emitReadArray(cas.type_ref, cas.name, tmp_name, cas.dimensions, 0);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                } else {
                    const cpp_type = try cppTypeStr(self.alloc, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{{}};\n", .{ cpp_type, tmp_name });
                    try self.emitReadForTypeRef(cas.type_ref, cas.name, tmp_name);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            if (!has_default_d) {
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("if (_emh.must_understand) return ZIDL_CDR_INVALID;\n");
                try self.writeI("_rc = zidl_cdr_skip_emheader_payload(_r, &_emh);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            self.indent_depth -= 1;
            try self.writeI("}\n"); // switch
            self.indent_depth -= 1;
            try self.writeI("}\n"); // if member_id==0 else
            self.indent_depth -= 1;
            try self.writeI("}\n"); // while
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        } else {
            try self.writeI("int _rc;\n");
            if (appendable) {
                try self.writeI("_rc = zidl_cdr_skip_dheader_if_xcdr2(_r);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            // Read discriminant into temp then set via setter
            try self.emitDiscReadCpp(u.discriminant, "_v");
            try self.writeI("switch (_v->_d()) {\n");
            self.indent_depth += 1;
            var has_default = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) has_default = true;
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const cpp_type = try cppTypeStr(self.alloc, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                    defer self.alloc.free(dims_str);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{s}{{}};\n", .{ cpp_type, tmp_name, dims_str });
                    try self.emitReadArray(cas.type_ref, cas.name, tmp_name, cas.dimensions, 0);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                } else {
                    const cpp_type = try cppTypeStr(self.alloc, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{{}};\n", .{ cpp_type, tmp_name });
                    try self.emitReadForTypeRef(cas.type_ref, cas.name, tmp_name);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            if (!has_default) {
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        }

        // ── skip ─────────────────────────────────────────────────────────────

        try self.print("int {s}_skip(ZidlCdrReader *_r) {{\n", .{c_name});
        try self.writeI("int _rc;\n");
        if (mutable) {
            try self.writeI("size_t _end;\n");
            try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_end);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("return zidl_cdr_seek_to(_r, _end);\n");
        } else {
            if (appendable) {
                try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
                self.indent_depth += 1;
                try self.writeI("uint32_t _size;\n");
                try self.writeI("_rc = zidl_cdr_read_dheader(_r, &_size);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("return zidl_cdr_skip(_r, _size);\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            try self.emitDiscReadLocalCpp(u.discriminant, "_d");
            try self.writeI("switch (_d) {\n");
            self.indent_depth += 1;
            var has_default_s = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) has_default_s = true;
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    try self.emitSkipArray(cas.type_ref, cas.dimensions, 0);
                } else {
                    try self.emitSkipForTypeRef(cas.type_ref);
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            if (!has_default_s) {
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
        }
        try self.write("}\n\n");
    }

    /// Emit CDR write for union discriminant, using the getter expression.
    fn emitDiscWriteCpp(self: *CdrGenerator, disc: ir.TypeRef, getter_expr: []const u8) anyerror!void {
        switch (disc) {
            .base => |b| {
                const fn_name = baseCWriteFn(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported discriminant type write */\n", .{});
                } else {
                    const c_type = baseToCType(b);
                    try self.printI("_rc = {s}(_w, static_cast<{s}>({s}));\n", .{ fn_name, c_type, getter_expr });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    try self.printI("_rc = zidl_cdr_write_{s}(_w, static_cast<{s}>({s}));\n", .{ suffix, ctype, getter_expr });
                    try self.writeI("if (_rc) return _rc;\n");
                },
                else => try self.printI("/* TODO: unsupported discriminant write */\n", .{}),
            },
            else => try self.printI("/* TODO: unsupported discriminant write */\n", .{}),
        }
    }

    /// Emit CDR read for union discriminant, then call `_v->_d(val)` setter.
    fn emitDiscReadCpp(self: *CdrGenerator, disc: ir.TypeRef, v_expr: []const u8) anyerror!void {
        switch (disc) {
            .base => |b| {
                const fn_name = baseCReadFn(b);
                const c_type = baseToCType(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported discriminant type read */\n", .{});
                } else {
                    try self.printI("{{ {s} _d; _rc = {s}(_r, &_d); if (_rc) return _rc; {s}->_d(static_cast<decltype({s}->_d())>(_d)); }}\n", .{ c_type, fn_name, v_expr, v_expr });
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    const cpp_enum = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
                    defer self.alloc.free(cpp_enum);
                    try self.printI("{{ {s} _d_raw; _rc = zidl_cdr_read_{s}(_r, &_d_raw); if (_rc) return _rc; {s}->_d(static_cast<{s}>(_d_raw)); }}\n", .{ ctype, suffix, v_expr, cpp_enum });
                },
                else => try self.printI("/* TODO: unsupported discriminant read */\n", .{}),
            },
            else => try self.printI("/* TODO: unsupported discriminant read */\n", .{}),
        }
    }

    /// Emit local declaration/read for a union discriminant, used by generated skip code.
    fn emitDiscReadLocalCpp(self: *CdrGenerator, disc: ir.TypeRef, lval: []const u8) anyerror!void {
        switch (disc) {
            .base => |b| {
                const fn_name = baseCReadFn(b);
                const c_type = baseToCType(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.writeI("return ZIDL_CDR_INVALID;\n");
                } else {
                    try self.printI("{s} {s};\n", .{ c_type, lval });
                    try self.printI("_rc = {s}(_r, &{s});\n", .{ fn_name, lval });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    const cpp_enum = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
                    defer self.alloc.free(cpp_enum);
                    try self.printI("{s} {s};\n", .{ cpp_enum, lval });
                    try self.printI("{{ {s} _d_raw; _rc = zidl_cdr_read_{s}(_r, &_d_raw); if (_rc) return _rc; {s} = static_cast<{s}>(_d_raw); }}\n", .{ ctype, suffix, lval, cpp_enum });
                },
                else => try self.writeI("return ZIDL_CDR_INVALID;\n"),
            },
            else => try self.writeI("return ZIDL_CDR_INVALID;\n"),
        }
    }

    /// Emit `case X:` / `default:` label lines for a union case (C++ style).
    fn emitUnionCaseLabelLinesCpp(self: *CdrGenerator, disc: ir.TypeRef, cas: ir.UnionCase) anyerror!void {
        if (cas.labels.len == 0) {
            try self.writeI("default:\n");
            return;
        }
        for (cas.labels) |lbl| {
            switch (lbl) {
                .default => try self.writeI("default:\n"),
                .integer => |v| try self.printI("case {d}:\n", .{v}),
                .boolean => |b| try self.printI("case {s}:\n", .{if (b) "true" else "false"}),
                .enumerator => |name| switch (disc) {
                    .named => |td| switch (td) {
                        .enum_ => |e| try self.printI("case ::{s}::{s}:\n", .{ e.qualified_name, name }),
                        else => try self.printI("case {s}:\n", .{name}),
                    },
                    else => try self.printI("case {s}:\n", .{name}),
                },
            }
        }
    }

    // ── Write helpers ─────────────────────────────────────────────────────────

    fn emitWriteForTypeRef(
        self: *CdrGenerator,
        tr: ir.TypeRef,
        field_name: []const u8,
        access: []const u8,
    ) anyerror!void {
        switch (tr) {
            .base => |b| {
                const fn_name = baseCWriteFn(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported type for field {s} */\n", .{field_name});
                } else {
                    try self.printI("_rc = {s}(_w, {s});\n", .{ fn_name, access });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .string => |bound| {
                _ = bound;
                try self.printI("_rc = zidl_cdr_write_string(_w, {s}.c_str(), (uint32_t){s}.size());\n", .{ access, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .wstring => {
                // std::wstring → CDR: write count+1 as u32, then each wchar_t cast to u16, then NUL u16.
                try self.printI("{{ uint32_t _wl = (uint32_t){s}.size();\n", .{access});
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_write_u32(_w, _wl + 1u); if (_rc) return _rc;\n");
                try self.writeI("for (uint32_t _wi = 0; _wi < _wl; _wi++) {\n");
                self.indent_depth += 1;
                try self.printI("_rc = zidl_cdr_write_u16(_w, (uint16_t){s}[_wi]); if (_rc) return _rc;\n", .{access});
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("_rc = zidl_cdr_write_u16(_w, 0u); if (_rc) return _rc;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .sequence => |seq| {
                try self.printI("_rc = zidl_cdr_write_u32(_w, (uint32_t){s}.size());\n", .{access});
                try self.writeI("if (_rc) return _rc;\n");
                try self.printI("{{ uint32_t _si; for (_si = 0; _si < (uint32_t){s}.size(); _si++) {{\n", .{access});
                self.indent_depth += 1;
                const elem_access = try std.fmt.allocPrint(self.alloc, "{s}[_si]", .{access});
                defer self.alloc.free(elem_access);
                try self.emitWriteForTypeRef(seq.element.*, field_name, elem_access);
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("}\n");
            },
            .named => |td| try self.emitWriteNamed(td, field_name, access),
            .fixed_pt => |fp| {
                try self.printI("_rc = zidl_cdr_write_fixed(_w, {d}, {d}, {s});\n", .{ fp.digits, fp.scale, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .map => |m| {
                try self.printI("{{ uint32_t _mc = (uint32_t){s}.size();\n", .{access});
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_write_u32(_w, _mc); if (_rc) return _rc;\n");
                try self.printI("for (auto const& _me : {s}) {{\n", .{access});
                self.indent_depth += 1;
                try self.emitWriteForTypeRef(m.key.*, field_name, "_me.first");
                try self.emitWriteForTypeRef(m.value.*, field_name, "_me.second");
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
        }
    }

    fn emitWriteNamed(
        self: *CdrGenerator,
        td: ir.TypeDecl,
        field_name: []const u8,
        access: []const u8,
    ) anyerror!void {
        switch (td) {
            .struct_, .exception => {
                const qname = ir.typeDeclQualifiedName(td);
                const c_type = try self.prefixedCName(qname);
                defer self.alloc.free(c_type);
                try self.printI("_rc = {s}_serialize(_w, &{s});\n", .{ c_type, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .enum_ => |e| {
                const suffix = enumCStorageType(e.annotations);
                const ctype = enumCTypeName(e.annotations);
                try self.printI("_rc = zidl_cdr_write_{s}(_w, static_cast<{s}>({s}));\n", .{ suffix, ctype, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .bitmask => |bm| {
                const suffix = enumCStorageType(bm.annotations);
                try self.printI("_rc = zidl_cdr_write_{s}(_w, {s});\n", .{ suffix, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .typedef => |t| {
                if (t.dimensions.len > 0) {
                    try self.emitWriteArray(t.type_ref, access, t.dimensions, 0);
                } else {
                    try self.emitWriteForTypeRef(t.type_ref, field_name, access);
                }
            },
            .union_ => {
                const qname = ir.typeDeclQualifiedName(td);
                const c_type = try self.prefixedCName(qname);
                defer self.alloc.free(c_type);
                try self.printI("_rc = {s}_serialize(_w, &{s});\n", .{ c_type, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .bitset => |bs| {
                const ctype = bitsetCdrStorageType(bs);
                const fn_sfx = bitsetCdrFnSuffix(bs);
                try self.printI("{{ {s} _bsv = 0;\n", .{ctype});
                self.indent_depth += 1;
                var bit_pos: u32 = 0;
                for (bs.fields) |field| {
                    if (field.names.len == 0) {
                        bit_pos += field.bits;
                        continue;
                    }
                    const mask: u64 = if (field.bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(field.bits)) - 1;
                    for (field.names) |fname| {
                        if (bit_pos == 0) {
                            try self.printI("_bsv |= ({s}){s}.{s} & 0x{X}u;\n", .{ ctype, access, fname, mask });
                        } else {
                            try self.printI("_bsv |= (({s}){s}.{s} & 0x{X}u) << {d};\n", .{ ctype, access, fname, mask, bit_pos });
                        }
                    }
                    bit_pos += field.bits;
                }
                try self.printI("_rc = zidl_cdr_write_{s}(_w, _bsv);\n", .{fn_sfx});
                try self.writeI("if (_rc) return _rc;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            else => {
                try self.printI("/* TODO: serialize named {s} */\n", .{field_name});
            },
        }
    }

    fn emitWriteArray(
        self: *CdrGenerator,
        elem_tr: ir.TypeRef,
        access: []const u8,
        dims: []const u64,
        dim_idx: usize,
    ) anyerror!void {
        const var_name = try std.fmt.allocPrint(self.alloc, "_ai{d}", .{dim_idx});
        defer self.alloc.free(var_name);
        try self.printI("{{ uint32_t {s}; for ({s} = 0; {s} < {d}u; {s}++) {{\n", .{
            var_name, var_name, var_name, dims[0], var_name,
        });
        self.indent_depth += 1;
        const elem_access = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ access, var_name });
        defer self.alloc.free(elem_access);
        if (dims.len > 1) {
            try self.emitWriteArray(elem_tr, elem_access, dims[1..], dim_idx + 1);
        } else {
            try self.emitWriteForTypeRef(elem_tr, "_elem", elem_access);
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("}\n");
    }

    fn emitReadMember(self: *CdrGenerator, m: ir.StructMember) anyerror!void {
        if (m.annotations.is_optional) {
            const pvar = try std.fmt.allocPrint(self.alloc, "_ip_{s}", .{m.name});
            defer self.alloc.free(pvar);
            try self.printI("{{ int8_t {s};\n", .{pvar});
            self.indent_depth += 1;
            try self.printI("_rc = zidl_cdr_read_bool(_r, &{s});\n", .{pvar});
            try self.writeI("if (_rc) return _rc;\n");
            try self.printI("if ({s}) {{\n", .{pvar});
            self.indent_depth += 1;
            try self.printI("_v->{s}.emplace();\n", .{m.name});
            const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
            defer self.alloc.free(deref);
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, m.name, deref, m.dimensions, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, m.name, deref);
            }
            self.indent_depth -= 1;
            try self.writeI("} else {\n");
            self.indent_depth += 1;
            try self.printI("_v->{s} = std::nullopt;\n", .{m.name});
            self.indent_depth -= 1;
            try self.writeI("}\n");
            self.indent_depth -= 1;
            try self.writeI("}\n");
            return;
        }

        const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
        defer self.alloc.free(lval);
        if (m.dimensions.len > 0) {
            try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
        } else {
            try self.emitReadForTypeRef(m.type_ref, m.name, lval);
        }
    }

    fn emitReadPresentMember(self: *CdrGenerator, m: ir.StructMember) anyerror!void {
        if (m.annotations.is_optional) {
            try self.printI("_v->{s}.emplace();\n", .{m.name});
            const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
            defer self.alloc.free(deref);
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, m.name, deref, m.dimensions, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, m.name, deref);
            }
            return;
        }

        const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
        defer self.alloc.free(lval);
        if (m.dimensions.len > 0) {
            try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
        } else {
            try self.emitReadForTypeRef(m.type_ref, m.name, lval);
        }
    }

    fn emitSkipMember(self: *CdrGenerator, m: ir.StructMember) anyerror!void {
        if (m.annotations.is_optional) {
            const pvar = try std.fmt.allocPrint(self.alloc, "_sp_{s}", .{m.name});
            defer self.alloc.free(pvar);
            try self.printI("{{ int8_t {s};\n", .{pvar});
            self.indent_depth += 1;
            try self.printI("_rc = zidl_cdr_read_bool(_r, &{s});\n", .{pvar});
            try self.writeI("if (_rc) return _rc;\n");
            try self.printI("if ({s}) {{\n", .{pvar});
            self.indent_depth += 1;
            if (m.dimensions.len > 0) {
                try self.emitSkipArray(m.type_ref, m.dimensions, 0);
            } else {
                try self.emitSkipForTypeRef(m.type_ref);
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            self.indent_depth -= 1;
            try self.writeI("}\n");
            return;
        }
        if (m.dimensions.len > 0) {
            try self.emitSkipArray(m.type_ref, m.dimensions, 0);
        } else {
            try self.emitSkipForTypeRef(m.type_ref);
        }
    }

    fn emitSkipArray(self: *CdrGenerator, elem_tr: ir.TypeRef, dims: []const u64, dim_idx: usize) anyerror!void {
        const var_name = try std.fmt.allocPrint(self.alloc, "_ski{d}", .{dim_idx});
        defer self.alloc.free(var_name);
        try self.printI("{{ uint32_t {s}; for ({s} = 0; {s} < {d}u; {s}++) {{\n", .{
            var_name, var_name, var_name, dims[0], var_name,
        });
        self.indent_depth += 1;
        if (dims.len > 1) {
            try self.emitSkipArray(elem_tr, dims[1..], dim_idx + 1);
        } else {
            try self.emitSkipForTypeRef(elem_tr);
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("}\n");
    }

    fn emitSkipForTypeRef(self: *CdrGenerator, tr: ir.TypeRef) anyerror!void {
        switch (tr) {
            .base => |b| {
                const fn_name = baseCReadFn(b);
                const c_type = baseToCType(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.writeI("return ZIDL_CDR_INVALID;\n");
                } else {
                    try self.printI("{{ {s} _tmp; _rc = {s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ c_type, fn_name });
                }
            },
            .string => {
                try self.writeI("{ const char *_sp; uint32_t _sl; _rc = zidl_cdr_read_string_zerocopy(_r, &_sp, &_sl); if (_rc) return _rc; }\n");
            },
            .wstring => {
                try self.writeI("{ uint32_t _wl; _rc = zidl_cdr_read_u32(_r, &_wl); if (_rc) return _rc; for (uint32_t _wi = 0; _wi < _wl; _wi++) { uint16_t _wc; _rc = zidl_cdr_read_u16(_r, &_wc); if (_rc) return _rc; } }\n");
            },
            .sequence => |seq| {
                try self.writeI("{ uint32_t _sl;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_u32(_r, &_sl);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("for (uint32_t _si = 0; _si < _sl; _si++) {\n");
                self.indent_depth += 1;
                try self.emitSkipForTypeRef(seq.element.*);
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .map => |m| {
                try self.writeI("{ uint32_t _ml;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_u32(_r, &_ml);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("for (uint32_t _mi = 0; _mi < _ml; _mi++) {\n");
                self.indent_depth += 1;
                try self.emitSkipForTypeRef(m.key.*);
                try self.emitSkipForTypeRef(m.value.*);
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
                },
                .bitmask => |bm| {
                    const ctype = bitmaskStorageType(bm.annotations);
                    const suffix = enumCStorageType(bm.annotations);
                    try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitSkipArray(t.type_ref, t.dimensions, 0);
                    } else {
                        try self.emitSkipForTypeRef(t.type_ref);
                    }
                },
                .struct_, .exception, .union_ => {
                    const c_type = try self.prefixedCName(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(c_type);
                    try self.printI("_rc = {s}_skip(_r);\n", .{c_type});
                    try self.writeI("if (_rc) return _rc;\n");
                },
                .bitset => |bs| {
                    const ctype = bitsetCdrStorageType(bs);
                    const suffix = bitsetCdrFnSuffix(bs);
                    try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
                },
                else => try self.writeI("return ZIDL_CDR_INVALID;\n"),
            },
            .fixed_pt => |fp| {
                try self.printI("{{ double _tmp; _rc = zidl_cdr_read_fixed(_r, {d}, {d}, &_tmp); if (_rc) return _rc; }}\n", .{ fp.digits, fp.scale });
            },
        }
    }

    // ── Read helpers ──────────────────────────────────────────────────────────

    fn emitReadForTypeRef(
        self: *CdrGenerator,
        tr: ir.TypeRef,
        field_name: []const u8,
        lval: []const u8,
    ) anyerror!void {
        switch (tr) {
            .base => |b| {
                const fn_name = baseCReadFn(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported type for field {s} */\n", .{field_name});
                } else {
                    try self.printI("_rc = {s}(_r, &{s});\n", .{ fn_name, lval });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .string => |bound| {
                // All strings in C++ are std::string; use zerocopy read + assign.
                try self.writeI("{ const char *_sp; uint32_t _sl;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_string_zerocopy(_r, &_sp, &_sl);\n");
                try self.writeI("if (_rc) return _rc;\n");
                if (bound) |n| {
                    try self.printI("if (_sl > {d}u) return ZIDL_CDR_INVALID;\n", .{n});
                }
                try self.printI("{s}.assign(_sp, _sl);\n", .{lval});
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .wstring => |bound| {
                // CDR → std::wstring: read count, then u16 chars cast to wchar_t.
                try self.writeI("{ uint32_t _wc;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_u32(_r, &_wc); if (_rc) return _rc;\n");
                try self.writeI("if (_wc == 0) return ZIDL_CDR_INVALID;\n");
                try self.writeI("uint32_t _wl = _wc - 1u;\n");
                if (bound) |n| {
                    try self.printI("if (_wl > {d}u) return ZIDL_CDR_INVALID;\n", .{n});
                }
                try self.printI("{s}.resize(_wl);\n", .{lval});
                try self.writeI("for (uint32_t _wi = 0; _wi < _wl; _wi++) {\n");
                self.indent_depth += 1;
                try self.writeI("uint16_t _wv;\n");
                try self.printI("_rc = zidl_cdr_read_u16(_r, &_wv); if (_rc) {{ {s}.clear(); return _rc; }}\n", .{lval});
                try self.printI("{s}[_wi] = (wchar_t)_wv;\n", .{lval});
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("uint16_t _nul;\n");
                try self.printI("_rc = zidl_cdr_read_u16(_r, &_nul); if (_rc) {{ {s}.clear(); return _rc; }}\n", .{lval});
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .sequence => |seq| {
                try self.writeI("{ uint32_t _sl;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_u32(_r, &_sl);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.printI("{s}.resize(_sl);\n", .{lval});
                try self.writeI("{ uint32_t _si; for (_si = 0; _si < _sl; _si++) {\n");
                self.indent_depth += 1;
                const elem_lval = try std.fmt.allocPrint(self.alloc, "{s}[_si]", .{lval});
                defer self.alloc.free(elem_lval);
                try self.emitReadForTypeRef(seq.element.*, field_name, elem_lval);
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .named => |td| try self.emitReadNamed(td, field_name, lval),
            .fixed_pt => |fp| {
                try self.printI("_rc = zidl_cdr_read_fixed(_r, {d}, {d}, &{s});\n", .{ fp.digits, fp.scale, lval });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .map => |m| {
                const k_type = try self.cppTypeForLocal(m.key.*);
                defer self.alloc.free(k_type);
                const v_type = try self.cppTypeForLocal(m.value.*);
                defer self.alloc.free(v_type);
                try self.writeI("{ uint32_t _mc;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_u32(_r, &_mc); if (_rc) return _rc;\n");
                try self.writeI("for (uint32_t _mi = 0; _mi < _mc; _mi++) {\n");
                self.indent_depth += 1;
                try self.printI("{s} _mk{{}};\n", .{k_type});
                try self.printI("{s} _mv{{}};\n", .{v_type});
                try self.emitReadForTypeRef(m.key.*, field_name, "_mk");
                try self.emitReadForTypeRef(m.value.*, field_name, "_mv");
                try self.printI("{s}.emplace(std::move(_mk), std::move(_mv));\n", .{lval});
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
        }
    }

    fn emitReadNamed(
        self: *CdrGenerator,
        td: ir.TypeDecl,
        field_name: []const u8,
        lval: []const u8,
    ) anyerror!void {
        switch (td) {
            .struct_, .exception => {
                const qname = ir.typeDeclQualifiedName(td);
                const c_type = try self.prefixedCName(qname);
                defer self.alloc.free(c_type);
                try self.printI("_rc = {s}_deserialize(_r, &{s});\n", .{ c_type, lval });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .enum_ => |e| {
                const suffix = enumCStorageType(e.annotations);
                const ctype = enumCTypeName(e.annotations);
                const cpp_enum = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
                defer self.alloc.free(cpp_enum);
                try self.printI(
                    "{{ {s} _ev; _rc = zidl_cdr_read_{s}(_r, &_ev); if (_rc) return _rc; {s} = static_cast<{s}>(_ev); }}\n",
                    .{ ctype, suffix, lval, cpp_enum },
                );
            },
            .bitmask => |bm| {
                const suffix = enumCStorageType(bm.annotations);
                try self.printI("_rc = zidl_cdr_read_{s}(_r, &{s});\n", .{ suffix, lval });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .typedef => |t| {
                if (t.dimensions.len > 0) {
                    try self.emitReadArray(t.type_ref, field_name, lval, t.dimensions, 0);
                } else {
                    try self.emitReadForTypeRef(t.type_ref, field_name, lval);
                }
            },
            .union_ => {
                const qname = ir.typeDeclQualifiedName(td);
                const c_type = try self.prefixedCName(qname);
                defer self.alloc.free(c_type);
                try self.printI("_rc = {s}_deserialize(_r, &{s});\n", .{ c_type, lval });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .bitset => |bs| {
                const ctype = bitsetCdrStorageType(bs);
                const fn_sfx = bitsetCdrFnSuffix(bs);
                try self.printI("{{ {s} _bsv;\n", .{ctype});
                self.indent_depth += 1;
                try self.printI("_rc = zidl_cdr_read_{s}(_r, &_bsv);\n", .{fn_sfx});
                try self.writeI("if (_rc) return _rc;\n");
                var bit_pos: u32 = 0;
                for (bs.fields) |field| {
                    if (field.names.len == 0) {
                        bit_pos += field.bits;
                        continue;
                    }
                    const mask: u64 = if (field.bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(field.bits)) - 1;
                    for (field.names) |fname| {
                        if (bit_pos == 0) {
                            try self.printI("{s}.{s} = _bsv & 0x{X}u;\n", .{ lval, fname, mask });
                        } else {
                            try self.printI("{s}.{s} = (_bsv >> {d}) & 0x{X}u;\n", .{ lval, fname, bit_pos, mask });
                        }
                    }
                    bit_pos += field.bits;
                }
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            else => {
                try self.printI("/* TODO: deserialize named {s} */\n", .{field_name});
            },
        }
    }

    fn emitReadArray(
        self: *CdrGenerator,
        elem_tr: ir.TypeRef,
        field_name: []const u8,
        lval: []const u8,
        dims: []const u64,
        dim_idx: usize,
    ) anyerror!void {
        const var_name = try std.fmt.allocPrint(self.alloc, "_ai{d}", .{dim_idx});
        defer self.alloc.free(var_name);
        try self.printI("{{ uint32_t {s}; for ({s} = 0; {s} < {d}u; {s}++) {{\n", .{
            var_name, var_name, var_name, dims[0], var_name,
        });
        self.indent_depth += 1;
        const elem_lval = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ lval, var_name });
        defer self.alloc.free(elem_lval);
        if (dims.len > 1) {
            try self.emitReadArray(elem_tr, field_name, elem_lval, dims[1..], dim_idx + 1);
        } else {
            try self.emitReadForTypeRef(elem_tr, field_name, elem_lval);
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("}\n");
    }
};

// ── Interface impl generation ─────────────────────────────────────────────────

/// Generate the interface binding source file `<stem>_impl.cpp` into `out`.
///
/// For each IDL `interface`, emits:
///   - An `extern "C" { ... }` block declaring Zig DDS runtime exports
///   - A concrete `FooZigImpl : public ::Foo` subclass that forwards every
///     pure-virtual method to the corresponding Zig export via `ptr_`
///
/// Method bodies perform direct forwarding for void returns and primitive
/// parameters.  Complex parameters / return types (std::string, std::vector,
/// named structs) emit `/* TODO */` stubs that still compile.
pub fn generateImplSource(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = ImplGenerator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.emitSource(spec);
}

const ImplGenerator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),

    fn write(self: *ImplGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *ImplGenerator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    fn emitSource(self: *ImplGenerator, spec: *const ir.Spec) !void {
        try self.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{self.opts.input_stem},
        );
        try self.print("#include \"{s}.hpp\"\n\n", .{self.opts.input_stem});
        try self.emitItems(spec.items);
    }

    fn emitItems(self: *ImplGenerator, items: []const ir.ModuleItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.emitItems(m.items),
                .type_decl => |td| switch (td) {
                    .interface => |iface| try self.emitIfaceImpl(iface),
                    else => {},
                },
                .const_ => {},
            }
        }
    }

    fn emitIfaceImpl(self: *ImplGenerator, iface: *const ir.Interface) !void {
        const qname = iface.qualified_name;

        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try self.collectInterfaceMembers(iface, &ops, &attrs);

        // Derive the C-flat name used for Zig export symbols.
        const c_name = try self.prefixedCName(qname);
        defer self.alloc.free(c_name);

        try self.print("// ── interface {s} ──\n\n", .{c_name});

        // extern "C" declarations for Zig DDS runtime exports.
        try self.write("extern \"C\" {\n");
        for (ops.items) |op| try self.emitExternDecl(c_name, &op);
        for (attrs.items) |attr| try self.emitExternAttrDecls(c_name, &attr);
        try self.print("void zidl_{s}_deinit(void *ptr);\n", .{c_name});
        try self.write("}\n\n");

        // Concrete ZigImpl subclass.
        try self.print("class {s}ZigImpl : public ::{s} {{\n", .{ c_name, qname });
        try self.write("public:\n");
        try self.print(
            "    explicit {s}ZigImpl(void *ptr) : ptr_(ptr) {{}}\n",
            .{c_name},
        );
        try self.print(
            "    ~{s}ZigImpl() override {{ zidl_{s}_deinit(ptr_); }}\n\n",
            .{ c_name, c_name },
        );

        for (ops.items) |op| try self.emitImplOp(c_name, &op);
        for (attrs.items) |attr| try self.emitImplAttr(c_name, &attr);

        try self.write("private:\n    void *ptr_;\n};\n\n");
    }

    fn emitExternDecl(self: *ImplGenerator, c_name: []const u8, op: *const ir.Operation) !void {
        const ret_c = if (op.return_type) |rt|
            try self.typeRefToC(rt)
        else
            try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret_c);

        try self.print("{s} zidl_{s}_{s}(void *ptr", .{ ret_c, c_name, op.name });
        for (op.params) |p| {
            const pt = try self.paramTypeC(p);
            defer self.alloc.free(pt);
            try self.print(", {s} {s}", .{ pt, p.name });
        }
        try self.write(");\n");
    }

    fn emitExternAttrDecls(self: *ImplGenerator, c_name: []const u8, attr: *const ir.Attribute) !void {
        const at = try self.typeRefToC(attr.type_ref);
        defer self.alloc.free(at);
        try self.print("{s} zidl_{s}_get_{s}(void *ptr);\n", .{ at, c_name, attr.name });
        if (!attr.readonly) {
            try self.print(
                "void zidl_{s}_set_{s}(void *ptr, {s} value);\n",
                .{ c_name, attr.name, at },
            );
        }
    }

    fn emitImplOp(self: *ImplGenerator, c_name: []const u8, op: *const ir.Operation) !void {
        const ret_cpp = if (op.return_type) |rt|
            try self.typeRefToCpp(rt)
        else
            try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret_cpp);

        try self.print("    {s} {s}(", .{ ret_cpp, op.name });
        for (op.params, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            const p_cpp = try self.typeRefToCpp(p.type_ref);
            defer self.alloc.free(p_cpp);
            switch (p.mode) {
                .in_ => try self.print("{s} {s}", .{ p_cpp, p.name }),
                .out, .inout => try self.print("{s}& {s}", .{ p_cpp, p.name }),
            }
        }
        try self.write(") override {\n");

        // Decide if we can do direct forwarding.
        const all_simple = blk: {
            if (op.return_type) |rt| {
                if (!self.isSimpleType(rt)) break :blk false;
            }
            for (op.params) |p| {
                if (!self.isSimpleType(p.type_ref)) break :blk false;
            }
            break :blk true;
        };

        if (all_simple) {
            if (op.return_type != null) {
                try self.print("        return zidl_{s}_{s}(ptr_", .{ c_name, op.name });
            } else {
                try self.print("        zidl_{s}_{s}(ptr_", .{ c_name, op.name });
            }
            for (op.params) |p| {
                try self.print(", {s}", .{p.name});
            }
            try self.write(");\n");
        } else {
            // String return type: wrap in std::string.
            const is_str_return = if (op.return_type) |rt| (rt == .string) else false;
            if (is_str_return) {
                try self.print("        return std::string(zidl_{s}_{s}(ptr_", .{ c_name, op.name });
                for (op.params) |p| try self.emitParamAdapt(p);
                try self.write("));\n");
            } else {
                // General TODO stub.
                try self.print(
                    "        /* TODO: adapt C++ types to C ABI for {s}::{s} */\n",
                    .{ c_name, op.name },
                );
                if (op.return_type != null) try self.write("        return {};\n");
            }
        }
        try self.write("    }\n");
    }

    fn emitImplAttr(self: *ImplGenerator, c_name: []const u8, attr: *const ir.Attribute) !void {
        const a_cpp = try self.typeRefToCpp(attr.type_ref);
        defer self.alloc.free(a_cpp);

        // Getter.
        try self.print("    {s} {s}() const override {{\n", .{ a_cpp, attr.name });
        if (self.isSimpleType(attr.type_ref)) {
            try self.print("        return zidl_{s}_get_{s}(ptr_);\n", .{ c_name, attr.name });
        } else if (attr.type_ref == .string) {
            try self.print("        return std::string(zidl_{s}_get_{s}(ptr_));\n", .{ c_name, attr.name });
        } else {
            try self.print(
                "        /* TODO: adapt C++ type for get_{s} */\n        return {{}};\n",
                .{attr.name},
            );
        }
        try self.write("    }\n");

        // Setter (omitted for readonly).
        if (!attr.readonly) {
            try self.print("    void {s}({s} value) override {{\n", .{ attr.name, a_cpp });
            if (self.isSimpleType(attr.type_ref)) {
                try self.print("        zidl_{s}_set_{s}(ptr_, value);\n", .{ c_name, attr.name });
            } else if (attr.type_ref == .string) {
                try self.print("        zidl_{s}_set_{s}(ptr_, value.c_str());\n", .{ c_name, attr.name });
            } else {
                try self.print(
                    "        /* TODO: adapt C++ type for set_{s} */\n",
                    .{attr.name},
                );
            }
            try self.write("    }\n");
        }
    }

    fn emitParamAdapt(self: *ImplGenerator, p: ir.Parameter) !void {
        switch (p.type_ref) {
            .string => switch (p.mode) {
                .in_ => try self.print(", {s}.c_str()", .{p.name}),
                .out, .inout => try self.print(", {s}", .{p.name}),
            },
            else => try self.print(", {s}", .{p.name}),
        }
    }

    /// Return true if `tr` is a C-ABI-compatible primitive or enum (no adaptation needed).
    fn isSimpleType(self: *ImplGenerator, tr: ir.TypeRef) bool {
        _ = self;
        return switch (tr) {
            .base => true,
            .named => |td| switch (td) {
                .enum_ => true,
                else => false,
            },
            else => false,
        };
    }

    fn collectInterfaceMembers(
        self: *ImplGenerator,
        iface: *const ir.Interface,
        ops: *std.ArrayListUnmanaged(ir.Operation),
        attrs: *std.ArrayListUnmanaged(ir.Attribute),
    ) anyerror!void {
        for (iface.bases) |base| {
            if (base == .interface) try self.collectInterfaceMembers(base.interface, ops, attrs);
        }
        try ops.appendSlice(self.alloc, iface.operations);
        try attrs.appendSlice(self.alloc, iface.attributes);
    }

    /// C type for a TypeRef (used in extern "C" declarations).
    fn typeRefToC(self: *ImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCType(b)),
            .named => |td| self.prefixedCName(ir.typeDeclQualifiedName(td)),
            .sequence => |seq| blk: {
                const key = try self.seqElemKey(seq.element.*);
                defer self.alloc.free(key);
                break :blk std.fmt.allocPrint(self.alloc, "{s}_seq", .{key});
            },
            .string => self.alloc.dupe(u8, "char *"),
            .wstring => self.alloc.dupe(u8, "uint16_t *"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => self.alloc.dupe(u8, "void *"),
        };
    }

    fn seqElemKey(self: *ImplGenerator, elem: ir.TypeRef) ![]u8 {
        return switch (elem) {
            .base => |b| self.alloc.dupe(u8, baseToSeqKey(b)),
            .named => |td| self.prefixedCName(ir.typeDeclQualifiedName(td)),
            .sequence => |seq| blk: {
                const inner = try self.seqElemKey(seq.element.*);
                defer self.alloc.free(inner);
                break :blk std.fmt.allocPrint(self.alloc, "{s}_seq", .{inner});
            },
            .string => self.alloc.dupe(u8, "string"),
            .wstring => self.alloc.dupe(u8, "wstring"),
            .fixed_pt => self.alloc.dupe(u8, "fixed_pt"),
            .map => self.alloc.dupe(u8, "map"),
        };
    }

    fn prefixedCName(self: *ImplGenerator, qname: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, self.opts.type_prefix);
    }

    /// C type for a parameter (const ptr for `in` string, etc.).
    fn paramTypeC(self: *ImplGenerator, p: ir.Parameter) ![]u8 {
        const base = try self.typeRefToC(p.type_ref);
        defer self.alloc.free(base);
        return switch (p.mode) {
            .in_ => self.alloc.dupe(u8, base),
            .out, .inout => std.fmt.allocPrint(self.alloc, "{s} *", .{base}),
        };
    }

    /// C++ type for a TypeRef (used in method signatures).
    fn typeRefToCpp(self: *ImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCppType(b)),
            .named => |td| std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
            .sequence => |seq| blk: {
                const elem = try self.typeRefToCpp(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "std::vector<{s}>", .{elem});
            },
            .string => self.alloc.dupe(u8, "std::string"),
            .wstring => self.alloc.dupe(u8, "std::wstring"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => |m| blk: {
                const ks = try self.typeRefToCpp(m.key.*);
                defer self.alloc.free(ks);
                const vs = try self.typeRefToCpp(m.value.*);
                defer self.alloc.free(vs);
                break :blk std.fmt.allocPrint(self.alloc, "std::map<{s}, {s}>", .{ ks, vs });
            },
        };
    }
};

/// Returns true if a union case is the `default:` arm.
fn isDefaultUnionCase(cas: ir.UnionCase) bool {
    if (cas.labels.len == 0) return true;
    for (cas.labels) |lbl| {
        if (lbl == .default) return true;
    }
    return false;
}

/// EMHEADER LC value (0–3) for a fixed-size scalar type, or null for LC=4.
fn lcForCppTypeRef(type_ref: ir.TypeRef, dimensions: []const u64) ?u2 {
    if (dimensions.len > 0) return null;
    return switch (type_ref) {
        .base => |b| switch (b) {
            .boolean, .octet, .char, .int8, .uint8 => 0,
            .short, .int16, .unsigned_short, .uint16, .wchar => 1,
            .long, .int32, .unsigned_long, .uint32, .float => 2,
            .long_long, .int64, .unsigned_long_long, .uint64, .double => 3,
            else => null,
        },
        .named => |td| switch (td) {
            .enum_ => 2,
            else => null,
        },
        else => null,
    };
}

/// XTYPES member ID for a struct member (from @id annotation or declaration index).
fn memberIdAtCpp(m: ir.StructMember, idx: usize) u32 {
    return if (m.annotations.id) |id| id else @intCast(idx);
}

fn typeDeclHasKeyCpp(td: ir.TypeDecl) bool {
    return switch (td) {
        .struct_ => |s| structHasKeyCpp(s),
        else => false,
    };
}

fn structHasKeyCpp(s: *const ir.Struct) bool {
    if (s.base) |base| {
        if (typeDeclHasKeyCpp(base)) return true;
    }
    for (s.members) |m| {
        if (m.annotations.is_key) return true;
    }
    return false;
}

/// C++ type string for a TypeRef — file-level helper for CdrGenerator.
/// Caller owns the returned slice.
fn cppTypeStr(alloc: std.mem.Allocator, tr: ir.TypeRef) anyerror![]u8 {
    return switch (tr) {
        .base => |b| alloc.dupe(u8, baseToCppType(b)),
        .named => |td| std.fmt.allocPrint(alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
        .sequence => |seq| blk: {
            const elem = try cppTypeStr(alloc, seq.element.*);
            defer alloc.free(elem);
            break :blk std.fmt.allocPrint(alloc, "std::vector<{s}>", .{elem});
        },
        .string => alloc.dupe(u8, "std::string"),
        .wstring => alloc.dupe(u8, "std::wstring"),
        .fixed_pt => alloc.dupe(u8, "double"),
        .map => |m| blk: {
            const ks = try cppTypeStr(alloc, m.key.*);
            defer alloc.free(ks);
            const vs = try cppTypeStr(alloc, m.value.*);
            defer alloc.free(vs);
            break :blk std.fmt.allocPrint(alloc, "std::map<{s}, {s}>", .{ ks, vs });
        },
    };
}

/// Build a C-style array dimension suffix string: `[d0][d1]...`
/// Used for union array member declarations and getter/setter signatures.
/// Caller owns the returned slice.
fn cArrayDimsStr(alloc: std.mem.Allocator, dims: []const u64) ![]u8 {
    var result = try alloc.dupe(u8, "");
    for (dims) |d| {
        const seg = try std.fmt.allocPrint(alloc, "[{d}]", .{d});
        defer alloc.free(seg);
        const combined = try std.mem.concat(alloc, u8, &.{ result, seg });
        alloc.free(result);
        result = combined;
    }
    return result;
}

/// C type string for a base type specifier (shared with IfaceGenerator).
fn baseToCType(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "float",
        .double => "double",
        .long_double => "long double",
        .short => "int16_t",
        .long => "int32_t",
        .long_long => "int64_t",
        .unsigned_short => "uint16_t",
        .unsigned_long => "uint32_t",
        .unsigned_long_long => "uint64_t",
        .char => "char",
        .wchar => "uint16_t",
        .boolean => "bool",
        .octet => "uint8_t",
        .int8 => "int8_t",
        .uint8 => "uint8_t",
        .int16 => "int16_t",
        .int32 => "int32_t",
        .int64 => "int64_t",
        .uint16 => "uint16_t",
        .uint32 => "uint32_t",
        .uint64 => "uint64_t",
        .any, .object, .value_base => "void *",
    };
}

fn baseToSeqKey(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "float",
        .double => "double",
        .long_double => "long_double",
        .short => "int16_t",
        .long => "int32_t",
        .long_long => "int64_t",
        .unsigned_short => "uint16_t",
        .unsigned_long => "uint32_t",
        .unsigned_long_long => "uint64_t",
        .char => "char",
        .wchar => "wchar",
        .boolean => "bool",
        .octet => "uint8_t",
        .int8 => "int8_t",
        .uint8 => "uint8_t",
        .int16 => "int16_t",
        .int32 => "int32_t",
        .int64 => "int64_t",
        .uint16 => "uint16_t",
        .uint32 => "uint32_t",
        .uint64 => "uint64_t",
        .any, .object, .value_base => "void_ptr",
    };
}

// ── CDR static helpers ────────────────────────────────────────────────────────

fn baseCWriteFn(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "zidl_cdr_write_bool",
        .octet, .uint8 => "zidl_cdr_write_u8",
        .char => "zidl_cdr_write_char",
        .wchar => "zidl_cdr_write_u16",
        .int8 => "zidl_cdr_write_i8",
        .short, .int16 => "zidl_cdr_write_i16",
        .long, .int32 => "zidl_cdr_write_i32",
        .long_long, .int64 => "zidl_cdr_write_i64",
        .unsigned_short, .uint16 => "zidl_cdr_write_u16",
        .unsigned_long, .uint32 => "zidl_cdr_write_u32",
        .unsigned_long_long, .uint64 => "zidl_cdr_write_u64",
        .float => "zidl_cdr_write_f32",
        .double => "zidl_cdr_write_f64",
        .long_double => "zidl_cdr_write_f64",
        .any, .object, .value_base => "// unsupported",
    };
}

fn baseCReadFn(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "zidl_cdr_read_bool",
        .octet, .uint8 => "zidl_cdr_read_u8",
        .char => "zidl_cdr_read_char",
        .wchar => "zidl_cdr_read_u16",
        .int8 => "zidl_cdr_read_i8",
        .short, .int16 => "zidl_cdr_read_i16",
        .long, .int32 => "zidl_cdr_read_i32",
        .long_long, .int64 => "zidl_cdr_read_i64",
        .unsigned_short, .uint16 => "zidl_cdr_read_u16",
        .unsigned_long, .uint32 => "zidl_cdr_read_u32",
        .unsigned_long_long, .uint64 => "zidl_cdr_read_u64",
        .float => "zidl_cdr_read_f32",
        .double => "zidl_cdr_read_f64",
        .long_double => "zidl_cdr_read_f64",
        .any, .object, .value_base => "// unsupported",
    };
}

fn enumCStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "u8" else if (bound <= 16) "u16" else if (bound <= 32) "u32" else "u64";
}

fn enumCTypeName(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "uint8_t" else if (bound <= 16) "uint16_t" else if (bound <= 32) "uint32_t" else "uint64_t";
}

// ── File writing helper ───────────────────────────────────────────────────────

fn writeOutputFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    opts: interface.Options,
    filename: []const u8,
    content: []const u8,
) !void {
    const path = if (opts.output_dir.len > 0)
        try std.fs.path.join(alloc, &.{ opts.output_dir, filename })
    else
        try alloc.dupe(u8, filename);
    defer alloc.free(path);
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var write_buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(f, io, &write_buf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
}

// ── Split-file mode ───────────────────────────────────────────────────────────

/// Scan a single TypeDecl for include needs (map / optional).
fn scanIncludesTypeDecl(td: ir.TypeDecl, needs: *Generator.IncludeNeeds) void {
    switch (td) {
        .struct_ => |s| {
            for (s.members) |m| {
                if (m.annotations.is_optional) needs.optional = true;
                Generator.scanIncludesTypeRef(m.type_ref, needs);
            }
        },
        .union_ => |u| {
            for (u.cases) |c| Generator.scanIncludesTypeRef(c.type_ref, needs);
        },
        .exception => |e| {
            for (e.members) |m| {
                if (m.annotations.is_optional) needs.optional = true;
                Generator.scanIncludesTypeRef(m.type_ref, needs);
            }
        },
        else => {},
    }
}

/// Collect named type stems that `td` directly depends on (for `#include`).
fn collectHeaderDeps(
    alloc: std.mem.Allocator,
    td: ir.TypeDecl,
    my_stem: []const u8,
    out_set: *std.StringHashMapUnmanaged(void),
) !void {
    switch (td) {
        .struct_ => |s| {
            if (s.base) |b| try addNamedDep(alloc, ir.typeDeclQualifiedName(b), my_stem, out_set);
            for (s.members) |m| try collectTypeRefDeps(alloc, m.type_ref, my_stem, out_set);
        },
        .union_ => |u| {
            try collectTypeRefDeps(alloc, u.discriminant, my_stem, out_set);
            for (u.cases) |c| try collectTypeRefDeps(alloc, c.type_ref, my_stem, out_set);
        },
        .exception => |e| {
            for (e.members) |m| try collectTypeRefDeps(alloc, m.type_ref, my_stem, out_set);
        },
        .typedef => |t| try collectTypeRefDeps(alloc, t.type_ref, my_stem, out_set),
        .interface => |iface| {
            for (iface.bases) |b| try addNamedDep(alloc, ir.typeDeclQualifiedName(b), my_stem, out_set);
            for (iface.operations) |op| {
                if (op.return_type) |rt| try collectTypeRefDeps(alloc, rt, my_stem, out_set);
                for (op.params) |p| try collectTypeRefDeps(alloc, p.type_ref, my_stem, out_set);
            }
            for (iface.attributes) |a| try collectTypeRefDeps(alloc, a.type_ref, my_stem, out_set);
        },
        .bitset => |bs| {
            if (bs.base) |b| try addNamedDep(alloc, ir.typeDeclQualifiedName(b), my_stem, out_set);
        },
        .bitmask, .enum_, .native => {},
    }
}

fn collectTypeRefDeps(
    alloc: std.mem.Allocator,
    tr: ir.TypeRef,
    my_stem: []const u8,
    out_set: *std.StringHashMapUnmanaged(void),
) !void {
    switch (tr) {
        .named => |named_td| try addNamedDep(alloc, ir.typeDeclQualifiedName(named_td), my_stem, out_set),
        .sequence => |s| try collectTypeRefDeps(alloc, s.element.*, my_stem, out_set),
        .map => |m| {
            try collectTypeRefDeps(alloc, m.key.*, my_stem, out_set);
            try collectTypeRefDeps(alloc, m.value.*, my_stem, out_set);
        },
        else => {},
    }
}

fn addNamedDep(
    alloc: std.mem.Allocator,
    qname: []const u8,
    my_stem: []const u8,
    out_set: *std.StringHashMapUnmanaged(void),
) !void {
    const dep = try interface.cNameFromQualified(alloc, qname);
    defer alloc.free(dep);
    if (std.mem.eql(u8, dep, my_stem)) return;
    if (out_set.contains(dep)) return;
    const k = try alloc.dupe(u8, dep);
    errdefer alloc.free(k);
    try out_set.put(alloc, k, {});
}

fn collectTypeDeclsFlat(
    alloc: std.mem.Allocator,
    items: []const ir.ModuleItem,
    out: *std.ArrayListUnmanaged(ir.TypeDecl),
) !void {
    for (items) |item| {
        switch (item) {
            .module => |m| try collectTypeDeclsFlat(alloc, m.items, out),
            .type_decl => |td| try out.append(alloc, td),
            .const_ => {},
        }
    }
}

/// Generate a single-type C++ header into `out`.
fn generateTypeHeader(
    alloc: std.mem.Allocator,
    td: ir.TypeDecl,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    const qname = ir.typeDeclQualifiedName(td);
    const type_stem = try interface.cNameFromQualified(alloc, qname);
    defer alloc.free(type_stem);

    var needs = Generator.IncludeNeeds{};
    scanIncludesTypeDecl(td, &needs);

    var deps = std.StringHashMapUnmanaged(void).empty;
    defer {
        var it = deps.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        deps.deinit(alloc);
    }
    try collectHeaderDeps(alloc, td, type_stem, &deps);

    const prefix = opts.header_guard_prefix;
    const guard = try std.fmt.allocPrint(alloc, "{s}{s}_HPP", .{ prefix, type_stem });
    defer alloc.free(guard);
    for (guard) |*c| c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';

    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };

    try gen.print("// Generated by zidl from {s}.idl — DO NOT EDIT\n\n", .{opts.input_stem});
    if (opts.pragma_once) {
        try gen.write("#pragma once\n\n");
    } else {
        try gen.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
    }
    try gen.write("#include <cstdint>\n");
    try gen.write("#include <string>\n");
    try gen.write("#include <vector>\n");
    if (needs.map) try gen.write("#include <map>\n");
    if (needs.optional) try gen.write("#include <optional>\n");
    try gen.write("#include <array>\n");
    try gen.write("#include <stdexcept>\n");
    if (!opts.no_typesupport) {
        switch (td) {
            .struct_, .exception, .union_ => try gen.write("#include \"zidl_cdr.h\"\n"),
            else => {},
        }
    }
    var it = deps.keyIterator();
    while (it.next()) |k| {
        try gen.print("#include \"{s}.hpp\"\n", .{k.*});
    }
    try gen.write("\n");
    if (opts.cpp_namespace.len > 0) {
        try gen.print("namespace {s} {{\n\n", .{opts.cpp_namespace});
    }

    try gen.emitTypeDecl(td);

    if (!opts.no_typesupport) {
        switch (td) {
            .struct_ => |s| try gen.emitStructCdrProtos(s),
            .exception => |e| try gen.emitExceptionCdrProtos(e),
            .union_ => |u| try gen.emitUnionCdrProtos(u),
            else => {},
        }
    }

    if (opts.cpp_namespace.len > 0) {
        try gen.print("\n}} // namespace {s}\n", .{opts.cpp_namespace});
    }
    if (!opts.pragma_once) {
        try gen.print("#endif // {s}\n", .{guard});
    }
}

/// Generate a single-type CDR source file into `out`.
fn generateTypeCdrSource(
    alloc: std.mem.Allocator,
    td: ir.TypeDecl,
    opts: interface.Options,
    type_stem: []const u8,
    out: *std.ArrayList(u8),
) !void {
    var gen = CdrGenerator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.print("// Generated by zidl from {s}.idl — DO NOT EDIT\n\n", .{opts.input_stem});
    try gen.print("#include \"{s}.hpp\"\n", .{type_stem});
    try gen.write("#include \"zidl_cdr.h\"\n");
    try gen.write("#include <cstring>\n\n");
    try gen.emitTypeDecl(td);
}

/// Generate the aggregate `<stem>_all.hpp` that includes every per-type header.
fn generateAggregateHeader(
    alloc: std.mem.Allocator,
    type_decls: []const ir.TypeDecl,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    const prefix = opts.header_guard_prefix;
    const guard = try std.fmt.allocPrint(alloc, "{s}{s}_ALL_HPP", .{ prefix, opts.input_stem });
    defer alloc.free(guard);
    for (guard) |*c| c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';

    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };

    try gen.print("// Generated by zidl from {s}.idl — DO NOT EDIT\n\n", .{opts.input_stem});
    if (opts.pragma_once) {
        try gen.write("#pragma once\n\n");
    } else {
        try gen.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
    }
    for (type_decls) |td| {
        const qname = ir.typeDeclQualifiedName(td);
        const type_stem = try interface.cNameFromQualified(alloc, qname);
        defer alloc.free(type_stem);
        try gen.print("#include \"{s}.hpp\"\n", .{type_stem});
    }
    if (opts.pragma_once) {
        try gen.write("\n");
    } else {
        try gen.print("\n#endif // {s}\n", .{guard});
    }
}

/// Split-file entry point: one header+CDR pair per named type, plus aggregate.
pub fn generateSplitFiles(
    alloc: std.mem.Allocator,
    io: std.Io,
    spec: *const ir.Spec,
    opts: interface.Options,
) !void {
    var type_decls = std.ArrayListUnmanaged(ir.TypeDecl).empty;
    defer type_decls.deinit(alloc);
    try collectTypeDeclsFlat(alloc, spec.items, &type_decls);

    for (type_decls.items) |td| {
        const qname = ir.typeDeclQualifiedName(td);
        const type_stem = try interface.cNameFromQualified(alloc, qname);
        defer alloc.free(type_stem);

        var h_content = std.ArrayList(u8).empty;
        defer h_content.deinit(alloc);
        try generateTypeHeader(alloc, td, opts, &h_content);
        const h_filename = try std.fmt.allocPrint(alloc, "{s}.hpp", .{type_stem});
        defer alloc.free(h_filename);
        try writeOutputFile(alloc, io, opts, h_filename, h_content.items);

        if (!opts.no_typesupport) {
            switch (td) {
                .struct_, .exception, .union_ => {
                    var c_content = std.ArrayList(u8).empty;
                    defer c_content.deinit(alloc);
                    try generateTypeCdrSource(alloc, td, opts, type_stem, &c_content);
                    const c_filename = try std.fmt.allocPrint(alloc, "{s}_cdr.cpp", .{type_stem});
                    defer alloc.free(c_filename);
                    try writeOutputFile(alloc, io, opts, c_filename, c_content.items);
                },
                else => {},
            }
        }
    }

    var all_content = std.ArrayList(u8).empty;
    defer all_content.deinit(alloc);
    try generateAggregateHeader(alloc, type_decls.items, opts, &all_content);
    const all_filename = try std.fmt.allocPrint(alloc, "{s}_all.hpp", .{opts.input_stem});
    defer alloc.free(all_filename);
    try writeOutputFile(alloc, io, opts, all_filename, all_content.items);

    if (opts.generate_interfaces) {
        var impl_content = std.ArrayList(u8).empty;
        defer impl_content.deinit(alloc);
        try generateImplSource(alloc, spec, opts, &impl_content);
        const impl_filename = try std.fmt.allocPrint(alloc, "{s}_impl.cpp", .{opts.input_stem});
        defer alloc.free(impl_filename);
        try writeOutputFile(alloc, io, opts, impl_filename, impl_content.items);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

/// Parse `source`, analyse, build IR, generate C++ header into a returned buffer.
/// Caller must call `.deinit(testing.allocator)` on the returned ArrayList.
fn testGen(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    return testGenOpts(source, stem, .{});
}

fn testGenOpts(source: []const u8, stem: []const u8, extra: struct {
    type_prefix: []const u8 = "",
    generate_interfaces: bool = false,
    pragma_once: bool = false,
    cpp_namespace: []const u8 = "",
}) !std.ArrayList(u8) {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const opts = interface.Options{
        .input_stem = stem,
        .type_prefix = extra.type_prefix,
        .generate_interfaces = extra.generate_interfaces,
        .pragma_once = extra.pragma_once,
        .cpp_namespace = extra.cpp_namespace,
    };
    try generateHeader(alloc, &ir_spec, opts, &out);
    return out;
}

/// Like testGen but generates the CDR source (the `_cdr.cpp` file content).
fn testGenCdr(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    return testGenCdrOpts(source, stem, .{});
}

fn testGenCdrOpts(source: []const u8, stem: []const u8, extra: struct {
    type_prefix: []const u8 = "",
}) !std.ArrayList(u8) {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = stem, .type_prefix = extra.type_prefix };
    try generateCdrSource(alloc, &ir_spec, opts, &out);
    return out;
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "cpp_backend: header guard and includes" {
    var out = try testGen("struct Dummy { long x; };", "my_types");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "ifndef MY_TYPES_HPP"));
    try testing.expect(has(s, "define MY_TYPES_HPP"));
    try testing.expect(has(s, "#include <cstdint>"));
    try testing.expect(has(s, "#include <vector>"));
    try testing.expect(has(s, "#include <string>"));
    try testing.expect(has(s, "endif // MY_TYPES_HPP"));
}

test "cpp_backend: header guard prefix" {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init("struct X { long a; };", ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = "types", .header_guard_prefix = "MYNS_" };
    try generateHeader(alloc, &ir_spec, opts, &out);
    try testing.expect(has(out.items, "ifndef MYNS_TYPES_HPP"));
}

test "cpp_backend: simple struct" {
    var out = try testGen("struct Point { long x; long y; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "struct Point {"));
    try testing.expect(has(s, "int32_t x{};"));
    try testing.expect(has(s, "int32_t y{};"));
    try testing.expect(has(s, "}; // struct Point"));
}

test "cpp_backend: struct in module becomes namespace" {
    var out = try testGen(
        \\module Sensor { struct Reading { double value; }; };
    , "sensor");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "namespace Sensor {"));
    try testing.expect(has(s, "struct Reading {"));
    try testing.expect(has(s, "double value{};"));
    try testing.expect(has(s, "} // namespace Sensor"));
}

test "cpp_backend: nested modules become nested namespaces" {
    var out = try testGen(
        \\module A { module B { struct C { long x; }; }; };
    , "nested");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "namespace A {"));
    try testing.expect(has(s, "namespace B {"));
    try testing.expect(has(s, "struct C {"));
    try testing.expect(has(s, "} // namespace B"));
    try testing.expect(has(s, "} // namespace A"));
}

test "cpp_backend: enum class" {
    var out = try testGen("enum Color { RED, GREEN, BLUE };", "color");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "enum class Color : uint32_t {"));
    try testing.expect(has(s, "RED = 0"));
    try testing.expect(has(s, "GREEN = 1"));
    try testing.expect(has(s, "BLUE = 2"));
    try testing.expect(has(s, "}; // enum class Color"));
}

test "cpp_backend: union" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class Var {"));
    try testing.expect(has(s, "int32_t _d() const noexcept"));
    try testing.expect(has(s, "void i(int32_t v)"));
    try testing.expect(has(s, "double d() const"));
    try testing.expect(has(s, "int32_t _disc{};"));
    try testing.expect(has(s, "}; // class Var"));
}

test "cpp_backend: union CDR serialize/deserialize" {
    var out = try testGenCdr(
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int Var_serialize(ZidlCdrWriter *_w, const ::Var *_v)"));
    try testing.expect(has(s, "int Var_deserialize(ZidlCdrReader *_r, ::Var *_v)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, static_cast<int32_t>(_v->_d()))"));
    try testing.expect(has(s, "switch (_v->_d()) {"));
    try testing.expect(has(s, "case 0:"));
    try testing.expect(has(s, "case 1:"));
}

test "cpp_backend: union with array member decl" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long arr[3]; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class Var {"));
    // array private member
    try testing.expect(has(s, "int32_t _arr[3];"));
    // array getter: trailing return type with reference-to-array
    try testing.expect(has(s, "auto arr() const noexcept -> int32_t const (&)[3]"));
    // array setter: const-ref param
    try testing.expect(has(s, "void arr(int32_t const (&v)[3]) noexcept"));
    // std::memcpy in setter
    try testing.expect(has(s, "std::memcpy(_u._arr, v, sizeof(_u._arr))"));
    // <cstring> included for std::memcpy
    try testing.expect(has(s, "#include <cstring>"));
    // scalar member unaffected
    try testing.expect(has(s, "void d(double v)"));
    try testing.expect(has(s, "}; // class Var"));
}

test "cpp_backend: union array CDR serialize/deserialize" {
    var out = try testGenCdr(
        \\union Var switch (long) { case 0: long arr[3]; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // serialize: write array via loop
    try testing.expect(has(s, "int Var_serialize(ZidlCdrWriter *_w, const ::Var *_v)"));
    try testing.expect(has(s, "_v->arr()[_ai0]"));
    // deserialize: temp array decl + read loop + setter call
    try testing.expect(has(s, "int Var_deserialize(ZidlCdrReader *_r, ::Var *_v)"));
    try testing.expect(has(s, "int32_t _tmp_arr[3]{}"));
    try testing.expect(has(s, "_v->arr(_tmp_arr)"));
    // no TODO stubs remain
    try testing.expect(!has(s, "TODO"));
}

test "cpp_backend: typedef scalar" {
    var out = try testGen("typedef long MyInt;", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "using MyInt = int32_t;"));
}

test "cpp_backend: typedef array" {
    var out = try testGen("typedef long Matrix[2][4];", "types");
    defer out.deinit(testing.allocator);
    // IDL [2][4] → std::array<std::array<int32_t, 4>, 2>
    try testing.expect(has(out.items, "using Matrix = std::array<std::array<int32_t, 4>, 2>;"));
}

test "cpp_backend: typedef 1d array" {
    var out = try testGen("typedef double Vec3[3];", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "using Vec3 = std::array<double, 3>;"));
}

test "cpp_backend: const integer" {
    var out = try testGen("const long MAX_SIZE = 100;", "consts");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "constexpr int32_t MAX_SIZE{100};"));
}

test "cpp_backend: const boolean" {
    var out = try testGen("const boolean FLAG = TRUE;", "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "constexpr bool FLAG{true};"));
}

test "cpp_backend: const string" {
    var out = try testGen(
        \\const string GREETING = "hello";
    , "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "constexpr const char* GREETING{\"hello\"};"));
}

test "cpp_backend: sequence member becomes std::vector" {
    var out = try testGen("struct Foo { sequence<long> items; };", "seq");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "std::vector<int32_t> items{};"));
}

test "cpp_backend: string member becomes std::string" {
    var out = try testGen("struct Msg { string text; };", "msg");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "std::string text{};"));
}

test "cpp_backend: optional member" {
    var out = try testGen(
        \\struct Opt {
        \\  @optional long maybe_x;
        \\  long required_y;
        \\};
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include <optional>"));
    try testing.expect(!has(s, "#include <map>"));
    try testing.expect(has(s, "std::optional<int32_t> maybe_x{};"));
    try testing.expect(has(s, "int32_t required_y{};"));
}

test "cpp_backend: no optional no map omits those includes" {
    var out = try testGen(
        \\struct Plain { long x; string s; sequence<long> nums; };
    , "plain");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "#include <optional>"));
    try testing.expect(!has(s, "#include <map>"));
}

test "cpp_backend: interface with operation" {
    var out = try testGen(
        \\interface Calc {
        \\  long add(in long a, in long b);
        \\  void reset();
        \\};
    , "calc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class Calc {"));
    try testing.expect(has(s, "virtual ~Calc() = default;"));
    try testing.expect(has(s, "virtual int32_t add(int32_t a, int32_t b) = 0;"));
    try testing.expect(has(s, "virtual void reset() = 0;"));
    try testing.expect(has(s, "}; // class Calc"));
}

test "cpp_backend: interface with attribute" {
    var out = try testGen(
        \\interface Obj {
        \\  attribute long value;
        \\  readonly attribute string name;
        \\};
    , "obj");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "virtual int32_t value() const = 0;"));
    try testing.expect(has(s, "virtual void value(int32_t value) = 0;"));
    try testing.expect(has(s, "virtual std::string name() const = 0;"));
    // No setter for readonly.
    try testing.expect(!has(s, "virtual void name("));
}

test "cpp_backend: interface inheritance" {
    var out = try testGen(
        \\interface Base { void foo(); };
        \\interface Derived : Base { void bar(); };
    , "inh");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class Derived : public ::Base {"));
}

test "cpp_backend: exception" {
    var out = try testGen(
        \\exception MyError { long code; string message; };
    , "err");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "struct MyError : std::exception {"));
    try testing.expect(has(s, "const char* what() const noexcept override { return \"MyError\"; }"));
    try testing.expect(has(s, "int32_t code{};"));
    try testing.expect(has(s, "std::string message{};"));
}

test "cpp_backend: bitmask" {
    var out = try testGen(
        \\bitmask Flags { FLAG_A, FLAG_B, FLAG_C };
    , "flags");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "using Flags = uint32_t;"));
    try testing.expect(has(s, "Flags_FLAG_A{Flags(1u << 0)};"));
    try testing.expect(has(s, "Flags_FLAG_B{Flags(1u << 1)};"));
    try testing.expect(has(s, "Flags_FLAG_C{Flags(1u << 2)};"));
}

test "cpp_backend: bitset" {
    var out = try testGen(
        \\bitset Bits { bitfield<4> lo; bitfield<4> hi; };
    , "bits");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "struct Bits {"));
    try testing.expect(has(s, "lo : 4;"));
    try testing.expect(has(s, "hi : 4;"));
}

test "cpp_backend: bitset cdr byte" {
    // 3+1 = 4 bits → uint8_t wire
    var out = try testGenCdr(
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
        \\struct S { BS bs; };
    , "bits");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "uint8_t _bsv = 0;"));
    try testing.expect(has(s, "_bsv |= (uint8_t)_v->bs.a & 0x7u;"));
    try testing.expect(has(s, "_bsv |= ((uint8_t)_v->bs.b & 0x1u) << 3;"));
    try testing.expect(has(s, "zidl_cdr_write_u8(_w, _bsv)"));
    try testing.expect(has(s, "zidl_cdr_read_u8(_r, &_bsv)"));
    try testing.expect(has(s, "_v->bs.a = _bsv & 0x7u;"));
    try testing.expect(has(s, "_v->bs.b = (_bsv >> 3) & 0x1u;"));
}

test "cpp_backend: bitset cdr int" {
    // 16+16 = 32 bits → uint32_t wire
    var out = try testGenCdr(
        \\bitset Cfg { bitfield<16> lo; bitfield<16> hi; };
        \\struct S { Cfg c; };
    , "cfg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "uint32_t _bsv = 0;"));
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, _bsv)"));
    try testing.expect(has(s, "zidl_cdr_read_u32(_r, &_bsv)"));
    try testing.expect(has(s, "_v->c.lo = _bsv & 0xFFFFu;"));
    try testing.expect(has(s, "_v->c.hi = (_bsv >> 16) & 0xFFFFu;"));
}

test "cpp_backend: map field declaration" {
    var out = try testGen("struct S { map<long, string> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include <map>"));
    try testing.expect(has(s, "std::map<int32_t, std::string> m{}"));
}

test "cpp_backend: map cdr write" {
    var out = try testGenCdr("struct S { map<long, string> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "uint32_t _mc = (uint32_t)_v->m.size()"));
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, _mc)"));
    try testing.expect(has(s, "for (auto const& _me : _v->m)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _me.first)"));
    try testing.expect(has(s, "_me.second.c_str()"));
}

test "cpp_backend: map cdr read" {
    var out = try testGenCdr("struct S { map<long, string> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_read_u32(_r, &_mc)"));
    try testing.expect(has(s, "for (uint32_t _mi = 0; _mi < _mc; _mi++)"));
    try testing.expect(has(s, "int32_t _mk{};"));
    try testing.expect(has(s, "std::string _mv{};"));
    try testing.expect(has(s, "_v->m.emplace(std::move(_mk), std::move(_mv))"));
}

test "cpp_backend: native" {
    var out = try testGen("native Opaque;", "nat");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "class Opaque; // @native"));
}

test "cpp_backend: struct array member" {
    var out = try testGen("struct Vec { long data[3]; };", "vec");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "int32_t data[3];"));
}

test "cpp_backend: cross-namespace type ref uses :: prefix" {
    var out = try testGen(
        \\struct Color { long r; long g; long b; };
        \\struct Pixel { Color color; long alpha; };
    , "cross");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Pixel.color should reference Color with :: prefix.
    try testing.expect(has(s, "::Color color{};"));
}

// ── CDR (Phase 8) tests ───────────────────────────────────────────────────────

test "cpp_backend: header includes zidl_cdr.h when typesupport enabled" {
    var out = try testGen("struct Foo { long x; };", "foo");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "#include \"zidl_cdr.h\""));
}

test "cpp_backend: header omits zidl_cdr.h with --no-typesupport" {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init("struct Foo { long x; };", ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = "foo", .no_typesupport = true };
    try generateHeader(alloc, &ir_spec, opts, &out);
    try testing.expect(!has(out.items, "zidl_cdr.h"));
}

test "cpp_backend: header contains CDR prototypes for struct" {
    var out = try testGen("struct Point { long x; long y; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#define Point_has_key 0"));
    try testing.expect(has(s, "int Point_serialize(ZidlCdrWriter *_w, const ::Point *_v);"));
    try testing.expect(has(s, "int Point_deserialize(ZidlCdrReader *_r, ::Point *_v);"));
}

test "cpp_backend: header CDR prototype uses :: for namespaced type" {
    var out = try testGen("module Ns { struct Reading { double v; }; };", "ns");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int Ns_Reading_serialize(ZidlCdrWriter *_w, const ::Ns::Reading *_v);"));
    try testing.expect(has(s, "int Ns_Reading_deserialize(ZidlCdrReader *_r, ::Ns::Reading *_v);"));
}

test "cpp_backend: header CDR prototype includes serialize_key when @key present" {
    var out = try testGen("struct Msg { @key long id; string text; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#define Msg_has_key 1"));
    try testing.expect(has(s, "int Msg_serialize_key(ZidlCdrWriter *_w, const ::Msg *_v);"));
}

test "cpp_backend: cdr source banner and includes" {
    var out = try testGenCdr("struct Foo { long x; };", "types");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "Generated by zidl from types.idl"));
    try testing.expect(has(s, "#include \"types.hpp\""));
    try testing.expect(has(s, "#include \"zidl_cdr.h\""));
}

test "cpp_backend: cdr @final struct serialize/deserialize" {
    var out = try testGenCdr(
        \\@final struct Point { long x; long y; };
    , "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int Point_serialize(ZidlCdrWriter *_w, const ::Point *_v) {"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->x)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->y)"));
    // No DHEADER for @final.
    try testing.expect(!has(s, "reserve_dheader_maybe"));
    try testing.expect(has(s, "int Point_deserialize(ZidlCdrReader *_r, ::Point *_v) {"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &_v->x)"));
}

test "cpp_backend: cdr @appendable struct gets DHEADER framing" {
    var out = try testGenCdr(
        \\@appendable struct Node { long val; };
    , "node");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_reserve_dheader_maybe(_w, &_dh)"));
    try testing.expect(has(s, "zidl_cdr_patch_dheader_maybe(_w, _dh)"));
    try testing.expect(has(s, "zidl_cdr_skip_dheader_if_xcdr2(_r)"));
}

test "cpp_backend: cdr @key serialize_key" {
    var out = try testGenCdr(
        \\struct Topic { @key long id; string name; };
    , "topic");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int Topic_serialize_key(ZidlCdrWriter *_w, const ::Topic *_v) {"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->id)"));
}

test "cpp_backend: cdr std::string serialize uses c_str and size" {
    var out = try testGenCdr("struct Msg { string text; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_write_string(_w, _v->text.c_str(), (uint32_t)_v->text.size())"));
}

test "cpp_backend: cdr std::string deserialize uses zerocopy assign" {
    var out = try testGenCdr("struct Msg { string text; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_read_string_zerocopy(_r, &_sp, &_sl)"));
    try testing.expect(has(s, "_v->text.assign(_sp, _sl)"));
}

test "cpp_backend: cdr bounded string deserialize checks bound" {
    var out = try testGenCdr("struct Msg { string<64> name; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "if (_sl > 64u) return ZIDL_CDR_INVALID"));
    try testing.expect(has(s, "_v->name.assign(_sp, _sl)"));
}

test "cpp_backend: cdr std::vector serialize" {
    var out = try testGenCdr("struct List { sequence<long> items; };", "list");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, (uint32_t)_v->items.size())"));
    try testing.expect(has(s, "_v->items.size(); _si++"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->items[_si])"));
}

test "cpp_backend: cdr std::vector deserialize uses resize" {
    var out = try testGenCdr("struct List { sequence<long> items; };", "list");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "_v->items.resize(_sl)"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &_v->items[_si])"));
}

test "cpp_backend: cdr enum class uses static_cast" {
    var out = try testGenCdr(
        \\enum Color { RED, GREEN, BLUE };
        \\struct Pixel { Color c; };
    , "px");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, static_cast<uint32_t>(_v->c))"));
    try testing.expect(has(s, "static_cast<::Color>(_ev)"));
}

test "cpp_backend: cdr nested struct calls serialize/deserialize by name" {
    var out = try testGenCdr(
        \\struct Inner { long v; };
        \\struct Outer { Inner inner; };
    , "nested");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "Inner_serialize(_w, &_v->inner)"));
    try testing.expect(has(s, "Inner_deserialize(_r, &_v->inner)"));
}

test "cpp_backend: cdr array member generates loop" {
    var out = try testGenCdr("struct Mat { long data[3]; };", "mat");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "for (_ai0 = 0; _ai0 < 3u; _ai0++)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->data[_ai0])"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &_v->data[_ai0])"));
}

test "cpp_backend: cdr all primitives serialize" {
    var out = try testGenCdr(
        \\struct Prims {
        \\  boolean b; octet o; char c; short s; long l;
        \\  unsigned long ul; long long ll; float f; double d;
        \\};
    , "prims");
    defer out.deinit(testing.allocator);
    const src = out.items;
    try testing.expect(has(src, "zidl_cdr_write_bool(_w, _v->b)"));
    try testing.expect(has(src, "zidl_cdr_write_u8(_w, _v->o)"));
    try testing.expect(has(src, "zidl_cdr_write_char(_w, _v->c)"));
    try testing.expect(has(src, "zidl_cdr_write_i16(_w, _v->s)"));
    try testing.expect(has(src, "zidl_cdr_write_i32(_w, _v->l)"));
    try testing.expect(has(src, "zidl_cdr_write_u32(_w, _v->ul)"));
    try testing.expect(has(src, "zidl_cdr_write_i64(_w, _v->ll)"));
    try testing.expect(has(src, "zidl_cdr_write_f32(_w, _v->f)"));
    try testing.expect(has(src, "zidl_cdr_write_f64(_w, _v->d)"));
}

test "cpp_backend: cdr @optional scalar serialize writes bool then value" {
    var out = try testGenCdr(
        \\struct Opt { @optional long maybe_x; long y; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Presence flag written before value.
    try testing.expect(has(s, "zidl_cdr_write_bool(_w, _v->maybe_x.has_value() ? 1 : 0)"));
    // Inner value accessed via dereference.
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, (*_v->maybe_x))"));
    // Non-optional field unaffected.
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->y)"));
}

test "cpp_backend: cdr @optional scalar deserialize reads bool then emplaces" {
    var out = try testGenCdr(
        \\struct Opt { @optional long maybe_x; long y; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Presence flag read.
    try testing.expect(has(s, "zidl_cdr_read_bool(_r, &_ip_maybe_x)"));
    // Emplace + read inner value on present.
    try testing.expect(has(s, "_v->maybe_x.emplace()"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &(*_v->maybe_x))"));
    // Nullopt on absent.
    try testing.expect(has(s, "_v->maybe_x = std::nullopt"));
}

// ── wstring CDR tests ─────────────────────────────────────────────────────────

test "cpp_backend cdr: wstring write emits u32 count then u16 loop" {
    var out = try testGenCdr("struct S { wstring ws; };", "s");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Count written as u32 (length + 1 for NUL wchar).
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, _wl + 1u)"));
    // Each wchar_t cast to uint16_t and written as u16.
    try testing.expect(has(s, "zidl_cdr_write_u16(_w, (uint16_t)"));
    // Terminating NUL wchar.
    try testing.expect(has(s, "zidl_cdr_write_u16(_w, 0u)"));
}

test "cpp_backend cdr: wstring read decodes u32 count then u16 chars" {
    var out = try testGenCdr("struct S { wstring ws; };", "s");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Count read as u32.
    try testing.expect(has(s, "zidl_cdr_read_u32(_r, &_wc)"));
    // Each u16 read and cast to wchar_t.
    try testing.expect(has(s, "zidl_cdr_read_u16(_r, &_wv)"));
    try testing.expect(has(s, "(wchar_t)_wv"));
    // NUL wchar consumed.
    try testing.expect(has(s, "zidl_cdr_read_u16(_r, &_nul)"));
}

test "cpp_backend cdr: bounded wstring read includes bound check" {
    var out = try testGenCdr("struct S { wstring<8> ws; };", "s");
    defer out.deinit(testing.allocator);
    // Bound check with the correct value (8).
    try testing.expect(has(out.items, "8u"));
    try testing.expect(has(out.items, "ZIDL_CDR_INVALID"));
}

test "cpp_backend cdr: unbounded wstring read has no bound check" {
    var out = try testGenCdr("struct S { wstring ws; };", "s");
    defer out.deinit(testing.allocator);
    // The 8u bound guard from the bounded test must not appear here.
    try testing.expect(!has(out.items, "8u"));
}

// ── --generate-interfaces tests ───────────────────────────────────────────────

fn testGenImpl(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = stem, .generate_interfaces = true };
    try generateImplSource(alloc, &ir_spec, opts, &out);
    return out;
}

test "cpp_backend: impl source includes header" {
    var out = try testGenImpl("interface Foo { void bar(); };", "foo");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "#include \"foo.hpp\""));
}

test "cpp_backend: impl source extern C block" {
    var out = try testGenImpl(
        \\interface Calc { long add(in long a, in long b); void reset(); };
    , "calc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "extern \"C\" {"));
    try testing.expect(has(s, "int32_t zidl_Calc_add(void *ptr, int32_t a, int32_t b);"));
    try testing.expect(has(s, "void zidl_Calc_reset(void *ptr);"));
    try testing.expect(has(s, "void zidl_Calc_deinit(void *ptr);"));
}

test "cpp_backend: impl source ZigImpl class" {
    var out = try testGenImpl(
        \\interface Calc { long add(in long a, in long b); void reset(); };
    , "calc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class CalcZigImpl : public ::Calc {"));
    try testing.expect(has(s, "explicit CalcZigImpl(void *ptr) : ptr_(ptr) {}"));
    try testing.expect(has(s, "~CalcZigImpl() override { zidl_Calc_deinit(ptr_); }"));
    try testing.expect(has(s, "int32_t add(int32_t a, int32_t b) override {"));
    try testing.expect(has(s, "return zidl_Calc_add(ptr_, a, b);"));
    try testing.expect(has(s, "void reset() override {"));
    try testing.expect(has(s, "zidl_Calc_reset(ptr_);"));
    try testing.expect(has(s, "private:"));
    try testing.expect(has(s, "void *ptr_;"));
}

// ── split-file tests ──────────────────────────────────────────────────────────

/// Build IR from `source`, call `generateTypeHeader` for the TypeDecl at `idx`.
fn testGenTypeHeader(source: []const u8, stem: []const u8, idx: usize) !std.ArrayList(u8) {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var decls = std.ArrayListUnmanaged(ir.TypeDecl).empty;
    defer decls.deinit(alloc);
    try collectTypeDeclsFlat(alloc, ir_spec.items, &decls);
    const opts = interface.Options{ .input_stem = stem };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try generateTypeHeader(alloc, decls.items[idx], opts, &out);
    return out;
}

test "cpp_backend split: enum gets own header with guard" {
    var out = try testGenTypeHeader("enum Color { RED, GREEN, BLUE };", "color", 0);
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#ifndef COLOR_HPP"));
    try testing.expect(has(s, "#define COLOR_HPP"));
    try testing.expect(has(s, "enum class Color"));
    try testing.expect(has(s, "#endif // COLOR_HPP"));
    try testing.expect(!has(s, "zidl_cdr.h"));
}

test "cpp_backend split: struct includes deps" {
    var out = try testGenTypeHeader(
        \\enum Color { RED };
        \\struct Foo { Color c; };
    , "types", 1);
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include \"Color.hpp\""));
    try testing.expect(has(s, "#include \"zidl_cdr.h\""));
    try testing.expect(has(s, "struct Foo"));
}

test "cpp_backend split: aggregate header includes all types" {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    const source = "enum Color { RED }; struct Foo { long x; };";
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var decls = std.ArrayListUnmanaged(ir.TypeDecl).empty;
    defer decls.deinit(alloc);
    try collectTypeDeclsFlat(alloc, ir_spec.items, &decls);
    const opts = interface.Options{ .input_stem = "types" };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try generateAggregateHeader(alloc, decls.items, opts, &out);
    const s = out.items;
    try testing.expect(has(s, "#ifndef TYPES_ALL_HPP"));
    try testing.expect(has(s, "#include \"Color.hpp\""));
    try testing.expect(has(s, "#include \"Foo.hpp\""));
}

test "cpp_backend type_prefix: CDR function prototypes use prefix" {
    var h = try testGenOpts("struct Foo { long x; };", "t", .{ .type_prefix = "DDS_" });
    defer h.deinit(testing.allocator);
    // CDR proto in header uses prefixed flat name.
    try testing.expect(has(h.items, "DDS_Foo_serialize("));
    try testing.expect(has(h.items, "DDS_Foo_deserialize("));
}

test "cpp_backend type_prefix: C++ type names inside namespace NOT prefixed" {
    var h = try testGenOpts("module M { struct Bar { long x; }; };", "t", .{ .type_prefix = "DDS_" });
    defer h.deinit(testing.allocator);
    // Namespace M and struct Bar retain their original names.
    try testing.expect(has(h.items, "namespace M {"));
    try testing.expect(has(h.items, "struct Bar {"));
    // But the CDR flat function IS prefixed.
    try testing.expect(has(h.items, "DDS_M_Bar_serialize("));
}

test "cpp_backend type_prefix: CDR source function name uses prefix" {
    var src = try testGenCdrOpts("struct Foo { long x; };", "t", .{ .type_prefix = "DDS_" });
    defer src.deinit(testing.allocator);
    try testing.expect(has(src.items, "DDS_Foo_serialize("));
    try testing.expect(has(src.items, "DDS_Foo_deserialize("));
}

test "cpp_backend pragma_once: replaces ifndef/define/endif guard" {
    var h = try testGenOpts("struct Foo { long x; };", "foo", .{ .pragma_once = true });
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "#pragma once"));
    try testing.expect(!has(s, "#ifndef"));
    try testing.expect(!has(s, "#define FOO_HPP"));
    try testing.expect(!has(s, "#endif"));
}

test "cpp_backend cpp_namespace: wraps output in named namespace" {
    var h = try testGenOpts("struct Foo { long x; };", "foo", .{ .cpp_namespace = "dds" });
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "namespace dds {"));
    try testing.expect(has(s, "} // namespace dds"));
    // The IDL struct is inside the outer namespace.
    const ns_open = std.mem.indexOf(u8, s, "namespace dds {").?;
    const struct_pos = std.mem.indexOf(u8, s, "struct Foo {").?;
    const ns_close = std.mem.indexOf(u8, s, "} // namespace dds").?;
    try testing.expect(struct_pos > ns_open);
    try testing.expect(struct_pos < ns_close);
}

test "cpp_backend pragma_once split: per-type header uses pragma once" {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init("struct Foo { long x; };", ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try generateTypeHeader(alloc, ir_spec.items[0].type_decl, interface.Options{
        .input_stem = "foo",
        .pragma_once = true,
    }, &out);
    const s = out.items;
    try testing.expect(has(s, "#pragma once"));
    try testing.expect(!has(s, "#ifndef"));
    try testing.expect(!has(s, "#endif"));
}

test "cpp_backend cdr: fixed<5,2> serialize/deserialize" {
    var cpp_src = try testGenCdr("struct S { fixed<5,2> price; };", "fp");
    defer cpp_src.deinit(testing.allocator);
    const s = cpp_src.items;
    try testing.expect(has(s, "zidl_cdr_write_fixed(_w, 5, 2, _v->price)"));
    try testing.expect(has(s, "zidl_cdr_read_fixed(_r, 5, 2, &_v->price)"));
}

test "cpp_backend: fixed<5,2> field type is double" {
    var h = try testGen("struct S { fixed<5,2> price; };", "fp");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "double price{}")); // C++ brace-initialization
}
