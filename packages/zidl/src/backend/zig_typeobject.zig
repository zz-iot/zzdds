//! TypeObject/TypeIdentifier encoder for the Zig backend — Phase 5.
//!
//! Computes MinimalTypeObject CDR bytes at *code-gen time* (not at runtime in
//! the generated code).  The Zig backend calls these functions and emits the
//! resulting bytes as literal byte-array constants in the generated source.
//!
//! ## Generated constants (inside each struct body):
//!
//!   pub const type_object: []const u8 = &[_]u8{0x00, 0x07, …};
//!       Full XCDR2 LE MinimalTypeObject bytes including encap header.
//!
//!   pub const equivalence_hash: [14]u8 = [14]u8{…};
//!       First 14 bytes of MD5(type_object) — the on-wire EquivalenceHash per
//!       DDS-XTypes §7.3.4.5.  Other DDS implementations use this value to
//!       identify the type.
//!
//!   pub const type_identifier: [32]u8 = [32]u8{…};
//!       SHA-256(type_object) — zidl project convention, not transmitted on the
//!       wire.  Provides a strong, stable fingerprint for out-of-band tooling.
//!
//! ## References
//!   docs/xtypes_typeobject.md — TypeObject IDL and encoding rules
//!   docs/xcdr_encoding.md    — XCDR2 encoding rules

const std = @import("std");
const ir = @import("../ir/root.zig");
const ast = @import("../ast.zig");
const xtypes = @import("zidl_xtypes");

// ── XTypes constants ──────────────────────────────────────────────────────────
// Canonical values live in packages/zidl-xtypes/src/root.zig.
// Local aliases keep call sites unchanged.

const EK_MINIMAL = xtypes.EK_MINIMAL;
const EK_COMPLETE = xtypes.EK_COMPLETE;
const EK_BOTH = xtypes.EK_BOTH;

const TK_NONE = xtypes.TK_NONE;
const TK_BOOLEAN = xtypes.TK_BOOLEAN;
const TK_BYTE = xtypes.TK_BYTE;
const TK_INT8 = xtypes.TK_INT8;
const TK_INT16 = xtypes.TK_INT16;
const TK_INT32 = xtypes.TK_INT32;
const TK_INT64 = xtypes.TK_INT64;
const TK_UINT8 = xtypes.TK_UINT8;
const TK_UINT16 = xtypes.TK_UINT16;
const TK_UINT32 = xtypes.TK_UINT32;
const TK_UINT64 = xtypes.TK_UINT64;
const TK_FLOAT32 = xtypes.TK_FLOAT32;
const TK_FLOAT64 = xtypes.TK_FLOAT64;
const TK_FLOAT128 = xtypes.TK_FLOAT128;
const TK_CHAR8 = xtypes.TK_CHAR8;
const TK_CHAR16 = xtypes.TK_CHAR16;
const TK_STRING8 = xtypes.TK_STRING8;
const TK_STRING16 = xtypes.TK_STRING16;
const TK_ALIAS = xtypes.TK_ALIAS;
const TK_ENUM = xtypes.TK_ENUM;
const TK_BITMASK = xtypes.TK_BITMASK;
const TK_ANNOTATION = xtypes.TK_ANNOTATION;
const TK_STRUCTURE = xtypes.TK_STRUCTURE;
const TK_UNION = xtypes.TK_UNION;
const TK_BITSET = xtypes.TK_BITSET;
const TK_SEQUENCE = xtypes.TK_SEQUENCE;
const TK_ARRAY = xtypes.TK_ARRAY;
const TK_MAP = xtypes.TK_MAP;

const TI_STRING8_SMALL = xtypes.TI_STRING8_SMALL;
const TI_STRING8_LARGE = xtypes.TI_STRING8_LARGE;
const TI_STRING16_SMALL = xtypes.TI_STRING16_SMALL;
const TI_STRING16_LARGE = xtypes.TI_STRING16_LARGE;
const TI_PLAIN_SEQUENCE_SMALL = xtypes.TI_PLAIN_SEQUENCE_SMALL;
const TI_PLAIN_SEQUENCE_LARGE = xtypes.TI_PLAIN_SEQUENCE_LARGE;
const TI_PLAIN_ARRAY_SMALL = xtypes.TI_PLAIN_ARRAY_SMALL;
const TI_PLAIN_ARRAY_LARGE = xtypes.TI_PLAIN_ARRAY_LARGE;

const IS_FINAL = xtypes.IS_FINAL;
const IS_APPENDABLE = xtypes.IS_APPENDABLE;
const IS_MUTABLE = xtypes.IS_MUTABLE;
const IS_NESTED = xtypes.IS_NESTED;

const TRY_CONSTRUCT_DISCARD = xtypes.TRY_CONSTRUCT_DISCARD;
const IS_OPTIONAL = xtypes.IS_OPTIONAL;
const IS_MUST_UNDERSTAND = xtypes.IS_MUST_UNDERSTAND;
const IS_KEY = xtypes.IS_KEY;
const IS_DEFAULT = xtypes.IS_DEFAULT;

// ── EquivalenceHash type alias ────────────────────────────────────────────────

pub const EquivalenceHash = [14]u8;

// ── XCDR2 LE Encoder ─────────────────────────────────────────────────────────
//
// Alignment rules (XCDR2):
//   - Max alignment = 4 bytes (unlike XCDR1 which goes up to 8).
//   - All alignment is measured from the start of the CDR *payload*, i.e. from
//     pos=0 immediately after the 4-byte encapsulation header.
//   - writeEncapHeader() writes the 4-byte header and resets pos to 0.
//
// DHEADER convention:
//   - @appendable types get a DHEADER (u32 = payload byte-count after the DHEADER).
//   - reserveDheader() returns the absolute byte offset in `buf` (not pos).
//   - patchDheader(off) fills in buf[off..off+4] = buf.len - off - 4.

const Encoder = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Current CDR payload position (for alignment).  Reset to 0 after
    /// writeEncapHeader(); does not count the 4-byte encap header itself.
    pos: usize = 0,

    fn deinit(self: *Encoder, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    /// Prepend the XCDR2 LE encapsulation header and reset pos to 0.
    /// Representation ID 0x0007 = CDR2_LE, written as big-endian pair per RTPS.
    fn writeEncapHeader(self: *Encoder, alloc: std.mem.Allocator) !void {
        try self.buf.appendSlice(alloc, &[_]u8{ 0x00, 0x07, 0x00, 0x00 });
        self.pos = 0;
    }

    fn writePad(self: *Encoder, alloc: std.mem.Allocator, boundary: usize) !void {
        const rem = self.pos % boundary;
        if (rem == 0) return;
        const n = boundary - rem;
        try self.buf.appendNTimes(alloc, 0, n);
        self.pos += n;
    }

    fn writeU8(self: *Encoder, alloc: std.mem.Allocator, v: u8) !void {
        try self.buf.append(alloc, v);
        self.pos += 1;
    }

    fn writeU16Le(self: *Encoder, alloc: std.mem.Allocator, v: u16) !void {
        try self.writePad(alloc, 2);
        try self.buf.append(alloc, @truncate(v));
        try self.buf.append(alloc, @truncate(v >> 8));
        self.pos += 2;
    }

    fn writeU32Le(self: *Encoder, alloc: std.mem.Allocator, v: u32) !void {
        try self.writePad(alloc, 4);
        try self.buf.append(alloc, @truncate(v));
        try self.buf.append(alloc, @truncate(v >> 8));
        try self.buf.append(alloc, @truncate(v >> 16));
        try self.buf.append(alloc, @truncate(v >> 24));
        self.pos += 4;
    }

    fn writeI32Le(self: *Encoder, alloc: std.mem.Allocator, v: i32) !void {
        try self.writeU32Le(alloc, @bitCast(v));
    }

    fn writeBytes(self: *Encoder, alloc: std.mem.Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(alloc, bytes);
        self.pos += bytes.len;
    }

    /// CDR string: u32 byte-length (including NUL), chars, NUL terminator.
    fn writeCdrString(self: *Encoder, alloc: std.mem.Allocator, s: []const u8) !void {
        try self.writeU32Le(alloc, @intCast(s.len + 1));
        try self.writeBytes(alloc, s);
        try self.writeU8(alloc, 0);
    }

    /// Write a DHEADER placeholder (u32 = 0) and return its absolute offset in buf.
    fn reserveDheader(self: *Encoder, alloc: std.mem.Allocator) !usize {
        try self.writePad(alloc, 4);
        const off = self.buf.items.len;
        try self.writeU32Le(alloc, 0); // filled by patchDheader
        return off;
    }

    /// Patch the DHEADER at buf[off..off+4] with `buf.len - off - 4`.
    fn patchDheader(self: *Encoder, off: usize) void {
        const payload: u32 = @intCast(self.buf.items.len - off - 4);
        self.buf.items[off + 0] = @truncate(payload);
        self.buf.items[off + 1] = @truncate(payload >> 8);
        self.buf.items[off + 2] = @truncate(payload >> 16);
        self.buf.items[off + 3] = @truncate(payload >> 24);
    }
};

