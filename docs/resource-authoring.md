# Experimental resource authoring

Slice 2 extends the shared resource path with a bounded TOML frontend, generated
presence-aware records and single-base QoS profile resolution. It creates the same
concrete `resources.Plan` consumed by the programmatic builder. It does not load
sample types: those still come from application IDL and explicit static bindings.

The [migration assessment](config-migration-assessment.md) and
[migration plan](config-migration-plan.md) preserve ordinary process, factory and
participant configuration contracts. The shared decoder supports conditional
`_field` settings and independent updates from an existing value. Resource authoring
remains an optional frontend, separate from ordinary runtime configuration APIs.

## Released dependency

The manifest pins zidl **v0.3.23-zig.0.17.0**, which supplies the generated metadata
and shared decoder. No local checkout or source override is required:

```sh
zig build test-resource-authoring -Dresource-authoring=true
```

`resource-authoring` defaults off and implies `resource-construction` unless that
option is explicitly disabled (an error). Ordinary runtime configuration uses the
shared decoder by default, independently of the resource builder. An explicit
`-Dconfig-authoring=false` selects the legacy runtime reader for comparison.

For coordinated development, `-Dzidl-source=/absolute/path/to/zidl` still replaces
generator, runtime and package sources together with one runtime module. It does not
change the dependency manifest. Native PR CI tests the pinned release on Linux,
macOS and Windows in Debug and ReleaseSafe, with Linux ThreadSanitizer checks.
Configured CI is separate from evidence of completed remote runs.

## Pipeline and ownership

```text
TOML bytes -> generic located tree -> IDL-generated strict records
          -> DDS references/profiles/defaults -> owned concrete Plan
          + static sample-type bindings -> Instance
```

`zzdds.toml` is the existing parser, extended once. It knows syntax and locations,
not DDS fields. zidl's new opt-in `--zig-generate-authoring` flag emits
`toml_fields`, `tomlSpec` and `decodeToml`; the latter uses `zidl_rt.authoring`.
The existing `--zig-generate-toml-config`/`applyToml` remains a separate mutating API with its prior default/ownership
contract. Existing configuration decoding is not silently made strict.

The [authoring IDL](../idl/resources/resource_authoring.idl) describes configuration
records; it is distinct from the application's sample IDL. These records are generated
without CDR/TypeObject scaffolding because this authored representation is not a wire
plan protocol. DDS field/reference resolution is implemented in the shared resource
layer, not in a handwritten TOML field decoder or inside zidl.

```zig
const A = zzdds.resources.authoring;
var diagnostic: A.Diagnostic = .{};
var authored = try A.parse(allocator, "writer.toml", bytes, &diagnostic);
defer authored.deinit();
var resolved = try authored.resolve(allocator, .{}, &diagnostic);
defer resolved.deinit();
// resolved.plan is an ordinary resources.Plan. It does not borrow authored.
var instance = try zzdds.resources.Instance.init(allocator, &resolved.plan, factory);
defer instance.deinit() catch @panic("cleanup failed");
try instance.build(&static_bindings);
```

Parse/decode/resolve failures free partial allocations. Diagnostics identify their
phase, error, line/byte-column/offset and a bounded display path. The input source
name remains known to the caller on failure; successful resolved provenance owns
that name and its winning locations. Some native graph validation failures report
the enclosing document; unknown references and strict field errors identify their
source field. The structured presence paths retain separate segments, so a resource
named `a.b` remains distinct from two path segments even when a display path is dotted.

Generated `decodeToml` results own an arena and must be released through that owner,
not by calling generated field-level `deinit`. Values carry IDL defaults for inspection,
but presence records distinguish omission from explicit false, zero, empty strings
and empty sequences. Resolver QoS fields are optional, so inherited settings are not
prematurely default-filled. The resolved plan and provenance can outlive parsed records.

## Initial schema

```toml
schema_version = 1
name = "Writer"

[profiles."Telemetry::Base".writer_qos]
reliability = "RELIABLE_RELIABILITY_QOS"
history_depth = 4

[profiles."Telemetry::Small"]
base = "Telemetry::Base"

[profiles."Telemetry::Small".writer_qos]
history_depth = 2

[participants.main]
domain_id = 42
types = { Probe = {} }
topics = { Readings = { topic_name = "Readings", type_ref = "Probe" } }
publishers = { pub = {} }

[participants.main.writers.endpoint]
container_ref = "pub"
topic_ref = "Readings"
profile_ref = "Telemetry::Small"

[participants.main.writers.endpoint.qos]
history_depth = 1
```

A reader uses `subscribers`, `readers` and a profile's `reader_qos` block. Record
collections can also be authored as arrays, e.g. `types = [{ name = "Probe" }]`,
or `[[participants]]` with explicit `name`. Named tables explicitly inject their
key into each record's `name`; supplying `name` again is an error. This is a selected
generic decoding convention, not a zidl rule about DDS resources. Empty named
containers such as `pub = {}` are valid.

Type references are actual registered DDS type names, matching slice 1. There are
no automatic type aliases, generated sample libraries or native-library paths in
this schema. Domain IDs must be supplied explicitly and satisfy the concrete
builder's range. This initial schema describes one application per document.

Profiles have one optional `base`, and separate writer/reader QoS overlays. Resolve
base -> derived -> endpoint, then retain the concrete builder defaults for remaining
fields. Those bounded defaults are documented in [resource construction](resource-construction.md).
Every explicit setting has a winning source/provenance entry; defaulted fields have
no authored location. Explicit zero is validated as zero, never treated as absence.
Unknown profiles, duplicate names and cycles are rejected, including unused profile
chains. Chains are limited to 64 levels even when ancestors have already been cached.

