# XCDR Encoding Reference

Extracted from OMG RTPS 2.3 (formal/22-04-01) and DDS-XTYPES v1.3 (formal/20-02-04).
Implementation: `packages/zidl-rt/src/cdr.zig`, `packages/zidl-cdr/src/zidl_cdr.c`.

Cross-validated byte-for-byte between the two implementations (41 tests).

---

## Encapsulation Header

Every serialized CDR message begins with a 4-byte encapsulation header.
The first two bytes encode the representation identifier (big-endian); the last two are options (usually 0x00 0x00).

| Identifier | Hex value | Bytes [0..3] |
|---|---|---|
| CDR1 LE | `0x0001` | `0x00 0x01 0x00 0x00` |
| CDR1 BE | `0x0000` | `0x00 0x00 0x00 0x00` |
| CDR2 LE | `0x0007` | `0x00 0x07 0x00 0x00` |
| CDR2 BE | `0x0006` | `0x00 0x06 0x00 0x00` |

Confirmed against Cyclone DDS 11.0.1:
- XCDR1 LE = `0x0001`
- XCDR2 LE = `0x0007`

**After writing the encap header, CDR position resets to 0.**
All alignment pads are computed from this reset position (the start of the CDR payload),
not from the start of the buffer.

---

## XCDR1 vs XCDR2 Alignment Rules

| Property | XCDR1 | XCDR2 |
|---|---|---|
| Max alignment | 8 bytes (natural) | 4 bytes (capped) |
| Reference spec | IDL §9.3.1 | XTypes §7.4.1 |
| DHEADER | No | Yes (for @appendable types) |
| EMHEADER | No | Yes (for @mutable types) |

Alignment pad formula: if `pos % boundary != 0`, insert `(boundary - pos % boundary)` zero bytes.
Padding bytes are always zero.

---

## Primitive Types

| IDL type | C type | CDR bytes | Alignment |
|---|---|---|---|
| `boolean` | `bool` | 1 (0=false, 1=true) | 1 |
| `octet` / `uint8` / `int8` / `byte` | `uint8_t` / `int8_t` | 1 | 1 |
| `char` | `char` | 1 | 1 |
| `wchar` | `uint16_t` | 2 (LE) | 2 |
| `short` / `int16` | `int16_t` | 2 (LE) | 2 |
| `unsigned short` / `uint16` | `uint16_t` | 2 (LE) | 2 |
| `long` / `int32` | `int32_t` | 4 (LE) | 4 |
| `unsigned long` / `uint32` | `uint32_t` | 4 (LE) | 4 |
| `float` | `float` | 4 (LE IEEE 754) | 4 |
| `long long` / `int64` | `int64_t` | 8 (LE) | 4 (XCDR2) / 8 (XCDR1) |
| `unsigned long long` / `uint64` | `uint64_t` | 8 (LE) | 4 (XCDR2) / 8 (XCDR1) |
| `double` | `double` | 8 (LE IEEE 754) | 4 (XCDR2) / 8 (XCDR1) |
| `long double` | `f128` | 16 (LE) | 4 (XCDR2) / 8 (XCDR1) |

Always emits little-endian. Reader handles both byte orders by detecting the encap header.

---

## String Encoding

### `string` (CDR string, char8)

```
[4]  length: u32 = byte_count + 1   (includes NUL terminator in the count)
[N]  UTF-8 bytes of the string
[1]  NUL terminator (0x00)
```

Alignment of the length field: 4-byte aligned.

`zidl_cdr_write_string(w, s, strlen(s))` — `len` = byte count, not including NUL.

### `wstring` (CDR wstring, char16)

```
[4]  count: u32 = wchar_count + 1   (includes NUL wchar in the count)
[2*count]  UTF-16 LE wchars
[2]  NUL wchar (0x0000)
```

Alignment: 4-byte aligned for the count; 2-byte aligned for each wchar.

---

## Sequence Encoding

```
[4]  element_count: u32   (4-byte aligned)
[…]  elements back-to-back (each element at its natural alignment from pos)
```

Bounded sequences (`sequence<T, N>`): the length still comes first; the CDR format is identical.
Bound enforcement is at the application level (serialization checks `count <= N`).

---

## Array Encoding

No length field. Elements written back-to-back, each at natural alignment.
For multi-dimensional arrays: row-major order (C-style, rightmost index varies fastest).

---

## Enum Encoding

Enums serialize as `uint32_t` (4 bytes, 4-byte aligned) regardless of declared bit_bound,
unless `@bit_bound(N)` annotation maps to a smaller integer.

Default: `uint32_t`.

---

## Struct Encoding

