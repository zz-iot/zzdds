//! Java language mapping backend (OMG formal/21-08-01 v1.0).
//!
//! Generates a single `<stem>.java` file per IDL spec containing:
//!   - Module    → nested `public static class ModuleName`
//!   - Struct    → `public static class Name implements java.io.Serializable`
//!   - Union     → `public static final class Name implements java.io.Serializable`
//!   - Enum      → `public enum Name` with value/getValue/valueOf(int)
//!   - Bitmask   → `public static final class Name` with bit-flag constants
//!   - Bitset    → TODO comment (no standard Java mapping)
//!   - Typedef   → transparent (no Java type emitted; resolved through)
//!   - Native    → no Java output
//!   - Exception → `public static class Name extends RuntimeException`
//!   - Interface → `public interface Name`
//!   - Const     → `public static final class NAME { public static final T value = V; }`
//!
//! ## Primitive type mapping (IDL → Java, Tables 7.2/7.3)
//!
//!   int8 / uint8 / octet                        → byte
//!   short / int16 / unsigned short / uint16     → short
//!   long / int32 / unsigned long / uint32       → int
//!   long long / int64 / unsigned long long / uint64 → long
//!   float                                       → float
//!   double / long double                        → double
//!   char                                        → char  (8-bit CDR)
//!   wchar                                       → char  (16-bit CDR)
//!   boolean                                     → boolean
//!   string / wstring (any bound)                → String
//!   sequence<T>                                 → java.util.List<BoxedT>
//!   T[N] / T[N1][N2]                            → T[] / T[][]
//!   fixed<D,S>                                  → double
//!   map<K,V>                                    → java.util.Map<BoxedK,BoxedV>
//!
//! ## CDR serialization (when --no-typesupport is absent)
//!
//!   Generates XCDR2 LE inline serialization using java.nio.ByteBuffer.
//!   Alignment is relative to `_cdrBase` (buffer position = CDR offset 0).
//!   XCDR2 max alignment = 4 bytes (8-byte types use align-4, not align-8).
//!   @appendable structs emit a 4-byte DHEADER before members.
//!   @key members cause emission of a `serializeKey` method.
//!
//! ## Naming scheme
//!
//!   IDL Naming Scheme (§7.1.1): member names kept as-is.
//!   Getter: `get_memberName()`, setter: `set_memberName(value)`.

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir/root.zig");
const interface = @import("interface.zig");

// ── Public backend struct ─────────────────────────────────────────────────────

pub const JavaBackend = struct {
    alloc: std.mem.Allocator,

    pub fn create(alloc: std.mem.Allocator) !*JavaBackend {
        const self = try alloc.create(JavaBackend);
        self.* = .{ .alloc = alloc };
        return self;
    }

    pub fn backend(self: *JavaBackend) interface.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = interface.Backend.Vtable{
        .language_id = "java",
        .generate = vtableGenerate,
        .deinit = vtableDeinit,
    };

    fn vtableGenerate(
        ctx: *anyopaque,
        spec: *const ir.Spec,
        opts: interface.Options,
    ) anyerror!void {
        const self: *JavaBackend = @ptrCast(@alignCast(ctx));
        const io = std.Io.Threaded.global_single_threaded.io();

        if (opts.split_files) {
            try generateSplitFiles(self.alloc, io, spec, opts);
            return;
        }

        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.alloc);
        try generateFile(self.alloc, spec, opts, &content);

        const class_name = try stemToClassName(self.alloc, opts.input_stem);
        defer self.alloc.free(class_name);
        const filename = try std.fmt.allocPrint(self.alloc, "{s}.java", .{class_name});
        defer self.alloc.free(filename);
        try writeOutputFile(self.alloc, io, opts, filename, content.items);

        // ── FooImpl.java (per interface) + <stem>_jni.c ──────────────────────
        if (opts.generate_interfaces) {
            var ifaces = std.ArrayListUnmanaged(*const ir.Interface).empty;
            defer ifaces.deinit(self.alloc);
            try collectInterfaces(self.alloc, spec.items, &ifaces);

            for (ifaces.items) |iface| {
                var impl_buf = std.ArrayList(u8).empty;
                defer impl_buf.deinit(self.alloc);
                try generateImplFile(self.alloc, iface, class_name, opts, &impl_buf);
                const impl_filename = try std.fmt.allocPrint(self.alloc, "{s}{s}Impl.java", .{ opts.type_prefix, iface.name });
                defer self.alloc.free(impl_filename);
                try writeOutputFile(self.alloc, io, opts, impl_filename, impl_buf.items);
            }

            var jni_buf = std.ArrayList(u8).empty;
            defer jni_buf.deinit(self.alloc);
            try generateJniSource(self.alloc, spec, opts, &jni_buf);
            const jni_filename = try std.fmt.allocPrint(self.alloc, "{s}_jni.c", .{opts.input_stem});
            defer self.alloc.free(jni_filename);
            try writeOutputFile(self.alloc, io, opts, jni_filename, jni_buf.items);
        }
    }

    fn vtableDeinit(ctx: *anyopaque) void {
        const self: *JavaBackend = @ptrCast(@alignCast(ctx));
        self.alloc.destroy(self);
    }
};

// ── Public entry point (testable) ─────────────────────────────────────────────

pub fn generateFile(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.emitFile(spec);
}

// ── Generator (private implementation) ───────────────────────────────────────

