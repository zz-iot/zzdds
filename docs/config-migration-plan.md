# Configuration reader migration plan

2026-10-27. Implementation plan following the
[migration assessment](config-migration-assessment.md). The shared reader additions
are released in zidl v0.3.23-zig.0.17.0. zzdds now pins that release and selects the
new runtime reader by default. The implementation and release history below records
the migration sequence; local qualification and remote CI results remain distinct.

## Outcome

Keep how applications configure zzdds today: start with IDL defaults, optionally
read a file, change fields in the returned config, and pass that value to a factory
or participant. Preserve the existing public types, memory-allocation rules,
one-time process setup and independent factory defaults.

Improve the shared file-reading machinery so it can also support builder profiles,
the XRCE agent and zzest. Ordinary DDS applications do not need to use the builder.

Finish the necessary zidl additions before its PR/release. Then update zzdds's
zidl dependency and move its existing readers onto the new machinery. Keep
`applyToml` available throughout; no removal or deprecation date is part of this plan.

## 1. Agree exactly what `_setting` means

Enable this convention explicitly in configuration readers. The general TOML parser
continues treating underscores as ordinary characters.

```toml
[participant]
_xtypes = true
```

This means: apply `xtypes` if this build's configuration definition contains it;
otherwise leave the existing/default value alone and record that it was skipped.
The example is illustrative: current runtime config has no `xtypes` member.

Rules to implement and test:

- An ordinary unknown setting is an error in the new reader's default strict mode.
- A recognized `_setting` is checked and applied exactly like `setting`. Wrong
  types, invalid enum names and out-of-range values are still errors.
- An unrecognized `_setting` is skipped. Report it as unrecognized by this
  configuration definition, not as proof of a particular missing build feature.
- An unrecognized optional section can be skipped as a whole. Its TOML must still
  be syntactically valid and obey size/depth limits. If the section is recognized,
  its contents are checked normally; it does not make all nested typos optional.
- `setting` and `_setting` in the same section are a duplicate, in either order.
  No last-value-wins rule. Apply the same rule to section names and dotted keys.
- `_` and `__setting` are invalid *member spellings* when this convention is on.
  Reserve a single leading underscore for this purpose at configuration-member
  positions; reject a schema whose public members conflict with that convention.
  Internal generated ownership fields are not public configuration members.
- User-chosen names remain literal: a profile or topic named `_Telemetry` is still
  named `_Telemetry`. Do not strip underscores from named collection entries.
- Keep the original spelling and file location for messages. Look up the applied
  value using its ordinary name; skipped settings must not appear as applied values.

This first version checks whether the field exists in the generated configuration
schema. It does not turn arbitrary runtime failures into ignored settings. If a
recognized setting asks for an unavailable runtime mode, transport or security
feature, the existing runtime validation still applies. Broader conditional
runtime-capability choices need their own explicit rules later.

The generic reader should return an owned list of skipped settings with their paths,
locations and reasons. Applications decide whether to print it, save it in test
results, or reject a run requiring those settings. Add explicit limits for that list
and report truncation/exhaustion honestly; never claim every setting was applied.

## 2. Support reading into defaults or existing values

Provide two explicit operations in zidl's general authoring support; exact Zig
function names can follow implementation conventions:

1. Read into a fresh value using the IDL defaults. This is what zzdds's four
   existing resolver functions need.
2. Read using an existing value as the starting point. This supplies an alternative
   for direct `applyToml` users who already customized their config.

For the second operation:

- Missing fields retain their current values, including inside nested records.
- Explicit false, zero and empty strings replace the previous value.
- An explicit sequence replaces the entire sequence; `[]` clears it. An omitted
  sequence retains its old contents. Do not append or merge entries by name.
- Optional records that already exist retain unspecified child fields. If an
  optional record is introduced by the new input, initialize its missing children
  from their IDL defaults.
- TOML still has no null literal. Do not add a clearing/reset syntax in this task.
- Prepare an independent replacement first. An error leaves the starting value
  unchanged and frees the partial replacement. Document this stronger failure
  behavior rather than copying legacy partial-update behavior.

This is a general decoding operation, not a new factory override object, sticky
setting mechanism, environment-variable layer, or automatic file reload service.
Profile inheritance remains an explicit operation in the resource resolver.

## 3. Preserve how existing callers keep and free configs

The new reader currently returns a value whose strings and lists live in its own
memory arena: one object owns that temporary group of allocations. Existing config
APIs instead expect a normal generated config that the caller can keep and free
independently.

For current zzdds config types, use the generated deep-copy operation already
verified by the assessment: copy the decoded value into independent storage before
releasing the reader's temporary storage. Use the caller's supplied allocator.
Enable both generated helper APIs during the transition; adding authoring methods
must not change the established config data layout or binding interfaces.