Members serialize in declaration order, each at natural alignment from the current CDR position.
If the struct has a base type (`struct Derived : Base`), base members serialize first, then derived members.

---

## XCDR2 DHEADER (for @appendable types)

A DHEADER is a `uint32_t` placed before the payload of each `@appendable` struct or union.
Its value = byte count of the payload (bytes after the DHEADER itself).

```
[4]  DHEADER: u32 = payload_byte_count   (4-byte aligned)
[…]  payload bytes
```

**Write pattern (when payload size is unknown at the time of writing):**
1. Call `zidl_cdr_reserve_dheader(w, &offset)` — writes placeholder `0x00000000`; records buffer offset.
2. Write the payload.
3. Call `zidl_cdr_patch_dheader(w, offset)` — fills in the actual byte count.

**Conditional DHEADER (for backends that support both XCDR1 and XCDR2):**

Use `zidl_cdr_reserve_dheader_maybe` / `zidl_cdr_patch_dheader_maybe`:
- On XCDR2: behaves as above.
- On XCDR1: no-op; stores sentinel `(size_t)-1` in `*out_offset`; patch is a no-op.

**Important:** The sentinel is `(size_t)-1` (all bits set), NOT `SIZE_MAX` from `<limits.h>`,
to avoid requiring `#include <limits.h>` in freestanding environments.

---

## XCDR2 EMHEADER (for @mutable types)

Each member of a `@mutable` struct is preceded by an EMHEADER that encodes the member ID,
a must-understand flag, and the length code (LC) that determines how to decode the payload length.

```
[4]  EMHEADER: u32 (4-byte aligned)
     bits [31]:   must_understand flag
     bits [30:28]: LC (length code, 0..7)
     bits [27:0]:  member_id (28 bits)
[4]  NEXTINT: u32   present only when LC >= 4; encodes payload byte count
[…]  payload
```

LC decoding:
- LC=0: payload = 1 byte
- LC=1: payload = 2 bytes
- LC=2: payload = 4 bytes
- LC=3: payload = 8 bytes
- LC=4: NEXTINT present; payload = NEXTINT bytes (for any-length members)
- LC=5: NEXTINT present; payload = 4 * NEXTINT bytes
- LC=6: NEXTINT present; payload = 8 * NEXTINT bytes
- LC=7: reserved

`@mutable` serialization is supported in the Zig backend (XCDR2).
The `ZidlEmHeader` struct in `zidl_cdr.h` and `zidl_cdr_read_emheader()` support decoding.

---

## @optional Encoding

An `@optional` member is prefixed by a presence flag (1 byte, bool):
- `0x01` (true): member value follows.
- `0x00` (false): no value; decoder assigns null/null-optional.

```
[1]  presence flag (bool)
[…]  member value (only if presence = true)
```

Supported in Zig, C++, Java backends. Not yet supported in C backend.

---

## zidl-rt (Zig) API Summary

`packages/zidl-rt/src/cdr.zig`:

```zig
// Writer
var buf = std.ArrayListUnmanaged(u8).empty;
var w = CdrWriter(.xcdr2).init(&buf, alloc);
try w.writeEncapHeader();   // writes encap header, resets pos
try w.writeBool(v);
try w.writeU8(v); try w.writeI8(v);
try w.writeU16(v); try w.writeI16(v);
try w.writeU32(v); try w.writeI32(v);
try w.writeU64(v); try w.writeI64(v);
try w.writeF32(v); try w.writeF64(v);
try w.writeString(s);       // u32 len + bytes + NUL
try w.writeWstring(ws);     // u32 count + wchars + NUL wchar
const off = try w.reserveDheader();
// ... write payload ...
w.patchDheader(off);
const bytes = buf.items;    // caller owns buf

// Reader
var r = CdrReader.init(data);  // parses encap header, checks byte order
try r.readBool(); try r.readU8(); try r.readI8();
try r.readU16(); try r.readI16();
try r.readU32(); try r.readI32();
try r.readU64(); try r.readI64();
try r.readF32(); try r.readF64();
try r.readString(alloc);    // allocates; caller must free
try r.readWstring(alloc);
try r.skipDheaderIfXcdr2(); // no-op on XCDR1
```

---

## zidl-cdr (C99) API Summary

`packages/zidl-cdr/include/zidl_cdr.h`:

