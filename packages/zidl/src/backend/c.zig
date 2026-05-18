//! C language mapping backend (OMG formal/99-07-35 baseline + IDL4 extensions).
//!
//! Generates a single `.h` header per IDL spec containing:
//!   - Sequence typedefs (pre-scanned, emitted before first use)
//!   - Struct / union / enum / bitmask / bitset / typedef / native / exception
//!     declarations in source order
//!   - Interface forward pointer typedef + operation prototypes
//!   - Module-level `#define` constants
//!
//! ## Primitive type mapping
//!
//!   IDL short / long / long long       → int16_t / int32_t / int64_t
//!   IDL unsigned short / long / …      → uint16_t / uint32_t / uint64_t
//!   IDL float / double / long double   → float / double / long double
//!   IDL char / wchar                   → char / uint16_t
//!   IDL boolean / octet                → bool / uint8_t
//!   IDL int8 … uint64                  → int8_t … uint64_t (IDL4 extended)
//!   IDL string / wstring               → char * / uint16_t *
//!   IDL any / object / value_base      → void *
//!   IDL fixed<D,S>                     → double (approximate; exact mapping TBD)
//!   IDL map<K,V>                       → void * (no standard C mapping)
//!
//! ## Sequence typedefs
//!
//!   sequence<long> → `int32_t_seq` (struct with _maximum/_length/_buffer/_release)
//!
//! ## Enum enumerators
//!
//!   IDL: `enum Color { RED, GREEN, BLUE };`
//!   C:   enumerators prefixed with the enum name: `Color_RED`, `Color_GREEN`, …

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir/root.zig");
const interface = @import("interface.zig");

// ── Public backend struct ─────────────────────────────────────────────────────

pub const CBackend = struct {
    alloc: std.mem.Allocator,

    pub fn create(alloc: std.mem.Allocator) !*CBackend {
        const self = try alloc.create(CBackend);
        self.* = .{ .alloc = alloc };
        return self;
    }

    /// Return a `Backend` value that dispatches to this instance.
    pub fn backend(self: *CBackend) interface.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = interface.Backend.Vtable{
        .language_id = "c",
        .generate = vtableGenerate,
        .deinit = vtableDeinit,
    };

    fn vtableGenerate(
        ctx: *anyopaque,
        spec: *const ir.Spec,
        opts: interface.Options,
    ) anyerror!void {
        const self: *CBackend = @ptrCast(@alignCast(ctx));
        const io = std.Io.Threaded.global_single_threaded.io();

        if (opts.split_files) {
            try generateSplitFiles(self.alloc, io, spec, opts);
            return;
        }

        // ── <stem>.h ──────────────────────────────────────────────────────────

        var header_content = std.ArrayList(u8).empty;
        defer header_content.deinit(self.alloc);
        try generateHeader(self.alloc, spec, opts, &header_content);
        const h_filename = try std.fmt.allocPrint(self.alloc, "{s}.h", .{opts.input_stem});
        defer self.alloc.free(h_filename);
        try writeOutputFile(self.alloc, io, opts, h_filename, header_content.items);

        // ── <stem>_cdr.c ─────────────────────────────────────────────────────

        if (!opts.no_typesupport) {
            var cdr_content = std.ArrayList(u8).empty;
            defer cdr_content.deinit(self.alloc);
            try generateCdrSource(self.alloc, spec, opts, &cdr_content);
            const c_filename = try std.fmt.allocPrint(self.alloc, "{s}_cdr.c", .{opts.input_stem});
            defer self.alloc.free(c_filename);
            try writeOutputFile(self.alloc, io, opts, c_filename, cdr_content.items);
        }

        // ── <stem>_iface.c ────────────────────────────────────────────────────

        if (opts.generate_interfaces) {
            var iface_content = std.ArrayList(u8).empty;
            defer iface_content.deinit(self.alloc);
            try generateIfaceSource(self.alloc, spec, opts, &iface_content);
            const if_filename = try std.fmt.allocPrint(self.alloc, "{s}_iface.c", .{opts.input_stem});
            defer self.alloc.free(if_filename);
            try writeOutputFile(self.alloc, io, opts, if_filename, iface_content.items);
        }
    }

    fn vtableDeinit(ctx: *anyopaque) void {
        const self: *CBackend = @ptrCast(@alignCast(ctx));
        self.alloc.destroy(self);
    }
};

// ── Public entry point (testable) ─────────────────────────────────────────────

/// Generate C header content into `out`.
///
/// This is the heart of the backend; exposed for unit testing without touching
/// the filesystem.  The vtable's `vtableGenerate` calls this then writes the
/// result to `<opts.output_dir>/<opts.input_stem>.h`.
pub fn generateHeader(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    if (itemsHaveMaps(spec.items)) return error.MapTypeNotSupportedInCBackend;
    var gen = Generator{
        .alloc = alloc,
        .opts = opts,
        .out = out,
        .seq_emitted = .empty,
    };
    defer {
        // Free the heap-allocated key strings stored in the map.
        var it = gen.seq_emitted.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        gen.seq_emitted.deinit(alloc);
    }
    try gen.emitHeader(spec);
}

/// Returns true if any type reference anywhere in the spec is a map<K,V>.
/// Used to reject map types early with a clear error.
fn itemsHaveMaps(items: []const ir.ModuleItem) bool {
    for (items) |item| switch (item) {
        .module => |m| if (itemsHaveMaps(m.items)) return true,
        .type_decl => |td| if (tdHasMap(td)) return true,
        .const_ => {},
    };
    return false;
}

fn tdHasMap(td: ir.TypeDecl) bool {
    switch (td) {
        .struct_ => |s| for (s.members) |m| if (typeRefHasMap(m.type_ref)) return true,
        .union_ => |u| for (u.cases) |c| if (typeRefHasMap(c.type_ref)) return true,
        .exception => |e| for (e.members) |m| if (typeRefHasMap(m.type_ref)) return true,
        .typedef => |t| return typeRefHasMap(t.type_ref),
        else => {},
    }
    return false;
}

fn typeRefHasMap(tr: ir.TypeRef) bool {
    return switch (tr) {
        .map => true,
        .sequence => |s| typeRefHasMap(s.element.*),
        .named => |td| switch (td) {
            .typedef => |t| typeRefHasMap(t.type_ref),
            else => false,
        },
        else => false,
    };
}

// ── Generator (private implementation) ───────────────────────────────────────

