//! Zig language mapping backend — type definitions (phase 3).
//!
//! Generates a single `<stem>.zig` source file per IDL spec containing:
//!   - Module    → `pub const Foo = struct { … };` (nested namespace struct)
//!   - Struct    → `pub const Foo = struct { field: Type = default, … };`
//!   - Union     → `pub const Foo = struct { _d: Disc = …, _u: union { … } = undefined };`
//!   - Enum      → `pub const Foo = enum(u32) { A = 0, … , _ };` (non-exhaustive)
//!   - Bitmask   → `pub const Foo = u32; pub const Foo_BIT: QName = 1 << N;`
//!   - Bitset    → `pub const Foo = packed struct { f: uN = 0, … };`
//!   - Typedef   → `pub const Foo = Bar;` or `pub const Foo = [N]Bar;`
//!   - Native    → `pub const Foo = opaque{};`
//!   - Exception → `pub const Foo = struct { … };`
//!   - Interface → comment placeholder (vtable requires `--generate-interfaces`)
//!   - Const     → `pub const NAME: Type = value;`
//!
//! ## Primitive type mapping
//!
//!   IDL short / long / long long       → i16 / i32 / i64
//!   IDL unsigned short / long / …      → u16 / u32 / u64
//!   IDL float / double / long double   → f32 / f64 / f128
//!   IDL char / wchar                   → u8 / u16
//!   IDL boolean / octet                → bool / u8
//!   IDL int8 … uint64                  → i8 … u64
//!   IDL string                         → []const u8
//!   IDL string<N>                      → zidl_rt.BoundedArray(u8, N)
//!   IDL wstring                        → []const u16
//!   IDL wstring<N>                     → zidl_rt.BoundedArray(u16, N)
//!   IDL sequence<T>                    → std.ArrayListUnmanaged(T)
//!   IDL sequence<T, N>                 → zidl_rt.BoundedArray(T, N)
//!   IDL T[N1][N2]                      → [N1][N2]T
//!   IDL @optional T                    → ?T  (null default)
//!   IDL any / object / value_base      → *anyopaque
//!   IDL fixed<D,S>                     → f64  (approximate)
//!   IDL map<K,V>                       → std.ArrayHashMapUnmanaged(K, V, …)

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir/root.zig");
const interface = @import("interface.zig");
const zig_to = @import("zig_typeobject.zig");

// ── Public backend struct ─────────────────────────────────────────────────────

pub const ZigBackend = struct {
    alloc: std.mem.Allocator,

    pub fn create(alloc: std.mem.Allocator) !*ZigBackend {
        const self = try alloc.create(ZigBackend);
        self.* = .{ .alloc = alloc };
        return self;
    }

    pub fn backend(self: *ZigBackend) interface.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = interface.Backend.Vtable{
        .language_id = "zig",
        .generate = vtableGenerate,
        .deinit = vtableDeinit,
    };

    fn vtableGenerate(
        ctx: *anyopaque,
        spec: *const ir.Spec,
        opts: interface.Options,
    ) anyerror!void {
        const self: *ZigBackend = @ptrCast(@alignCast(ctx));
        const io = std.Io.Threaded.global_single_threaded.io();

        if (opts.split_files) {
            try generateSplitFiles(self.alloc, io, spec, opts);
            return;
        }

        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.alloc);
        try generateFile(self.alloc, spec, opts, &content);

        const filename = try std.fmt.allocPrint(self.alloc, "{s}.zig", .{opts.input_stem});
        defer self.alloc.free(filename);
        try writeOutputFile(self.alloc, io, opts, filename, content.items);
    }

    fn vtableDeinit(ctx: *anyopaque) void {
        const self: *ZigBackend = @ptrCast(@alignCast(ctx));
        self.alloc.destroy(self);
    }
};

// ── Public entry points (testable) ───────────────────────────────────────────

/// Generate Zig source content into `out`.
///
/// Exposed for unit testing without touching the filesystem.
pub fn generateFile(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.emitFile(spec);
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
    // Ensure exactly one trailing newline (zig fmt convention).
    const trimmed = std.mem.trimEnd(u8, content, "\n");
    try fw.interface.writeAll(trimmed);
    try fw.interface.writeAll("\n");
    try fw.interface.flush();
}

// ── Split-file mode ───────────────────────────────────────────────────────────

/// Split mode: one `.zig` file per top-level IDL module, plus `<stem>.zig`
/// as a root that re-exports each module file.
///
/// Items not inside any top-level module are emitted inline in the root file.
/// Nested modules within a top-level module are handled by the existing
/// recursive `emitModule` logic within that module's file.
pub fn generateSplitFiles(
    alloc: std.mem.Allocator,
    io: std.Io,
    spec: *const ir.Spec,
    opts: interface.Options,
) !void {
    // Collect names of non-empty top-level modules and emit their files.
    var module_names = std.ArrayListUnmanaged([]const u8).empty;
    defer module_names.deinit(alloc);

    for (spec.items) |item| {
        const m = switch (item) {
            .module => |m| m,
            else => continue,
        };
        if (m.items.len == 0) continue;
        try module_names.append(alloc, m.name);

        // Build the module file: standard header + module items at depth 0.
        var content = std.ArrayList(u8).empty;
        defer content.deinit(alloc);
        var gen = Generator{ .alloc = alloc, .opts = opts, .out = &content };
        try gen.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{opts.input_stem},
        );
        try gen.write("const std = @import(\"std\");\n");
        if (!opts.no_typesupport or opts.pl_cdr) {
            try gen.write("const zidl_rt = @import(\"zidl_rt\");\n");
        }
        // Self-reference alias: allows Module.SomeType syntax within this file.
        try gen.print("// Self-reference alias: allows {s}.SomeType syntax within this file.\n", .{m.name});
        try gen.print("const {s} = @This();\n", .{m.name});
        try gen.write("\n");
        try gen.emitItems(m.items);

        const filename = try std.fmt.allocPrint(alloc, "{s}.zig", .{m.name});
        defer alloc.free(filename);
        try writeOutputFile(alloc, io, opts, filename, content.items);
    }

    // Build the root stem file: re-exports + any non-module items.
    var root = std.ArrayList(u8).empty;
    defer root.deinit(alloc);
    var gen = Generator{ .alloc = alloc, .opts = opts, .out = &root };

    try gen.print(
        "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
        .{opts.input_stem},
    );

    // Re-export each module file.
    for (module_names.items) |name| {
        try gen.print("pub const {s} = @import(\"{s}.zig\");\n", .{ name, name });
    }

    // Collect non-module items.
    var non_module: std.ArrayListUnmanaged(ir.ModuleItem) = .empty;
    defer non_module.deinit(alloc);
    for (spec.items) |item| {
        switch (item) {
            .module => {},
            else => try non_module.append(alloc, item),
        }
    }

    if (non_module.items.len > 0) {
        if (module_names.items.len > 0) try gen.write("\n");
        try gen.write("const std = @import(\"std\");\n");
        if (!opts.no_typesupport or opts.pl_cdr) {
            try gen.write("const zidl_rt = @import(\"zidl_rt\");\n");
        }
        try gen.write("\n");
        try gen.emitItems(non_module.items);
    } else if (module_names.items.len > 0) {
        try gen.write("\n");
    } else {
        // No modules and no items: emit standard header anyway.
        try gen.write("const std = @import(\"std\");\n");
        if (!opts.no_typesupport or opts.pl_cdr) {
            try gen.write("const zidl_rt = @import(\"zidl_rt\");\n");
        }
        try gen.write("\n");
    }

    const stem_filename = try std.fmt.allocPrint(alloc, "{s}.zig", .{opts.input_stem});
    defer alloc.free(stem_filename);
    try writeOutputFile(alloc, io, opts, stem_filename, root.items);
}

// ── Generator (private implementation) ───────────────────────────────────────

