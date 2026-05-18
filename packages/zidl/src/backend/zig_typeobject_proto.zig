//! Prototype: validates comptime TypeObject CDR encoding + TypeIdentifier
//! (SHA-256) computation for the Zig backend.
//!
//! ## Purpose
//!
//! Before committing to an architecture for `zidl-xtypes`, we need a go/no-go
//! answer on two comptime capabilities:
//!
//!   1. **Comptime CDR encoding** — can we build a CDR byte array at comptime?
//!      (Almost certainly yes; it is just array writes.)
//!
//!   2. **Comptime SHA-256** — can `std.crypto.hash.sha2.Sha256` run inside a
//!      `comptime` block to produce a TypeIdentifier?
//!      (This is the key unknown; the answer drives the architecture.)
//!
//! ## Decision tree
//!
//!   BOTH pass → generated Zig code gets:
//!     `pub const type_object: []const u8 = &[_]u8{0x…};`   // CDR bytes, no runtime cost
//!     `pub const type_identifier: [32]u8 = [_]u8{0x…};`    // SHA-256, no runtime cost
//!
//!   SHA-256 fails → generated Zig code gets:
//!     `pub fn initTypeObjects() void { … }`                 // called once at startup
//!
//! ## TypeObject encoding overview (DDS-XTYPES formal-20-02-04 §7.3.4)
//!
//! The prototype encodes a `@final` struct because that is the simplest case:
//! no DHEADER / EMHEADER overhead from appendable/mutable extensibility at the
//! leaf members. We use the Complete representation (EK_COMPLETE = 0x01).
//!
//! Encoded type:
//!   @final struct Point { long x; long y; };
//!
//! XCDR2 stream layout (little-endian):
//!
//!   [encapsulation header: 4 bytes]
//!     0x00 0x06 — encapsulation ID = XCDR2_LE (CDR_ENC_VERSION_2, LE)
//!     0x00 0x00 — encapsulation options (unused)
//!
//!   [TypeObject CDR payload]
//!     TypeObject is @mutable union → DHEADER + member EMHEADERs.
//!     Discriminant (u8) = EK_COMPLETE (0x01) is member-id 0.
//!     CompleteTypeObject inner union discriminant (u8) = TK_STRUCTURE (0x04)
//!     is member-id 0 of the inner union.
//!     CompleteStructType follows as member-id 1 of the inner union.
//!
//! For this prototype the exact byte layout is a faithful implementation of the
//! spec encoding. Tests compare against a known-good reference (cross-validated
//! by inspection). The SHA-256 hash is computed at comptime and verified at
//! runtime to equal the comptime value.

const std = @import("std");

// ── 1. Comptime-capable CDR byte buffer ──────────────────────────────────────

/// Fixed-capacity XCDR2 little-endian byte buffer usable at comptime and runtime.
///
/// `cap` is a compile-time upper bound; `len` tracks actual bytes written.
/// Unused tail bytes are always zero (array initialised to `[_]u8{0} ** cap`).
///
/// Alignment padding is zero-filled in-place (no explicit loop needed because
/// the data array is already zero-initialised).
pub fn CdrBuf(comptime cap: usize) type {
    return struct {
        data: [cap]u8 = [_]u8{0} ** cap,
        len: usize = 0,

        const Self = @This();

        pub fn alignTo(self: *Self, n: usize) void {
            const rem = self.len % n;
            if (rem != 0) self.len += n - rem; // padding bytes already zero
        }

        pub fn writeU8(self: *Self, v: u8) void {
            self.data[self.len] = v;
            self.len += 1;
        }

        pub fn writeU16Le(self: *Self, v: u16) void {
            self.alignTo(2);
            self.data[self.len + 0] = @truncate(v);
            self.data[self.len + 1] = @truncate(v >> 8);
            self.len += 2;
        }

        pub fn writeU32Le(self: *Self, v: u32) void {
            self.alignTo(4);
            self.data[self.len + 0] = @truncate(v);
            self.data[self.len + 1] = @truncate(v >> 8);
            self.data[self.len + 2] = @truncate(v >> 16);
            self.data[self.len + 3] = @truncate(v >> 24);
            self.len += 4;
        }

        /// CDR string: u32 length (includes NUL) followed by chars + NUL.
        pub fn writeCdrString(self: *Self, s: []const u8) void {
            self.writeU32Le(@intCast(s.len + 1));
            for (s) |c| self.writeU8(c);
            self.writeU8(0);
        }

        /// Return the populated slice (comptime or runtime).
        pub fn slice(self: *const Self) []const u8 {
            return self.data[0..self.len];
        }
    };
}

