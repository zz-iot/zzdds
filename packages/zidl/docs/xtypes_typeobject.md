# TypeIdentifier / TypeObject Reference

Extracted from DDS-XTypes v1.3 (formal/20-02-04), Annex B and §7.3.4.
Implementation: `src/backend/zig_typeobject.zig`, `packages/zidl-xtypes/src/root.zig`.

---

## EquivalenceKind

| Constant | Value | Meaning |
|---|---|---|
| `EK_MINIMAL`  | `0xF1` | MinimalTypeObject |
| `EK_COMPLETE` | `0xF2` | CompleteTypeObject |
| `EK_BOTH`     | `0xF3` | Fully-descriptive (plain/primitive); same under both relations |

---

## TypeKind (TK_*)

| Constant | Value | IDL type |
|---|---|---|
| `TK_NONE`      | `0x00` | Placeholder / unsupported |
| `TK_BOOLEAN`   | `0x01` | `boolean` |
| `TK_BYTE`      | `0x02` | `byte` |
| `TK_INT16`     | `0x03` | `short` / `int16` |
| `TK_INT32`     | `0x04` | `long` / `int32` |
| `TK_INT64`     | `0x05` | `long long` / `int64` |
| `TK_UINT16`    | `0x06` | `unsigned short` / `uint16` |
| `TK_UINT32`    | `0x07` | `unsigned long` / `uint32` |
| `TK_UINT64`    | `0x08` | `unsigned long long` / `uint64` |
| `TK_FLOAT32`   | `0x09` | `float` |
| `TK_FLOAT64`   | `0x0A` | `double` |
| `TK_FLOAT128`  | `0x0B` | `long double` |
| `TK_INT8`      | `0x0C` | `int8` |
| `TK_UINT8`     | `0x0D` | `uint8` / `octet` |
| `TK_CHAR8`     | `0x10` | `char` |
| `TK_CHAR16`    | `0x11` | `wchar` |
| `TK_STRING8`   | `0x20` | `string` (named type) |
| `TK_STRING16`  | `0x21` | `wstring` (named type) |
| `TK_ALIAS`     | `0x30` | `typedef` |
| `TK_ENUM`      | `0x40` | `enum` |
| `TK_BITMASK`   | `0x41` | `bitmask` |
| `TK_ANNOTATION`| `0x50` | `@annotation` |
| `TK_STRUCTURE` | `0x51` | `struct` |
| `TK_UNION`     | `0x52` | `union` |
| `TK_BITSET`    | `0x53` | `bitset` |
| `TK_SEQUENCE`  | `0x60` | `sequence<T>` (named) |
| `TK_ARRAY`     | `0x61` | `T[N]` (named) |
| `TK_MAP`       | `0x62` | `map<K,V>` (named) |

**Common mistake:** The prototype had `TK_INT32=0x05` and `TK_STRUCTURE=0x04` — these are wrong. Use the values above.

---

## TypeIdentifier kinds (TI_*)

Plain (non-named) type identifiers; the discriminant encodes the full type.

| Constant | Value | Meaning |
|---|---|---|
| `TI_STRING8_SMALL`          | `0x70` | `string<B>` with B=0 (unbounded) or B<256 |
| `TI_STRING8_LARGE`          | `0x71` | `string<B>` with B>=256 |
| `TI_STRING16_SMALL`         | `0x72` | `wstring<B>` with B=0 or B<256 |
| `TI_STRING16_LARGE`         | `0x73` | `wstring<B>` with B>=256 |
| `TI_PLAIN_SEQUENCE_SMALL`   | `0x80` | `sequence<T,B>` with B=0 or B<256 |
| `TI_PLAIN_SEQUENCE_LARGE`   | `0x81` | `sequence<T,B>` with B>=256 |
| `TI_PLAIN_ARRAY_SMALL`      | `0x90` | `T[D1][D2]…` with all dims <256 |
| `TI_PLAIN_ARRAY_LARGE`      | `0x91` | `T[D1][D2]…` with any dim >=256 |