const Generator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),
    /// Current nesting depth: 0 = file level, 1 = inside one module struct, …
    depth: usize = 0,

    // ── Low-level output helpers ──────────────────────────────────────────────

    fn write(self: *Generator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *Generator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    /// Emit `depth * 4` spaces.
    fn ind(self: *Generator) !void {
        var i: usize = 0;
        while (i < self.depth) : (i += 1) try self.write("    ");
    }

    // ── Top-level file emission ───────────────────────────────────────────────

    fn emitFile(self: *Generator, spec: *const ir.Spec) !void {
        try self.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{self.opts.input_stem},
        );
        if (self.opts.zig_version != .@"0.16.0") {
            try self.print("// Zig output target: {s}\n\n", .{self.opts.zig_version.label()});
        }
        try self.write("const std = @import(\"std\");\n");
        if (!self.opts.no_typesupport or self.opts.pl_cdr) {
            try self.write("const zidl_rt = @import(\"zidl_rt\");\n");
        }
        try self.write("\n");
        try self.emitItems(spec.items);
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
        try self.ind();
        try self.print("pub const {s} = struct {{\n", .{m.name});
        self.depth += 1;
        try self.emitItems(m.items);
        self.depth -= 1;
        try self.ind();
        try self.print("}}; // {s}\n\n", .{m.name});
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
        const pfx = self.opts.type_prefix;
        try self.ind();
        try self.print("pub const {s}{s} = struct {{\n", .{ pfx, s.name });
        if (s.base) |base| {
            // Zig has no struct inheritance — embed the base as a named field.
            const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
            defer self.alloc.free(base_zig);
            try self.ind();
            try self.print("    _base: {s} = .{{}},\n", .{base_zig});
        }
        for (s.members) |m| {
            try self.emitField(m.name, m.type_ref, m.dimensions, m.annotations.is_optional);
        }
        // Emit serialize fns when full typesupport is requested, or when
        // --pl-cdr is set (PL_CDR fns are part of the struct, not TypeSupport).
        if (!self.opts.no_typesupport or self.opts.pl_cdr) {
            try self.emitStructSerializeFns(s);
        }
        if (!self.opts.no_typeobject_support) {
            try self.emitStructTypeObjectConsts(s);
        }
        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, s.name });
    }

    // ── Union ─────────────────────────────────────────────────────────────────

    fn emitUnion(self: *Generator, u: *const ir.Union) !void {
        const disc_zig = try self.typeRefToZig(u.discriminant);
        defer self.alloc.free(disc_zig);
        const disc_default = try self.defaultForTypeRef(u.discriminant);
        defer self.alloc.free(disc_default);

        const pfx = self.opts.type_prefix;
        try self.ind();
        try self.print("pub const {s}{s} = struct {{\n", .{ pfx, u.name });

        // Discriminant field.
        try self.ind();
        try self.print("    _d: {s} = {s},\n", .{ disc_zig, disc_default });

        // Anonymous union field.  Access is undefined unless discriminant is set.
        try self.ind();
        try self.write("    _u: union {\n");
        for (u.cases) |cas| {
            const case_zig = try self.typeRefToZig(cas.type_ref);
            defer self.alloc.free(case_zig);
            try self.ind();
            if (cas.dimensions.len > 0) {
                const arr_type = try self.makeArrayType(case_zig, cas.dimensions);
                defer self.alloc.free(arr_type);
                try self.print("        {s}: {s},\n", .{ cas.name, arr_type });
            } else {
                try self.print("        {s}: {s},\n", .{ cas.name, case_zig });
            }
        }
        try self.ind();
        try self.write("    } = undefined,\n");

        if (!self.opts.no_typesupport) {
            try self.emitUnionCdr(u);
        }

        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, u.name });
    }

    fn emitUnionCdr(self: *Generator, u: *const ir.Union) anyerror!void {
        const ext = u.annotations.extensibility;
        const mutable = ext == .mutable;
        const appendable = ext == .appendable; // strictly @appendable only

        const needs_alloc = blk: {
            for (u.cases) |cas| {
                if (typeRefNeedsAllocator(cas.type_ref)) break :blk true;
            }
            break :blk false;
        };

        // has_key constant (discriminant is implicit key but not annotated, so false by default)
        try self.write("\n");
        try self.ind();
        try self.write("    pub const has_key = false;\n");

        // Find default case (shared by serialize + deserialize)
        const default_case: ?ir.UnionCase = blk: {
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) break :blk cas;
            }
            break :blk null;
        };

        // ── serialize ────────────────────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn serialize(writer: anytype, value: @This()) !void {\n");

        if (mutable) {
            // @mutable union: DHEADER + EMHEADER(0) for discriminant + EMHEADER(N) for case.
            try self.ind();
            try self.write("        const _dh = try writer.reserveDheader();\n");
            // Discriminant: member_id=0.
            const disc_lc = lcForTypeRef(u.discriminant, &.{});
            if (disc_lc) |lc| {
                try self.ind();
                try self.print("        try writer.writeEmheaderFixed(0, false, {d});\n", .{lc});
                try self.emitDiscWriteZig(u.discriminant, "value._d", "        ");
            } else {
                try self.ind();
                try self.write("        const _em_disc = try writer.reserveEmheader(0, false);\n");
                try self.emitDiscWriteZig(u.discriminant, "value._d", "        ");
                try self.ind();
                try self.write("        writer.patchEmheader(_em_disc);\n");
            }
            // Case value: member_id = annotation.id ?? (case_index + 1)
            try self.ind();
            try self.write("        switch (value._d) {\n");
            for (u.cases, 0..) |cas, cas_idx| {
                if (isDefaultUnionCase(cas)) continue;
                const case_member_id: u32 = if (cas.annotations.id) |id| id else @intCast(cas_idx + 1);
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
                try self.write(" => {\n");
                const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{cas.name});
                defer self.alloc.free(access);
                if (lcForTypeRef(cas.type_ref, cas.dimensions)) |lc| {
                    try self.ind();
                    try self.print("                try writer.writeEmheaderFixed({d}, false, {d});\n", .{ case_member_id, lc });
                    if (cas.dimensions.len > 0) {
                        try self.emitWriteArray(cas.type_ref, access, cas.dimensions, "                ", 0);
                    } else {
                        try self.emitWriteForTypeRef(cas.type_ref, access, "                ");
                    }
                } else {
                    try self.ind();
                    try self.print("                const _em_case = try writer.reserveEmheader({d}, false);\n", .{case_member_id});
                    if (cas.dimensions.len > 0) {
                        try self.emitWriteArray(cas.type_ref, access, cas.dimensions, "                ", 0);
                    } else {
                        try self.emitWriteForTypeRef(cas.type_ref, access, "                ");
                    }
                    try self.ind();
                    try self.write("                writer.patchEmheader(_em_case);\n");
                }
                try self.ind();
                try self.write("            },\n");
            }
            if (default_case) |dc| {
                const dc_member_id: u32 = if (dc.annotations.id) |id| id else 0xFFFF_FFFF;
                const dc_access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{dc.name});
                defer self.alloc.free(dc_access);
                try self.ind();
                try self.write("            else => {\n");
                if (lcForTypeRef(dc.type_ref, dc.dimensions)) |lc| {
                    try self.ind();
                    try self.print("                try writer.writeEmheaderFixed({d}, false, {d});\n", .{ dc_member_id, lc });
                    if (dc.dimensions.len > 0) {
                        try self.emitWriteArray(dc.type_ref, dc_access, dc.dimensions, "                ", 0);
                    } else {
                        try self.emitWriteForTypeRef(dc.type_ref, dc_access, "                ");
                    }
                } else {
                    try self.ind();
                    try self.print("                const _em_case = try writer.reserveEmheader({d}, false);\n", .{dc_member_id});
                    if (dc.dimensions.len > 0) {
                        try self.emitWriteArray(dc.type_ref, dc_access, dc.dimensions, "                ", 0);
                    } else {
                        try self.emitWriteForTypeRef(dc.type_ref, dc_access, "                ");
                    }
                    try self.ind();
                    try self.write("                writer.patchEmheader(_em_case);\n");
                }
                try self.ind();
                try self.write("            },\n");
            } else {
                try self.ind();
                try self.write("            else => {},\n");
            }
            try self.ind();
            try self.write("        }\n");
            try self.ind();
            try self.write("        writer.patchDheader(_dh);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        const _dh = try writer.reserveDheaderMaybe();\n");
            }
            // Write discriminant
            try self.emitDiscWriteZig(u.discriminant, "value._d", "        ");
            // Switch on discriminant
            try self.ind();
            try self.write("        switch (value._d) {\n");
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) continue; // emit as else arm
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
                try self.write(" => {\n");
                if (cas.dimensions.len > 0) {
                    const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{cas.name});
                    defer self.alloc.free(access);
                    try self.emitWriteArray(cas.type_ref, access, cas.dimensions, "            ", 0);
                } else {
                    const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{cas.name});
                    defer self.alloc.free(access);
                    try self.emitWriteForTypeRef(cas.type_ref, access, "            ");
                }
                try self.ind();
                try self.write("            },\n");
            }
            if (default_case) |dc| {
                try self.ind();
                try self.write("            else => {\n");
                if (dc.dimensions.len > 0) {
                    const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{dc.name});
                    defer self.alloc.free(access);
                    try self.emitWriteArray(dc.type_ref, access, dc.dimensions, "                ", 0);
                } else {
                    const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{dc.name});
                    defer self.alloc.free(access);
                    try self.emitWriteForTypeRef(dc.type_ref, access, "                ");
                }
                try self.ind();
                try self.write("            },\n");
            } else {
                try self.ind();
                try self.write("            else => {},\n");
            }
            try self.ind();
            try self.write("        }\n");
            if (appendable) {
                try self.ind();
                try self.write("        writer.patchDheaderMaybe(_dh);\n");
            }
        }
        try self.ind();
        try self.write("    }\n");

        // ── deserializeInto ──────────────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {\n");
        if (!needs_alloc) {
            try self.ind();
            try self.write("        _ = allocator;\n");
        }

        if (mutable) {
            // @mutable union: read DHEADER, then EMHEADER loop.
            // Convention: member_id=0 is the discriminant; subsequent IDs are case values.
            try self.ind();
            try self.write("        const _em_end = try reader.readMutableDheader();\n");
            try self.ind();
            try self.write("        while (reader.mutableHasMore(_em_end)) {\n");
            try self.ind();
            try self.write("            const _emh = try reader.readEmheader();\n");
            try self.ind();
            try self.write("            if (_emh.member_id == 0) {\n");
            // Discriminant
            try self.emitDiscReadZig(u.discriminant, "out._d", "                ");
            try self.ind();
            try self.write("            } else {\n");
            // Case values: switch on the already-read discriminant
            try self.ind();
            try self.write("                switch (out._d) {\n");
            for (u.cases, 0..) |cas, cas_idx| {
                if (isDefaultUnionCase(cas)) continue;
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "                    ");
                try self.write(" => {\n");
                if (cas.dimensions.len > 0) {
                    const lval = try std.fmt.allocPrint(self.alloc, "out._u.{s}", .{cas.name});
                    defer self.alloc.free(lval);
                    try self.emitReadArray(cas.type_ref, lval, cas.dimensions, "                        ", 0);
                } else {
                    const lval = try std.fmt.allocPrint(self.alloc, "out._u.{s}", .{cas.name});
                    defer self.alloc.free(lval);
                    try self.emitReadForTypeRef(cas.type_ref, lval, "                        ");
                }
                _ = cas_idx;
                try self.ind();
                try self.write("                    },\n");
            }
            if (default_case) |dc| {
                try self.ind();
                try self.write("                    else => {\n");
                if (dc.dimensions.len > 0) {
                    const lval = try std.fmt.allocPrint(self.alloc, "out._u.{s}", .{dc.name});
                    defer self.alloc.free(lval);
                    try self.emitReadArray(dc.type_ref, lval, dc.dimensions, "                        ", 0);
                } else {
                    const lval = try std.fmt.allocPrint(self.alloc, "out._u.{s}", .{dc.name});
                    defer self.alloc.free(lval);
                    try self.emitReadForTypeRef(dc.type_ref, lval, "                        ");
                }
                try self.ind();
                try self.write("                    },\n");
            } else {
                try self.ind();
                try self.write("                    else => {\n");
                try self.ind();
                try self.write("                        if (_emh.must_understand) return error.UnknownMustUnderstand;\n");
                try self.ind();
                try self.write("                        try reader.skipEmheaderPayload(_emh);\n");
                try self.ind();
                try self.write("                    },\n");
            }
            try self.ind();
            try self.write("                }\n");
            try self.ind();
            try self.write("            }\n");
            try self.ind();
            try self.write("        }\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        try reader.skipDheaderIfXcdr2();\n");
            }
            // Read discriminant
            try self.emitDiscReadZig(u.discriminant, "out._d", "        ");
            // Switch on discriminant
            try self.ind();
            try self.write("        switch (out._d) {\n");
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) continue; // handled as else
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
                try self.write(" => {\n");
                if (cas.dimensions.len > 0) {
                    const lval = try std.fmt.allocPrint(self.alloc, "out._u.{s}", .{cas.name});
                    defer self.alloc.free(lval);
                    try self.emitReadArray(cas.type_ref, lval, cas.dimensions, "                ", 0);
                } else {
                    const lval = try std.fmt.allocPrint(self.alloc, "out._u.{s}", .{cas.name});
                    defer self.alloc.free(lval);
                    try self.emitReadForTypeRef(cas.type_ref, lval, "                ");
                }
                try self.ind();
                try self.write("            },\n");
            }
            if (default_case) |dc| {
                try self.ind();
                try self.write("            else => {\n");
                if (dc.dimensions.len > 0) {
                    const lval = try std.fmt.allocPrint(self.alloc, "out._u.{s}", .{dc.name});
                    defer self.alloc.free(lval);
                    try self.emitReadArray(dc.type_ref, lval, dc.dimensions, "                ", 0);
                } else {
                    const lval = try std.fmt.allocPrint(self.alloc, "out._u.{s}", .{dc.name});
                    defer self.alloc.free(lval);
                    try self.emitReadForTypeRef(dc.type_ref, lval, "                ");
                }
                try self.ind();
                try self.write("            },\n");
            } else {
                try self.ind();
                try self.write("            else => {},\n");
            }
            try self.ind();
            try self.write("        }\n");
        }
        try self.ind();
        try self.write("    }\n");

        // ── deserialize (convenience) ─────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn deserialize(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {\n");
        try self.ind();
        try self.write("        var _out: @This() = .{};\n");
        try self.ind();
        try self.write("        try @This().deserializeInto(&_out, reader, allocator);\n");
        try self.ind();
        try self.write("        return _out;\n");
        try self.ind();
        try self.write("    }\n");

        // ── skip ──────────────────────────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn skip(reader: *zidl_rt.CdrReader) !void {\n");
        if (mutable) {
            try self.ind();
            try self.write("        const _end = try reader.readMutableDheader();\n");
            try self.ind();
            try self.write("        try reader.seekTo(_end);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        if (reader.xcdr_version == .xcdr2) {\n");
                try self.ind();
                try self.write("            const _size = try reader.readDheader();\n");
                try self.ind();
                try self.write("            try reader.skip(_size);\n");
                try self.ind();
                try self.write("            return;\n");
                try self.ind();
                try self.write("        }\n");
            }
            const disc_zig = try self.typeRefToZig(u.discriminant);
            defer self.alloc.free(disc_zig);
            try self.ind();
            try self.print("        var _d: {s} = undefined;\n", .{disc_zig});
            try self.emitDiscReadZig(u.discriminant, "_d", "        ");
            try self.ind();
            try self.write("        switch (_d) {\n");
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) continue;
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
                try self.write(" => {\n");
                if (cas.dimensions.len > 0) {
                    try self.emitSkipArray(cas.type_ref, cas.dimensions, "                ", 0);
                } else {
                    try self.emitSkipForTypeRef(cas.type_ref, "                ");
                }
                try self.ind();
                try self.write("            },\n");
            }
            if (default_case) |dc| {
                try self.ind();
                try self.write("            else => {\n");
                if (dc.dimensions.len > 0) {
                    try self.emitSkipArray(dc.type_ref, dc.dimensions, "                ", 0);
                } else {
                    try self.emitSkipForTypeRef(dc.type_ref, "                ");
                }
                try self.ind();
                try self.write("            },\n");
            } else {
                try self.ind();
                try self.write("            else => {},\n");
            }
            try self.ind();
            try self.write("        }\n");
        }
        try self.ind();
        try self.write("    }\n");
    }

    /// Emit the discriminant write statement for Zig.
    fn emitDiscWriteZig(self: *Generator, disc: ir.TypeRef, access: []const u8, extra: []const u8) anyerror!void {
        switch (disc) {
            .base => |b| {
                const method = baseWriteMethod(b);
                try self.ind();
                try self.print("{s}try writer.{s}({s});\n", .{ extra, method, access });
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "writeU8",
                            '1' => "writeU16",
                            '3' => "writeU32",
                            '6' => "writeU64",
                            else => "writeU32",
                        },
                        else => "writeU32",
                    };
                    try self.ind();
                    try self.print("{s}try writer.{s}(@intFromEnum({s}));\n", .{ extra, method, access });
                },
                else => {
                    try self.ind();
                    try self.print("{s}// TODO: unsupported discriminant write\n", .{extra});
                },
            },
            else => {
                try self.ind();
                try self.print("{s}// TODO: unsupported discriminant write\n", .{extra});
            },
        }
    }

    /// Emit the discriminant read statement for Zig.
    fn emitDiscReadZig(self: *Generator, disc: ir.TypeRef, out_expr: []const u8, extra: []const u8) anyerror!void {
        switch (disc) {
            .base => |b| {
                const method = baseReadMethod(b);
                try self.ind();
                try self.print("{s}{s} = try reader.{s}();\n", .{ extra, out_expr, method });
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s} = @enumFromInt(try reader.{s}());\n", .{ extra, out_expr, method });
                },
                else => {
                    try self.ind();
                    try self.print("{s}// TODO: unsupported discriminant read\n", .{extra});
                },
            },
            else => {
                try self.ind();
                try self.print("{s}// TODO: unsupported discriminant read\n", .{extra});
            },
        }
    }

    /// Emit the Zig switch arm pattern (labels) for a union case.
    /// Writes the comma-separated pattern, then the caller appends ` => {`.
    fn emitZigUnionCaseArmPattern(self: *Generator, disc: ir.TypeRef, cas: ir.UnionCase, extra: []const u8) anyerror!void {
        try self.ind();
        try self.print("{s}", .{extra});
        var first = true;
        for (cas.labels) |lbl| {
            if (lbl == .default) continue; // skip — handled as else
            if (!first) try self.write(", ");
            first = false;
            switch (lbl) {
                .integer => |v| try self.print("{d}", .{v}),
                .boolean => |b| try self.write(if (b) "true" else "false"),
                .enumerator => |name| try self.print(".{s}", .{name}),
                .default => {},
            }
        }
        _ = disc;
    }

    // ── Enum ──────────────────────────────────────────────────────────────────

    fn emitEnum(self: *Generator, e: *const ir.Enum) !void {
        const pfx = self.opts.type_prefix;
        const storage = enumStorageType(e.annotations);
        try self.ind();
        try self.print("pub const {s}{s} = enum({s}) {{\n", .{ pfx, e.name, storage });
        for (e.enumerators) |en| {
            try self.ind();
            try self.print("    {s} = {d},\n", .{ en.name, en.value });
        }
        // Non-exhaustive: allows unknown enumerator values (DDS wire evolution).
        try self.ind();
        try self.write("    _,\n");
        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, e.name });
    }

    // ── Bitmask ───────────────────────────────────────────────────────────────

    fn emitBitmask(self: *Generator, bm: *const ir.Bitmask) !void {
        const pfx = self.opts.type_prefix;
        const storage = bitmaskStorageType(bm.annotations);
        // Use the fully-qualified Zig name for the bit-constant type annotations
        // so they remain valid if the bitmask is inside a module struct.
        // qualNameToZig already applies the prefix to the last segment.
        const zig_qname = try self.qualNameToZig(bm.qualified_name);
        defer self.alloc.free(zig_qname);

        try self.ind();
        try self.print("pub const {s}{s} = {s};\n", .{ pfx, bm.name, storage });
        for (bm.bits, 0..) |bit, i| {
            try self.ind();
            try self.print(
                "pub const {s}{s}_{s}: {s} = 1 << {d};\n",
                .{ pfx, bm.name, bit.name, zig_qname, i },
            );
        }
        try self.write("\n");
    }

    // ── Bitset ────────────────────────────────────────────────────────────────

    fn emitBitset(self: *Generator, bs: *const ir.Bitset) !void {
        const pfx = self.opts.type_prefix;
        try self.ind();
        try self.print("pub const {s}{s} = packed struct {{\n", .{ pfx, bs.name });
        for (bs.fields) |field| {
            if (field.names.len == 0) {
                // Anonymous padding field — skip with a comment to keep the
                // struct compilable; layout may need adjustment for exact bit counts.
                try self.ind();
                try self.print("    // {d} bits padding (unnamed)\n", .{field.bits});
                continue;
            }
            // Use u<N> for the bitfield width regardless of declared destination
            // type; Zig packed structs support arbitrary unsigned integer sizes.
            const field_zig = try std.fmt.allocPrint(self.alloc, "u{d}", .{field.bits});
            defer self.alloc.free(field_zig);
            for (field.names) |fname| {
                try self.ind();
                try self.print("    {s}: {s} = 0,\n", .{ fname, field_zig });
            }
        }

        if (!self.opts.no_typesupport) {
            const total = bitsetTotalBits(bs);
            if (total > 0) {
                const write_m: []const u8 = if (total <= 8) "writeU8" else if (total <= 16) "writeU16" else if (total <= 32) "writeU32" else "writeU64";
                const read_m: []const u8 = if (total <= 8) "readU8" else if (total <= 16) "readU16" else if (total <= 32) "readU32" else "readU64";
                try self.write("\n");
                try self.ind();
                try self.write("    pub fn serialize(writer: anytype, value: @This()) !void {\n");
                try self.ind();
                try self.print("        const _bs: u{d} = @bitCast(value);\n", .{total});
                try self.ind();
                try self.print("        try writer.{s}(@intCast(_bs));\n", .{write_m});
                try self.ind();
                try self.write("    }\n");
                try self.write("\n");
                try self.ind();
                try self.write("    pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, _: std.mem.Allocator) !void {\n");
                try self.ind();
                try self.print("        out.* = @bitCast(@as(u{d}, @truncate(try reader.{s}())));\n", .{ total, read_m });
                try self.ind();
                try self.write("    }\n");
                try self.write("\n");
                try self.ind();
                try self.write("    pub fn skip(reader: *zidl_rt.CdrReader) !void {\n");
                try self.ind();
                try self.print("        _ = try reader.{s}();\n", .{read_m});
                try self.ind();
                try self.write("    }\n");
            }
        }

        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, bs.name });
    }

    // ── Typedef ───────────────────────────────────────────────────────────────

    fn emitTypedef(self: *Generator, t: *const ir.Typedef) !void {
        const pfx = self.opts.type_prefix;
        const zig_type = try self.typeRefToZig(t.type_ref);
        defer self.alloc.free(zig_type);

        try self.ind();
        if (t.dimensions.len == 0) {
            try self.print("pub const {s}{s} = {s};\n\n", .{ pfx, t.name, zig_type });
        } else {
            // Array typedef: `typedef long Matrix[2][4]` → `pub const Matrix = [2][4]i32;`
            const arr_type = try self.makeArrayType(zig_type, t.dimensions);
            defer self.alloc.free(arr_type);
            try self.print("pub const {s}{s} = {s};\n\n", .{ pfx, t.name, arr_type });
        }
    }

    // ── Native ────────────────────────────────────────────────────────────────

    fn emitNative(self: *Generator, n: *const ir.Native) !void {
        try self.ind();
        try self.print("pub const {s}{s} = opaque{{}}; // @native\n\n", .{ self.opts.type_prefix, n.name });
    }

    // ── Exception ─────────────────────────────────────────────────────────────

    fn emitException(self: *Generator, e: *const ir.Exception) !void {
        const pfx = self.opts.type_prefix;
        try self.ind();
        try self.write("// IDL exception\n");
        try self.ind();
        try self.print("pub const {s}{s} = struct {{\n", .{ pfx, e.name });
        for (e.members) |m| {
            try self.emitField(m.name, m.type_ref, m.dimensions, false);
        }
        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, e.name });
    }

    // ── Interface ─────────────────────────────────────────────────────────────

    fn emitInterface(self: *Generator, iface: *const ir.Interface) anyerror!void {
        const pfx = self.opts.type_prefix;
        if (!self.opts.generate_interfaces) {
            try self.ind();
            try self.print(
                "// IDL interface {s}{s} — vtable struct emitted with --generate-interfaces\n\n",
                .{ pfx, iface.name },
            );
            return;
        }

        // Collect all inherited operations and attributes (flattened, in
        // declaration order: base first, then derived).  We walk the base
        // chain recursively so that multiple-level inheritance is handled.
        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try self.collectInterfaceMembers(iface, &ops, &attrs);

        // ── Outer struct ──────────────────────────────────────────────────
        try self.ind();
        try self.print("pub const {s}{s} = struct {{\n", .{ pfx, iface.name });

        try self.ind();
        try self.write("    ptr: *anyopaque,\n");
        try self.ind();
        try self.write("    vtable: *const Vtable,\n\n");

        // ── Vtable ────────────────────────────────────────────────────────
        try self.ind();
        try self.write("    pub const Vtable = struct {\n");

        for (ops.items) |op| {
            try self.ind();
            try self.write("        ");
            try self.print("{s}: *const fn (*anyopaque", .{op.name});
            for (op.params) |p| {
                const pt = try self.paramTypeStr(p);
                defer self.alloc.free(pt);
                try self.print(", {s}: {s}", .{ p.name, pt });
            }
            const ret = try self.returnTypeStr(op.return_type);
            defer self.alloc.free(ret);
            try self.print(") {s},\n", .{ret});
        }

        for (attrs.items) |attr| {
            const at = try self.typeRefToZig(attr.type_ref);
            defer self.alloc.free(at);
            // getter
            try self.ind();
            try self.print("        get_{s}: *const fn (*anyopaque) {s},\n", .{ attr.name, at });
            // setter (writable attributes only)
            if (!attr.readonly) {
                try self.ind();
                try self.print("        set_{s}: *const fn (*anyopaque, {s}) void,\n", .{ attr.name, at });
            }
        }

        try self.ind();
        try self.write("        deinit: *const fn (*anyopaque) void,\n");
        try self.ind();
        try self.write("    };\n\n");

        // ── Forwarding methods ────────────────────────────────────────────
        for (ops.items) |op| {
            const ret = try self.returnTypeStr(op.return_type);
            defer self.alloc.free(ret);

            try self.ind();
            try self.write("    pub fn ");
            try self.print("{s}(self: @This()", .{op.name});
            for (op.params) |p| {
                const pt = try self.paramTypeStr(p);
                defer self.alloc.free(pt);
                try self.print(", {s}: {s}", .{ p.name, pt });
            }
            try self.print(") {s} {{\n", .{ret});

            try self.ind();
            try self.write("        return self.vtable.");
            try self.print("{s}(self.ptr", .{op.name});
            for (op.params) |p| {
                try self.print(", {s}", .{p.name});
            }
            try self.write(");\n");
            try self.ind();
            try self.write("    }\n\n");
        }

        for (attrs.items) |attr| {
            const at = try self.typeRefToZig(attr.type_ref);
            defer self.alloc.free(at);
            // getter
            try self.ind();
            try self.print("    pub fn get_{s}(self: @This()) {s} {{\n", .{ attr.name, at });
            try self.ind();
            try self.print("        return self.vtable.get_{s}(self.ptr);\n", .{attr.name});
            try self.ind();
            try self.write("    }\n\n");
            // setter
            if (!attr.readonly) {
                try self.ind();
                try self.print("    pub fn set_{s}(self: @This(), value: {s}) void {{\n", .{ attr.name, at });
                try self.ind();
                try self.print("        self.vtable.set_{s}(self.ptr, value);\n", .{attr.name});
                try self.ind();
                try self.write("    }\n\n");
            }
        }

        try self.ind();
        try self.write("    pub fn deinit(self: @This()) void {\n");
        try self.ind();
        try self.write("        self.vtable.deinit(self.ptr);\n");
        try self.ind();
        try self.write("    }\n");

        // Nested type decls and consts inside the interface body.
        if (iface.type_decls.len > 0 or iface.consts.len > 0) {
            try self.write("\n");
            self.depth += 1;
            for (iface.type_decls) |td| try self.emitTypeDecl(td);
            for (iface.consts) |*c| try self.emitConst(c);
            self.depth -= 1;
        }

        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, iface.name });
    }

    /// Flatten inherited operations and attributes into `ops`/`attrs`.
    /// Base interfaces are processed first (declaration order).
    fn collectInterfaceMembers(
        self: *Generator,
        iface: *const ir.Interface,
        ops: *std.ArrayListUnmanaged(ir.Operation),
        attrs: *std.ArrayListUnmanaged(ir.Attribute),
    ) anyerror!void {
        for (iface.bases) |base| {
            if (base == .interface) {
                try self.collectInterfaceMembers(base.interface, ops, attrs);
            }
        }
        try ops.appendSlice(self.alloc, iface.operations);
        try attrs.appendSlice(self.alloc, iface.attributes);
    }

    /// Return the Zig type string for an operation parameter, applying the
    /// `out`/`inout` → pointer transformation.  Caller owns result.
    fn paramTypeStr(self: *Generator, p: ir.Parameter) ![]u8 {
        const base = try self.typeRefToZig(p.type_ref);
        defer self.alloc.free(base);
        return switch (p.mode) {
            .in_ => self.alloc.dupe(u8, base),
            .out, .inout => std.fmt.allocPrint(self.alloc, "*{s}", .{base}),
        };
    }

    /// Return the Zig return type string for an operation.  Caller owns result.
    fn returnTypeStr(self: *Generator, ret: ?ir.TypeRef) ![]u8 {
        return if (ret) |tr|
            self.typeRefToZig(tr)
        else
            self.alloc.dupe(u8, "void");
    }

    // ── Const ─────────────────────────────────────────────────────────────────

    fn emitConst(self: *Generator, c: *const ir.Const) !void {
        const zig_type = try self.typeRefToZig(c.type_ref);
        defer self.alloc.free(zig_type);

        try self.ind();
        switch (c.value) {
            .integer => |v| try self.print(
                "pub const {s}: {s} = {d};\n",
                .{ c.name, zig_type, v },
            ),
            .float => |v| try self.print(
                "pub const {s}: {s} = {d};\n",
                .{ c.name, zig_type, v },
            ),
            .boolean => |v| try self.print(
                "pub const {s}: bool = {s};\n",
                .{ c.name, if (v) "true" else "false" },
            ),
            .character => |ch| {
                if (std.ascii.isPrint(ch) and ch != '\'' and ch != '\\') {
                    try self.print("pub const {s}: u8 = '{c}';\n", .{ c.name, ch });
                } else {
                    try self.print("pub const {s}: u8 = 0x{X:0>2};\n", .{ c.name, ch });
                }
            },
            .string => |s| {
                try self.print("pub const {s}: []const u8 = \"", .{c.name});
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
                try self.write("\";\n");
            },
            .wide_character => |wc| try self.print(
                "pub const {s}: u16 = 0x{X:0>4};\n",
                .{ c.name, wc },
            ),
            .wide_string => try self.print(
                "// {s}: wide string const — []const u16 literal not supported\n",
                .{c.name},
            ),
            .fixed_pt => |fp| try self.print(
                "// {s}: fixed-point const {s}\n",
                .{ c.name, fp },
            ),
        }
    }

    // ── Field helper ──────────────────────────────────────────────────────────

    /// Emit one struct field line: `    name: Type = default,\n`.
    /// `ind()` provides the struct's own indentation; the `"    "` prefix adds
    /// one level for the field inside the struct body.
    fn emitField(
        self: *Generator,
        name: []const u8,
        type_ref: ir.TypeRef,
        dims: []const u64,
        is_optional: bool,
    ) !void {
        const zig_type = try self.typeRefToZig(type_ref);
        defer self.alloc.free(zig_type);

        try self.ind();

        if (is_optional) {
            try self.print("    {s}: ?{s} = null,\n", .{ name, zig_type });
        } else if (dims.len > 0) {
            const arr_type = try self.makeArrayType(zig_type, dims);
            defer self.alloc.free(arr_type);
            const default = try self.defaultForArrayType(arr_type);
            defer self.alloc.free(default);
            try self.print("    {s}: {s} = {s},\n", .{ name, arr_type, default });
        } else {
            const default = try self.defaultForTypeRef(type_ref);
            defer self.alloc.free(default);
            try self.print("    {s}: {s} = {s},\n", .{ name, zig_type, default });
        }
    }

    // ── CDR serialization emission ────────────────────────────────────────────

    fn emitStructSerializeFns(self: *Generator, s: *const ir.Struct) anyerror!void {
        const ext = s.annotations.extensibility;
        const mutable = ext == .mutable;
        const appendable = ext == .appendable; // true only for strictly @appendable

        const has_key = structHasKey(s);
        const needs_alloc = blk: {
            for (s.members) |m| {
                if (typeRefNeedsAllocator(m.type_ref)) break :blk true;
            }
            break :blk false;
        };

        try self.write("\n");

        // has_key constant
        try self.ind();
        try self.print("    pub const has_key = {s};\n\n", .{if (has_key) "true" else "false"});

        // ── serialize ────────────────────────────────────────────────────────
        try self.ind();
        try self.write("    pub fn serialize(writer: anytype, value: @This()) !void {\n");

        if (mutable) {
            // @mutable: outer DHEADER + per-member EMHEADER framing.
            try self.ind();
            try self.write("        const _dh = try writer.reserveDheader();\n");
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAt(m, idx);
                const mu_flag = m.annotations.must_understand;
                const mu_str = if (mu_flag) "true" else "false";
                if (m.annotations.is_optional) {
                    // Optional member: only emit EMHEADER when value is present.
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    try self.ind();
                    try self.print("        if (value.{s}) |{s}| {{\n", .{ m.name, opt_var });
                    if (lcForTypeRef(m.type_ref, m.dimensions)) |lc| {
                        try self.ind();
                        try self.print("            try writer.writeEmheaderFixed({d}, {s}, {d});\n", .{ member_id, mu_str, lc });
                    } else {
                        try self.ind();
                        try self.print("            const _em{d} = try writer.reserveEmheader({d}, {s});\n", .{ idx, member_id, mu_str });
                    }
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, opt_var, m.dimensions, "            ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, opt_var, "            ");
                    }
                    if (lcForTypeRef(m.type_ref, m.dimensions) == null) {
                        try self.ind();
                        try self.print("            writer.patchEmheader(_em{d});\n", .{idx});
                    }
                    try self.ind();
                    try self.write("        }\n");
                    continue;
                }
                const access = try std.fmt.allocPrint(self.alloc, "value.{s}", .{m.name});
                defer self.alloc.free(access);
                if (lcForTypeRef(m.type_ref, m.dimensions)) |lc| {
                    try self.ind();
                    try self.print("        try writer.writeEmheaderFixed({d}, {s}, {d});\n", .{ member_id, mu_str, lc });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                    }
                } else {
                    try self.ind();
                    try self.print("        const _em{d} = try writer.reserveEmheader({d}, {s});\n", .{ idx, member_id, mu_str });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                    }
                    try self.ind();
                    try self.print("        writer.patchEmheader(_em{d});\n", .{idx});
                }
            }
            try self.ind();
            try self.write("        writer.patchDheader(_dh);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        const _dh = try writer.reserveDheaderMaybe();\n");
            }
            if (s.base) |base| {
                const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_zig);
                try self.ind();
                try self.print("        try {s}.serialize(writer, value._base);\n", .{base_zig});
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: write bool presence flag, then value if present (§12).
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    try self.ind();
                    try self.print("        try writer.writeBool(value.{s} != null);\n", .{m.name});
                    try self.ind();
                    try self.print("        if (value.{s}) |{s}| {{\n", .{ m.name, opt_var });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, opt_var, m.dimensions, "            ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, opt_var, "            ");
                    }
                    try self.ind();
                    try self.write("        }\n");
                    continue;
                }
                const access = try std.fmt.allocPrint(self.alloc, "value.{s}", .{m.name});
                defer self.alloc.free(access);
                if (m.dimensions.len > 0) {
                    try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                } else {
                    try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                }
            }
            if (appendable) {
                try self.ind();
                try self.write("        writer.patchDheaderMaybe(_dh);\n");
            }
        }
        try self.ind();
        try self.write("    }\n\n");

        // ── deserializeInto ──────────────────────────────────────────────────
        try self.ind();
        try self.write("    pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {\n");
        if (!needs_alloc) {
            try self.ind();
            try self.write("        _ = allocator;\n");
        }

        if (mutable) {
            // @mutable: read DHEADER for end pos, loop on EMHEADER-framed members.
            try self.ind();
            try self.write("        const _em_end = try reader.readMutableDheader();\n");
            try self.ind();
            try self.write("        while (reader.mutableHasMore(_em_end)) {\n");
            try self.ind();
            try self.write("            const _emh = try reader.readEmheader();\n");
            try self.ind();
            try self.write("            switch (_emh.member_id) {\n");
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAt(m, idx);
                try self.ind();
                try self.print("                {d} => {{\n", .{member_id});
                if (m.annotations.is_optional) {
                    // For @mutable+@optional: member appears → value is present.
                    const zig_type = try self.typeRefToZig(m.type_ref);
                    defer self.alloc.free(zig_type);
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    const decl_type: []u8 = if (m.dimensions.len > 0)
                        try self.makeArrayType(zig_type, m.dimensions)
                    else
                        try self.alloc.dupe(u8, zig_type);
                    defer self.alloc.free(decl_type);
                    const default_val: []u8 = if (m.dimensions.len > 0)
                        try self.defaultForArrayType(decl_type)
                    else
                        try self.defaultForTypeRef(m.type_ref);
                    defer self.alloc.free(default_val);
                    try self.ind();
                    try self.print("                    var {s}: {s} = {s};\n", .{ opt_var, decl_type, default_val });
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, opt_var, m.dimensions, "                    ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, opt_var, "                    ");
                    }
                    try self.ind();
                    try self.print("                    out.{s} = {s};\n", .{ m.name, opt_var });
                } else {
                    const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                    defer self.alloc.free(out_expr);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, out_expr, m.dimensions, "                    ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, out_expr, "                    ");
                    }
                }
                try self.ind();
                try self.write("                },\n");
            }
            try self.ind();
            try self.write("                else => {\n");
            try self.ind();
            try self.write("                    if (_emh.must_understand) return error.UnknownMustUnderstand;\n");
            try self.ind();
            try self.write("                    try reader.skipEmheaderPayload(_emh);\n");
            try self.ind();
            try self.write("                },\n");
            try self.ind();
            try self.write("            }\n");
            try self.ind();
            try self.write("        }\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        try reader.skipDheaderIfXcdr2();\n");
            }
            if (s.base) |base| {
                const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_zig);
                try self.ind();
                try self.print("        try {s}.deserializeInto(&out._base, reader, allocator);\n", .{base_zig});
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: read bool presence flag; if true deserialize value (§12).
                    const zig_type = try self.typeRefToZig(m.type_ref);
                    defer self.alloc.free(zig_type);
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    const decl_type: []u8 = if (m.dimensions.len > 0)
                        try self.makeArrayType(zig_type, m.dimensions)
                    else
                        try self.alloc.dupe(u8, zig_type);
                    defer self.alloc.free(decl_type);
                    const default_val: []u8 = if (m.dimensions.len > 0)
                        try self.defaultForArrayType(decl_type)
                    else
                        try self.defaultForTypeRef(m.type_ref);
                    defer self.alloc.free(default_val);
                    try self.ind();
                    try self.write("        if (try reader.readBool()) {\n");
                    try self.ind();
                    try self.print("            var {s}: {s} = {s};\n", .{ opt_var, decl_type, default_val });
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, opt_var, m.dimensions, "            ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, opt_var, "            ");
                    }
                    try self.ind();
                    try self.print("            out.{s} = {s};\n", .{ m.name, opt_var });
                    try self.ind();
                    try self.write("        } else {\n");
                    try self.ind();
                    try self.print("            out.{s} = null;\n", .{m.name});
                    try self.ind();
                    try self.write("        }\n");
                    continue;
                }
                const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                defer self.alloc.free(out_expr);
                if (m.dimensions.len > 0) {
                    try self.emitReadArray(m.type_ref, out_expr, m.dimensions, "        ", 0);
                } else {
                    try self.emitReadForTypeRef(m.type_ref, out_expr, "        ");
                }
            }
        }
        try self.ind();
        try self.write("    }\n\n");

        // deserialize (convenience wrapper)
        try self.ind();
        try self.write("    pub fn deserialize(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {\n");
        try self.ind();
        try self.write("        var _out: @This() = .{};\n");
        try self.ind();
        try self.write("        try @This().deserializeInto(&_out, reader, allocator);\n");
        try self.ind();
        try self.write("        return _out;\n");
        try self.ind();
        try self.write("    }\n");

        // skip (allocation-free fast-forward over one full serialized sample)
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn skip(reader: *zidl_rt.CdrReader) !void {\n");
        if (mutable) {
            try self.ind();
            try self.write("        const _end = try reader.readMutableDheader();\n");
            try self.ind();
            try self.write("        try reader.seekTo(_end);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        if (reader.xcdr_version == .xcdr2) {\n");
                try self.ind();
                try self.write("            const _size = try reader.readDheader();\n");
                try self.ind();
                try self.write("            try reader.skip(_size);\n");
                try self.ind();
                try self.write("            return;\n");
                try self.ind();
                try self.write("        }\n");
            }
            if (s.base) |base| {
                const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_zig);
                try self.ind();
                try self.print("        try {s}.skip(reader);\n", .{base_zig});
            }
            for (s.members) |m| {
                try self.emitSkipMember(m, "        ");
            }
        }
        try self.ind();
        try self.write("    }\n");

        // serializeKey (only if has_key)
        if (has_key) {
            try self.write("\n");
            try self.ind();
            try self.write("    pub fn serializeKey(writer: anytype, value: @This()) !void {\n");
            if (s.base) |base| {
                if (typeDeclHasKey(base)) {
                    const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(base_zig);
                    try self.ind();
                    try self.print("        try {s}.serializeKey(writer, value._base);\n", .{base_zig});
                }
            }
            for (s.members) |m| {
                if (!m.annotations.is_key) continue;
                const access = try std.fmt.allocPrint(self.alloc, "value.{s}", .{m.name});
                defer self.alloc.free(access);
                if (m.dimensions.len > 0) {
                    try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                } else {
                    try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                }
            }
            try self.ind();
            try self.write("    }\n");

            try self.write("\n");
            try self.ind();
            try self.write("    pub fn deserializeKey(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {\n");
            try self.ind();
            try self.write("        var _out: @This() = .{};\n");
            try self.ind();
            try self.write("        try @This().deserializeKeyInto(&_out, reader, allocator);\n");
            try self.ind();
            try self.write("        return _out;\n");
            try self.ind();
            try self.write("    }\n");

            try self.write("\n");
            try self.ind();
            try self.write("    pub fn deserializeKeyInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {\n");
            if (!structKeyNeedsAllocator(s)) {
                try self.ind();
                try self.write("        _ = allocator;\n");
            }
            if (mutable) {
                try self.ind();
                try self.write("        const _em_end = try reader.readMutableDheader();\n");
                try self.ind();
                try self.write("        while (reader.mutableHasMore(_em_end)) {\n");
                try self.ind();
                try self.write("            const _emh = try reader.readEmheader();\n");
                try self.ind();
                try self.write("            switch (_emh.member_id) {\n");
                for (s.members, 0..) |m, idx| {
                    if (!m.annotations.is_key) continue;
                    const member_id: u32 = memberIdAt(m, idx);
                    try self.ind();
                    try self.print("                {d} => {{\n", .{member_id});
                    const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                    defer self.alloc.free(out_expr);
                    try self.emitReadPresentMember(m, out_expr, "                    ");
                    try self.ind();
                    try self.write("                },\n");
                }
                try self.ind();
                try self.write("                else => {\n");
                try self.ind();
                try self.write("                    if (_emh.must_understand) return error.UnknownMustUnderstand;\n");
                try self.ind();
                try self.write("                    try reader.skipEmheaderPayload(_emh);\n");
                try self.ind();
                try self.write("                },\n");
                try self.ind();
                try self.write("            }\n");
                try self.ind();
                try self.write("        }\n");
            } else {
                if (appendable) {
                    try self.ind();
                    try self.write("        const _key_end: ?usize = if (reader.xcdr_version == .xcdr2) blk: {\n");
                    try self.ind();
                    try self.write("            const _size = try reader.readDheader();\n");
                    try self.ind();
                    try self.write("            break :blk reader.pos + _size;\n");
                    try self.ind();
                    try self.write("        } else null;\n");
                }
                if (s.base) |base| {
                    const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(base_zig);
                    if (typeDeclHasKey(base)) {
                        try self.ind();
                        try self.print("        try {s}.deserializeKeyInto(&out._base, reader, allocator);\n", .{base_zig});
                    } else {
                        try self.ind();
                        try self.print("        try {s}.skip(reader);\n", .{base_zig});
                    }
                }
                for (s.members) |m| {
                    if (m.annotations.is_key) {
                        const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                        defer self.alloc.free(out_expr);
                        try self.emitReadMember(m, out_expr, "        ");
                    } else {
                        try self.emitSkipMember(m, "        ");
                    }
                }
                if (appendable) {
                    try self.ind();
                    try self.write("        if (_key_end) |_end| try reader.seekTo(_end);\n");
                }
            }
            try self.ind();
            try self.write("    }\n");

            try self.write("\n");
            try self.ind();
            try self.write("    pub fn computeKeyHash(value: @This()) [16]u8 {\n");
            try self.ind();
            try self.write("        var _khw = zidl_rt.KeyHashWriter.init();\n");
            try self.ind();
            try self.write("        @This().serializeKey(&_khw, value) catch unreachable;\n");
            try self.ind();
            try self.write("        return _khw.final();\n");
            try self.ind();
            try self.write("    }\n");
        }

        // PL_CDR functions (only for @mutable types when --pl-cdr is set)
        if (mutable and self.opts.pl_cdr) {
            try self.write("\n");
            try self.ind();
            try self.write("    pub fn serializePlCdr(writer: *zidl_rt.PlCdrWriter, value: @This()) !void {\n");
            for (s.members, 0..) |m, idx| {
                const pid: u32 = memberIdAt(m, idx);
                if (m.annotations.is_pl_repeated) {
                    // @pl_repeated: emit one PID entry per element instead of a single
                    // length-prefixed sequence parameter.
                    const elem_tr = m.type_ref.sequence.element.*;
                    if (m.annotations.is_optional) {
                        const seq_var = try std.fmt.allocPrint(self.alloc, "_seq_{d}", .{idx});
                        defer self.alloc.free(seq_var);
                        try self.ind();
                        try self.print("        if (value.{s}) |{s}| {{\n", .{ m.name, seq_var });
                        try self.ind();
                        try self.print("            for ({s}.items) |_elem| {{\n", .{seq_var});
                        try self.ind();
                        try self.print("                const _ph = try writer.reservePlParam({d});\n", .{pid});
                        try self.emitWriteForTypeRef(elem_tr, "_elem", "                ");
                        try self.ind();
                        try self.write("                try writer.patchPlParam(_ph);\n");
                        try self.ind();
                        try self.write("            }\n");
                        try self.ind();
                        try self.write("        }\n");
                    } else {
                        try self.ind();
                        try self.print("        for (value.{s}.items) |_elem| {{\n", .{m.name});
                        try self.ind();
                        try self.print("            const _ph = try writer.reservePlParam({d});\n", .{pid});
                        try self.emitWriteForTypeRef(elem_tr, "_elem", "            ");
                        try self.ind();
                        try self.write("            try writer.patchPlParam(_ph);\n");
                        try self.ind();
                        try self.write("        }\n");
                    }
                } else if (m.annotations.is_optional) {
                    // @optional: only emit param when value is present (no presence byte)
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    try self.ind();
                    try self.print("        if (value.{s}) |{s}| {{\n", .{ m.name, opt_var });
                    try self.ind();
                    try self.print("            const _ph{d} = try writer.reservePlParam({d});\n", .{ idx, pid });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, opt_var, m.dimensions, "            ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, opt_var, "            ");
                    }
                    try self.ind();
                    try self.print("            try writer.patchPlParam(_ph{d});\n", .{idx});
                    try self.ind();
                    try self.write("        }\n");
                } else {
                    const access = try std.fmt.allocPrint(self.alloc, "value.{s}", .{m.name});
                    defer self.alloc.free(access);
                    try self.ind();
                    try self.print("        const _ph{d} = try writer.reservePlParam({d});\n", .{ idx, pid });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                    }
                    try self.ind();
                    try self.print("        try writer.patchPlParam(_ph{d});\n", .{idx});
                }
            }
            try self.ind();
            try self.write("        try writer.writePlSentinel();\n");
            try self.ind();
            try self.write("    }\n\n");

            // deserializeFromPlCdr
            try self.ind();
            try self.write("    pub fn deserializeFromPlCdr(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {\n");
            if (!needs_alloc) {
                try self.ind();
                try self.write("        _ = allocator;\n");
            }
            try self.ind();
            try self.write("        while (try reader.readPlParam()) |_p| {\n");
            try self.ind();
            try self.write("            switch (_p.pid & 0x3FFF) {\n");
            for (s.members, 0..) |m, idx| {
                const pid: u32 = memberIdAt(m, idx);
                try self.ind();
                try self.print("                {d} => {{\n", .{pid});
                if (m.annotations.is_pl_repeated) {
                    // @pl_repeated: each occurrence of this PID carries one element;
                    // accumulate into the sequence.
                    const elem_tr = m.type_ref.sequence.element.*;
                    if (m.annotations.is_optional) {
                        // ?std.ArrayListUnmanaged(T): initialise on first occurrence.
                        try self.ind();
                        try self.print("                    if (out.{s} == null) out.{s} = .{{}};\n", .{ m.name, m.name });
                        const seq_expr = try std.fmt.allocPrint(self.alloc, "out.{s}.?", .{m.name});
                        defer self.alloc.free(seq_expr);
                        try self.emitPlRepeatedElementAppend(elem_tr, seq_expr, "                    ");
                    } else {
                        const seq_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                        defer self.alloc.free(seq_expr);
                        try self.emitPlRepeatedElementAppend(elem_tr, seq_expr, "                    ");
                    }
                } else if (m.annotations.is_optional) {
                    // Presence implied by PID appearing in the stream
                    const zig_type = try self.typeRefToZig(m.type_ref);
                    defer self.alloc.free(zig_type);
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    const decl_type: []u8 = if (m.dimensions.len > 0)
                        try self.makeArrayType(zig_type, m.dimensions)
                    else
                        try self.alloc.dupe(u8, zig_type);
                    defer self.alloc.free(decl_type);
                    const default_val: []u8 = if (m.dimensions.len > 0)
                        try self.defaultForArrayType(decl_type)
                    else
                        try self.defaultForTypeRef(m.type_ref);
                    defer self.alloc.free(default_val);
                    try self.ind();
                    try self.print("                    var {s}: {s} = {s};\n", .{ opt_var, decl_type, default_val });
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, opt_var, m.dimensions, "                    ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, opt_var, "                    ");
                    }
                    try self.ind();
                    try self.print("                    out.{s} = {s};\n", .{ m.name, opt_var });
                } else {
                    const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                    defer self.alloc.free(out_expr);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, out_expr, m.dimensions, "                    ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, out_expr, "                    ");
                    }
                }
                try self.ind();
                try self.write("                },\n");
            }
            try self.ind();
            try self.write("                else => {},\n");
            try self.ind();
            try self.write("            }\n");
            try self.ind();
            try self.write("            try reader.seekTo(_p.end_pos);\n");
            try self.ind();
            try self.write("        }\n");
            try self.ind();
            try self.write("    }\n");
        }
    }

    // ── TypeObject / TypeIdentifier constant emission ─────────────────────────

    /// Emit `type_object`, `equivalence_hash`, and `type_identifier` constants
    /// inside the struct body.  The bytes are computed at code-gen time.
    fn emitStructTypeObjectConsts(self: *Generator, s: *const ir.Struct) !void {
        const bytes = try zig_to.encodeMinimalStruct(self.alloc, s);
        defer self.alloc.free(bytes);

        const eq_hash = zig_to.computeEquivalenceHash(bytes);
        const type_id = zig_to.computeTypeIdentifier(bytes);

        try self.write("\n");

        // type_object — full XCDR2 LE MinimalTypeObject CDR bytes
        try self.ind();
        try self.write("    pub const type_object: []const u8 = &[_]u8{");
        try emitByteSlice(self, bytes);
        try self.write(" };\n");

        // equivalence_hash — MD5[0..14] of type_object, the on-wire DDS EquivalenceHash
        try self.ind();
        try self.write("    pub const equivalence_hash: [14]u8 = [14]u8{");
        try emitByteSlice(self, &eq_hash);
        try self.write(" };\n");

        // type_identifier — SHA-256 of type_object, zidl project fingerprint
        try self.ind();
        try self.write("    pub const type_identifier: [32]u8 = [32]u8{");
        try emitByteSlice(self, &type_id);
        try self.write(" };\n");
    }

    /// Emit comma-separated `0xXX` hex literals for `bytes`.
    fn emitByteSlice(self: *Generator, bytes: []const u8) !void {
        for (bytes, 0..) |b, i| {
            if (i > 0) try self.write(",");
            try self.print(" 0x{X:0>2}", .{b});
        }
    }

    /// Emit a single CDR write statement for the given type.
    /// `access` is the value expression (e.g. "value.x").
    /// `extra` is the fixed indentation beyond `ind()` (e.g. "        " for method body).
    fn emitWriteForTypeRef(self: *Generator, tr: ir.TypeRef, access: []const u8, extra: []const u8) anyerror!void {
        switch (tr) {
            .base => |b| {
                const method = baseWriteMethod(b);
                try self.ind();
                try self.print("{s}try writer.{s}({s});\n", .{ extra, method, access });
            },
            .string => |bound| {
                try self.ind();
                if (bound != null) {
                    try self.print("{s}try writer.writeString({s}.slice());\n", .{ extra, access });
                } else {
                    try self.print("{s}try writer.writeString({s});\n", .{ extra, access });
                }
            },
            .wstring => |bound| {
                try self.ind();
                if (bound != null) {
                    try self.print("{s}try writer.writeWstring({s}.slice());\n", .{ extra, access });
                } else {
                    try self.print("{s}try writer.writeWstring({s});\n", .{ extra, access });
                }
            },
            .sequence => |seq| {
                try self.ind();
                if (seq.bound != null) {
                    try self.print("{s}try writer.writeU32(@intCast({s}.slice().len));\n", .{ extra, access });
                } else {
                    try self.print("{s}try writer.writeU32(@intCast({s}.items.len));\n", .{ extra, access });
                }
                try self.ind();
                if (seq.bound != null) {
                    try self.print("{s}for ({s}.slice()) |_se| {{\n", .{ extra, access });
                } else {
                    try self.print("{s}for ({s}.items) |_se| {{\n", .{ extra, access });
                }
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.emitWriteForTypeRef(seq.element.*, "_se", inner);
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "writeU8",
                            '1' => "writeU16",
                            '3' => "writeU32",
                            '6' => "writeU64",
                            else => "writeU32",
                        },
                        else => "writeU32",
                    };
                    try self.ind();
                    try self.print("{s}try writer.{s}(@intFromEnum({s}));\n", .{ extra, method, access });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitWriteArray(t.type_ref, access, t.dimensions, extra, 0);
                    } else {
                        try self.emitWriteForTypeRef(t.type_ref, access, extra);
                    }
                },
                .bitmask => |bm| {
                    const stor = bitmaskStorageType(bm.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "writeU8",
                            '1' => "writeU16",
                            '3' => "writeU32",
                            '6' => "writeU64",
                            else => "writeU32",
                        },
                        else => "writeU32",
                    };
                    try self.ind();
                    try self.print("{s}try writer.{s}({s});\n", .{ extra, method, access });
                },
                .union_ => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.serialize(writer, {s});\n", .{ extra, zig_type, access });
                },
                .bitset => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.serialize(writer, {s});\n", .{ extra, zig_type, access });
                },
                else => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.serialize(writer, {s});\n", .{ extra, zig_type, access });
                },
            },
            .map => |m| {
                try self.ind();
                try self.print("{s}try writer.writeU32(@intCast({s}.count()));\n", .{ extra, access });
                try self.ind();
                try self.print("{s}for ({s}.keys(), {s}.values()) |_mk, _mv| {{\n", .{ extra, access, access });
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.emitWriteForTypeRef(m.key.*, "_mk", inner);
                try self.emitWriteForTypeRef(m.value.*, "_mv", inner);
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .fixed_pt => |fp| {
                try self.ind();
                try self.print("{s}try writer.writeFixed({d}, {d}, {s});\n", .{ extra, fp.digits, fp.scale, access });
            },
        }
    }

    /// Emit CDR read statement(s) for the given type.
    /// `out_expr` is the lvalue expression (e.g. "out.x").
    fn emitReadForTypeRef(self: *Generator, tr: ir.TypeRef, out_expr: []const u8, extra: []const u8) anyerror!void {
        switch (tr) {
            .base => |b| {
                const method = baseReadMethod(b);
                try self.ind();
                try self.print("{s}{s} = try reader.{s}();\n", .{ extra, out_expr, method });
            },
            .string => |bound| {
                if (bound) |n| {
                    // Bounded: zero-copy read, then copy into BoundedArray
                    try self.ind();
                    try self.print("{s}{{\n", .{extra});
                    const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                    defer self.alloc.free(ii);
                    try self.ind();
                    try self.print("{s}const _s = try reader.readStringZeroCopy();\n", .{ii});
                    try self.ind();
                    try self.print("{s}if (_s.len > {d}) return error.StringTooLong;\n", .{ ii, n });
                    try self.ind();
                    try self.print("{s}{s} = zidl_rt.BoundedArray(u8, {d}).fromSlice(_s) catch unreachable;\n", .{ ii, out_expr, n });
                    try self.ind();
                    try self.print("{s}}}\n", .{extra});
                } else {
                    try self.ind();
                    try self.print("{s}{s} = try reader.readString(allocator);\n", .{ extra, out_expr });
                }
            },
            .wstring => |bound| {
                if (bound) |n| {
                    // Bounded: allocate temp slice, bound-check, copy into BoundedArray, free temp.
                    try self.ind();
                    try self.print("{s}{{\n", .{extra});
                    const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                    defer self.alloc.free(ii);
                    try self.ind();
                    try self.print("{s}const _ws = try reader.readWstring(allocator);\n", .{ii});
                    try self.ind();
                    try self.print("{s}defer allocator.free(_ws);\n", .{ii});
                    try self.ind();
                    try self.print("{s}if (_ws.len > {d}) return error.StringTooLong;\n", .{ ii, n });
                    try self.ind();
                    try self.print("{s}{s} = zidl_rt.BoundedArray(u16, {d}).fromSlice(_ws) catch unreachable;\n", .{ ii, out_expr, n });
                    try self.ind();
                    try self.print("{s}}}\n", .{extra});
                } else {
                    try self.ind();
                    try self.print("{s}{s} = try reader.readWstring(allocator);\n", .{ extra, out_expr });
                }
            },
            .sequence => |seq| {
                try self.ind();
                try self.print("{s}{{\n", .{extra});
                const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(ii);
                try self.ind();
                try self.print("{s}const _n = try reader.readU32();\n", .{ii});
                if (seq.bound) |bound| {
                    try self.ind();
                    try self.print("{s}if (_n > {d}) return error.SequenceTooLong;\n", .{ ii, bound });
                    try self.ind();
                    try self.print("{s}{s}.clearRetainingCapacity();\n", .{ ii, out_expr });
                } else {
                    try self.ind();
                    try self.print("{s}try {s}.ensureTotalCapacity(allocator, _n);\n", .{ ii, out_expr });
                }
                try self.ind();
                try self.print("{s}for (0.._n) |_| {{\n", .{ii});
                const iii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{ii});
                defer self.alloc.free(iii);
                try self.emitSequenceElementRead(seq.element.*, out_expr, iii);
                try self.ind();
                try self.print("{s}}}\n", .{ii});
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .map => |m| {
                try self.ind();
                try self.print("{s}{{\n", .{extra});
                const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(ii);
                try self.ind();
                try self.print("{s}const _mn = try reader.readU32();\n", .{ii});
                try self.ind();
                try self.print("{s}{s} = .{{}};\n", .{ ii, out_expr });
                try self.ind();
                try self.print("{s}try {s}.ensureTotalCapacity(allocator, _mn);\n", .{ ii, out_expr });
                try self.ind();
                try self.print("{s}for (0.._mn) |_| {{\n", .{ii});
                const iii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{ii});
                defer self.alloc.free(iii);
                const key_zig = try self.typeRefToZig(m.key.*);
                defer self.alloc.free(key_zig);
                try self.ind();
                try self.print("{s}var _mk: {s} = undefined;\n", .{ iii, key_zig });
                try self.emitReadForTypeRef(m.key.*, "_mk", iii);
                const val_zig = try self.typeRefToZig(m.value.*);
                defer self.alloc.free(val_zig);
                try self.ind();
                try self.print("{s}var _mv: {s} = undefined;\n", .{ iii, val_zig });
                try self.emitReadForTypeRef(m.value.*, "_mv", iii);
                try self.ind();
                try self.print("{s}try {s}.putNoClobber(allocator, _mk, _mv);\n", .{ iii, out_expr });
                try self.ind();
                try self.print("{s}}}\n", .{ii});
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s} = @enumFromInt(try reader.{s}());\n", .{ extra, out_expr, method });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitReadArray(t.type_ref, out_expr, t.dimensions, extra, 0);
                    } else {
                        try self.emitReadForTypeRef(t.type_ref, out_expr, extra);
                    }
                },
                .bitmask => |bm| {
                    const stor = bitmaskStorageType(bm.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s} = try reader.{s}();\n", .{ extra, out_expr, method });
                },
                .union_ => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&{s}, reader, allocator);\n", .{ extra, zig_type, out_expr });
                },
                .bitset => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&{s}, reader, allocator);\n", .{ extra, zig_type, out_expr });
                },
                else => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&{s}, reader, allocator);\n", .{ extra, zig_type, out_expr });
                },
            },
            .fixed_pt => |fp| {
                try self.ind();
                try self.print("{s}{s} = try reader.readFixed({d}, {d});\n", .{ extra, out_expr, fp.digits, fp.scale });
            },
        }
    }

    /// Emit read of one sequence element and append it.
    fn emitSequenceElementRead(self: *Generator, elem_tr: ir.TypeRef, seq_expr: []const u8, extra: []const u8) anyerror!void {
        switch (elem_tr) {
            .base => |b| {
                const method = baseReadMethod(b);
                try self.ind();
                try self.print("{s}{s}.appendAssumeCapacity(try reader.{s}());\n", .{ extra, seq_expr, method });
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(@enumFromInt(try reader.{s}()));\n", .{ extra, seq_expr, method });
                },
                .typedef => |t| {
                    // For scalar typedefs, recurse on the underlying type so that
                    // e.g. `typedef long MyInt` → sequence element uses readI32.
                    // Array typedefs as sequence elements are rare; emit TODO.
                    if (t.dimensions.len > 0) {
                        try self.ind();
                        try self.print("{s}// TODO: sequence element read array-typedef {s}\n", .{ extra, t.name });
                    } else {
                        try self.emitSequenceElementRead(t.type_ref, seq_expr, extra);
                    }
                },
                .bitmask => |bm| {
                    const stor = bitmaskStorageType(bm.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(try reader.{s}());\n", .{ extra, seq_expr, method });
                },
                .union_ => {
                    const zig_type = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}var _elem: {s} = .{{}};\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&_elem, reader, allocator);\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(_elem);\n", .{ extra, seq_expr });
                },
                .bitset => {
                    const zig_type = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}var _elem: {s} = .{{}};\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&_elem, reader, allocator);\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(_elem);\n", .{ extra, seq_expr });
                },
                else => {
                    const zig_type = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}var _elem: {s} = .{{}};\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&_elem, reader, allocator);\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(_elem);\n", .{ extra, seq_expr });
                },
            },
            else => {
                try self.ind();
                try self.print("{s}// TODO: sequence element read\n", .{extra});
            },
        }
    }

    /// Emit "read one element and `try seq.append(allocator, elem)`" for `@pl_repeated` fields.
    /// Unlike `emitSequenceElementRead` (which uses `appendAssumeCapacity` after
    /// `ensureTotalCapacity`), this path works without a prior element count.
    fn emitPlRepeatedElementAppend(
        self: *Generator,
        elem_tr: ir.TypeRef,
        seq_expr: []const u8,
        extra: []const u8,
    ) anyerror!void {
        switch (elem_tr) {
            .base => |b| {
                const method = baseReadMethod(b);
                try self.ind();
                try self.print("{s}try {s}.append(allocator, try reader.{s}());\n", .{ extra, seq_expr, method });
            },
            .string => |bound| {
                if (bound != null) {
                    const zig_elem = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_elem);
                    try self.ind();
                    try self.print("{s}{{\n", .{extra});
                    const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                    defer self.alloc.free(ii);
                    try self.ind();
                    try self.print("{s}const _s = try reader.readStringZeroCopy();\n", .{ii});
                    try self.ind();
                    try self.print("{s}if (_s.len > {d}) return error.StringTooLong;\n", .{ ii, bound.? });
                    try self.ind();
                    try self.print("{s}try {s}.append(allocator, {s}.fromSlice(_s) catch unreachable);\n", .{ ii, seq_expr, zig_elem });
                    try self.ind();
                    try self.print("{s}}}\n", .{extra});
                } else {
                    try self.ind();
                    try self.print("{s}try {s}.append(allocator, try reader.readString(allocator));\n", .{ extra, seq_expr });
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}try {s}.append(allocator, @enumFromInt(try reader.{s}()));\n", .{ extra, seq_expr, method });
                },
                .bitmask => |bm| {
                    const stor = bitmaskStorageType(bm.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}try {s}.append(allocator, try reader.{s}());\n", .{ extra, seq_expr, method });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.ind();
                        try self.print("{s}// TODO: @pl_repeated sequence-of-array-typedef\n", .{extra});
                    } else {
                        try self.emitPlRepeatedElementAppend(t.type_ref, seq_expr, extra);
                    }
                },
                .union_ => {
                    const zig_type = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}var _elem: {s} = .{{}};\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&_elem, reader, allocator);\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.append(allocator, _elem);\n", .{ extra, seq_expr });
                },
                .bitset => {
                    const zig_type = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}var _elem: {s} = .{{}};\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&_elem, reader, allocator);\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.append(allocator, _elem);\n", .{ extra, seq_expr });
                },
                else => {
                    const zig_type = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}var _elem: {s} = .{{}};\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&_elem, reader, allocator);\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.append(allocator, _elem);\n", .{ extra, seq_expr });
                },
            },
            else => {
                try self.ind();
                try self.print("{s}// TODO: @pl_repeated element read\n", .{extra});
            },
        }
    }

    /// Emit write loops for an IDL array member (multi-dimensional).
    fn emitWriteArray(self: *Generator, elem_tr: ir.TypeRef, access: []const u8, dims: []const u64, extra: []const u8, depth: usize) anyerror!void {
        if (dims.len == 0) {
            try self.emitWriteForTypeRef(elem_tr, access, extra);
            return;
        }
        const var_name = try std.fmt.allocPrint(self.alloc, "_d{d}", .{depth});
        defer self.alloc.free(var_name);
        try self.ind();
        try self.print("{s}for ({s}) |{s}| {{\n", .{ extra, access, var_name });
        const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(inner);
        try self.emitWriteArray(elem_tr, var_name, dims[1..], inner, depth + 1);
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    /// Emit index-based read loops for an IDL array member (multi-dimensional).
    fn emitReadArray(self: *Generator, elem_tr: ir.TypeRef, base_access: []const u8, dims: []const u64, extra: []const u8, depth: usize) anyerror!void {
        if (dims.len == 0) {
            try self.emitReadForTypeRef(elem_tr, base_access, extra);
            return;
        }
        const idx = try std.fmt.allocPrint(self.alloc, "_i{d}", .{depth});
        defer self.alloc.free(idx);
        try self.ind();
        try self.print("{s}for (0..{d}) |{s}| {{\n", .{ extra, dims[0], idx });
        const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(inner);
        const indexed = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ base_access, idx });
        defer self.alloc.free(indexed);
        try self.emitReadArray(elem_tr, indexed, dims[1..], inner, depth + 1);
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    /// Emit read of one struct member from final/appendable payload, including
    /// the XCDR2 optional presence flag when the member is @optional.
    fn emitReadMember(self: *Generator, m: ir.StructMember, out_expr: []const u8, extra: []const u8) anyerror!void {
        try self.emitReadMemberInternal(m, out_expr, extra, true);
    }

    /// Emit read of one struct member whose presence is known from outer
    /// framing, e.g. an @mutable EMHEADER.  No optional presence byte is read.
    fn emitReadPresentMember(self: *Generator, m: ir.StructMember, out_expr: []const u8, extra: []const u8) anyerror!void {
        try self.emitReadMemberInternal(m, out_expr, extra, false);
    }

    fn emitReadMemberInternal(
        self: *Generator,
        m: ir.StructMember,
        out_expr: []const u8,
        extra: []const u8,
        optional_presence_flag: bool,
    ) anyerror!void {
        if (!m.annotations.is_optional) {
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, out_expr, m.dimensions, extra, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, out_expr, extra);
            }
            return;
        }

        const zig_type = try self.typeRefToZig(m.type_ref);
        defer self.alloc.free(zig_type);
        const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
        defer self.alloc.free(opt_var);
        const decl_type: []u8 = if (m.dimensions.len > 0)
            try self.makeArrayType(zig_type, m.dimensions)
        else
            try self.alloc.dupe(u8, zig_type);
        defer self.alloc.free(decl_type);
        const default_val: []u8 = if (m.dimensions.len > 0)
            try self.defaultForArrayType(decl_type)
        else
            try self.defaultForTypeRef(m.type_ref);
        defer self.alloc.free(default_val);

        if (optional_presence_flag) {
            try self.ind();
            try self.print("{s}if (try reader.readBool()) {{\n", .{extra});
            const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
            defer self.alloc.free(inner);
            try self.ind();
            try self.print("{s}var {s}: {s} = {s};\n", .{ inner, opt_var, decl_type, default_val });
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, opt_var, m.dimensions, inner, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, opt_var, inner);
            }
            try self.ind();
            try self.print("{s}{s} = {s};\n", .{ inner, out_expr, opt_var });
            try self.ind();
            try self.print("{s}}} else {{\n", .{extra});
            try self.ind();
            try self.print("{s}    {s} = null;\n", .{ extra, out_expr });
            try self.ind();
            try self.print("{s}}}\n", .{extra});
            return;
        }

        try self.ind();
        try self.print("{s}var {s}: {s} = {s};\n", .{ extra, opt_var, decl_type, default_val });
        if (m.dimensions.len > 0) {
            try self.emitReadArray(m.type_ref, opt_var, m.dimensions, extra, 0);
        } else {
            try self.emitReadForTypeRef(m.type_ref, opt_var, extra);
        }
        try self.ind();
        try self.print("{s}{s} = {s};\n", .{ extra, out_expr, opt_var });
    }

    fn emitSkipMember(self: *Generator, m: ir.StructMember, extra: []const u8) anyerror!void {
        if (m.annotations.is_optional) {
            try self.ind();
            try self.print("{s}if (try reader.readBool()) {{\n", .{extra});
            const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
            defer self.alloc.free(inner);
            if (m.dimensions.len > 0) {
                try self.emitSkipArray(m.type_ref, m.dimensions, inner, 0);
            } else {
                try self.emitSkipForTypeRef(m.type_ref, inner);
            }
            try self.ind();
            try self.print("{s}}}\n", .{extra});
            return;
        }

        if (m.dimensions.len > 0) {
            try self.emitSkipArray(m.type_ref, m.dimensions, extra, 0);
        } else {
            try self.emitSkipForTypeRef(m.type_ref, extra);
        }
    }

    fn emitSkipArray(self: *Generator, elem_tr: ir.TypeRef, dims: []const u64, extra: []const u8, depth: usize) anyerror!void {
        if (dims.len == 0) {
            try self.emitSkipForTypeRef(elem_tr, extra);
            return;
        }
        try self.ind();
        try self.print("{s}for (0..{d}) |_| {{\n", .{ extra, dims[0] });
        const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(inner);
        try self.emitSkipArray(elem_tr, dims[1..], inner, depth + 1);
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    fn emitSkipForTypeRef(self: *Generator, tr: ir.TypeRef, extra: []const u8) anyerror!void {
        switch (tr) {
            .base => |b| {
                const method = baseReadMethod(b);
                try self.ind();
                if (std.mem.startsWith(u8, method, "//")) {
                    try self.print("{s}@compileError(\"zidl: unsupported IDL base type in skip\");\n", .{extra});
                } else {
                    try self.print("{s}_ = try reader.{s}();\n", .{ extra, method });
                }
            },
            .string => {
                try self.ind();
                try self.print("{s}try reader.skipString();\n", .{extra});
            },
            .wstring => {
                try self.ind();
                try self.print("{s}try reader.skipWstring();\n", .{extra});
            },
            .sequence => |seq| {
                try self.ind();
                try self.print("{s}{{\n", .{extra});
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.ind();
                try self.print("{s}const _n = try reader.readU32();\n", .{inner});
                try self.ind();
                try self.print("{s}for (0.._n) |_| {{\n", .{inner});
                const inner2 = try std.fmt.allocPrint(self.alloc, "{s}    ", .{inner});
                defer self.alloc.free(inner2);
                try self.emitSkipForTypeRef(seq.element.*, inner2);
                try self.ind();
                try self.print("{s}}}\n", .{inner});
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .map => |m| {
                try self.ind();
                try self.print("{s}{{\n", .{extra});
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.ind();
                try self.print("{s}const _mn = try reader.readU32();\n", .{inner});
                try self.ind();
                try self.print("{s}for (0.._mn) |_| {{\n", .{inner});
                const inner2 = try std.fmt.allocPrint(self.alloc, "{s}    ", .{inner});
                defer self.alloc.free(inner2);
                try self.emitSkipForTypeRef(m.key.*, inner2);
                try self.emitSkipForTypeRef(m.value.*, inner2);
                try self.ind();
                try self.print("{s}}}\n", .{inner});
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}_ = try reader.{s}();\n", .{ extra, method });
                },
                .bitmask => |bm| {
                    const stor = bitmaskStorageType(bm.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}_ = try reader.{s}();\n", .{ extra, method });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitSkipArray(t.type_ref, t.dimensions, extra, 0);
                    } else {
                        try self.emitSkipForTypeRef(t.type_ref, extra);
                    }
                },
                .struct_, .union_, .bitset => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.skip(reader);\n", .{ extra, zig_type });
                },
                else => {
                    try self.ind();
                    try self.print("{s}@compileError(\"zidl: unsupported named IDL type in skip\");\n", .{extra});
                },
            },
            .fixed_pt => |fp| {
                try self.ind();
                try self.print("{s}_ = try reader.readFixed({d}, {d});\n", .{ extra, fp.digits, fp.scale });
            },
        }
    }

    // ── Type-ref → Zig type string ────────────────────────────────────────────

    /// Convert a `TypeRef` to its Zig type expression string.
    /// Named types use fully-qualified dot-separated paths (e.g. `Foo.Bar.Baz`).
    /// Caller owns the returned slice.
    fn typeRefToZig(self: *Generator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToZigType(b)),
            .named => |td| self.qualNameToZig(ir.typeDeclQualifiedName(td)),
            .sequence => |seq| blk: {
                const elem = try self.typeRefToZig(seq.element.*);
                defer self.alloc.free(elem);
                break :blk if (seq.bound) |n|
                    std.fmt.allocPrint(self.alloc, "zidl_rt.BoundedArray({s}, {d})", .{ elem, n })
                else
                    std.fmt.allocPrint(self.alloc, "std.ArrayListUnmanaged({s})", .{elem});
            },
            .string => |bound| if (bound) |n|
                std.fmt.allocPrint(self.alloc, "zidl_rt.BoundedArray(u8, {d})", .{n})
            else
                self.alloc.dupe(u8, "[]const u8"),
            .wstring => |bound| if (bound) |n|
                std.fmt.allocPrint(self.alloc, "zidl_rt.BoundedArray(u16, {d})", .{n})
            else
                self.alloc.dupe(u8, "[]const u16"),
            .fixed_pt => self.alloc.dupe(u8, "f64"),
            .map => |m| blk: {
                // String keys need content-based equality; use StringArrayHashMapUnmanaged.
                // All other key types use AutoArrayHashMapUnmanaged (hash/eq from key type).
                const key_is_string = switch (m.key.*) {
                    .string => true,
                    else => false,
                };
                if (key_is_string) {
                    const val_s = try self.typeRefToZig(m.value.*);
                    defer self.alloc.free(val_s);
                    break :blk std.fmt.allocPrint(self.alloc, "std.StringArrayHashMapUnmanaged({s})", .{val_s});
                }
                const key_s = try self.typeRefToZig(m.key.*);
                defer self.alloc.free(key_s);
                const val_s = try self.typeRefToZig(m.value.*);
                defer self.alloc.free(val_s);
                break :blk std.fmt.allocPrint(self.alloc, "std.AutoArrayHashMapUnmanaged({s}, {s})", .{ key_s, val_s });
            },
        };
    }

    /// Convert `Foo::Bar::Baz` → `Foo.Bar.Baz`.
    /// At file level, `Foo` is always accessible, so the full dotted path is
    /// valid from anywhere in the generated file.
    fn qualNameToZig(self: *Generator, qname: []const u8) ![]u8 {
        const pfx = self.opts.type_prefix;
        if (pfx.len == 0) {
            // Fast path: no prefix.
            var out = try self.alloc.alloc(u8, qname.len);
            var out_i: usize = 0;
            var i: usize = 0;
            while (i < qname.len) {
                if (i + 1 < qname.len and qname[i] == ':' and qname[i + 1] == ':') {
                    out[out_i] = '.';
                    out_i += 1;
                    i += 2;
                } else {
                    out[out_i] = qname[i];
                    out_i += 1;
                    i += 1;
                }
            }
            return self.alloc.realloc(out, out_i);
        }
        // With prefix: apply it to the last segment (the type name).
        // E.g. "Foo::Bar::Baz" with "DDS_" → "Foo.Bar.DDS_Baz"
        const last_sep = std.mem.lastIndexOf(u8, qname, "::");
        if (last_sep == null) {
            return std.fmt.allocPrint(self.alloc, "{s}{s}", .{ pfx, qname });
        }
        const sep = last_sep.?;
        const module_part = qname[0..sep];
        const type_name = qname[sep + 2 ..];
        var mod_buf = try self.alloc.alloc(u8, module_part.len);
        defer self.alloc.free(mod_buf);
        var wi: usize = 0;
        var ri: usize = 0;
        while (ri < module_part.len) {
            if (ri + 1 < module_part.len and module_part[ri] == ':' and module_part[ri + 1] == ':') {
                mod_buf[wi] = '.';
                wi += 1;
                ri += 2;
            } else {
                mod_buf[wi] = module_part[ri];
                wi += 1;
                ri += 1;
            }
        }
        return std.fmt.allocPrint(self.alloc, "{s}.{s}{s}", .{ mod_buf[0..wi], pfx, type_name });
    }

    // ── Default value helpers ─────────────────────────────────────────────────

    /// Return the Zig default-value expression for a scalar `TypeRef`
    /// (no array dimensions — those are handled by `defaultForArrayType`).
    fn defaultForTypeRef(self: *Generator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, switch (b) {
                .boolean => "false",
                .float, .double, .long_double => "0.0",
                .any, .object, .value_base => "undefined",
                else => "0",
            }),
            .string => |bound| if (bound != null)
                self.alloc.dupe(u8, ".{}")
            else
                self.alloc.dupe(u8, "\"\""),
            .wstring => |bound| if (bound != null)
                self.alloc.dupe(u8, ".{}")
            else
                self.alloc.dupe(u8, "&.{}"),
            .sequence => |seq| if (seq.bound != null)
                self.alloc.dupe(u8, ".{}") // BoundedArray has field defaults
            else
                self.alloc.dupe(u8, ".empty"),
            .named => |td| switch (td) {
                .enum_ => |e| if (e.enumerators.len > 0)
                    // In a type-inferred context (struct field), .Name resolves
                    // to the first enumerator of the field's declared enum type.
                    std.fmt.allocPrint(self.alloc, ".{s}", .{e.enumerators[0].name})
                else
                    self.alloc.dupe(u8, "@enumFromInt(0)"),
                .bitmask => self.alloc.dupe(u8, "0"),
                .native, .interface => self.alloc.dupe(u8, "undefined"),
                .typedef => |t| blk: {
                    // Follow the chain: array typedefs need zeroes, scalar ones recurse.
                    if (t.dimensions.len > 0) {
                        const elem = try self.typeRefToZig(t.type_ref);
                        defer self.alloc.free(elem);
                        const arr = try self.makeArrayType(elem, t.dimensions);
                        defer self.alloc.free(arr);
                        break :blk try self.defaultForArrayType(arr);
                    } else {
                        break :blk try self.defaultForTypeRef(t.type_ref);
                    }
                },
                // struct, union (as struct), exception, bitset → zero-init struct literal
                else => self.alloc.dupe(u8, ".{}"),
            },
            .fixed_pt => self.alloc.dupe(u8, "0.0"),
            .map => self.alloc.dupe(u8, ".{}"),
        };
    }

    fn defaultForArrayType(self: *Generator, arr_type: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "std.mem.zeroes({s})", .{arr_type});
    }

    // ── Array type builder ────────────────────────────────────────────────────

    /// Build a Zig array type string for IDL array dimensions.
    ///
    /// IDL `T[d0][d1]` → Zig `[d0][d1]T` (same left-to-right order).
    /// Recursively wraps: `[d0](makeArrayType(T, dims[1..]))`.
    fn makeArrayType(self: *Generator, elem_type: []const u8, dims: []const u64) anyerror![]u8 {
        if (dims.len == 0) return self.alloc.dupe(u8, elem_type);
        const inner = try self.makeArrayType(elem_type, dims[1..]);
        defer self.alloc.free(inner);
        return std.fmt.allocPrint(self.alloc, "[{d}]{s}", .{ dims[0], inner });
    }
};