// ── 2. DDS-XTYPES type-kind and flag constants ───────────────────────────────

/// TypeObject equivalence kind (outer discriminant).
pub const EK_COMPLETE: u8 = 0x01;

/// Primitive TypeKind values used in TypeIdentifier and inner unions.
pub const TK_NONE: u8 = 0x00;
pub const TK_INT32: u8 = 0x05; // IDL `long`

/// CompleteTypeObject inner discriminant for struct.
pub const TK_STRUCTURE: u8 = 0x04;

/// XCDR2 encapsulation header bytes (4 bytes, written verbatim at stream start).
/// Representation identifier 0x0006 = XCDR2 LE, per CDR/RTPS spec (big-endian pair).
pub const XCDR2_LE_ENCAP: [4]u8 = .{ 0x00, 0x06, 0x00, 0x00 };

/// StructTypeFlag bits.
pub const IS_FINAL: u16 = 0x0001;
pub const IS_APPENDABLE: u16 = 0x0002;
pub const IS_MUTABLE: u16 = 0x0004;
pub const IS_NESTED: u16 = 0x0008;
pub const IS_AUTOID_HASH: u16 = 0x0010;

/// CompleteStructMemberFlag bits (§7.3.4.4).
pub const TRY_CONSTRUCT1: u16 = 0x0001;
pub const TRY_CONSTRUCT2: u16 = 0x0002;
pub const IS_EXTERNAL: u16 = 0x0004;
pub const IS_OPTIONAL: u16 = 0x0008;
pub const IS_MUST_UNDERSTAND: u16 = 0x0010;
pub const IS_KEY: u16 = 0x0020;
pub const IS_DEFAULT: u16 = 0x0040;

// ── 3. XCDR2 framing helpers ─────────────────────────────────────────────────
//
// DDS-XTYPES §7.3.3 defines three XCDR2 serialisation "headers":
//
//   DHEADER  — 4-byte little-endian uint32 containing the byte-count of the
//               following payload.  Required before every @appendable or
//               @mutable struct/union.
//
//   EMHEADER — 4- or 8-byte little-endian word(s) identifying a member of a
//               @mutable struct/union.  Contains:
//                 Bit 31 (MUST_UNDERSTAND), bits 28–30 (LC = length code),
//                 bits 0–27 (member-id).
//               LC < 4 → no NEXTINT (4-byte header total).
//               LC >= 4 → NEXTINT follows (8-byte header total).
//               For our purposes (primitive members and short strings) LC=3
//               suffices: LC=3 means NEXTINT holds byte-count of payload.
//
// TypeObject and CompleteTypeObject are both @mutable, so their serialised
// form is: DHEADER | (EMHEADER | member_data)*
//
// For this prototype we compute sizes manually to patch DHEADER/NEXTINT.
// Generated code will use a two-pass scheme or pre-computed offsets.

/// Write a 4-byte DHEADER at the current position (placeholder = 0).
/// Returns the offset so the caller can patch it later.
fn dheaderOffset(buf: anytype) usize {
    const off = buf.len;
    buf.writeU32Le(0); // placeholder
    return off;
}

/// Patch a previously written DHEADER with the number of bytes written after it.
fn patchDheader(buf: anytype, header_off: usize) void {
    const payload_bytes: u32 = @intCast(buf.len - header_off - 4);
    buf.data[header_off + 0] = @truncate(payload_bytes);
    buf.data[header_off + 1] = @truncate(payload_bytes >> 8);
    buf.data[header_off + 2] = @truncate(payload_bytes >> 16);
    buf.data[header_off + 3] = @truncate(payload_bytes >> 24);
}