// ── Public hashing helpers ────────────────────────────────────────────────────

/// First 4 bytes of MD5 of the UTF-8 member name (no null terminator).
/// Used as NameHash in MinimalMemberDetail and for @hashid member-ID computation.
pub fn nameHash(name: []const u8) [4]u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(name);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    return digest[0..4].*;
}

/// EquivalenceHash = first 14 bytes of MD5 of the serialized TypeObject.
/// This is the on-wire identifier used by other DDS implementations (Cyclone,
/// FastDDS, etc.) to match types.  §7.3.4.5 DDS-XTypes v1.3.
pub fn computeEquivalenceHash(type_object_bytes: []const u8) EquivalenceHash {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(type_object_bytes);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    return digest[0..14].*;
}

/// SHA-256 of the serialized TypeObject — zidl project convention.
/// NOT transmitted on the wire; used as a strong out-of-band fingerprint.
pub fn computeTypeIdentifier(type_object_bytes: []const u8) [32]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(type_object_bytes);
    var out: [32]u8 = undefined;
    sha.final(&out);
    return out;
}

// ── TypeIdentifier encoding ───────────────────────────────────────────────────
//
// TypeIdentifier is a @FINAL union switch (octet).  For plain/primitive types
// the discriminant alone identifies the type; for non-plain types the
// discriminant (EK_MINIMAL) is followed by a 14-byte EquivalenceHash.
//
// writeTypeIdentifier() writes the complete TypeIdentifier (discriminant + any
// data) into enc, including any needed alignment padding before data fields
// inside collection headers.

fn writeTypeIdentifier(
    enc: *Encoder,
    alloc: std.mem.Allocator,
    tr: ir.TypeRef,
    /// Array dimensions in IDL declaration order.  Empty = scalar or sequence.
    dims: []const u64,
) anyerror!void {
    // ── Array ────────────────────────────────────────────────────────────────
    if (dims.len > 0) {
        // All dimensions < 256 → SMALL; any dimension >= 256 → LARGE.
        const small = blk: {
            for (dims) |d| if (d >= 256) break :blk false;
            break :blk true;
        };
        const equiv_kind: u8 = if (typeRefIsFullyDescriptive(tr)) EK_BOTH else EK_MINIMAL;
        if (small) {
            try enc.writeU8(alloc, TI_PLAIN_ARRAY_SMALL);
            // PlainArraySElemDefn (@final struct):
            //   PlainCollectionHeader: equiv_kind (u8), element_flags (u16)
            try enc.writeU8(alloc, equiv_kind);
            try enc.writeU16Le(alloc, TRY_CONSTRUCT_DISCARD);
            // SBoundSeq: sequence<u8> with the dimensions
            try enc.writeU32Le(alloc, @intCast(dims.len));
            for (dims) |d| try enc.writeU8(alloc, @intCast(d));
        } else {
            try enc.writeU8(alloc, TI_PLAIN_ARRAY_LARGE);
            try enc.writeU8(alloc, equiv_kind);
            try enc.writeU16Le(alloc, TRY_CONSTRUCT_DISCARD);
            // LBoundSeq: sequence<u32>
            try enc.writeU32Le(alloc, @intCast(dims.len));
            for (dims) |d| try enc.writeU32Le(alloc, @intCast(d));
        }
        // Inline element TypeIdentifier (no dims — element is a scalar)
        try writeTypeIdentifier(enc, alloc, tr, &.{});
        return;
    }

    // ── Scalar / sequence ────────────────────────────────────────────────────
    switch (tr) {
        .base => |b| {
            try enc.writeU8(alloc, baseTypeKind(b));
            // Primitives: discriminant alone — no member data.
        },

        .string => |bound| {
            if (bound == null or bound.? < 256) {
                try enc.writeU8(alloc, TI_STRING8_SMALL);
                // StringSTypeDefn: { SBound bound; }
                try enc.writeU8(alloc, if (bound) |b| @intCast(b) else 0);
            } else {
                try enc.writeU8(alloc, TI_STRING8_LARGE);
                // StringLTypeDefn: { LBound bound; }
                try enc.writeU32Le(alloc, @intCast(bound.?));
            }
        },

        .wstring => |bound| {
            if (bound == null or bound.? < 256) {
                try enc.writeU8(alloc, TI_STRING16_SMALL);
                try enc.writeU8(alloc, if (bound) |b| @intCast(b) else 0);
            } else {
                try enc.writeU8(alloc, TI_STRING16_LARGE);
                try enc.writeU32Le(alloc, @intCast(bound.?));
            }
        },

        .sequence => |seq| {
            const elem_bound = seq.bound;
            const elem_tr = seq.element.*;
            const equiv_kind: u8 = if (typeRefIsFullyDescriptive(elem_tr)) EK_BOTH else EK_MINIMAL;
            if (elem_bound == null or elem_bound.? < 256) {
                try enc.writeU8(alloc, TI_PLAIN_SEQUENCE_SMALL);
                // PlainSequenceSElemDefn (@final struct):
                //   PlainCollectionHeader: equiv_kind (u8), element_flags (u16)
                try enc.writeU8(alloc, equiv_kind);
                try enc.writeU16Le(alloc, TRY_CONSTRUCT_DISCARD);
                // SBound: bound (u8)
                try enc.writeU8(alloc, if (elem_bound) |b| @intCast(b) else 0);
            } else {
                try enc.writeU8(alloc, TI_PLAIN_SEQUENCE_LARGE);
                try enc.writeU8(alloc, equiv_kind);
                try enc.writeU16Le(alloc, TRY_CONSTRUCT_DISCARD);
                // LBound: bound (u32)
                try enc.writeU32Le(alloc, @intCast(elem_bound.?));
            }
            // Inline element TypeIdentifier
            try writeTypeIdentifier(enc, alloc, elem_tr, &.{});
        },

        .named => |td| {
            // Non-plain type: EK_MINIMAL + 14-byte EquivalenceHash.
            const eq_hash = try computeNamedEquivalenceHash(alloc, td);
            try enc.writeU8(alloc, EK_MINIMAL);
            try enc.writeBytes(alloc, &eq_hash);
        },

        // map and fixed_pt: not yet supported; emit TK_NONE as fallback.
        // TODO: implement TI_PLAIN_MAP_* and fixed-point TypeIdentifiers.
        .map, .fixed_pt => {
            try enc.writeU8(alloc, TK_NONE);
        },
    }
}

/// Returns true if the TypeRef has a "fully-descriptive" TypeIdentifier
/// (i.e. the TI alone fully identifies the type; no TypeObject required).
/// Used to determine PlainCollectionHeader.equiv_kind for collection TypeIds.
fn typeRefIsFullyDescriptive(tr: ir.TypeRef) bool {
    return switch (tr) {
        .base => true, // all primitives: TK_NONE…TK_CHAR16
        // strings/wstrings are plain (their TI encodes the bound):
        .string, .wstring => true,
        else => false, // named, sequence, array, map → needs TypeObject or recursive TI
    };
}