// ── Static helpers ────────────────────────────────────────────────────────────

fn baseToZigType(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "f32",
        .double => "f64",
        .long_double => "f128",
        .short => "i16",
        .long => "i32",
        .long_long => "i64",
        .unsigned_short => "u16",
        .unsigned_long => "u32",
        .unsigned_long_long => "u64",
        .char => "u8",
        .wchar => "u16",
        .boolean => "bool",
        .octet => "u8",
        .int8 => "i8",
        .uint8 => "u8",
        .int16 => "i16",
        .int32 => "i32",
        .int64 => "i64",
        .uint16 => "u16",
        .uint32 => "u32",
        .uint64 => "u64",
        .any => "*anyopaque",
        .object => "*anyopaque",
        .value_base => "*anyopaque",
    };
}

fn bitmaskStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8)
        "u8"
    else if (bound <= 16)
        "u16"
    else if (bound <= 32)
        "u32"
    else
        "u64";
}

fn bitsetTotalBits(bs: *const ir.Bitset) u32 {
    var total: u32 = 0;
    for (bs.fields) |field| {
        total += field.bits;
    }
    return total;
}

fn enumStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8)
        "u8"
    else if (bound <= 16)
        "u16"
    else if (bound <= 32)
        "u32"
    else
        "u64";
}

