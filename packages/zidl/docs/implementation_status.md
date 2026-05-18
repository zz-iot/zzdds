# Implementation Status and Design Notes

Per-file notes on design decisions, key invariants, and implementation details.

Current verification inventory:
- `zig build test`: 681 tests passed (672 library tests, 1 CLI test, 8 Zig integration tests) plus golden-output comparison.
- `zig build integration-test`: compile-and-run integration for generated C, C++, and Java code.
- `zig build interop-test`: 10 committed CDR interop vector tests.
- `packages/zidl-rt`: 61 Zig runtime tests.
- `packages/zidl-cdr`: 44 CDR cross-validation tests.

---

## Pipeline Overview

```
.idl source
  │
  ▼
src/preprocessor.zig   — #include / #define / #ifdef / #if / #pragma
  │
  ▼
src/lexer.zig          — tokenization (keywords, identifiers, literals)
  │
  ▼
src/parser.zig         — recursive descent; one fn per grammar rule (227 rules)
  │
  ▼
src/ast.zig            — tagged-union AST nodes; ArenaAllocator ownership
  │
  ▼
src/semantic/          — scope resolution, const eval, error reporting
  │
  ▼
src/ir/                — clean IR: resolved names, merged modules, typed annotations
  │
  ▼
src/backend/<lang>.zig — code generation
```

---

## src/preprocessor.zig

**Design:** A streaming character source with macro expansion and conditional
compilation. Implements the subset of C preprocessing specified in IDL4 §7.3.

**Key decisions:**
- Processes bytes, not tokens — the lexer runs on the expanded text.
- `#include` files are found via `-I` search paths, read recursively.
- `#pragma keylist`, `#pragma DCPS_DATA_TYPE`, `#pragma DCPS_DATA_KEY` are parsed
  and preserved as `PragmaNode` AST nodes; the IR builder converts them to
  `@key` annotations and `@nested` suppressions.
- `__DATE__` and `__TIME__` expand to UTC C-preprocessor-style strings. CLI runs honor
  `SOURCE_DATE_EPOCH` for reproducible output; tests inject a fixed timestamp.
- Non-fatal preprocessor warnings are reported through `Diagnostics`, not direct logging,
  so tests can assert expected warnings without confusing Zig's test runner.
- No macro hygiene — fully textual expansion like a C preprocessor.

**Tests:** 65.

---

## src/lexer.zig

**Design:** Hand-written single-pass lexer. Produces a `Token` stream with
`Span` (byte offset + length) for error messages.

**Key decisions:**
- All IDL4 keywords are reserved (e.g. `module`, `struct`, `sequence`, `bitset`,
  `bitmask`, `annotation`, `int8`, `uint16`, etc.).
- `@` is lexed as its own token (`ANNOTATION`), not part of the annotation name.
- Octal/hex/float literals all handled; wide character (`L'x'`) and wide string
  (`L"…"`) literals represented as separate token kinds.
- Span offsets are relative to the expanded (post-preprocessor) source, not the
  original file. Error messages include the pre-expansion source file name
  passed down via preprocessor line markers.

**Tests:** 41.

---

## src/ast.zig

**Design:** Tagged union per node kind. No visitor pattern — callers switch on
the tag directly.

**Key decisions:**
- `ArenaAllocator` memory model: all AST nodes live in one arena allocated at
  parse time. When the arena is freed (after IR build), the entire AST goes away.
- Annotation applications (`AppliedAnnotation`) carry a `params` slice. The
  parser does NOT evaluate annotation param expressions — that happens in the
  IR builder.
- Scoped name references are unresolved strings at the AST level; resolution
  happens in semantic analysis.

**No separate tests** — tested indirectly through parser tests.

---

## src/parser.zig

**Design:** Recursive descent with backtracking on ambiguous alternatives.
One function per grammar rule (`parseModuleDecl`, `parseStructType`, etc.).

**Key decisions:**
- Follows IDL4 Annex A grammar exactly (227 rules). `::+` alternatives are
  collapsed into the primary rule function.
- Parses all IDL4 constructs including value types, component declarations,
  home declarations, and template modules — even those the IR builder drops.
  This ensures parse correctness is tested against the full grammar.
- Annotation application (`@Foo`) is parsed at every `<element>` position
  permitted by §8.2. The parser does not validate annotation applicability.
- Parser error recovery: on unexpected token, parse error is returned immediately
  (no panic-mode recovery). Tests use small self-contained snippets.