```c
// Error codes
ZIDL_CDR_OK       = 0
ZIDL_CDR_OVERFLOW = -1   // buffer full or malloc failed
ZIDL_CDR_TRUNCATED = -2  // read past end of data
ZIDL_CDR_INVALID  = -3   // bad encap ID, invalid bool byte

// Version/byte-order constants
ZIDL_XCDR1, ZIDL_XCDR2
ZIDL_CDR_LE, ZIDL_CDR_BE
ZIDL_ENCAP_CDR1_LE = 0x0001, ZIDL_ENCAP_CDR1_BE = 0x0000
ZIDL_ENCAP_CDR2_LE = 0x0007, ZIDL_ENCAP_CDR2_BE = 0x0006

// Writer init
int  zidl_cdr_writer_init(ZidlCdrWriter *w, int xcdr_version);       // malloc-backed
void zidl_cdr_writer_init_fixed(ZidlCdrWriter *w, uint8_t *buf,
                                size_t cap, int xcdr_version);        // fixed buffer
void zidl_cdr_writer_deinit(ZidlCdrWriter *w);                       // free malloc buffer

// Encapsulation (must be first write call)
int zidl_cdr_write_encap(ZidlCdrWriter *w);

// Primitives — all return ZIDL_CDR_OK or error code
int zidl_cdr_write_bool(ZidlCdrWriter *w, bool v);
int zidl_cdr_write_u8(ZidlCdrWriter *w, uint8_t v);
int zidl_cdr_write_i8(ZidlCdrWriter *w, int8_t v);
int zidl_cdr_write_char(ZidlCdrWriter *w, char v);
int zidl_cdr_write_u16(ZidlCdrWriter *w, uint16_t v);
// ... i16, u32, i32, f32, u64, i64, f64

// Strings
int zidl_cdr_write_string(ZidlCdrWriter *w, const char *s, uint32_t len);
int zidl_cdr_write_wstring(ZidlCdrWriter *w, const uint16_t *s, uint32_t len);

// DHEADER framing
int  zidl_cdr_reserve_dheader(ZidlCdrWriter *w, size_t *out_offset);
void zidl_cdr_patch_dheader(ZidlCdrWriter *w, size_t dheader_offset);
int  zidl_cdr_reserve_dheader_maybe(ZidlCdrWriter *w, size_t *out_offset);
void zidl_cdr_patch_dheader_maybe(ZidlCdrWriter *w, size_t dheader_offset);

// EMHEADER framing
int  zidl_cdr_write_emheader(ZidlCdrWriter *w, uint32_t member_id,
                             bool must_understand, uint8_t lc);
int  zidl_cdr_reserve_emheader(ZidlCdrWriter *w, uint32_t member_id,
                               bool must_understand, size_t *out_nextint_off);
void zidl_cdr_patch_emheader(ZidlCdrWriter *w, size_t nextint_off);

// Reader init
int zidl_cdr_reader_init(ZidlCdrReader *r, const uint8_t *data, size_t data_len);

// Primitives — write result to *out; return error code
int zidl_cdr_read_bool(ZidlCdrReader *r, bool *out);
int zidl_cdr_read_u8(ZidlCdrReader *r, uint8_t *out);
// ... i8, char, u16, i16, u32, i32, f32, u64, i64, f64

// String reads
int zidl_cdr_read_string_zerocopy(ZidlCdrReader *r, const char **out, uint32_t *out_len);
int zidl_cdr_read_string(ZidlCdrReader *r, char **out);       // malloc; caller frees
int zidl_cdr_read_wstring(ZidlCdrReader *r, uint16_t **out, uint32_t *out_len);

// DHEADER / EMHEADER reads
int zidl_cdr_read_dheader(ZidlCdrReader *r, uint32_t *out);
int zidl_cdr_skip_dheader_if_xcdr2(ZidlCdrReader *r);
int zidl_cdr_read_emheader(ZidlCdrReader *r, ZidlEmHeader *out);

// Utility
size_t zidl_cdr_remaining(const ZidlCdrReader *r);
int    zidl_cdr_skip(ZidlCdrReader *r, size_t n);
```

---

## Key Implementation Notes

**Alignment is from CDR payload start, not buffer start.**
After writing the encap header, `pos` resets to 0. All subsequent `pos % boundary` pads are
relative to this zero point. This matches RTPS and Cyclone DDS behavior.

**Reader `pos` starts at 4 (past encap header), but alignment computes `(pos - 4) % boundary`.**
This gives the same logical CDR-payload offset without resetting the reader's absolute position.

**XCDR2 max alignment is 4**, not 8. This means `int64`, `uint64`, `double`, and `long double`
all align to 4 bytes under XCDR2, not their natural 8-byte boundary.

**Bool encoding:** exactly `0x00` (false) or `0x01` (true). Any other byte value is invalid (`ZIDL_CDR_INVALID`).

**String length field includes the NUL terminator** in its count. A zero-length string has length = 1 (the NUL byte only). A string of 5 characters has length = 6.