const Generator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),
    /// Current class nesting depth.
    /// 0 = before outer class, 1 = inside outer class, 2 = inside nested class, …
    depth: usize = 0,
    /// When true, the Generator is emitting a standalone top-level class file
    /// (split mode). Removes the `static` qualifier from type declarations and
    /// adjusts the CDR helper visibility to public.
    top_level: bool = false,

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
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n",
            .{self.opts.input_stem},
        );
        if (self.opts.java_package.len > 0) {
            try self.print("package {s};\n", .{self.opts.java_package});
        }
        try self.write("\n");
        try self.write("import java.util.List;\n");
        try self.write("import java.util.ArrayList;\n");
        try self.write("\n");

        const class_name = try stemToClassName(self.alloc, self.opts.input_stem);
        defer self.alloc.free(class_name);
        try self.print("public class {s} {{\n", .{class_name});
        self.depth = 1;

        if (!self.opts.no_typesupport) {
            try self.emitCdrHelpers();
        }

        try self.emitItems(spec.items);
        try self.write("}\n");
    }

    /// Emit private static CDR helper methods into the outer class body.
    fn emitCdrHelpers(self: *Generator) !void {
        try self.ind();
        try self.write("private static void _cdrAlign(java.nio.ByteBuffer _buf, int _cdrBase, int _align) {\n");
        try self.ind();
        try self.write("    if (_align <= 1) return;\n");
        try self.ind();
        try self.write("    int _p = (_buf.position() - _cdrBase) % _align;\n");
        try self.ind();
        try self.write("    if (_p != 0) _buf.position(_buf.position() + (_align - _p));\n");
        try self.ind();
        try self.write("}\n");
        try self.ind();
        try self.write("private static void _cdrWriteString(java.nio.ByteBuffer _buf, int _cdrBase, String _s) {\n");
        try self.ind();
        try self.write("    _cdrAlign(_buf, _cdrBase, 4);\n");
        try self.ind();
        try self.write("    byte[] _bytes = _s.getBytes(java.nio.charset.StandardCharsets.UTF_8);\n");
        try self.ind();
        try self.write("    _buf.putInt(_bytes.length + 1); _buf.put(_bytes); _buf.put((byte)0);\n");
        try self.ind();
        try self.write("}\n");
        try self.ind();
        try self.write("private static String _cdrReadString(java.nio.ByteBuffer _buf, int _cdrBase) {\n");
        try self.ind();
        try self.write("    _cdrAlign(_buf, _cdrBase, 4);\n");
        try self.ind();
        try self.write("    int _len = _buf.getInt(); if (_len <= 0) return \"\";\n");
        try self.ind();
        try self.write("    byte[] _bytes = new byte[_len - 1]; _buf.get(_bytes); _buf.get();\n");
        try self.ind();
        try self.write("    return new String(_bytes, java.nio.charset.StandardCharsets.UTF_8);\n");
        try self.ind();
        try self.write("}\n");
        try self.ind();
        try self.write("private static void _cdrWriteFixed(java.nio.ByteBuffer _buf, int _d, int _s, double _v) {\n");
        try self.ind();
        try self.write("    int _n = (_d / 2) + 1; int _n2 = _n * 2; int _pad = _n2 - _d - 1;\n");
        try self.ind();
        try self.write("    boolean _neg = _v < 0.0;\n");
        try self.ind();
        try self.write("    double _sf = Math.pow(10, _s); long _iv = (long)(Math.abs(_v) * _sf + 0.5);\n");
        try self.ind();
        try self.write("    byte[] _dig = new byte[_d];\n");
        try self.ind();
        try self.write("    for (int _i = _d - 1; _i >= 0; _i--) { _dig[_i] = (byte)(_iv % 10); _iv /= 10; }\n");
        try self.ind();
        try self.write("    byte[] _nib = new byte[_n2];\n");
        try self.ind();
        try self.write("    for (int _i = 0; _i < _d; _i++) _nib[_pad + _i] = _dig[_i];\n");
        try self.ind();
        try self.write("    _nib[_n2 - 1] = _neg ? (byte)0x0D : (byte)0x0C;\n");
        try self.ind();
        try self.write("    byte[] _bcd = new byte[_n];\n");
        try self.ind();
        try self.write("    for (int _i = 0; _i < _n; _i++) _bcd[_i] = (byte)((_nib[2*_i] << 4) | _nib[2*_i+1]);\n");
        try self.ind();
        try self.write("    _buf.put(_bcd);\n");
        try self.ind();
        try self.write("}\n");
        try self.ind();
        try self.write("private static double _cdrReadFixed(java.nio.ByteBuffer _buf, int _d, int _s) {\n");
        try self.ind();
        try self.write("    int _n = (_d / 2) + 1; int _n2 = _n * 2; int _pad = _n2 - _d - 1;\n");
        try self.ind();
        try self.write("    byte[] _bcd = new byte[_n]; _buf.get(_bcd);\n");
        try self.ind();
        try self.write("    byte[] _nib = new byte[_n2];\n");
        try self.ind();
        try self.write("    for (int _i = 0; _i < _n; _i++) { _nib[2*_i] = (byte)((_bcd[_i]>>4)&0x0F); _nib[2*_i+1] = (byte)(_bcd[_i]&0x0F); }\n");
        try self.ind();
        try self.write("    long _iv = 0; for (int _k = 0; _k < _d; _k++) _iv = _iv * 10 + _nib[_pad + _k];\n");
        try self.ind();
        try self.write("    boolean _neg = (_nib[_n2-1] == 0x0D || _nib[_n2-1] == 0x0B);\n");
        try self.ind();
        try self.write("    double _r = (double)_iv / Math.pow(10, _s); return _neg ? -_r : _r;\n");
        try self.ind();
        try self.write("}\n\n");
        try self.ind();
        try self.write("private static byte[] _cdrComputeKeyHash(java.nio.ByteBuffer _buf) {\n");
        try self.ind();
        try self.write("    int _len = _buf.position();\n");
        try self.ind();
        try self.write("    byte[] _key = new byte[_len];\n");
        try self.ind();
        try self.write("    _buf.position(0); _buf.get(_key);\n");
        try self.ind();
        try self.write("    if (_len <= 16) {\n");
        try self.ind();
        try self.write("        byte[] _out = new byte[16];\n");
        try self.ind();
        try self.write("        System.arraycopy(_key, 0, _out, 0, _len);\n");
        try self.ind();
        try self.write("        return _out;\n");
        try self.ind();
        try self.write("    }\n");
        try self.ind();
        try self.write("    try { return java.security.MessageDigest.getInstance(\"MD5\").digest(_key); }\n");
        try self.ind();
        try self.write("    catch (java.security.NoSuchAlgorithmException _e) { throw new IllegalStateException(_e); }\n");
        try self.ind();
        try self.write("}\n\n");
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
        try self.print("public static class {s} {{\n", .{m.name});
        self.depth += 1;
        try self.emitItems(m.items);
        self.depth -= 1;
        try self.ind();
        try self.print("}} // {s}\n\n", .{m.name});
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
            .exception => |ex| try self.emitException(ex),
            .interface => |iface| try self.emitInterface(iface),
        }
    }

    // ── Struct ────────────────────────────────────────────────────────────────

    fn emitStruct(self: *Generator, s: *const ir.Struct) !void {
        const pfx = self.opts.type_prefix;
        const cls_kw = if (self.top_level and self.depth == 0) "public class" else "public static class";
        try self.ind();
        if (s.base) |base| {
            const java_base = try self.qualNameToJava(ir.typeDeclQualifiedName(base));
            defer self.alloc.free(java_base);
            try self.print(
                "{s} {s}{s} extends {s} implements java.io.Serializable {{\n",
                .{ cls_kw, pfx, s.name, java_base },
            );
        } else {
            try self.print(
                "{s} {s}{s} implements java.io.Serializable {{\n",
                .{ cls_kw, pfx, s.name },
            );
        }
        self.depth += 1;

        try self.ind();
        try self.write("private static final long serialVersionUID = 1L;\n");

        // Private fields
        for (s.members) |m| {
            const java_type = try self.memberJavaType(m);
            defer self.alloc.free(java_type);
            try self.ind();
            try self.print("private {s} {s};\n", .{ java_type, m.name });
        }

        // Default constructor
        try self.write("\n");
        try self.ind();
        try self.print("public {s}{s}() {{\n", .{ pfx, s.name });
        for (s.members) |m| {
            const dflt = try self.memberDefault(m);
            defer self.alloc.free(dflt);
            try self.ind();
            try self.print("    this.{s} = {s};\n", .{ m.name, dflt });
        }
        try self.ind();
        try self.write("}\n");

        // All-values constructor
        if (s.members.len > 0) {
            try self.write("\n");
            try self.ind();
            try self.print("public {s}{s}(", .{ pfx, s.name });
            for (s.members, 0..) |m, i| {
                const java_type = try self.memberJavaType(m);
                defer self.alloc.free(java_type);
                if (i > 0) try self.write(", ");
                try self.print("{s} {s}", .{ java_type, m.name });
            }
            try self.write(") {\n");
            for (s.members) |m| {
                try self.ind();
                try self.print("    this.{s} = {s};\n", .{ m.name, m.name });
            }
            try self.ind();
            try self.write("}\n");
        }

        // Getters and setters
        for (s.members) |m| {
            const java_type = try self.memberJavaType(m);
            defer self.alloc.free(java_type);
            try self.write("\n");
            try self.ind();
            try self.print(
                "public {s} get_{s}() {{ return {s}; }}\n",
                .{ java_type, m.name, m.name },
            );
            try self.ind();
            try self.print(
                "public void set_{s}({s} {s}) {{ this.{s} = {s}; }}\n",
                .{ m.name, java_type, m.name, m.name, m.name },
            );
        }

        // CDR serialization
        if (!self.opts.no_typesupport) {
            try self.emitStructSerializeFns(s);
        }

        self.depth -= 1;
        try self.ind();
        try self.print("}} // {s}{s}\n\n", .{ pfx, s.name });
    }

    // ── Union ─────────────────────────────────────────────────────────────────

    fn emitUnion(self: *Generator, u: *const ir.Union) !void {
        const pfx = self.opts.type_prefix;
        const disc_java = try self.typeRefToJava(u.discriminant, &.{});
        defer self.alloc.free(disc_java);

        const cls_kw_u = if (self.top_level and self.depth == 0) "public final class" else "public static final class";
        try self.ind();
        try self.print(
            "{s} {s}{s} implements java.io.Serializable {{\n",
            .{ cls_kw_u, pfx, u.name },
        );
        self.depth += 1;
        try self.ind();
        try self.write("private static final long serialVersionUID = 1L;\n");
        try self.ind();
        try self.print("private {s} _discriminator;\n", .{disc_java});

        for (u.cases) |cas| {
            const java_type = try self.typeRefToJava(cas.type_ref, cas.dimensions);
            defer self.alloc.free(java_type);
            try self.ind();
            try self.print("private {s} {s};\n", .{ java_type, cas.name });
        }

        try self.write("\n");
        try self.ind();
        try self.print("public {s}{s}() {{}}\n", .{ pfx, u.name });
        try self.write("\n");
        try self.ind();
        try self.print(
            "public {s} get_discriminator() {{ return _discriminator; }}\n",
            .{disc_java},
        );

        for (u.cases) |cas| {
            const java_type = try self.typeRefToJava(cas.type_ref, cas.dimensions);
            defer self.alloc.free(java_type);
            try self.write("\n");
            try self.ind();
            try self.print(
                "public {s} get_{s}() {{ return {s}; }}\n",
                .{ java_type, cas.name, cas.name },
            );
            // Setter with discriminant assignment
            const label_str = try self.unionLabelExpr(u.discriminant, cas.labels);
            defer self.alloc.free(label_str);
            try self.ind();
            if (label_str.len > 0) {
                try self.print(
                    "public void set_{s}({s} _v) {{ _discriminator = {s}; {s} = _v; }}\n",
                    .{ cas.name, java_type, label_str, cas.name },
                );
            } else {
                try self.print(
                    "public void set_{s}({s} _v) {{ {s} = _v; }}\n",
                    .{ cas.name, java_type, cas.name },
                );
            }
        }

        if (!self.opts.no_typesupport) {
            try self.emitUnionSerializeFns(u);
        }

        self.depth -= 1;
        try self.ind();
        try self.print("}} // {s}{s}\n\n", .{ pfx, u.name });
    }

    fn emitUnionSerializeFns(self: *Generator, u: *const ir.Union) anyerror!void {
        const pfx = self.opts.type_prefix;
        const ext = u.annotations.extensibility;
        const appendable = ext == .appendable;
        const mutable = ext == .mutable;

        // Determine whether the discriminant is a Java enum or a primitive
        const disc_is_enum = switch (u.discriminant) {
            .named => |td| td == .enum_,
            else => false,
        };
        const disc_is_bool = switch (u.discriminant) {
            .base => |b| b == .boolean,
            else => false,
        };

        // ── serialize ────────────────────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.write("public void serialize(java.nio.ByteBuffer _buf, int _cdrBase) {\n");
        self.depth += 1;
        try self.ind();
        try self.write("_buf.order(java.nio.ByteOrder.LITTLE_ENDIAN);\n");

        if (mutable) {
            // @mutable union: DHEADER + EMHEADER(0) for discriminant + EMHEADER(N) per case.
            try self.ind();
            try self.write("_cdrAlign(_buf, _cdrBase, 4); int _dhPos = _buf.position(); _buf.putInt(0);\n");
            // Discriminant EMHEADER (member_id=0).
            const disc_lc = lcForJavaTypeRef(u.discriminant, &.{});
            const disc_emhword: u32 = if (disc_lc) |lc|
                (@as(u32, lc) << 28) // member_id=0, must_understand=false
            else
                0x4000_0000; // LC=4 fallback
            try self.ind();
            try self.print("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(0x{X:0>8}); // disc EMHEADER\n", .{disc_emhword});
            if (disc_lc == null) {
                // variable-length: add NEXTINT placeholder (rare for discriminants)
                try self.ind();
                try self.write("int _niPos_disc = _buf.position(); _buf.putInt(0);\n");
            }
            // Write discriminant value.
            if (disc_is_enum) {
                try self.ind();
                try self.write("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(_discriminator.getValue());\n");
            } else if (disc_is_bool) {
                try self.ind();
                try self.write("_buf.put((byte)(_discriminator ? 1 : 0));\n");
            } else {
                switch (u.discriminant) {
                    .base => |b| {
                        const align_v = baseCdrAlign(b);
                        if (align_v > 1) {
                            try self.ind();
                            try self.print("_cdrAlign(_buf, _cdrBase, {d}); ", .{align_v});
                        } else {
                            try self.ind();
                        }
                        switch (b) {
                            .octet, .int8, .uint8 => try self.write("_buf.put((byte)_discriminator);\n"),
                            .short, .int16, .unsigned_short, .uint16 => try self.write("_buf.putShort((short)_discriminator);\n"),
                            .long, .int32, .unsigned_long, .uint32 => try self.write("_buf.putInt((int)_discriminator);\n"),
                            .long_long, .int64, .unsigned_long_long, .uint64 => try self.write("_buf.putLong((long)_discriminator);\n"),
                            else => try self.write("_buf.putInt((int)_discriminator);\n"),
                        }
                    },
                    else => {
                        try self.ind();
                        try self.write("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt((int)_discriminator);\n");
                    },
                }
            }
            if (disc_lc == null) {
                try self.ind();
                try self.write("_buf.putInt(_niPos_disc, _buf.position() - _niPos_disc - 4);\n");
            }
            // Case value EMHEADER: switch on discriminant.
            try self.ind();
            try self.write("switch (_discriminator) {\n");
            self.depth += 1;
            for (u.cases, 0..) |cas, cas_idx| {
                if (isDefaultUnionCase(cas)) continue;
                const case_mid: u32 = if (cas.annotations.id) |id| id else @intCast(cas_idx + 1);
                const case_lc = lcForJavaTypeRef(cas.type_ref, cas.dimensions);
                const case_vword: u32 = 0x4000_0000 | case_mid; // LC=4
                const case_fword: u32 = if (case_lc) |lc| (@as(u32, lc) << 28) | case_mid else case_vword;
                try self.emitJavaUnionCaseLabelLines(u.discriminant, cas);
                const access_ser = try std.fmt.allocPrint(self.alloc, "this.{s}", .{cas.name});
                defer self.alloc.free(access_ser);
                try self.ind();
                if (case_lc) |_| {
                    try self.print("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(0x{X:0>8}); // EMHEADER case {d}\n", .{ case_fword, case_mid });
                } else {
                    try self.print("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(0x{X:0>8}); int _niPos_c{d} = _buf.position(); _buf.putInt(0);\n", .{ case_vword, cas_idx });
                }
                if (cas.dimensions.len > 0) {
                    try self.emitSerializeArray(cas.type_ref, access_ser, cas.dimensions, "", 0);
                } else {
                    try self.emitSerializeForTypeRef(cas.type_ref, access_ser, "");
                }
                if (case_lc == null) {
                    try self.ind();
                    try self.print("_buf.putInt(_niPos_c{d}, _buf.position() - _niPos_c{d} - 4);\n", .{ cas_idx, cas_idx });
                }
                try self.ind();
                try self.write("break;\n");
            }
            // default arm
            const default_case_mu: ?ir.UnionCase = blk: {
                for (u.cases) |cas| {
                    if (isDefaultUnionCase(cas)) break :blk cas;
                }
                break :blk null;
            };
            if (default_case_mu) |dc| {
                const dc_mid: u32 = if (dc.annotations.id) |id| id else 0xFFFF_FFFF;
                const dc_lc = lcForJavaTypeRef(dc.type_ref, dc.dimensions);
                const dc_vword: u32 = 0x4000_0000 | dc_mid;
                const dc_fword: u32 = if (dc_lc) |lc| (@as(u32, lc) << 28) | dc_mid else dc_vword;
                try self.ind();
                try self.write("default:\n");
                const dc_access = try std.fmt.allocPrint(self.alloc, "this.{s}", .{dc.name});
                defer self.alloc.free(dc_access);
                try self.ind();
                if (dc_lc) |_| {
                    try self.print("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(0x{X:0>8}); // EMHEADER default\n", .{dc_fword});
                } else {
                    try self.print("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(0x{X:0>8}); int _niPos_cdef = _buf.position(); _buf.putInt(0);\n", .{dc_vword});
                }
                if (dc.dimensions.len > 0) {
                    try self.emitSerializeArray(dc.type_ref, dc_access, dc.dimensions, "", 0);
                } else {
                    try self.emitSerializeForTypeRef(dc.type_ref, dc_access, "");
                }
                if (dc_lc == null) {
                    try self.ind();
                    try self.write("_buf.putInt(_niPos_cdef, _buf.position() - _niPos_cdef - 4);\n");
                }
                try self.ind();
                try self.write("break;\n");
            } else {
                try self.ind();
                try self.write("default: break;\n");
            }
            self.depth -= 1;
            try self.ind();
            try self.write("}\n");
            try self.ind();
            try self.write("_buf.putInt(_dhPos, _buf.position() - _dhPos - 4);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("_cdrAlign(_buf, _cdrBase, 4); int _dhPos = _buf.position(); _buf.putInt(0);\n");
            }
            // Write discriminant
            if (disc_is_enum) {
                try self.ind();
                try self.write("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(_discriminator.getValue());\n");
            } else if (disc_is_bool) {
                try self.ind();
                try self.write("_buf.put((byte)(_discriminator ? 1 : 0));\n");
            } else {
                switch (u.discriminant) {
                    .base => |b| {
                        const align_v = baseCdrAlign(b);
                        if (align_v > 1) {
                            try self.ind();
                            try self.print("_cdrAlign(_buf, _cdrBase, {d}); ", .{align_v});
                        } else {
                            try self.ind();
                        }
                        switch (b) {
                            .octet, .int8, .uint8 => try self.write("_buf.put((byte)_discriminator);\n"),
                            .short, .int16, .unsigned_short, .uint16 => try self.write("_buf.putShort((short)_discriminator);\n"),
                            .long, .int32, .unsigned_long, .uint32 => try self.write("_buf.putInt((int)_discriminator);\n"),
                            .long_long, .int64, .unsigned_long_long, .uint64 => try self.write("_buf.putLong((long)_discriminator);\n"),
                            else => try self.write("_buf.putInt((int)_discriminator);\n"),
                        }
                    },
                    else => {
                        try self.ind();
                        try self.write("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt((int)_discriminator);\n");
                    },
                }
            }
            // Switch on discriminant
            if (disc_is_bool) {
                // Java can't switch on boolean — use if/else
                for (u.cases) |cas| {
                    if (isDefaultUnionCase(cas)) continue;
                    for (cas.labels) |lbl| {
                        if (lbl == .boolean) {
                            const bval = lbl.boolean;
                            try self.ind();
                            try self.print("if (_discriminator == {s}) {{\n", .{if (bval) "true" else "false"});
                            self.depth += 1;
                            const access = try std.fmt.allocPrint(self.alloc, "this.{s}", .{cas.name});
                            defer self.alloc.free(access);
                            if (cas.dimensions.len > 0) {
                                try self.emitSerializeArray(cas.type_ref, access, cas.dimensions, "", 0);
                            } else {
                                try self.emitSerializeForTypeRef(cas.type_ref, access, "");
                            }
                            self.depth -= 1;
                            try self.ind();
                            try self.write("}\n");
                        }
                    }
                }
            } else {
                try self.ind();
                try self.write("switch (_discriminator) {\n");
                self.depth += 1;
                var has_default = false;
                for (u.cases) |cas| {
                    if (isDefaultUnionCase(cas)) {
                        has_default = true;
                        continue;
                    }
                    try self.emitJavaUnionCaseLabelLines(u.discriminant, cas);
                    const access_ser = try std.fmt.allocPrint(self.alloc, "this.{s}", .{cas.name});
                    defer self.alloc.free(access_ser);
                    if (cas.dimensions.len > 0) {
                        try self.emitSerializeArray(cas.type_ref, access_ser, cas.dimensions, "", 0);
                    } else {
                        try self.emitSerializeForTypeRef(cas.type_ref, access_ser, "");
                    }
                    try self.ind();
                    try self.write("break;\n");
                }
                // default arm
                const default_case: ?ir.UnionCase = blk: {
                    for (u.cases) |cas| {
                        if (isDefaultUnionCase(cas)) break :blk cas;
                    }
                    break :blk null;
                };
                if (default_case) |dc| {
                    try self.ind();
                    try self.write("default:\n");
                    const dc_access = try std.fmt.allocPrint(self.alloc, "this.{s}", .{dc.name});
                    defer self.alloc.free(dc_access);
                    if (dc.dimensions.len > 0) {
                        try self.emitSerializeArray(dc.type_ref, dc_access, dc.dimensions, "", 0);
                    } else {
                        try self.emitSerializeForTypeRef(dc.type_ref, dc_access, "");
                    }
                    try self.ind();
                    try self.write("break;\n");
                } else if (!has_default) {
                    try self.ind();
                    try self.write("default: break;\n");
                }
                self.depth -= 1;
                try self.ind();
                try self.write("}\n");
            }
            if (appendable) {
                try self.ind();
                try self.write("int _dhEnd = _buf.position(); _buf.putInt(_dhPos, _dhEnd - _dhPos - 4);\n");
            }
        }
        self.depth -= 1;
        try self.ind();
        try self.write("}\n");

        // ── deserializeFrom ──────────────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.print("public static {s}{s} deserializeFrom(java.nio.ByteBuffer _buf, int _cdrBase) {{\n", .{ pfx, u.name });
        self.depth += 1;
        try self.ind();
        try self.write("_buf.order(java.nio.ByteOrder.LITTLE_ENDIAN);\n");
        try self.ind();
        try self.print("{s}{s} _out = new {s}{s}();\n", .{ pfx, u.name, pfx, u.name });
        if (mutable) {
            // @mutable union: read DHEADER, then EMHEADER loop.
            // member_id=0 is the discriminant; other IDs are case values.
            try self.ind();
            try self.write("_cdrAlign(_buf, _cdrBase, 4); int _emEnd = _buf.position() + _buf.getInt();\n");
            try self.ind();
            try self.write("while (_buf.position() < _emEnd) {\n");
            self.depth += 1;
            try self.ind();
            try self.write("_cdrAlign(_buf, _cdrBase, 4); int _emWord = _buf.getInt(); int _memberId = _emWord & 0x0FFFFFFF;\n");
            try self.ind();
            try self.write("int _emLc = (_emWord >>> 28) & 0x7; int _emPayload; if (_emLc == 0) _emPayload = 1; else if (_emLc == 1) _emPayload = 2; else if (_emLc == 2) _emPayload = 4; else if (_emLc == 3) _emPayload = 8; else _emPayload = _buf.getInt();\n");
            try self.ind();
            try self.write("if (_memberId == 0) {\n");
            self.depth += 1;
            // Read discriminant
            if (disc_is_enum) {
                const disc_java = try self.typeRefToJava(u.discriminant, &.{});
                defer self.alloc.free(disc_java);
                try self.ind();
                try self.print("_cdrAlign(_buf, _cdrBase, 4); _out._discriminator = {s}.valueOf(_buf.getInt());\n", .{disc_java});
            } else if (disc_is_bool) {
                try self.ind();
                try self.write("_out._discriminator = _buf.get() != 0;\n");
            } else {
                switch (u.discriminant) {
                    .base => |b| {
                        const align_v = baseCdrAlign(b);
                        const read_expr = baseCdrReadExpr(b);
                        if (align_v > 1) {
                            try self.ind();
                            try self.print("_cdrAlign(_buf, _cdrBase, {d}); _out._discriminator = {s};\n", .{ align_v, read_expr });
                        } else {
                            try self.ind();
                            try self.print("_out._discriminator = {s};\n", .{read_expr});
                        }
                    },
                    else => {
                        try self.ind();
                        try self.write("_cdrAlign(_buf, _cdrBase, 4); _out._discriminator = _buf.getInt();\n");
                    },
                }
            }
            self.depth -= 1;
            try self.ind();
            try self.write("} else {\n");
            self.depth += 1;
            // Switch on discriminant to read the corresponding case value.
            try self.ind();
            try self.write("switch (_out._discriminator) {\n");
            self.depth += 1;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) continue;
                try self.emitJavaUnionCaseLabelLines(u.discriminant, cas);
                const out_expr = try std.fmt.allocPrint(self.alloc, "_out.{s}", .{cas.name});
                defer self.alloc.free(out_expr);
                if (cas.dimensions.len > 0) {
                    try self.emitDeserializeArray(cas.type_ref, out_expr, cas.dimensions, "", 0);
                } else {
                    try self.emitDeserializeForTypeRef(cas.type_ref, out_expr, "");
                }
                try self.ind();
                try self.write("break;\n");
            }
            const dc_mu: ?ir.UnionCase = blk: {
                for (u.cases) |cas| {
                    if (isDefaultUnionCase(cas)) break :blk cas;
                }
                break :blk null;
            };
            if (dc_mu) |dc| {
                try self.ind();
                try self.write("default:\n");
                const out_expr = try std.fmt.allocPrint(self.alloc, "_out.{s}", .{dc.name});
                defer self.alloc.free(out_expr);
                if (dc.dimensions.len > 0) {
                    try self.emitDeserializeArray(dc.type_ref, out_expr, dc.dimensions, "", 0);
                } else {
                    try self.emitDeserializeForTypeRef(dc.type_ref, out_expr, "");
                }
                try self.ind();
                try self.write("break;\n");
            } else {
                try self.ind();
                try self.write("default: _buf.position(_buf.position() + _emPayload); break;\n");
            }
            self.depth -= 1;
            try self.ind();
            try self.write("}\n");
            self.depth -= 1;
            try self.ind();
            try self.write("}\n");
            self.depth -= 1;
            try self.ind();
            try self.write("}\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("_cdrAlign(_buf, _cdrBase, 4); _buf.getInt(); // skip DHEADER\n");
            }
            // Read discriminant
            if (disc_is_enum) {
                const disc_java = try self.typeRefToJava(u.discriminant, &.{});
                defer self.alloc.free(disc_java);
                try self.ind();
                try self.print("_cdrAlign(_buf, _cdrBase, 4); _out._discriminator = {s}.valueOf(_buf.getInt());\n", .{disc_java});
            } else if (disc_is_bool) {
                try self.ind();
                try self.write("_out._discriminator = _buf.get() != 0;\n");
            } else {
                switch (u.discriminant) {
                    .base => |b| {
                        const align_v = baseCdrAlign(b);
                        const read_expr = baseCdrReadExpr(b);
                        if (align_v > 1) {
                            try self.ind();
                            try self.print("_cdrAlign(_buf, _cdrBase, {d}); _out._discriminator = {s};\n", .{ align_v, read_expr });
                        } else {
                            try self.ind();
                            try self.print("_out._discriminator = {s};\n", .{read_expr});
                        }
                    },
                    else => {
                        try self.ind();
                        try self.write("_cdrAlign(_buf, _cdrBase, 4); _out._discriminator = _buf.getInt();\n");
                    },
                }
            }
            // Switch on discriminant to read member
            if (disc_is_bool) {
                for (u.cases) |cas| {
                    if (isDefaultUnionCase(cas)) continue;
                    for (cas.labels) |lbl| {
                        if (lbl == .boolean) {
                            const bval = lbl.boolean;
                            try self.ind();
                            try self.print("if (_out._discriminator == {s}) {{\n", .{if (bval) "true" else "false"});
                            self.depth += 1;
                            const out_expr = try std.fmt.allocPrint(self.alloc, "_out.{s}", .{cas.name});
                            defer self.alloc.free(out_expr);
                            if (cas.dimensions.len > 0) {
                                try self.emitDeserializeArray(cas.type_ref, out_expr, cas.dimensions, "", 0);
                            } else {
                                try self.emitDeserializeForTypeRef(cas.type_ref, out_expr, "");
                            }
                            self.depth -= 1;
                            try self.ind();
                            try self.write("}\n");
                        }
                    }
                }
            } else {
                try self.ind();
                try self.write("switch (_out._discriminator) {\n");
                self.depth += 1;
                for (u.cases) |cas| {
                    if (isDefaultUnionCase(cas)) continue;
                    try self.emitJavaUnionCaseLabelLines(u.discriminant, cas);
                    const out_expr = try std.fmt.allocPrint(self.alloc, "_out.{s}", .{cas.name});
                    defer self.alloc.free(out_expr);
                    if (cas.dimensions.len > 0) {
                        try self.emitDeserializeArray(cas.type_ref, out_expr, cas.dimensions, "", 0);
                    } else {
                        try self.emitDeserializeForTypeRef(cas.type_ref, out_expr, "");
                    }
                    try self.ind();
                    try self.write("break;\n");
                }
                const default_case2: ?ir.UnionCase = blk: {
                    for (u.cases) |cas| {
                        if (isDefaultUnionCase(cas)) break :blk cas;
                    }
                    break :blk null;
                };
                if (default_case2) |dc| {
                    try self.ind();
                    try self.write("default:\n");
                    const out_expr = try std.fmt.allocPrint(self.alloc, "_out.{s}", .{dc.name});
                    defer self.alloc.free(out_expr);
                    if (dc.dimensions.len > 0) {
                        try self.emitDeserializeArray(dc.type_ref, out_expr, dc.dimensions, "", 0);
                    } else {
                        try self.emitDeserializeForTypeRef(dc.type_ref, out_expr, "");
                    }
                    try self.ind();
                    try self.write("break;\n");
                } else {
                    try self.ind();
                    try self.write("default: break;\n");
                }
                self.depth -= 1;
                try self.ind();
                try self.write("}\n");
            }
        }
        try self.ind();
        try self.write("return _out;\n");
        self.depth -= 1;
        try self.ind();
        try self.write("}\n");
    }

    /// Emit Java switch case label line(s) for a union case.
    fn emitJavaUnionCaseLabelLines(self: *Generator, disc: ir.TypeRef, cas: ir.UnionCase) anyerror!void {
        for (cas.labels) |lbl| {
            switch (lbl) {
                .default => {
                    try self.ind();
                    try self.write("default:\n");
                },
                .integer => |v| {
                    try self.ind();
                    try self.print("case {d}:\n", .{v});
                },
                .boolean => |b| {
                    // Boolean switch not supported in Java — should be handled by caller
                    try self.ind();
                    try self.print("case {d}:\n", .{@intFromBool(b)});
                },
                .enumerator => |name| {
                    // Java switch on enum uses bare member name
                    _ = disc;
                    try self.ind();
                    try self.print("case {s}:\n", .{name});
                },
            }
        }
    }

    /// Format the first non-default label of a union case as a Java expression.
    /// Returns empty string for the default case.
    fn unionLabelExpr(
        self: *Generator,
        disc: ir.TypeRef,
        labels: []const ir.UnionLabel,
    ) anyerror![]u8 {
        for (labels) |lbl| {
            switch (lbl) {
                .integer => |v| return std.fmt.allocPrint(self.alloc, "{d}", .{v}),
                .boolean => |v| return self.alloc.dupe(u8, if (v) "true" else "false"),
                .enumerator => |name| {
                    const disc_java = try self.typeRefToJava(disc, &.{});
                    defer self.alloc.free(disc_java);
                    return std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ disc_java, name });
                },
                .default => {},
            }
        }
        return self.alloc.dupe(u8, "");
    }

    // ── Enum ──────────────────────────────────────────────────────────────────

    fn emitEnum(self: *Generator, e: *const ir.Enum) !void {
        const pfx = self.opts.type_prefix;
        try self.ind();
        try self.print("public enum {s}{s} {{\n", .{ pfx, e.name });
        self.depth += 1;

        for (e.enumerators, 0..) |en, i| {
            try self.ind();
            const sep: []const u8 = if (i + 1 < e.enumerators.len) "," else ";";
            try self.print("{s}({d}){s}\n", .{ en.name, en.value, sep });
        }
        // Handle empty enum
        if (e.enumerators.len == 0) {
            try self.ind();
            try self.write(";\n");
        }

        try self.write("\n");
        try self.ind();
        try self.write("private final int value;\n");
        try self.ind();
        try self.print("private {s}{s}(int value) {{ this.value = value; }}\n", .{ pfx, e.name });
        try self.write("\n");
        try self.ind();
        try self.write("public int getValue() { return value; }\n");
        try self.write("\n");
        try self.ind();
        try self.print("public static {s}{s} valueOf(int v) {{\n", .{ pfx, e.name });
        try self.ind();
        try self.print(
            "    for ({s}{s} _e : values()) {{ if (_e.value == v) return _e; }}\n",
            .{ pfx, e.name },
        );
        try self.ind();
        try self.print(
            "    throw new RuntimeException(\"Unknown {s}{s} value: \" + v);\n",
            .{ pfx, e.name },
        );
        try self.ind();
        try self.write("}\n");

        self.depth -= 1;
        try self.ind();
        try self.print("}} // {s}{s}\n\n", .{ pfx, e.name });
    }

    // ── Bitmask ───────────────────────────────────────────────────────────────

    fn emitBitmask(self: *Generator, bm: *const ir.Bitmask) !void {
        const pfx = self.opts.type_prefix;
        const storage = bitmaskJavaType(bm.annotations);
        const cls_kw_bm = if (self.top_level and self.depth == 0) "public final class" else "public static final class";
        try self.ind();
        try self.print("{s} {s}{s} {{\n", .{ cls_kw_bm, pfx, bm.name });
        self.depth += 1;
        try self.ind();
        try self.print("private {s}{s}() {{}}\n", .{ pfx, bm.name });
        for (bm.bits, 0..) |bit, i| {
            try self.ind();
            try self.print(
                "public static final {s} {s} = ({s})(1 << {d});\n",
                .{ storage, bit.name, storage, i },
            );
        }
        self.depth -= 1;
        try self.ind();
        try self.print("}} // {s}{s}\n\n", .{ pfx, bm.name });
    }

    // ── Bitset ────────────────────────────────────────────────────────────────

    fn emitBitset(self: *Generator, bs: *const ir.Bitset) !void {
        const pfx = self.opts.type_prefix;
        const total = bitsetTotalBits(bs);
        const long_backing = total > 32;
        const backing_type: []const u8 = if (long_backing) "long" else "int";
        const cls_kw = if (self.top_level and self.depth == 0) "public final class" else "public static final class";

        try self.ind();
        try self.print("{s} {s}{s} implements java.io.Serializable {{\n", .{ cls_kw, pfx, bs.name });
        self.depth += 1;

        try self.ind();
        try self.write("private static final long serialVersionUID = 1L;\n");
        try self.ind();
        try self.print("private {s} _value = 0;\n", .{backing_type});

        // Getters and setters — accumulate bit position from LSB
        var bit_pos: u32 = 0;
        for (bs.fields) |field| {
            if (field.names.len == 0) {
                bit_pos += field.bits;
                continue;
            }
            const w = field.bits;
            const mask: u64 = if (w >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(w)) - 1;
            const field_type = bitsetFieldJavaType(w);
            const pos = bit_pos;

            for (field.names) |fname| {
                try self.write("\n");
                try self.ind();
                // getter
                if (w == 1) {
                    if (long_backing) {
                        try self.print("public boolean get_{s}() {{ return ((_value >>> {d}) & 0x{X}L) != 0L; }}\n", .{ fname, pos, mask });
                    } else {
                        try self.print("public boolean get_{s}() {{ return ((_value >>> {d}) & 0x{X}) != 0; }}\n", .{ fname, pos, mask });
                    }
                } else {
                    if (long_backing) {
                        try self.print("public {s} get_{s}() {{ return ({s})((_value >>> {d}) & 0x{X}L); }}\n", .{ field_type, fname, field_type, pos, mask });
                    } else {
                        try self.print("public {s} get_{s}() {{ return ({s})((_value >>> {d}) & 0x{X}); }}\n", .{ field_type, fname, field_type, pos, mask });
                    }
                }
                try self.ind();
                // setter
                if (w == 1) {
                    if (long_backing) {
                        try self.print("public void set_{s}(boolean val) {{ _value = (_value & ~(0x{X}L << {d})) | ((val ? 1L : 0L) << {d}); }}\n", .{ fname, mask, pos, pos });
                    } else {
                        try self.print("public void set_{s}(boolean val) {{ _value = (_value & ~(0x{X} << {d})) | ((val ? 1 : 0) << {d}); }}\n", .{ fname, mask, pos, pos });
                    }
                } else {
                    const cast = if (long_backing) "(long)" else if (std.mem.eql(u8, field_type, "int")) "(int)" else if (std.mem.eql(u8, field_type, "short")) "(int)" else "(int)";
                    if (long_backing) {
                        try self.print("public void set_{s}({s} val) {{ _value = (_value & ~(0x{X}L << {d})) | (({s}val & 0x{X}L) << {d}); }}\n", .{ fname, field_type, mask, pos, cast, mask, pos });
                    } else {
                        try self.print("public void set_{s}({s} val) {{ _value = (_value & ~(0x{X} << {d})) | (({s}val & 0x{X}) << {d}); }}\n", .{ fname, field_type, mask, pos, cast, mask, pos });
                    }
                }
            }
            bit_pos += w;
        }

        // CDR serialize / deserializeFrom
        if (!self.opts.no_typesupport and total > 0) {
            try self.write("\n");
            try self.ind();
            try self.write("public void serialize(java.nio.ByteBuffer _buf, int _cdrBase) {\n");
            self.depth += 1;
            try self.ind();
            try self.write("_buf.order(java.nio.ByteOrder.LITTLE_ENDIAN);\n");
            try self.ind();
            if (total <= 8) {
                try self.write("_buf.put((byte)(_value & 0xFF));\n");
            } else if (total <= 16) {
                try self.write("_cdrAlign(_buf, _cdrBase, 2); _buf.putShort((short)(_value & 0xFFFF));\n");
            } else if (total <= 32) {
                try self.write("_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(_value);\n");
            } else {
                try self.write("_cdrAlign(_buf, _cdrBase, 4); _buf.putLong(_value);\n");
            }
            self.depth -= 1;
            try self.ind();
            try self.write("}\n");

            try self.write("\n");
            try self.ind();
            try self.print("public static {s}{s} deserializeFrom(java.nio.ByteBuffer _buf, int _cdrBase) {{\n", .{ pfx, bs.name });
            self.depth += 1;
            try self.ind();
            try self.write("_buf.order(java.nio.ByteOrder.LITTLE_ENDIAN);\n");
            try self.ind();
            try self.print("{s}{s} _out = new {s}{s}();\n", .{ pfx, bs.name, pfx, bs.name });
            try self.ind();
            if (total <= 8) {
                try self.write("_out._value = (_buf.get() & 0xFF);\n");
            } else if (total <= 16) {
                try self.write("_cdrAlign(_buf, _cdrBase, 2); _out._value = (_buf.getShort() & 0xFFFF);\n");
            } else if (total <= 32) {
                try self.write("_cdrAlign(_buf, _cdrBase, 4); _out._value = _buf.getInt();\n");
            } else {
                try self.write("_cdrAlign(_buf, _cdrBase, 4); _out._value = _buf.getLong();\n");
            }
            try self.ind();
            try self.write("return _out;\n");
            self.depth -= 1;
            try self.ind();
            try self.write("}\n");
        }

        self.depth -= 1;
        try self.ind();
        try self.print("}} // {s}{s}\n\n", .{ pfx, bs.name });
    }

    // ── Typedef ───────────────────────────────────────────────────────────────

    fn emitTypedef(self: *Generator, t: *const ir.Typedef) !void {
        try self.ind();
        try self.print(
            "// IDL typedef {s} — transparent in Java; use the underlying type\n\n",
            .{t.name},
        );
    }

    // ── Native ────────────────────────────────────────────────────────────────

    fn emitNative(self: *Generator, n: *const ir.Native) !void {
        try self.ind();
        try self.print(
            "// IDL native {s} — platform-specific; no Java mapping\n\n",
            .{n.name},
        );
    }

    // ── Exception ─────────────────────────────────────────────────────────────

    fn emitException(self: *Generator, ex: *const ir.Exception) !void {
        const pfx = self.opts.type_prefix;
        const cls_kw_ex = if (self.top_level and self.depth == 0) "public class" else "public static class";
        try self.ind();
        try self.print(
            "{s} {s}{s} extends RuntimeException {{\n",
            .{ cls_kw_ex, pfx, ex.name },
        );
        self.depth += 1;
        try self.ind();
        try self.write("private static final long serialVersionUID = 1L;\n");

        for (ex.members) |m| {
            const java_type = try self.typeRefToJava(m.type_ref, m.dimensions);
            defer self.alloc.free(java_type);
            try self.ind();
            try self.print("private {s} {s};\n", .{ java_type, m.name });
        }

        try self.write("\n");
        try self.ind();
        try self.print("public {s}{s}() {{ super(); }}\n", .{ pfx, ex.name });

        if (ex.members.len > 0) {
            try self.ind();
            try self.print("public {s}{s}(", .{ pfx, ex.name });
            for (ex.members, 0..) |m, i| {
                const java_type = try self.typeRefToJava(m.type_ref, m.dimensions);
                defer self.alloc.free(java_type);
                if (i > 0) try self.write(", ");
                try self.print("{s} {s}", .{ java_type, m.name });
            }
            try self.write(") {\n");
            try self.ind();
            try self.write("    super();\n");
            for (ex.members) |m| {
                try self.ind();
                try self.print("    this.{s} = {s};\n", .{ m.name, m.name });
            }
            try self.ind();
            try self.write("}\n");
        }

        for (ex.members) |m| {
            const java_type = try self.typeRefToJava(m.type_ref, m.dimensions);
            defer self.alloc.free(java_type);
            try self.write("\n");
            try self.ind();
            try self.print(
                "public {s} get_{s}() {{ return {s}; }}\n",
                .{ java_type, m.name, m.name },
            );
            try self.ind();
            try self.print(
                "public void set_{s}({s} {s}) {{ this.{s} = {s}; }}\n",
                .{ m.name, java_type, m.name, m.name, m.name },
            );
        }

        self.depth -= 1;
        try self.ind();
        try self.print("}} // {s}{s}\n\n", .{ pfx, ex.name });
    }

    // ── Interface ─────────────────────────────────────────────────────────────

    fn emitInterface(self: *Generator, iface: *const ir.Interface) anyerror!void {
        const pfx = self.opts.type_prefix;
        try self.ind();
        try self.print("public interface {s}{s}", .{ pfx, iface.name });
        if (iface.bases.len > 0) {
            try self.write(" extends ");
            for (iface.bases, 0..) |base, i| {
                if (i > 0) try self.write(", ");
                const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(qname);
                try self.write(qname);
            }
        }
        try self.write(" {\n");
        self.depth += 1;

        // Nested type declarations
        for (iface.type_decls) |td| try self.emitTypeDecl(td);
        for (iface.consts) |*c| try self.emitConst(c);

        // Operations
        for (iface.operations) |op| {
            try self.ind();
            if (op.return_type) |ret| {
                const ret_java = try self.typeRefToJava(ret, &.{});
                defer self.alloc.free(ret_java);
                try self.print("{s} {s}(", .{ ret_java, op.name });
            } else {
                try self.print("void {s}(", .{op.name});
            }
            for (op.params, 0..) |p, i| {
                const pt = try self.typeRefToJava(p.type_ref, &.{});
                defer self.alloc.free(pt);
                if (i > 0) try self.write(", ");
                try self.print("{s} {s}", .{ pt, p.name });
            }
            try self.write(");\n");
        }

        // Attributes
        for (iface.attributes) |attr| {
            const at = try self.typeRefToJava(attr.type_ref, &.{});
            defer self.alloc.free(at);
            try self.ind();
            try self.print("{s} get_{s}();\n", .{ at, attr.name });
            if (!attr.readonly) {
                try self.ind();
                try self.print("void set_{s}({s} value);\n", .{ attr.name, at });
            }
        }

        self.depth -= 1;
        try self.ind();
        try self.print("}} // interface {s}{s}\n\n", .{ pfx, iface.name });
    }

    // ── Const ─────────────────────────────────────────────────────────────────

    fn emitConst(self: *Generator, c: *const ir.Const) !void {
        const pfx = self.opts.type_prefix;
        const java_type = try self.typeRefToJava(c.type_ref, &.{});
        defer self.alloc.free(java_type);

        const cls_kw_c = if (self.top_level and self.depth == 0) "public final class" else "public static final class";
        try self.ind();
        try self.print("{s} {s}{s} {{\n", .{ cls_kw_c, pfx, c.name });
        self.depth += 1;
        try self.ind();
        try self.print("private {s}{s}() {{}}\n", .{ pfx, c.name });
        try self.ind();
        try self.print("public static final {s} value = ", .{java_type});
        try self.emitConstValue(c.type_ref, c.value);
        try self.write(";\n");
        self.depth -= 1;
        try self.ind();
        try self.print("}} // {s}{s}\n\n", .{ pfx, c.name });
    }

    fn emitConstValue(self: *Generator, type_ref: ir.TypeRef, val: anytype) !void {
        // Determine if this is a long type (needs 'L' suffix).
        const is_long = switch (type_ref) {
            .base => |b| switch (b) {
                .long_long, .unsigned_long_long, .int64, .uint64 => true,
                else => false,
            },
            else => false,
        };
        const is_float = switch (type_ref) {
            .base => |b| b == .float,
            else => false,
        };

        switch (val) {
            .integer => |v| {
                if (is_long) {
                    try self.print("{d}L", .{v});
                } else {
                    try self.print("{d}", .{v});
                }
            },
            .float => |v| {
                if (is_float) {
                    try self.print("{d}f", .{v});
                } else {
                    try self.print("{d}", .{v});
                }
            },
            .boolean => |v| try self.write(if (v) "true" else "false"),
            .character => |ch| {
                if (std.ascii.isPrint(ch) and ch != '\'' and ch != '\\') {
                    try self.print("'{c}'", .{ch});
                } else {
                    try self.print("(char)0x{X:0>2}", .{ch});
                }
            },
            .string => |s| {
                try self.write("\"");
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
                try self.write("\"");
            },
            .wide_character => |wc| try self.print("(char)0x{X:0>4}", .{wc}),
            .wide_string => try self.write("\"\""),
            .fixed_pt => |fp| try self.write(fp),
        }
    }

    // ── CDR serialization emission ────────────────────────────────────────────

    fn emitStructSerializeFns(self: *Generator, s: *const ir.Struct) anyerror!void {
        const ext = s.annotations.extensibility;
        const appendable = ext == .appendable;
        const mutable = ext == .mutable;

        const has_key = structHasKeyJava(s);

        try self.write("\n");
        try self.ind();
        try self.print("public static final boolean HAS_KEY = {s};\n", .{if (has_key) "true" else "false"});

        // serialize
        try self.write("\n");
        try self.ind();
        try self.write("public void serialize(java.nio.ByteBuffer _buf, int _cdrBase) {\n");
        try self.ind();
        try self.write("    _buf.order(java.nio.ByteOrder.LITTLE_ENDIAN);\n");

        if (mutable) {
            // @mutable: DHEADER + per-member EMHEADER framing.
            try self.ind();
            try self.write("    _cdrAlign(_buf, _cdrBase, 4);\n");
            try self.ind();
            try self.write("    int _dhPos = _buf.position(); _buf.putInt(0);\n");
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAtJava(m, idx);
                const mu_flag = m.annotations.must_understand;
                const lc_opt = lcForJavaTypeRef(m.type_ref, m.dimensions);
                // Variable-length EMHEADER word (LC=4, always followed by NEXTINT):
                const vword: u32 = (if (mu_flag) @as(u32, 0x8000_0000) else 0) | 0x4000_0000 | member_id;
                // Fixed-length EMHEADER word (LC=0..3):
                const fword: u32 = if (lc_opt) |lc|
                    (if (mu_flag) @as(u32, 0x8000_0000) else 0) | (@as(u32, lc) << 28) | member_id
                else
                    vword;
                if (m.annotations.is_optional) {
                    // @mutable + @optional: only emit EMHEADER when value is present.
                    try self.ind();
                    try self.print("    if (this.{s} != null) {{\n", .{m.name});
                    try self.ind();
                    if (lc_opt) |_| {
                        try self.print("        _cdrAlign(_buf, _cdrBase, 4); _buf.putInt(0x{X:0>8});\n", .{fword});
                    } else {
                        try self.print("        _cdrAlign(_buf, _cdrBase, 4); _buf.putInt(0x{X:0>8}); int _niPos_{s} = _buf.position(); _buf.putInt(0);\n", .{ vword, m.name });
                    }
                    const access = try std.fmt.allocPrint(self.alloc, "this.{s}", .{m.name});
                    defer self.alloc.free(access);
                    if (m.dimensions.len > 0) {
                        try self.emitSerializeArray(m.type_ref, access, m.dimensions, "        ", 0);
                    } else {
                        try self.emitSerializeForTypeRef(m.type_ref, access, "        ");
                    }
                    if (lc_opt == null) {
                        try self.ind();
                        try self.print("        _buf.putInt(_niPos_{s}, _buf.position() - _niPos_{s} - 4);\n", .{ m.name, m.name });
                    }
                    try self.ind();
                    try self.write("    }\n");
                } else {
                    try self.ind();
                    if (lc_opt) |_| {
                        try self.print("    _cdrAlign(_buf, _cdrBase, 4); _buf.putInt(0x{X:0>8});\n", .{fword});
                    } else {
                        try self.print("    _cdrAlign(_buf, _cdrBase, 4); _buf.putInt(0x{X:0>8}); int _niPos_{s} = _buf.position(); _buf.putInt(0);\n", .{ vword, m.name });
                    }
                    try self.emitMemberSerialize(m, "    ");
                    if (lc_opt == null) {
                        try self.ind();
                        try self.print("    _buf.putInt(_niPos_{s}, _buf.position() - _niPos_{s} - 4);\n", .{ m.name, m.name });
                    }
                }
            }
            try self.ind();
            try self.write("    _buf.putInt(_dhPos, _buf.position() - _dhPos - 4);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("    _cdrAlign(_buf, _cdrBase, 4);\n");
                try self.ind();
                try self.write("    int _dhPos = _buf.position(); _buf.putInt(0);\n");
            }

            if (s.base) |base| {
                const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(qname);
                try self.ind();
                try self.print("    super.serialize(_buf, _cdrBase);\n", .{});
            }

            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: write bool presence flag (1 byte, no alignment), then value if present.
                    try self.ind();
                    try self.print("    _buf.put(this.{s} != null ? (byte)1 : (byte)0);\n", .{m.name});
                    try self.ind();
                    try self.print("    if (this.{s} != null) {{\n", .{m.name});
                    const access = try std.fmt.allocPrint(self.alloc, "this.{s}", .{m.name});
                    defer self.alloc.free(access);
                    if (m.dimensions.len > 0) {
                        try self.emitSerializeArray(m.type_ref, access, m.dimensions, "        ", 0);
                    } else {
                        try self.emitSerializeForTypeRef(m.type_ref, access, "        ");
                    }
                    try self.ind();
                    try self.write("    }\n");
                    continue;
                }
                try self.emitMemberSerialize(m, "    ");
            }

            if (appendable) {
                try self.ind();
                try self.write("    _buf.putInt(_dhPos, _buf.position() - _dhPos - 4);\n");
            }
        }
        try self.ind();
        try self.write("}\n");

        // deserializeFrom
        try self.write("\n");
        try self.ind();
        try self.print("public static {s}{s} deserializeFrom(java.nio.ByteBuffer _buf, int _cdrBase) {{\n", .{ self.opts.type_prefix, s.name });
        try self.ind();
        try self.write("    _buf.order(java.nio.ByteOrder.LITTLE_ENDIAN);\n");
        try self.ind();
        try self.print("    {s}{s} _out = new {s}{s}();\n", .{ self.opts.type_prefix, s.name, self.opts.type_prefix, s.name });

        if (mutable) {
            // @mutable: read DHEADER for end pos, loop on EMHEADER-framed members.
            try self.ind();
            try self.write("    _cdrAlign(_buf, _cdrBase, 4); int _emEnd = _buf.position() + _buf.getInt();\n");
            try self.ind();
            try self.write("    while (_buf.position() < _emEnd) {\n");
            try self.ind();
            try self.write("        _cdrAlign(_buf, _cdrBase, 4); int _emWord = _buf.getInt(); int _memberId = _emWord & 0x0FFFFFFF;\n");
            try self.ind();
            try self.write("        int _emLc = (_emWord >>> 28) & 0x7; int _emPayload; if (_emLc == 0) _emPayload = 1; else if (_emLc == 1) _emPayload = 2; else if (_emLc == 2) _emPayload = 4; else if (_emLc == 3) _emPayload = 8; else _emPayload = _buf.getInt();\n");
            try self.ind();
            try self.write("        switch (_memberId) {\n");
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAtJava(m, idx);
                try self.ind();
                try self.print("            case {d}:\n", .{member_id});
                if (m.annotations.is_optional) {
                    // @mutable + @optional: EMHEADER presence = value present; no bool flag.
                    const out_expr = try std.fmt.allocPrint(self.alloc, "_out.{s}", .{m.name});
                    defer self.alloc.free(out_expr);
                    if (m.dimensions.len > 0) {
                        try self.emitDeserializeArray(m.type_ref, out_expr, m.dimensions, "                ", 0);
                    } else {
                        try self.emitDeserializeForTypeRef(m.type_ref, out_expr, "                ");
                    }
                } else {
                    try self.emitMemberDeserialize(m, "_out", "                ");
                }
                try self.ind();
                try self.write("                break;\n");
            }
            try self.ind();
            try self.write("            default: _buf.position(_buf.position() + _emPayload); break;\n");
            try self.ind();
            try self.write("        }\n");
            try self.ind();
            try self.write("    }\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("    _cdrAlign(_buf, _cdrBase, 4); _buf.getInt(); // skip DHEADER\n");
            }

            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: read bool presence flag (1 byte), then value if present.
                    try self.ind();
                    try self.print("    {{ boolean _ip_{s} = _buf.get() != 0;\n", .{m.name});
                    try self.ind();
                    try self.print("      if (_ip_{s}) {{\n", .{m.name});
                    const out_expr = try std.fmt.allocPrint(self.alloc, "_out.{s}", .{m.name});
                    defer self.alloc.free(out_expr);
                    if (m.dimensions.len > 0) {
                        try self.emitDeserializeArray(m.type_ref, out_expr, m.dimensions, "        ", 0);
                    } else {
                        try self.emitDeserializeForTypeRef(m.type_ref, out_expr, "        ");
                    }
                    try self.ind();
                    try self.write("      } else {\n");
                    try self.ind();
                    try self.print("        _out.{s} = null;\n", .{m.name});
                    try self.ind();
                    try self.write("      }\n    }\n");
                    continue;
                }
                try self.emitMemberDeserialize(m, "_out", "    ");
            }
        }

        try self.ind();
        try self.write("    return _out;\n");
        try self.ind();
        try self.write("}\n");

        // skip
        try self.write("\n");
        try self.ind();
        try self.write("public static void skip(java.nio.ByteBuffer _buf, int _cdrBase) {\n");
        try self.ind();
        try self.write("    _buf.order(java.nio.ByteOrder.LITTLE_ENDIAN);\n");
        if (mutable) {
            try self.ind();
            try self.write("    _cdrAlign(_buf, _cdrBase, 4); int _end = _buf.position() + _buf.getInt();\n");
            try self.ind();
            try self.write("    _buf.position(_end);\n");
        } else if (appendable) {
            try self.ind();
            try self.write("    _cdrAlign(_buf, _cdrBase, 4); int _end = _buf.position() + 4 + _buf.getInt();\n");
            try self.ind();
            try self.write("    _buf.position(_end);\n");
        } else {
            if (s.base) |base| {
                const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(qname);
                try self.ind();
                try self.print("    {s}.skip(_buf, _cdrBase);\n", .{qname});
            }
            for (s.members) |m| {
                try self.emitMemberSkip(m, "    ");
            }
        }
        try self.ind();
        try self.write("}\n");

        // serializeKey / deserializeKey / computeKeyHash (only if has_key)
        if (has_key) {
            try self.write("\n");
            try self.ind();
            try self.write("protected void serializeKeyFields(java.nio.ByteBuffer _buf, int _cdrBase) {\n");
            if (s.base) |base| {
                if (typeDeclHasKeyJava(base)) {
                    try self.ind();
                    try self.write("    super.serializeKeyFields(_buf, _cdrBase);\n");
                }
            }
            for (s.members) |m| {
                if (!m.annotations.is_key) continue;
                try self.emitMemberSerialize(m, "    ");
            }
            try self.ind();
            try self.write("}\n");

            try self.write("\n");
            try self.ind();
            try self.write("public void serializeKey(java.nio.ByteBuffer _buf, int _cdrBase) {\n");
            try self.ind();
            try self.write("    _buf.order(java.nio.ByteOrder.LITTLE_ENDIAN);\n");
            try self.ind();
            try self.write("    serializeKeyFields(_buf, _cdrBase);\n");
            try self.ind();
            try self.write("}\n");

            try self.write("\n");
            try self.ind();
            try self.print("public static {s}{s} deserializeKey(java.nio.ByteBuffer _buf, int _cdrBase) {{\n", .{ self.opts.type_prefix, s.name });
            try self.ind();
            try self.write("    _buf.order(java.nio.ByteOrder.LITTLE_ENDIAN);\n");
            try self.ind();
            try self.print("    {s}{s} _out = new {s}{s}();\n", .{ self.opts.type_prefix, s.name, self.opts.type_prefix, s.name });
            try self.ind();
            try self.write("    deserializeKeyInto(_out, _buf, _cdrBase);\n");
            try self.ind();
            try self.write("    return _out;\n");
            try self.ind();
            try self.write("}\n");

            try self.write("\n");
            try self.ind();
            try self.print("protected static void deserializeKeyInto({s}{s} _out, java.nio.ByteBuffer _buf, int _cdrBase) {{\n", .{ self.opts.type_prefix, s.name });
            if (mutable) {
                try self.ind();
                try self.write("    _cdrAlign(_buf, _cdrBase, 4); int _emEnd = _buf.position() + _buf.getInt();\n");
                try self.ind();
                try self.write("    while (_buf.position() < _emEnd) {\n");
                try self.ind();
                try self.write("        _cdrAlign(_buf, _cdrBase, 4); int _emWord = _buf.getInt(); int _memberId = _emWord & 0x0FFFFFFF;\n");
                try self.ind();
                try self.write("        int _emLc = (_emWord >>> 28) & 0x7; int _emPayload; if (_emLc == 0) _emPayload = 1; else if (_emLc == 1) _emPayload = 2; else if (_emLc == 2) _emPayload = 4; else if (_emLc == 3) _emPayload = 8; else _emPayload = _buf.getInt();\n");
                try self.ind();
                try self.write("        switch (_memberId) {\n");
                for (s.members, 0..) |m, idx| {
                    if (!m.annotations.is_key) continue;
                    const member_id: u32 = memberIdAtJava(m, idx);
                    try self.ind();
                    try self.print("            case {d}:\n", .{member_id});
                    try self.emitMemberDeserializePresent(m, "_out", "                ");
                    try self.ind();
                    try self.write("                break;\n");
                }
                try self.ind();
                try self.write("            default: _buf.position(_buf.position() + _emPayload); break;\n");
                try self.ind();
                try self.write("        }\n");
                try self.ind();
                try self.write("    }\n");
            } else {
                if (appendable) {
                    try self.ind();
                    try self.write("    _cdrAlign(_buf, _cdrBase, 4); int _keyEnd = _buf.position() + 4 + _buf.getInt();\n");
                }
                if (s.base) |base| {
                    const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(qname);
                    if (typeDeclHasKeyJava(base)) {
                        try self.ind();
                        try self.print("    {s}.deserializeKeyInto(_out, _buf, _cdrBase);\n", .{qname});
                    } else {
                        try self.ind();
                        try self.print("    {s}.skip(_buf, _cdrBase);\n", .{qname});
                    }
                }
                for (s.members) |m| {
                    if (m.annotations.is_key) {
                        try self.emitMemberDeserializeKey(m, "_out", "    ");
                    } else {
                        try self.emitMemberSkip(m, "    ");
                    }
                }
                if (appendable) {
                    try self.ind();
                    try self.write("    _buf.position(_keyEnd);\n");
                }
            }
            try self.ind();
            try self.write("}\n");

            try self.write("\n");
            try self.ind();
            try self.write("public byte[] computeKeyHash() {\n");
            try self.ind();
            try self.write("    int _cap = 256;\n");
            try self.ind();
            try self.write("    while (true) {\n");
            try self.ind();
            try self.write("        java.nio.ByteBuffer _buf = java.nio.ByteBuffer.allocate(_cap).order(java.nio.ByteOrder.BIG_ENDIAN);\n");
            try self.ind();
            try self.write("        try {\n");
            try self.ind();
            try self.write("            serializeKeyFields(_buf, 0);\n");
            try self.ind();
            try self.write("            return _cdrComputeKeyHash(_buf);\n");
            try self.ind();
            try self.write("        } catch (java.nio.BufferOverflowException _e) {\n");
            try self.ind();
            try self.write("            _cap *= 2;\n");
            try self.ind();
            try self.write("        }\n");
            try self.ind();
            try self.write("    }\n");
            try self.ind();
            try self.write("}\n");
        }
    }

    /// Emit CDR write statement(s) for one struct member.
    fn emitMemberSerialize(
        self: *Generator,
        m: ir.StructMember,
        extra: []const u8,
    ) anyerror!void {
        const access = try std.fmt.allocPrint(self.alloc, "this.{s}", .{m.name});
        defer self.alloc.free(access);
        if (m.dimensions.len > 0) {
            try self.emitSerializeArray(m.type_ref, access, m.dimensions, extra, 0);
        } else {
            try self.emitSerializeForTypeRef(m.type_ref, access, extra);
        }
    }

    /// Emit CDR read statement(s) for one struct member into `out_var`.
    fn emitMemberDeserialize(
        self: *Generator,
        m: ir.StructMember,
        out_var: []const u8,
        extra: []const u8,
    ) anyerror!void {
        const out_expr = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ out_var, m.name });
        defer self.alloc.free(out_expr);
        if (m.dimensions.len > 0) {
            try self.emitDeserializeArray(m.type_ref, out_expr, m.dimensions, extra, 0);
        } else {
            try self.emitDeserializeForTypeRef(m.type_ref, out_expr, extra);
        }
    }

    fn emitMemberDeserializeKey(
        self: *Generator,
        m: ir.StructMember,
        out_var: []const u8,
        extra: []const u8,
    ) anyerror!void {
        const out_expr = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ out_var, m.name });
        defer self.alloc.free(out_expr);
        if (m.annotations.is_optional) {
            try self.ind();
            try self.print("{s}{{ boolean _present_{s} = _buf.get() != 0;\n", .{ extra, m.name });
            try self.ind();
            try self.print("{s}  if (_present_{s}) {{\n", .{ extra, m.name });
            const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
            defer self.alloc.free(inner);
            if (m.dimensions.len > 0) {
                try self.emitDeserializeArray(m.type_ref, out_expr, m.dimensions, inner, 0);
            } else {
                try self.emitDeserializeForTypeRef(m.type_ref, out_expr, inner);
            }
            try self.ind();
            try self.print("{s}  }} else {{ {s} = null; }}\n", .{ extra, out_expr });
            try self.ind();
            try self.print("{s}}}\n", .{extra});
            return;
        }
        if (m.dimensions.len > 0) {
            try self.emitDeserializeArray(m.type_ref, out_expr, m.dimensions, extra, 0);
        } else {
            try self.emitDeserializeForTypeRef(m.type_ref, out_expr, extra);
        }
    }

    fn emitMemberDeserializePresent(
        self: *Generator,
        m: ir.StructMember,
        out_var: []const u8,
        extra: []const u8,
    ) anyerror!void {
        const out_expr = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ out_var, m.name });
        defer self.alloc.free(out_expr);
        if (m.dimensions.len > 0) {
            try self.emitDeserializeArray(m.type_ref, out_expr, m.dimensions, extra, 0);
        } else {
            try self.emitDeserializeForTypeRef(m.type_ref, out_expr, extra);
        }
    }

    fn emitMemberSkip(self: *Generator, m: ir.StructMember, extra: []const u8) anyerror!void {
        if (m.annotations.is_optional) {
            try self.ind();
            try self.print("{s}{{ boolean _present_{s} = _buf.get() != 0;\n", .{ extra, m.name });
            try self.ind();
            try self.print("{s}  if (_present_{s}) {{\n", .{ extra, m.name });
            const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
            defer self.alloc.free(inner);
            if (m.dimensions.len > 0) {
                try self.emitSkipArray(m.type_ref, m.dimensions, inner, 0);
            } else {
                try self.emitSkipForTypeRef(m.type_ref, inner);
            }
            try self.ind();
            try self.print("{s}  }}\n", .{extra});
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

    fn emitSkipArray(
        self: *Generator,
        elem_tr: ir.TypeRef,
        dims: []const u64,
        extra: []const u8,
        depth: usize,
    ) anyerror!void {
        const idx = try std.fmt.allocPrint(self.alloc, "_sk{d}", .{depth});
        defer self.alloc.free(idx);
        try self.ind();
        try self.print(
            "{s}for (int {s} = 0; {s} < {d}; {s}++) {{\n",
            .{ extra, idx, idx, dims[0], idx },
        );
        const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(inner);
        if (dims.len > 1) {
            try self.emitSkipArray(elem_tr, dims[1..], inner, depth + 1);
        } else {
            try self.emitSkipForTypeRef(elem_tr, inner);
        }
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    fn emitSkipForTypeRef(self: *Generator, tr: ir.TypeRef, extra: []const u8) anyerror!void {
        switch (tr) {
            .base => |b| {
                const align_v = baseCdrAlign(b);
                try self.ind();
                if (align_v > 1) {
                    try self.print("{s}_cdrAlign(_buf, _cdrBase, {d}); ", .{ extra, align_v });
                } else {
                    try self.print("{s}", .{extra});
                }
                switch (b) {
                    .boolean, .char, .octet, .int8, .uint8 => try self.write("_buf.get();\n"),
                    .short, .int16, .unsigned_short, .uint16, .wchar => try self.write("_buf.getShort();\n"),
                    .long, .int32, .unsigned_long, .uint32, .float => try self.write("_buf.getInt();\n"),
                    .long_long, .int64, .unsigned_long_long, .uint64, .double, .long_double => try self.write("_buf.getLong();\n"),
                    .any, .object, .value_base => try self.write("throw new IllegalArgumentException(\"unsupported CDR skip type\");\n"),
                }
            },
            .string, .wstring => {
                try self.ind();
                try self.print("{s}_cdrReadString(_buf, _cdrBase);\n", .{extra});
            },
            .sequence => |seq| {
                try self.ind();
                try self.print("{s}{{ _cdrAlign(_buf, _cdrBase, 4); int _n = _buf.getInt();\n", .{extra});
                try self.ind();
                try self.print("{s}  for (int _i = 0; _i < _n; _i++) {{\n", .{extra});
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.emitSkipForTypeRef(seq.element.*, inner);
                try self.ind();
                try self.print("{s}  }}\n", .{extra});
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .map => |m| {
                try self.ind();
                try self.print("{s}{{ _cdrAlign(_buf, _cdrBase, 4); int _n = _buf.getInt();\n", .{extra});
                try self.ind();
                try self.print("{s}  for (int _i = 0; _i < _n; _i++) {{\n", .{extra});
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.emitSkipForTypeRef(m.key.*, inner);
                try self.emitSkipForTypeRef(m.value.*, inner);
                try self.ind();
                try self.print("{s}  }}\n", .{extra});
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .named => |td| switch (td) {
                .enum_ => {
                    try self.ind();
                    try self.print("{s}_cdrAlign(_buf, _cdrBase, 4); _buf.getInt();\n", .{extra});
                },
                .bitmask => |bm| {
                    const storage = bitmaskJavaType(bm.annotations);
                    const method = if (std.mem.eql(u8, storage, "long")) "getLong" else "getInt";
                    try self.ind();
                    try self.print("{s}_cdrAlign(_buf, _cdrBase, 4); _buf.{s}();\n", .{ extra, method });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitSkipArray(t.type_ref, t.dimensions, extra, 0);
                    } else {
                        try self.emitSkipForTypeRef(t.type_ref, extra);
                    }
                },
                .struct_ => {
                    const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(qname);
                    try self.ind();
                    try self.print("{s}{s}.skip(_buf, _cdrBase);\n", .{ extra, qname });
                },
                .union_, .bitset => {
                    const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(qname);
                    try self.ind();
                    try self.print("{s}{s}.deserializeFrom(_buf, _cdrBase);\n", .{ extra, qname });
                },
                else => {
                    try self.ind();
                    try self.print("{s}throw new IllegalArgumentException(\"unsupported CDR skip type\");\n", .{extra});
                },
            },
            .fixed_pt => |fp| {
                try self.ind();
                try self.print("{s}_cdrReadFixed(_buf, {d}, {d});\n", .{ extra, fp.digits, fp.scale });
            },
        }
    }

    fn emitSerializeForTypeRef(
        self: *Generator,
        tr: ir.TypeRef,
        access: []const u8,
        extra: []const u8,
    ) anyerror!void {
        switch (tr) {
            .base => |b| {
                const align_v = baseCdrAlign(b);
                try self.ind();
                if (align_v > 1) {
                    try self.print("{s}_cdrAlign(_buf, _cdrBase, {d}); ", .{ extra, align_v });
                } else {
                    try self.print("{s}", .{extra});
                }
                switch (b) {
                    .boolean => try self.print("_buf.put((byte)({s} ? 1 : 0));\n", .{access}),
                    .char => try self.print("_buf.put((byte){s});\n", .{access}),
                    .wchar => try self.print("_buf.putShort((short){s});\n", .{access}),
                    .octet, .int8, .uint8 => try self.print("_buf.put({s});\n", .{access}),
                    .short, .int16, .unsigned_short, .uint16 => try self.print("_buf.putShort({s});\n", .{access}),
                    .long, .int32, .unsigned_long, .uint32 => try self.print("_buf.putInt({s});\n", .{access}),
                    .long_long, .int64, .unsigned_long_long, .uint64 => try self.print("_buf.putLong({s});\n", .{access}),
                    .float => try self.print("_buf.putFloat({s});\n", .{access}),
                    .double, .long_double => try self.print("_buf.putDouble({s});\n", .{access}),
                    .any, .object, .value_base => try self.print("// TODO: any/object {s}\n", .{access}),
                }
            },
            .string, .wstring => {
                try self.ind();
                try self.print(
                    "{s}_cdrWriteString(_buf, _cdrBase, {s});\n",
                    .{ extra, access },
                );
            },
            .sequence => |seq| {
                try self.ind();
                try self.print(
                    "{s}_cdrAlign(_buf, _cdrBase, 4); _buf.putInt({s}.size());\n",
                    .{ extra, access },
                );
                const elem_java = try self.typeRefToJavaElem(seq.element.*);
                defer self.alloc.free(elem_java);
                try self.ind();
                try self.print(
                    "{s}for ({s} _e : {s}) {{\n",
                    .{ extra, elem_java, access },
                );
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.emitSerializeForTypeRef(seq.element.*, "_e", inner);
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .named => |td| switch (td) {
                .enum_ => {
                    try self.ind();
                    try self.print(
                        "{s}_cdrAlign(_buf, _cdrBase, 4); _buf.putInt({s}.getValue());\n",
                        .{ extra, access },
                    );
                },
                .bitmask => |bm| {
                    const storage = bitmaskJavaType(bm.annotations);
                    const method = if (std.mem.eql(u8, storage, "long")) "putLong" else "putInt";
                    const align_v: u8 = if (std.mem.eql(u8, storage, "long")) 4 else 4;
                    try self.ind();
                    try self.print(
                        "{s}_cdrAlign(_buf, _cdrBase, {d}); _buf.{s}({s});\n",
                        .{ extra, align_v, method, access },
                    );
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitSerializeArray(t.type_ref, access, t.dimensions, extra, 0);
                    } else {
                        try self.emitSerializeForTypeRef(t.type_ref, access, extra);
                    }
                },
                .union_ => {
                    try self.ind();
                    try self.print("{s}{s}.serialize(_buf, _cdrBase);\n", .{ extra, access });
                },
                .bitset => {
                    try self.ind();
                    try self.print("{s}{s}.serialize(_buf, _cdrBase);\n", .{ extra, access });
                },
                else => {
                    // struct, exception, native, interface — call .serialize()
                    try self.ind();
                    try self.print("{s}{s}.serialize(_buf, _cdrBase);\n", .{ extra, access });
                },
            },
            .fixed_pt => |fp| {
                try self.ind();
                try self.print("{s}_cdrWriteFixed(_buf, {d}, {d}, {s});\n", .{ extra, fp.digits, fp.scale, access });
            },
            .map => |m| {
                const key_elem = try self.typeRefToJavaElem(m.key.*);
                defer self.alloc.free(key_elem);
                const val_elem = try self.typeRefToJavaElem(m.value.*);
                defer self.alloc.free(val_elem);
                try self.ind();
                try self.print("{s}_cdrAlign(_buf, _cdrBase, 4); _buf.putInt({s}.size());\n", .{ extra, access });
                try self.ind();
                try self.print("{s}for (java.util.Map.Entry<{s},{s}> _me : {s}.entrySet()) {{\n", .{ extra, key_elem, val_elem, access });
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.emitSerializeForTypeRef(m.key.*, "_me.getKey()", inner);
                try self.emitSerializeForTypeRef(m.value.*, "_me.getValue()", inner);
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
        }
    }

    fn emitDeserializeForTypeRef(
        self: *Generator,
        tr: ir.TypeRef,
        out_expr: []const u8,
        extra: []const u8,
    ) anyerror!void {
        switch (tr) {
            .base => |b| {
                const align_v = baseCdrAlign(b);
                const read_expr = baseCdrReadExpr(b);
                try self.ind();
                if (align_v > 1) {
                    try self.print(
                        "{s}_cdrAlign(_buf, _cdrBase, {d}); {s} = {s};\n",
                        .{ extra, align_v, out_expr, read_expr },
                    );
                } else {
                    try self.print("{s}{s} = {s};\n", .{ extra, out_expr, read_expr });
                }
            },
            .string, .wstring => {
                try self.ind();
                try self.print(
                    "{s}{s} = _cdrReadString(_buf, _cdrBase);\n",
                    .{ extra, out_expr },
                );
            },
            .sequence => |seq| {
                // Unique counter variable based on out_expr
                const safe_name = try safeName(self.alloc, out_expr);
                defer self.alloc.free(safe_name);
                const n_var = try std.fmt.allocPrint(self.alloc, "_n_{s}", .{safe_name});
                defer self.alloc.free(n_var);
                const i_var = try std.fmt.allocPrint(self.alloc, "_i_{s}", .{safe_name});
                defer self.alloc.free(i_var);

                try self.ind();
                try self.print(
                    "{s}_cdrAlign(_buf, _cdrBase, 4); int {s} = _buf.getInt();\n",
                    .{ extra, n_var },
                );

                // Determine the element type for the new ArrayList
                const list_elem = try self.typeRefToJavaElem(seq.element.*);
                defer self.alloc.free(list_elem);
                try self.ind();
                try self.print(
                    "{s}{s} = new java.util.ArrayList<>({s});\n",
                    .{ extra, out_expr, n_var },
                );
                try self.ind();
                try self.print(
                    "{s}for (int {s} = 0; {s} < {s}; {s}++) {{\n",
                    .{ extra, i_var, i_var, n_var, i_var },
                );
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.emitSequenceElemDeserialize(seq.element.*, out_expr, inner);
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const e_java = try self.qualNameToJava(e.qualified_name);
                    defer self.alloc.free(e_java);
                    try self.ind();
                    try self.print(
                        "{s}_cdrAlign(_buf, _cdrBase, 4); {s} = {s}.valueOf(_buf.getInt());\n",
                        .{ extra, out_expr, e_java },
                    );
                },
                .bitmask => |bm| {
                    const storage = bitmaskJavaType(bm.annotations);
                    const method = if (std.mem.eql(u8, storage, "long")) "getLong" else "getInt";
                    try self.ind();
                    try self.print(
                        "{s}_cdrAlign(_buf, _cdrBase, 4); {s} = _buf.{s}();\n",
                        .{ extra, out_expr, method },
                    );
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitDeserializeArray(t.type_ref, out_expr, t.dimensions, extra, 0);
                    } else {
                        try self.emitDeserializeForTypeRef(t.type_ref, out_expr, extra);
                    }
                },
                .union_ => {
                    const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(qname);
                    try self.ind();
                    try self.print(
                        "{s}{s} = {s}.deserializeFrom(_buf, _cdrBase);\n",
                        .{ extra, out_expr, qname },
                    );
                },
                .bitset => |bs| {
                    const qname = try self.qualNameToJava(bs.qualified_name);
                    defer self.alloc.free(qname);
                    try self.ind();
                    try self.print("{s}{s} = {s}.deserializeFrom(_buf, _cdrBase);\n", .{ extra, out_expr, qname });
                },
                else => {
                    // struct, exception, native, interface
                    const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(qname);
                    try self.ind();
                    try self.print(
                        "{s}{s} = {s}.deserializeFrom(_buf, _cdrBase);\n",
                        .{ extra, out_expr, qname },
                    );
                },
            },
            .fixed_pt => |fp| {
                try self.ind();
                try self.print("{s}{s} = _cdrReadFixed(_buf, {d}, {d});\n", .{ extra, out_expr, fp.digits, fp.scale });
            },
            .map => |m| {
                const safe_name = try safeName(self.alloc, out_expr);
                defer self.alloc.free(safe_name);
                const n_var = try std.fmt.allocPrint(self.alloc, "_mn_{s}", .{safe_name});
                defer self.alloc.free(n_var);
                const i_var = try std.fmt.allocPrint(self.alloc, "_mi_{s}", .{safe_name});
                defer self.alloc.free(i_var);
                const k_var = try std.fmt.allocPrint(self.alloc, "_mk_{s}", .{safe_name});
                defer self.alloc.free(k_var);
                const v_var = try std.fmt.allocPrint(self.alloc, "_mv_{s}", .{safe_name});
                defer self.alloc.free(v_var);
                const key_elem = try self.typeRefToJavaElem(m.key.*);
                defer self.alloc.free(key_elem);
                const val_elem = try self.typeRefToJavaElem(m.value.*);
                defer self.alloc.free(val_elem);
                try self.ind();
                try self.print("{s}_cdrAlign(_buf, _cdrBase, 4); int {s} = _buf.getInt();\n", .{ extra, n_var });
                try self.ind();
                try self.print("{s}{s} = new java.util.LinkedHashMap<>({s});\n", .{ extra, out_expr, n_var });
                try self.ind();
                try self.print("{s}for (int {s} = 0; {s} < {s}; {s}++) {{\n", .{ extra, i_var, i_var, n_var, i_var });
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.ind();
                try self.print("{s}{s} {s};\n", .{ inner, key_elem, k_var });
                try self.emitDeserializeForTypeRef(m.key.*, k_var, inner);
                try self.ind();
                try self.print("{s}{s} {s};\n", .{ inner, val_elem, v_var });
                try self.emitDeserializeForTypeRef(m.value.*, v_var, inner);
                try self.ind();
                try self.print("{s}{s}.put({s}, {s});\n", .{ inner, out_expr, k_var, v_var });
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
        }
    }

    fn emitSequenceElemDeserialize(
        self: *Generator,
        elem_tr: ir.TypeRef,
        seq_expr: []const u8,
        extra: []const u8,
    ) anyerror!void {
        switch (elem_tr) {
            .base => |b| {
                const align_v = baseCdrAlign(b);
                const read_expr = baseCdrReadExpr(b);
                try self.ind();
                if (align_v > 1) {
                    try self.print(
                        "{s}_cdrAlign(_buf, _cdrBase, {d}); {s}.add({s});\n",
                        .{ extra, align_v, seq_expr, read_expr },
                    );
                } else {
                    try self.print("{s}{s}.add({s});\n", .{ extra, seq_expr, read_expr });
                }
            },
            .string, .wstring => {
                try self.ind();
                try self.print(
                    "{s}{s}.add(_cdrReadString(_buf, _cdrBase));\n",
                    .{ extra, seq_expr },
                );
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const e_java = try self.qualNameToJava(e.qualified_name);
                    defer self.alloc.free(e_java);
                    try self.ind();
                    try self.print(
                        "{s}_cdrAlign(_buf, _cdrBase, 4); {s}.add({s}.valueOf(_buf.getInt()));\n",
                        .{ extra, seq_expr, e_java },
                    );
                },
                .typedef => |t| {
                    // Follow typedef chain for element
                    try self.emitSequenceElemDeserialize(t.type_ref, seq_expr, extra);
                },
                else => {
                    const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(qname);
                    try self.ind();
                    try self.print(
                        "{s}{s}.add({s}.deserializeFrom(_buf, _cdrBase));\n",
                        .{ extra, seq_expr, qname },
                    );
                },
            },
            else => {
                try self.ind();
                try self.print("{s}// TODO: seq elem deserialize\n", .{extra});
            },
        }
    }

    fn emitSerializeArray(
        self: *Generator,
        elem_tr: ir.TypeRef,
        access: []const u8,
        dims: []const u64,
        extra: []const u8,
        depth: usize,
    ) anyerror!void {
        if (dims.len == 0) {
            try self.emitSerializeForTypeRef(elem_tr, access, extra);
            return;
        }
        const idx = try std.fmt.allocPrint(self.alloc, "_d{d}", .{depth});
        defer self.alloc.free(idx);
        try self.ind();
        try self.print(
            "{s}for (int {s} = 0; {s} < {d}; {s}++) {{\n",
            .{ extra, idx, idx, dims[0], idx },
        );
        const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(inner);
        const elem_access = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ access, idx });
        defer self.alloc.free(elem_access);
        try self.emitSerializeArray(elem_tr, elem_access, dims[1..], inner, depth + 1);
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    fn emitDeserializeArray(
        self: *Generator,
        elem_tr: ir.TypeRef,
        base_access: []const u8,
        dims: []const u64,
        extra: []const u8,
        depth: usize,
    ) anyerror!void {
        if (dims.len == 0) {
            try self.emitDeserializeForTypeRef(elem_tr, base_access, extra);
            return;
        }
        const idx = try std.fmt.allocPrint(self.alloc, "_d{d}", .{depth});
        defer self.alloc.free(idx);
        try self.ind();
        try self.print(
            "{s}for (int {s} = 0; {s} < {d}; {s}++) {{\n",
            .{ extra, idx, idx, dims[0], idx },
        );
        const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(inner);
        const elem_access = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ base_access, idx });
        defer self.alloc.free(elem_access);
        try self.emitDeserializeArray(elem_tr, elem_access, dims[1..], inner, depth + 1);
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    // ── Type-ref → Java type string ───────────────────────────────────────────

    /// Convert a TypeRef + array dimensions to a complete Java type string.
    /// Follows typedef chains, combining dimensions.
    /// Caller owns the returned slice.
    fn typeRefToJava(self: *Generator, tr: ir.TypeRef, dims: []const u64) anyerror![]u8 {
        // Typedef: follow chain, combining dimensions
        if (tr == .named) {
            if (tr.named == .typedef) {
                const t = tr.named.typedef;
                const all = try std.mem.concat(self.alloc, u64, &.{ t.dimensions, dims });
                defer self.alloc.free(all);
                return self.typeRefToJava(t.type_ref, all);
            }
        }

        const base = try self.typeRefToJavaBase(tr);
        defer self.alloc.free(base);
        if (dims.len == 0) return self.alloc.dupe(u8, base);
        return makeJavaArrayType(self.alloc, base, dims);
    }

    /// Convert a TypeRef (without extra dims) to a Java base type string.
    fn typeRefToJavaBase(self: *Generator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToJavaType(b)),
            .named => |td| switch (td) {
                .typedef => |t| blk: {
                    const all = try std.mem.concat(self.alloc, u64, &.{t.dimensions});
                    defer self.alloc.free(all);
                    break :blk self.typeRefToJava(t.type_ref, all);
                },
                .bitmask => |bm| self.alloc.dupe(u8, bitmaskJavaType(bm.annotations)),
                else => self.qualNameToJava(ir.typeDeclQualifiedName(td)),
            },
            .sequence => |seq| blk: {
                const elem = try self.typeRefToJavaElem(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "java.util.List<{s}>", .{elem});
            },
            .string, .wstring => self.alloc.dupe(u8, "String"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => |m| blk: {
                const key_s = try self.typeRefToJavaElem(m.key.*);
                defer self.alloc.free(key_s);
                const val_s = try self.typeRefToJavaElem(m.value.*);
                defer self.alloc.free(val_s);
                break :blk std.fmt.allocPrint(
                    self.alloc,
                    "java.util.Map<{s},{s}>",
                    .{ key_s, val_s },
                );
            },
        };
    }

    /// Return the Java element type for generic containers (uses boxed types for primitives).
    fn typeRefToJavaElem(self: *Generator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToJavaBoxedType(b)),
            .string, .wstring => self.alloc.dupe(u8, "String"),
            .named => |td| switch (td) {
                .typedef => |t| self.typeRefToJavaElem(t.type_ref),
                else => self.qualNameToJava(ir.typeDeclQualifiedName(td)),
            },
            else => self.typeRefToJavaBase(tr),
        };
    }

    /// Return the Java default value for a member given type + dimensions.
    fn defaultForMember(self: *Generator, tr: ir.TypeRef, dims: []const u64) anyerror![]u8 {
        if (dims.len > 0) {
            return self.makeJavaNewArray(tr, dims);
        }
        return self.defaultForTypeRef(tr);
    }

    /// Return the Java type for a struct member, using boxed types for @optional scalars.
    fn memberJavaType(self: *Generator, m: ir.StructMember) ![]u8 {
        if (m.annotations.is_optional and m.dimensions.len == 0) {
            return self.typeRefToJavaElem(m.type_ref);
        }
        return self.typeRefToJava(m.type_ref, m.dimensions);
    }

    /// Return the Java default expression for a struct member (@optional → null).
    fn memberDefault(self: *Generator, m: ir.StructMember) ![]u8 {
        if (m.annotations.is_optional) return self.alloc.dupe(u8, "null");
        return self.defaultForMember(m.type_ref, m.dimensions);
    }

    fn defaultForTypeRef(self: *Generator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, switch (b) {
                .boolean => "false",
                .float => "0.0f",
                .double, .long_double => "0.0",
                .char, .wchar => "'\\0'",
                .any, .object, .value_base => "null",
                else => "0",
            }),
            .string, .wstring => self.alloc.dupe(u8, "\"\""),
            .sequence => self.alloc.dupe(u8, "new java.util.ArrayList<>()"),
            .named => |td| switch (td) {
                .typedef => |t| blk: {
                    if (t.dimensions.len > 0) break :blk try self.makeJavaNewArray(t.type_ref, t.dimensions);
                    break :blk try self.defaultForTypeRef(t.type_ref);
                },
                .enum_ => |e| if (e.enumerators.len > 0)
                    std.fmt.allocPrint(self.alloc, "{s}{s}.values()[0]", .{ self.opts.type_prefix, e.name })
                else
                    self.alloc.dupe(u8, "null"),
                .bitmask => self.alloc.dupe(u8, "0"),
                .native, .interface => self.alloc.dupe(u8, "null"),
                .bitset => blk: {
                    const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(qname);
                    break :blk std.fmt.allocPrint(self.alloc, "new {s}()", .{qname});
                },
                else => blk: {
                    const qname = try self.qualNameToJava(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(qname);
                    break :blk std.fmt.allocPrint(self.alloc, "new {s}()", .{qname});
                },
            },
            .fixed_pt => self.alloc.dupe(u8, "0.0"),
            .map => self.alloc.dupe(u8, "new java.util.LinkedHashMap<>()"),
        };
    }

    /// Build a `new T[N1][N2]...` allocation expression.
    fn makeJavaNewArray(self: *Generator, tr: ir.TypeRef, dims: []const u64) anyerror![]u8 {
        const base = try self.typeRefToJavaBase(tr);
        defer self.alloc.free(base);
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);
        try buf.appendSlice(self.alloc, "new ");
        try buf.appendSlice(self.alloc, base);
        for (dims) |d| {
            const s = try std.fmt.allocPrint(self.alloc, "[{d}]", .{d});
            defer self.alloc.free(s);
            try buf.appendSlice(self.alloc, s);
        }
        return buf.toOwnedSlice(self.alloc);
    }

    /// Convert `Foo::Bar::Baz` → `Foo.Bar.Baz`.
    fn qualNameToJava(self: *Generator, qname: []const u8) ![]u8 {
        const pfx = self.opts.type_prefix;
        if (pfx.len == 0) {
            // Fast path: no prefix — original behaviour.
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
        // E.g. "Foo::Bar::Baz" with prefix "DDS_" → "Foo.Bar.DDS_Baz"
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
};

// ── Static helpers ────────────────────────────────────────────────────────────

/// Determine the EMHEADER LC value (0–3) for a fixed-size scalar type in Java.
/// Returns null if the type requires LC=4 (NEXTINT) — variable-length or complex.
fn lcForJavaTypeRef(type_ref: ir.TypeRef, dimensions: []const u64) ?u2 {
    if (dimensions.len > 0) return null;
    return switch (type_ref) {
        .base => |b| switch (b) {
            .boolean, .octet, .char, .int8, .uint8 => 0,
            .short, .int16, .unsigned_short, .uint16, .wchar => 1,
            .long, .int32, .unsigned_long, .uint32, .float => 2,
            .long_long, .int64, .unsigned_long_long, .uint64, .double => 3,
            else => null, // long_double, any, etc.
        },
        .named => |td| switch (td) {
            .enum_ => 2, // enums serialize as int32
            else => null,
        },
        else => null, // string, wstring, sequence, etc.
    };
}

/// Return the XTYPES member ID for a struct member.
/// Uses the `@id` annotation if present; otherwise the declaration index.
fn memberIdAtJava(m: ir.StructMember, idx: usize) u32 {
    return if (m.annotations.id) |id| id else @intCast(idx);
}

fn typeDeclHasKeyJava(td: ir.TypeDecl) bool {
    return switch (td) {
        .struct_ => |s| structHasKeyJava(s),
        else => false,
    };
}

fn structHasKeyJava(s: *const ir.Struct) bool {
    if (s.base) |base| {
        if (typeDeclHasKeyJava(base)) return true;
    }
    for (s.members) |m| {
        if (m.annotations.is_key) return true;
    }
    return false;
}

/// Capitalize first character of `stem` to form the outer Java class name.
fn isDefaultUnionCase(cas: ir.UnionCase) bool {
    if (cas.labels.len == 0) return true;
    for (cas.labels) |lbl| {
        if (lbl == .default) return true;
    }
    return false;
}

fn stemToClassName(alloc: std.mem.Allocator, stem: []const u8) ![]u8 {
    if (stem.len == 0) return alloc.dupe(u8, "Generated");
    var out = try alloc.dupe(u8, stem);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

fn baseToJavaType(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "float",
        .double, .long_double => "double",
        .short, .int16, .unsigned_short, .uint16 => "short",
        .long, .int32, .unsigned_long, .uint32 => "int",
        .long_long, .int64, .unsigned_long_long, .uint64 => "long",
        .char => "char",
        .wchar => "char",
        .boolean => "boolean",
        .octet, .int8, .uint8 => "byte",
        .any, .object, .value_base => "Object",
    };
}

/// Boxed type for use in generic parameters (List<E>, Map<K,V>).
fn baseToJavaBoxedType(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "Float",
        .double, .long_double => "Double",
        .short, .int16, .unsigned_short, .uint16 => "Short",
        .long, .int32, .unsigned_long, .uint32 => "Integer",
        .long_long, .int64, .unsigned_long_long, .uint64 => "Long",
        .char, .wchar => "Character",
        .boolean => "Boolean",
        .octet, .int8, .uint8 => "Byte",
        .any, .object, .value_base => "Object",
    };
}