const Generator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),
    /// Sequence element keys (e.g. `"int32_t"`) for which we have already
    /// emitted a sequence typedef.  Prevents duplicate emission.
    seq_emitted: std.StringHashMapUnmanaged(void),
    /// When true, wrap each sequence typedef in `#ifndef`/`#define`/`#endif`
    /// guards so that multiple split headers defining the same typedef can be
    /// safely included together.
    guarded_seqs: bool = false,

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

    fn emitHeader(self: *Generator, spec: *const ir.Spec) !void {
        const guard = try self.headerGuard();
        defer self.alloc.free(guard);

        // Banner + include guard.
        try self.print(
            "/* Generated by zidl from {s}.idl — DO NOT EDIT */\n\n",
            .{self.opts.input_stem},
        );
        if (self.opts.pragma_once) {
            try self.write("#pragma once\n\n");
        } else {
            try self.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
        }
        try self.write("#include <stdint.h>\n");
        try self.write("#include <stdbool.h>\n");
        if (!self.opts.no_typesupport) {
            try self.write("#include \"zidl_cdr.h\"\n");
        }
        try self.write("\n");
        if (self.opts.extern_c) {
            try self.write("#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n");
        }

        // Pre-scan all items and emit sequence typedefs before any struct.
        try self.scanItemsForSeqs(spec.items);

        // Emit all declarations in source order.
        try self.emitItems(spec.items);

        // Closing guard.
        if (self.opts.extern_c) {
            try self.write("\n#ifdef __cplusplus\n}\n#endif\n");
        }
        if (!self.opts.pragma_once) {
            try self.print("#endif /* {s} */\n", .{guard});
        }
    }

    fn headerGuard(self: *Generator) ![]u8 {
        const prefix = self.opts.header_guard_prefix;
        const stem = self.opts.input_stem;
        const g = try std.fmt.allocPrint(self.alloc, "{s}{s}_H", .{ prefix, stem });
        for (g) |*c| {
            c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';
        }
        return g;
    }

    // ── Sequence pre-scan ─────────────────────────────────────────────────────

    fn scanItemsForSeqs(self: *Generator, items: []const ir.ModuleItem) !void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.scanItemsForSeqs(m.items),
                .type_decl => |td| try self.scanTypeDeclForSeqs(td),
                .const_ => {},
            }
        }
    }

    fn scanTypeDeclForSeqs(self: *Generator, td: ir.TypeDecl) !void {
        switch (td) {
            .struct_ => |s| {
                for (s.members) |m| {
                    try self.scanTypeRefForSeqs(m.type_ref);
                }
            },
            .union_ => |u| {
                try self.scanTypeRefForSeqs(u.discriminant);
                for (u.cases) |c| {
                    try self.scanTypeRefForSeqs(c.type_ref);
                }
            },
            .typedef => |t| try self.scanTypeRefForSeqs(t.type_ref),
            .exception => |e| {
                for (e.members) |m| {
                    try self.scanTypeRefForSeqs(m.type_ref);
                }
            },
            .interface => |iface| {
                for (iface.operations) |op| {
                    if (op.return_type) |rt| {
                        try self.scanTypeRefForSeqs(rt);
                    }
                    for (op.params) |p| {
                        try self.scanTypeRefForSeqs(p.type_ref);
                    }
                }
                for (iface.attributes) |a| {
                    try self.scanTypeRefForSeqs(a.type_ref);
                }
            },
            else => {},
        }
    }

    fn scanTypeRefForSeqs(self: *Generator, tr: ir.TypeRef) !void {
        switch (tr) {
            .sequence => |seq| {
                // Recurse first so the inner typedef is emitted before the outer.
                try self.scanTypeRefForSeqs(seq.element.*);
                try self.ensureSeqTypedef(seq.element.*);
            },
            .map => |m| {
                try self.scanTypeRefForSeqs(m.key.*);
                try self.scanTypeRefForSeqs(m.value.*);
            },
            else => {},
        }
    }

    /// Emit a sequence typedef for element type `elem` if not already done.
    fn ensureSeqTypedef(self: *Generator, elem: ir.TypeRef) !void {
        const key = try self.seqElemKey(elem);
        defer self.alloc.free(key);

        if (self.seq_emitted.get(key) != null) {
            return;
        }

        const key_dup = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_dup);
        try self.seq_emitted.put(self.alloc, key_dup, {});

        const seq_name = try std.fmt.allocPrint(self.alloc, "{s}_seq", .{key});
        defer self.alloc.free(seq_name);

        const elem_c = try self.typeRefToC(elem);
        defer self.alloc.free(elem_c);

        // In split mode, guard against duplicate definitions across headers.
        if (self.guarded_seqs) {
            const guard = try std.fmt.allocPrint(self.alloc, "{s}_DEFINED", .{seq_name});
            defer self.alloc.free(guard);
            for (guard) |*c| c.* = std.ascii.toUpper(c.*);
            try self.print("#ifndef {s}\n#define {s}\n", .{ guard, guard });
        }
        try self.print("typedef struct {{\n", .{});
        try self.print("    uint32_t _maximum;\n", .{});
        try self.print("    uint32_t _length;\n", .{});
        try self.print("    {s} *_buffer;\n", .{elem_c});
        try self.print("    bool _release;\n", .{});
        try self.print("}} {s};\n", .{seq_name});
        if (self.guarded_seqs) {
            try self.print("#endif\n", .{});
        }
        try self.write("\n");
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
        if (m.items.len == 0) {
            return;
        }
        try self.print("/* --- module {s} --- */\n\n", .{m.qualified_name});
        try self.emitItems(m.items);
        try self.print("/* --- end module {s} --- */\n\n", .{m.qualified_name});
    }

    fn emitTypeDecl(self: *Generator, td: ir.TypeDecl) !void {
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
        const c_name = try self.prefixedCName(s.qualified_name);
        defer self.alloc.free(c_name);

        try self.print("typedef struct {s}_s {{\n", .{c_name});
        if (s.base) |base| {
            const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
            defer self.alloc.free(base_c);
            try self.print("    {s} _base;\n", .{base_c});
        }
        for (s.members) |m| {
            try self.emitMemberDecl(m.type_ref, m.name, m.dimensions, "    ");
        }
        try self.print("}} {s};\n\n", .{c_name});

        if (!self.opts.no_typesupport) {
            try self.emitStructCdrProtos(c_name, s);
        }
    }

    fn emitStructCdrProtos(self: *Generator, c_name: []const u8, s: *const ir.Struct) !void {
        const has_key = structHasKeyC(s);
        try self.print("#define {s}_has_key {d}\n", .{ c_name, @intFromBool(has_key) });
        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ c_name, c_name });
        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ c_name, c_name });
        try self.print("int {s}_skip(ZidlCdrReader *_r);\n", .{c_name});
        if (has_key) {
            try self.print("int {s}_serialize_key(ZidlCdrWriter *_w, const {s} *_v);\n", .{ c_name, c_name });
            try self.print("int {s}_deserialize_key(ZidlCdrReader *_r, {s} *_v);\n", .{ c_name, c_name });
            try self.print("int {s}_compute_key_hash(const {s} *_v, uint8_t _hash[16]);\n", .{ c_name, c_name });
        }
        try self.write("\n");
    }

    // ── Union ─────────────────────────────────────────────────────────────────

    fn emitUnion(self: *Generator, u: *const ir.Union) !void {
        const c_name = try self.prefixedCName(u.qualified_name);
        defer self.alloc.free(c_name);

        const disc_c = try self.typeRefToC(u.discriminant);
        defer self.alloc.free(disc_c);

        try self.print("typedef struct {s}_s {{\n", .{c_name});
        try self.print("    {s}{s}_d;\n", .{ disc_c, ptrSep(disc_c) });
        try self.write("    union {\n");
        for (u.cases) |cas| {
            try self.emitMemberDecl(cas.type_ref, cas.name, cas.dimensions, "        ");
        }
        try self.write("    } _u;\n");
        try self.print("}} {s};\n\n", .{c_name});

        if (!self.opts.no_typesupport) {
            try self.emitUnionCdrProtos(c_name);
        }
    }

    fn emitUnionCdrProtos(self: *Generator, c_name: []const u8) !void {
        try self.print("#define {s}_has_key 0\n", .{c_name});
        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ c_name, c_name });
        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ c_name, c_name });
        try self.print("int {s}_skip(ZidlCdrReader *_r);\n", .{c_name});
        try self.write("\n");
    }

    // ── Enum ──────────────────────────────────────────────────────────────────

    fn emitEnum(self: *Generator, e: *const ir.Enum) !void {
        const c_name = try self.prefixedCName(e.qualified_name);
        defer self.alloc.free(c_name);

        try self.write("typedef enum {\n");
        for (e.enumerators, 0..) |en, i| {
            const comma = if (i + 1 < e.enumerators.len) "," else "";
            try self.print("    {s}_{s} = {d}{s}\n", .{ c_name, en.name, en.value, comma });
        }
        try self.print("}} {s};\n\n", .{c_name});
    }

    // ── Bitmask ───────────────────────────────────────────────────────────────

    fn emitBitmask(self: *Generator, bm: *const ir.Bitmask) !void {
        const c_name = try self.prefixedCName(bm.qualified_name);
        defer self.alloc.free(c_name);

        const storage = bitmaskStorageType(bm.annotations);
        try self.print("typedef {s} {s};\n", .{ storage, c_name });
        for (bm.bits, 0..) |bit, i| {
            try self.print(
                "#define {s}_{s} (({s})(1u << {d}))\n",
                .{ c_name, bit.name, c_name, i },
            );
        }
        try self.write("\n");
    }

    // ── Bitset ────────────────────────────────────────────────────────────────

    fn emitBitset(self: *Generator, bs: *const ir.Bitset) !void {
        const c_name = try self.prefixedCName(bs.qualified_name);
        defer self.alloc.free(c_name);

        try self.print("typedef struct {s}_s {{\n", .{c_name});
        for (bs.fields) |field| {
            const field_c_type = if (field.type_ref) |tr| blk: {
                const s = try self.typeRefToC(tr);
                break :blk s;
            } else try self.alloc.dupe(u8, "unsigned int");
            defer self.alloc.free(field_c_type);

            for (field.names) |fname| {
                try self.print("    {s}{s}{s} : {d};\n", .{ field_c_type, ptrSep(field_c_type), fname, field.bits });
            }
        }
        try self.print("}} {s};\n\n", .{c_name});
    }

    // ── Typedef ───────────────────────────────────────────────────────────────

    fn emitTypedef(self: *Generator, t: *const ir.Typedef) !void {
        const c_name = try self.prefixedCName(t.qualified_name);
        defer self.alloc.free(c_name);

        const c_type = try self.typeRefToC(t.type_ref);
        defer self.alloc.free(c_type);

        if (t.dimensions.len == 0) {
            try self.print("typedef {s}{s}{s};\n\n", .{ c_type, ptrSep(c_type), c_name });
        } else {
            // Array typedef: `typedef int32_t Matrix[2][4];`
            try self.print("typedef {s}{s}{s}", .{ c_type, ptrSep(c_type), c_name });
            for (t.dimensions) |d| {
                try self.print("[{d}]", .{d});
            }
            try self.write(";\n\n");
        }
    }

    // ── Native ────────────────────────────────────────────────────────────────

    fn emitNative(self: *Generator, n: *const ir.Native) !void {
        const c_name = try self.prefixedCName(n.qualified_name);
        defer self.alloc.free(c_name);

        try self.print("typedef void *{s}; /* @native */\n\n", .{c_name});
    }

    // ── Exception (struct-like in C) ──────────────────────────────────────────

    fn emitException(self: *Generator, e: *const ir.Exception) !void {
        const c_name = try self.prefixedCName(e.qualified_name);
        defer self.alloc.free(c_name);

        try self.print("/* IDL exception */\n", .{});
        try self.print("typedef struct {s}_s {{\n", .{c_name});
        for (e.members) |m| {
            try self.emitMemberDecl(m.type_ref, m.name, m.dimensions, "    ");
        }
        try self.print("}} {s};\n\n", .{c_name});
    }

    // ── Interface ─────────────────────────────────────────────────────────────

    fn emitInterface(self: *Generator, iface: *const ir.Interface) !void {
        const c_name = try self.prefixedCName(iface.qualified_name);
        defer self.alloc.free(c_name);

        if (!self.opts.generate_interfaces) {
            try self.print(
                "/* IDL interface {s} — vtable struct emitted with --generate-interfaces */\n\n",
                .{c_name},
            );
            return;
        }

        // Collect all operations and attributes (flattened through inheritance).
        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try self.collectInterfaceMembers(iface, &ops, &attrs);

        // ── Vtable struct ──────────────────────────────────────────────────
        try self.print("/* IDL interface: {s} */\n", .{c_name});
        try self.print("typedef struct {s}_Vtable {{\n", .{c_name});
        for (ops.items) |op| try self.emitVtableEntry(&op);
        for (attrs.items) |attr| try self.emitVtableAttrEntry(&attr);
        try self.write("    void (*deinit)(void *ptr);\n");
        try self.print("}} {s}_Vtable;\n\n", .{c_name});

        // ── Fat-pointer struct ─────────────────────────────────────────────
        try self.print("typedef struct {s} {{\n", .{c_name});
        try self.write("    void                *ptr;\n");
        try self.print("    const {s}_Vtable *vtable;\n", .{c_name});
        try self.print("}} {s};\n\n", .{c_name});

        // ── Inline forwarding functions ────────────────────────────────────
        for (ops.items) |op| try self.emitVtableFwdOp(c_name, &op);
        for (attrs.items) |attr| try self.emitVtableFwdAttr(c_name, &attr);
        try self.print("static inline void {s}_deinit({s} _self) {{\n", .{ c_name, c_name });
        try self.write("    _self.vtable->deinit(_self.ptr);\n}\n\n");

        // Constructor declaration for the Zig-backed vtable instance.
        try self.print("{s} {s}_zig_new(void *ptr);\n\n", .{ c_name, c_name });
    }

    /// Emit one vtable function-pointer field for an operation.
    fn emitVtableEntry(self: *Generator, op: *const ir.Operation) !void {
        const ret = if (op.return_type) |rt|
            try self.typeRefToC(rt)
        else
            try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret);

        try self.print("    {s}{s}(*{s})(void *ptr", .{ ret, ptrSep(ret), op.name });
        for (op.params) |p| {
            const pt = try self.vtableParamC(p);
            defer self.alloc.free(pt);
            try self.print(", {s}{s}{s}", .{ pt, ptrSep(pt), p.name });
        }
        try self.write(");\n");
    }

    /// Emit vtable function-pointer fields for an attribute.
    fn emitVtableAttrEntry(self: *Generator, attr: *const ir.Attribute) !void {
        const at = try self.typeRefToC(attr.type_ref);
        defer self.alloc.free(at);
        try self.print("    {s}{s}(*get_{s})(void *ptr);\n", .{ at, ptrSep(at), attr.name });
        if (!attr.readonly) {
            try self.print(
                "    void (*set_{s})(void *ptr, {s}{s}value);\n",
                .{ attr.name, at, ptrSep(at) },
            );
        }
    }

    /// Emit a static-inline forwarding function for an operation.
    fn emitVtableFwdOp(self: *Generator, c_name: []const u8, op: *const ir.Operation) !void {
        const ret = if (op.return_type) |rt|
            try self.typeRefToC(rt)
        else
            try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret);

        try self.print("static inline {s}{s}{s}_{s}({s} _self", .{
            ret, ptrSep(ret), c_name, op.name, c_name,
        });
        for (op.params) |p| {
            const pt = try self.vtableParamC(p);
            defer self.alloc.free(pt);
            try self.print(", {s}{s}{s}", .{ pt, ptrSep(pt), p.name });
        }
        try self.write(") {\n");
        if (op.return_type != null) {
            try self.print("    return _self.vtable->{s}(_self.ptr", .{op.name});
        } else {
            try self.print("    _self.vtable->{s}(_self.ptr", .{op.name});
        }
        for (op.params) |p| try self.print(", {s}", .{p.name});
        try self.write(");\n}\n\n");
    }

    /// Emit static-inline forwarding functions for an attribute.
    fn emitVtableFwdAttr(self: *Generator, c_name: []const u8, attr: *const ir.Attribute) !void {
        const at = try self.typeRefToC(attr.type_ref);
        defer self.alloc.free(at);
        try self.print(
            "static inline {s}{s}{s}_get_{s}({s} _self) {{\n    return _self.vtable->get_{s}(_self.ptr);\n}}\n\n",
            .{ at, ptrSep(at), c_name, attr.name, c_name, attr.name },
        );
        if (!attr.readonly) {
            try self.print(
                "static inline void {s}_set_{s}({s} _self, {s}{s}value) {{\n" ++
                    "    _self.vtable->set_{s}(_self.ptr, value);\n}}\n\n",
                .{ c_name, attr.name, c_name, at, ptrSep(at), attr.name },
            );
        }
    }

    /// C type for an operation parameter respecting in/out/inout mode.
    fn vtableParamC(self: *Generator, p: ir.Parameter) ![]u8 {
        const base = try self.typeRefToC(p.type_ref);
        defer self.alloc.free(base);
        return switch (p.mode) {
            .in_ => self.alloc.dupe(u8, base),
            .out, .inout => std.fmt.allocPrint(self.alloc, "{s} *", .{base}),
        };
    }

    /// Flatten inherited operations and attributes into `ops`/`attrs`.
    fn collectInterfaceMembers(
        self: *Generator,
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

    // ── Const ─────────────────────────────────────────────────────────────────

    fn emitConst(self: *Generator, c: *const ir.Const) !void {
        const c_name = try self.prefixedCName(c.qualified_name);
        defer self.alloc.free(c_name);

        const c_type = try self.typeRefToC(c.type_ref);
        defer self.alloc.free(c_type);

        switch (c.value) {
            .integer => |v| try self.print(
                "#define {s} (({s}){d})\n",
                .{ c_name, c_type, v },
            ),
            .float => |v| try self.print(
                "#define {s} (({s}){d})\n",
                .{ c_name, c_type, v },
            ),
            .boolean => |v| try self.print(
                "#define {s} ({s})\n",
                .{ c_name, if (v) "true" else "false" },
            ),
            .character => |ch| {
                if (std.ascii.isPrint(ch) and ch != '\'' and ch != '\\') {
                    try self.print("#define {s} ('{c}')\n", .{ c_name, ch });
                } else {
                    try self.print("#define {s} ((char)0x{X:0>2})\n", .{ c_name, ch });
                }
            },
            .string => |s| try self.print("#define {s} \"{s}\"\n", .{ c_name, s }),
            .wide_character => |wc| try self.print(
                "#define {s} ((uint16_t)0x{X:0>4})\n",
                .{ c_name, wc },
            ),
            .wide_string => try self.print(
                "/* {s}: wide string const — not directly representable in C */\n",
                .{c_name},
            ),
            .fixed_pt => |fp| try self.print(
                "/* {s}: fixed-point const {s} */\n",
                .{ c_name, fp },
            ),
        }
    }

    // ── Member declaration helper ─────────────────────────────────────────────

    /// Emit a single member/field declaration: `{indent}{c_type}[sep]{name}[dims];\n`.
    /// Uses `ptrSep` to omit the space when `c_type` ends with `'*'` so that
    /// pointer declarations follow the C convention `char *name` not `char * name`.
    ///
    /// Bounded strings emit a C array declarator: `char name[N+1]` / `uint16_t name[N+1]`
    /// rather than a pointer, per the OMG C language mapping (formal-99-07-35).
    fn emitMemberDecl(
        self: *Generator,
        type_ref: ir.TypeRef,
        name: []const u8,
        dims: []const u64,
        indent: []const u8,
    ) !void {
        // Bounded string / wstring → C fixed-length char array.
        switch (type_ref) {
            .string => |bound| if (bound) |n| {
                try self.print("{s}char {s}[{d}]", .{ indent, name, n + 1 });
                for (dims) |d| try self.print("[{d}]", .{d});
                try self.write(";\n");
                return;
            },
            .wstring => |bound| if (bound) |n| {
                try self.print("{s}uint16_t {s}[{d}]", .{ indent, name, n + 1 });
                for (dims) |d| try self.print("[{d}]", .{d});
                try self.write(";\n");
                return;
            },
            else => {},
        }

        const c_type = try self.typeRefToC(type_ref);
        defer self.alloc.free(c_type);

        try self.print("{s}{s}{s}{s}", .{ indent, c_type, ptrSep(c_type), name });
        for (dims) |d| {
            try self.print("[{d}]", .{d});
        }
        try self.write(";\n");
    }

    // ── Type-ref → C type string ──────────────────────────────────────────────

    /// Convert a `TypeRef` to its C type expression string.
    /// Caller owns the returned slice.
    fn typeRefToC(self: *Generator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCType(b)),
            .named => |td| self.prefixedCName(ir.typeDeclQualifiedName(td)),
            .sequence => |seq| self.seqTypeName(seq.element.*),
            .string => self.alloc.dupe(u8, "char *"),
            .wstring => self.alloc.dupe(u8, "uint16_t *"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => self.alloc.dupe(u8, "void *"),
        };
    }

    /// Return the deduplication key for a sequence element type.
    /// This is also the base for the sequence typedef name (`key + "_seq"`).
    /// Caller owns the returned slice.
    fn seqElemKey(self: *Generator, elem: ir.TypeRef) ![]u8 {
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

    /// Return the prefixed flat C name for a qualified IDL name.
    /// Combines `cNameFromQualified` with `opts.type_prefix`.
    /// Caller owns the returned slice.
    fn prefixedCName(self: *Generator, qname: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, self.opts.type_prefix);
    }

    /// Return the C typedef name for `sequence<elem>`.
    /// E.g. `sequence<long>` → `"int32_t_seq"`.
    /// Caller owns the returned slice.
    fn seqTypeName(self: *Generator, elem: ir.TypeRef) ![]u8 {
        const key = try self.seqElemKey(elem);
        defer self.alloc.free(key);
        return std.fmt.allocPrint(self.alloc, "{s}_seq", .{key});
    }
};