---

## TypeFlag (StructTypeFlag, UnionTypeFlag)

`u16` bitmask encoding the extensibility and nestedness of a named type.

| Constant | Value | Meaning |
|---|---|---|
| `IS_FINAL`      | `0x0001` | `@final` extensibility |
| `IS_APPENDABLE` | `0x0002` | `@appendable` extensibility |
| `IS_MUTABLE`    | `0x0004` | `@mutable` extensibility |
| `IS_NESTED`     | `0x0008` | `@nested` — not a top-level DDS topic |

---

## MemberFlag (StructMemberFlag)

`u16` bitmask on each struct member.

| Constant | Value | Meaning |
|---|---|---|
| `TRY_CONSTRUCT_DISCARD` | `0x0001` | T1=1, T2=0 — discard on decode failure (XCDR default) |
| `FLAG_IS_OPTIONAL`      | `0x0008` | Member has `@optional` |
| `FLAG_IS_MUST_UNDERSTAND`| `0x0010` | Member has `@must_understand` |
| `FLAG_IS_KEY`           | `0x0020` | Member has `@key` |

---

## Hashing Algorithms

### NameHash (for member names and @hashid)

```
NameHash(member_name) = MD5(UTF-8 bytes of member_name)[0..4]
```

- No null terminator in the hash input.
- Used in `MinimalMemberDetail.name_hash`.
- Also used as the `@hashid` member ID (masked to 28 bits: `& 0x0FFFFFFF`).

### EquivalenceHash (on-wire TypeIdentifier for named types)

```
EquivalenceHash(type_object) = MD5(type_object_CDR_bytes)[0..14]
```

- Input: full XCDR2 LE bytes of the MinimalTypeObject (including the 4-byte encap header).
- Output: 14 bytes, used in `TypeIdentifier` when discriminant = `EK_MINIMAL`.
- This is what other DDS implementations (Cyclone DDS, FastDDS) compare to match types.
- Defined in DDS-XTypes §7.3.4.5.

### type_identifier (zidl convention, not on-wire)

```
type_identifier = SHA-256(type_object_CDR_bytes)
```

- 32 bytes.
- Not transmitted; used as a strong fingerprint for out-of-band tooling.
- Emitted as `pub const type_identifier: [32]u8` in generated Zig struct bodies.

---

## Generated Constants (Zig backend)

Inside each generated struct body:

```zig
pub const type_object: []const u8 = &[_]u8{ 0x00, 0x07, 0x00, 0x00, … };
// Full XCDR2 LE MinimalTypeObject bytes (encap header + payload)

pub const equivalence_hash: [14]u8 = [14]u8{ … };
// EquivalenceHash — on-wire DDS type match identifier

pub const type_identifier: [32]u8 = [32]u8{ … };
// SHA-256 fingerprint — zidl convention only
```

---

## XCDR2 LE Stream Layout: MinimalStructType

```
[4]  Encap header: 0x00 0x07 0x00 0x00   (CDR2_LE, big-endian representation ID)
[TypeObject — @appendable union]:
  [4]  DHEADER (u32, payload byte count after this DHEADER)
  [1]  EK_MINIMAL (0xF1)
  [MinimalTypeObject — @final union]:
    [1]  TK_STRUCTURE (0x51)
    [MinimalStructType — @final struct]:
      [2]  struct_flags (TypeFlag u16, 2-byte aligned)
      [MinimalStructHeader — @appendable]:
        [4]  DHEADER
        [1+…]  base_type TypeIdentifier (TK_NONE = 0x00 if no base; or EK_MINIMAL + 14 bytes)
        (MinimalTypeDetail is @final and empty — nothing written)
      [sequence<MinimalStructMember>]:
        [4]  count (u32, 4-byte aligned)
        for each member:
          [MinimalStructMember — @appendable]:
            [4]  DHEADER
            [CommonStructMember — @final]:
              [4]  member_id (u32)
              [2]  member_flags (MemberFlag u16)
              [1+…]  member_type_id TypeIdentifier
            [MinimalMemberDetail — @final]:
              [4]  name_hash ([4]u8, no alignment — written as raw bytes)
```