/// CDR alignment for a base type in XCDR2 (max alignment = 4).
fn baseCdrAlign(b: ast.BaseTypeSpec) u8 {
    return switch (b) {
        .boolean, .char, .octet, .int8, .uint8 => 1,
        .short, .int16, .unsigned_short, .uint16, .wchar => 2,
        // XCDR2: long long / double capped at 4
        .long, .int32, .unsigned_long, .uint32, .long_long, .int64, .unsigned_long_long, .uint64, .float, .double, .long_double, .any, .object, .value_base => 4,
    };
}

/// Return the CDR read expression for a base type.
fn baseCdrReadExpr(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "_buf.get() != 0",
        .char => "(char)(_buf.get() & 0xFF)",
        .wchar => "(char)_buf.getShort()",
        .octet, .int8, .uint8 => "_buf.get()",
        .short, .int16, .unsigned_short, .uint16 => "_buf.getShort()",
        .long, .int32, .unsigned_long, .uint32 => "_buf.getInt()",
        .long_long, .int64, .unsigned_long_long, .uint64 => "_buf.getLong()",
        .float => "_buf.getFloat()",
        .double, .long_double => "_buf.getDouble()",
        .any, .object, .value_base => "null",
    };
}

fn bitsetTotalBits(bs: *const ir.Bitset) u32 {
    var total: u32 = 0;
    for (bs.fields) |field| total += field.bits;
    return total;
}