// ── Static helpers ────────────────────────────────────────────────────────────

/// Returns true if a union case is the `default:` arm.
/// EMHEADER LC value (0–3) for a fixed-size scalar type, or null for LC=4.
fn lcForCTypeRef(type_ref: ir.TypeRef, dimensions: []const u64) ?u2 {
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
fn memberIdAtC(m: ir.StructMember, idx: usize) u32 {
    return if (m.annotations.id) |id| id else @intCast(idx);
}

fn typeDeclHasKeyC(td: ir.TypeDecl) bool {
    return switch (td) {
        .struct_ => |s| structHasKeyC(s),
        else => false,
    };
}

fn structHasKeyC(s: *const ir.Struct) bool {
    if (s.base) |base| {
        if (typeDeclHasKeyC(base)) return true;
    }
    for (s.members) |m| {
        if (m.annotations.is_key) return true;
    }
    return false;
}

fn isDefaultUnionCase(cas: ir.UnionCase) bool {
    if (cas.labels.len == 0) return true;
    for (cas.labels) |lbl| {
        if (lbl == .default) return true;
    }
    return false;
}

fn bitsetTotalBits(bs: *const ir.Bitset) u32 {
    var total: u32 = 0;
    for (bs.fields) |field| {
        total += field.bits;
    }
    return total;
}

fn bitsetCStorageSuffix(bs: *const ir.Bitset) []const u8 {
    const total = bitsetTotalBits(bs);
    return if (total <= 8) "u8" else if (total <= 16) "u16" else if (total <= 32) "u32" else "u64";
}

fn bitsetCStorageType(bs: *const ir.Bitset) []const u8 {
    const total = bitsetTotalBits(bs);
    return if (total <= 8) "uint8_t" else if (total <= 16) "uint16_t" else if (total <= 32) "uint32_t" else "uint64_t";
}

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
        .any => "void *",
        .object => "void *",
        .value_base => "void *",
    };
}

/// A clean identifier fragment for a base type, used when constructing
/// sequence typedef names (e.g. `"int32_t"` → `"int32_t_seq"`).
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

fn bitmaskStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "uint8_t" else if (bound <= 16) "uint16_t" else if (bound <= 32) "uint32_t" else "uint64_t";
}

/// Return `""` when `c_type` ends with `'*'` (pointer type), otherwise `" "`.
/// Used to produce idiomatic C declarations: `char *name` not `char * name`.
fn ptrSep(c_type: []const u8) []const u8 {
    return if (c_type.len > 0 and c_type[c_type.len - 1] == '*') "" else " ";
}

// ── CDR source generation ─────────────────────────────────────────────────────