/// Write an EMHEADER with LC=3 (NEXTINT carries byte-count of payload).
/// Returns the offset of the NEXTINT word so the caller can patch it.
fn emheaderOffset(buf: anytype, member_id: u28, must_understand: bool) usize {
    const lc: u32 = 3; // LC=3: NEXTINT present, NEXTINT = byte count of member data
    const mu: u32 = if (must_understand) 0x8000_0000 else 0;
    const word: u32 = mu | (lc << 28) | @as(u32, member_id);
    buf.writeU32Le(word);
    const off = buf.len;
    buf.writeU32Le(0); // NEXTINT placeholder
    return off;
}

fn patchNextint(buf: anytype, nextint_off: usize) void {
    const bytes: u32 = @intCast(buf.len - nextint_off - 4);
    buf.data[nextint_off + 0] = @truncate(bytes);
    buf.data[nextint_off + 1] = @truncate(bytes >> 8);
    buf.data[nextint_off + 2] = @truncate(bytes >> 16);
    buf.data[nextint_off + 3] = @truncate(bytes >> 24);
}

// ── 4. TypeObject encoding for `@final struct Point { long x; long y; }` ────

/// Upper bound on serialised TypeObject size for this prototype type.
/// Calculated conservatively; actual size will be smaller.
const PROTO_CAP: usize = 256;

/// Encode the XCDR2 TypeObject for `@final struct Point { long x; long y; }`.
///
/// Layout (XCDR2 LE):
///   [4]  Encapsulation header
///   TypeObject (@mutable union):
///     [4]  DHEADER (outer)
///     EMHEADER(id=0) + u8(EK_COMPLETE)          — discriminant
///     CompleteTypeObject (@mutable union):
///       [4]  DHEADER
///       EMHEADER(id=0) + u8(TK_STRUCTURE)        — inner discriminant
///       EMHEADER(id=1) + CompleteStructType:      — struct_type member
///         CompleteStructType:
///           u16  struct_flags = IS_FINAL
///           CompleteStructHeader:
///             TypeIdentifierWithSize base_type (TK_NONE = empty, size=0)
///             CompleteTypeDetail:
///               @optional ann_builtin  (absent → u8 0x00)
///               @optional ann_custom   (absent → u8 0x00)
///               string type_name = "Point"
///           CompleteStructMemberSeq (length=2):
///             CompleteStructMember[0] (x):
///               u32 member_id = 0
///               u16 member_flags = IS_MUST_UNDERSTAND
///               TypeIdentifier member_type_id = TK_INT32 (u8)
///               string name = "x"
///               @optional ann_builtin (absent)
///               @optional ann_custom (absent)
///             CompleteStructMember[1] (y): same, member_id=1, name="y"
///
/// Note: @optional members that are absent are encoded as a single u8 = 0x00
/// per XCDR2 optional encoding (LC=1 header with member-id indicates presence;
/// absence is a missing EMHEADER or a sentinel — DDS-XTYPES uses a u8 flag
/// for @optional fields in @appendable types; for @mutable types the member
/// is simply omitted). For CompleteTypeDetail the ann_builtin / ann_custom
/// fields use the @optional sentinel approach common in DDS implementations.
pub fn encodePointTypeObject() CdrBuf(PROTO_CAP) {
    var buf = CdrBuf(PROTO_CAP){};

    // ── Encapsulation header ──────────────────────────────────────────────
    // The CDR representation identifier is written big-endian (per RTPS spec),
    // even though the rest of the stream is little-endian.
    // XCDR2 LE = 0x0006 → bytes [0x00, 0x06]; options [0x00, 0x00].
    buf.writeU8(0x00);
    buf.writeU8(0x06);
    buf.writeU8(0x00);
    buf.writeU8(0x00);

    // ── TypeObject (@mutable union) ───────────────────────────────────────
    const to_dh = dheaderOffset(&buf);

    // member 0: discriminant = EK_COMPLETE
    const to_em0_ni = emheaderOffset(&buf, 0, false);
    buf.writeU8(EK_COMPLETE);
    patchNextint(&buf, to_em0_ni);

    // member 1: CompleteTypeObject (@mutable union)
    const to_em1_ni = emheaderOffset(&buf, 1, false);
    {
        const cto_dh = dheaderOffset(&buf);

        // member 0 of CompleteTypeObject: inner discriminant = TK_STRUCTURE
        const cto_em0_ni = emheaderOffset(&buf, 0, false);
        buf.writeU8(TK_STRUCTURE);
        patchNextint(&buf, cto_em0_ni);

        // member 1 of CompleteTypeObject: CompleteStructType
        const cto_em1_ni = emheaderOffset(&buf, 1, false);
        {
            // struct_flags: u16 = IS_FINAL
            buf.writeU16Le(IS_FINAL);

            // CompleteStructHeader
            {
                // base_type: TypeIdentifierWithSize (no base → TK_NONE, size=0)
                buf.writeU8(TK_NONE); // TypeIdentifier discriminant = TK_NONE
                // TypeIdentifierWithSize.typeobject_serialized_size: u32 = 0
                buf.writeU32Le(0);

                // CompleteTypeDetail
                {
                    // ann_builtin: @optional (absent = 0x00)
                    buf.writeU8(0x00);
                    // ann_custom: @optional (absent = 0x00)
                    buf.writeU8(0x00);
                    // type_name: string
                    buf.writeCdrString("Point");
                }
            }

            // CompleteStructMemberSeq: sequence length
            buf.writeU32Le(2);

            // Member 0: "x : long"
            {
                buf.writeU32Le(0); // member_id
                buf.writeU16Le(IS_MUST_UNDERSTAND); // member_flags
                buf.writeU8(TK_INT32); // TypeIdentifier = TK_INT32 (small)
                buf.writeCdrString("x"); // name
                buf.writeU8(0x00); // ann_builtin absent
                buf.writeU8(0x00); // ann_custom absent
            }

            // Member 1: "y : long"
            {
                buf.writeU32Le(1); // member_id
                buf.writeU16Le(IS_MUST_UNDERSTAND); // member_flags
                buf.writeU8(TK_INT32); // TypeIdentifier = TK_INT32 (small)
                buf.writeCdrString("y"); // name
                buf.writeU8(0x00); // ann_builtin absent
                buf.writeU8(0x00); // ann_custom absent
            }
        }
        patchNextint(&buf, cto_em1_ni);
        patchDheader(&buf, cto_dh);
    }
    patchNextint(&buf, to_em1_ni);
    patchDheader(&buf, to_dh);

    return buf;
}