fn bitsetFieldJavaType(width: u8) []const u8 {
    if (width == 1) return "boolean";
    if (width <= 8) return "byte";
    if (width <= 16) return "short";
    if (width <= 32) return "int";
    return "long";
}

/// Return the Java integer type for a bitmask based on @bit_bound.
fn bitmaskJavaType(ann: ir.EnumAnnotations) []const u8 {
    if (ann.bit_bound) |n| {
        if (n > 32) return "long";
    }
    return "int";
}

/// Build a Java array type: `base[][]` for dims = [N1, N2].
fn makeJavaArrayType(alloc: std.mem.Allocator, base: []const u8, dims: []const u64) ![]u8 {
    if (dims.len == 0) return alloc.dupe(u8, base);
    const brackets = dims.len * 2; // "[]" per dimension
    var out = try alloc.alloc(u8, base.len + brackets);
    @memcpy(out[0..base.len], base);
    for (0..dims.len) |i| {
        out[base.len + i * 2] = '[';
        out[base.len + i * 2 + 1] = ']';
    }
    return out;
}

/// Convert an lvalue expression like "_out.items" into a safe identifier
/// for variable names by replacing `.` and `[` etc. with `_`.
fn safeName(alloc: std.mem.Allocator, expr: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, expr);
    for (out) |*ch| {
        if (ch.* == '.' or ch.* == '[' or ch.* == ']') ch.* = '_';
    }
    return out;
}