/// Map an IDL base type to its TypeKind constant.
fn baseTypeKind(b: ast.BaseTypeSpec) u8 {
    return switch (b) {
        .boolean => TK_BOOLEAN,
        .octet, .uint8 => TK_UINT8,
        .char => TK_CHAR8,
        .wchar => TK_CHAR16,
        .int8 => TK_INT8,
        .short, .int16 => TK_INT16,
        .long, .int32 => TK_INT32,
        .long_long, .int64 => TK_INT64,
        .unsigned_short, .uint16 => TK_UINT16,
        .unsigned_long, .uint32 => TK_UINT32,
        .unsigned_long_long, .uint64 => TK_UINT64,
        .float => TK_FLOAT32,
        .double => TK_FLOAT64,
        .long_double => TK_FLOAT128,
        .any, .object, .value_base => TK_NONE,
    };
}

// ── Named type EquivalenceHash ────────────────────────────────────────────────

/// Compute the EquivalenceHash (MD5[0..14]) for a named TypeDecl by encoding
/// its MinimalTypeObject and hashing the result.
fn computeNamedEquivalenceHash(alloc: std.mem.Allocator, td: ir.TypeDecl) !EquivalenceHash {
    const bytes = try encodeMinimalTypeDecl(alloc, td);
    defer alloc.free(bytes);
    return computeEquivalenceHash(bytes);
}

/// Encode a MinimalTypeObject for any named type.
/// Returns the full XCDR2 LE bytes (encap header + payload); caller owns slice.
pub fn encodeMinimalTypeDecl(alloc: std.mem.Allocator, td: ir.TypeDecl) anyerror![]u8 {
    return switch (td) {
        .struct_ => |s| encodeMinimalStruct(alloc, s),
        .enum_ => |e| encodeMinimalEnum(alloc, e),
        .union_ => |u| encodeMinimalUnion(alloc, u),
        .bitmask => |b| encodeMinimalBitmask(alloc, b),
        .bitset => |b| encodeMinimalBitset(alloc, b),
        // TODO: alias (typedef), native, exception, interface TypeObjects
        else => encodeMinimalFallback(alloc, TK_NONE),
    };
}

// ── MinimalStructType encoding ────────────────────────────────────────────────
//
// XCDR2 LE stream layout for a struct:
//
//   [4]  Encap header: 00 07 00 00
//   [TypeObject — @appendable union]:
//     [4]  DHEADER
//     [1]  EK_MINIMAL
//     [MinimalTypeObject — @final union]:
//       [1]  TK_STRUCTURE
//       [MinimalStructType — @final struct]:
//         [2]  struct_flags (u16, 2-byte aligned)
//         [MinimalStructHeader — @appendable struct]:
//           [4]  DHEADER
//           [1+…]  base_type TypeIdentifier (TK_NONE if no base)
//           [MinimalTypeDetail — @final, empty]
//         [sequence<MinimalStructMember> — count + elements]:
//           [4]  count (u32, 4-byte aligned)
//           for each member:
//             [MinimalStructMember — @appendable]:
//               [4]  DHEADER
//               [CommonStructMember — @final]:
//                 [4]  member_id (u32)
//                 [2]  member_flags (u16)
//                 [1+…]  member_type_id TypeIdentifier
//               [MinimalMemberDetail — @final]:
//                 [4]  name_hash ([4]u8, alignment 1)

/// Encode the full XCDR2 LE MinimalTypeObject for an IDL struct.
/// Caller owns the returned slice.
pub fn encodeMinimalStruct(alloc: std.mem.Allocator, s: *const ir.Struct) ![]u8 {
    var enc = Encoder{};
    defer enc.deinit(alloc);

    try enc.writeEncapHeader(alloc);

    // TypeObject (@appendable union)
    const to_dh = try enc.reserveDheader(alloc);
    try enc.writeU8(alloc, EK_MINIMAL);

    // MinimalTypeObject (@final union) — discriminant only, no DHEADER
    try enc.writeU8(alloc, TK_STRUCTURE);

    // MinimalStructType (@final struct)
    try enc.writeU16Le(alloc, structTypeFlags(s.annotations));

    // MinimalStructHeader (@appendable struct)
    const msh_dh = try enc.reserveDheader(alloc);
    if (s.base) |base| {
        const eq_hash = try computeNamedEquivalenceHash(alloc, base);
        try enc.writeU8(alloc, EK_MINIMAL);
        try enc.writeBytes(alloc, &eq_hash);
    } else {
        try enc.writeU8(alloc, TK_NONE); // no base type
    }
    // MinimalTypeDetail is @final and empty — nothing to write
    enc.patchDheader(msh_dh);

    // MinimalStructMemberSeq: sequence<MinimalStructMember>
    const base_count = baseStructMemberCount(s.base);
    try enc.writeU32Le(alloc, @intCast(s.members.len));
    for (s.members, 0..) |m, i| {
        try encodeMinimalStructMember(&enc, alloc, &m, @intCast(base_count + i));
    }

    enc.patchDheader(to_dh);
    return enc.buf.toOwnedSlice(alloc);
}

fn structTypeFlags(ann: ir.TypeAnnotations) u16 {
    var flags: u16 = switch (ann.extensibility) {
        .final => IS_FINAL,
        .appendable => IS_APPENDABLE,
        .mutable => IS_MUTABLE,
    };
    if (ann.is_nested) flags |= IS_NESTED;
    return flags;
}

/// Count members in the base struct chain (for member-ID offset).
fn baseStructMemberCount(base: ?ir.TypeDecl) usize {
    const b = base orelse return 0;
    return switch (b) {
        .struct_ => |s| baseStructMemberCount(s.base) + s.members.len,
        else => 0,
    };
}

/// Encode a single MinimalStructMember (@appendable struct) into enc.
fn encodeMinimalStructMember(
    enc: *Encoder,
    alloc: std.mem.Allocator,
    m: *const ir.StructMember,
    member_idx: u32,
) anyerror!void {
    const msm_dh = try enc.reserveDheader(alloc);

    // CommonStructMember (@final struct): member_id, member_flags, member_type_id
    const member_id: u32 = m.annotations.id orelse member_idx;
    try enc.writeU32Le(alloc, member_id);
    try enc.writeU16Le(alloc, memberFlags(m.annotations));
    try writeTypeIdentifier(enc, alloc, m.type_ref, m.dimensions);

    // MinimalMemberDetail (@final struct): name_hash [4]u8
    const nh = nameHash(m.name);
    try enc.writeBytes(alloc, &nh);

    enc.patchDheader(msm_dh);
}

fn memberFlags(ann: ir.MemberAnnotations) u16 {
    var flags: u16 = TRY_CONSTRUCT_DISCARD;
    if (ann.is_optional) flags |= IS_OPTIONAL;
    if (ann.must_understand) flags |= IS_MUST_UNDERSTAND;
    if (ann.is_key) flags |= IS_KEY;
    return flags;
}

// ── MinimalEnumeratedType encoding ───────────────────────────────────────────
//
// XCDR2 LE layout for an enum:
//
//   [4]  Encap header
//   [TypeObject — @appendable union]:
//     [4]  DHEADER
//     [1]  EK_MINIMAL
//     [MinimalTypeObject — @final union]:
//       [1]  TK_ENUM
//       [MinimalEnumeratedType — @final struct]:
//         [2]  enum_flags (u16, unused, = 0)
//         [MinimalEnumeratedHeader — @appendable]:
//           [4]  DHEADER
//           [CommonEnumeratedHeader — @final]: bit_bound (u16)
//         [sequence<MinimalEnumeratedLiteral>]:
//           [4]  count (u32, 4-byte aligned)
//           for each literal (sorted by value per spec):
//             [MinimalEnumeratedLiteral — @appendable]:
//               [4]  DHEADER
//               [CommonEnumeratedLiteral — @appendable]:
//                 [4]  DHEADER
//                 [4]  value (i32)
//                 [2]  flags (u16, EnumeratedLiteralFlag = 0)
//               [MinimalMemberDetail — @final]: name_hash [4]u8

