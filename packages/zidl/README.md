# zidl — IDL4 Parser and Code Generator

A fully-featured, spec-compliant OMG IDL 4.2 parser and code generator written in Zig.
zidl generates language bindings and type support (CDR serialization, TypeObject/TypeIdentifier)
for all supported targets.

## Goals

- Parse IDL 4.2 per OMG formal/18-01-05
- Generate correct output for (in priority order):
  - Zig — type definitions + CDR serialization + TypeObject/TypeIdentifier (primary target)
  - C — type definitions + serialization (embedded FFI and standalone use)
  - C++11 — type definitions + serialization (formal/25-03-03 v1.0, IDL4-native)
  - Java — type definitions + serialization (formal/21-08-01 v1.0, desktop/server only)
  - Python 3.10+ — type definitions + inline CDR serialization (no companion runtime package)
  - C# / .NET — type definitions + inline CDR serialization targeting `netstandard2.1`
  - Rust — type definitions + CDR serialization via `zidl-rs` (pure mode) or zero-copy FFI into
    a poential Zig DDS runtime (zig-ffi mode); `no_std + alloc` compatible
- Generate DCPS abstract API from IDL for bootstrapping a Zig DDS runtime (`--generate-interfaces`)
- Extensible backend interface so new mappings can be added cleanly
- Hand-written recursive descent parser (no parser generator, no combinator library)
- Ship companion runtime packages (`zidl-rt`, `zidl-xtypes`, `zidl-cdr`, `zidl-rs`, `zidl-types-rs`)

## Build

Requires Zig 0.16.0.

```sh
zig build                   # build the zidl binary (output: zig-out/bin/zidl)
zig build -Doptimize=ReleaseFast  # optimised release build
```

## Testing

Run the full test suite (unit tests, Zig integration tests, and golden file check):

```sh
zig build test
```