// ── Interface impl generation ─────────────────────────────────────────────────

/// Collect all `*const ir.Interface` pointers from the spec recursively.
fn collectInterfaces(
    alloc: std.mem.Allocator,
    items: []const ir.ModuleItem,
    out: *std.ArrayListUnmanaged(*const ir.Interface),
) !void {
    for (items) |item| {
        switch (item) {
            .module => |m| try collectInterfaces(alloc, m.items, out),
            .type_decl => |td| {
                if (td == .interface) try out.append(alloc, td.interface);
            },
            .const_ => {},
        }
    }
}

/// Generate a `<IfaceName>Impl.java` file for one IDL interface.
///
/// Exposed for unit testing.  The vtable calls this per interface when
/// `opts.generate_interfaces` is true.
pub fn generateImplFile(
    alloc: std.mem.Allocator,
    iface: *const ir.Interface,
    stem_class: []const u8,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = ImplFileGenerator{
        .alloc = alloc,
        .iface = iface,
        .stem_class = stem_class,
        .opts = opts,
        .out = out,
    };
    try gen.emit();
}

/// Generate the JNI bridge source file `<stem>_jni.c` into `out`.
///
/// Exposed for unit testing.
pub fn generateJniSource(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = JniBridgeGenerator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.emitSource(spec);
}