/// Encode the full XCDR2 LE MinimalTypeObject for an IDL enum.
/// Caller owns the returned slice.
pub fn encodeMinimalEnum(alloc: std.mem.Allocator, e: *const ir.Enum) ![]u8 {
    var enc = Encoder{};
    defer enc.deinit(alloc);

    try enc.writeEncapHeader(alloc);

    // TypeObject (@appendable union)
    const to_dh = try enc.reserveDheader(alloc);
    try enc.writeU8(alloc, EK_MINIMAL);

    // MinimalTypeObject (@final union)
    try enc.writeU8(alloc, TK_ENUM);

    // MinimalEnumeratedType (@final struct)
    try enc.writeU16Le(alloc, 0); // enum_flags: unused

    // MinimalEnumeratedHeader (@appendable)
    const meh_dh = try enc.reserveDheader(alloc);
    // CommonEnumeratedHeader (@final): bit_bound (u16)
    const bit_bound: u16 = e.annotations.bit_bound orelse 32;
    try enc.writeU16Le(alloc, bit_bound);
    enc.patchDheader(meh_dh);

    // MinimalEnumeratedLiteralSeq: sequence<MinimalEnumeratedLiteral>
    // Spec: ordered by numeric value (ascending).
    // IR enumerators are in declaration order with sequential auto-values;
    // explicit values might be out of order — we sort a local copy.
    const sorted = try alloc.dupe(ir.Enumerator, e.enumerators);
    defer alloc.free(sorted);
    std.mem.sort(ir.Enumerator, sorted, {}, struct {
        fn lt(_: void, a: ir.Enumerator, b: ir.Enumerator) bool {
            return a.value < b.value;
        }
    }.lt);

    try enc.writeU32Le(alloc, @intCast(sorted.len));
    for (sorted) |en| {
        // MinimalEnumeratedLiteral (@appendable)
        const mel_dh = try enc.reserveDheader(alloc);

        // CommonEnumeratedLiteral (@appendable)
        const cel_dh = try enc.reserveDheader(alloc);
        try enc.writeI32Le(alloc, @intCast(en.value));
        try enc.writeU16Le(alloc, 0); // flags: EnumeratedLiteralFlag, unused
        enc.patchDheader(cel_dh);

        // MinimalMemberDetail (@final): name_hash [4]u8
        const nh = nameHash(en.name);
        try enc.writeBytes(alloc, &nh);

        enc.patchDheader(mel_dh);
    }

    enc.patchDheader(to_dh);
    return enc.buf.toOwnedSlice(alloc);
}

// ── MinimalUnionType encoding ─────────────────────────────────────────────────
//
// XCDR2 LE stream layout for a union:
//
//   [4]  Encap header: 00 07 00 00
//   [TypeObject — @appendable union]:
//     [4]  DHEADER
//     [1]  EK_MINIMAL
//     [MinimalTypeObject — @final union]:
//       [1]  TK_UNION
//       [MinimalUnionType — @final struct]:
//         [2]  union_flags (UnionTypeFlag u16, 2-byte aligned)
//         [MinimalUnionHeader — @appendable]:
//           [4]  DHEADER
//           [MinimalTypeDetail — @final, empty — nothing written]
//         [MinimalDiscriminatorMember — @appendable]:
//           [4]  DHEADER
//           [CommonDiscriminatorMember — @final]:
//             [2]  member_flags (UnionDiscriminatorFlag u16)
//             [1+…]  type_id (TypeIdentifier of discriminant)
//         [sequence<MinimalUnionMember>]:
//           [4]  count (u32, 4-byte aligned)
//           for each member (ordered by member_id):
//             [MinimalUnionMember — @appendable]:
//               [4]  DHEADER
//               [CommonUnionMember — @final]:
//                 [4]  member_id (u32)
//                 [2]  member_flags (UnionMemberFlag u16; IS_DEFAULT set for default arm)
//                 [1+…]  type_id (TypeIdentifier)
//                 [sequence<long>]:  label_seq (i32 values, ascending)
//                   [4]  count (u32)
//                   for each label: [4]  value (i32)
//               [MinimalMemberDetail — @final]:
//                 [4]  name_hash ([4]u8)

/// Encode the full XCDR2 LE MinimalTypeObject for an IDL union.
/// Caller owns the returned slice.
pub fn encodeMinimalUnion(alloc: std.mem.Allocator, u: *const ir.Union) ![]u8 {
    var enc = Encoder{};
    defer enc.deinit(alloc);

    try enc.writeEncapHeader(alloc);

    // TypeObject (@appendable union)
    const to_dh = try enc.reserveDheader(alloc);
    try enc.writeU8(alloc, EK_MINIMAL);

    // MinimalTypeObject (@final union) — discriminant only, no DHEADER
    try enc.writeU8(alloc, TK_UNION);

    // MinimalUnionType (@final struct)
    try enc.writeU16Le(alloc, structTypeFlags(u.annotations));

    // MinimalUnionHeader (@appendable, contains only empty MinimalTypeDetail)
    const muh_dh = try enc.reserveDheader(alloc);
    // MinimalTypeDetail is @final and empty — nothing to write
    enc.patchDheader(muh_dh);

    // MinimalDiscriminatorMember (@appendable)
    const mdm_dh = try enc.reserveDheader(alloc);
    // CommonDiscriminatorMember (@final): member_flags (u16), type_id
    try enc.writeU16Le(alloc, TRY_CONSTRUCT_DISCARD); // UnionDiscriminatorFlag
    try writeTypeIdentifier(&enc, alloc, u.discriminant, &.{});
    enc.patchDheader(mdm_dh);

    // MinimalUnionMemberSeq: sequence<MinimalUnionMember> ordered by member_id.
    // Build an index array and sort it by member_id before encoding.
    const Idx = struct { seq_idx: u32, member_id: u32 };
    var indices = try alloc.alloc(Idx, u.cases.len);
    defer alloc.free(indices);
    for (u.cases, 0..) |c, i| {
        indices[i] = .{
            .seq_idx = @intCast(i),
            .member_id = c.annotations.id orelse @as(u32, @intCast(i)),
        };
    }
    std.mem.sort(Idx, indices, {}, struct {
        fn lt(_: void, a: Idx, b: Idx) bool {
            return a.member_id < b.member_id;
        }
    }.lt);

    try enc.writeU32Le(alloc, @intCast(u.cases.len));
    for (indices) |idx| {
        const c = &u.cases[idx.seq_idx];
        try encodeMinimalUnionMember(&enc, alloc, c, idx.member_id, u.discriminant);
    }

    enc.patchDheader(to_dh);
    return enc.buf.toOwnedSlice(alloc);
}

fn encodeMinimalUnionMember(
    enc: *Encoder,
    alloc: std.mem.Allocator,
    c: *const ir.UnionCase,
    member_id: u32,
    discriminant: ir.TypeRef,
) anyerror!void {
    const mum_dh = try enc.reserveDheader(alloc);

    // CommonUnionMember (@final struct)
    try enc.writeU32Le(alloc, member_id);

    // Default arm: empty labels slice → IS_DEFAULT flag set, label_seq empty.
    const is_default = c.labels.len == 0;
    const flags: u16 = if (is_default) TRY_CONSTRUCT_DISCARD | IS_DEFAULT else TRY_CONSTRUCT_DISCARD;
    try enc.writeU16Le(alloc, flags);

    // type_id: TypeIdentifier for the case member's type
    try writeTypeIdentifier(enc, alloc, c.type_ref, c.dimensions);

    // label_seq: sequence<long> (i32 values), ordered ascending by value.
    if (is_default) {
        try enc.writeU32Le(alloc, 0); // empty sequence
    } else {
        var labels = try alloc.alloc(i32, c.labels.len);
        defer alloc.free(labels);
        for (c.labels, 0..) |lbl, i| {
            labels[i] = @intCast(resolveLabelValue(lbl, discriminant));
        }
        std.mem.sort(i32, labels, {}, struct {
            fn lt(_: void, a: i32, b: i32) bool {
                return a < b;
            }
        }.lt);
        try enc.writeU32Le(alloc, @intCast(labels.len));
        for (labels) |v| try enc.writeI32Le(alloc, v);
    }

    // MinimalMemberDetail (@final struct): name_hash [4]u8
    const nh = nameHash(c.name);
    try enc.writeBytes(alloc, &nh);

    enc.patchDheader(mum_dh);
}

