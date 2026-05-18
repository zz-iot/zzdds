# IDL 4.2 Standardized Annotations

Source: OMG IDL 4.2 (formal/18-01-05) §8, Standardized Annotations.
There are exactly 24 built-in annotations, organized into 6 groups.

---

## zidl Annotation Handling: Pre-interpreted vs Raw

The IR builder uses a **hybrid approach**:

**Pre-interpreted** — parsed into typed IR fields; backends read typed fields, never the raw annotation:

| Annotation | Applied to | IR field |
|---|---|---|
| `@final` / `@appendable` / `@mutable` / `@extensibility` | types | `TypeAnnotations.extensibility` |
| `@nested` | types | `TypeAnnotations.is_nested` |
| `@key` | struct members | `MemberAnnotations.is_key` |
| `@optional` | struct members | `MemberAnnotations.is_optional` |
| `@must_understand` | struct members | `MemberAnnotations.must_understand` |
| `@id` | struct members | `MemberAnnotations.id` |
| `@bound` (non-standard shorthand) | sequence members | TypeRef.sequence.bound |
| `@max` (used as bound on strings) | string/wstring members | TypeRef.string/wstring bound |
| `@bit_bound` | enum declarations | `EnumAnnotations.bit_bound` |

**Raw** (`RawAnnotation` slice, backends inspect by name) — everything else:

`@verbatim`, `@value`, `@default`, `@range`, `@min`, `@max` (non-string), `@unit`,
`@default_literal`, `@external`, `@position`, `@autoid`, `@hashid`,
`@service`, `@oneway`, `@ami`, and all vendor/unknown annotations.

`RawAnnotation` struct: `name: []const u8`, `params: []const AnnotationParam`.

---

## §8.3.1 Group: General Purpose

### @id
Assigns a 32-bit integer identifier to an element (data member or operation).

```idl
@annotation id {
    unsigned long value;
};
```

Applicable to: data members within a constructed type, operations within an interface.
zidl: pre-interpreted into `MemberAnnotations.id`.

### @autoid
Instructs how to automatically allocate member IDs.

```idl
@annotation autoid {
    enum AutoidKind { SEQUENTIAL, HASH };
    AutoidKind value default HASH;
};
```

- `SEQUENTIAL`: IDs are assigned 0, 1, 2, … in declaration order.
- `HASH`: IDs are computed by hashing the member name (default). Algorithm: `MD5(name)[0..4] & 0x0FFFFFFF`.

zidl: kept as raw; backends may inspect it.

### @optional
Marks a member as optional (may be absent in serialized form).

```idl
@annotation optional {
    boolean value default TRUE;
};
```

The compact form `@optional` is equivalent to `@optional(TRUE)`.
zidl: pre-interpreted into `MemberAnnotations.is_optional`.
CDR wire format: 1-byte presence flag precedes the value (1=present, 0=absent).

### @position
Sets an ordering position for an element within a set.

```idl
@annotation position {
    unsigned short value;
};
```

Applicable to: data members, operations.
zidl: kept as raw.

### @value
Sets a constant value for an annotated element.

```idl
@annotation value {
    any value;
};
```

Applicable to: elements that can be given a constant value (e.g. enum literals).
zidl: kept as raw.

### @extensibility
Specifies how a constructed type is allowed to evolve.

```idl
@annotation extensibility {
    enum ExtensibilityKind { FINAL, APPENDABLE, MUTABLE };
    ExtensibilityKind value;
};
```

- `FINAL`: no evolution; no DHEADER in CDR.
- `APPENDABLE`: new members may be appended; DHEADER required in CDR (XCDR2).
- `MUTABLE`: type may evolve freely; EMHEADER per member in CDR (XCDR2).

zidl: pre-interpreted into `TypeAnnotations.extensibility`. Default: `FINAL`.

### @final
Shortcut for `@extensibility(FINAL)`.

```idl
@annotation final {};
```

### @appendable
Shortcut for `@extensibility(APPENDABLE)`.

```idl
@annotation appendable {};
```

### @mutable
Shortcut for `@extensibility(MUTABLE)`.

```idl
@annotation mutable {};
```

---

## §8.3.2 Group: Data Modeling

### @key
Marks a data member as part of the key for the enclosing type.
All objects with the same key values are considered to represent the same entity.

```idl
@annotation key {
    boolean value default TRUE;
};
```

The compact form `@key` is equivalent to `@key(TRUE)`.
zidl: pre-interpreted into `MemberAnnotations.is_key`.
CDR: key members are also serialized by `serializeKey()`.

### @must_understand
Marks a member that, if present, must be understood by the receiver.
(Does not imply the member cannot be optional.)

```idl
@annotation must_understand {
    boolean value default TRUE;
};
```

zidl: pre-interpreted into `MemberAnnotations.must_understand`.
Reflected in `MemberFlag` as `FLAG_IS_MUST_UNDERSTAND` in the TypeObject.

### @default_literal
Marks one enumerator as the default within an enumeration.

```idl
@annotation default_literal {};
```

Applicable to: enumerators within an enum declaration.
zidl: kept as raw.

---

## §8.3.3 Group: Units and Ranges

### @default
Specifies a default value for an annotated member.

```idl
@annotation default {
    any value;
};
```

The provided value must be compatible with the member's type.
zidl: kept as raw.

### @range
Specifies a range of allowed values (`min` ≤ value ≤ `max`).

```idl
@annotation range {
    any min;
    any max;
};
```

zidl: kept as raw.

### @min
Specifies a minimum allowed value.

```idl
@annotation min {
    any value;
};
```

zidl: kept as raw. Also used by the IR builder to set string/wstring bounds (non-standard dual use via `@max`).

### @max
Specifies a maximum allowed value.