// ── ImplFileGenerator ─────────────────────────────────────────────────────────

/// Generates `FooImpl.java` for a single IDL `interface Foo`.
///
/// The class implements the Java interface, loads the native library via
/// `System.loadLibrary()`, and forwards each method to a JNI `private native`
/// method.
const ImplFileGenerator = struct {
    alloc: std.mem.Allocator,
    iface: *const ir.Interface,
    stem_class: []const u8,
    opts: interface.Options,
    out: *std.ArrayList(u8),

    fn write(self: *ImplFileGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *ImplFileGenerator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    fn emit(self: *ImplFileGenerator) !void {
        const iface = self.iface;

        // Collect flattened ops + attrs.
        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try self.collectMembers(iface, &ops, &attrs);

        // Build the Java qualified interface name (e.g. `Calc.Foo` or `Calc.M.Foo`).
        const java_iface_path = try self.javaIfacePath(iface);
        defer self.alloc.free(java_iface_path);

        try self.print("// Generated by zidl from {s}.idl — DO NOT EDIT\n\n", .{self.opts.input_stem});

        if (self.opts.java_package.len > 0) {
            try self.print("package {s};\n\n", .{self.opts.java_package});
        }

        const pfx = self.opts.type_prefix;
        try self.print("public class {s}{s}Impl implements {s} {{\n", .{ pfx, iface.name, java_iface_path });
        try self.print("    static {{ System.loadLibrary(\"{s}\"); }}\n\n", .{self.opts.jni_library});
        try self.write("    private final long ptr_;\n\n");
        try self.print("    public {s}{s}Impl(long ptr) {{ this.ptr_ = ptr; }}\n\n", .{ pfx, iface.name });

        // @Override forwarding methods.
        for (ops.items) |op| try self.emitForwardingOp(&op);
        for (attrs.items) |attr| try self.emitForwardingAttr(&attr);

        // private native declarations.
        try self.write("\n");
        for (ops.items) |op| try self.emitNativeDecl(&op);
        for (attrs.items) |attr| try self.emitNativeAttrDecl(&attr);

        try self.write("}\n");
    }

    fn emitForwardingOp(self: *ImplFileGenerator, op: *const ir.Operation) !void {
        const ret_java = if (op.return_type) |rt|
            try self.typeRefToJava(rt)
        else
            try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret_java);

        try self.write("    @Override\n");
        try self.print("    public {s} {s}(", .{ ret_java, op.name });
        for (op.params, 0..) |p, i| {
            const pt = try self.typeRefToJava(p.type_ref);
            defer self.alloc.free(pt);
            if (i > 0) try self.write(", ");
            try self.print("{s} {s}", .{ pt, p.name });
        }
        try self.write(") {\n");

        if (op.return_type != null) {
            try self.print("        return n_{s}(ptr_", .{op.name});
        } else {
            try self.print("        n_{s}(ptr_", .{op.name});
        }
        for (op.params) |p| try self.print(", {s}", .{p.name});
        try self.write(");\n    }\n");
    }

    fn emitForwardingAttr(self: *ImplFileGenerator, attr: *const ir.Attribute) !void {
        const at = try self.typeRefToJava(attr.type_ref);
        defer self.alloc.free(at);

        try self.write("    @Override\n");
        try self.print("    public {s} get_{s}() {{ return n_get_{s}(ptr_); }}\n", .{
            at, attr.name, attr.name,
        });
        if (!attr.readonly) {
            try self.write("    @Override\n");
            try self.print(
                "    public void set_{s}({s} value) {{ n_set_{s}(ptr_, value); }}\n",
                .{ attr.name, at, attr.name },
            );
        }
    }

    fn emitNativeDecl(self: *ImplFileGenerator, op: *const ir.Operation) !void {
        const ret_java = if (op.return_type) |rt|
            try self.typeRefToJava(rt)
        else
            try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret_java);

        try self.print("    private native {s} n_{s}(long ptr", .{ ret_java, op.name });
        for (op.params) |p| {
            const pt = try self.typeRefToJava(p.type_ref);
            defer self.alloc.free(pt);
            try self.print(", {s} {s}", .{ pt, p.name });
        }
        try self.write(");\n");
    }

    fn emitNativeAttrDecl(self: *ImplFileGenerator, attr: *const ir.Attribute) !void {
        const at = try self.typeRefToJava(attr.type_ref);
        defer self.alloc.free(at);
        try self.print("    private native {s} n_get_{s}(long ptr);\n", .{ at, attr.name });
        if (!attr.readonly) {
            try self.print("    private native void n_set_{s}(long ptr, {s} value);\n", .{
                attr.name, at,
            });
        }
    }

    /// Build `<stem_class>.<JavaQualified.Interface>` (e.g. `Calc.Foo` or `Calc.DDS_Foo`).
    fn javaIfacePath(self: *ImplFileGenerator, iface: *const ir.Interface) ![]u8 {
        const java_qname = try qualNameToJavaStatic(self.alloc, iface.qualified_name);
        defer self.alloc.free(java_qname);
        const prefixed = try prefixJavaLastSegment(self.alloc, java_qname, self.opts.type_prefix);
        defer self.alloc.free(prefixed);
        return std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ self.stem_class, prefixed });
    }

    fn typeRefToJava(self: *ImplFileGenerator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToJavaType(b)),
            .named => |td| blk: {
                const raw = try qualNameToJavaStatic(self.alloc, ir.typeDeclQualifiedName(td));
                defer self.alloc.free(raw);
                break :blk prefixJavaLastSegment(self.alloc, raw, self.opts.type_prefix);
            },
            .string, .wstring => self.alloc.dupe(u8, "String"),
            .sequence => |seq| blk: {
                const elem = try self.typeRefToJavaBoxed(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "java.util.List<{s}>", .{elem});
            },
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => self.alloc.dupe(u8, "java.util.Map<Object,Object>"),
        };
    }

    fn typeRefToJavaBoxed(self: *ImplFileGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToJavaBoxedType(b)),
            else => self.typeRefToJava(tr),
        };
    }

    fn collectMembers(
        self: *ImplFileGenerator,
        iface: *const ir.Interface,
        ops: *std.ArrayListUnmanaged(ir.Operation),
        attrs: *std.ArrayListUnmanaged(ir.Attribute),
    ) anyerror!void {
        for (iface.bases) |base| {
            if (base == .interface) try self.collectMembers(base.interface, ops, attrs);
        }
        try ops.appendSlice(self.alloc, iface.operations);
        try attrs.appendSlice(self.alloc, iface.attributes);
    }
};

// ── JniBridgeGenerator ────────────────────────────────────────────────────────

/// Generates `<stem>_jni.c` with JNI bridge functions for all IDL interfaces.
///
/// Each IDL operation `op` in interface `Foo` produces a JNI function that:
///   1. Casts `jlong ptr` to `void*`
///   2. Casts JNI params to C types
///   3. Calls `zidl_Foo_op(void *ptr, ...)`
///   4. Returns the result cast to a JNI type
const JniBridgeGenerator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),

    fn write(self: *JniBridgeGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *JniBridgeGenerator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    fn emitSource(self: *JniBridgeGenerator, spec: *const ir.Spec) !void {
        try self.print(
            "/* Generated by zidl from {s}.idl — DO NOT EDIT */\n\n",
            .{self.opts.input_stem},
        );
        try self.write("#include <jni.h>\n");
        try self.write("#include <stdint.h>\n");
        try self.write("#include <stddef.h>\n\n");
        try self.emitItems(spec.items);
    }

    fn emitItems(self: *JniBridgeGenerator, items: []const ir.ModuleItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.emitItems(m.items),
                .type_decl => |td| {
                    if (td == .interface) try self.emitIfaceBridge(td.interface);
                },
                .const_ => {},
            }
        }
    }

    fn emitIfaceBridge(self: *JniBridgeGenerator, iface: *const ir.Interface) !void {
        const c_name = try interface.prefixedCNameFromQualified(self.alloc, iface.qualified_name, self.opts.type_prefix);
        defer self.alloc.free(c_name);

        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try self.collectMembers(iface, &ops, &attrs);

        try self.print("/* ── interface {s} ── */\n\n", .{c_name});

        // Zig DDS runtime extern declarations.
        try self.write("/* Zig DDS runtime exports (provided at link time). */\n");
        for (ops.items) |op| {
            const ret_c = if (op.return_type) |rt| try self.typeRefToC(rt) else try self.alloc.dupe(u8, "void");
            defer self.alloc.free(ret_c);
            try self.print("extern {s} zidl_{s}_{s}(void *ptr", .{ ret_c, c_name, op.name });
            for (op.params) |p| {
                const pt = try self.paramTypeC(p);
                defer self.alloc.free(pt);
                try self.print(", {s} {s}", .{ pt, p.name });
            }
            try self.write(");\n");
        }
        for (attrs.items) |attr| {
            const at = try self.typeRefToC(attr.type_ref);
            defer self.alloc.free(at);
            try self.print("extern {s} zidl_{s}_get_{s}(void *ptr);\n", .{ at, c_name, attr.name });
            if (!attr.readonly)
                try self.print("extern void zidl_{s}_set_{s}(void *ptr, {s} value);\n", .{ c_name, attr.name, at });
        }
        try self.print("extern void zidl_{s}_deinit(void *ptr);\n\n", .{c_name});

        // Build JNI class path prefix (e.g. "com_example_FooImpl" or "FooImpl").
        const jni_class_prefix = try self.jniClassPrefix(iface.name);
        defer self.alloc.free(jni_class_prefix);

        // JNI bridge for deinit (called from FooImpl finalizer/close, not an IDL op).
        try self.print("/* JNI bridge for {s}{s}Impl */\n", .{ self.opts.type_prefix, iface.name });

        for (ops.items) |op| try self.emitJniBridgeOp(c_name, jni_class_prefix, &op);
        for (attrs.items) |attr| try self.emitJniBridgeAttr(c_name, jni_class_prefix, &attr);

        // deinit bridge.
        const deinit_jni = try self.buildJniFnName(jni_class_prefix, "deinit");
        defer self.alloc.free(deinit_jni);
        try self.print(
            "JNIEXPORT void JNICALL {s}(\n" ++
                "    JNIEnv *env, jobject self, jlong ptr)\n{{\n" ++
                "    (void)env; (void)self;\n" ++
                "    zidl_{s}_deinit((void *)(intptr_t)ptr);\n}}\n\n",
            .{ deinit_jni, c_name },
        );
    }

    fn emitJniBridgeOp(
        self: *JniBridgeGenerator,
        c_name: []const u8,
        jni_class_prefix: []const u8,
        op: *const ir.Operation,
    ) !void {
        const jni_ret = if (op.return_type) |rt| jniType(rt) else "void";
        const native_name = try std.fmt.allocPrint(self.alloc, "n_{s}", .{op.name});
        defer self.alloc.free(native_name);
        const jni_fn = try self.buildJniFnName(jni_class_prefix, native_name);
        defer self.alloc.free(jni_fn);

        try self.print("JNIEXPORT {s} JNICALL {s}(\n    JNIEnv *env, jobject self, jlong ptr", .{
            jni_ret, jni_fn,
        });
        for (op.params) |p| {
            try self.print(", {s} {s}", .{ jniType(p.type_ref), p.name });
        }
        try self.write(")\n{\n    (void)env; (void)self;\n");

        // Body: call Zig export with casts.
        if (op.return_type) |rt| {
            try self.print("    return ({s})zidl_{s}_{s}((void *)(intptr_t)ptr", .{
                jniType(rt), c_name, op.name,
            });
        } else {
            try self.print("    zidl_{s}_{s}((void *)(intptr_t)ptr", .{ c_name, op.name });
        }
        for (op.params) |p| {
            const ct = try self.typeRefToC(p.type_ref);
            defer self.alloc.free(ct);
            try self.print(", ({s}){s}", .{ ct, p.name });
        }
        try self.write(");\n}\n\n");
    }

    fn emitJniBridgeAttr(
        self: *JniBridgeGenerator,
        c_name: []const u8,
        jni_class_prefix: []const u8,
        attr: *const ir.Attribute,
    ) !void {
        const at_c = try self.typeRefToC(attr.type_ref);
        defer self.alloc.free(at_c);
        const at_jni = jniType(attr.type_ref);

        // Getter.
        const get_name = try std.fmt.allocPrint(self.alloc, "n_get_{s}", .{attr.name});
        defer self.alloc.free(get_name);
        const get_jni = try self.buildJniFnName(jni_class_prefix, get_name);
        defer self.alloc.free(get_jni);
        try self.print(
            "JNIEXPORT {s} JNICALL {s}(\n    JNIEnv *env, jobject self, jlong ptr)\n{{\n" ++
                "    (void)env; (void)self;\n" ++
                "    return ({s})zidl_{s}_get_{s}((void *)(intptr_t)ptr);\n}}\n\n",
            .{ at_jni, get_jni, at_jni, c_name, attr.name },
        );

        if (!attr.readonly) {
            const set_name = try std.fmt.allocPrint(self.alloc, "n_set_{s}", .{attr.name});
            defer self.alloc.free(set_name);
            const set_jni = try self.buildJniFnName(jni_class_prefix, set_name);
            defer self.alloc.free(set_jni);
            try self.print(
                "JNIEXPORT void JNICALL {s}(\n    JNIEnv *env, jobject self, jlong ptr, {s} value)\n{{\n" ++
                    "    (void)env; (void)self;\n" ++
                    "    zidl_{s}_set_{s}((void *)(intptr_t)ptr, ({s})value);\n}}\n\n",
                .{ set_jni, at_jni, c_name, attr.name, at_c },
            );
        }
    }

    /// Build a full JNI function name: `<class_prefix>_<mangled_method>`.
    /// Mangling: each `_` in `method` becomes `_1` (JNI spec §2.2.1).
    fn buildJniFnName(self: *JniBridgeGenerator, class_prefix: []const u8, method: []const u8) ![]u8 {
        var mangled = std.ArrayListUnmanaged(u8).empty;
        defer mangled.deinit(self.alloc);
        for (method) |ch| {
            if (ch == '_') {
                try mangled.appendSlice(self.alloc, "_1");
            } else {
                try mangled.append(self.alloc, ch);
            }
        }
        return std.fmt.allocPrint(self.alloc, "{s}_{s}", .{ class_prefix, mangled.items });
    }

    /// Build JNI method name: `Java_<pkg_mangled>_<class>Impl_<method_mangled>`.
    /// (All `_` in method name → `_1`; package `.` → `_`; `_` in type_prefix → `_1`.)
    fn jniClassPrefix(self: *JniBridgeGenerator, iface_name: []const u8) ![]u8 {
        // Mangle type_prefix underscores for JNI: _ → _1
        var mangled_pfx = std.ArrayListUnmanaged(u8).empty;
        defer mangled_pfx.deinit(self.alloc);
        for (self.opts.type_prefix) |ch| {
            if (ch == '_') try mangled_pfx.appendSlice(self.alloc, "_1") else try mangled_pfx.append(self.alloc, ch);
        }
        const mpfx = mangled_pfx.items;
        const pkg = self.opts.java_package;
        if (pkg.len > 0) {
            // Replace '.' with '_' in package.
            const pkg_m = try self.alloc.dupe(u8, pkg);
            defer self.alloc.free(pkg_m);
            for (pkg_m) |*ch| if (ch.* == '.') {
                ch.* = '_';
            };
            return std.fmt.allocPrint(self.alloc, "Java_{s}_{s}{s}Impl", .{ pkg_m, mpfx, iface_name });
        }
        return std.fmt.allocPrint(self.alloc, "Java_{s}{s}Impl", .{ mpfx, iface_name });
    }

    fn collectMembers(
        self: *JniBridgeGenerator,
        iface: *const ir.Interface,
        ops: *std.ArrayListUnmanaged(ir.Operation),
        attrs: *std.ArrayListUnmanaged(ir.Attribute),
    ) anyerror!void {
        for (iface.bases) |base| {
            if (base == .interface) try self.collectMembers(base.interface, ops, attrs);
        }
        try ops.appendSlice(self.alloc, iface.operations);
        try attrs.appendSlice(self.alloc, iface.attributes);
    }

    fn typeRefToC(self: *JniBridgeGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCJava(b)),
            .named => |td| interface.cNameFromQualified(self.alloc, ir.typeDeclQualifiedName(td)),
            .string => self.alloc.dupe(u8, "const char *"),
            .wstring => self.alloc.dupe(u8, "const uint16_t *"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => self.alloc.dupe(u8, "void *"),
            .sequence => |seq| blk: {
                const elem = try self.alloc.dupe(u8, if (seq.element.* == .base)
                    baseToCJava(seq.element.base)
                else
                    "void");
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "{s} *", .{elem});
            },
        };
    }

    fn paramTypeC(self: *JniBridgeGenerator, p: ir.Parameter) ![]u8 {
        const base = try self.typeRefToC(p.type_ref);
        defer self.alloc.free(base);
        return switch (p.mode) {
            .in_ => self.alloc.dupe(u8, base),
            .out, .inout => std.fmt.allocPrint(self.alloc, "{s} *", .{base}),
        };
    }
};