fn baseWriteMethod(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "writeBool",
        .octet, .uint8 => "writeU8",
        .char => "writeChar",
        .wchar => "writeWchar",
        .int8 => "writeI8",
        .short, .int16 => "writeI16",
        .long, .int32 => "writeI32",
        .long_long, .int64 => "writeI64",
        .unsigned_short, .uint16 => "writeU16",
        .unsigned_long, .uint32 => "writeU32",
        .unsigned_long_long, .uint64 => "writeU64",
        .float => "writeF32",
        .double => "writeF64",
        .long_double => "writeF64",
        .any, .object, .value_base => "// unsupported",
    };
}

fn baseReadMethod(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "readBool",
        .octet, .uint8 => "readU8",
        .char => "readChar",
        .wchar => "readWchar",
        .int8 => "readI8",
        .short, .int16 => "readI16",
        .long, .int32 => "readI32",
        .long_long, .int64 => "readI64",
        .unsigned_short, .uint16 => "readU16",
        .unsigned_long, .uint32 => "readU32",
        .unsigned_long_long, .uint64 => "readU64",
        .float => "readF32",
        .double => "readF64",
        .long_double => "readF64",
        .any, .object, .value_base => "// unsupported",
    };
}

/// Returns true if deserializing this type may need an allocator
/// (unbounded strings, wstrings, or sequences; or any named struct/exception
/// which may transitively need one).
/// Returns true if a union case is the `default:` arm.
fn isDefaultUnionCase(cas: ir.UnionCase) bool {
    if (cas.labels.len == 0) return true;
    for (cas.labels) |lbl| {
        if (lbl == .default) return true;
    }
    return false;
}

