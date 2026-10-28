# Resource provider bindings

Slice 3 connects resolved resource plans to the existing typesupport library
manager. Enable `-Dresource-construction=true -Dtypesupport-library=true` for
`zzdds.resources.providers`. Resource TOML additionally needs
`-Dresource-authoring=true`, which enables resource construction automatically.
The ordinary builder and compiled registrations still work without library loading.
This work uses current zzdds main; it requires no new downstream release or zidl pin.

## Explicit local bindings

Keep provider locations and selections outside portable resource definitions. A
library may export many types. A binding selects one exact export for one named
participant and registered type name. There is no automatic choice among equivalent
exports and no registered-name aliasing. Two participants may select different
providers for the same name; one participant cannot select two, even when their
Minimal TypeIdentifiers agree.

```zig
const P = zzdds.resources.providers;
const requested = [_]P.Binding{.{
    .participant = "main",
    .type_name = "Telemetry::Reading",
    .source = .{ .provider = .{
        .provider = "project_a",
        .name = "Telemetry::Reading",
    } },
}};
try P.validate(&plan, &requested, .{}); // No library access or DDS calls.
var prepared = try P.Prepared.init(allocator, &plan, &manager, &requested, .{});
defer prepared.deinit();
var instance = try prepared.instantiate(allocator, factory);
defer instance.deinit() catch @panic("cleanup failed");
try prepared.build(&instance);
```

`manager` is an existing `zzdds.typesupport.Manager`. Preparation copies the plan,
acquires each provider alias once, pins the chosen generations and checks exports
and capabilities. Multiple types from one alias cannot accidentally select different
generations during concurrent replacement. Preparation creates no DDS entities.
Binding errors leave the manager and input plan unchanged and release partial pins.

The prepared object must remain at the same address and outlive every instance
borrowing its plan. Do not copy an active owner. All instance operations retain the
builder's owner-serialization contract. Removing/replacing a provider, or destroying
the manager, does not change an existing preparation. Future preparations see the
new generation. Existing participants retain their own registrations independently.
There is no automatic graph reload or callback swap.

Each binding can require an exact `expected_identifier` (15 bytes: EK_MINIMAL plus
its 14-byte hash), additional `required_representations`, and wire validation. The
current resource endpoint model uses XCDR1, so every selected source must support it.
Different Minimal identifiers fail exact-identity checks; no assignability or
CompleteTypeObject equivalence is inferred. Type identity also does not establish
native ABI compatibility; the existing loader checks its separate descriptor ABI.

`prepared.info(index)` reports the participant/name, selected alias/generation,
Minimal identifier, keyed/keyless status, wire capabilities, artifact path and SHA-256 when file-backed.
It borrows strings from the preparation. `prepared.bindings.len` gives the count.
`prepared.write(&instance, participant, writer, kind, bytes)` performs checked wire
validation and key hashing with the captured provider before writing. Direct raw
writes do not provide that guarantee. The existing loader registration checks
incoming complete samples before reader history admission.

## Compiled registrations and explicit startup inputs

A `.compiled` source wraps an ordinary `resources.StaticBinding` plus declared
identity/capabilities. Its context remains borrowed; the callback must install
support whose lifetime covers its participant, as with the original builder.
Identity defaults to unknown and validation defaults to false: a compiled adapter
cannot satisfy a requirement it has not declared. It keeps using its generated typed
writer operations; `prepared.write` is for provider-backed bindings.

`StaticBinding.participant` now optionally restricts an ordinary builder binding to
one participant. Null retains the existing global binding behavior. Global/scoped
bindings that overlap are rejected before DDS calls.

For explicit multi-provider startup, `Environment.init(allocator, inputs, options)`
accepts a list of `ProviderInput` records. Each has an alias and either a `.library`
file or a `.linked` immutable library descriptor. Optional expected SHA-256 values
are checked before any library is loaded. All paths are resolved and all files hashed
before loading starts; failures clean up the new environment rather than modifying
an existing manager. Relative files need an explicit absolute `base_directory`.
There is no ambient scan, library search or network fetching. Linked descriptors
and their callbacks must remain valid while any selection or participant uses them,
as required by the existing loader contract.

Use `environment.manager` for preparation. `environment.artifacts` records the
initial startup inputs, hashes and generation IDs; it is not a live view of later
manager replacement. Preparation independently captures its selected generations
and file hashes. Bounds default to 32 startup providers, 64 live generations, 64 MiB per
artifact and 1,024 bindings. The separate generation budget leaves replacement
headroom and counts both active providers and retired generations still pinned by
preparations/participants. Plain compiled adapters need no exported query function. Multiple
statically linked generated modules still need distinct exported symbols; the
current generator's common query symbol is intended for separately loaded libraries.