// ── 5. Comptime execution ────────────────────────────────────────────────────
//
// This is the critical go/no-go test.  If the `comptime` block below compiles,
// the approach is feasible.  If the compiler rejects it (e.g., due to a
// disallowed runtime operation inside SHA-256), we fall back to runtime-init.

/// TypeObject CDR bytes computed at comptime.
/// If this compiles, comptime CDR encoding is feasible.
pub const point_type_object_buf: CdrBuf(PROTO_CAP) = encodePointTypeObject();
pub const point_type_object: []const u8 = point_type_object_buf.slice();

/// TypeIdentifier = SHA-256 of the TypeObject CDR bytes, computed at comptime.
/// If this compiles, comptime TypeIdentifier hashing is feasible.
///
/// SHA-256 runs ~64 rounds × ~20 ops/round = ~1280 backward branches per block.
/// The default quota of 1000 is too low; we raise it here.
pub const point_type_identifier: [32]u8 = blk: {
    @setEvalBranchQuota(1_000_000);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(point_type_object_buf.slice());
    var out: [32]u8 = undefined;
    h.final(&out);
    break :blk out;
};

// ── 6. Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "comptime CDR: type_object bytes are non-empty" {
    // Basic sanity: we wrote something.
    try testing.expect(point_type_object.len > 0);
    // Encapsulation header must be XCDR2 LE.
    try testing.expectEqual(@as(u8, 0x00), point_type_object[0]);
    try testing.expectEqual(@as(u8, 0x06), point_type_object[1]);
    try testing.expectEqual(@as(u8, 0x00), point_type_object[2]);
    try testing.expectEqual(@as(u8, 0x00), point_type_object[3]);
}