/// Resolve a union case label to its i64 numeric value.
/// For enumerator labels, looks up the value in the discriminant's enum type.
fn resolveLabelValue(label: ir.UnionLabel, discriminant: ir.TypeRef) i64 {
    return switch (label) {
        .integer => |v| v,
        .boolean => |v| if (v) 1 else 0,
        .enumerator => |name| blk: {
            switch (discriminant) {
                .named => |td| switch (td) {
                    .enum_ => |e| {
                        for (e.enumerators) |en| {
                            if (std.mem.eql(u8, en.name, name))
                                break :blk @as(i64, @intCast(en.value));
                        }
                    },
                    else => {},
                },
                else => {},
            }
            break :blk 0; // fallback — shouldn't occur in valid IDL
        },
        .default => 0, // shouldn't be called for default arms (handled by empty labels)
    };
}

// ── MinimalBitmaskType encoding ───────────────────────────────────────────────
//
// XCDR2 LE layout for a bitmask:
//
//   [4]  Encap header: 00 07 00 00
//   [TypeObject — @appendable union]:
//     [4]  DHEADER
//     [1]  EK_MINIMAL
//     [MinimalTypeObject — @final union]:
//       [1]  TK_BITMASK
//       [MinimalBitmaskType — @appendable struct]:
//         [4]  DHEADER
//         [2]  bitmask_flags (u16, unused = 0)
//         [MinimalBitmaskHeader — @appendable]:
//           [4]  DHEADER
//           [CommonEnumeratedHeader — @final]:
//             [2]  bit_bound (u16; default 32)
//         [sequence<MinimalBitflag>]:
//           [4]  count (u32, 4-byte aligned)
//           for each bit (ordered by position = declaration index):
//             [MinimalBitflag — @appendable]:
//               [4]  DHEADER
//               [CommonBitflag — @final]:
//                 [2]  position (u16)
//                 [2]  flags (BitflagFlag u16, unused = 0)
//               [MinimalMemberDetail — @final]:
//                 [4]  name_hash ([4]u8)

/// Encode the full XCDR2 LE MinimalTypeObject for an IDL bitmask.
/// Caller owns the returned slice.
pub fn encodeMinimalBitmask(alloc: std.mem.Allocator, b: *const ir.Bitmask) ![]u8 {
    var enc = Encoder{};
    defer enc.deinit(alloc);

    try enc.writeEncapHeader(alloc);

    // TypeObject (@appendable union)
    const to_dh = try enc.reserveDheader(alloc);
    try enc.writeU8(alloc, EK_MINIMAL);

    // MinimalTypeObject (@final union) — discriminant only, no DHEADER
    try enc.writeU8(alloc, TK_BITMASK);

    // MinimalBitmaskType (@appendable struct) — has its own DHEADER
    const mbt_dh = try enc.reserveDheader(alloc);
    try enc.writeU16Le(alloc, 0); // bitmask_flags: unused

    // MinimalBitmaskHeader (@appendable) = MinimalEnumeratedHeader
    const mbh_dh = try enc.reserveDheader(alloc);
    // CommonEnumeratedHeader (@final): bit_bound (u16)
    const bit_bound: u16 = b.annotations.bit_bound orelse 32;
    try enc.writeU16Le(alloc, bit_bound);
    enc.patchDheader(mbh_dh);

    // MinimalBitflagSeq: sequence<MinimalBitflag>, ordered by position (= index).
    try enc.writeU32Le(alloc, @intCast(b.bits.len));
    for (b.bits, 0..) |bit, i| {
        const position: u16 = @intCast(i);
        // MinimalBitflag (@appendable)
        const mbf_dh = try enc.reserveDheader(alloc);
        // CommonBitflag (@final): position (u16), flags (BitflagFlag u16, unused)
        try enc.writeU16Le(alloc, position);
        try enc.writeU16Le(alloc, 0); // BitflagFlag: unused
        // MinimalMemberDetail (@final): name_hash [4]u8
        try enc.writeBytes(alloc, &nameHash(bit.name));
        enc.patchDheader(mbf_dh);
    }

    enc.patchDheader(mbt_dh);
    enc.patchDheader(to_dh);
    return enc.buf.toOwnedSlice(alloc);
}

// ── MinimalBitsetType encoding ────────────────────────────────────────────────
//
// XCDR2 LE layout for a bitset:
//
//   [4]  Encap header: 00 07 00 00
//   [TypeObject — @appendable union]:
//     [4]  DHEADER
//     [1]  EK_MINIMAL
//     [MinimalTypeObject — @final union]:
//       [1]  TK_BITSET
//       [MinimalBitsetType — @appendable struct]:
//         [4]  DHEADER
//         [2]  bitset_flags (u16, unused = 0)
//         [MinimalBitsetHeader — @appendable, empty]:
//           [4]  DHEADER (payload = 0)
//         [sequence<MinimalBitfield>]:
//           [4]  count (u32, 4-byte aligned)
//           for each named bitfield (ordered by bit position):
//             [MinimalBitfield — @appendable]:
//               [4]  DHEADER
//               [CommonBitfield — @final]:
//                 [2]  position (u16, starting bit of this field)
//                 [2]  flags (BitsetMemberFlag u16, unused = 0)
//                 [1]  bitcount (octet)
//                 [1]  holder_type (TypeKind; TK_BOOLEAN for single-bit / no type_ref)
//               [4]  name_hash ([4]u8, written directly — not via MinimalMemberDetail)

/// Encode the full XCDR2 LE MinimalTypeObject for an IDL bitset.
/// Caller owns the returned slice.
pub fn encodeMinimalBitset(alloc: std.mem.Allocator, b: *const ir.Bitset) ![]u8 {
    var enc = Encoder{};
    defer enc.deinit(alloc);

    try enc.writeEncapHeader(alloc);

    // TypeObject (@appendable union)
    const to_dh = try enc.reserveDheader(alloc);
    try enc.writeU8(alloc, EK_MINIMAL);

    // MinimalTypeObject (@final union) — discriminant only, no DHEADER
    try enc.writeU8(alloc, TK_BITSET);

    // MinimalBitsetType (@appendable struct) — has its own DHEADER
    const mbt_dh = try enc.reserveDheader(alloc);
    try enc.writeU16Le(alloc, 0); // bitset_flags: unused

    // MinimalBitsetHeader (@appendable, empty — available for future extension)
    const mbh_dh = try enc.reserveDheader(alloc);
    enc.patchDheader(mbh_dh);

    // Count total MinimalBitfield entries (one per name per field group).
    var total_names: usize = 0;
    for (b.fields) |f| total_names += f.names.len;

    // MinimalBitfieldSeq: sequence<MinimalBitfield>, ordered by position.
    try enc.writeU32Le(alloc, @intCast(total_names));
    var bit_pos: u16 = 0;
    for (b.fields) |f| {
        // Determine holder_type: null type_ref = boolean single-bit.
        const holder_type: u8 = if (f.type_ref) |tr| switch (tr) {
            .base => |base| baseTypeKind(base),
            else => TK_NONE,
        } else TK_BOOLEAN;

        // One MinimalBitfield entry per name in this field group.
        for (f.names) |name| {
            // MinimalBitfield (@appendable)
            const mbf_dh = try enc.reserveDheader(alloc);
            // CommonBitfield (@final)
            try enc.writeU16Le(alloc, bit_pos); // position
            try enc.writeU16Le(alloc, 0); // BitsetMemberFlag: unused
            try enc.writeU8(alloc, f.bits); // bitcount
            try enc.writeU8(alloc, holder_type); // TypeKind
            // name_hash written directly (MinimalBitfield.name_hash: NameHash)
            try enc.writeBytes(alloc, &nameHash(name));
            enc.patchDheader(mbf_dh);
        }
        bit_pos += @as(u16, f.bits);
    }

    enc.patchDheader(mbt_dh);
    enc.patchDheader(to_dh);
    return enc.buf.toOwnedSlice(alloc);
}

// ── Fallback encoder ──────────────────────────────────────────────────────────