/// IDL TypeRef → JNI C type (jint, jlong, jstring, jobject, …).
fn jniType(tr: ir.TypeRef) []const u8 {
    return switch (tr) {
        .base => |b| switch (b) {
            .boolean => "jboolean",
            .char => "jchar",
            .wchar => "jchar",
            .octet, .uint8 => "jbyte",
            .int8 => "jbyte",
            .short, .int16, .unsigned_short, .uint16 => "jshort",
            .long, .int32, .unsigned_long, .uint32 => "jint",
            .long_long, .int64, .unsigned_long_long, .uint64 => "jlong",
            .float => "jfloat",
            .double, .long_double => "jdouble",
            .any, .object, .value_base => "jobject",
        },
        .string, .wstring => "jstring",
        else => "jobject",
    };
}

/// C type for Java-exported IDL primitive (used in extern declarations for JNI bridge).
fn baseToCJava(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "uint8_t",
        .char => "char",
        .wchar => "uint16_t",
        .octet, .uint8 => "uint8_t",
        .int8 => "int8_t",
        .short, .int16, .unsigned_short, .uint16 => "int16_t",
        .long, .int32, .unsigned_long, .uint32 => "int32_t",
        .long_long, .int64, .unsigned_long_long, .uint64 => "int64_t",
        .float => "float",
        .double, .long_double => "double",
        .any, .object, .value_base => "void *",
    };
}

/// `Foo::Bar::Baz` → `Foo.Bar.Baz` (static version usable outside Generator).
/// Apply `prefix` to the last segment of a Java-dotted qualified name.
/// E.g. ("Foo.Bar.Baz", "DDS_") → "Foo.Bar.DDS_Baz"; ("Foo", "DDS_") → "DDS_Foo".
fn prefixJavaLastSegment(alloc: std.mem.Allocator, java_name: []const u8, prefix: []const u8) ![]u8 {
    if (prefix.len == 0) return alloc.dupe(u8, java_name);
    if (std.mem.lastIndexOf(u8, java_name, ".")) |dot| {
        return std.fmt.allocPrint(alloc, "{s}.{s}{s}", .{ java_name[0..dot], prefix, java_name[dot + 1 ..] });
    }
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, java_name });
}

fn qualNameToJavaStatic(alloc: std.mem.Allocator, qname: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, qname.len);
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
    return alloc.realloc(out, out_i);
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

/// Generate `<StemClass>CdrUtils.java` with public static CDR helper methods.
fn generateCdrUtils(
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.print("// Generated by zidl from {s}.idl — DO NOT EDIT\n", .{opts.input_stem});
    if (opts.java_package.len > 0) {
        try gen.print("package {s};\n", .{opts.java_package});
    }
    try gen.write("\n");
    const class_name = try stemToClassName(alloc, opts.input_stem);
    defer alloc.free(class_name);
    try gen.print("public class {s}CdrUtils {{\n", .{class_name});
    gen.depth = 1;
    // Emit CDR helpers as public static (not private static).
    try gen.write("    public static void _cdrAlign(java.nio.ByteBuffer _buf, int _cdrBase, int _align) {\n");
    try gen.write("        if (_align <= 1) return;\n");
    try gen.write("        int _p = (_buf.position() - _cdrBase) % _align;\n");
    try gen.write("        if (_p != 0) { for (int _i = 0; _i < _align - _p; _i++) _buf.put((byte)0); }\n");
    try gen.write("    }\n");
    try gen.write("    public static void _cdrWriteString(java.nio.ByteBuffer _buf, int _cdrBase, String _s) {\n");
    try gen.write("        _cdrAlign(_buf, _cdrBase, 4);\n");
    try gen.write("        byte[] _b = _s.getBytes(java.nio.charset.StandardCharsets.UTF_8);\n");
    try gen.write("        _buf.putInt(_b.length + 1);\n");
    try gen.write("        _buf.put(_b);\n");
    try gen.write("        _buf.put((byte)0);\n");
    try gen.write("    }\n");
    try gen.write("    public static String _cdrReadString(java.nio.ByteBuffer _buf, int _cdrBase) {\n");
    try gen.write("        _cdrAlign(_buf, _cdrBase, 4);\n");
    try gen.write("        int _len = _buf.getInt() - 1;\n");
    try gen.write("        byte[] _b = new byte[_len];\n");
    try gen.write("        _buf.get(_b);\n");
    try gen.write("        _buf.get(); // null terminator\n");
    try gen.write("        return new String(_b, java.nio.charset.StandardCharsets.UTF_8);\n");
    try gen.write("    }\n");
    try gen.write("    public static byte[] _cdrComputeKeyHash(java.nio.ByteBuffer _buf) {\n");
    try gen.write("        int _len = _buf.position();\n");
    try gen.write("        byte[] _key = new byte[_len];\n");
    try gen.write("        _buf.position(0); _buf.get(_key);\n");
    try gen.write("        if (_len <= 16) {\n");
    try gen.write("            byte[] _out = new byte[16];\n");
    try gen.write("            System.arraycopy(_key, 0, _out, 0, _len);\n");
    try gen.write("            return _out;\n");
    try gen.write("        }\n");
    try gen.write("        try { return java.security.MessageDigest.getInstance(\"MD5\").digest(_key); }\n");
    try gen.write("        catch (java.security.NoSuchAlgorithmException _e) { throw new IllegalStateException(_e); }\n");
    try gen.write("    }\n");
    try gen.write("}\n");
}

/// Collect all TypeDecls from items recursively, flattened.
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

/// Split-file entry point: one `.java` per named type plus `<Stem>CdrUtils.java`.
pub fn generateSplitFiles(
    alloc: std.mem.Allocator,
    io: std.Io,
    spec: *const ir.Spec,
    opts: interface.Options,
) !void {
    const class_name = try stemToClassName(alloc, opts.input_stem);
    defer alloc.free(class_name);

    // Generate CdrUtils file.
    if (!opts.no_typesupport) {
        var utils_content = std.ArrayList(u8).empty;
        defer utils_content.deinit(alloc);
        try generateCdrUtils(alloc, opts, &utils_content);
        const utils_filename = try std.fmt.allocPrint(alloc, "{s}CdrUtils.java", .{class_name});
        defer alloc.free(utils_filename);
        try writeOutputFile(alloc, io, opts, utils_filename, utils_content.items);
    }

    // Collect all type declarations.
    var type_decls = std.ArrayListUnmanaged(ir.TypeDecl).empty;
    defer type_decls.deinit(alloc);
    try collectTypeDeclsFlat(alloc, spec.items, &type_decls);

    // Determine if any type uses CDR (needs import static CdrUtils).
    const needs_cdr = !opts.no_typesupport;

    // Generate one file per type.
    for (type_decls.items) |td| {
        const type_name = ir.typeDeclName(td);
        var content = std.ArrayList(u8).empty;
        defer content.deinit(alloc);

        var gen = Generator{ .alloc = alloc, .opts = opts, .out = &content, .top_level = true };

        // File header.
        try gen.print("// Generated by zidl from {s}.idl — DO NOT EDIT\n", .{opts.input_stem});
        if (opts.java_package.len > 0) {
            try gen.print("package {s};\n", .{opts.java_package});
        }
        try gen.write("\n");
        try gen.write("import java.util.List;\n");
        try gen.write("import java.util.ArrayList;\n");

        // CDR helpers import (for types that use serialization).
        if (needs_cdr) {
            switch (td) {
                .struct_, .exception => {
                    if (opts.java_package.len > 0) {
                        try gen.print("import static {s}.{s}CdrUtils.*;\n", .{ opts.java_package, class_name });
                    } else {
                        try gen.print("import static {s}CdrUtils.*;\n", .{class_name});
                    }
                },
                else => {},
            }
        }
        try gen.write("\n");

        // Type definition (top_level=true strips `static` from class decls).
        try gen.emitTypeDecl(td);

        const filename = try std.fmt.allocPrint(alloc, "{s}.java", .{type_name});
        defer alloc.free(filename);
        try writeOutputFile(alloc, io, opts, filename, content.items);
    }

    // FooImpl.java + <stem>_jni.c (same as single-file mode).
    if (opts.generate_interfaces) {
        var ifaces = std.ArrayListUnmanaged(*const ir.Interface).empty;
        defer ifaces.deinit(alloc);
        try collectInterfaces(alloc, spec.items, &ifaces);

        for (ifaces.items) |iface| {
            var impl_buf = std.ArrayList(u8).empty;
            defer impl_buf.deinit(alloc);
            try generateImplFile(alloc, iface, class_name, opts, &impl_buf);
            const impl_filename = try std.fmt.allocPrint(alloc, "{s}Impl.java", .{iface.name});
            defer alloc.free(impl_filename);
            try writeOutputFile(alloc, io, opts, impl_filename, impl_buf.items);
        }

        var jni_buf = std.ArrayList(u8).empty;
        defer jni_buf.deinit(alloc);
        try generateJniSource(alloc, spec, opts, &jni_buf);
        const jni_filename = try std.fmt.allocPrint(alloc, "{s}_jni.c", .{opts.input_stem});
        defer alloc.free(jni_filename);
        try writeOutputFile(alloc, io, opts, jni_filename, jni_buf.items);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

fn testGen(
    alloc: std.mem.Allocator,
    idl: []const u8,
    stem: []const u8,
    expected_fragment: []const u8,
) !void {
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(idl, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = stem };
    try generateFile(alloc, &ir_spec, opts, &out);
    const content = out.items;
    if (std.mem.indexOf(u8, content, expected_fragment) == null) {
        std.debug.print("\n=== Java output ===\n{s}\n=== expected fragment ===\n{s}\n", .{
            content, expected_fragment,
        });
        return error.FragmentNotFound;
    }
}

fn testGenOpts(
    alloc: std.mem.Allocator,
    idl: []const u8,
    stem: []const u8,
    opts: interface.Options,
    expected_fragment: []const u8,
) !void {
    _ = stem;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(idl, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try generateFile(alloc, &ir_spec, opts, &out);
    const content = out.items;
    if (std.mem.indexOf(u8, content, expected_fragment) == null) {
        std.debug.print("\n=== Java output ===\n{s}\n=== expected fragment ===\n{s}\n", .{
            content, expected_fragment,
        });
        return error.FragmentNotFound;
    }
}

test "java: outer class capitalized from stem" {
    const alloc = testing.allocator;
    try testGen(alloc, "struct P { long x; };", "types", "public class Types {");
}

test "java: package declaration" {
    const alloc = testing.allocator;
    const opts = interface.Options{
        .input_stem = "test",
        .java_package = "com.example.dds",
    };
    try testGenOpts(alloc, "struct P { long x; };", "test", opts, "package com.example.dds;");
}

test "java: struct basic fields" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct Point {
        \\    long x;
        \\    long y;
        \\};
    , "test", "public static class Point implements java.io.Serializable {");
    try testGen(alloc,
        \\struct Point {
        \\    long x;
        \\    long y;
        \\};
    , "test", "private int x;");
    try testGen(alloc,
        \\struct Point {
        \\    long x;
        \\    long y;
        \\};
    , "test", "public int get_x() { return x; }");
    try testGen(alloc,
        \\struct Point {
        \\    long x;
        \\    long y;
        \\};
    , "test", "public void set_x(int x) { this.x = x; }");
}

test "java: struct default constructor" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct S {
        \\    long val;
        \\    string name;
        \\    boolean flag;
        \\};
    , "test", "this.val = 0;");
    try testGen(alloc,
        \\struct S {
        \\    long val;
        \\    string name;
        \\    boolean flag;
        \\};
    , "test", "this.name = \"\";");
    try testGen(alloc,
        \\struct S {
        \\    long val;
        \\    string name;
        \\    boolean flag;
        \\};
    , "test", "this.flag = false;");
}

test "java: struct all-values constructor" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct Point { long x; long y; };
    , "test", "public Point(int x, int y) {");
}

test "java: enum" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\enum Color { RED, GREEN, BLUE };
    , "test", "public enum Color {");
    try testGen(alloc,
        \\enum Color { RED, GREEN, BLUE };
    , "test", "RED(0),");
    try testGen(alloc,
        \\enum Color { RED, GREEN, BLUE };
    , "test", "BLUE(2);");
    try testGen(alloc,
        \\enum Color { RED, GREEN, BLUE };
    , "test", "public static Color valueOf(int v) {");
    try testGen(alloc,
        \\enum Color { RED, GREEN, BLUE };
    , "test", "public int getValue() { return value; }");
}

test "java: module → nested static class" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\module Nav {
        \\    struct Pose { double x; double y; };
        \\};
    , "test", "public static class Nav {");
    try testGen(alloc,
        \\module Nav {
        \\    struct Pose { double x; double y; };
        \\};
    , "test", "public static class Pose implements java.io.Serializable {");
}

test "java: const" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\const long MAX_SIZE = 256;
    , "test", "public static final class MAX_SIZE {");
    try testGen(alloc,
        \\const long MAX_SIZE = 256;
    , "test", "public static final int value = 256;");
    try testGen(alloc,
        \\const string VERSION = "1.0";
    , "test", "public static final String value = \"1.0\";");
}

test "java: string field" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct Msg { string text; string<128> bounded; };
    , "test", "private String text;");
    // bounded string also maps to String
    try testGen(alloc,
        \\struct Msg { string text; string<128> bounded; };
    , "test", "private String bounded;");
}

test "java: sequence field" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct S { sequence<long> items; };
    , "test", "private java.util.List<Integer> items;");
    try testGen(alloc,
        \\struct S { sequence<long> items; };
    , "test", "this.items = new java.util.ArrayList<>();");
}

test "java: array field" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct S { long arr[10]; };
    , "test", "private int[] arr;");
    try testGen(alloc,
        \\struct S { long arr[10]; };
    , "test", "this.arr = new int[10];");
}

test "java: multi-dim array" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct S { short mat[3][4]; };
    , "test", "private short[][] mat;");
    try testGen(alloc,
        \\struct S { short mat[3][4]; };
    , "test", "this.mat = new short[3][4];");
}

test "java: typedef transparent" {
    const alloc = testing.allocator;
    // typedef struct member should resolve to int, not typedef name
    try testGen(alloc,
        \\typedef long MyLong;
        \\struct S { MyLong x; };
    , "test", "private int x;");
    // typedef itself emits a comment
    try testGen(alloc,
        \\typedef long MyLong;
    , "test", "// IDL typedef MyLong");
}

test "java: bitset basic" {
    const alloc = testing.allocator;
    // 3+1 = 4 bits total → int backing, byte wire
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "public static final class BS implements java.io.Serializable {");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "private int _value = 0;");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "public byte get_a()");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "public void set_a(byte val)");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "public boolean get_b()");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "public void set_b(boolean val)");
}

test "java: bitset cdr byte" {
    const alloc = testing.allocator;
    // 4 total bits → serialize as byte
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "public void serialize(java.nio.ByteBuffer _buf, int _cdrBase)");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "_buf.put((byte)(_value & 0xFF));");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "public static BS deserializeFrom(java.nio.ByteBuffer _buf, int _cdrBase)");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "test", "_out._value = (_buf.get() & 0xFF);");
}