**member_id** rule: use `@id` annotation value if present; otherwise use the member's
0-based index counting from the first member of the root base class (inheritance flattening).

---

## XCDR2 LE Stream Layout: MinimalEnumeratedType

```
[4]  Encap header: 0x00 0x07 0x00 0x00
[TypeObject — @appendable union]:
  [4]  DHEADER
  [1]  EK_MINIMAL
  [MinimalTypeObject — @final union]:
    [1]  TK_ENUM (0x40)
    [MinimalEnumeratedType — @final struct]:
      [2]  enum_flags (u16 = 0, unused)
      [MinimalEnumeratedHeader — @appendable]:
        [4]  DHEADER
        [CommonEnumeratedHeader — @final]:
          [2]  bit_bound (u16; default = 32 if no @bit_bound annotation)
      [sequence<MinimalEnumeratedLiteral>]:
        [4]  count (u32)
        Literals sorted ascending by numeric value (not declaration order).
        for each literal:
          [MinimalEnumeratedLiteral — @appendable]:
            [4]  DHEADER
            [CommonEnumeratedLiteral — @appendable]:
              [4]  DHEADER
              [4]  value (i32)
              [2]  flags (EnumeratedLiteralFlag u16 = 0)
            [MinimalMemberDetail — @final]:
              [4]  name_hash ([4]u8)
```

---

---

## XCDR2 LE Stream Layout: MinimalUnionType

```
[4]  Encap header: 0x00 0x07 0x00 0x00
[TypeObject — @appendable union]:
  [4]  DHEADER
  [1]  EK_MINIMAL (0xF1)
  [MinimalTypeObject — @final union]:
    [1]  TK_UNION (0x52)
    [MinimalUnionType — @final struct]:
      [2]  union_flags (UnionTypeFlag u16, 2-byte aligned)
      [MinimalUnionHeader — @appendable]:
        [4]  DHEADER
        (MinimalTypeDetail is @final and empty — nothing written)
      [MinimalDiscriminatorMember — @appendable]:
        [4]  DHEADER
        [CommonDiscriminatorMember — @final]:
          [2]  member_flags (UnionDiscriminatorFlag u16 = TRY_CONSTRUCT_DISCARD)
          [1+…]  type_id TypeIdentifier (discriminant type)
      [sequence<MinimalUnionMember>]:
        [4]  count (u32, 4-byte aligned)
        Members ordered by member_id ascending.
        for each member:
          [MinimalUnionMember — @appendable]:
            [4]  DHEADER
            [CommonUnionMember — @final]:
              [4]  member_id (u32; @id annotation value, else sequential index)
              [2]  member_flags (UnionMemberFlag u16; IS_DEFAULT=0x0040 for default arm)
              [1+…]  type_id TypeIdentifier
              [sequence<long>]:  label_seq (i32 values, ascending; empty for default arm)
                [4]  count (u32)
                for each label: [4]  value (i32)
            [MinimalMemberDetail — @final]:
              [4]  name_hash ([4]u8)
```

**default arm**: empty `labels` slice in IR → `IS_DEFAULT` flag set, `label_seq` count = 0.
**enumerator labels**: resolved to numeric value by looking up the discriminant's enum IR node.

---

## XCDR2 LE Stream Layout: MinimalBitmaskType