/// Generate the CDR serialization source file `<stem>_cdr.c` into `out`.
///
/// Each IDL struct produces:
///   - `<CName>_serialize`   — writes the struct to a ZidlCdrWriter
///   - `<CName>_deserialize` — reads the struct from a ZidlCdrReader
///   - `<CName>_serialize_key` — only when any member is annotated `@key`
///
/// Extensibility:
///   - `@final`    — no DHEADER framing
///   - `@appendable` — DHEADER via reserve_dheader_maybe / patch_dheader_maybe
///   - `@mutable`  — TODO comment emitted (requires EMHEADER; deferred)
///
/// The generated file `#include`s both the header and `zidl_cdr.h`.
pub fn generateCdrSource(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = CdrGenerator{
        .alloc = alloc,
        .opts = opts,
        .out = out,
    };
    try gen.emitSource(spec);
}

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

    fn emitSource(self: *CdrGenerator, spec: *const ir.Spec) !void {
        try self.print(
            "/* Generated by zidl from {s}.idl — DO NOT EDIT */\n\n",
            .{self.opts.input_stem},
        );
        try self.print("#include \"{s}.h\"\n", .{self.opts.input_stem});
        try self.write("#include \"zidl_cdr.h\"\n");
        try self.write("#include <stdlib.h>\n");
        try self.write("#include <string.h>\n\n");
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

    // ── Struct / Exception ────────────────────────────────────────────────────

    fn emitStructFns(self: *CdrGenerator, s: *const ir.Struct) !void {
        const c_name = try self.prefixedCName(s.qualified_name);
        defer self.alloc.free(c_name);

        const ext = s.annotations.extensibility;
        const appendable = (ext == .appendable or ext == .mutable);
        const mutable = (ext == .mutable);

        const has_key = structHasKeyC(s);

        // ── serialize ────────────────────────────────────────────────────────

        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, c_name });
        try self.writeI("int _rc;\n");
        if (mutable) {
            // @mutable: outer DHEADER + per-member EMHEADER framing.
            try self.writeI("size_t _dh;\n");
            try self.writeI("_rc = zidl_cdr_reserve_dheader(_w, &_dh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAtC(m, idx);
                const mu: u8 = if (m.annotations.must_understand) 1 else 0;
                if (m.annotations.is_optional) {
                    // Optional: wrap in an if + EMHEADER only when value is present.
                    try self.printI("if (_v->has_{s}) {{\n", .{m.name});
                    self.indent_depth += 1;
                    if (lcForCTypeRef(m.type_ref, m.dimensions)) |lc| {
                        try self.printI("_rc = zidl_cdr_write_emheader(_w, {d}, {d}, {d});\n", .{ member_id, mu, lc });
                        try self.writeI("if (_rc) return _rc;\n");
                        const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                        defer self.alloc.free(access);
                        if (m.dimensions.len > 0) {
                            try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                        } else {
                            try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                        }
                    } else {
                        try self.printI("size_t _em{d}; size_t _es{d};\n", .{ idx, idx });
                        try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, {d}, &_em{d});\n", .{ member_id, mu, idx });
                        try self.writeI("if (_rc) return _rc;\n");
                        try self.printI("_es{d} = _w->len;\n", .{idx});
                        const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                        defer self.alloc.free(access);
                        if (m.dimensions.len > 0) {
                            try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                        } else {
                            try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                        }
                        try self.printI("zidl_cdr_patch_emheader(_w, _em{d}, _es{d});\n", .{ idx, idx });
                    }
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                    continue;
                }
                const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                defer self.alloc.free(access);
                if (lcForCTypeRef(m.type_ref, m.dimensions)) |lc| {
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
                try self.printI("_rc = {s}_serialize(_w, &_v->_base);\n", .{base_c});
                try self.writeI("if (_rc) return _rc;\n");
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    try self.printI("/* TODO: @optional {s} */\n", .{m.name});
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

        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, c_name });
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
                const member_id: u32 = memberIdAtC(m, idx);
                try self.printI("case {d}: {{\n", .{member_id});
                self.indent_depth += 1;
                if (m.annotations.is_optional) {
                    // Optional: set presence flag then read value.
                    try self.printI("_v->has_{s} = 1;\n", .{m.name});
                    const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                    defer self.alloc.free(lval);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, m.name, lval);
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
                try self.printI("_rc = {s}_deserialize(_r, &_v->_base);\n", .{base_c});
                try self.writeI("if (_rc) return _rc;\n");
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    try self.printI("/* TODO: @optional {s} */\n", .{m.name});
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

        // ── serialize_key ─────────────────────────────────────────────────────

        if (has_key) {
            try self.print("int {s}_serialize_key(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, c_name });
            try self.writeI("int _rc;\n");
            if (s.base) |base| {
                if (typeDeclHasKeyC(base)) {
                    const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(base_c);
                    try self.printI("_rc = {s}_serialize_key(_w, &_v->_base);\n", .{base_c});
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

            try self.print("int {s}_deserialize_key(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, c_name });
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
                    const member_id: u32 = memberIdAtC(m, idx);
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
                    if (typeDeclHasKeyC(base)) {
                        try self.printI("_rc = {s}_deserialize_key(_r, &_v->_base);\n", .{base_c});
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

            try self.print("int {s}_compute_key_hash(const {s} *_v, uint8_t _hash[16]) {{\n", .{ c_name, c_name });
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

        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, c_name });
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

        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, c_name });
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

        const ext = u.annotations.extensibility;
        const appendable = (ext == .appendable or ext == .mutable);
        const mutable = (ext == .mutable);

        // ── serialize ────────────────────────────────────────────────────────

        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, c_name });
        if (mutable) {
            // @mutable union: DHEADER + EMHEADER(0)=discriminant + EMHEADER(N)=case value.
            try self.writeI("int _rc;\n");
            try self.writeI("size_t _dh;\n");
            try self.writeI("_rc = zidl_cdr_reserve_dheader(_w, &_dh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            // Discriminant: member_id=0
            if (lcForCTypeRef(u.discriminant, &.{})) |lc| {
                try self.printI("_rc = zidl_cdr_write_emheader(_w, 0, 0, {d});\n", .{lc});
                try self.writeI("if (_rc) return _rc;\n");
                try self.emitDiscWriteC(u.discriminant, "_v->_d");
            } else {
                try self.writeI("{ size_t _em_d = 0, _es_d = 0;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_reserve_emheader(_w, 0, 0, &_em_d);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("_es_d = _w->len;\n");
                try self.emitDiscWriteC(u.discriminant, "_v->_d");
                try self.writeI("zidl_cdr_patch_emheader(_w, _em_d, _es_d); }\n");
                self.indent_depth -= 1;
            }
            // Case value: member_id = annotation.id ?? (case_index + 1)
            try self.writeI("switch (_v->_d) {\n");
            self.indent_depth += 1;
            var has_default_m = false;
            for (u.cases, 0..) |cas, cas_idx| {
                if (isDefaultUnionCase(cas)) {
                    has_default_m = true;
                    continue;
                }
                const case_member_id: u32 = if (cas.annotations.id) |id| id else @intCast(cas_idx + 1);
                try self.emitUnionCaseLabelLinesC(u.discriminant, cas);
                self.indent_depth += 1;
                const access = try std.fmt.allocPrint(self.alloc, "_v->_u.{s}", .{cas.name});
                defer self.alloc.free(access);
                if (lcForCTypeRef(cas.type_ref, cas.dimensions)) |lc| {
                    try self.printI("_rc = zidl_cdr_write_emheader(_w, {d}, 0, {d});\n", .{ case_member_id, lc });
                    try self.writeI("if (_rc) return _rc;\n");
                    if (cas.dimensions.len > 0) {
                        try self.emitWriteArray(cas.type_ref, access, cas.dimensions, 0);
                    } else {
                        try self.emitWriteForTypeRef(cas.type_ref, cas.name, access);
                    }
                } else {
                    try self.printI("{{ size_t _em_c{d} = 0, _es_c{d} = 0;\n", .{ cas_idx, cas_idx });
                    self.indent_depth += 1;
                    try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, 0, &_em_c{d});\n", .{ case_member_id, cas_idx });
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("_es_c{d} = _w->len;\n", .{cas_idx});
                    if (cas.dimensions.len > 0) {
                        try self.emitWriteArray(cas.type_ref, access, cas.dimensions, 0);
                    } else {
                        try self.emitWriteForTypeRef(cas.type_ref, cas.name, access);
                    }
                    try self.printI("zidl_cdr_patch_emheader(_w, _em_c{d}, _es_c{d}); }}\n", .{ cas_idx, cas_idx });
                    self.indent_depth -= 1;
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
            try self.emitDiscWriteC(u.discriminant, "_v->_d");
            try self.writeI("switch (_v->_d) {\n");
            self.indent_depth += 1;
            var has_default = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) has_default = true;
                try self.emitUnionCaseLabelLinesC(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const access = try std.fmt.allocPrint(self.alloc, "_v->_u.{s}", .{cas.name});
                    defer self.alloc.free(access);
                    try self.emitWriteArray(cas.type_ref, access, cas.dimensions, 0);
                } else {
                    const access = try std.fmt.allocPrint(self.alloc, "_v->_u.{s}", .{cas.name});
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

        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, c_name });
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
            try self.emitDiscReadC(u.discriminant, "_v->_d");
            self.indent_depth -= 1;
            try self.writeI("} else {\n");
            self.indent_depth += 1;
            try self.writeI("switch (_v->_d) {\n");
            self.indent_depth += 1;
            var has_default_d = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) {
                    has_default_d = true;
                    continue;
                }
                try self.emitUnionCaseLabelLinesC(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const lval = try std.fmt.allocPrint(self.alloc, "_v->_u.{s}", .{cas.name});
                    defer self.alloc.free(lval);
                    try self.emitReadArray(cas.type_ref, cas.name, lval, cas.dimensions, 0);
                } else {
                    const lval = try std.fmt.allocPrint(self.alloc, "_v->_u.{s}", .{cas.name});
                    defer self.alloc.free(lval);
                    try self.emitReadForTypeRef(cas.type_ref, cas.name, lval);
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
            try self.emitDiscReadC(u.discriminant, "_v->_d");
            try self.writeI("switch (_v->_d) {\n");
            self.indent_depth += 1;
            var has_default = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) has_default = true;
                try self.emitUnionCaseLabelLinesC(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const lval = try std.fmt.allocPrint(self.alloc, "_v->_u.{s}", .{cas.name});
                    defer self.alloc.free(lval);
                    try self.emitReadArray(cas.type_ref, cas.name, lval, cas.dimensions, 0);
                } else {
                    const lval = try std.fmt.allocPrint(self.alloc, "_v->_u.{s}", .{cas.name});
                    defer self.alloc.free(lval);
                    try self.emitReadForTypeRef(cas.type_ref, cas.name, lval);
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
            const disc_c = try self.elemCType(u.discriminant);
            defer self.alloc.free(disc_c);
            try self.printI("{s} _d;\n", .{disc_c});
            try self.emitDiscReadC(u.discriminant, "_d");
            try self.writeI("switch (_d) {\n");
            self.indent_depth += 1;
            var has_default = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) has_default = true;
                try self.emitUnionCaseLabelLinesC(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    try self.emitSkipArray(cas.type_ref, cas.dimensions, 0);
                } else {
                    try self.emitSkipForTypeRef(cas.type_ref);
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
        }
        try self.write("}\n\n");
    }

    /// Emit CDR write statement(s) for the union discriminant.
    fn emitDiscWriteC(self: *CdrGenerator, disc: ir.TypeRef, access: []const u8) anyerror!void {
        switch (disc) {
            .base => |b| {
                const fn_name = baseCWriteFn(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported discriminant type write */\n", .{});
                } else {
                    try self.printI("_rc = {s}(_w, {s});\n", .{ fn_name, access });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    try self.printI("_rc = zidl_cdr_write_{s}(_w, ({s}){s});\n", .{ suffix, ctype, access });
                    try self.writeI("if (_rc) return _rc;\n");
                },
                else => try self.printI("/* TODO: unsupported discriminant write */\n", .{}),
            },
            else => try self.printI("/* TODO: unsupported discriminant write */\n", .{}),
        }
    }

    /// Emit CDR read statement(s) for the union discriminant into `lval`.
    fn emitDiscReadC(self: *CdrGenerator, disc: ir.TypeRef, lval: []const u8) anyerror!void {
        switch (disc) {
            .base => |b| {
                const fn_name = baseCReadFn(b);
                const c_type = baseToCType(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported discriminant type read */\n", .{});
                } else {
                    try self.printI("{{ {s} _d; _rc = {s}(_r, &_d); if (_rc) return _rc; {s} = ({s})_d; }}\n", .{ c_type, fn_name, lval, c_type });
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    const enum_c = try self.prefixedCName(e.qualified_name);
                    defer self.alloc.free(enum_c);
                    try self.printI("{{ {s} _d_raw; _rc = zidl_cdr_read_{s}(_r, &_d_raw); if (_rc) return _rc; {s} = ({s})_d_raw; }}\n", .{ ctype, suffix, lval, enum_c });
                },
                else => try self.printI("/* TODO: unsupported discriminant read */\n", .{}),
            },
            else => try self.printI("/* TODO: unsupported discriminant read */\n", .{}),
        }
    }

    /// Emit `case X:` / `default:` label lines for a union case.
    fn emitUnionCaseLabelLinesC(self: *CdrGenerator, disc: ir.TypeRef, cas: ir.UnionCase) anyerror!void {
        if (cas.labels.len == 0) {
            try self.writeI("default:\n");
            return;
        }
        for (cas.labels) |lbl| {
            switch (lbl) {
                .default => try self.writeI("default:\n"),
                .integer => |v| try self.printI("case {d}:\n", .{v}),
                .boolean => |b| try self.printI("case {d}:\n", .{@intFromBool(b)}),
                .enumerator => |name| switch (disc) {
                    .named => |td| switch (td) {
                        .enum_ => |e| {
                            const enum_c = try self.prefixedCName(e.qualified_name);
                            defer self.alloc.free(enum_c);
                            try self.printI("case {s}_{s}:\n", .{ enum_c, name });
                        },
                        else => try self.printI("case {s}:\n", .{name}),
                    },
                    else => try self.printI("case {s}:\n", .{name}),
                },
            }
        }
    }

    // ── Write helpers ─────────────────────────────────────────────────────────

    /// Emit a CDR write statement for `access` of type `tr`.
    /// `field_name` is only used for comments.
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
                if (bound != null) {
                    try self.printI("_rc = zidl_cdr_write_string(_w, {s}, (uint32_t)strlen({s}));\n", .{ access, access });
                } else {
                    try self.printI("_rc = zidl_cdr_write_string(_w, {s} ? {s} : \"\", {s} ? (uint32_t)strlen({s}) : 0u);\n", .{ access, access, access, access });
                }
                try self.writeI("if (_rc) return _rc;\n");
            },
            .wstring => |bound| {
                if (bound != null) {
                    // Bounded wstring<N> → uint16_t[N+1]: compute length, write directly.
                    try self.printI("{{ uint32_t _wl = 0; while ({s}[_wl]) _wl++; _rc = zidl_cdr_write_wstring(_w, {s}, _wl); if (_rc) return _rc; }}\n", .{ access, access });
                } else {
                    // Unbounded wstring → uint16_t * (may be null): null-safe length count.
                    try self.printI("{{ uint32_t _wl = 0; const uint16_t *_ws = {s}; while (_ws && _ws[_wl]) _wl++; _rc = zidl_cdr_write_wstring(_w, _ws, _wl); if (_rc) return _rc; }}\n", .{access});
                }
            },
            .sequence => |seq| {
                _ = seq.bound;
                try self.printI("_rc = zidl_cdr_write_u32(_w, {s}._length);\n", .{access});
                try self.writeI("if (_rc) return _rc;\n");
                try self.printI("{{ uint32_t _si; for (_si = 0; _si < {s}._length; _si++) {{\n", .{access});
                self.indent_depth += 1;
                const elem_access = try std.fmt.allocPrint(self.alloc, "{s}._buffer[_si]", .{access});
                defer self.alloc.free(elem_access);
                try self.emitWriteForTypeRef(seq.element.*, field_name, elem_access);
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("}\n");
            },
            .named => |td| {
                try self.emitWriteNamed(td, field_name, access);
            },
            .fixed_pt => |fp| {
                try self.printI("_rc = zidl_cdr_write_fixed(_w, {d}, {d}, {s});\n", .{ fp.digits, fp.scale, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .map => {
                try self.printI("/* TODO: map write for {s} */\n", .{field_name});
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
                try self.printI("_rc = zidl_cdr_write_{s}(_w, ({s}){s});\n", .{ suffix, ctype, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .bitmask => |bm| {
                const ctype = bitmaskStorageType(bm.annotations);
                const suffix = enumCStorageType(bm.annotations);
                try self.printI("_rc = zidl_cdr_write_{s}(_w, ({s}){s});\n", .{ suffix, ctype, access });
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

    // ── Read helpers ──────────────────────────────────────────────────────────

    fn emitReadMember(self: *CdrGenerator, m: ir.StructMember) anyerror!void {
        if (m.annotations.is_optional) {
            try self.printI("/* TODO: @optional key member {s} */\n", .{m.name});
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
            try self.printI("_v->has_{s} = 1;\n", .{m.name});
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
            try self.writeI("{ bool _present;\n");
            self.indent_depth += 1;
            try self.writeI("_rc = zidl_cdr_read_bool(_r, &_present);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("if (_present) {\n");
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
                    const suffix = bitsetCStorageSuffix(bs);
                    const ctype = bitsetCStorageType(bs);
                    try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
                },
                else => try self.writeI("return ZIDL_CDR_INVALID;\n"),
            },
            .fixed_pt => |fp| {
                try self.printI("{{ double _tmp; _rc = zidl_cdr_read_fixed(_r, {d}, {d}, &_tmp); if (_rc) return _rc; }}\n", .{ fp.digits, fp.scale });
            },
        }
    }

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
                if (bound) |n| {
                    // Bounded string → char[N+1]; zero-copy + memcpy
                    try self.writeI("{ const char *_sp; uint32_t _sl;\n");
                    self.indent_depth += 1;
                    try self.writeI("_rc = zidl_cdr_read_string_zerocopy(_r, &_sp, &_sl);\n");
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("if (_sl > {d}u) return ZIDL_CDR_INVALID;\n", .{n});
                    try self.printI("memcpy({s}, _sp, _sl);\n", .{lval});
                    try self.printI("{s}[_sl] = '\\0';\n", .{lval});
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                } else {
                    // Unbounded string → char *; allocating read
                    try self.printI("_rc = zidl_cdr_read_string(_r, &{s});\n", .{lval});
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .wstring => |bound| {
                if (bound) |n| {
                    // Bounded wstring<N> → uint16_t[N+1]: alloc read, bound-check, memcpy, free.
                    try self.printI("{{ uint16_t *_wp; uint32_t _wl; _rc = zidl_cdr_read_wstring(_r, &_wp, &_wl); if (_rc) return _rc; if (_wl > {d}u) {{ free(_wp); return ZIDL_CDR_INVALID; }} memcpy({s}, _wp, _wl * sizeof(uint16_t)); {s}[_wl] = 0; free(_wp); }}\n", .{ n, lval, lval });
                } else {
                    // Unbounded wstring → uint16_t * (NUL-terminated, caller frees).
                    try self.printI("{{ uint32_t _wl; _rc = zidl_cdr_read_wstring(_r, &{s}, &_wl); if (_rc) return _rc; }}\n", .{lval});
                }
            },
            .sequence => |seq| {
                _ = seq.bound;
                try self.writeI("{ uint32_t _sl;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_u32(_r, &_sl);\n");
                try self.writeI("if (_rc) return _rc;\n");
                const elem_c = try self.elemCType(seq.element.*);
                defer self.alloc.free(elem_c);
                try self.printI("{s}._length = _sl;\n", .{lval});
                try self.printI("{s}._maximum = _sl;\n", .{lval});
                try self.printI("{s}._release = true;\n", .{lval});
                try self.printI("{s}._buffer = ({s} *)malloc(_sl * sizeof({s}));\n", .{ lval, elem_c, elem_c });
                try self.printI("if (!{s}._buffer && _sl > 0) return ZIDL_CDR_OVERFLOW;\n", .{lval});
                try self.writeI("{ uint32_t _si; for (_si = 0; _si < _sl; _si++) {\n");
                self.indent_depth += 1;
                const elem_lval = try std.fmt.allocPrint(self.alloc, "{s}._buffer[_si]", .{lval});
                defer self.alloc.free(elem_lval);
                try self.emitReadForTypeRef(seq.element.*, field_name, elem_lval);
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .named => |td| {
                try self.emitReadNamed(td, field_name, lval);
            },
            .fixed_pt => |fp| {
                try self.printI("_rc = zidl_cdr_read_fixed(_r, {d}, {d}, &{s});\n", .{ fp.digits, fp.scale, lval });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .map => {
                try self.printI("/* TODO: map read for {s} */\n", .{field_name});
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
                try self.printI("{{ {s} _ev; _rc = zidl_cdr_read_{s}(_r, &_ev); if (_rc) return _rc; {s} = _ev; }}\n", .{ ctype, suffix, lval });
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

    fn prefixedCName(self: *CdrGenerator, qname: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, self.opts.type_prefix);
    }

    /// Return the C type string for a sequence element (used in malloc cast).
    /// Caller owns the result.
    fn elemCType(self: *CdrGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCType(b)),
            .named => |td| self.prefixedCName(ir.typeDeclQualifiedName(td)),
            .string => self.alloc.dupe(u8, "char *"),
            .wstring => self.alloc.dupe(u8, "uint16_t *"),
            .sequence => self.alloc.dupe(u8, "void *"), // nested seq — use _seq typedef
            else => self.alloc.dupe(u8, "void *"),
        };
    }
};

// ── Interface source generation ────────────────────────────────────────────────

/// Generate the interface binding source file `<stem>_iface.c` into `out`.
///
/// For each IDL `interface` declaration, emits:
///   - `extern` declarations for Zig DDS runtime function exports
///     (`zidl_<CName>_<op>`, `zidl_<CName>_get_<attr>`, etc.)
///   - A `static const <CName>_Vtable <CName>_zig_vtable_` initialiser
///   - `<CName> <CName>_zig_new(void *ptr)` constructor definition
///
/// The generated file `#include`s the corresponding header, which contains the
/// vtable struct and fat-pointer struct declarations.
pub fn generateIfaceSource(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = IfaceGenerator{
        .alloc = alloc,
        .opts = opts,
        .out = out,
    };
    try gen.emitSource(spec);
}

const IfaceGenerator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),

    fn write(self: *IfaceGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *IfaceGenerator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    fn emitSource(self: *IfaceGenerator, spec: *const ir.Spec) !void {
        try self.print(
            "/* Generated by zidl from {s}.idl — DO NOT EDIT */\n\n",
            .{self.opts.input_stem},
        );
        try self.print("#include \"{s}.h\"\n", .{self.opts.input_stem});
        try self.write("#include <stddef.h>\n\n");
        try self.emitItems(spec.items);
    }

    fn emitItems(self: *IfaceGenerator, items: []const ir.ModuleItem) anyerror!void {
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

    fn emitIfaceImpl(self: *IfaceGenerator, iface: *const ir.Interface) !void {
        const c_name = try self.prefixedCName(iface.qualified_name);
        defer self.alloc.free(c_name);

        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try self.collectInterfaceMembers(iface, &ops, &attrs);

        try self.print("/* ── interface {s} ── */\n\n", .{c_name});

        // Extern declarations for Zig DDS runtime exports.
        try self.write("/* Zig DDS runtime exports (provided at link time). */\n");
        for (ops.items) |op| try self.emitZigExtern(c_name, &op);
        for (attrs.items) |attr| try self.emitZigAttrExterns(c_name, &attr);
        try self.print("extern void zidl_{s}_deinit(void *ptr);\n\n", .{c_name});

        // Static vtable initialiser.
        try self.print("static const {s}_Vtable {s}_zig_vtable_ = {{\n", .{ c_name, c_name });
        for (ops.items) |op| {
            try self.print("    .{s} = zidl_{s}_{s},\n", .{ op.name, c_name, op.name });
        }
        for (attrs.items) |attr| {
            try self.print("    .get_{s} = zidl_{s}_get_{s},\n", .{ attr.name, c_name, attr.name });
            if (!attr.readonly) {
                try self.print("    .set_{s} = zidl_{s}_set_{s},\n", .{ attr.name, c_name, attr.name });
            }
        }
        try self.print("    .deinit = zidl_{s}_deinit,\n", .{c_name});
        try self.print("}};\n\n", .{});

        // Constructor definition.
        try self.print("{s} {s}_zig_new(void *ptr) {{\n", .{ c_name, c_name });
        try self.print(
            "    return ({s}){{ .ptr = ptr, .vtable = &{s}_zig_vtable_ }};\n",
            .{ c_name, c_name },
        );
        try self.write("}\n\n");
    }

    fn emitZigExtern(self: *IfaceGenerator, c_name: []const u8, op: *const ir.Operation) !void {
        const ret = if (op.return_type) |rt|
            try self.typeRefToC(rt)
        else
            try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret);

        try self.print("extern {s}{s}zidl_{s}_{s}(void *ptr", .{ ret, ptrSep(ret), c_name, op.name });
        for (op.params) |p| {
            const pt = try self.vtableParamC(p);
            defer self.alloc.free(pt);
            try self.print(", {s}{s}{s}", .{ pt, ptrSep(pt), p.name });
        }
        try self.write(");\n");
    }

    fn emitZigAttrExterns(self: *IfaceGenerator, c_name: []const u8, attr: *const ir.Attribute) !void {
        const at = try self.typeRefToC(attr.type_ref);
        defer self.alloc.free(at);
        try self.print(
            "extern {s}{s}zidl_{s}_get_{s}(void *ptr);\n",
            .{ at, ptrSep(at), c_name, attr.name },
        );
        if (!attr.readonly) {
            try self.print(
                "extern void zidl_{s}_set_{s}(void *ptr, {s}{s}value);\n",
                .{ c_name, attr.name, at, ptrSep(at) },
            );
        }
    }

    fn collectInterfaceMembers(
        self: *IfaceGenerator,
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

    fn typeRefToC(self: *IfaceGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCType(b)),
            .named => |td| self.prefixedCName(ir.typeDeclQualifiedName(td)),
            .sequence => |seq| self.seqTypeName(seq.element.*),
            .string => self.alloc.dupe(u8, "char *"),
            .wstring => self.alloc.dupe(u8, "uint16_t *"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => self.alloc.dupe(u8, "void *"),
        };
    }

    fn seqElemKey(self: *IfaceGenerator, elem: ir.TypeRef) ![]u8 {
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

    fn seqTypeName(self: *IfaceGenerator, elem: ir.TypeRef) ![]u8 {
        const key = try self.seqElemKey(elem);
        defer self.alloc.free(key);
        return std.fmt.allocPrint(self.alloc, "{s}_seq", .{key});
    }

    fn prefixedCName(self: *IfaceGenerator, qname: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, self.opts.type_prefix);
    }

    fn vtableParamC(self: *IfaceGenerator, p: ir.Parameter) ![]u8 {
        const base = try self.typeRefToC(p.type_ref);
        defer self.alloc.free(base);
        return switch (p.mode) {
            .in_ => self.alloc.dupe(u8, base),
            .out, .inout => std.fmt.allocPrint(self.alloc, "{s} *", .{base}),
        };
    }
};

/// Map IDL base type to C CDR write function name.
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

/// Map IDL base type to C CDR read function name.
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

/// Map enum bit_bound to the C CDR function suffix (e.g. "u32").
fn enumCStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "u8" else if (bound <= 16) "u16" else if (bound <= 32) "u32" else "u64";
}

/// Map enum bit_bound to the C type name used in casts (e.g. "uint32_t").
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

/// Collect all named TypeDecls from `items` recursively, in source order.
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

/// Collect named type stems that `td` directly depends on (for `#include`).
/// Results are stored in `out_set` (key = stem such as `"Foo_Bar"`; owned by caller).
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

/// Generate a single-type header into `out`.
fn generateTypeHeader(
    alloc: std.mem.Allocator,
    td: ir.TypeDecl,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    const qname = ir.typeDeclQualifiedName(td);
    const type_stem = try interface.cNameFromQualified(alloc, qname);
    defer alloc.free(type_stem);

    // Collect header dependencies.
    var deps = std.StringHashMapUnmanaged(void).empty;
    defer {
        var it = deps.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        deps.deinit(alloc);
    }
    try collectHeaderDeps(alloc, td, type_stem, &deps);

    // Include guard: use prefix + type stem.
    const prefix = opts.header_guard_prefix;
    const guard = try std.fmt.allocPrint(alloc, "{s}{s}_H", .{ prefix, type_stem });
    defer alloc.free(guard);
    for (guard) |*c| c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';

    var gen = Generator{
        .alloc = alloc,
        .opts = opts,
        .out = out,
        .seq_emitted = .empty,
        .guarded_seqs = true,
    };
    defer {
        var it = gen.seq_emitted.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        gen.seq_emitted.deinit(alloc);
    }

    try gen.print("/* Generated by zidl from {s}.idl — DO NOT EDIT */\n\n", .{opts.input_stem});
    if (opts.pragma_once) {
        try gen.write("#pragma once\n\n");
    } else {
        try gen.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
    }
    try gen.write("#include <stdint.h>\n");
    try gen.write("#include <stdbool.h>\n");
    if (!opts.no_typesupport) {
        switch (td) {
            .struct_ => try gen.write("#include \"zidl_cdr.h\"\n"),
            else => {},
        }
    }

    // Include headers for dependencies.
    var it = deps.keyIterator();
    while (it.next()) |k| {
        try gen.print("#include \"{s}.h\"\n", .{k.*});
    }
    try gen.write("\n");
    if (opts.extern_c) {
        try gen.write("#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n");
    }

    // Sequence typedefs for this type.
    try gen.scanTypeDeclForSeqs(td);

    // Type definition (emitStruct already emits CDR prototypes when typesupport is on).
    try gen.emitTypeDecl(td);

    if (opts.extern_c) {
        try gen.write("\n#ifdef __cplusplus\n}\n#endif\n");
    }
    if (!opts.pragma_once) {
        try gen.print("#endif /* {s} */\n", .{guard});
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
    try gen.print("/* Generated by zidl from {s}.idl — DO NOT EDIT */\n\n", .{opts.input_stem});
    try gen.print("#include \"{s}.h\"\n", .{type_stem});
    try gen.write("#include \"zidl_cdr.h\"\n");
    try gen.write("#include <stdlib.h>\n");
    try gen.write("#include <string.h>\n\n");
    try gen.emitTypeDecl(td);
}

/// Generate the aggregate `<stem>_all.h` that includes every per-type header.
fn generateAggregateHeader(
    alloc: std.mem.Allocator,
    type_decls: []const ir.TypeDecl,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    const prefix = opts.header_guard_prefix;
    const guard = try std.fmt.allocPrint(alloc, "{s}{s}_ALL_H", .{ prefix, opts.input_stem });
    defer alloc.free(guard);
    for (guard) |*c| c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';

    var gen = Generator{
        .alloc = alloc,
        .opts = opts,
        .out = out,
        .seq_emitted = .empty,
    };
    defer {
        var it = gen.seq_emitted.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        gen.seq_emitted.deinit(alloc);
    }

    try gen.print("/* Generated by zidl from {s}.idl — DO NOT EDIT */\n\n", .{opts.input_stem});
    if (opts.pragma_once) {
        try gen.write("#pragma once\n\n");
    } else {
        try gen.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
    }
    for (type_decls) |td| {
        const qname = ir.typeDeclQualifiedName(td);
        const type_stem = try interface.cNameFromQualified(alloc, qname);
        defer alloc.free(type_stem);
        try gen.print("#include \"{s}.h\"\n", .{type_stem});
    }
    if (opts.pragma_once) {
        try gen.write("\n");
    } else {
        try gen.print("\n#endif /* {s} */\n", .{guard});
    }
}

/// Split-file mode entry point: one header+CDR pair per named type, plus aggregate.
pub fn generateSplitFiles(
    alloc: std.mem.Allocator,
    io: std.Io,
    spec: *const ir.Spec,
    opts: interface.Options,
) !void {
    // Collect all named type declarations in source order.
    var type_decls = std.ArrayListUnmanaged(ir.TypeDecl).empty;
    defer type_decls.deinit(alloc);
    try collectTypeDeclsFlat(alloc, spec.items, &type_decls);

    // Generate per-type header and (for structs/exceptions) CDR source.
    for (type_decls.items) |td| {
        const qname = ir.typeDeclQualifiedName(td);
        const type_stem = try interface.cNameFromQualified(alloc, qname);
        defer alloc.free(type_stem);

        // Header.
        var h_content = std.ArrayList(u8).empty;
        defer h_content.deinit(alloc);
        try generateTypeHeader(alloc, td, opts, &h_content);
        const h_filename = try std.fmt.allocPrint(alloc, "{s}.h", .{type_stem});
        defer alloc.free(h_filename);
        try writeOutputFile(alloc, io, opts, h_filename, h_content.items);

        // CDR source (structs and exceptions only).
        if (!opts.no_typesupport) {
            switch (td) {
                .struct_, .exception => {
                    var c_content = std.ArrayList(u8).empty;
                    defer c_content.deinit(alloc);
                    try generateTypeCdrSource(alloc, td, opts, type_stem, &c_content);
                    const c_filename = try std.fmt.allocPrint(alloc, "{s}_cdr.c", .{type_stem});
                    defer alloc.free(c_filename);
                    try writeOutputFile(alloc, io, opts, c_filename, c_content.items);
                },
                else => {},
            }
        }
    }

    // Aggregate header.
    var all_content = std.ArrayList(u8).empty;
    defer all_content.deinit(alloc);
    try generateAggregateHeader(alloc, type_decls.items, opts, &all_content);
    const all_filename = try std.fmt.allocPrint(alloc, "{s}_all.h", .{opts.input_stem});
    defer alloc.free(all_filename);
    try writeOutputFile(alloc, io, opts, all_filename, all_content.items);

    // Interface vtable source (same as single-file mode).
    if (opts.generate_interfaces) {
        var iface_content = std.ArrayList(u8).empty;
        defer iface_content.deinit(alloc);
        try generateIfaceSource(alloc, spec, opts, &iface_content);
        const if_filename = try std.fmt.allocPrint(alloc, "{s}_iface.c", .{opts.input_stem});
        defer alloc.free(if_filename);
        try writeOutputFile(alloc, io, opts, if_filename, iface_content.items);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

/// Parse `source`, analyse, build IR, generate C header into a returned buffer.
/// Caller must call `.deinit(testing.allocator)` on the returned ArrayList.
fn testGen(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    return testGenFullOpts(source, stem, .{});
}

fn testGenFullOpts(source: []const u8, stem: []const u8, extra: struct {
    type_prefix: []const u8 = "",
    generate_interfaces: bool = false,
    pragma_once: bool = false,
    extern_c: bool = false,
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
        .extern_c = extra.extern_c,
    };
    try generateHeader(alloc, &ir_spec, opts, &out);

    return out;
}

/// Return true if `haystack` contains `needle`.
fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

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

test "c_backend split: enum gets own header with guard" {
    var out = try testGenTypeHeader("enum Color { RED, GREEN, BLUE };", "color", 0);
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#ifndef COLOR_H"));
    try testing.expect(has(s, "#define COLOR_H"));
    try testing.expect(has(s, "typedef enum {"));
    try testing.expect(has(s, "Color_RED = 0"));
    try testing.expect(has(s, "#endif /* COLOR_H */"));
    try testing.expect(!has(s, "zidl_cdr.h"));
}

test "c_backend split: struct includes deps and has seq guard" {
    var out = try testGenTypeHeader(
        \\enum Color { RED };
        \\struct Foo { Color c; sequence<long> items; };
    , "types", 1);
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include \"Color.h\""));
    try testing.expect(has(s, "#ifndef INT32_T_SEQ_DEFINED"));
    try testing.expect(has(s, "#define INT32_T_SEQ_DEFINED"));
    try testing.expect(has(s, "} int32_t_seq;"));
    try testing.expect(has(s, "#endif"));
    try testing.expect(has(s, "#include \"zidl_cdr.h\""));
}

test "c_backend split: aggregate includes all types" {
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
    try testing.expect(has(s, "#ifndef TYPES_ALL_H"));
    try testing.expect(has(s, "#include \"Color.h\""));
    try testing.expect(has(s, "#include \"Foo.h\""));
}

test "c_backend: header guard and includes" {
    var out = try testGen("struct Dummy { long x; };", "my_types");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "ifndef MY_TYPES_H"));
    try testing.expect(has(s, "define MY_TYPES_H"));
    try testing.expect(has(s, "#include <stdint.h>"));
    try testing.expect(has(s, "#include <stdbool.h>"));
    try testing.expect(has(s, "endif"));
}

test "c_backend: header guard prefix" {
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
    try testing.expect(has(out.items, "ifndef MYNS_TYPES_H"));
}

test "c_backend: simple struct" {
    var out = try testGen("struct Point { long x; long y; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "typedef struct Point_s {"));
    try testing.expect(has(s, "    int32_t x;"));
    try testing.expect(has(s, "    int32_t y;"));
    try testing.expect(has(s, "} Point;"));
}

test "c_backend: struct in module" {
    var out = try testGen(
        \\module Sensor { struct Reading { double value; }; };
    , "sensor");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "typedef struct Sensor_Reading_s {"));
    try testing.expect(has(s, "    double value;"));
    try testing.expect(has(s, "} Sensor_Reading;"));
}

test "c_backend: nested module" {
    var out = try testGen(
        \\module A { module B { struct C { long x; }; }; };
    , "nested");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "typedef struct A_B_C_s {"));
    try testing.expect(has(s, "} A_B_C;"));
}

test "c_backend: enum" {
    var out = try testGen("enum Color { RED, GREEN, BLUE };", "color");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "typedef enum {"));
    try testing.expect(has(s, "Color_RED = 0"));
    try testing.expect(has(s, "Color_GREEN = 1"));
    try testing.expect(has(s, "Color_BLUE = 2"));
    try testing.expect(has(s, "} Color;"));
}