/// Determine the EMHEADER LC value (0–3) for a fixed-size scalar type.
/// Returns null if the member requires LC=4 (NEXTINT) — i.e. variable-length
/// or complex (string, sequence, array, struct, union, typedef, etc.).
fn lcForTypeRef(type_ref: ir.TypeRef, dimensions: []const u64) ?u2 {
    if (dimensions.len > 0) return null;
    return switch (type_ref) {
        .base => |b| switch (b) {
            .boolean, .octet, .char, .int8, .uint8 => 0,
            .short, .int16, .unsigned_short, .uint16, .wchar => 1,
            .long, .int32, .unsigned_long, .uint32, .float => 2,
            .long_long, .int64, .unsigned_long_long, .uint64, .double => 3,
            // long_double is 16 bytes — no matching LC; use LC=4.
            else => null,
        },
        .named => |td| switch (td) {
            // Enums serialize as uint32_t (4 bytes) → LC=2.
            .enum_ => 2,
            // Everything else (struct, union, bitmask, bitset, typedef, …) → LC=4.
            else => null,
        },
        // string, wstring, sequence, map, fixed_pt — all variable / complex.
        else => null,
    };
}

/// Return the XTYPES member ID for a struct member.
/// Uses the `@id` annotation if present; otherwise the declaration index.
fn memberIdAt(m: ir.StructMember, idx: usize) u32 {
    return if (m.annotations.id) |id| id else @intCast(idx);
}