**Tests:** 160.

---

## src/semantic/

Three files:

### src/semantic/scope.zig
Hierarchical symbol table. `Scope` structs form a chain. Names are resolved by
walking the chain outward. Qualified names (`Foo::Bar`) are resolved component
by component.

### src/semantic/const_eval.zig
Constant expression evaluator. Handles integer/float arithmetic, bitwise ops,
string concatenation, enum value resolution, and `sizeof`. Result type: `ConstValue`
(tagged union of integer | float | string | boolean | character | wide variants).

### src/semantic/analyzer.zig
Two-pass:
1. Forward pass: collect all type names and forward declarations into scope.
2. Full pass: resolve all type references, validate types, evaluate const exprs.

**Key decisions:**
- Forward declarations are tracked; only the full definition is emitted in the IR.
- Duplicate definitions are an error; re-opened modules are allowed (IDL4 §7.5.2).
- No type-checking of const assignments (e.g. `const long x = "hello"` is not
  caught — see Known Limitations below).

**Tests:** 29.

---

## src/ir/

### src/ir/types.zig
All IR data types. Key properties:
- `TypeRef`: fully resolved reference; no scoped names remain.
- `TypeDecl`: pointer into the arena to a named type node.
- `TypeAnnotations`, `MemberAnnotations`, `EnumAnnotations`: pre-interpreted
  OMG annotation fields. `raw: []const RawAnnotation` carries everything else.
- `Spec`: root; owns the arena. `spec.deinit()` frees everything.

### src/ir/builder.zig
Builds the IR from (AST, Analyzer) in two passes:
1. First pass: allocate all named type nodes, populate the type map.
2. Second pass: fill in all fields, resolving type references.

**Key decisions:**
- Module re-opening is merged: each module appears exactly once in the IR.
- Annotation interpretation: `interpretTypeAnnotations`, `interpretMemberAnnotations`,
  `interpretEnumAnnotations` are the three pre-interpretation functions.
  See `docs/idl4_annotations.md` for the full list of what is pre-interpreted vs raw.
- Advanced constructs (value_dcl, component_dcl, home_dcl, template modules) are
  parsed and dropped here with a warning diagnostic to stderr.
- `@topic` (not an OMG standard annotation, but a common DDS extension)
  is pre-interpreted into `TypeAnnotations.is_topic`.

**Tests:** 18.

---

## src/backend/interface.zig

Defines the vtable contract all backends implement. See `docs/backend_interface.md`.

- `Backend.Vtable`: `language_id`, `generate`, `deinit`.
- `Options`: all CLI flags passed through to every backend.
- `Profile`: `.full` (default) or `.xrce`.
- `validateXrce`: called before backends when `--profile xrce` is set.
- `cNameFromQualified`, `prefixedCNameFromQualified`: shared name utilities.

**Tests:** 9 (name utilities + XRCE validation).

---

## src/backend/c.zig

**Output:** One `.h` file (declarations) + one `.c` file (CDR serialize/deserialize).

**Key decisions:**
- C structs map IDL struct members 1-to-1. No struct inheritance; base members
  are manually inlined (base struct embedded as first field named `_base`).
- `typedef struct _Foo { … } Foo;` pattern for all structs.
- Enum: `typedef enum { … } Foo;` → CDR encodes as `uint32_t` always.
- Sequence: `typedef struct { T* data; uint32_t size; uint32_t maximum; } FooSeq;`
- CDR serialize functions: `int Foo_serialize(ZidlCdrWriter* w, const Foo* v)`.
- CDR deserialize functions: `int Foo_deserialize(ZidlCdrReader* r, Foo* v, …allocator…)`.
- Keyed structs emit `Foo_serialize_key`, `Foo_deserialize_key`, and
  `Foo_compute_key_hash`. Key hashes serialize keys as canonical PLAIN_CDR2
  big-endian, then apply the RTPS <=16-byte padding / MD5 rule via `zidl-cdr`.
- `@optional` not yet supported (requires invasive struct change — deferred).
- Include guards: `#ifndef PREFIX_FOO_H` / `#define PREFIX_FOO_H` / `#endif`.

**Tests:** 55.

---

## src/backend/cpp.zig

**Output:** One `.hpp` file (declarations + inline serialize/deserialize).