test "c_backend: union" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "typedef struct Var_s {"));
    try testing.expect(has(s, "int32_t _d;"));
    try testing.expect(has(s, "union {"));
    try testing.expect(has(s, "int32_t i;"));
    try testing.expect(has(s, "char *s;"));
    try testing.expect(has(s, "} _u;"));
    try testing.expect(has(s, "} Var;"));
}

test "c_backend: union CDR serialize/deserialize" {
    var out = try testGenCdr(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int Var_serialize(ZidlCdrWriter *_w, const Var *_v)"));
    try testing.expect(has(s, "int Var_deserialize(ZidlCdrReader *_r, Var *_v)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->_d)"));
    try testing.expect(has(s, "switch (_v->_d) {"));
    try testing.expect(has(s, "case 0:"));
    try testing.expect(has(s, "default:"));
}

test "c_backend: typedef scalar" {
    var out = try testGen("typedef long MyInt;", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "typedef int32_t MyInt;"));
}

test "c_backend: typedef array" {
    var out = try testGen("typedef long Matrix[2][4];", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "typedef int32_t Matrix[2][4];"));
}

test "c_backend: const integer" {
    var out = try testGen("const long MAX_SIZE = 100;", "consts");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#define MAX_SIZE"));
    try testing.expect(has(s, "100"));
}