Run the C, C++, and Java integration tests (uses Zig's bundled clang; no external compiler needed):

```sh
zig build integration-test
```

Run CDR interop tests against hardcoded expected byte vectors (no Cyclone DDS installation required):

```sh
zig build interop-test
```

Run the CDR runtime package tests independently:

```sh
cd packages/zidl-rt && zig build test  # Zig CDR runtime
cd packages/zidl-cdr && zig build test # C CDR library
```

### Golden files

Golden files are committed snapshots of zidl's output for each backend, stored under
`test/golden/<lang>/` (single-file mode) and `test/golden/<lang>-split/` (split-file mode).
`zig build test` automatically checks that the current binary produces output that is
byte-for-byte identical to those snapshots, catching regressions across all backends.

Regenerate the golden files after an intentional change to generated output (e.g. a bug fix,
a new annotation, or a formatting change):

```sh
zig build regen-goldens
```

Review the diff (`git diff test/golden/`) to confirm only the expected files changed, then
commit the updated goldens alongside the code change that caused them.

## CLI Reference

| Option | Purpose |
|---|---|
| `<file> [<file>...]` | Input IDL file(s) |
| `-o <dir>` | Output directory |
| `-b <backend>` | Target language (`c`, `cpp`, `java`, `zig`) |
| `-I <dir>` | Preprocessor include path (repeatable) |
| `-D <MACRO>[=value]` | Define preprocessor macro (repeatable) |
| `-E` | Preprocess only; emit expanded IDL |
| `--default-extensibility <final\|appendable\|mutable>` | Default extensibility (spec default: `final`) |
| `--no-typesupport` | Suppress CDR serialization output |
| `--no-typeobject-support` | Suppress TypeObject/TypeIdentifier output |
| `--generate-interfaces` | Emit DDS API binding layer for IDL `interface` declarations |
| `--split-files` | One file per type instead of single output file |
| `--pragma-once` | C/C++: `#pragma once` instead of `#ifndef` guards |
| `--extern-c` | C: wrap header in `extern "C" {}` for C++ inclusion |
| `--cpp-namespace <ns>` | C++: wrap all output in an outer namespace |
| `--profile <full\|xrce>` | `full` (default) or `xrce` (XCDR1+@final+bounded only) |
| `--java-package <pkg>` | Java package prefix |
| `--header-guard-prefix <pfx>` | C/C++ include guard prefix |
| `--export-macro <macro>` | DLL export macro for topic descriptors |
| `--jni-library <name>` | `System.loadLibrary()` name for Java JNI bridge |
| `--pl-cdr` | Generate `serializePlCdr`/`deserializeFromPlCdr` for `@mutable` types (RTPS PL_CDR wire format) |
| `--zig-version <0.16.0\|0.15.1>` | Zig backend output compatibility target (`0.16.0` default; `0.15.1` for MicroZig consumers) |
| `--version` / `--help` | Standard |

## Specification References

### Primary
- [OMG IDL 4.2 (formal/18-01-05)](https://www.omg.org/spec/IDL/4.2/) — primary reference
  - Grammar: Annex A (pages 123–132); lexical rules: §7.2
  - Preprocessing: §7.3; annotation placement: §8.2; default extensibility: §8.3.1
  - `::+` in the grammar denotes rule extension (adds alternatives, not a new rule)
  - Building blocks: Core Data Types, Extended Data-Types, Anonymous Types, Annotations,
    Interfaces–Basic/Full, Value Types, Components, Template Modules, CCM, CORBA-Specific

### Language Mappings — IDL4-Native
- [IDL4 to C++ v1.0 (formal/25-03-03)](https://www.omg.org/spec/IDL4-CPP/1.0/) (March 2025)
- [IDL4 to Java v1.0 (formal/21-08-01)](https://www.omg.org/spec/IDL4-JAVA/1.0/) (April 2022)
- [IDL4 to C# v1.0 Beta (ptc/20-03-02)](https://www.omg.org/spec/IDL4-CSHARP/1.0/)

### Language Mappings — Legacy/CORBA-Era
- [C Language Mapping (formal/99-07-35)](https://www.omg.org/spec/C/1.0/) (June 1999)
- [IDL to C++11 v1.7 (formal/24-07-01)](https://www.omg.org/spec/CPP11/1.7/)
- [IDL to Java v1.3 (formal/08-01-11)](https://www.omg.org/spec/I2JAV/1.3/)

### DDS Specs
- [DDS v1.4: DCPS API (formal/15-04-10)](https://www.omg.org/spec/DDS/1.4/) — primary reference for `--generate-interfaces`
- [DDS-XTYPES v1.3 (formal/20-02-04)](https://www.omg.org/spec/DDS-XTypes/1.3/) — TypeObject/TypeIdentifier/TypeMapping
- [RTPS 2.5](https://www.omg.org/spec/DDSI-RTPS/2.5/) — CDR encoding, key hash, participant discovery
- [DDS-XRCE v1.0 (formal/20-02-01)](https://www.omg.org/spec/DDS-XRCE/1.0/) — primary reference for `--profile xrce`
- [DDS-RPC v1.0 (formal/17-04-01)](https://www.omg.org/spec/DDS-RPC/1.0/) (deferred; architecture must not preclude it)
- [DDS Security v1.2 (formal/25-03-06)](https://www.omg.org/spec/DDS-SECURITY/1.2/) (2025)

## Documentation

- `docs/implementation_status.md` — per-file design notes, test counts, PL_CDR details, known limitations
- `docs/backend_interface.md` — adding a new backend; annotation handling; DDS type support
- `docs/backend_zig.md` — Zig backend type mapping, generated file structure, serialization API
- `docs/runtime_libraries.md` — zidl-rt, zidl-cdr, zidl-xtypes API reference, CDR runtime strategy
- `docs/dds_architecture.md` — full DDS vs XRCE scope; interoperability testing strategy; future RTPS/RPC
- `docs/roadmap.md` — current completed priorities, embedded/XRCE plan, and planned backends
- `docs/idl4_grammar.md` — Annex A grammar, all 227 rules
- `docs/xcdr_encoding.md` — XCDR1/XCDR2 encoding rules, DHEADER/EMHEADER, alignment
- `docs/xtypes_typeobject.md` — TypeIdentifier/TypeObject discriminants, EquivalenceHash algorithm
- `docs/idl4_annotations.md` — All 24 built-in annotations; pre-interpreted vs raw handling
- `docs/dcps_idl.md` — Complete normative DCPS IDL (DDS v1.4 §2.3.3)