Keep this adaptation in zzdds. Do not invent another general ownership system in
zidl merely to migrate these configs. Types without the required generated lifecycle
support can keep using the arena-owned API until separately supported.

Required checks:

- Defaults containing nonempty strings remain valid after temporary storage is freed.
- Returned config strings/lists remain valid after the source tree and the reader's
  temporary storage are freed.
- Every allocation failure cleans up, without invalidating the caller's prior config.
- Process setup still consumes its config under its existing contract and installs
  only once. Failed reads do not install partial process state.
- Factory get/set operations retain their allocator contracts and return independent
  snapshots. Existing participants do not acquire later default changes.
- Fixed-buffer and custom-allocator examples still meet their startup memory and
  allocation requirements. Measure temporary peak usage; do not fall back to libc
  allocation to make a test pass.

## 4. Choose compatibility behavior deliberately

The shared decoder should have explicit choices rather than making every consumer
accept the resource frontend's policies.

| Caller | Unknown ordinary fields | Enum spelling |
| --- | --- | --- |
| Generic new reader by default | Reject | Canonical IDL spelling |
| New resource/builder frontend | Reject | Canonical IDL spelling |
| Existing runtime resolver entry points, initial migration | Preserve legacy ignoring; make diagnostics available separately | Preserve case-insensitive matching of full IDL names |
| New strict runtime-config entry point/options | Reject | Explicitly selected/documented policy |

All migrated configuration frontends enable the `_setting` convention. The existing
runtime functions deliberately select compatibility behavior; that does not weaken
the new decoder's default. This allows changing the implementation without silently
changing the acceptance rules of existing public calls. Any later switch of those
public defaults requires a separately documented compatibility decision.

Keep the four existing return types/signatures. Add a diagnostic-capable companion
or explicit-options variant so callers wanting strict checks and skipped-setting
reports can request them. Do not require all callers to retain the reader's arena,
and do not introduce a new global logging policy.

Preserve the established treatment of files:

- Participant defaults involve no file reads.
- An explicitly named file propagates read/access/parse/value failures.
- Only the ambient process lookup tries `./zzdds.toml` and retains its documented
  `FileNotFound`/`AccessDenied` fallback.
- Preserve public error mappings where existing callers rely on them; return the
  new reader's more detailed messages through the additional diagnostics path.

Do not silently apply the new generic 4 KiB string limit to existing runtime files.
Retain the 256 KiB file policy and select decoding/report limits appropriate to that
schema. Test long strings and dense string arrays that fit the existing file limit;
use compact per-field tracking when full per-element history is unnecessary. Final
internal limits must pass those tests and allocator checks before switching callers.
This preserves useful accepted inputs without promising unlimited memory use.

## 5. Implement and release in this order

### A. zidl: complete the shared reader

Add conditional member handling, skipped/applied reporting, the existing-value
operation and explicit enum/unknown-field choices. Keep `applyToml` generation and
behavior unchanged. Add tests to normal CI and emitted coverage test binaries.

Test both versions of a generated fixture: one contains a feature setting and one
omits it. The same `_setting` input must apply on the first and skip on the second;
the ordinary spelling must fail on the second in strict mode. Include optional
sections, duplicates, nested mistakes, name-prefix collisions, false/zero/empty
values, source locations and allocation failures.

This decoder test does not require repairing unrelated full DDS builds with XTypes
disabled. Qualifying actual feature combinations remains a separate integration check.

### B. zzdds: prove the adapter with a local zidl override

Turn the assessment's probes into maintained tests using the actual runtime-config
IDL. Compare the old and new paths on shipped files and successful repeated updates.
Check memory ownership after the temporary reader is destroyed. Cover default,
explicit-file and ambient-file behavior, failed/duplicate process setup, factory
snapshots and binding error/allocator rules.

Run participant-config examples in Zig/C/C++/Java, custom-allocator startup tests,
and the resource writer/reader tests. Keep the released dependency pin unchanged
while testing the coordinated work locally. Fix any missing general mechanism in
zidl before declaring its PR ready.

### C. Review and release zidl

Include the general reader additions and their tests in the zidl PR. Keep the
configuration syntax/compatibility decisions documented. Release after review and
required checks, then update zzdds's dependency and verified hash.

### D. Switch zzdds's four resolver implementations

Keep their existing public API and the compatibility behavior above. Preserve the
process/factory/runtime conversion layers. Add the strict/reporting entry point,
correct stale ownership/fallback comments, and qualify against the released zidl
on native CI. This joins the resource-authoring PR; it does not require an agent or
zzest implementation to validate.

### E. Update shared files and revisit direct `applyToml` use

Only start writing `_setting` into shared files after the intended readers support
it. Older releases ignore that spelling even when the underlying feature exists;
a new reader cannot repair an already released binary. Document the minimum reader
version and test every intended worker baseline before claiming cross-version use.