test "c_backend: const string" {
    var out = try testGen(
        \\const string GREETING = "hello";
    , "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "#define GREETING \"hello\""));
}

test "c_backend: sequence member" {
    var out = try testGen("struct Foo { sequence<long> items; };", "seq");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Sequence typedef must appear before the struct.
    const seq_pos = std.mem.indexOf(u8, s, "int32_t_seq");
    const struct_pos = std.mem.indexOf(u8, s, "typedef struct Foo_s");
    try testing.expect(seq_pos != null);
    try testing.expect(struct_pos != null);
    try testing.expect(seq_pos.? < struct_pos.?);
    // Buffer element pointer.
    try testing.expect(has(s, "int32_t *_buffer;"));
    // Member uses the typedef.
    try testing.expect(has(s, "    int32_t_seq items;"));
}

test "c_backend: bitmask" {
    var out = try testGen("bitmask Flags { FLAG_A, FLAG_B, FLAG_C };", "flags");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "typedef uint32_t Flags;"));
    try testing.expect(has(s, "#define Flags_FLAG_A"));
    try testing.expect(has(s, "#define Flags_FLAG_B"));
    try testing.expect(has(s, "#define Flags_FLAG_C"));
}

test "c_backend: map type returns error" {
    // map<K,V> is not supported in the C backend — must fail loudly at codegen time.
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init("struct S { map<long, long> m; };", ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = "map_test" };
    const result = generateHeader(alloc, &ir_spec, opts, &out);
    try testing.expectError(error.MapTypeNotSupportedInCBackend, result);
}

