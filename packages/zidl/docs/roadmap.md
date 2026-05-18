# Backend Roadmap and Development Plan

Current implementation status plus planned backend work, ordered by dependency
and real-world priority.

---

## Implemented Baseline: `deserializeKey` + `computeKeyHash`

**Status:** implemented for Zig, C, C++, and Java backends. Runtime support exists in
`zidl-rt` (`KeyHashWriter`) and `zidl-cdr` (`zidl_cdr_compute_key_hash`, `zidl_md5`).
Golden output and integration tests cover keyed sample deserialization and key-hash
computation.

**Why this mattered first:** zzdds instance-handle and ownership behavior needs key
hashes computed from received samples. The generated `serializeKey` alone is not enough
when middleware receives raw CDR bytes. The language-binding TypeSupport path also needs
a key-hash callback implementation in each generated language.

### Generated Functions

For every struct that has at least one `@key` member (i.e., `has_key = true`):

**`deserializeKey`** — reads only the `@key`-annotated members from a CDR stream,
leaving all other members at their default/zero value. The CDR stream must be positioned
at the start of a full serialized instance (not a key-only stream). Non-key fields are
skipped (scanned past, not deserialized into an allocation). Allocates only for key
members that are variable-length (strings, sequences).

**`computeKeyHash`** — takes an already-deserialized value (or a partially-filled value
from `deserializeKey`), serializes only the key fields as canonical PLAIN_CDR2 big-endian,
then applies the RTPS 2.5 §9.6.4.8 rule:
- serialized key ≤ 16 bytes → zero-pad to 16 bytes (no MD5)
- serialized key > 16 bytes → MD5 of the serialized key bytes

The hash is returned as `[16]u8` in Zig, written to a `uint8_t[16]` out parameter
in C/C++, and returned as `byte[16]` in Java.

### Backend-specific signatures

| Backend | `deserializeKey` | `computeKeyHash` |
|---------|-----------------|-----------------|
| Zig | `pub fn deserializeKey(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This()` | `pub fn computeKeyHash(value: @This()) [16]u8` |
| C | `int Foo_deserialize_key(ZidlCdrReader *r, Foo *v)` | `int Foo_compute_key_hash(const Foo *v, uint8_t hash[16])` |
| C++ | `int Foo_deserialize_key(ZidlCdrReader *r, Foo *v)` | `int Foo_compute_key_hash(const Foo *v, uint8_t hash[16])` |
| Java | `public static Foo deserializeKey(java.nio.ByteBuffer buf, int cdrBase)` | `public byte[] computeKeyHash()` |

The C and C++ header prototypes are emitted alongside `Foo_serialize_key` when
`has_key` is true. The implementations follow the same structure as `Foo_serialize_key`.

### MD5 dependency

`computeKeyHash` requires MD5 for keys whose serialized form exceeds 16 bytes.
- **Zig**: use `std.crypto.hash.Md5` from the standard library.
- **C/C++**: `zidl_cdr.h` gains `void zidl_md5(const uint8_t *data, size_t len, uint8_t out[16])`.
  Implementation in `zidl_cdr.c` via a small self-contained MD5 (no external dependency).
- **Java**: `java.security.MessageDigest.getInstance("MD5")`.
- **Runtime libraries (`zidl-rt`, `zidl-cdr`)**: provide key-hash helpers so generated code
  does not duplicate MD5 or the ≤16-byte padding rule.

### Future backends