Supported QoS is exactly slice 1's subset: reliability (canonical, case-sensitive IDL
enum spelling), history depth and finite sample/instance limits. Unsupported policies,
transport settings and entity kinds fail strict decoding. There is no generic deep
merge or implicit collection overlay. Profile names can be qualified strings, but
multi-file catalog composition, includes, multiple bases, topic filters, CLI overrides,
collection inheritance and live graph/QoS mutation are separately scoped follow-ons.
This schema is experimental and does not freeze the eventual catalog vocabulary.

## Parser/decoder subset and limits

The parser targets an explicit subset of [TOML 1.0](https://toml.io/en/v1.0.0):
quoted/literal strings and keys, dotted keys/headers, comments, booleans, signed decimal
integers, finite decimal/exponent floats, arrays, inline records, nested arrays and
arrays of tables. Basic-string escapes include Unicode scalar escapes. Date/time,
multiline strings, nondecimal numbers and numeric underscores are not supported and
fail explicitly. No full TOML conformance claim is made. Invalid duplicate definitions,
inline-table extension, leading-zero decimals, malformed escapes and control characters
are rejected. The legacy string-array accessor now handles commas/escapes correctly.

Default parser limits: 256 KiB input, depth 64 and 65,536 value/table work units.
`parseOwned` rolls back its arena on failure; the legacy raw `parse` contract still
requires an arena supplied by its caller. Duplicate-key diagnostics identify the
repeated key; strict decoder diagnostics own their display buffer after rollback.

The generic decoder supports optional scalars, strings/bounded strings, enums,
records, fixed arrays, nested sequences and explicitly enabled named record collections.
IDL inheritance, unions, wide strings and opaque types are rejected by this strict
subset. Its default limits are depth 64, 65,536 decoding work units, 4 KiB per string
and 4 MiB of copied presence-path text. Embedded NUL is rejected for IDL strings,
including C-string sequence elements. Source presence marks collection representation
explicitly; record names that resemble indexes cannot change source-path interpretation.

Resource limits count profiles as well as the concrete graph, before conversion or
entity creation. The frontend does no I/O, environment expansion, network lookup or
provider execution. Parsing and resolution do not construct DDS entities.

## Validation

`test-resource-authoring` runs the generated decoder/profile fixtures and the existing
programmatic builder tests. Tests compare a TOML reader plan with its programmatic
counterpart, free authored records before using the plan, preserve winning sources,
reject typos/references/zero QoS/cycles/depth overflow, inject allocation failures and
exchange a zidl-generated Probe through independently owned writer/reader graphs.

```sh
zig build test-resource-authoring -Dresource-authoring=true
zig build test-resource-authoring -Dresource-authoring=true -Doptimize=ReleaseSafe
zig build test-resource-authoring -Dresource-authoring=true -Dsanitize-thread=true
```

zidl's `zig build test-authoring` independently tests the generated decoder with a
small tree fixture, without depending on zzdds or a second parser. Those binaries
also join zidl's ordinary tests and coverage artifacts.

For zzdds coverage and Valgrind, build with
`zig build emit-tests-llvm -Dresource-authoring=true`. This emits both the resource
builder/authoring tests and the runtime migration tests. The CI coverage and
Valgrind jobs use that command, so the optional frontend is measured too.

## Ordinary runtime configuration migration

The default build enables `config-authoring` using the pinned zidl release.
`zig build test-config-authoring` checks shipped runtime files, independent ownership,
allocation failures, conditional settings, long strings and dense arrays. Use
`-Dconfig-authoring=false` only to select the legacy path.
The four existing config resolvers retain their signatures and compatibility policy:
unknown ordinary members are ignored and full IDL enum names match without regard
to case. Returned values still use the caller's allocator and generated `deinit`.

For strict checks and skipped-setting reports, use
`resolve_config.resolveParticipantConfigFromWithOptions` or
`resolveProcessConfigFromWithOptions`, passing `ReadOptions` and an initialized
`ReadDiagnostics`. Deinitialize the report separately from the returned config.
Reports survive temporary parse storage and contain original spellings and locations;
errors preserve legacy `InvalidValue` mappings while the report identifies the
underlying range/enum error. These companions return `ConfigAuthoringUnavailable`
when `config-authoring` is explicitly disabled.

Both migrated runtime configuration and resource authoring recognize `_setting`:
apply a known member normally, or record a skip when it is absent from the schema.
Known invalid values still fail. Ordinary unknowns remain errors in resource files.
User names such as `_Telemetry` are literal. Resolved resource plans retain an
independent `skipped` list and `source_name` after parsed records are destroyed.
See zidl's authoring documentation for duplicate and reserved-name rules.

Do not add conditional spellings to files shared with old readers yet: legacy
`applyToml` ignores `_setting` even when `setting` exists. This migration requires
zidl v0.3.23 and the updated zzdds reader; older zzdds releases do not acquire the
convention merely by generating new records. Existing direct `applyToml` remains
supported.

Ordinary file readers reserve 8 KiB of stack workspace for parsing and another 8 KiB
while decoding. Larger temporary work uses the caller's allocator. This lets the
shipped small-file bootstrap examples retain their 4 KiB allocation-block limit;
it does not guarantee every accepted file fits that allocator. Include this bounded
stack cost when sizing embedded tasks. Custom nesting limits also apply while
parsing conditional sections, even if those sections are later skipped.