test "c_backend: native" {
    var out = try testGen("native Handle;", "native_test");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "typedef void *Handle;"));
}

test "c_backend: exception" {
    var out = try testGen("exception BadInput { string reason; };", "exc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "/* IDL exception */"));
    try testing.expect(has(s, "typedef struct BadInput_s {"));
    try testing.expect(has(s, "char *reason;"));
    try testing.expect(has(s, "} BadInput;"));
}

test "c_backend: interface (no --generate-interfaces)" {
    // Without --generate-interfaces, a comment placeholder is emitted.
    var out = try testGen(
        \\interface Greeter { string greet(in string name); };
    , "iface");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "IDL interface Greeter"));
    try testing.expect(!has(s, "Greeter_Vtable"));
}

fn testGenIfaceHeader(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
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
    try generateHeader(alloc, &ir_spec, opts, &out);
    return out;
}

fn testGenIfaceSource(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
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
    try generateIfaceSource(alloc, &ir_spec, opts, &out);
    return out;
}

test "c_backend: interface vtable header" {
    var out = try testGenIfaceHeader(
        \\interface Greeter { string greet(in string name); };
    , "iface");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "/* IDL interface: Greeter */"));
    try testing.expect(has(s, "Greeter_Vtable"));
    try testing.expect(has(s, "char *(*greet)(void *ptr, char *name);"));
    try testing.expect(has(s, "void (*deinit)(void *ptr);"));
    try testing.expect(has(s, "typedef struct Greeter {"));
    try testing.expect(has(s, "void                *ptr;"));
    try testing.expect(has(s, "const Greeter_Vtable *vtable;"));
    try testing.expect(has(s, "Greeter Greeter_zig_new(void *ptr);"));
}

test "c_backend: interface iface source" {
    var out = try testGenIfaceSource(
        \\interface Calc { long add(in long a, in long b); };
    , "calc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include \"calc.h\""));
    try testing.expect(has(s, "extern int32_t zidl_Calc_add(void *ptr, int32_t a, int32_t b);"));
    try testing.expect(has(s, "extern void zidl_Calc_deinit(void *ptr);"));
    try testing.expect(has(s, "static const Calc_Vtable Calc_zig_vtable_"));
    try testing.expect(has(s, ".add = zidl_Calc_add,"));
    try testing.expect(has(s, ".deinit = zidl_Calc_deinit,"));
    try testing.expect(has(s, "Calc Calc_zig_new(void *ptr)"));
}

test "c_backend: all primitives in struct" {
    var out = try testGen(
        \\struct Prims {
        \\  short a; long b; long long c;
        \\  unsigned short d; unsigned long e; unsigned long long f;
        \\  float g; double h;
        \\  char i; boolean j; octet k;
        \\  int8 l; uint8 m; int16 n; int32 o; int64 p;
        \\  uint16 q; uint32 r; uint64 s;
        \\};
    , "prims");
    defer out.deinit(testing.allocator);
    const content = out.items;
    try testing.expect(has(content, "int16_t a;"));
    try testing.expect(has(content, "int32_t b;"));
    try testing.expect(has(content, "int64_t c;"));
    try testing.expect(has(content, "uint16_t d;"));
    try testing.expect(has(content, "uint32_t e;"));
    try testing.expect(has(content, "uint64_t f;"));
    try testing.expect(has(content, "float g;"));
    try testing.expect(has(content, "double h;"));
    try testing.expect(has(content, "char i;"));
    try testing.expect(has(content, "bool j;"));
    try testing.expect(has(content, "uint8_t k;"));
    try testing.expect(has(content, "int8_t l;"));
    try testing.expect(has(content, "uint8_t m;"));
    try testing.expect(has(content, "int16_t n;"));
    try testing.expect(has(content, "int32_t o;"));
    try testing.expect(has(content, "int64_t p;"));
    try testing.expect(has(content, "uint16_t q;"));
    try testing.expect(has(content, "uint32_t r;"));
    try testing.expect(has(content, "uint64_t s;"));
}

test "c_backend: bounded string → char array" {
    var out = try testGen("struct Msg { string<64> name; };", "bstr");
    defer out.deinit(testing.allocator);
    // Bounded string<64> must produce a fixed char array with room for NUL.
    try testing.expect(has(out.items, "char name[65];"));
    // Must NOT emit a char pointer for bounded strings.
    try testing.expect(!has(out.items, "char *name;"));
}

test "c_backend: bounded wstring → uint16_t array" {
    var out = try testGen("struct Msg { wstring<32> label; };", "bwstr");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "uint16_t label[33];"));
}

test "c_backend: unbounded string → char pointer" {
    var out = try testGen("struct Msg { string name; };", "ubstr");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "char *name;"));
}

// ── wstring CDR tests ─────────────────────────────────────────────────────────