**Key decisions:**
- C++11 target (formal/25-03-03 IDL4-native mapping).
- Namespaces: IDL modules → C++ namespaces, nested correctly.
- Structs: plain `struct` with public member fields, default member initializers.
- Inheritance: `: public Base`.
- Sequences: `std::vector<T>`.
- Strings: `std::string` (unbounded) / `zidl::BoundedString<N>` (bounded).
- Enums: `enum class Foo : uint32_t { … }`.
- Optional members: `std::optional<T>`.
- Serialize/deserialize declared as free functions `zidl_serialize(w, v)` /
  `zidl_deserialize(r, v)` — overloaded per type.
- Keyed structs emit C ABI helpers `Foo_serialize_key`, `Foo_deserialize_key`,
  and `Foo_compute_key_hash` using the same canonical PLAIN_CDR2 big-endian key
  hash rule as C.
- `@verbatim` injection at `BEGIN_FILE`, `BEFORE_DECLARATION`, etc. if
  `language == "c++"` or `language == "*"`.

**Tests:** 72.

---

## src/backend/java.zig

**Output:** One `.java` file per top-level IDL module or one per type (split mode).

**Key decisions:**
- IDL4-to-Java mapping (formal/21-08-01 v1.0).
- Modules → Java packages (`--java-package` prepended).
- Structs → Java classes with public fields, default constructor, copy constructor.
- Enums → Java `enum` with a numeric `value` field, `fromValue(int)` factory.
- Sequences → `java.util.ArrayList<T>`.
- CDR serialize/deserialize: `public static void serialize(ZidlCdrWriter w, T v)`
  and `public static T deserialize(ZidlCdrReader r)`.
- Keyed structs emit `serializeKey`, `deserializeKey`, `deserializeKeyInto`, and
  `computeKeyHash`; MD5 uses `java.security.MessageDigest`.
- JNI bridge: when `--generate-interfaces`, emits a `*Impl.java` class with
  `System.loadLibrary(jni_library)`.
- Package annotation: `package com.example;` header per file.

**Tests:** 56.

---

## src/backend/zig.zig

Zig language mapping backend. See `docs/backend_zig.md` for comprehensive reference.
Keyed structs emit `serializeKey`, `deserializeKey`, `deserializeKeyInto`, and
`computeKeyHash`. `computeKeyHash` uses `zidl_rt.KeyHashWriter` for canonical
PLAIN_CDR2 big-endian key serialization and RTPS key-hash finalization.

**Tests:** 102.

### PL_CDR (`--pl-cdr`)

When `opts.pl_cdr && struct.extensibility == .mutable`, emits additional functions alongside
the normal XCDR2 serialize/deserialize:

```zig
fn serializePlCdr(writer: *zidl_rt.PlCdrWriter, value: @This()) !void
fn deserializeFromPlCdr(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void
```

- PID = `@id(N)` if present on the member, else sequential member index (same as EMHEADER)
- `@optional` members: serialize skips if null (no presence byte); deserialize assigns if PID seen
- `deserializeFromPlCdr` always calls `seekTo(_p.end_pos)` after each param (handles unknown PIDs)
- `@pl_repeated` on a `sequence<T>` member: serialize emits one PID entry per element (no count
  prefix); deserialize appends one element per occurrence of the PID
- `@pl_repeated` on a non-sequence member is a build-time error (`error.PlRepeatedOnNonSequence`
  from the IR builder)

**Tests:** 15 new (9 codegen + 6 zidl-rt round-trip).

---

## src/backend/zig_typeobject.zig

TypeObject/TypeIdentifier encoder. See `docs/xtypes_typeobject.md` for the
XTypes stream format. Key implementation notes:

- `Encoder` struct writes into a growing `std.ArrayList(u8)`.
- `writeEncapHeader()`: writes 4-byte encap header, resets `pos` to 0 so all
  subsequent alignment is relative to CDR payload start (not buffer start).
- `nameHash(name)`: MD5 of UTF-8 name bytes, returns `[4]u8`.
- `computeEquivalenceHash(bytes)`: MD5 of the full type object bytes (including
  encap header), returns `[14]u8`.
- `computeTypeIdentifier(bytes)`: SHA-256 of type object bytes, returns `[32]u8`.
- `encodeMinimalStruct`, `encodeMinimalEnum`, `encodeMinimalUnion`,
  `encodeMinimalBitmask`, and `encodeMinimalBitset` produce spec-compliant
  MinimalTypeObject streams verified against Cyclone DDS.