All future backends (Python, C#, Rust, etc.) should include `deserializeKey` and
`computeKeyHash` from the start, parallel to the existing `@key` → `serializeKey`
generation pattern. The roadmap entries below are written with this in mind.

### Current Tests

Current coverage includes:
- Keyed struct: `deserializeKey` round-trips all key fields; non-key fields are zeroed.
- Key ≤ 16 bytes: `computeKeyHash` matches padded serialized key (no MD5).
- Key > 16 bytes: `computeKeyHash` matches MD5 of serialized key.
- Keyless struct: neither function is emitted.
- Struct with inherited key (base struct `@key` member): both functions include inherited keys.

Remaining useful additions:
- More mixed key-shape cases across all backends: bounded strings, sequences, arrays, inheritance.
- Explicit negative tests for unsupported/deferred cases, especially C `@optional` key fields.
- Cross-language fixture comparison of the exact 16-byte key hash for the same IDL sample.

### Connection to zzdds TypeSupport registration (Option A)

When zzdds gains C/C++/Java language bindings, the application will register a type with
the middleware via a TypeSupport call that includes function pointers:
- `serialize_fn(const void *sample, uint8_t *buf, size_t *len)`
- `deserialize_fn(const uint8_t *buf, size_t len, void *sample_out)`
- `key_hash_fn(const uint8_t *buf, size_t len, uint8_t hash[16])`

The generated `Foo_deserialize_key` and `Foo_compute_key_hash` are the building blocks
for `key_hash_fn`: a binding adapter can deserialize the key from the raw sample bytes,
then compute the RTPS key hash from the partially-filled value. This is Option A in the
zzdds language binding architecture; XTYPES dynamic interpretation (Option B) is the
future complement for remote type discovery, where no generated code is available.

---

## Embedded / MicroZig / XRCE Roadmap

**Status:** `--profile xrce` exists and validates important XRCE constraints before
backend generation: only `@final` types, bounded strings/sequences, no maps, no optional
members, no wstring, and no TypeObject/TypeIdentifier output. The Zig backend now accepts
`--zig-version 0.15.1` and emits bounded sequence/string code that uses fixed-capacity
`zidl_rt.BoundedArray` storage instead of heap-backed containers.

This is the first MicroZig-enabling slice, not a complete freestanding output mode yet.
zidl itself still builds with Zig 0.16.0; the 0.15.1 target is for generated Zig code and
`zidl-rt` consumers.

Remaining work:
1. Add a committed compile fixture that generates XRCE-profile Zig and checks it with the
   Zig 0.15.1 toolchain.
2. Split generated Zig runtime assumptions into a full runtime path and a constrained
   XRCE-client path.
3. Define the no-heap writer/reader surface expected by MicroZig clients; current generated
   bounded-field storage is heap-free, but CDR buffers still use the normal runtime model.
4. Audit generated code and `zidl-rt` APIs for freestanding compatibility.
5. Add XRCE-client-focused fixtures that exercise bounded-only IDL on embedded-friendly
   generated output.
6. Keep DDS-XRCE agent/broker work separate from zidl unless codegen needs explicit hooks.
   zidl should generate client-side type support; the agent can live in zzdds or a separate
   repository that consumes zidl output.

---

## Python backend (`-b python`)

Target: Python 3.10+. No OMG spec; pragmatic conventions. Inline CDR (no companion
runtime package), following Java's model.

**Type mapping**:
- `struct` → `@dataclass(slots=True)` with typed fields
- `enum` → `enum.IntEnum`
- `union` → class with `_d: DiscType` property + `T | None` case properties; `match` dispatch in deserialize
- `sequence<T>` / `T[N]` → `list[T]` (array length checked at serialize time)
- `map<K,V>` → `dict[K, V]`
- `string` / `wstring` → `str`
- `@optional` → `T | None` (default `None`)
- Module → Python module namespace (flat file; `--split-files` emits per-type `.py` files)
- `@key` → `serialize_key()`, `deserialize_key()`, and `compute_key_hash()` methods
- No TypeObject generation (deferred — TypeObject is Zig-specific for now)

**CDR**: inline `struct.pack`/`struct.unpack` with an alignment-tracking writer/reader
class generated at the top of each output file. XCDR2 LE baseline; `@appendable` emits
DHEADER; `@mutable` emits EMHEADER per member.

**Implementation steps**:
1. `src/backend/python.zig` — declarations: struct/enum/union/typedef/const; `--no-typesupport` path
2. Python CDR: `@final` struct + union serialize/deserialize; inline writer/reader helper
3. Python CDR: `@appendable` (DHEADER), `@mutable` (EMHEADER), sequences, arrays, maps
4. Python CDR: `@key`, `deserialize_key`, `compute_key_hash`, `@optional`, wstring, fixed-pt
5. Python: `--split-files`, `--python-package <pkg>` option, tests, golden snapshot
6. Python integration test (roundtrip via subprocess or embedded interpreter)

---

## C# / .NET backend (`-b csharp`)

Target: `netstandard2.1` (covers Unity/Mono, .NET Core 3+, .NET 5–10+). C# 10+ syntax
(file-scoped namespaces). Spec: [IDL4 to C# v1.0 Beta (ptc/20-03-02)](https://www.omg.org/spec/IDL4-CSHARP/1.0/). Inline CDR
using `System.Buffers.BinaryPrimitives` + `Span<byte>`. No companion runtime package.

**Type mapping** (per formal/ptc-20-03-02):
- `struct` → `public sealed partial class` with auto-properties and a default constructor
- `enum` → C# `enum : int` (or underlying type per `@bit_bound`)
- `union` → `public sealed partial class` with discriminant property + typed case accessors
- `sequence<T>` → `List<T>`
- `T[N]` / `T[N1][N2]` → `T[]` / `T[][]`
- `map<K,V>` → `Dictionary<TKey, TValue>`
- `string` / `wstring` → `string`
- `@optional` → nullable value (`T?`)
- Module → `namespace` (nested modules → nested namespaces)
- `@key` → `SerializeKey`, `DeserializeKey`, and `ComputeKeyHash` methods
- No TypeObject generation (deferred)

**CDR**: inline `BinaryPrimitives`-based `CdrWriter`/`CdrReader` helper struct generated
at the top of each output file. `Span<byte>` for zero-copy primitives. XCDR2 LE baseline;
`@appendable` / `@mutable` follow same DHEADER/EMHEADER rules as Java.

**Implementation steps**:
1. `src/backend/dotnet.zig` — declarations: struct/enum/union/typedef/const; `--no-typesupport` path
2. C# CDR: `@final` struct + union serialize/deserialize; inline CdrWriter/CdrReader helpers
3. C# CDR: `@appendable` (DHEADER), `@mutable` (EMHEADER), sequences, arrays, maps
4. C# CDR: `@key`, `DeserializeKey`, `ComputeKeyHash`, `@optional`, wstring, fixed-pt
5. C# CDR: `--split-files`, `--dotnet-namespace <ns>` option, tests, golden snapshot
6. C# integration test (compile + roundtrip via `dotnet run`)

---

## Rust backend (`-b rust`)

Two generation modes selected via `--rust-runtime`:

- **`pure` (default)**: idiomatic Rust; `Vec<T>`, `String`, `HashMap`; CDR via `zidl-rs`
  companion crate (`no_std + alloc`). Target audience: desktop/server Rust projects that want
  a pure-Rust dep graph with no Zig runtime dependency.
- **`zig-ffi`**: zero-copy FFI into the Zig DDS runtime; sequences/strings as `ZidlSlice<T>`/
  `ZidlString` (`#[repr(C)]`, `no_std + alloc`); lifetime-annotated borrows for zero-copy
  deserialization; `--rust-types-crate <crate>` redirects the import source (default:
  `zidl_types`). A DDS implementation that wants to bundle the types re-exports from
  `zidl-types-rs` rather than reimplementing, preserving Rust type identity across the dep
  graph. Target audience: embedded and high-performance DDS consumers.

No OMG spec for Rust. No TypeObject generation (deferred — TypeObject is Zig-specific for now).

**Type mapping**:
- `struct` → Rust `struct` with named fields
- `enum` → Rust `enum` with unit variants; discriminant value via `#[repr(i32)]` etc.
- `union` → Rust `enum` with associated data (exhaustiveness checking); discriminant serialized separately
- `sequence<T>` → `Vec<T>` (pure) / `ZidlSlice<T>` (zig-ffi)
- `T[N]` → `[T; N]` — native fixed-size arrays, stack-allocated, no package needed
- `map<K,V>` → `HashMap<K, V>`
- `string` / `wstring` → `String` (pure) / `ZidlString` (zig-ffi)
- `@optional` → `Option<T>`
- `typedef` → `type` alias or newtype `struct Foo(Inner)`
- Module → `mod`
- `@key` → `serialize_key()`, `deserialize_key()`, and `compute_key_hash()` methods
- Structs annotated `#[repr(C)]` in zig-ffi mode where layout permits

**Implementation steps**:
1. `packages/zidl-types-rs/` — `ZidlSlice<T>`, `ZidlString` as `#[repr(C)]`; `no_std + alloc`
2. `src/backend/rust.zig` — declarations: struct/enum/union/typedef/const; `--no-typesupport` path; both runtime modes; `--rust-types-crate` flag wiring
3. `packages/zidl-rs/` — pure Rust CDR runtime: `CdrWriter`/`CdrReader`, XCDR1/XCDR2, alignment tracking, DHEADER/EMHEADER patching, `no_std + alloc`
4. Rust CDR (pure): `@final` struct + union serialize/deserialize
5. Rust CDR (pure): `@appendable` (DHEADER), `@mutable` (EMHEADER), sequences, arrays, maps
6. Rust CDR (pure): `@key`, `deserialize_key`, `compute_key_hash`, `@optional`, wstring, fixed-pt
7. Rust CDR (zig-ffi): zero-copy path — `ZidlSlice<T>`/`ZidlString` types, FFI serialization bindings, lifetime-annotated borrows for deserialized data
8. Rust: `--split-files`, `--rust-types-crate` wiring, tests, golden snapshot
9. Rust integration test (compile + roundtrip via `cargo test`)

---

## Haskell backend (`-b haskell`) — future consideration, not scheduled

Haskell ADTs are arguably the best semantic fit for IDL types of any language. Captured here
for future reference; no steps assigned.

**Type mapping** (strong fit):
- `struct` → record syntax `data MyStruct = MyStruct { field :: Int32, ... }`
- `union` → sum type with associated data; exhaustiveness checking at compile time
- `enum` → nullary constructors (labels converted `ALL_CAPS` → `UpperCamelCase`)
- `@optional` → `Maybe T` — perfect semantic fit
- `sequence<T>` → `[T]` or `Data.Vector.Vector T`
- `map<K,V>` → `Data.Map.Map K V`
- `string` / `wstring` → `Data.Text.Text` (Unicode-native)
- `typedef` → `type` alias (transparent) or `newtype` (type-safe)
- Module → Haskell module system

**Pain points**:
- CDR alignment tracking requires a custom writer monad (`newtype CdrPut a = CdrPut (StateT
  Int PutM a)`) — `binary`/`cereal` do not expose current byte position.
- DHEADER/EMHEADER size patching for `@appendable`/`@mutable` is awkward in pure functional
  style; requires two-pass, `MonadFix`, or a `ByteString` builder with known sizes.
- `T[N]` fixed-size arrays have no native representation; need `vector-sized`/DataKinds or
  runtime length checks with a plain list.
- `fixed<D,S>` has no standard Haskell type (`Data.Fixed` exists but uses type-level resolution).
- Two CDR strategy options: fully inline (large generated files, no external dep) vs. typeclass
  instances with a `zidl-hs` companion package on Hackage. The typeclass approach is more
  idiomatic but adds a distribution dependency.