Loading executes trusted native code. Artifact paths/content must remain immutable
while in use; use a distinct artifact path for replacement, as the loader requires.
A recorded hash supplies provenance, not authentication or protection against a file
being modified between hashing and OS loading. Descriptor/ABI validation and all
existing generation retirement limits remain in force. Static-only builds reject
library inputs before file access and still support linked descriptors/adapters.

## Command-line example

Build the tool and independently generated example libraries:

```sh
zig build resource-inspect resource-provider-fixtures \
  -Dresource-authoring=true -Dtypesupport-library=true
```

On Linux, inspect selected types from two libraries:

```sh
zig-out/bin/resource-inspect inspect examples/zig/resource-inspect/reading.toml \
  --library project_a=zig-out/lib/libprovider_a.so \
  --library project_b=zig-out/lib/libprovider_b.so \
  --bind 'main/LibraryTest::Reading=project_b/LibraryTest::Reading' \
  --bind 'main/LibraryTest::Pulse=project_a/LibraryTest::Pulse'
```

macOS uses `.dylib` and Windows uses `.dll` artifacts in their normal Zig install
locations. CLI library paths are relative to the working directory. Names in this
small CLI use `/` to separate participant/type and alias/export. The programmatic
API does not impose that delimiter convention.

`validate` checks resource syntax, resolution and explicit binding names without
accessing provider files; nonexistent library paths are valid in that offline mode.
`plan` additionally prints resolved domains, topic references and effective endpoint
QoS. Both explicitly report that export identity/capabilities remain unchecked.
`inspect` loads the requested libraries and performs preparation, reporting host
architecture/OS, ABI, generation, hashes and type identities. It creates no DDS graph.
Output follows the existing inspection examples on stderr.

Add `--expect 'main/Type=<30 hex digits>'` for an exact Minimal identifier and
`--sha256 'alias=<64 hex digits>'` for expected artifact content. Copy the continuous
hex values from inspection. Duplicate constraints and constraints for unknown names
are errors. Ordinary unknown resource settings remain strict, with the established
`_setting` conditional convention available independently.

## Verification

```sh
zig build test-resource-providers test-resource-inspect \
  -Dresource-authoring=true -Dtypesupport-library=true
zig build test-resource-providers -Dresource-construction=true \
  -Dtypesupport-library=true -Dtypesupport-dynamic=false
```

Tests cover independent generated providers, equivalent/conflicting exports, explicit
scopes, missing/duplicate bindings, exact identity, honest compiled capabilities,
generation pinning/removal, allocation failure cleanup, hashes and real keyed/keyless
sample exchange between independent graphs. CLI checks prove offline validation does
not open providers, enforce the loader's provider limit, and reject a mismatched
artifact hash during preparation. Tests also destroy the provider manager before
constructing DDS entities and exchanging samples, proving preparation owns the
references it needs.

The provider CI matrix covers native Linux/macOS/Windows in Debug and ReleaseSafe,
including static-only builds. Linux TSan instruments host preparation, loading,
registration and DDS code. Its generated shared-library fixtures are uninstrumented:
Zig currently bundles another sanitizer runtime into instrumented DSOs, and dlopen
cannot allocate that runtime's initial-exec TLS. Their immutable synchronous wire
callbacks are also exercised in ordinary Debug/ReleaseSafe tests.

`emit-provider-tests -Dresource-construction=true -Dtypesupport-library=true
-Dcpu=baseline` emits the LLVM test binary for coverage and Valgrind. CI runs it in
addition to the ordinary LLVM suite. Hosted CI results must be checked separately;
local Linux evidence does not qualify other platforms.

## Local checkpoint (2026-10-28)

Implemented on `resource-provider-bindings` from main `23dd295` (#111), retaining the
zidl v0.3.23 dependency. The full resource/provider-enabled suite passed 1,453 tests
with two configuration-specific skips. Provider checks pass in Debug, ReleaseSafe,
static-only ReleaseSafe and host TSan; each configuration executes ten of eleven
cases, with the complementary dynamic/static-only case intentionally skipped.
The emitted baseline-CPU LLVM binary passes Valgrind. Local kcov measures 99.4% line
coverage of `providers.zig`. These are local Linux results, not hosted CI or a release
claim. The next zzdds release can wait for the concurrency work without blocking this
branch or further integration using a pinned commit/local checkout.