- `src/backend/zig_typeobject_proto.zig`: prototype/scratch file used during
  initial implementation; not part of production pipeline.
- **Housekeeping**: `zig_typeobject.zig` imports the `zidl-xtypes` package for
  all `TK_*`/`EK_*`/`IS_*` constants.

**Tests:** 29.

---

## src/main.zig

CLI entry point. Parses argv, drives preprocessor → parser → semantic → IR → backend.
Validates `--profile xrce` before invoking backends.

Key behavior:
- Multiple input files are processed as a single logical IDL spec (concatenated
  after independent preprocessing).
- `-E` flag: preprocess only, emit expanded IDL to stdout, exit.
- Backend selection: `-b c` / `-b cpp` / `-b java` / `-b zig`.
- `--split-files`: passed through to backend; semantics are backend-specific.
- `SOURCE_DATE_EPOCH`: when set, drives deterministic UTC `__DATE__` / `__TIME__`
  expansion in the preprocessor; invalid values are rejected before generation.

---

## src/root.zig

Library root for use as a Zig package. Exports: `parse`, `build`, `validate`,
`findBackendByLanguageId`.

---

## packages/zidl-rt/

Zig CDR runtime. `src/cdr.zig` — see `docs/runtime_libraries.md`.
`src/root.zig` — re-exports `CdrWriter`, `CdrReader`, `BoundedArray`, constants.
Includes `KeyHashWriter`, a canonical RTPS key-hash writer that emits PLAIN_CDR2
big-endian bytes, keeps the first 16 bytes, and streams the full key into MD5.

**Tests:** 61 (comprehensive CDR round-trip tests, including PL_CDR and key-hash tests).

---

## packages/zidl-cdr/

Standalone C99 CDR library. `include/zidl_cdr.h` + `src/zidl_cdr.c`.
See `docs/runtime_libraries.md` and `docs/xcdr_encoding.md` for API reference.
Includes `zidl_md5` and `zidl_cdr_compute_key_hash` for generated C/C++ key hashes.

Cross-validated byte-for-byte against `zidl-rt` (44 tests, including PL_CDR and key-hash cross-validation).

---

## packages/zidl-xtypes/

Zig package exporting all XTypes constants (`EK_*`, `TK_*`, `TI_*`, flag values).
See `docs/xtypes_typeobject.md`.

No tests — pure constant definitions.

---

## interop/

Cyclone DDS interoperability harness. Requires a Cyclone DDS checkout.
`make -C interop test` compiles zidl-generated C code alongside Cyclone DDS
and verifies byte-for-byte CDR stream equality.

**Tests:** 10.

---

## test/

Integration tests. Run with `zig build integration-test`.
Compile-and-run tests for generated C, C++, and Java backends. Zig generated-code
integration tests run as part of `zig build test`.

**Tests:** 8 Zig integration tests plus C/C++/Java executable integration suites.

---

## Known Limitations (current)

| Feature | Status |
|---|---|
| C backend: `map<K,V>` | Not supported (`error.MapTypeNotSupportedInCBackend`); no DDS vendor generates C maps; banned in XRCE |
| C backend: `@optional` | Deferred — requires invasive `has_NAME` bool field alongside each optional, breaking ABI |
| C backend: `@optional` key fields | Deferred with C `@optional`; generated key code emits a TODO comment for this case |
| C/C++ backends: PL_CDR codegen | `--pl-cdr` flag is parsed and wired but C/C++ backends do not yet emit PL_CDR functions |
| Zig 0.15.1 / MicroZig output | Partially implemented: `--zig-version 0.15.1` is wired and bounded strings/sequences use fixed-capacity `zidl_rt.BoundedArray`; full freestanding/no-heap runtime path remains planned |
| `--generate-interfaces` C++: complex-type adaptation | `ImplGenerator.emitImplOp` emits `/* TODO */` stubs — ABI boundary must be decided with DDS runtime |
| Const type-checking | Not implemented (e.g. `const long x = "hello"` is not caught) |
| Union discriminant type validation | Not implemented |
| TypeObject for typedef/alias | Deferred |
| `@mutable` EMHEADER serialization (XCDR2) | Not implemented in any backend (PL_CDR for Zig only, via `--pl-cdr`) |
| value_dcl / component_dcl / home_dcl / template modules | Parsed, silently dropped + warning diagnostic |