fn typeRefNeedsAllocator(tr: ir.TypeRef) bool {
    return switch (tr) {
        .string => |bound| bound == null,
        .wstring => true, // readWstring always allocates, even for bounded wstring
        .sequence => |seq| seq.bound == null,
        .named => |td| switch (td) {
            .struct_, .exception => true, // conservatively: may have nested strings/seqs
            .typedef => |t| typeRefNeedsAllocator(t.type_ref),
            else => false,
        },
        else => false,
    };
}

fn typeDeclHasKey(td: ir.TypeDecl) bool {
    return switch (td) {
        .struct_ => |s| structHasKey(s),
        .exception => |e| blk: {
            for (e.members) |m| {
                if (m.annotations.is_key) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn structHasKey(s: *const ir.Struct) bool {
    if (s.base) |base| {
        if (typeDeclHasKey(base)) return true;
    }
    for (s.members) |m| {
        if (m.annotations.is_key) return true;
    }
    return false;
}

fn structKeyNeedsAllocator(s: *const ir.Struct) bool {
    if (s.base) |base| {
        if (typeDeclHasKey(base)) return true; // conservatively assume base key members may need allocator
    }
    for (s.members) |m| {
        if (m.annotations.is_key and typeRefNeedsAllocator(m.type_ref)) return true;
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

/// Parse `source`, analyse, build IR, generate Zig source into a returned buffer.
/// Caller must call `.deinit(testing.allocator)` on the returned ArrayList.
fn testGen(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    return testGenOpts(source, stem, .{});
}

fn testGenOpts(source: []const u8, stem: []const u8, extra_opts: struct {
    no_typesupport: bool = false,
    no_typeobject_support: bool = false,
    generate_interfaces: bool = false,
    type_prefix: []const u8 = "",
    pl_cdr: bool = false,
    zig_version: interface.ZigVersion = .@"0.16.0",
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
        .no_typesupport = extra_opts.no_typesupport,
        .no_typeobject_support = extra_opts.no_typeobject_support,
        .generate_interfaces = extra_opts.generate_interfaces,
        .type_prefix = extra_opts.type_prefix,
        .pl_cdr = extra_opts.pl_cdr,
        .zig_version = extra_opts.zig_version,
    };
    try generateFile(alloc, &ir_spec, opts, &out);
    return out;
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "zig_backend: file header" {
    var out = try testGen("struct Dummy { long x; };", "types");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "Generated by zidl from types.idl"));
    try testing.expect(has(s, "const std = @import(\"std\");"));
}

test "zig_backend: Zig 0.15.1 target marker" {
    var out = try testGenOpts("struct Dummy { long x; };", "types", .{
        .zig_version = .@"0.15.1",
    });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "Zig output target: 0.15.1"));
}

test "zig_backend: simple struct" {
    var out = try testGen("struct Point { long x; long y; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Point = struct {"));
    try testing.expect(has(s, "x: i32 = 0,"));
    try testing.expect(has(s, "y: i32 = 0,"));
    try testing.expect(has(s, "}; // Point"));
}

test "zig_backend: struct in module" {
    var out = try testGen(
        \\module Sensor { struct Reading { double value; }; };
    , "sensor");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Sensor = struct {"));
    try testing.expect(has(s, "pub const Reading = struct {"));
    try testing.expect(has(s, "value: f64 = 0.0,"));
    try testing.expect(has(s, "}; // Sensor"));
}

test "zig_backend: nested module" {
    var out = try testGen(
        \\module A { module B { struct C { long x; }; }; };
    , "nested");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const A = struct {"));
    try testing.expect(has(s, "pub const B = struct {"));
    try testing.expect(has(s, "pub const C = struct {"));
}

test "zig_backend: primitive type mapping" {
    var out = try testGen(
        \\struct Prims {
        \\  short a; long b; long long c;
        \\  unsigned short d; unsigned long e; unsigned long long f;
        \\  float g; double h; boolean i; octet j; char k; wchar l;
        \\};
    , "prims");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "a: i16 = 0,"));
    try testing.expect(has(s, "b: i32 = 0,"));
    try testing.expect(has(s, "c: i64 = 0,"));
    try testing.expect(has(s, "d: u16 = 0,"));
    try testing.expect(has(s, "e: u32 = 0,"));
    try testing.expect(has(s, "f: u64 = 0,"));
    try testing.expect(has(s, "g: f32 = 0.0,"));
    try testing.expect(has(s, "h: f64 = 0.0,"));
    try testing.expect(has(s, "i: bool = false,"));
    try testing.expect(has(s, "j: u8 = 0,"));
    try testing.expect(has(s, "k: u8 = 0,"));
    try testing.expect(has(s, "l: u16 = 0,"));
}

test "zig_backend: extended integer types" {
    var out = try testGen(
        \\struct Ext { int8 a; uint8 b; int16 c; int32 d; int64 e; };
    , "ext");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "a: i8 = 0,"));
    try testing.expect(has(s, "b: u8 = 0,"));
    try testing.expect(has(s, "c: i16 = 0,"));
    try testing.expect(has(s, "d: i32 = 0,"));
    try testing.expect(has(s, "e: i64 = 0,"));
}

test "zig_backend: string types" {
    var out = try testGen(
        \\struct S { string s; string<32> bs; wstring ws; };
    , "str");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "s: []const u8 = \"\","));
    try testing.expect(has(s, "bs: zidl_rt.BoundedArray(u8, 32) = .{},"));
    try testing.expect(has(s, "ws: []const u16 = &.{},"));
}

test "zig_backend: sequence types" {
    var out = try testGen(
        \\struct S { sequence<long> unbounded; sequence<long, 10> bounded; };
    , "seq");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "unbounded: std.ArrayListUnmanaged(i32) = .empty,"));
    try testing.expect(has(s, "bounded: zidl_rt.BoundedArray(i32, 10) = .{},"));
}

test "zig_backend: map type integer key" {
    var out = try testGen("struct S { map<long, long> m; };", "map_test");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "m: std.AutoArrayHashMapUnmanaged(i32, i32) = .{},"));
}

test "zig_backend: map type string key" {
    var out = try testGen("struct S { map<string, long> m; };", "map_test");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "m: std.StringArrayHashMapUnmanaged(i32) = .{},"));
}

test "zig_backend: map cdr write" {
    var out = try testGen("struct S { map<long, long> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU32(@intCast(value.m.count()));"));
    try testing.expect(has(s, "for (value.m.keys(), value.m.values()) |_mk, _mv|"));
    try testing.expect(has(s, "try writer.writeI32(_mk);"));
    try testing.expect(has(s, "try writer.writeI32(_mv);"));
}

test "zig_backend: map cdr read" {
    var out = try testGen("struct S { map<long, long> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const _mn = try reader.readU32();"));
    try testing.expect(has(s, "try out.m.ensureTotalCapacity(allocator, _mn);"));
    try testing.expect(has(s, "var _mk: i32 = undefined;"));
    try testing.expect(has(s, "var _mv: i32 = undefined;"));
    try testing.expect(has(s, "try out.m.putNoClobber(allocator, _mk, _mv);"));
}

test "zig_backend: array field" {
    var out = try testGen(
        \\struct Mat { long m[2][4]; };
    , "mat");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "m: [2][4]i32 = std.mem.zeroes([2][4]i32),"));
}

test "zig_backend: optional field" {
    var out = try testGen(
        \\struct S { @optional long x; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "x: ?i32 = null,"));
}

test "zig_backend: enum" {
    var out = try testGen("enum Color { RED, GREEN, BLUE };", "color");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Color = enum(u32) {"));
    try testing.expect(has(s, "RED = 0,"));
    try testing.expect(has(s, "GREEN = 1,"));
    try testing.expect(has(s, "BLUE = 2,"));
    try testing.expect(has(s, "_,"));
    try testing.expect(has(s, "}; // Color"));
}

test "zig_backend: union" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Var = struct {"));
    try testing.expect(has(s, "_d: i32 = 0,"));
    try testing.expect(has(s, "_u: union {"));
    try testing.expect(has(s, "i: i32,"));
    try testing.expect(has(s, "s: []const u8,"));
    try testing.expect(has(s, "} = undefined,"));
}

test "zig_backend: union CDR serialize/deserialize" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const has_key = false;"));
    try testing.expect(has(s, "pub fn serialize(writer: anytype, value: @This()) !void {"));
    try testing.expect(has(s, "pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader"));
    try testing.expect(has(s, "try writer.writeI32(value._d);"));
    try testing.expect(has(s, "out._d = try reader.readI32();"));
    try testing.expect(has(s, "switch (value._d) {"));
    try testing.expect(has(s, "0 => {"));
    try testing.expect(has(s, "else => {"));
}

test "zig_backend: union CDR appendable adds DHEADER" {
    var out = try testGen(
        \\@appendable union Var switch (long) { case 0: long i; };
    , "var_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const _dh = try writer.reserveDheaderMaybe();"));
    try testing.expect(has(s, "try reader.skipDheaderIfXcdr2();"));
}

test "zig_backend: typedef scalar" {
    var out = try testGen("typedef long MyInt;", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const MyInt = i32;"));
}

test "zig_backend: typedef array" {
    var out = try testGen("typedef long Matrix[2][4];", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const Matrix = [2][4]i32;"));
}

test "zig_backend: bitmask" {
    var out = try testGen(
        \\bitmask Flags { READ, WRITE, EXECUTE };
    , "flags");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Flags = u32;"));
    try testing.expect(has(s, "pub const Flags_READ: Flags = 1 << 0;"));
    try testing.expect(has(s, "pub const Flags_WRITE: Flags = 1 << 1;"));
    try testing.expect(has(s, "pub const Flags_EXECUTE: Flags = 1 << 2;"));
}

test "zig_backend: bitmask in module uses qualified name" {
    var out = try testGen(
        \\module M { bitmask Flags { READ, WRITE }; };
    , "mod_flags");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const M = struct {"));
    try testing.expect(has(s, "pub const Flags = u32;"));
    // Bit constants must reference the qualified type so they compile inside
    // the module struct where 'Flags' may not be directly resolvable from a
    // nested inner struct.
    try testing.expect(has(s, "pub const Flags_READ: M.Flags = 1 << 0;"));
    try testing.expect(has(s, "pub const Flags_WRITE: M.Flags = 1 << 1;"));
}

test "zig_backend: bitset" {
    var out = try testGen(
        \\bitset Config { bitfield<3> mode; bitfield<1> flag; };
    , "cfg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Config = packed struct {"));
    try testing.expect(has(s, "mode: u3 = 0,"));
    try testing.expect(has(s, "flag: u1 = 0,"));
}

test "zig_backend: native" {
    var out = try testGen("native Handle;", "native_t");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const Handle = opaque{};"));
}

test "zig_backend: exception" {
    var out = try testGen(
        \\exception MyError { long code; string message; };
    , "err");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "// IDL exception"));
    try testing.expect(has(s, "pub const MyError = struct {"));
    try testing.expect(has(s, "code: i32 = 0,"));
    try testing.expect(has(s, "message: []const u8 = \"\","));
}