```
[4]  Encap header: 0x00 0x07 0x00 0x00
[TypeObject — @appendable union]:
  [4]  DHEADER
  [1]  EK_MINIMAL (0xF1)
  [MinimalTypeObject — @final union]:
    [1]  TK_BITMASK (0x41)
    [MinimalBitmaskType — @appendable struct]:
      [4]  DHEADER
      [2]  bitmask_flags (u16 = 0, unused)
      [MinimalBitmaskHeader — @appendable]:
        [4]  DHEADER
        [CommonEnumeratedHeader — @final]:
          [2]  bit_bound (u16; @bit_bound annotation value, default 32)
      [sequence<MinimalBitflag>]:
        [4]  count (u32, 4-byte aligned)
        Ordered by position (declaration index 0, 1, 2, …).
        for each bit:
          [MinimalBitflag — @appendable]:
            [4]  DHEADER
            [CommonBitflag — @final]:
              [2]  position (u16, = declaration index)
              [2]  flags (BitflagFlag u16 = 0, unused)
            [MinimalMemberDetail — @final]:
              [4]  name_hash ([4]u8)
```

---

## XCDR2 LE Stream Layout: MinimalBitsetType

```
[4]  Encap header: 0x00 0x07 0x00 0x00
[TypeObject — @appendable union]:
  [4]  DHEADER
  [1]  EK_MINIMAL (0xF1)
  [MinimalTypeObject — @final union]:
    [1]  TK_BITSET (0x53)
    [MinimalBitsetType — @appendable struct]:
      [4]  DHEADER
      [2]  bitset_flags (u16 = 0, unused)
      [MinimalBitsetHeader — @appendable, empty]:
        [4]  DHEADER (payload = 0)
      [sequence<MinimalBitfield>]:
        [4]  count (u32, 4-byte aligned)  — one entry per name (multi-name fields → N entries)
        Ordered by bit position (accumulated from field 0).
        for each named bitfield:
          [MinimalBitfield — @appendable]:
            [4]  DHEADER
            [CommonBitfield — @final]:
              [2]  position (u16, starting bit index)
              [2]  flags (BitsetMemberFlag u16 = 0, unused)
              [1]  bitcount (octet = field.bits)
              [1]  holder_type (TypeKind; TK_BOOLEAN for null/single-bit type_ref)
            [4]  name_hash ([4]u8, written directly)
```

---

## TypeIdentifier Encoding Rules

| IDL type | Discriminant | Payload after discriminant |
|---|---|---|
| Primitive (boolean, octet, char, etc.) | `TK_*` | None |
| `string<B>` B=0 or B<256 | `TI_STRING8_SMALL` | 1 byte: bound (0 = unbounded) |
| `string<B>` B>=256 | `TI_STRING8_LARGE` | 4 bytes: bound (u32 LE) |
| `wstring<B>` B=0 or B<256 | `TI_STRING16_SMALL` | 1 byte: bound |
| `wstring<B>` B>=256 | `TI_STRING16_LARGE` | 4 bytes: bound |
| `sequence<T,B>` B=0 or B<256 | `TI_PLAIN_SEQUENCE_SMALL` | PlainCollectionHeader + SBound(u8) + elem TI |
| `sequence<T,B>` B>=256 | `TI_PLAIN_SEQUENCE_LARGE` | PlainCollectionHeader + LBound(u32) + elem TI |
| Array (all dims<256) | `TI_PLAIN_ARRAY_SMALL` | PlainCollectionHeader + SBoundSeq + elem TI |
| Array (any dim>=256) | `TI_PLAIN_ARRAY_LARGE` | PlainCollectionHeader + LBoundSeq + elem TI |
| Named type | `EK_MINIMAL` | 14-byte EquivalenceHash |

**PlainCollectionHeader** (@final struct, no DHEADER):
```
[1]  equiv_kind   (EK_BOTH for fully-descriptive elements; EK_MINIMAL otherwise)
[2]  element_flags (u16 = TRY_CONSTRUCT_DISCARD = 0x0001, 2-byte aligned)
```

---

## Supported / Deferred

| Type | Status |
|---|---|
| `struct` | Full MinimalTypeObject |
| `enum` | Full MinimalTypeObject |
| `union` | Full MinimalTypeObject |
| `bitmask` | Full MinimalTypeObject |
| `bitset` | Full MinimalTypeObject |
| `typedef` / alias | Deferred |
| Collections (array, sequence) | TypeIdentifier only (inline in member TI) |