test "java: bitset cdr int" {
    const alloc = testing.allocator;
    // 16+16 = 32 bits → serialize as int
    try testGen(alloc,
        \\bitset Cfg { bitfield<16> lo; bitfield<16> hi; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(_value);");
    try testGen(alloc,
        \\bitset Cfg { bitfield<16> lo; bitfield<16> hi; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _out._value = _buf.getInt();");
}

test "java: bitset member in struct" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
        \\struct S { BS bs; };
    , "test", "this.bs = new BS();");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
        \\struct S { BS bs; };
    , "test", "this.bs.serialize(_buf, _cdrBase);");
    try testGen(alloc,
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
        \\struct S { BS bs; };
    , "test", "_out.bs = BS.deserializeFrom(_buf, _cdrBase);");
}

test "java: bitset padding field" {
    const alloc = testing.allocator;
    // 4 bits padding between a and c — no getter/setter for padding
    try testGen(alloc,
        \\bitset BS { bitfield<4> a; bitfield<4>; bitfield<4> c; };
    , "test", "public byte get_a()");
    try testGen(alloc,
        \\bitset BS { bitfield<4> a; bitfield<4>; bitfield<4> c; };
    , "test", "public byte get_c() { return (byte)((_value >>> 8) & 0xF); }");
}

test "java: map field declaration" {
    const alloc = testing.allocator;
    // Field type is the interface; initialization happens in the constructor.
    try testGen(alloc,
        \\struct S { map<long, string> m; };
    , "test", "private java.util.Map<Integer,String> m;");
    try testGen(alloc,
        \\struct S { map<long, string> m; };
    , "test", "this.m = new java.util.LinkedHashMap<>();");
}

test "java: map cdr serialize" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct S { map<long, string> m; };
    , "test", "_buf.putInt(this.m.size());");
    try testGen(alloc,
        \\struct S { map<long, string> m; };
    , "test", "for (java.util.Map.Entry<Integer,String> _me : this.m.entrySet())");
    try testGen(alloc,
        \\struct S { map<long, string> m; };
    , "test", "_buf.putInt(_me.getKey());");
}

test "java: map cdr deserialize" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct S { map<long, string> m; };
    , "test", "_out.m = new java.util.LinkedHashMap<>");
    try testGen(alloc,
        \\struct S { map<long, string> m; };
    , "test", "Integer _mk_");
    try testGen(alloc,
        \\struct S { map<long, string> m; };
    , "test", "_out.m.put(");
}

test "java: bitmask" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\bitmask Flags { FLAG_A, FLAG_B, FLAG_C };
    , "test", "public static final class Flags {");
    try testGen(alloc,
        \\bitmask Flags { FLAG_A, FLAG_B, FLAG_C };
    , "test", "public static final int FLAG_A = (int)(1 << 0);");
    try testGen(alloc,
        \\bitmask Flags { FLAG_A, FLAG_B, FLAG_C };
    , "test", "public static final int FLAG_C = (int)(1 << 2);");
}

test "java: interface" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\interface IFoo {
        \\    long add(in long a, in long b);
        \\    attribute long value;
        \\};
    , "test", "public interface IFoo {");
    try testGen(alloc,
        \\interface IFoo {
        \\    long add(in long a, in long b);
        \\    attribute long value;
        \\};
    , "test", "int add(int a, int b);");
    try testGen(alloc,
        \\interface IFoo {
        \\    long add(in long a, in long b);
        \\    attribute long value;
        \\};
    , "test", "int get_value();");
    try testGen(alloc,
        \\interface IFoo {
        \\    long add(in long a, in long b);
        \\    attribute long value;
        \\};
    , "test", "void set_value(int value);");
}

test "java: exception" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\exception MyError { long code; string message; };
    , "test", "public static class MyError extends RuntimeException {");
    try testGen(alloc,
        \\exception MyError { long code; string message; };
    , "test", "public int get_code()");
    try testGen(alloc,
        \\exception MyError { long code; string message; };
    , "test", "public void set_message(String message)");
}

test "java: struct inheritance" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct Base { long id; };
        \\struct Derived : Base { long value; };
    , "test", "public static class Derived extends Base implements java.io.Serializable {");
}

test "java: CDR helpers emitted" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct S { long x; };
    , "test", "private static void _cdrAlign(java.nio.ByteBuffer _buf, int _cdrBase, int _align) {");
    try testGen(alloc,
        \\struct S { long x; };
    , "test", "private static void _cdrWriteString(java.nio.ByteBuffer _buf, int _cdrBase, String _s) {");
    try testGen(alloc,
        \\struct S { long x; };
    , "test", "private static String _cdrReadString(java.nio.ByteBuffer _buf, int _cdrBase) {");
}

test "java: CDR primitive serialize" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct Point { long x; long y; };
    , "test", "public void serialize(java.nio.ByteBuffer _buf, int _cdrBase) {");
    try testGen(alloc,
        \\struct Point { long x; long y; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(this.x)");
    try testGen(alloc,
        \\struct Point { long x; long y; };
    , "test", "public static Point deserializeFrom(java.nio.ByteBuffer _buf, int _cdrBase) {");
    try testGen(alloc,
        \\struct Point { long x; long y; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _out.x = _buf.getInt();");
}

test "java: CDR string serialize" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct Msg { string text; };
    , "test", "_cdrWriteString(_buf, _cdrBase, this.text);");
    try testGen(alloc,
        \\struct Msg { string text; };
    , "test", "_out.text = _cdrReadString(_buf, _cdrBase);");
}

test "java: CDR sequence serialize" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct S { sequence<long> items; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(this.items.size());");
    try testGen(alloc,
        \\struct S { sequence<long> items; };
    , "test", "for (Integer _e : this.items) {");
    try testGen(alloc,
        \\struct S { sequence<long> items; };
    , "test", "_out.items = new java.util.ArrayList<>(");
}

test "java: CDR appendable DHEADER" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\@appendable struct S { long x; };
    , "test", "int _dhPos = _buf.position(); _buf.putInt(0);");
    try testGen(alloc,
        \\@appendable struct S { long x; };
    , "test", "_buf.putInt(_dhPos, _buf.position() - _dhPos - 4);");
    try testGen(alloc,
        \\@appendable struct S { long x; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _buf.getInt(); // skip DHEADER");
}

test "java: CDR @key serializeKey" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct Topic {
        \\    @key long id;
        \\    string name;
        \\};
    , "test", "public static final boolean HAS_KEY = true;");
    try testGen(alloc,
        \\struct Topic {
        \\    @key long id;
        \\    string name;
        \\};
    , "test", "public void serializeKey(java.nio.ByteBuffer _buf, int _cdrBase) {");
    // serializeKey should serialize the @key field
    try testGen(alloc,
        \\struct Topic {
        \\    @key long id;
        \\    string name;
        \\};
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(this.id)");
}

test "java: CDR enum field" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\enum Color { RED, GREEN, BLUE };
        \\struct S { Color c; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(this.c.getValue());");
    try testGen(alloc,
        \\enum Color { RED, GREEN, BLUE };
        \\struct S { Color c; };
    , "test", "_out.c = Color.valueOf(_buf.getInt());");
}

test "java: CDR no typesupport" {
    const alloc = testing.allocator;
    const opts = interface.Options{
        .input_stem = "test",
        .no_typesupport = true,
    };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init("struct S { long x; };", ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope);
    defer ir_spec.deinit();
    try generateFile(alloc, &ir_spec, opts, &out);
    const content = out.items;
    // No CDR helpers
    try testing.expect(std.mem.indexOf(u8, content, "_cdrAlign") == null);
    // No serialize method
    try testing.expect(std.mem.indexOf(u8, content, "serialize") == null);
}

test "java: has_key false when no @key" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\struct NoKey { long x; long y; };
    , "test", "public static final boolean HAS_KEY = false;");
}

test "java: @optional scalar field uses boxed type" {
    const alloc = testing.allocator;
    // @optional long → Integer (boxed, nullable)
    try testGen(alloc,
        \\struct Opt { @optional long maybe_x; long y; };
    , "test", "private Integer maybe_x;");
    // Non-optional field stays primitive
    try testGen(alloc,
        \\struct Opt { @optional long maybe_x; long y; };
    , "test", "private int y;");
    // Default constructor sets optional to null
    try testGen(alloc,
        \\struct Opt { @optional long maybe_x; long y; };
    , "test", "this.maybe_x = null;");
}

test "java: @optional CDR serialize writes presence flag then value" {
    const alloc = testing.allocator;
    // Presence flag written before value
    try testGen(alloc,
        \\struct Opt { @optional long maybe_x; long y; };
    , "test", "_buf.put(this.maybe_x != null ? (byte)1 : (byte)0);");
    // Value written inside null-check
    try testGen(alloc,
        \\struct Opt { @optional long maybe_x; long y; };
    , "test", "if (this.maybe_x != null) {");
    // Non-optional field serialized normally
    try testGen(alloc,
        \\struct Opt { @optional long maybe_x; long y; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _buf.putInt(this.y);");
}

test "java: @optional CDR deserialize reads presence flag and sets null" {
    const alloc = testing.allocator;
    // Presence flag read
    try testGen(alloc,
        \\struct Opt { @optional long maybe_x; long y; };
    , "test", "boolean _ip_maybe_x = _buf.get() != 0;");
    // Value read on present
    try testGen(alloc,
        \\struct Opt { @optional long maybe_x; long y; };
    , "test", "_out.maybe_x = _buf.getInt();");
    // Null assigned on absent
    try testGen(alloc,
        \\struct Opt { @optional long maybe_x; long y; };
    , "test", "_out.maybe_x = null;");
}

// ── --generate-interfaces tests ───────────────────────────────────────────────

fn buildIrSpec(alloc: std.mem.Allocator, idl: []const u8) !ir.Spec {
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(idl, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    return ir.build(alloc, &spec, az.global_scope);
}

test "java: union basic fields" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var", "private int _discriminator");
}

test "java: union CDR serialize emitted" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var", "public void serialize(java.nio.ByteBuffer _buf, int _cdrBase)");
}

test "java: union CDR deserializeFrom emitted" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var", "public static Var deserializeFrom(java.nio.ByteBuffer _buf, int _cdrBase)");
}

test "java: union CDR switch on discriminant" {
    const alloc = testing.allocator;
    try testGen(alloc,
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var", "switch (_discriminator) {");
}

test "java: FooImpl file basic structure" {
    const alloc = testing.allocator;
    var ir_spec = try buildIrSpec(alloc,
        \\interface Calc { long add(in long a, in long b); void reset(); };
    );
    defer ir_spec.deinit();

    var ifaces = std.ArrayListUnmanaged(*const ir.Interface).empty;
    defer ifaces.deinit(alloc);
    try collectInterfaces(alloc, ir_spec.items, &ifaces);
    try testing.expectEqual(@as(usize, 1), ifaces.items.len);

    const stem_class = try stemToClassName(alloc, "calc");
    defer alloc.free(stem_class);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = "calc", .jni_library = "zidl_dds_jni" };
    try generateImplFile(alloc, ifaces.items[0], stem_class, opts, &out);
    const s = out.items;

    try testing.expect(std.mem.indexOf(u8, s, "public class CalcImpl implements Calc.Calc {") != null);
    try testing.expect(std.mem.indexOf(u8, s, "System.loadLibrary(\"zidl_dds_jni\")") != null);
    try testing.expect(std.mem.indexOf(u8, s, "private final long ptr_;") != null);
    try testing.expect(std.mem.indexOf(u8, s, "public CalcImpl(long ptr)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "public int add(int a, int b)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "return n_add(ptr_") != null);
    try testing.expect(std.mem.indexOf(u8, s, "public void reset()") != null);
    try testing.expect(std.mem.indexOf(u8, s, "n_reset(ptr_)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "private native int n_add(long ptr, int a, int b);") != null);
    try testing.expect(std.mem.indexOf(u8, s, "private native void n_reset(long ptr);") != null);
}

test "java: FooImpl file with package" {
    const alloc = testing.allocator;
    var ir_spec = try buildIrSpec(alloc,
        \\interface Greeter { string greet(in string name); };
    );
    defer ir_spec.deinit();

    var ifaces = std.ArrayListUnmanaged(*const ir.Interface).empty;
    defer ifaces.deinit(alloc);
    try collectInterfaces(alloc, ir_spec.items, &ifaces);

    const stem_class = try stemToClassName(alloc, "greet");
    defer alloc.free(stem_class);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{
        .input_stem = "greet",
        .java_package = "com.example",
        .jni_library = "mylib",
    };
    try generateImplFile(alloc, ifaces.items[0], stem_class, opts, &out);
    const s = out.items;

    try testing.expect(std.mem.indexOf(u8, s, "package com.example;") != null);
    try testing.expect(std.mem.indexOf(u8, s, "System.loadLibrary(\"mylib\")") != null);
}

test "java: JNI bridge source" {
    const alloc = testing.allocator;
    var ir_spec = try buildIrSpec(alloc,
        \\interface Calc { long add(in long a, in long b); void reset(); };
    );
    defer ir_spec.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = "calc" };
    try generateJniSource(alloc, &ir_spec, opts, &out);
    const s = out.items;

    try testing.expect(std.mem.indexOf(u8, s, "#include <jni.h>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "extern int32_t zidl_Calc_add(void *ptr") != null);
    try testing.expect(std.mem.indexOf(u8, s, "extern void zidl_Calc_deinit(void *ptr)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Java_CalcImpl_n_1add") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Java_CalcImpl_n_1reset") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Java_CalcImpl_deinit") != null);
    try testing.expect(std.mem.indexOf(u8, s, "return (jint)zidl_Calc_add") != null);
}

test "java: JNI bridge source with package" {
    const alloc = testing.allocator;
    var ir_spec = try buildIrSpec(alloc,
        \\interface Foo { void bar(); };
    );
    defer ir_spec.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = "foo", .java_package = "com.example" };
    try generateJniSource(alloc, &ir_spec, opts, &out);
    const s = out.items;

    try testing.expect(std.mem.indexOf(u8, s, "Java_com_example_FooImpl_n_1bar") != null);
}

test "java type_prefix: class name uses prefix" {
    const alloc = testing.allocator;
    try testGenOpts(alloc, "struct Foo { long x; };", "t", .{ .input_stem = "t", .type_prefix = "DDS_" }, "public static class DDS_Foo");
}

test "java type_prefix: enum class name uses prefix" {
    const alloc = testing.allocator;
    try testGenOpts(alloc, "enum Color { RED, GREEN };", "t", .{ .input_stem = "t", .type_prefix = "DDS_" }, "public enum DDS_Color {");
}

test "java type_prefix: field type reference uses prefix" {
    const alloc = testing.allocator;
    try testGenOpts(alloc,
        \\struct Point { long x; long y; };
        \\struct Line { Point start; Point end; };
    , "t", .{ .input_stem = "t", .type_prefix = "DDS_" }, "private DDS_Point start;");
}

test "java type_prefix: module-qualified name has prefix on last segment" {
    const alloc = testing.allocator;
    try testGenOpts(alloc, "module M { struct S { long x; }; };", "t", .{ .input_stem = "t", .type_prefix = "DDS_" }, "public static class DDS_S");
}

// ── @mutable EMHEADER tests ───────────────────────────────────────────────────

test "java: @mutable struct serialize emits DHEADER + EMHEADER per member" {
    const alloc = testing.allocator;
    // DHEADER opening
    try testGen(alloc,
        \\@mutable struct S { long x; string name; };
    , "test", "int _dhPos = _buf.position(); _buf.putInt(0);");
    // LC=2 EMHEADER for `long x` (member_id=0, LC=2 → 0x20000000)
    try testGen(alloc,
        \\@mutable struct S { long x; string name; };
    , "test", "_buf.putInt(0x20000000);");
    // Variable-length EMHEADER for `string name` (member_id=1, LC=4 → 0x40000001) + NEXTINT
    try testGen(alloc,
        \\@mutable struct S { long x; string name; };
    , "test", "_buf.putInt(0x40000001); int _niPos_name = _buf.position(); _buf.putInt(0);");
    // NEXTINT patch for name
    try testGen(alloc,
        \\@mutable struct S { long x; string name; };
    , "test", "_buf.putInt(_niPos_name, _buf.position() - _niPos_name - 4);");
    // DHEADER patch at end
    try testGen(alloc,
        \\@mutable struct S { long x; string name; };
    , "test", "_buf.putInt(_dhPos, _buf.position() - _dhPos - 4);");
}

test "java: @mutable struct deserialize loops over EMHEADERs" {
    const alloc = testing.allocator;
    // Read DHEADER → end position
    try testGen(alloc,
        \\@mutable struct S { long x; long y; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); int _emEnd = _buf.position() + _buf.getInt();");
    // EMHEADER loop
    try testGen(alloc,
        \\@mutable struct S { long x; long y; };
    , "test", "while (_buf.position() < _emEnd) {");
    // LC decode + payload size
    try testGen(alloc,
        \\@mutable struct S { long x; long y; };
    , "test", "int _emLc = (_emWord >>> 28) & 0x7;");
    // Switch on member_id
    try testGen(alloc,
        \\@mutable struct S { long x; long y; };
    , "test", "switch (_memberId) {");
    // Member case arms
    try testGen(alloc,
        \\@mutable struct S { long x; long y; };
    , "test", "case 0:");
    try testGen(alloc,
        \\@mutable struct S { long x; long y; };
    , "test", "case 1:");
    // Unknown member skip
    try testGen(alloc,
        \\@mutable struct S { long x; long y; };
    , "test", "default: _buf.position(_buf.position() + _emPayload); break;");
}

test "java: @mutable struct @id annotation overrides member_id" {
    const alloc = testing.allocator;
    // @id(5) on x: EMHEADER should use member_id=5 (LC=2 → 0x20000005)
    try testGen(alloc,
        \\@mutable struct S { @id(5) long x; };
    , "test", "_buf.putInt(0x20000005);");
    // deserialize case arm for member_id=5
    try testGen(alloc,
        \\@mutable struct S { @id(5) long x; };
    , "test", "case 5:");
}

test "java: @mutable union serialize emits DHEADER + disc EMHEADER + case EMHEADER" {
    const alloc = testing.allocator;
    // DHEADER
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: string s; };
    , "test", "int _dhPos = _buf.position(); _buf.putInt(0);");
    // Discriminant EMHEADER (member_id=0, LC=2 → 0x20000000)
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: string s; };
    , "test", "_buf.putInt(0x20000000); // disc EMHEADER");
    // Case `long x` EMHEADER (case_idx=0, member_id=1, LC=2 → 0x20000001)
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: string s; };
    , "test", "_buf.putInt(0x20000001); // EMHEADER case 1");
    // Case `string s` EMHEADER (case_idx=1, member_id=2, LC=4 → 0x40000002) + NEXTINT
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: string s; };
    , "test", "_buf.putInt(0x40000002); int _niPos_c1 = _buf.position(); _buf.putInt(0);");
    // DHEADER patch
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: string s; };
    , "test", "_buf.putInt(_dhPos, _buf.position() - _dhPos - 4);");
}

test "java: @mutable union deserialize reads DHEADER then loops EMHEADERs" {
    const alloc = testing.allocator;
    // DHEADER read
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: long y; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); int _emEnd = _buf.position() + _buf.getInt();");
    // Discriminant arm: member_id == 0
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: long y; };
    , "test", "if (_memberId == 0) {");
    // Discriminant read inside if arm
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: long y; };
    , "test", "_cdrAlign(_buf, _cdrBase, 4); _out._discriminator = _buf.getInt();");
    // Case switch inside else arm
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: long y; };
    , "test", "} else {");
    try testGen(alloc,
        \\@mutable union U switch (long) { case 0: long x; case 1: long y; };
    , "test", "switch (_out._discriminator) {");
}

test "java: fixed<5,2> field type is double and serializes as BCD" {
    const alloc = testing.allocator;
    try testGen(alloc, "struct S { fixed<5,2> price; };", "fp", "double price");
    try testGen(alloc, "struct S { fixed<5,2> price; };", "fp", "_cdrWriteFixed(_buf, 5, 2, this.price)");
    try testGen(alloc, "struct S { fixed<5,2> price; };", "fp", "_out.price = _cdrReadFixed(_buf, 5, 2)");
}

test "java: CDR helpers include _cdrWriteFixed and _cdrReadFixed" {
    const alloc = testing.allocator;
    try testGen(alloc, "struct S { long x; };", "s", "private static void _cdrWriteFixed");
    try testGen(alloc, "struct S { long x; };", "s", "private static double _cdrReadFixed");
}