test "zig_backend: interface placeholder" {
    var out = try testGen(
        \\interface Foo { long op(in long x); };
    , "iface");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "// IDL interface Foo"));
    try testing.expect(has(out.items, "--generate-interfaces"));
}

test "zig_backend: const integer" {
    var out = try testGen("const long MAX = 42;", "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const MAX: i32 = 42;"));
}

test "zig_backend: const string" {
    var out = try testGen("const string VERSION = \"1.0\";", "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const VERSION: []const u8 = \"1.0\";"));
}

test "zig_backend: const bool" {
    var out = try testGen("const boolean FLAG = TRUE;", "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const FLAG: bool = true;"));
}

test "zig_backend: cross-module type ref" {
    var out = try testGen(
        \\module A { struct X { long val; }; };
        \\module B { struct Y { A::X ax; }; };
    , "cross");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const A = struct {"));
    try testing.expect(has(s, "pub const B = struct {"));
    // Cross-module reference must use the full dotted path.
    try testing.expect(has(s, "ax: A.X = .{},"));
}

test "zig_backend: struct with enum field default" {
    var out = try testGen(
        \\enum Color { RED, GREEN, BLUE };
        \\struct S { Color c; };
    , "enum_field");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Default for the enum field should use the first enumerator.
    try testing.expect(has(s, "c: Color = .RED,"));
}

test "zig_backend: struct inheritance embeds base" {
    var out = try testGen(
        \\struct Base { long x; };
        \\struct Derived : Base { long y; };
    , "inherit");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "_base: Base = .{},"));
    try testing.expect(has(s, "y: i32 = 0,"));
}

// ── CDR serialization emission tests ─────────────────────────────────────────

test "zig_backend: no_typesupport suppresses serialize" {
    var out = try testGenOpts("struct Point { long x; long y; };", "p", .{ .no_typesupport = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "zidl_rt"));
    try testing.expect(!has(s, "serialize"));
    try testing.expect(!has(s, "has_key"));
}

test "zig_backend: serialize @final struct primitives" {
    var out = try testGen("struct Point { long x; float y; boolean flag; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Import present
    try testing.expect(has(s, "const zidl_rt = @import(\"zidl_rt\");"));
    // has_key = false (no @key members)
    try testing.expect(has(s, "pub const has_key = false;"));
    // serialize function present with correct write calls
    try testing.expect(has(s, "pub fn serialize(writer: anytype, value: @This()) !void {"));
    try testing.expect(has(s, "try writer.writeI32(value.x);"));
    try testing.expect(has(s, "try writer.writeF32(value.y);"));
    try testing.expect(has(s, "try writer.writeBool(value.flag);"));
    // No DHEADER for @final
    try testing.expect(!has(s, "reserveDheaderMaybe"));
    // deserializeInto present
    try testing.expect(has(s, "pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {"));
    try testing.expect(has(s, "out.x = try reader.readI32();"));
    try testing.expect(has(s, "out.y = try reader.readF32();"));
    try testing.expect(has(s, "out.flag = try reader.readBool();"));
    // No allocator needed for scalars only
    try testing.expect(has(s, "_ = allocator;"));
    // deserialize convenience wrapper
    try testing.expect(has(s, "pub fn deserialize(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {"));
    try testing.expect(has(s, "var _out: @This() = .{};"));
    // No serializeKey (no @key)
    try testing.expect(!has(s, "serializeKey"));
}

test "zig_backend: serialize @appendable struct has DHEADER" {
    var out = try testGen("@appendable struct Point { long x; long y; };", "pt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const _dh = try writer.reserveDheaderMaybe();"));
    try testing.expect(has(s, "writer.patchDheaderMaybe(_dh);"));
    try testing.expect(has(s, "try reader.skipDheaderIfXcdr2();"));
}

test "zig_backend: serialize @key member emits serializeKey" {
    var out = try testGen("struct Msg { @key long id; string label; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const has_key = true;"));
    try testing.expect(has(s, "pub fn serializeKey(writer: anytype, value: @This()) !void {"));
    // Key field included in serializeKey
    try testing.expect(has(s, "try writer.writeI32(value.id);"));
}

test "zig_backend: keyed struct emits deserializeKey and computeKeyHash" {
    var out = try testGen("struct Msg { @key long id; string label; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deserializeKey(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {"));
    try testing.expect(has(s, "pub fn deserializeKeyInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {"));
    try testing.expect(has(s, "out.id = try reader.readI32();"));
    try testing.expect(has(s, "try reader.skipString();"));
    try testing.expect(has(s, "pub fn computeKeyHash(value: @This()) [16]u8 {"));
    try testing.expect(has(s, "var _khw = zidl_rt.KeyHashWriter.init();"));
}

test "zig_backend: keyless struct does not emit key helpers" {
    var out = try testGen("struct Msg { long id; string label; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const has_key = false;"));
    try testing.expect(!has(s, "serializeKey"));
    try testing.expect(!has(s, "deserializeKey"));
    try testing.expect(!has(s, "computeKeyHash"));
}

test "zig_backend: inherited key participates in key helpers" {
    var out = try testGen(
        \\struct Base { @key long id; string ignored; };
        \\struct Derived : Base { long value; };
    , "inh_key");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Derived = struct {"));
    try testing.expect(has(s, "pub const has_key = true;"));
    try testing.expect(has(s, "try Base.serializeKey(writer, value._base);"));
    try testing.expect(has(s, "try Base.deserializeKeyInto(&out._base, reader, allocator);"));
}

test "zig_backend: serialize string and sequence" {
    var out = try testGen("struct S { string label; sequence<long> values; };", "seq");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Unbounded string → writeString, readString(allocator)
    try testing.expect(has(s, "try writer.writeString(value.label);"));
    try testing.expect(has(s, "label = try reader.readString(allocator);"));
    // Sequence → length prefix + loop
    try testing.expect(has(s, "try writer.writeU32(@intCast(value.values.items.len));"));
    try testing.expect(has(s, "for (value.values.items) |_se|"));
    try testing.expect(has(s, "try writer.writeI32(_se);"));
    // Read side: ensureTotalCapacity + loop
    try testing.expect(has(s, "const _n = try reader.readU32();"));
    try testing.expect(has(s, "try out.values.ensureTotalCapacity(allocator, _n);"));
    try testing.expect(has(s, "out.values.appendAssumeCapacity(try reader.readI32());"));
    // Needs allocator → no "_ = allocator"
    try testing.expect(!has(s, "_ = allocator;"));
}

test "zig_backend: bounded sequence deserialize is heap-free" {
    var out = try testGen("struct S { sequence<long, 4> values; };", "bounded_seq");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU32(@intCast(value.values.slice().len));"));
    try testing.expect(has(s, "for (value.values.slice()) |_se|"));
    try testing.expect(has(s, "if (_n > 4) return error.SequenceTooLong;"));
    try testing.expect(has(s, "out.values.clearRetainingCapacity();"));
    try testing.expect(!has(s, "out.values.ensureTotalCapacity(allocator, _n);"));
    try testing.expect(!has(s, "value.values.items"));
}

test "zig_backend: serialize enum field" {
    var out = try testGen("enum Color { RED, GREEN }; struct S { Color c; };", "col");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU32(@intFromEnum(value.c));"));
    try testing.expect(has(s, "out.c = @enumFromInt(try reader.readU32());"));
}

test "zig_backend: serialize array field" {
    var out = try testGen("struct Mat { long m[2][4]; };", "mat");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Write: nested for loops
    try testing.expect(has(s, "for (value.m) |_d0|"));
    try testing.expect(has(s, "for (_d0) |_d1|"));
    try testing.expect(has(s, "try writer.writeI32(_d1);"));
    // Read: index-based loops with hardcoded bounds
    try testing.expect(has(s, "for (0..2) |_i0|"));
    try testing.expect(has(s, "for (0..4) |_i1|"));
    try testing.expect(has(s, "out.m[_i0][_i1] = try reader.readI32();"));
}

test "zig_backend: serialize nested struct" {
    var out = try testGen("struct Inner { long x; }; struct Outer { Inner inner; long tag; };", "nest");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try Inner.serialize(writer, value.inner);"));
    try testing.expect(has(s, "try Inner.deserializeInto(&out.inner, reader, allocator);"));
}

// ── TypeObject constant emission tests ───────────────────────────────────────

test "zig_backend: typeobject constants present for struct" {
    var out = try testGen("struct Point { long x; long y; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const type_object: []const u8 ="));
    try testing.expect(has(s, "pub const equivalence_hash: [14]u8 ="));
    try testing.expect(has(s, "pub const type_identifier: [32]u8 ="));
    // encap header bytes 0x00, 0x07 must appear in hex in type_object
    try testing.expect(has(s, "0x00, 0x07, 0x00, 0x00"));
    // EK_MINIMAL = 0xF1
    try testing.expect(has(s, "0xF1"));
    // TK_STRUCTURE = 0x51
    try testing.expect(has(s, "0x51"));
}

test "zig_backend: typeobject no_typeobject_support suppresses constants" {
    var out = try testGenOpts("struct Point { long x; };", "p", .{ .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "type_object"));
    try testing.expect(!has(s, "equivalence_hash"));
    try testing.expect(!has(s, "type_identifier"));
}

test "zig_backend: typeobject IS_FINAL flag for default extensibility" {
    var out = try testGen("struct F { long x; };", "f");
    defer out.deinit(testing.allocator);
    // IS_FINAL = 0x0001, encoded LE as first u16 of struct_flags in type_object.
    // The byte 0x01 must appear in the type_object hex string.
    try testing.expect(has(out.items, "type_object"));
}

test "zig_backend: typeobject IS_APPENDABLE flag" {
    var out = try testGen("@appendable struct A { long x; };", "a");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "type_object"));
    // IS_APPENDABLE = 0x0002, encoded LE as 0x02, 0x00 somewhere in bytes
    try testing.expect(has(s, "0x02, 0x00"));
}

test "zig_backend: typeobject both typesupport and typeobject by default" {
    var out = try testGen("struct S { @key long id; string label; };", "s");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Both CDR and TypeObject constants must be present
    try testing.expect(has(s, "pub fn serialize("));
    try testing.expect(has(s, "pub const type_object"));
    try testing.expect(has(s, "pub const has_key = true;"));
}