test "c_backend cdr: bounded wstring write uses zidl_cdr_write_wstring" {
    var src = try testGenCdr("struct S { wstring<16> ws; };", "s");
    defer src.deinit(testing.allocator);
    try testing.expect(has(src.items, "zidl_cdr_write_wstring"));
    // Bounded: length computed via while loop on the array.
    try testing.expect(has(src.items, "while ("));
    // Must NOT be a null-guard (bounded fields are arrays, never null).
    try testing.expect(!has(src.items, "_ws &&"));
}

test "c_backend cdr: unbounded wstring write uses null-safe loop" {
    var src = try testGenCdr("struct S { wstring ws; };", "s");
    defer src.deinit(testing.allocator);
    try testing.expect(has(src.items, "zidl_cdr_write_wstring"));
    // Unbounded: uses _ws pointer with null guard.
    try testing.expect(has(src.items, "_ws &&"));
}

test "c_backend cdr: bounded wstring read uses memcpy and bound check" {
    var src = try testGenCdr("struct S { wstring<16> ws; };", "s");
    defer src.deinit(testing.allocator);
    try testing.expect(has(src.items, "zidl_cdr_read_wstring"));
    // Bound check with the correct bound (16).
    try testing.expect(has(src.items, "16u"));
    try testing.expect(has(src.items, "memcpy"));
    try testing.expect(has(src.items, "free(_wp)"));
}

test "c_backend cdr: unbounded wstring read uses zidl_cdr_read_wstring" {
    var src = try testGenCdr("struct S { wstring ws; };", "s");
    defer src.deinit(testing.allocator);
    try testing.expect(has(src.items, "zidl_cdr_read_wstring"));
    // Unbounded: assigns directly into the field pointer, no memcpy.
    try testing.expect(!has(src.items, "memcpy"));
}

// ── CDR generation tests ──────────────────────────────────────────────────────

/// Parse `source`, build IR, generate CDR source into a returned buffer.
/// Caller must call `.deinit(testing.allocator)` on the returned ArrayList.
fn testGenCdr(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    return testGenCdrOpts(source, stem, .{});
}

fn testGenCdrOpts(source: []const u8, stem: []const u8, opts_extra: struct {
    no_typesupport: bool = false,
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

    const opts = interface.Options{
        .input_stem = stem,
        .no_typesupport = opts_extra.no_typesupport,
        .type_prefix = opts_extra.type_prefix,
    };
    try generateCdrSource(alloc, &ir_spec, opts, &out);

    return out;
}

test "c_backend cdr: header includes zidl_cdr.h when typesupport enabled" {
    var h = try testGen("struct Dummy { long x; };", "t");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "#include \"zidl_cdr.h\""));
}

test "c_backend cdr: header omits zidl_cdr.h when no_typesupport" {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init("struct Dummy { long x; };", ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = "t", .no_typesupport = true };
    try generateHeader(alloc, &ir_spec, opts, &out);
    try testing.expect(!has(out.items, "zidl_cdr.h"));
}

test "c_backend cdr: header emits CDR prototypes after struct" {
    var h = try testGen("struct Pt { long x; long y; };", "pt");
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "#define Pt_has_key 0"));
    try testing.expect(has(s, "int Pt_serialize(ZidlCdrWriter *_w, const Pt *_v);"));
    try testing.expect(has(s, "int Pt_deserialize(ZidlCdrReader *_r, Pt *_v);"));
    try testing.expect(!has(s, "Pt_serialize_key")); // no @key members
}

test "c_backend cdr: header emits serialize_key proto when @key present" {
    var h = try testGen("struct Msg { @key long id; string name; };", "msg");
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "#define Msg_has_key 1"));
    try testing.expect(has(s, "int Msg_serialize_key(ZidlCdrWriter *_w, const Msg *_v);"));
}

test "c_backend cdr: source file banner and includes" {
    var c_src = try testGenCdr("struct Pt { long x; };", "pt");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "#include \"pt.h\""));
    try testing.expect(has(s, "#include \"zidl_cdr.h\""));
    try testing.expect(has(s, "#include <stdlib.h>"));
    try testing.expect(has(s, "#include <string.h>"));
}

test "c_backend cdr: serialize @final struct primitives" {
    var c_src = try testGenCdr("struct Pt { long x; long y; };", "pt");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    // @final → no DHEADER
    try testing.expect(!has(s, "reserve_dheader_maybe"));
    try testing.expect(has(s, "Pt_serialize(ZidlCdrWriter *_w, const Pt *_v)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->x)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->y)"));
    try testing.expect(has(s, "Pt_deserialize(ZidlCdrReader *_r, Pt *_v)"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &_v->x)"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &_v->y)"));
}

test "c_backend cdr: serialize @appendable struct has DHEADER" {
    var c_src = try testGenCdr("@appendable struct App { long val; };", "app");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "zidl_cdr_reserve_dheader_maybe"));
    try testing.expect(has(s, "zidl_cdr_patch_dheader_maybe"));
    try testing.expect(has(s, "zidl_cdr_skip_dheader_if_xcdr2"));
}

test "c_backend cdr: serialize @key member emits serialize_key" {
    var c_src = try testGenCdr("struct Key { @key long id; string name; };", "key");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "Key_serialize_key(ZidlCdrWriter *_w, const Key *_v)"));
    // Only the @key member should appear in serialize_key
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->id)"));
}

test "c_backend cdr: serialize unbounded string" {
    var c_src = try testGenCdr("struct Msg { string name; };", "msg");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "zidl_cdr_write_string"));
    try testing.expect(has(s, "zidl_cdr_read_string(_r, &_v->name)"));
}

test "c_backend cdr: serialize bounded string" {
    var c_src = try testGenCdr("struct Msg { string<31> label; };", "msg");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "zidl_cdr_write_string"));
    try testing.expect(has(s, "zidl_cdr_read_string_zerocopy"));
}

test "c_backend cdr: serialize sequence member" {
    var c_src = try testGenCdr("struct List { sequence<long> items; };", "list");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, _v->items._length)"));
    try testing.expect(has(s, "zidl_cdr_read_u32(_r, &_sl)"));
    try testing.expect(has(s, "malloc"));
}

test "c_backend cdr: serialize enum member" {
    var c_src = try testGenCdr("enum Color { RED, GREEN }; struct Pixel { Color c; };", "px");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, (uint32_t)_v->c)"));
    try testing.expect(has(s, "zidl_cdr_read_u32"));
}

test "c_backend cdr: serialize nested struct" {
    var c_src = try testGenCdr("struct Inner { long v; }; struct Outer { Inner inner; };", "nest");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "Inner_serialize(_w, &_v->inner)"));
    try testing.expect(has(s, "Inner_deserialize(_r, &_v->inner)"));
}

test "c_backend cdr: serialize array field" {
    var c_src = try testGenCdr("struct Arr { long v[3]; };", "arr");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    // Array loop variable
    try testing.expect(has(s, "for (_ai0 = 0; _ai0 < 3u; _ai0++)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->v[_ai0])"));
}

test "c_backend cdr: all primitives in struct" {
    var c_src = try testGenCdr(
        \\struct All {
        \\  boolean b; octet oc; char ch; wchar wc;
        \\  short s; long l; long long ll;
        \\  unsigned short us; unsigned long ul; unsigned long long ull;
        \\  float f; double d;
        \\};
    , "all");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "zidl_cdr_write_bool"));
    try testing.expect(has(s, "zidl_cdr_write_u8"));
    try testing.expect(has(s, "zidl_cdr_write_char"));
    try testing.expect(has(s, "zidl_cdr_write_u16(_w, _v->wc)"));
    try testing.expect(has(s, "zidl_cdr_write_i16"));
    try testing.expect(has(s, "zidl_cdr_write_i32"));
    try testing.expect(has(s, "zidl_cdr_write_i64"));
    try testing.expect(has(s, "zidl_cdr_write_u16(_w, _v->us)"));
    try testing.expect(has(s, "zidl_cdr_write_u32"));
    try testing.expect(has(s, "zidl_cdr_write_u64"));
    try testing.expect(has(s, "zidl_cdr_write_f32"));
    try testing.expect(has(s, "zidl_cdr_write_f64"));
}

test "c_backend type_prefix: struct typedef and forward decl use prefix" {
    var h = try testGenFullOpts("struct Foo { long x; };", "t", .{ .type_prefix = "DDS_" });
    defer h.deinit(testing.allocator);
    // C backend uses tag "Foo_s" to avoid the struct-tag/typedef name collision.
    try testing.expect(has(h.items, "typedef struct DDS_Foo_s {"));
    try testing.expect(has(h.items, "} DDS_Foo;"));
    try testing.expect(!has(h.items, "typedef struct Foo_s {"));
}

test "c_backend type_prefix: serialize proto in header uses prefix" {
    var h = try testGenFullOpts("struct Foo { long x; };", "t", .{ .type_prefix = "DDS_" });
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "DDS_Foo_serialize("));
    try testing.expect(has(h.items, "DDS_Foo_deserialize("));
}

test "c_backend type_prefix: module-qualified name flattened with prefix" {
    var h = try testGenFullOpts("module M { struct S { long x; }; };", "t", .{ .type_prefix = "DDS_" });
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "typedef struct DDS_M_S_s {"));
    try testing.expect(has(h.items, "} DDS_M_S;"));
}

test "c_backend type_prefix: CDR source function name uses prefix" {
    var src = try testGenCdrOpts("struct Foo { long x; };", "t", .{ .type_prefix = "DDS_" });
    defer src.deinit(testing.allocator);
    try testing.expect(has(src.items, "DDS_Foo_serialize("));
    try testing.expect(has(src.items, "DDS_Foo_deserialize("));
}

test "c_backend pragma_once: replaces ifndef/define/endif guard" {
    var h = try testGenFullOpts("struct Foo { long x; };", "foo", .{ .pragma_once = true });
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "#pragma once"));
    try testing.expect(!has(s, "#ifndef"));
    try testing.expect(!has(s, "#define FOO_H"));
    try testing.expect(!has(s, "#endif"));
}

test "c_backend extern_c: wraps content in extern C brackets" {
    var h = try testGenFullOpts("struct Foo { long x; };", "foo", .{ .extern_c = true });
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "#ifdef __cplusplus"));
    try testing.expect(has(s, "extern \"C\" {"));
    try testing.expect(has(s, "typedef struct Foo_s {"));
    // closing bracket appears after the type
    const open_pos = std.mem.indexOf(u8, s, "extern \"C\" {").?;
    const close_pos = std.mem.indexOf(u8, s, "#ifdef __cplusplus\n}\n#endif").?;
    try testing.expect(close_pos > open_pos);
}

test "c_backend pragma_once split: per-type header uses pragma once" {
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

test "c_backend cdr: fixed<5,2> serialize/deserialize" {
    var c_src = try testGenCdr("struct S { fixed<5,2> price; };", "fp");
    defer c_src.deinit(testing.allocator);
    const s = c_src.items;
    try testing.expect(has(s, "zidl_cdr_write_fixed(_w, 5, 2, _v->price)"));
    try testing.expect(has(s, "zidl_cdr_read_fixed(_r, 5, 2, &_v->price)"));
}

test "c_backend: fixed<5,2> field type is double" {
    var h = try testGenTypeHeader("struct S { fixed<5,2> price; };", "fp", 0);
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "double price;"));
}