```idl
@annotation max {
    any value;
};
```

zidl: pre-interpreted as a bound setter for `string`/`wstring` members:
`@max(N)` on a `string` member → `string<N>`. Kept as raw for all other types.

### @unit
Specifies the unit of measurement for an annotated element.

```idl
@annotation unit {
    string value;
};
```

Recommended to use BIPM standardized abbreviations (e.g. `"m"`, `"kg"`, `"s"`).
zidl: kept as raw.

---

## §8.3.4 Group: Data Implementation

### @bit_bound
Sets the size in bits for an enum or bitmask element.

```idl
@annotation bit_bound {
    unsigned short value;
};
```

Typically used to force smaller integer storage for enums.
zidl: pre-interpreted into `EnumAnnotations.bit_bound`. Used in TypeObject `bit_bound` field.

### @external
Places a member in external (non-contiguous) storage — useful for large or shared members.

```idl
@annotation external {
    boolean value default TRUE;
};
```

zidl: kept as raw.

### @nested
Indicates that objects of this type are always nested inside another object and
are never used as top-level DDS topic instances.

```idl
@annotation nested {
    boolean value default TRUE;
};
```

zidl: pre-interpreted into `TypeAnnotations.is_nested`.
Reflected in `TypeFlag` as `IS_NESTED` in the TypeObject.

---

## §8.3.5 Group: Code Generation

### @verbatim
Injects verbatim text into the generated output at a specified location.

```idl
@annotation verbatim {
    enum PlacementKind {
        BEGIN_FILE,
        BEFORE_DECLARATION,
        BEGIN_DECLARATION,
        END_DECLARATION,
        AFTER_DECLARATION,
        END_FILE
    };
    string language default "*";
    PlacementKind placement default BEFORE_DECLARATION;
    string text;
};
```

`language` values: `"c"`, `"c++"`, `"java"`, `"idl"`, `"*"` (any, default).
`placement` values:
- `BEGIN_FILE`: before any type declarations in the file.
- `BEFORE_DECLARATION`: immediately before the declaration (default).
- `BEGIN_DECLARATION`: inside the declaration body, before any members.
- `END_DECLARATION`: inside the declaration body, after all members.
- `AFTER_DECLARATION`: immediately after the declaration.
- `END_FILE`: at the end of the file, after all type declarations.

zidl: kept as raw. Backends may inspect `language` and `placement` params.

---

## §8.3.6 Group: Interfaces

### @service
Marks an interface as a service accessible via a specific platform.

```idl
@annotation service {
    string platform default "*";
};
```

`platform` values: `"CORBA"`, `"DDS"`, `"*"` (any, default).
zidl: kept as raw.

### @oneway
Marks an operation as one-way (fire-and-forget; no response).

```idl
@annotation oneway {
    boolean value default TRUE;
};
```

Only applicable to operations with `void` return type and no `out`/`inout` parameters.
zidl: kept as raw.

### @ami
Marks an interface or operation as asynchronously callable.

```idl
@annotation ami {
    boolean value default TRUE;
};
```

zidl: kept as raw.

---

## Non-Standard / XTypes Extension

### @hashid
Not in IDL 4.2 §8; comes from DDS-XTypes. Computes a member ID by hashing a specified name.

Algorithm: `MD5(UTF-8 bytes of name)[0..4] as LE u32, masked & 0x0FFFFFFF`.

If no name is given, the member's own name is used. This is the same algorithm used when `@autoid(HASH)` is in effect.

zidl: kept as raw (backends may inspect it; not yet auto-applied to member IDs).

---

## Summary Table

| Annotation | Group | IDL declaration | zidl handling |
|---|---|---|---|
| `@id` | General | `unsigned long value` | pre-interpreted → `MemberAnnotations.id` |
| `@autoid` | General | `AutoidKind value default HASH` | raw |
| `@optional` | General | `boolean value default TRUE` | pre-interpreted → `MemberAnnotations.is_optional` |
| `@position` | General | `unsigned short value` | raw |
| `@value` | General | `any value` | raw |
| `@extensibility` | General | `ExtensibilityKind value` | pre-interpreted → `TypeAnnotations.extensibility` |
| `@final` | General | (no params) | pre-interpreted → extensibility=final |
| `@appendable` | General | (no params) | pre-interpreted → extensibility=appendable |
| `@mutable` | General | (no params) | pre-interpreted → extensibility=mutable |
| `@key` | Data Modeling | `boolean value default TRUE` | pre-interpreted → `MemberAnnotations.is_key` |
| `@must_understand` | Data Modeling | `boolean value default TRUE` | pre-interpreted → `MemberAnnotations.must_understand` |
| `@default_literal` | Data Modeling | (no params) | raw |
| `@default` | Units/Ranges | `any value` | raw |
| `@range` | Units/Ranges | `any min; any max` | raw |
| `@min` | Units/Ranges | `any value` | raw |
| `@max` | Units/Ranges | `any value` | pre-interpreted for string bound; raw otherwise |
| `@unit` | Units/Ranges | `string value` | raw |
| `@bit_bound` | Data Impl | `unsigned short value` | pre-interpreted → `EnumAnnotations.bit_bound` |
| `@external` | Data Impl | `boolean value default TRUE` | raw |
| `@nested` | Data Impl | `boolean value default TRUE` | pre-interpreted → `TypeAnnotations.is_nested` |
| `@verbatim` | Code Gen | `language`, `placement`, `text` | raw |
| `@service` | Interfaces | `string platform default "*"` | raw |
| `@oneway` | Interfaces | `boolean value default TRUE` | raw |
| `@ami` | Interfaces | `boolean value default TRUE` | raw |
| `@hashid` | XTypes ext | (name string) | raw |