/// Emit a minimal valid TypeObject with TK_NONE (or any given kind byte) as a
/// placeholder for types not yet handled (native, exception, interface, alias).
fn encodeMinimalFallback(alloc: std.mem.Allocator, tk: u8) ![]u8 {
    var enc = Encoder{};
    defer enc.deinit(alloc);
    try enc.writeEncapHeader(alloc);
    const to_dh = try enc.reserveDheader(alloc);
    try enc.writeU8(alloc, EK_MINIMAL);
    try enc.writeU8(alloc, tk);
    enc.patchDheader(to_dh);
    return enc.buf.toOwnedSlice(alloc);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "nameHash: 'color' example from spec" {
    // DDS-XTypes §7.3.1.2.1.1 example: MD5("color") = 70DDA5DF...
    // First 4 bytes: {0x70, 0xDD, 0xA5, 0xDF}
    const nh = nameHash("color");
    try testing.expectEqual(@as(u8, 0x70), nh[0]);
    try testing.expectEqual(@as(u8, 0xDD), nh[1]);
    try testing.expectEqual(@as(u8, 0xA5), nh[2]);
    try testing.expectEqual(@as(u8, 0xDF), nh[3]);
}

test "nameHash: 'shapesize' example from spec" {
    // DDS-XTypes §7.3.1.2.1.1 example: MD5("shapesize") starts with DA 90 77 14
    const nh = nameHash("shapesize");
    try testing.expectEqual(@as(u8, 0xDA), nh[0]);
    try testing.expectEqual(@as(u8, 0x90), nh[1]);
    try testing.expectEqual(@as(u8, 0x77), nh[2]);
    try testing.expectEqual(@as(u8, 0x14), nh[3]);
}

test "encodeMinimalStruct: encap header is XCDR2 LE" {
    const alloc = testing.allocator;
    const s = ir.Struct{
        .name = "P",
        .qualified_name = "P",
        .span = undefined,
        .members = &.{},
        .annotations = .{},
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);

    try testing.expect(bytes.len >= 4);
    try testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try testing.expectEqual(@as(u8, 0x07), bytes[1]); // CDR2_LE = 0x0007
    try testing.expectEqual(@as(u8, 0x00), bytes[2]);
    try testing.expectEqual(@as(u8, 0x00), bytes[3]);
}

test "encodeMinimalStruct: EK_MINIMAL and TK_STRUCTURE present" {
    const alloc = testing.allocator;
    const s = ir.Struct{
        .name = "P",
        .qualified_name = "P",
        .span = undefined,
        .members = &.{},
        .annotations = .{},
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);

    // EK_MINIMAL and TK_STRUCTURE must appear somewhere after the encap+DHEADER
    var found_ek = false;
    var found_tk = false;
    for (bytes) |b| {
        if (b == EK_MINIMAL) found_ek = true;
        if (b == TK_STRUCTURE) found_tk = true;
    }
    try testing.expect(found_ek);
    try testing.expect(found_tk);
}

test "encodeMinimalStruct: @final struct_flags" {
    const alloc = testing.allocator;
    const s = ir.Struct{
        .name = "F",
        .qualified_name = "F",
        .span = undefined,
        .members = &.{},
        .annotations = .{ .extensibility = .final },
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);
    // IS_FINAL = 0x0001 encoded LE: bytes 01 00
    var found = false;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == 0x01 and bytes[i + 1] == 0x00) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "encodeMinimalStruct: @appendable struct_flags" {
    const alloc = testing.allocator;
    const s = ir.Struct{
        .name = "A",
        .qualified_name = "A",
        .span = undefined,
        .members = &.{},
        .annotations = .{ .extensibility = .appendable },
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);
    // IS_APPENDABLE = 0x0002 encoded LE: bytes 02 00
    var found = false;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == 0x02 and bytes[i + 1] == 0x00) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "encodeMinimalStruct: member count in output" {
    const alloc = testing.allocator;
    const x_member = ir.StructMember{
        .name = "x",
        .span = undefined,
        .type_ref = .{ .base = .long },
        .dimensions = &.{},
        .annotations = .{},
    };
    const y_member = ir.StructMember{
        .name = "y",
        .span = undefined,
        .type_ref = .{ .base = .long },
        .dimensions = &.{},
        .annotations = .{},
    };
    const members = [_]ir.StructMember{ x_member, y_member };
    const s = ir.Struct{
        .name = "Point",
        .qualified_name = "Point",
        .span = undefined,
        .members = &members,
        .annotations = .{},
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);
    // Sequence count = 2 must appear as LE u32: 02 00 00 00
    const needle = [_]u8{ 0x02, 0x00, 0x00, 0x00 };
    var found = false;
    if (bytes.len >= needle.len) {
        var i: usize = 0;
        while (i + needle.len <= bytes.len) : (i += 1) {
            if (std.mem.eql(u8, bytes[i .. i + needle.len], &needle)) {
                found = true;
                break;
            }
        }
    }
    try testing.expect(found);
}

test "encodeMinimalStruct: name_hash of 'x' member present" {
    const alloc = testing.allocator;
    const x_member = ir.StructMember{
        .name = "x",
        .span = undefined,
        .type_ref = .{ .base = .long },
        .dimensions = &.{},
        .annotations = .{},
    };
    const members = [_]ir.StructMember{x_member};
    const s = ir.Struct{
        .name = "P",
        .qualified_name = "P",
        .span = undefined,
        .members = &members,
        .annotations = .{},
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);

    // name_hash("x") = MD5("x")[0..4]
    const nh = nameHash("x");
    var found = false;
    if (bytes.len >= 4) {
        var i: usize = 0;
        while (i + 4 <= bytes.len) : (i += 1) {
            if (std.mem.eql(u8, bytes[i .. i + 4], &nh)) {
                found = true;
                break;
            }
        }
    }
    try testing.expect(found);
}

test "encodeMinimalStruct: TK_INT32 member type identifier present" {
    const alloc = testing.allocator;
    const x_member = ir.StructMember{
        .name = "x",
        .span = undefined,
        .type_ref = .{ .base = .long }, // IDL long → TK_INT32
        .dimensions = &.{},
        .annotations = .{},
    };
    const members = [_]ir.StructMember{x_member};
    const s = ir.Struct{
        .name = "P",
        .qualified_name = "P",
        .span = undefined,
        .members = &members,
        .annotations = .{},
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);

    var found = false;
    for (bytes) |b| if (b == TK_INT32) {
        found = true;
        break;
    };
    try testing.expect(found);
}

test "computeEquivalenceHash: 14 bytes, non-zero for non-empty input" {
    const dummy = [_]u8{ 0x00, 0x07, 0x00, 0x00, 0xF1 };
    const h = computeEquivalenceHash(&dummy);
    try testing.expectEqual(@as(usize, 14), h.len);
    var all_zero = true;
    for (h) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try testing.expect(!all_zero);
}

test "computeTypeIdentifier: 32 bytes, matches runtime re-computation" {
    const dummy = [_]u8{ 0x00, 0x07, 0x00, 0x00, 0xF1, 0x51 };
    const ti = computeTypeIdentifier(&dummy);
    try testing.expectEqual(@as(usize, 32), ti.len);

    // Verify against a fresh runtime hash
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(&dummy);
    var expected: [32]u8 = undefined;
    sha.final(&expected);
    try testing.expectEqualSlices(u8, &expected, &ti);
}

test "encodeMinimalEnum: encap header and EK_MINIMAL + TK_ENUM present" {
    const alloc = testing.allocator;
    const enumerators = [_]ir.Enumerator{
        .{ .name = "RED", .span = undefined, .value = 0, .has_explicit_value = false, .raw = &.{} },
        .{ .name = "GREEN", .span = undefined, .value = 1, .has_explicit_value = false, .raw = &.{} },
    };
    const e = ir.Enum{
        .name = "Color",
        .qualified_name = "Color",
        .span = undefined,
        .enumerators = &enumerators,
        .annotations = .{},
    };
    const bytes = try encodeMinimalEnum(alloc, &e);
    defer alloc.free(bytes);

    try testing.expect(bytes.len >= 4);
    try testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try testing.expectEqual(@as(u8, 0x07), bytes[1]);

    var found_ek = false;
    var found_tk = false;
    for (bytes) |b| {
        if (b == EK_MINIMAL) found_ek = true;
        if (b == TK_ENUM) found_tk = true;
    }
    try testing.expect(found_ek);
    try testing.expect(found_tk);
}

test "encodeMinimalEnum: literal name_hashes present in output" {
    const alloc = testing.allocator;
    const enumerators = [_]ir.Enumerator{
        .{ .name = "RED", .span = undefined, .value = 0, .has_explicit_value = false, .raw = &.{} },
        .{ .name = "GREEN", .span = undefined, .value = 1, .has_explicit_value = false, .raw = &.{} },
    };
    const e = ir.Enum{
        .name = "Color",
        .qualified_name = "Color",
        .span = undefined,
        .enumerators = &enumerators,
        .annotations = .{},
    };
    const bytes = try encodeMinimalEnum(alloc, &e);
    defer alloc.free(bytes);

    // Each enumerator's name_hash must appear somewhere in the output.
    for ([_][]const u8{ "RED", "GREEN" }) |name| {
        const nh = nameHash(name);
        var found = false;
        var i: usize = 0;
        while (i + 4 <= bytes.len) : (i += 1) {
            if (std.mem.eql(u8, bytes[i .. i + 4], &nh)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "encodeMinimalEnum: out-of-order literals are sorted by value" {
    // Literals declared with explicit values out of order:
    // Z=2, A=0, M=1 — output must contain them sorted by value (A, M, Z).
    const alloc = testing.allocator;
    const enumerators = [_]ir.Enumerator{
        .{ .name = "Z", .span = undefined, .value = 2, .has_explicit_value = true, .raw = &.{} },
        .{ .name = "A", .span = undefined, .value = 0, .has_explicit_value = true, .raw = &.{} },
        .{ .name = "M", .span = undefined, .value = 1, .has_explicit_value = true, .raw = &.{} },
    };
    const e = ir.Enum{
        .name = "E",
        .qualified_name = "E",
        .span = undefined,
        .enumerators = &enumerators,
        .annotations = .{},
    };
    const bytes = try encodeMinimalEnum(alloc, &e);
    defer alloc.free(bytes);

    // Find positions of each name_hash; A (value 0) must appear before M (1),
    // M before Z (2).
    const nhA = nameHash("A");
    const nhM = nameHash("M");
    const nhZ = nameHash("Z");
    var posA: usize = bytes.len;
    var posM: usize = bytes.len;
    var posZ: usize = bytes.len;
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 1) {
        const sl = bytes[i .. i + 4];
        if (posA == bytes.len and std.mem.eql(u8, sl, &nhA)) posA = i;
        if (posM == bytes.len and std.mem.eql(u8, sl, &nhM)) posM = i;
        if (posZ == bytes.len and std.mem.eql(u8, sl, &nhZ)) posZ = i;
    }
    try testing.expect(posA < posM);
    try testing.expect(posM < posZ);
}

test "encodeMinimalStruct: string member uses TI_STRING8_SMALL" {
    const alloc = testing.allocator;
    const mem = ir.StructMember{
        .name = "label",
        .span = undefined,
        .type_ref = .{ .string = null }, // unbounded string
        .dimensions = &.{},
        .annotations = .{},
    };
    const members = [_]ir.StructMember{mem};
    const s = ir.Struct{
        .name = "S",
        .qualified_name = "S",
        .span = undefined,
        .members = &members,
        .annotations = .{},
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);

    var found = false;
    for (bytes) |b| if (b == TI_STRING8_SMALL) {
        found = true;
        break;
    };
    try testing.expect(found);
}

test "encodeMinimalStruct: sequence member uses TI_PLAIN_SEQUENCE_SMALL" {
    // sequence<long> — unbounded, small element bound
    const alloc = testing.allocator;
    const elem_tr = ir.TypeRef{ .base = .long };
    const seq_tr = ir.TypeRef{ .sequence = .{ .element = &elem_tr, .bound = null } };
    const mem = ir.StructMember{
        .name = "items",
        .span = undefined,
        .type_ref = seq_tr,
        .dimensions = &.{},
        .annotations = .{},
    };
    const members = [_]ir.StructMember{mem};
    const s = ir.Struct{
        .name = "S",
        .qualified_name = "S",
        .span = undefined,
        .members = &members,
        .annotations = .{},
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);

    var found = false;
    for (bytes) |b| if (b == TI_PLAIN_SEQUENCE_SMALL) {
        found = true;
        break;
    };
    try testing.expect(found);
}

test "encodeMinimalStruct: array member uses TI_PLAIN_ARRAY_SMALL" {
    const alloc = testing.allocator;
    const elem_tr = ir.TypeRef{ .base = .long };
    const dims = [_]u64{3};
    const mem = ir.StructMember{
        .name = "arr",
        .span = undefined,
        .type_ref = elem_tr,
        .dimensions = &dims,
        .annotations = .{},
    };
    const members = [_]ir.StructMember{mem};
    const s = ir.Struct{
        .name = "S",
        .qualified_name = "S",
        .span = undefined,
        .members = &members,
        .annotations = .{},
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);

    var found = false;
    for (bytes) |b| if (b == TI_PLAIN_ARRAY_SMALL) {
        found = true;
        break;
    };
    try testing.expect(found);
}

test "encodeMinimalStruct: named member type uses EK_MINIMAL + hash" {
    // A struct member with an enum type: its TypeIdentifier must be
    // EK_MINIMAL (0xF1) followed by a 14-byte equivalence hash.
    const alloc = testing.allocator;

    const enumerators = [_]ir.Enumerator{
        .{ .name = "RED", .span = undefined, .value = 0, .has_explicit_value = false, .raw = &.{} },
    };
    var color_enum = ir.Enum{
        .name = "Color",
        .qualified_name = "Color",
        .span = undefined,
        .enumerators = &enumerators,
        .annotations = .{},
    };
    const mem = ir.StructMember{
        .name = "c",
        .span = undefined,
        .type_ref = .{ .named = .{ .enum_ = &color_enum } },
        .dimensions = &.{},
        .annotations = .{},
    };
    const members = [_]ir.StructMember{mem};
    const s = ir.Struct{
        .name = "S",
        .qualified_name = "S",
        .span = undefined,
        .members = &members,
        .annotations = .{},
    };
    const bytes = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes);

    // EK_MINIMAL (0xF1) must appear as a TypeIdentifier discriminant (not just
    // as the outer EK_MINIMAL byte which we already test elsewhere).
    // Count occurrences of 0xF1 — there should be at least two:
    // one for the outer TypeObject and one for the member TypeIdentifier.
    var count: usize = 0;
    for (bytes) |b| if (b == EK_MINIMAL) {
        count += 1;
    };
    try testing.expect(count >= 2);
}

// ── Union tests ───────────────────────────────────────────────────────────────

test "encodeMinimalUnion: encap header and EK_MINIMAL + TK_UNION present" {
    const alloc = testing.allocator;
    const u = ir.Union{
        .name = "U",
        .qualified_name = "U",
        .span = undefined,
        .discriminant = .{ .base = .long },
        .cases = &.{},
        .annotations = .{},
    };
    const bytes = try encodeMinimalUnion(alloc, &u);
    defer alloc.free(bytes);

    try testing.expect(bytes.len >= 4);
    try testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try testing.expectEqual(@as(u8, 0x07), bytes[1]);

    var found_ek = false;
    var found_tk = false;
    for (bytes) |byt| {
        if (byt == EK_MINIMAL) found_ek = true;
        if (byt == TK_UNION) found_tk = true;
    }
    try testing.expect(found_ek);
    try testing.expect(found_tk);
}

test "encodeMinimalUnion: IS_FINAL union_flags present" {
    const alloc = testing.allocator;
    const u = ir.Union{
        .name = "U",
        .qualified_name = "U",
        .span = undefined,
        .discriminant = .{ .base = .long },
        .cases = &.{},
        .annotations = .{ .extensibility = .final },
    };
    const bytes = try encodeMinimalUnion(alloc, &u);
    defer alloc.free(bytes);
    // IS_FINAL = 0x0001 LE: 01 00
    var found = false;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == 0x01 and bytes[i + 1] == 0x00) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "encodeMinimalUnion: member count in output" {
    const alloc = testing.allocator;
    const case_a = ir.UnionCase{
        .labels = &[_]ir.UnionLabel{.{ .integer = 1 }},
        .name = "a",
        .span = undefined,
        .type_ref = .{ .base = .long },
        .dimensions = &.{},
        .annotations = .{},
    };
    const case_b = ir.UnionCase{
        .labels = &[_]ir.UnionLabel{.{ .integer = 2 }},
        .name = "b",
        .span = undefined,
        .type_ref = .{ .base = .float },
        .dimensions = &.{},
        .annotations = .{},
    };
    const cases = [_]ir.UnionCase{ case_a, case_b };
    const u = ir.Union{
        .name = "U",
        .qualified_name = "U",
        .span = undefined,
        .discriminant = .{ .base = .long },
        .cases = &cases,
        .annotations = .{},
    };
    const bytes = try encodeMinimalUnion(alloc, &u);
    defer alloc.free(bytes);
    // Sequence count = 2: 02 00 00 00
    const needle = [_]u8{ 0x02, 0x00, 0x00, 0x00 };
    var found = false;
    var i: usize = 0;
    while (i + needle.len <= bytes.len) : (i += 1) {
        if (std.mem.eql(u8, bytes[i .. i + needle.len], &needle)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "encodeMinimalUnion: default case has IS_DEFAULT flag set" {
    const alloc = testing.allocator;
    // Default case: empty labels slice
    const default_case = ir.UnionCase{
        .labels = &.{},
        .name = "other",
        .span = undefined,
        .type_ref = .{ .base = .long },
        .dimensions = &.{},
        .annotations = .{},
    };
    const cases = [_]ir.UnionCase{default_case};
    const u = ir.Union{
        .name = "U",
        .qualified_name = "U",
        .span = undefined,
        .discriminant = .{ .base = .long },
        .cases = &cases,
        .annotations = .{},
    };
    const bytes = try encodeMinimalUnion(alloc, &u);
    defer alloc.free(bytes);
    // FLAG_IS_DEFAULT | TRY_CONSTRUCT_DISCARD = 0x41 LE: 41 00
    var found = false;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == 0x41 and bytes[i + 1] == 0x00) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "encodeMinimalUnion: case name_hash present in output" {
    const alloc = testing.allocator;
    const case_x = ir.UnionCase{
        .labels = &[_]ir.UnionLabel{.{ .integer = 0 }},
        .name = "x",
        .span = undefined,
        .type_ref = .{ .base = .long },
        .dimensions = &.{},
        .annotations = .{},
    };
    const cases = [_]ir.UnionCase{case_x};
    const u = ir.Union{
        .name = "U",
        .qualified_name = "U",
        .span = undefined,
        .discriminant = .{ .base = .long },
        .cases = &cases,
        .annotations = .{},
    };
    const bytes = try encodeMinimalUnion(alloc, &u);
    defer alloc.free(bytes);

    const nh = nameHash("x");
    var found = false;
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 1) {
        if (std.mem.eql(u8, bytes[i .. i + 4], &nh)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// ── Bitmask tests ─────────────────────────────────────────────────────────────

test "encodeMinimalBitmask: EK_MINIMAL + TK_BITMASK present" {
    const alloc = testing.allocator;
    const bits = [_]ir.BitmaskBit{
        .{ .name = "A", .span = undefined },
        .{ .name = "B", .span = undefined },
    };
    const b = ir.Bitmask{
        .name = "Flags",
        .qualified_name = "Flags",
        .span = undefined,
        .bits = &bits,
        .annotations = .{},
    };
    const bytes = try encodeMinimalBitmask(alloc, &b);
    defer alloc.free(bytes);

    try testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try testing.expectEqual(@as(u8, 0x07), bytes[1]);

    var found_ek = false;
    var found_tk = false;
    for (bytes) |byt| {
        if (byt == EK_MINIMAL) found_ek = true;
        if (byt == TK_BITMASK) found_tk = true;
    }
    try testing.expect(found_ek);
    try testing.expect(found_tk);
}

test "encodeMinimalBitmask: bit name_hashes present in output" {
    const alloc = testing.allocator;
    const bits = [_]ir.BitmaskBit{
        .{ .name = "ENABLE", .span = undefined },
        .{ .name = "VERBOSE", .span = undefined },
    };
    const b = ir.Bitmask{
        .name = "Flags",
        .qualified_name = "Flags",
        .span = undefined,
        .bits = &bits,
        .annotations = .{},
    };
    const bytes = try encodeMinimalBitmask(alloc, &b);
    defer alloc.free(bytes);

    for ([_][]const u8{ "ENABLE", "VERBOSE" }) |name| {
        const nh = nameHash(name);
        var found = false;
        var i: usize = 0;
        while (i + 4 <= bytes.len) : (i += 1) {
            if (std.mem.eql(u8, bytes[i .. i + 4], &nh)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "encodeMinimalBitmask: @bit_bound annotation in header" {
    const alloc = testing.allocator;
    const b = ir.Bitmask{
        .name = "M",
        .qualified_name = "M",
        .span = undefined,
        .bits = &.{},
        .annotations = .{ .bit_bound = 8 },
    };
    const bytes = try encodeMinimalBitmask(alloc, &b);
    defer alloc.free(bytes);
    // bit_bound = 8 = 0x0008 LE: 08 00
    var found = false;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == 0x08 and bytes[i + 1] == 0x00) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// ── Bitset tests ──────────────────────────────────────────────────────────────

test "encodeMinimalBitset: EK_MINIMAL + TK_BITSET present" {
    const alloc = testing.allocator;
    const elem_tr = ir.TypeRef{ .base = .short };
    const field_names = [_][]const u8{"count"};
    const fields = [_]ir.BitsetField{
        .{ .names = &field_names, .bits = 4, .type_ref = elem_tr, .span = undefined },
    };
    const b = ir.Bitset{
        .name = "BS",
        .qualified_name = "BS",
        .span = undefined,
        .base = null,
        .fields = &fields,
        .raw = &.{},
    };
    const bytes = try encodeMinimalBitset(alloc, &b);
    defer alloc.free(bytes);

    try testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try testing.expectEqual(@as(u8, 0x07), bytes[1]);

    var found_ek = false;
    var found_tk = false;
    for (bytes) |byt| {
        if (byt == EK_MINIMAL) found_ek = true;
        if (byt == TK_BITSET) found_tk = true;
    }
    try testing.expect(found_ek);
    try testing.expect(found_tk);
}

test "encodeMinimalBitset: bitfield name_hash present in output" {
    const alloc = testing.allocator;
    const elem_tr = ir.TypeRef{ .base = .octet };
    const field_names = [_][]const u8{"level"};
    const fields = [_]ir.BitsetField{
        .{ .names = &field_names, .bits = 3, .type_ref = elem_tr, .span = undefined },
    };
    const b = ir.Bitset{
        .name = "BS",
        .qualified_name = "BS",
        .span = undefined,
        .base = null,
        .fields = &fields,
        .raw = &.{},
    };
    const bytes = try encodeMinimalBitset(alloc, &b);
    defer alloc.free(bytes);

    const nh = nameHash("level");
    var found = false;
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 1) {
        if (std.mem.eql(u8, bytes[i .. i + 4], &nh)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "encodeMinimalStruct: deterministic output for same input" {
    const alloc = testing.allocator;
    const x_member = ir.StructMember{
        .name = "x",
        .span = undefined,
        .type_ref = .{ .base = .long },
        .dimensions = &.{},
        .annotations = .{},
    };
    const members = [_]ir.StructMember{x_member};
    const s = ir.Struct{
        .name = "P",
        .qualified_name = "P",
        .span = undefined,
        .members = &members,
        .annotations = .{},
    };
    const bytes1 = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes1);
    const bytes2 = try encodeMinimalStruct(alloc, &s);
    defer alloc.free(bytes2);
    try testing.expectEqualSlices(u8, bytes1, bytes2);
}
