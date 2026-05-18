//! zidl-xtypes — DDS-XTypes TypeObject/TypeIdentifier constants and utilities.
//!
//! Optional dependency for DDS-XTYPES type discovery.  Omit for embedded
//! targets (XRCE profile) where TypeObject is not needed.
//!
//! ## Generated code uses this package for (Phase 5+):
//!   - XTypes constants: EK_MINIMAL, TK_STRUCTURE, etc.
//!   - TypeObject registration helpers (Phase 6)
//!   - Topic descriptor generation (Phase 6)
//!
//! ## What generated Zig code contains (from Phase 5):
//!   ```zig
//!   // Inside each IDL struct — pre-computed at code-gen time, zero runtime cost:
//!   pub const type_object: []const u8 = &[_]u8{0x00, 0x07, …};
//!   pub const equivalence_hash: [14]u8 = [14]u8{…};   // MD5[0..14] — on-wire DDS hash
//!   pub const type_identifier: [32]u8  = [32]u8{…};   // SHA-256    — zidl fingerprint
//!   ```
//!
//! ## Architecture (confirmed by prototype in src/backend/zig_typeobject_proto.zig):
//!   - TypeObject CDR bytes are computed at zidl code-gen time (not at Zig compile time
//!     in the generated code), then emitted as literal byte arrays.
//!   - Both equivalence_hash and type_identifier are also pre-computed at code-gen time.
//!   - Zero runtime overhead; bare-metal / XRCE safe.
//!
//! ## References
//!   docs/xtypes_typeobject.md — full TypeObject IDL (Annex B) and encoding rules
//!   src/backend/zig_typeobject.zig — encoder that computes the bytes

// ── EquivalenceKind ───────────────────────────────────────────────────────────

/// Equivalence kind for TypeIdentifier and TypeObject discriminant.
/// Source: DDS-XTypes v1.3 Annex B.
pub const EK_MINIMAL: u8 = 0xF1;
pub const EK_COMPLETE: u8 = 0xF2;
pub const EK_BOTH: u8 = 0xF3; // fully-descriptive; same under both relations

// ── TypeKind ──────────────────────────────────────────────────────────────────

/// TypeKind constants — used as TypeObject inner-union discriminants and as
/// TypeIdentifiers for primitive types.  Source: DDS-XTypes v1.3 Annex B.
pub const TK_NONE: u8 = 0x00;

// Primitive
pub const TK_BOOLEAN: u8 = 0x01;
pub const TK_BYTE: u8 = 0x02;
pub const TK_INT16: u8 = 0x03;
pub const TK_INT32: u8 = 0x04; // IDL `long`
pub const TK_INT64: u8 = 0x05; // IDL `long long`
pub const TK_UINT16: u8 = 0x06;
pub const TK_UINT32: u8 = 0x07;
pub const TK_UINT64: u8 = 0x08;
pub const TK_FLOAT32: u8 = 0x09;
pub const TK_FLOAT64: u8 = 0x0A;
pub const TK_FLOAT128: u8 = 0x0B;
pub const TK_INT8: u8 = 0x0C;
pub const TK_UINT8: u8 = 0x0D;
pub const TK_CHAR8: u8 = 0x10;
pub const TK_CHAR16: u8 = 0x11;

// String
pub const TK_STRING8: u8 = 0x20;
pub const TK_STRING16: u8 = 0x21;

// Named
pub const TK_ALIAS: u8 = 0x30;

// Enumerated
pub const TK_ENUM: u8 = 0x40;
pub const TK_BITMASK: u8 = 0x41;

// Structured
pub const TK_ANNOTATION: u8 = 0x50;
pub const TK_STRUCTURE: u8 = 0x51;
pub const TK_UNION: u8 = 0x52;
pub const TK_BITSET: u8 = 0x53;

// Collection
pub const TK_SEQUENCE: u8 = 0x60;
pub const TK_ARRAY: u8 = 0x61;
pub const TK_MAP: u8 = 0x62;

// ── TypeIdentifierKind (plain collections and strings with bounds) ─────────────

pub const TI_STRING8_SMALL: u8 = 0x70; // SBound (u8) follows; 0 = unbounded
pub const TI_STRING8_LARGE: u8 = 0x71; // LBound (u32) follows
pub const TI_STRING16_SMALL: u8 = 0x72;
pub const TI_STRING16_LARGE: u8 = 0x73;
pub const TI_PLAIN_SEQUENCE_SMALL: u8 = 0x80; // max_length < 256
pub const TI_PLAIN_SEQUENCE_LARGE: u8 = 0x81; // max_length >= 256
pub const TI_PLAIN_ARRAY_SMALL: u8 = 0x90; // all dims < 256
pub const TI_PLAIN_ARRAY_LARGE: u8 = 0x91; // any dim >= 256
pub const TI_PLAIN_MAP_SMALL: u8 = 0xA0;
pub const TI_PLAIN_MAP_LARGE: u8 = 0xA1;
pub const TI_STRONGLY_CONNECTED_COMPONENT: u8 = 0xB0;

// ── TypeFlag ──────────────────────────────────────────────────────────────────

/// StructTypeFlag / UnionTypeFlag bits.
/// Minimal mask (affects assignability): M | A | F = 0x0007.
pub const IS_FINAL: u16 = 0x0001;
pub const IS_APPENDABLE: u16 = 0x0002;
pub const IS_MUTABLE: u16 = 0x0004;
pub const IS_NESTED: u16 = 0x0008;
pub const IS_AUTOID_HASH: u16 = 0x0010;
pub const TYPE_FLAG_MINIMAL_MASK: u16 = 0x0007;

// ── MemberFlag ────────────────────────────────────────────────────────────────

/// StructMemberFlag bits.
/// Minimal mask (affects assignability): T1 | T2 | O | M | K | D = 0x003F.
pub const TRY_CONSTRUCT1: u16 = 0x0001; // T1 | 00=INVALID, 01=DISCARD, 10=USE_DEFAULT, 11=TRIM
pub const TRY_CONSTRUCT2: u16 = 0x0002; // T2
pub const IS_EXTERNAL: u16 = 0x0004;
pub const IS_OPTIONAL: u16 = 0x0008;
pub const IS_MUST_UNDERSTAND: u16 = 0x0010;
pub const IS_KEY: u16 = 0x0020;
pub const IS_DEFAULT: u16 = 0x0040;
pub const MEMBER_FLAG_MINIMAL_MASK: u16 = 0x003F;

/// Convenience: TRY_CONSTRUCT = DISCARD (T1=1, T2=0).
pub const TRY_CONSTRUCT_DISCARD: u16 = TRY_CONSTRUCT1;

// ── XCDR2 LE encapsulation header ─────────────────────────────────────────────

/// XCDR2 LE encapsulation header bytes, written verbatim at the start of every
/// TypeObject serialization.  Representation ID 0x0007 = CDR_ENC_VERSION_2 LE;
/// written as a big-endian pair per RTPS spec (do NOT write via LE u16).
///
/// Confirmed against Cyclone DDS 11.0.1 ddsi_protocol.h: ENCAP_CDR2_LE = 0x0007.
pub const XCDR2_LE_ENCAP: [4]u8 = .{ 0x00, 0x07, 0x00, 0x00 };