Keep direct `applyToml` supported. Move documented examples to the new operations
when their use cases are covered. Decide deprecation later from actual caller and
type coverage, not from the builder's readiness.

## Completion criteria

The same shipped files produce the same effective runtime configs; ordinary API
behavior and allocator contracts remain intact; strict mode detects unmarked typos;
conditional settings apply or produce a recorded skip across feature schemas;
existing-value reads preserve omitted settings; failures leave no leaks or damaged
starting values; native/binding/custom-allocator checks pass against the released
zidl pin. Only then describe the existing runtime configuration as migrated.

This extends slice 2. Typesupport-library bindings remain the next slice, followed
by the XRCE backend and lifecycle work. Neither the builder architecture nor the
concurrency/broker implementation needs redesign for this migration.

## Local implementation and checks (2026-10-27)

Implemented A and the development adapter in B: conditional settings and skip
reports, independent reads from an existing value, explicit compatibility policies,
and the actual runtime-config adapter behind `-Dconfig-authoring=true`. Resource
plans retain their own skipped-setting reports. Default builds still select the
released reader. No dependency pin was changed.

Qualification so far:

- The full coordinated zzdds suite passed 1,300 tests; the default released-pin
  suite passed 1,273. Both include existing process, factory and fixed-buffer checks.
- Focused resource/config tests passed in Debug, ReleaseSafe and ThreadSanitizer.
- Nine shipped configuration files produce the same semantic values through legacy
  `applyToml` and the new adapter. Maintained tests also cover strict/conditional
  behavior, diagnostic ownership, allocation failures, legacy enum spelling,
  5,000-byte strings and 70,000-element string arrays within the file limit.
- Zig, C, C++ and Java participant-config examples passed sample exchange in both
  programmatic and file modes against the coordinated build.
- C and C++ custom-allocator startup guards passed with the original 4 KiB block
  pools, without libc allocation. An instrumented C startup run peaked at eight
  pool blocks (32 KiB), including configuration and factory bootstrap. Persistent
  process state remains installed under its existing contract.

The expanded parser initially exceeded the custom allocator's block limit because
its temporary arena grew. Ordinary readers now reserve 8 KiB of stack workspace for
parsing and another 8 KiB during decoding; any larger temporary work uses only the
caller's allocator. This is a bounded stack cost, not a promise that every 256 KiB
file fits a 4 KiB-block allocator. Keep these budgets in embedded stack assessments.
The general decoder and resource frontend retain their existing allocator policies.

Remaining release gates: review/release zidl, update the verified dependency pin,
qualify that released version on native CI, and then enable the migrated runtime
path by default. Shared files must not depend on `_setting` before that minimum
reader version is available. Direct `applyToml` remains supported.

## Released dependency integration (2026-10-28)

zidl v0.3.23-zig.0.17.0 is released. The zzdds manifest now pins its archive and
verified package hash. The shared runtime reader defaults on; explicit
`-Dconfig-authoring=false` preserves the legacy fallback. Resource authoring stays
optional. Native PR CI now qualifies resource authoring and configuration against
the release rather than requiring a manually supplied zidl checkout. Remote results
must be checked when the zzdds PR runs; no hosted CI run is claimed by this update.

Do not assume conditional settings work with older zzdds releases or with the
explicit legacy fallback. Existing direct `applyToml` stays supported.

Local checks against the published package passed: the full resource-enabled suite
(1,295 tests), 28 focused resource/config tests in Debug, ReleaseSafe and
ThreadSanitizer, all four language binding builds, and guarded C/C++ factory startup
with the original allocator pools. Zig/C/C++/Java programmatic and file-mode sample
exchanges passed. LLVM emission includes the maintained config migration tests for
coverage and Valgrind; the emitted migration binary also passes directly. The legacy
fallback still builds. These checks used the manifest dependency without a source
override; they are Linux evidence, not a substitute for the configured native matrix.

## PR readiness sweep (2026-10-28)

The final review also applies custom nesting limits while parsing skipped sections.
The LLVM and TSan module graphs now receive the generated resource schema and honor
the local runtime override. Resource construction/authoring tests are emitted with
LLVM, and coverage/Valgrind CI enables the optional resource frontend so it is
actually measured. The focused suite passes 29 tests in Debug, ReleaseSafe and
ThreadSanitizer. The full resource-enabled suite passes; native hosted results still
need review when the PR runs.

Local kcov also confirms the emitted tests execute the new frontend: resource
construction 98.7%, resource authoring 97.6%, config resolution 98.4%, and the parser
94.1% line coverage in the focused/library run. These are local kcov results, not a
hosted Codecov result. All three emitted resource/config binaries pass Valgrind
with full leak checking and an error exit code.
