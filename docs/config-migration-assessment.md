# Existing configuration migration assessment

2026-10-27. Assessment of the local slice-2 work, not a consumer migration or a
release/conformance claim. Existing process/factory/participant entry points and
legacy generated decoding are unchanged by this assessment.

Implementation order and selected compatibility rules are now recorded in the
[migration plan](config-migration-plan.md).

## Recommendation

Preserve the established configuration policy and public owned-value APIs. Introduce
strict/presence-aware decoding underneath those APIs only after compatibility gaps
are addressed. The resource builder and zzest should reuse generic authoring
mechanisms without redefining ordinary DDS bootstrap configuration.

The new decoder is a useful authoring primitive, not yet a drop-in replacement for
`applyToml`. Do not deprecate that API merely because the resource frontend works.
Make `_field` conditional settings and owned-value adaptation migration gates.
Keep seeded overrides supported before deprecating direct `applyToml`, rather than
accepting regressions as necessary for the builder.

## Existing contracts to preserve

The controlling [configuration decision](decisions.md#configuration) is explicit:
resolvers return concrete config values; applications customize those values through
ordinary field mutation; factories/participants do not subsequently re-merge them.
There is no configuration environment-variable layer, sticky override object or
file hot-reload mechanism. Preserve those choices.

| Current use case | Current behavior | Migration mapping |
| --- | --- | --- |
| `resolveParticipantConfig(alloc)` | Pure IDL defaults, no filesystem access; owned result | Decode defaults and detach to the same generated owned type, or retain a specialized default-construction path |
| `resolveParticipantConfigFrom(alloc, path)` | Explicit file over IDL defaults; all file/parse/value failures propagate | Preserve file selection, defaults, return type and compatible public errors |
| `resolveProcessConfig(alloc)` | Tries `./zzdds.toml`; `FileNotFound` and `AccessDenied` fall back to defaults | Retain this explicit exception; do not change it as a decoder side effect |
| `resolveProcessConfigFrom(alloc, path)` | Explicit path; no missing/access-denied fallback | Same contract; no ambient search or environment substitution |
| Post-resolution customization | Caller mutates concrete fields, observing existing string/sequence ownership rules | Keep direct mutation; do not introduce profile re-resolution after mutation |
| Repeated `applyToml` | Present fields replace current values; omitted fields retain current values | Requires a seeded generic overlay path, not fresh decode from `T{}` |
| Omitted/explicit sequences | Absent sequence remains; explicit sequence replaces, including `[]` | Preserve presence and whole-sequence replacement; no implicit append/name merge |
| Process installation | `configure` consumes its input on success/failure, clones persistent state, installs once | Preserve allocator, consumption, one-time and failure semantics |
| Ambient factory creation | First factory lazily installs process config; later factories receive independent clones | No shared mutable participant configs or first-factory allocator capture |
| Factory config get/set | Owned snapshots; setter affects future participants; caller-facing getter uses its established allocator contract | Keep snapshots, allocator boundaries and existing ABI |
| Explicit participant creation | Uses supplied config, with existing explicit domain argument behavior | No profile lookup, implicit file access or overlay introduced here |
| C/C++/Java file configuration | Existing C/JNI wrappers and DDS return-code mappings | Retain signatures and translations; do not expose arena-backed values as owned C-compatible configs |

Profile inheritance is an explicitly selected *resource-definition* operation.
It must not become a hidden merge stage in these runtime configuration APIs.
The builder remains optional; existing DDS applications need not instantiate it.

## Audited consumers and schemas

- `idl/zzdds.idl`: DomainParticipantConfig, ProcessConfig, defaults, optional fields,
  string sequences and canonical enum types. The current runtime-config records
  do not contain an `xtypes` option; that example motivates conditional-schema
  support rather than describing a field found in this checkout.
- `src/config/resolve.zig`, `process.zig`, `generated.zig` and `schema.zig`.
- `src/c_abi/extensions.zig`: process installation, factory config snapshots,
  custom allocator handling and conversion to runtime config.
- Participant-config examples in Zig, C, C++ and Java; custom-allocator examples;
  the companion zzdds-examples shape adapter, which gets current factory defaults
  and changes selected scalar fields before `create_participant_ex`.
- Generator implementation/docs and the new `zidl_rt.authoring` ownership model.
- Concurrency runtime configuration/capability contract, to preserve its separate
  runtime scope and explicit unsupported-choice behavior.

Direct production `applyToml` calls found in the audited zzdds source are concentrated
in three call sites in `resolve.zig`. The searched companion sources predominantly
use the public file/config APIs. This does not enumerate external users of generated
zidl code; retain its compatibility surface until migration support is available.

## Verified bridge and observed differences

Six isolated local probes used the **actual** `idl/zzdds.idl`, generated with both
legacy TOML and new authoring flags and one shared zidl runtime:

1. Default ProcessConfig decodes and deep-clones into the existing owned generated
   type, preserving nonempty timer/multicast defaults after the decoded arena closes.
2. Nested authored values preserve explicit false, zero, optional zero, strings,
   sequences and omitted defaults across legacy/modern decoding.
3. Expected incompatibilities are demonstrated: lowercase enum spellings accepted
   by legacy code are rejected by the strict decoder; ordinary and underscore-prefixed
   unknown fields currently fail strict decoding.
4. Reapplying an empty legacy table to a config seeded with port base 9000 retains
   9000; fresh decoding returns the IDL default 7400. Fresh decode is not an overlay.
5. Allocation-failure injection across decode plus owned clone releases partial
   allocations. This supports a detach bridge; it does not qualify every binding
   or allocator/bootstrap budget.
6. Nine checked-in runtime config files produce identical **semantic values** through
   the pre-slice-2 parser plus `applyToml`, and the extended parser plus strict decode
   and owned clone. Private ownership flags/buffer addresses are not semantic values.

Corpus: all six `examples/config/*.toml`, the C/C++ custom-allocator `zzdds.toml`
files, and Java listener-pubsub's `zzdds.toml`. The old parser was read from checkpoint
`6ba20aa`. The new decoder/compiler use the current local zidl work. Probe source,
generated config/shim, old parser and logs are retained locally under
`/tmp/zzdds-config-assessment/` (six passing tests). These exploratory probes are
not integrated CI tests or proof that all externally authored files migrate.

All three internal production `applyToml` call sites start from a fresh `.{}`.
Consequently the four resolver APIs can use fresh decoding plus owned detachment;
they do not need a new seeded-override input type. Seeded overlay parity matters
for direct generated-API users and deprecation, not as a reason to complicate
ordinary factory/participant configuration.

The promising adapter is:

```text
explicit input/defaults -> located tree -> decode/overlay with presence
                       -> generated deep-owned clone -> existing config API
```

Generate both helper surfaces during migration so the existing generated lifecycle
and binding contracts remain available. Never return `decoded.value` by shallow
copy and then destroy its arena. Test detachment from that arena before handing a
config to `process.configure`, factory setters or language bindings.

## Compatibility gaps before switching consumers

| Gap | Required resolution |
| --- | --- |
| Unknown fields | Ordinary unknowns fail in the new strict path; implement explicit conditional members and a staged compatibility policy before changing established entry points |
| `_field` syntax | Proposed and agreed direction; **not implemented yet**. A new decoder currently rejects it, while old `applyToml` ignores it even when `field` exists |
| Seeded overrides | Generic overlay must retain omitted existing fields and replace explicit ones, including false/zero/empty collections; no DDS-specific field decoder |
| Enum spelling | Legacy generated converters use case-insensitive matching; strict decoding uses canonical case-sensitive IDL names. A runtime-config compatibility option or explicit transition is needed |
| Limits | Strict decoding adds 4 KiB string/depth/work/presence budgets. Do not silently impose tighter limits on existing valid runtime-config inputs; select/document compatible consumer budgets |
| IDL/type coverage | Strict inheritance/unions/wide strings are not supported. Actual current config shapes decoded successfully; that is not parity for all generated `applyToml` users |
| Public errors | Preserve established resolver error behavior where required, including current `InvalidValue` cases, while retaining richer diagnostics separately |
| Ownership/allocator | Return the existing independently owned type, preserve allocator identity and consumed-input rules, and test fixed-buffer high-water/bootstrap costs |
| Failure atomicity | Define successful overlay equivalence; prefer preparing a complete replacement before committing it. Do not replicate partially mutated failure states as a compatibility goal |
| Parser tightening | Duplicate/invalid TOML and some formerly accepted syntax now fail. Separate intentional syntax corrections from valid-file compatibility; the nine-file corpus is a baseline, not a full conformance audit |

## Conditional settings using underscore

Use ordinary TOML `_xtypes = true` or `[participant._xtypes]`; no parser grammar
extension is required. Interpretation belongs at schema-member decoding and the
relevant capability-validation boundary, not in raw key tokenization.

Recommended semantics for implementation:

- `field` is a required setting. `_field` is an explicitly conditional setting.
- If the field is recognized and available, decode and validate it normally.
- If the conditional field is absent from this build's schema, skip it and record
  its raw/canonical path, location and `unrecognized_in_this_schema` reason. The
  generic decoder cannot determine whether it was compiled out or misspelled.
- Known values with wrong types/ranges/enums fail even when conditional. A known
  setting unavailable at runtime needs an explicit capability-stage decision; do
  not catch arbitrary backend failures and reinterpret them as optional skips.
- Unknown conditional subtrees can be skipped in full. TOML syntax/duplicates/limits
  are still checked. When the subtree is recognized, its children remain strict
  unless individually marked conditional.
- A setting supplied as both `field` and `_field` is a duplicate, never an
  order-dependent override. Define normalization before choosing a winner.
- Interpret the prefix only at schema-member positions. A named profile/topic/type
  such as `_Telemetry` remains that literal resource name.
- Reserve the marker at schema-member positions when this convention is enabled.
  Detect genuine leading-underscore field collisions explicitly; do not rely on
  an exact-match-first heuristic whose meaning changes when a field is compiled out.
  Define empty/doubled-marker handling before implementation. The audited runtime
  config schema has no public member-name collision with the proposed convention.
- Applied conditional settings retain canonical presence and their source spelling.
  Skipped settings do not become applied presence. Return/report skipped settings
  separately so zzest can require a feature or label a result accurately.

The mechanism is opt-in for the generic decoder, enabled by the relevant configuration
frontends. It must not silently redefine arbitrary TOML documents or named collections.
For APIs whose existing return type is just a config, provide a diagnostic-capable
companion/report path rather than forcing all callers to adopt an arena wrapper or
installing a new global logging/configuration policy.

**Mixed-version warning:** marking an existing setting `_field` today makes an older
legacy decoder ignore it, including on builds that could have applied it. Introduce
compatible member lookup/normalization for consumers first, then migrate shared
files. Shared generic helpers or a duck-typed legacy table view can bridge lookup
without writing a second field-by-field decoder. Do not bulk-prefix files before
that bridge exists.

Conditional unsupported choices must also be reconciled explicitly with the runtime
contract: ignoring an opted-in preference leaves the configured default unchanged;
it does not authorize silently substituting an unavailable required execution mode,
security setting or transport. No runtime/broker policy changes are made here.

## Migration sequence and acceptance gates

1. Implement conditional-member lookup, collision rules, applied/skipped provenance
   and diagnostics in generic authoring support. Test schemas generated with and
   without a feature field; the decoder test need not depend on the currently
   unqualified full `-Dxtypes=false` DDS build.
2. Add the owned detach adapter and preserve direct `applyToml` while defining a
   generic seeded overlay alternative. Test existing value retention,
   explicit replacements and failure cleanup using the real config IDL. Preserve
   enum compatibility deliberately and pick runtime-config budgets explicitly.
3. Promote the isolated probes to maintained CI tests. Extend coverage to every
   resolver entry point, missing/access-denied/malformed files, one-time install,
   independent factory snapshots and custom-allocator consumption/failure paths.
   Keep C/C++/Java participant-config and zero-allocation examples as acceptance gates.
4. Add both generated helper surfaces to runtime config codegen, then migrate the
   four resolver implementations behind their existing public types/contracts.
   Process/factory ownership and runtime conversion remain their current layers.
   New optional settings must work through compatibility lookup before example files
   begin using them.
5. Compare effective configs, errors and application behavior across feature builds.
   Capture skipped settings for zzest/agent diagnostics. Complete native CI and the
   coordinated zidl release/pin sequence before advertising migrated behavior.
6. Only then decide deprecation of direct generated `applyToml`. Resource authoring
   can use the modern path independently while established runtime callers retain
   a supported compatibility path.

This is not a proposal to add sticky pins, environment-variable precedence, implicit
profile merging, a new process singleton, or mandatory builder machinery to ordinary
DDS construction.

## Documentation discrepancies to correct during migration

`resolveProcessConfig` code and `docs/decisions.md` deliberately allow AccessDenied
fallback for the ambient file, whereas some comments mention only missing files.
The opening ownership comments in resolve/process still warn that untouched/failed
`applyToml` values cannot be deinitialized; the current zidl generator documents and
emits `_toml_applied` guards and cleanup support. Reconcile those comments with actual
supported behavior and regression tests rather than treating stale prose as the
migration contract. Repeated apply failure need not preserve earlier values atomically.

`zzdds_process_configure` is documented as a Zig/internal export, not a generally
constructible public C config-pointer API. The supported from-file C entry point
and its caller-supplied allocator path must remain distinguished in migration claims.