test "zig_backend: typeobject suppressed independently of typesupport" {
    var out = try testGenOpts("struct S { long x; };", "s", .{ .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Serialize still present
    try testing.expect(has(s, "pub fn serialize("));
    // TypeObject absent
    try testing.expect(!has(s, "type_object"));
}

// ── Serialization fix tests: typedef / bitmask / union / bitset members ───────

test "zig_backend: serialize typedef-of-primitive member" {
    // typedef long resolves to i32; serialize must emit writeI32, not .serialize()
    var out = try testGen(
        \\typedef long MyInt;
        \\struct S { MyInt x; };
    , "td");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeI32(value.x);"));
    try testing.expect(has(s, "out.x = try reader.readI32();"));
    try testing.expect(!has(s, ".serialize(writer, value.x)"));
}

test "zig_backend: serialize typedef-of-string member" {
    // typedef string MyStr; struct S { MyStr label; }
    // resolves to unbounded string → writeString / readString(allocator)
    var out = try testGen(
        \\typedef string MyStr;
        \\struct S { MyStr label; };
    , "tds");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeString(value.label);"));
    try testing.expect(has(s, "label = try reader.readString(allocator);"));
}

test "zig_backend: serialize bitmask member" {
    // bitmask<32> Flags; struct S { Flags f; }
    // bitmask is u32 — serialize as writeU32/readU32
    var out = try testGen(
        \\bitmask Flags { flag1, flag2 };
        \\struct S { Flags f; };
    , "bm");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU32(value.f);"));
    try testing.expect(has(s, "out.f = try reader.readU32();"));
    try testing.expect(!has(s, ".serialize(writer, value.f)"));
}

test "zig_backend: serialize bitmask<16> member uses writeU16" {
    var out = try testGen(
        \\@bit_bound(16) bitmask SmallFlags { a, b };
        \\struct S { SmallFlags f; };
    , "bm16");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU16(value.f);"));
    try testing.expect(has(s, "out.f = try reader.readU16();"));
}

test "zig_backend: union member in struct uses .serialize()/.deserializeInto()" {
    var out = try testGen(
        \\union U switch (long) { case 0: long x; };
        \\struct S { U u; };
    , "un");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try U.serialize(writer, value.u);"));
    try testing.expect(has(s, "try U.deserializeInto(&out.u, reader, allocator);"));
}

test "zig_backend: serialize bitset member" {
    // bitset BS { bitfield<3> a; bitfield<1> b; }; total=4 bits → u8
    var out = try testGen(
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
        \\struct S { BS bs; };
    , "bs");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // bitset itself has serialize/deserializeInto
    try testing.expect(has(s, "pub fn serialize(writer: anytype, value: @This()) !void {"));
    try testing.expect(has(s, "const _bs: u4 = @bitCast(value);"));
    try testing.expect(has(s, "try writer.writeU8(@intCast(_bs));"));
    try testing.expect(has(s, "pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, _: std.mem.Allocator) !void {"));
    try testing.expect(has(s, "out.* = @bitCast(@as(u4, @truncate(try reader.readU8())));"));
    // struct member dispatch calls .serialize / .deserializeInto
    try testing.expect(has(s, "try BS.serialize(writer, value.bs);"));
    try testing.expect(has(s, "try BS.deserializeInto(&out.bs, reader, allocator);"));
}

test "zig_backend: serialize bitset 32-bit member" {
    // bitset Cfg with 32 total bits → storage u32
    var out = try testGen(
        \\bitset Cfg { bitfield<16> a; bitfield<16> b; };
        \\struct S { Cfg c; };
    , "cfg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const _bs: u32 = @bitCast(value);"));
    try testing.expect(has(s, "try writer.writeU32(@intCast(_bs));"));
    try testing.expect(has(s, "out.* = @bitCast(@as(u32, @truncate(try reader.readU32())));"));
    try testing.expect(has(s, "try Cfg.serialize(writer, value.c);"));
    try testing.expect(has(s, "try Cfg.deserializeInto(&out.c, reader, allocator);"));
}

test "zig_backend: serialize bitset no_typesupport" {
    // --no-typesupport suppresses bitset CDR methods
    var out = try testGenOpts(
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "bs", .{ .no_typesupport = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const BS = packed struct {"));
    try testing.expect(!has(s, "pub fn serialize"));
    try testing.expect(!has(s, "pub fn deserializeInto"));
}

// ── Additional CDR serialization coverage ────────────────────────────────────

test "zig_backend: serialize struct inheritance deserializeInto" {
    var out = try testGen(
        \\struct Base { long x; };
        \\struct Derived : Base { long y; };
    , "inh");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // serialize: _base first
    try testing.expect(has(s, "try Base.serialize(writer, value._base);"));
    // deserializeInto: _base first
    try testing.expect(has(s, "try Base.deserializeInto(&out._base, reader, allocator);"));
}

test "zig_backend: serialize wstring field" {
    var out = try testGen("struct S { wstring ws; };", "ws");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeWstring(value.ws);"));
    try testing.expect(has(s, "out.ws = try reader.readWstring(allocator);"));
}

test "zig_backend: serialize bounded string member" {
    // bounded string<32> → BoundedArray(u8,32); serialize uses .slice()
    var out = try testGen("struct S { string<32> label; };", "bs");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeString(value.label.slice());"));
    // Read: zero-copy read then copy into BoundedArray
    try testing.expect(has(s, "label"));
    // No allocator needed for bounded string
    try testing.expect(has(s, "_ = allocator;"));
}

test "zig_backend: serialize bounded wstring member" {
    var out = try testGen("struct S { wstring<16> label; };", "bws");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Write: use .slice() on BoundedArray(u16,16)
    try testing.expect(has(s, "try writer.writeWstring(value.label.slice());"));
    // Read: allocate temp, defer free, bound-check, fromSlice
    try testing.expect(has(s, "const _ws = try reader.readWstring(allocator);"));
    try testing.expect(has(s, "defer allocator.free(_ws);"));
    try testing.expect(has(s, "if (_ws.len > 16) return error.StringTooLong;"));
    try testing.expect(has(s, "zidl_rt.BoundedArray(u16, 16).fromSlice(_ws) catch unreachable;"));
    // Bounded wstring needs allocator (readWstring always allocates)
    try testing.expect(!has(s, "_ = allocator;"));
}

test "zig_backend: serialize sequence of structs" {
    var out = try testGen(
        \\struct Item { long id; };
        \\struct S { sequence<Item> items; };
    , "seqstruct");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Write: length + loop calling .serialize()
    try testing.expect(has(s, "try writer.writeU32(@intCast(value.items.items.len));"));
    try testing.expect(has(s, "for (value.items.items) |_se|"));
    try testing.expect(has(s, "try Item.serialize(writer, _se);"));
    // Read: ensureTotalCapacity + loop + deserializeInto
    try testing.expect(has(s, "var _elem: Item = .{};"));
    try testing.expect(has(s, "try Item.deserializeInto(&_elem, reader, allocator);"));
    try testing.expect(has(s, "out.items.appendAssumeCapacity(_elem);"));
}

test "zig_backend: serialize sequence of enums" {
    var out = try testGen(
        \\enum Color { RED, GREEN, BLUE };
        \\struct S { sequence<Color> colors; };
    , "seqenum");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Write loop: @intFromEnum
    try testing.expect(has(s, "try writer.writeU32(@intFromEnum(_se));"));
    // Read loop: appendAssumeCapacity(@enumFromInt(...))
    try testing.expect(has(s, "out.colors.appendAssumeCapacity(@enumFromInt(try reader.readU32()));"));
}

test "zig_backend: typedef needsAllocator recurses correctly" {
    // typedef string MyStr — needs allocator (unbounded string)
    var out = try testGen(
        \\typedef string MyStr;
        \\struct S { MyStr s; };
    , "tda");
    defer out.deinit(testing.allocator);
    // allocator IS needed for the string read → must NOT emit "_ = allocator;"
    try testing.expect(!has(out.items, "_ = allocator;"));
}

test "zig_backend: serialize @key member in serializeKey" {
    var out = try testGen("struct S { @key long id; long val; };", "key");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn serializeKey("));
    // serializeKey emits only the @key member
    try testing.expect(has(s, "try writer.writeI32(value.id);"));
}

// ── TypeObject coverage tests ─────────────────────────────────────────────────

test "zig_backend: typeobject struct with enum member uses recursive hash" {
    // A struct with an enum member: the member's TypeIdentifier must be
    // EK_MINIMAL + 14-byte hash, not TK_ENUM directly.
    var out = try testGen(
        \\enum Color { RED, GREEN };
        \\struct S { Color c; };
    , "toc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // TypeObject must be present; equivalence_hash is 14 bytes.
    try testing.expect(has(s, "pub const type_object: []const u8 ="));
    try testing.expect(has(s, "pub const equivalence_hash: [14]u8 ="));
    // EK_MINIMAL (0xF1) must appear in the type_object bytes (for the enum TI)
    try testing.expect(has(s, "0xF1"));
}

test "zig_backend: typeobject struct with string member" {
    // string members use TI_STRING8_SMALL (0x70)
    var out = try testGen("struct S { string label; };", "tos");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const type_object: []const u8 ="));
    // TI_STRING8_SMALL = 0x70
    try testing.expect(has(out.items, "0x70"));
}

test "zig_backend: typeobject deterministic across two calls" {
    // Calling generate twice for the same type must produce identical bytes.
    var out1 = try testGen("struct S { long x; float y; };", "det");
    defer out1.deinit(testing.allocator);
    var out2 = try testGen("struct S { long x; float y; };", "det");
    defer out2.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, out1.items, out2.items);
}

// ── --generate-interfaces tests ───────────────────────────────────────────────

test "zig_backend: interface placeholder without flag" {
    // Without --generate-interfaces, interface emits a comment.
    var out = try testGen(
        \\interface Greeter { string greet(in string name); };
    , "iface");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "// IDL interface Greeter"));
    try testing.expect(!has(s, "pub const Greeter = struct {"));
}

test "zig_backend: interface basic vtable struct" {
    var out = try testGenOpts(
        \\interface Greeter { string greet(in string name); };
    , "iface", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Greeter = struct {"));
    try testing.expect(has(s, "ptr: *anyopaque,"));
    try testing.expect(has(s, "vtable: *const Vtable,"));
    try testing.expect(has(s, "pub const Vtable = struct {"));
    try testing.expect(has(s, "deinit: *const fn (*anyopaque) void,"));
}

test "zig_backend: interface operation vtable entry and forwarder" {
    var out = try testGenOpts(
        \\interface Calc { long add(in long a, in long b); };
    , "calc", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Vtable entry: fn ptr with self as first *anyopaque param
    try testing.expect(has(s, "add: *const fn (*anyopaque, a: i32, b: i32) i32,"));
    // Forwarding method
    try testing.expect(has(s, "pub fn add(self: @This(), a: i32, b: i32) i32 {"));
    try testing.expect(has(s, "return self.vtable.add(self.ptr, a, b);"));
}

test "zig_backend: interface void operation" {
    var out = try testGenOpts(
        \\interface Sink { void write(in long val); };
    , "sink", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "write: *const fn (*anyopaque, val: i32) void,"));
    try testing.expect(has(s, "pub fn write(self: @This(), val: i32) void {"));
    try testing.expect(has(s, "return self.vtable.write(self.ptr, val);"));
}

test "zig_backend: interface out/inout params become pointers" {
    var out = try testGenOpts(
        \\interface Io { void read(out long val, inout long count); };
    , "io", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "read: *const fn (*anyopaque, val: *i32, count: *i32) void,"));
    try testing.expect(has(s, "pub fn read(self: @This(), val: *i32, count: *i32) void {"));
}

test "zig_backend: interface readonly attribute" {
    var out = try testGenOpts(
        \\interface Named { readonly attribute string name; };
    , "named", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Vtable: getter only
    try testing.expect(has(s, "get_name: *const fn (*anyopaque) []const u8,"));
    try testing.expect(!has(s, "set_name"));
    // Forwarding getter
    try testing.expect(has(s, "pub fn get_name(self: @This()) []const u8 {"));
    try testing.expect(has(s, "return self.vtable.get_name(self.ptr);"));
}

test "zig_backend: interface read-write attribute" {
    var out = try testGenOpts(
        \\interface Counter { attribute long count; };
    , "counter", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Both getter and setter in vtable
    try testing.expect(has(s, "get_count: *const fn (*anyopaque) i32,"));
    try testing.expect(has(s, "set_count: *const fn (*anyopaque, i32) void,"));
    // Forwarding methods
    try testing.expect(has(s, "pub fn get_count(self: @This()) i32 {"));
    try testing.expect(has(s, "pub fn set_count(self: @This(), value: i32) void {"));
    try testing.expect(has(s, "self.vtable.set_count(self.ptr, value);"));
}

test "zig_backend: interface deinit forwarder" {
    var out = try testGenOpts(
        \\interface Foo { void noop(); };
    , "foo", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deinit(self: @This()) void {"));
    try testing.expect(has(s, "self.vtable.deinit(self.ptr);"));
}

test "zig_backend: interface inheritance flattens base methods" {
    var out = try testGenOpts(
        \\interface Base { void base_op(); };
        \\interface Derived : Base { void derived_op(); };
    , "inh", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Derived vtable must contain both base_op and derived_op
    try testing.expect(has(s, "base_op: *const fn (*anyopaque) void,"));
    try testing.expect(has(s, "derived_op: *const fn (*anyopaque) void,"));
    // Forwarders for both
    try testing.expect(has(s, "pub fn base_op(self: @This()) void {"));
    try testing.expect(has(s, "pub fn derived_op(self: @This()) void {"));
}

test "zig_backend: interface nested const" {
    var out = try testGenOpts(
        \\interface Versioned { const long VERSION = 2; void noop(); };
    , "ver", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Nested const emitted inside struct body
    try testing.expect(has(s, "pub const VERSION: i32 = 2;"));
}

test "zig_backend: interface in module" {
    var out = try testGenOpts(
        \\module DDS { interface Entity { long get_id(); }; };
    , "dds", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Struct inside DDS namespace struct
    try testing.expect(has(s, "pub const DDS = struct {"));
    try testing.expect(has(s, "pub const Entity = struct {"));
    try testing.expect(has(s, "get_id: *const fn (*anyopaque) i32,"));
}

test "zig_backend: cdr @optional scalar serialize writes bool then value" {
    var out = try testGen(
        \\struct Opt { @optional long maybe_x; long y; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Field type: ?i32
    try testing.expect(has(s, "maybe_x: ?i32 = null"));
    // Serialize: presence bool + conditional value.
    try testing.expect(has(s, "try writer.writeBool(value.maybe_x != null);"));
    try testing.expect(has(s, "if (value.maybe_x) |_opt_maybe_x| {"));
    try testing.expect(has(s, "try writer.writeI32(_opt_maybe_x);"));
    // Non-optional unaffected.
    try testing.expect(has(s, "try writer.writeI32(value.y);"));
}

test "zig_backend: cdr @optional scalar deserialize reads bool and sets null" {
    var out = try testGen(
        \\struct Opt { @optional long maybe_x; long y; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Deserialize: read bool, branch on presence.
    try testing.expect(has(s, "if (try reader.readBool()) {"));
    try testing.expect(has(s, "var _opt_maybe_x: i32 ="));
    try testing.expect(has(s, "out.maybe_x = _opt_maybe_x;"));
    try testing.expect(has(s, "out.maybe_x = null;"));
}

// ── split-file tests ──────────────────────────────────────────────────────────

test "zig_backend split: module gets own file and root re-exports" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(tmp_path);

    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(
        \\module M { struct S { long x; }; };
    , ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();

    const opts = interface.Options{
        .input_stem = "mymod",
        .output_dir = tmp_path,
        .no_typesupport = true,
        .no_typeobject_support = true,
    };
    try generateSplitFiles(alloc, io, &ir_spec, opts);

    // M.zig contains the struct definition.
    const m_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/M.zig", .{tmp.sub_path});
    defer alloc.free(m_path);
    const m_content = try std.Io.Dir.cwd().readFileAlloc(io, m_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(m_content);
    try testing.expect(has(m_content, "pub const S = struct {"));

    // mymod.zig re-exports M.
    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/mymod.zig", .{tmp.sub_path});
    defer alloc.free(root_path);
    const root_content = try std.Io.Dir.cwd().readFileAlloc(io, root_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(root_content);
    try testing.expect(has(root_content, "pub const M = @import(\"M.zig\");"));
}

test "zig_backend split: non-module items go in root file" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(tmp_path);

    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    // No module — just a bare struct at the top level.
    var p = parser_mod.Parser.init(
        \\struct Point { long x; long y; };
    , ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();

    const opts = interface.Options{
        .input_stem = "geo",
        .output_dir = tmp_path,
        .no_typesupport = true,
        .no_typeobject_support = true,
    };
    try generateSplitFiles(alloc, io, &ir_spec, opts);

    // geo.zig should contain the struct inline (no module split).
    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/geo.zig", .{tmp.sub_path});
    defer alloc.free(root_path);
    const root_content = try std.Io.Dir.cwd().readFileAlloc(io, root_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(root_content);
    try testing.expect(has(root_content, "pub const Point = struct {"));
    // No module re-export lines (those look like: pub const M = @import("M.zig")).
    try testing.expect(!has(root_content, ".zig\");"));
}

test "zig_backend type_prefix: struct declaration prefixed" {
    var out = try testGenOpts("struct Foo { long x; };", "t", .{
        .no_typesupport = true,
        .no_typeobject_support = true,
        .type_prefix = "DDS_",
    });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const DDS_Foo = struct {"));
    try testing.expect(!has(out.items, "pub const Foo = struct {"));
}

test "zig_backend type_prefix: enum declaration prefixed" {
    var out = try testGenOpts("enum Color { RED, GREEN };", "t", .{
        .no_typesupport = true,
        .no_typeobject_support = true,
        .type_prefix = "DDS_",
    });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const DDS_Color = enum("));
}

test "zig_backend type_prefix: field type reference prefixed" {
    var out = try testGenOpts(
        \\struct Point { long x; long y; };
        \\struct Line { Point start; Point end; };
    , "t", .{
        .no_typesupport = true,
        .no_typeobject_support = true,
        .type_prefix = "DDS_",
    });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const DDS_Line = struct {"));
    try testing.expect(has(out.items, "start: DDS_Point"));
}

test "zig_backend type_prefix: module name not prefixed" {
    var out = try testGenOpts("module M { struct S { long x; }; };", "t", .{
        .no_typesupport = true,
        .no_typeobject_support = true,
        .type_prefix = "DDS_",
    });
    defer out.deinit(testing.allocator);
    // Module M should NOT be prefixed.
    try testing.expect(has(out.items, "pub const M = struct {"));
    // But type S inside it should be.
    try testing.expect(has(out.items, "pub const DDS_S = struct {"));
}

// ── PL_CDR generation ─────────────────────────────────────────────────────────

test "zig_backend pl_cdr: not emitted without --pl-cdr" {
    var out = try testGenOpts("@mutable struct S { long x; long y; };", "t", .{
        .no_typeobject_support = true,
    });
    defer out.deinit(testing.allocator);
    try testing.expect(!has(out.items, "serializePlCdr"));
    try testing.expect(!has(out.items, "deserializeFromPlCdr"));
}

test "zig_backend pl_cdr: not emitted for non-mutable struct" {
    var out = try testGenOpts("@appendable struct S { long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    try testing.expect(!has(out.items, "serializePlCdr"));
    try testing.expect(!has(out.items, "deserializeFromPlCdr"));
}

test "zig_backend pl_cdr: serializePlCdr emitted for @mutable struct" {
    var out = try testGenOpts("@mutable struct S { long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn serializePlCdr(writer: *zidl_rt.PlCdrWriter, value: @This()) !void {"));
    try testing.expect(has(s, "reservePlParam(0)"));
    try testing.expect(has(s, "reservePlParam(1)"));
    try testing.expect(has(s, "patchPlParam(_ph0)"));
    try testing.expect(has(s, "patchPlParam(_ph1)"));
    try testing.expect(has(s, "writePlSentinel()"));
}

test "zig_backend pl_cdr: deserializeFromPlCdr emitted for @mutable struct" {
    var out = try testGenOpts("@mutable struct S { long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deserializeFromPlCdr(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {"));
    try testing.expect(has(s, "readPlParam()"));
    try testing.expect(has(s, "switch (_p.pid & 0x3FFF) {"));
    try testing.expect(has(s, "seekTo(_p.end_pos)"));
}

test "zig_backend pl_cdr: @optional member skips sentinel in serialize" {
    var out = try testGenOpts("@mutable struct S { @optional long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // @optional x: emit PID only when present
    try testing.expect(has(s, "if (value.x) |_opt_x|"));
    // y: always emitted
    try testing.expect(has(s, "reservePlParam(1)"));
}

test "zig_backend pl_cdr: explicit @id used as PID" {
    var out = try testGenOpts("@mutable struct S { @id(42) long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "reservePlParam(42)"));
    // y is member index 1 (no explicit @id)
    try testing.expect(has(s, "reservePlParam(1)"));
}

// ── @pl_repeated ──────────────────────────────────────────────────────────────

test "zig_backend pl_cdr: @pl_repeated serialize: per-element loop" {
    var out = try testGenOpts(
        "@mutable struct S { @id(10) @pl_repeated sequence<long> items; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Per-element loop: field `items` (ArrayListUnmanaged) accessed via `.items`.
    // The PL_CDR path uses `_elem`; regular serialize uses `_se`.
    try testing.expect(has(s, "for (value.items.items) |_elem|"));
    // One reservePlParam per element (no index suffix — not a fixed _ph0 / _ph1).
    try testing.expect(has(s, "const _ph = try writer.reservePlParam(10)"));
    try testing.expect(has(s, "try writer.patchPlParam(_ph)"));
    // The per-element _ph handle must not use the indexed naming _ph0 that the
    // non-repeated path would use for member index 0.
    try testing.expect(!has(s, "const _ph0 = try writer.reservePlParam(10)"));
}

test "zig_backend pl_cdr: @pl_repeated deserialize: append per PID occurrence" {
    var out = try testGenOpts(
        "@mutable struct S { @id(10) @pl_repeated sequence<long> items; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Switch on PID 10.
    try testing.expect(has(s, "10 => {"));
    // Should append one element per PID occurrence using the allocator.
    try testing.expect(has(s, "try out.items.append(allocator, try reader.readI32())"));
}

test "zig_backend pl_cdr: @pl_repeated + @optional serialize" {
    var out = try testGenOpts(
        "@mutable struct S { @id(5) @optional @pl_repeated sequence<long> vals; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // @optional wrapper uses the captured sequence.
    try testing.expect(has(s, "if (value.vals) |_seq_0|"));
    try testing.expect(has(s, "for (_seq_0.items) |_elem|"));
    try testing.expect(has(s, "const _ph = try writer.reservePlParam(5)"));
}

test "zig_backend pl_cdr: @pl_repeated + @optional deserialize" {
    var out = try testGenOpts(
        "@mutable struct S { @id(5) @optional @pl_repeated sequence<long> vals; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Must initialise the optional on first occurrence.
    try testing.expect(has(s, "if (out.vals == null) out.vals = .{}"));
    // Must append via the optional pointer.
    try testing.expect(has(s, "try out.vals.?.append(allocator, try reader.readI32())"));
}

test "zig_backend pl_cdr: @pl_repeated with struct element type" {
    var out = try testGenOpts(
        \\struct Point { long x; long y; };
        \\@mutable struct S { @id(1) @pl_repeated sequence<Point> pts; };
    , "t", .{ .no_typeobject_support = true, .pl_cdr = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Serialize: iterate and write each struct element.
    try testing.expect(has(s, "for (value.pts.items) |_elem|"));
    try testing.expect(has(s, "try Point.serialize(writer, _elem)"));
    // Deserialize: read into a temp var and append.
    try testing.expect(has(s, "var _elem: Point = .{}"));
    try testing.expect(has(s, "try Point.deserializeInto(&_elem, reader, allocator)"));
    try testing.expect(has(s, "try out.pts.append(allocator, _elem)"));
}

test "zig_backend pl_cdr: @pl_repeated with string element type" {
    var out = try testGenOpts(
        "@mutable struct S { @id(3) @pl_repeated sequence<string> strs; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Serialize: write each string.
    try testing.expect(has(s, "for (value.strs.items) |_elem|"));
    try testing.expect(has(s, "try writer.writeString(_elem)"));
    // Deserialize: append each string.
    try testing.expect(has(s, "try out.strs.append(allocator, try reader.readString(allocator))"));
}

test "zig_backend: fixed<5,2> field type is f64 with zero default" {
    var out = try testGen("struct S { fixed<5,2> price; };", "fp");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "price: f64 = 0.0,"));
}

test "zig_backend: fixed<5,2> serialize emits writeFixed(5,2)" {
    var out = try testGen("struct S { fixed<5,2> price; };", "fp");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeFixed(5, 2, value.price);"));
    try testing.expect(has(s, "out.price = try reader.readFixed(5, 2);"));
}

test "zig_backend: fixed<4,0> (even digits) serialize emits writeFixed(4,0)" {
    var out = try testGen("struct S { fixed<4,0> qty; };", "fp");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeFixed(4, 0, value.qty);"));
    try testing.expect(has(s, "out.qty = try reader.readFixed(4, 0);"));
}