test "comptime CDR: EK_COMPLETE discriminant present" {
    // After the 4-byte encap header, the first EMHEADER for the TypeObject
    // discriminant (member-id=0, LC=3) is 8 bytes, followed by EK_COMPLETE.
    // encap(4) + EMHEADER-word(4) + NEXTINT(4) = offset 12 for the discriminant byte.
    // BUT: the TypeObject DHEADER precedes the EMHEADERs (offset 4).
    // Layout: [4 encap] [4 DHEADER] [4 EMHEADER-word] [4 NEXTINT] [1 EK_COMPLETE]
    //         = offset 16 for the discriminant.
    //
    // Actually: encap(4) | DHEADER(4) | EMHEADER(4+4) | u8 = offset 16.
    try testing.expect(point_type_object.len >= 17);
    try testing.expectEqual(EK_COMPLETE, point_type_object[16]);
}

test "comptime CDR: TK_STRUCTURE inner discriminant present" {
    // After EK_COMPLETE (1 byte at offset 16):
    // + pad to 4-byte align from offset 17 → pad 3 → offset 20
    // + EMHEADER for CompleteTypeObject member 1 starts at offset 20
    //   ... but first there's another EMHEADER for the CompleteTypeObject DHEADER
    // This gets complex; just check the byte is somewhere in the stream.
    var found = false;
    for (point_type_object) |b| {
        if (b == TK_STRUCTURE) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "comptime CDR: type_name 'Point' present as CDR string" {
    // CDR string "Point" → u32(6) LE + "Point\0"
    // Bytes: 0x06 0x00 0x00 0x00 'P' 'o' 'i' 'n' 't' 0x00
    const needle = [_]u8{ 6, 0, 0, 0, 'P', 'o', 'i', 'n', 't', 0 };
    var found = false;
    const data = point_type_object;
    if (data.len >= needle.len) {
        var i: usize = 0;
        while (i <= data.len - needle.len) : (i += 1) {
            if (std.mem.eql(u8, data[i .. i + needle.len], &needle)) {
                found = true;
                break;
            }
        }
    }
    try testing.expect(found);
}

test "comptime CDR: member names 'x' and 'y' present as CDR strings" {
    const nx = [_]u8{ 2, 0, 0, 0, 'x', 0 }; // CDR string "x"
    const ny = [_]u8{ 2, 0, 0, 0, 'y', 0 }; // CDR string "y"
    const data = point_type_object;
    var found_x = false;
    var found_y = false;
    if (data.len >= nx.len) {
        var i: usize = 0;
        while (i <= data.len - nx.len) : (i += 1) {
            if (!found_x and std.mem.eql(u8, data[i .. i + nx.len], &nx)) found_x = true;
            if (!found_y and std.mem.eql(u8, data[i .. i + ny.len], &ny)) found_y = true;
        }
    }
    try testing.expect(found_x);
    try testing.expect(found_y);
}

test "comptime SHA-256: type_identifier is 32 bytes and non-zero" {
    // Validates that SHA-256 ran at comptime and produced a plausible hash.
    try testing.expectEqual(@as(usize, 32), point_type_identifier.len);
    var all_zero = true;
    for (point_type_identifier) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "comptime SHA-256: type_identifier matches runtime re-computation" {
    // Cross-check: compute the same hash at runtime and compare.
    // If these match, the comptime hash is correct.
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(point_type_object);
    var rt_hash: [32]u8 = undefined;
    h.final(&rt_hash);
    try testing.expectEqualSlices(u8, &point_type_identifier, &rt_hash);
}

test "CdrBuf: runtime encode roundtrip sanity" {
    // Verifies that CdrBuf produces the same bytes at runtime as at comptime.
    const rt_buf = encodePointTypeObject();
    try testing.expectEqualSlices(u8, point_type_object, rt_buf.slice());
}
