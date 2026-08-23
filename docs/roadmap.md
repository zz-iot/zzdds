# Zenzen DDS — Roadmap

Future work only. Completed work is in the git log. For current implementation status
see `docs/implementation_status.md`.

---

## Raw / loaned DataReader & DataWriter API redesign — implemented (2026-08-22)

Full design in `docs/design/raw-loan-api.md`. Triggered by an external ROS2 RMW
integration attempt depending on `zzdds_take_loaned_raw()` as if it were real zero-copy —
it isn't (heap-copies out of reader history, wraps the copy in a loan-shaped handle) —
combined with the raw family being hand-written, C/C++-only, exactly the
independently-authored-per-binding-signature shape that caused the `create_participant_ex`
bug found via the participant-config/discovery examples.

Decided: replace the entire hand-written raw family (`bootstrap.zig`'s `write_raw`,
`take_one_raw`, `take_n_raw`, `take_loaned_raw`, etc. — full list in the design doc) with
real `dcps.idl` operations, generated consistently across all four bindings, full batch
support (read/take side only), and a write-side loan (`loan_raw`/`publish_loan_raw`/
`return_loan_raw`) that didn't exist before in any form. No back-compat shim — full
replacement.

Two real, pre-existing bugs found and fixed along the way, independent of raw/loan itself:

- `delete_contained_entities` has zero error propagation at any level
  (`participant.zig`/`subscriber.zig`/`reader.zig` all hardcode `RETCODE_OK` regardless of
  precondition state) — a real DDS 1.4 spec-compliance gap, not just a loan-teardown issue.
- Three of four bindings' typed reader family (C, C++, Java — Zig is correct) carries an
  incomplete 3-field `zzdds_sample_info`/`Sample` instead of the real 12-field spec
  `SampleInfo` — missing `source_timestamp` and every generation/rank field, live in every
  current C/C++/Java example today.

Punch list, all landed (see design doc for full detail on each):

- [x] Fixed `delete_contained_entities` cascading error propagation (participant → publisher/
      subscriber/topic → reader/writer), via a synchronous check-then-teardown pass (fails
      all-or-nothing with `PRECONDITION_NOT_MET` before any child is torn down, rather than
      the async-completion status-aggregation originally sketched — `deinit()` completes via
      `EntityQuiesce`, so there was nothing synchronous to aggregate from).
- [x] Loan-outstanding tracking + `PRECONDITION_NOT_MET` fast-fail teardown, read (CAS-based
      refcount pin table, `reader.zig`) and write (single-owner counter, `writer.zig`) side.
- [x] Real `max_len == 0` loan branching wired into zidl's generated `take_raw`/`read_raw`
      (and `take_next_instance_raw`/`read_next_instance_raw`, added for full parity with the
      old raw family's instance/condition-filtered variants — the illustrative IDL sketch
      above only showed the unfiltered case).
- [x] `take_raw`/`read_raw`/`return_loan_raw` (read) and
      `write_raw`/`loan_raw`/`publish_loan_raw`/`return_loan_raw` (write) added to
      `dcps.idl`, generated across all 4 bindings (Zig, C, C++, Java).
- [x] Batch read/take-loan with the non-contiguous, one-shared-pin-per-batch shape
      (`sequence<OctetSeq>`, `reader.zig`'s `loan_table` keyed off the descriptor array's
      pointer identity).
- [x] DCPS-layer refcounted pin/retirement mechanism (`EntityQuiesce`-modeled), heap-backed;
      pool/allocator seam still a single concrete (heap) implementation, as planned — no
      config flag yet.
- [x] Fixed the reduced-`SampleInfo` bug in C/C++'s typed reader codegen (Java's typed
      wrapper reads `SampleInfo` fields off the base interface's own real 12-field struct
      via the new ops, not a separate reduced shape).
- [x] Added `zidl_cdr_writer`'s "counting" mode, wired into C's and C++'s generated
      non-timestamped `write`/`dispose`/`unregister` (count-then-`loan_raw`, no
      malloc/realloc). The `_w_timestamp` family stays on `write_raw` — `publish_loan_raw`
      has no `source_timestamp` parameter, so only the "use now" path can loan.
- [x] Java write-loan buffer exposure landed differently than originally scoped here: not a
      new hand-written method in `zzdds_java_runtime.c`, but a `java.zig` codegen special
      case (`isWriteLoanBufferOp`) generating a real `java.nio.ByteBuffer`-based
      `loan_raw`/`publish_loan_raw`/`return_loan_raw` for the base `DataWriter` interface —
      `zzdds_java_runtime.c` needed no changes at all. Found and fixed a real, previously
      unexercised bug along the way: the *generic* per-op JNI marshaling this would otherwise
      have used copies through a fresh native buffer on every call, losing the loaned
      buffer's identity between `loan_raw()` and `publish_loan_raw()` — confirmed via a real
      re-break to publish uninitialized memory as sample data, not just a resource leak.
- [x] Migrated the one known direct consumer of the old raw functions,
      `zzdds-examples/spikes/rust` (no external RMW code exists in this workspace to
      migrate). `c/shape/shape_main.c` needed only a rebuild, as expected.

---

## Hardened `zzdds_java_runtime.c`'s JNI boundary against null/invalid handle inputs (2026-08-20)

Greptile's review of PR #67 (the `configureFromFile`/`asZzddsFactory` JNI wrappers added there)
flagged that both would crash the whole JVM — not throw a catchable exception — if a Java caller
passed `null`: `zzdds_java_unbox(env, NULL)` itself returns a safe native `NULL`, but the
downstream C-ABI functions it feeds (`zzdds_process_configure_from_file`'s `path:
[*:0]const u8`, `DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory`'s `factory:
*anyopaque`) declare non-nullable parameters and dereference them unconditionally. Verified this
is real (not just theoretical): `DDS_DataWriter_as_zzdds_DataWriter` — `asZzddsDataWriter`'s
already-merged target function — has the exact same non-nullable-`*anyopaque`-dereferenced-
unconditionally shape, confirming this wasn't a one-off in the two new functions but a
pattern already present (and unfixed) in the file.

Generalized rather than patching just the two flagged functions: audited every `zzdds_java_unbox`
(21 call sites) and `GetStringUTFChars` (4 call sites) use in the file. Added two helpers —
`zzdds_java_require_non_null` (throws `NullPointerException` naming the parameter, returns
false) and `zzdds_java_require_utf_chars` (same, plus the UTF-8 conversion) — and applied them
to every call site whose Java-side object/string parameter has no existing null-tolerant
semantics of its own. Deliberately left three call sites unguarded, because null already has
real, documented meaning there: `destroyWaitSet`/`destroyGuardCondition`'s idempotent-destroy
convention, and `cftMatchSample`'s `cft == NULL` "no content filter" convention (its `accessor`
parameter, which has no such meaning, is guarded).

Verified for real, not just by inspection: a standalone Java harness calling
`configureFromFile(null)`, `asZzddsFactory(null)`, `asZzddsDataWriter(null)`, and
`registerTypeSupport(null, ...)` confirmed all four now throw a catchable
`NullPointerException` (previously: a JVM crash) — including confirming a normal
`createFactory()` call still succeeds immediately afterward, i.e. the JNI environment isn't left
in a bad state by the throw. Re-ran `zzdds-examples`' `participant-config` (exercises
`registerTypeSupport`/write/take/`asZzddsFactory`/`configureFromFile` together) end-to-end on
Java after the change — still passes cleanly, confirming the new guards don't reject legitimate
non-null calls.

**Update (2026-08-20) — a second, distinct gap found on re-review**: Greptile's next pass on
`asZzddsFactory` pointed out that a *non-null* but wrong-type argument was still unsafe —
`zzdds_java_require_non_null` only checks for `NULL`, but `zzdds_java_unbox` itself never checked
whether its `GetFieldID(cls, "ptr_", "J")` lookup actually succeeded before calling
`GetLongField` with the result: an object with no `ptr_` field at all (some unrelated Java type)
makes `GetFieldID` fail and leaves a pending `NoSuchFieldError`, and calling `GetLongField` with
that invalid field ID is itself undefined behavior — a second, independent crash underneath the
first one, present in `zzdds_java_unbox` for every one of its 21 callers, not just the two new
functions. Worse: even an object that *does* have a `ptr_` field (any other zzdds entity
wrapper — they all share that same field declaration) unboxes "successfully" into a real,
valid-looking native pointer of the *wrong entity type*, which the C-ABI downcast then
dereferences as if it were the right one.

Fixed in two layers: (1) `zzdds_java_unbox` now checks `GetFieldID`'s result and clears/returns
`NULL` instead of proceeding to `GetLongField`, closing the "no `ptr_` field at all" case for
every caller — the null-tolerant ones included, which needed this protection just as much for a
non-null-but-wrong-type argument. A new `zzdds_java_require_unboxed` helper (null-check +
unbox + "throw `IllegalArgumentException` if unbox still came back empty") replaced the
`require_non_null`-then-`unbox` two-step at every "required" call site from the first pass. (2)
For the two extension-view "narrowing" functions specifically (`asZzddsFactory`/
`asZzddsDataWriter`) — the ones a caller could plausibly hand *any* other real entity wrapper to
by mistake, since they take a bare `Object` — added a `zzdds_java_require_instance_of` check
against the expected `Dcps.DDS.DomainParticipantFactory`/`DataWriter` interface before
unboxing, catching the "right shape, wrong entity type" case `GetFieldID` succeeding can't rule
out on its own.

Verified for real again: the same standalone Java harness, extended to pass a plain unrelated
object (`"not a factory"`, `new Object()`) and — the specific scenario raised — a real, live
`DomainParticipantFactory` object into `asZzddsDataWriter`, confirmed all three now throw
`IllegalArgumentException` (previously: undefined behavior/crash territory) while a genuine
`asZzddsFactory(<real factory>)` call still succeeds. `zig build`/`zig build test` clean; the
`participant-config` example re-run end-to-end again afterward.

Broadening the same `IsInstanceOf` type-check (not just the `GetFieldID`-safety fix, which now
covers everything) to the other ~19 handle parameters in this file (`writer`/`reader`/
`condition`/`participant`/`waitset`/`guardcondition` across the write/take/lookup family) is a
further, separate expansion — deliberately not done here. It would need researching the exact
valid Java class(es) for each (some, like `writer`, can legitimately be either the `dcps` or
`ext` package view of the same entity) and touches the whole file's structure again; flagged as
a follow-up, not folded into this pass.

**Update (2026-08-20) — two more rounds, then the broader rollout done**: Greptile's next two
review passes found (a) the same call chain still crashed on a *non-null* wrong-type
argument — `zzdds_java_require_non_null` only checks for `NULL`; `zzdds_java_unbox` never
checked whether its own `GetFieldID` lookup succeeded before calling `GetLongField` with the
result, undefined behavior for any object with no `ptr_` field, and even a real `ptr_`-bearing
object from a *different* entity type unboxed "successfully" into the wrong native pointer —
and (b) once fixed with an interface-based `IsInstanceOf` check, that an app-defined class could
still `implements Dcps.DDS.DomainParticipantFactory` with an arbitrary `ptr_`, since interfaces
are open to any implementer, plus the new `static jclass` cache backing that check published
across threads with no synchronization (unlike every other class cache in this file). Investigated
whether `writer`/`reader` can legitimately be either the `dcps` or `ext` package view before
broadening further: no — the generated per-topic `XxxDataWriter`/`XxxDataReader` wrapper
constructors are compile-time typed to the plain `Dcps.DDS.DataWriter`/`DataReader` interface
(`writer_iface`/`reader_iface` in zidl's `emitZzddsDataWriterFile`), so only the base `dcps`-package
class is ever legitimately passed to the raw write/take functions; the `ext` view is only used for
`set_listener_ex`, never write/take.

Fixed all three, then finished the broadening: (1) `zzdds_java_unbox` now checks `GetFieldID`
itself, closing the "no `ptr_` field" case at the root for every caller. (2) `zzdds_java_require_
instance_of` now checks the concrete `*Impl` class (e.g. `io/zzdds/dcps/DomainParticipantFactoryImpl`,
not the `Dcps.DDS.DomainParticipantFactory` interface it implements) via the existing, already
mutex-protected `zzdds_java_class_cache`/`zzdds_java_get_or_cache_class` — reusing that
infrastructure closed the race for free instead of needing a new lock. A new `zzdds_java_require_
instance_of_any` variant (accepts a caller-supplied array of candidate classes) handles the one
parameter that legitimately spans two concrete types: `take_w_condition`'s `condition` argument,
which per spec accepts a `ReadCondition` or its `QueryCondition` subtype — two independent
sibling Impl classes in Java, not one a subclass of the other, so a single-class check would wrongly
reject one of them. (3) Rolled the (now race-free, concrete-class) check out to every remaining
unboxed handle parameter: `participant` (`registerTypeSupport`), `writer` (the five write/
register/lookup functions), `reader`/`reader_obj` (all eight take/read functions, six of them
shared static helpers so one check covers two `JNIEXPORT` wrappers each), `condition_obj` (the
two `_w_condition` functions, via the new "any of" variant), `waitset`/`guardcondition`
(`destroyWaitSet`/`destroyGuardCondition` — null still a no-op, a wrong-type non-null value now
rejected instead of silently no-op'd), and `cft` (`cftMatchSample` — null still means "no filter",
non-null wrong-type now rejected). Deliberately left unchanged: `zzdds_java_waitset_attach_
condition`/`zzdds_java_resolve_condition_handle`'s own existing type-dispatch cascade for `cond`
(already spec-appropriate — `WaitSet.attach_condition` genuinely takes any `Condition`, and this
code has its own delicate, separately-hardened history across three earlier rounds of Greptile
review in PR #62; not part of the same `*_Raw` pattern, and riskier to touch than to leave alone)
and `accessor`/`typeName`/`typeClass` (not zzdds entity handles at all — an app-supplied callback
interface and a plain `String`/`Class<?>`, with no "wrong concrete type" to check).

Explicitly **not** attempted, and documented as such directly in `zzdds_java_require_instance_of`'s
own comment: validating that a correctly-typed handle's native pointer is still *live* (not already
destroyed). That's a use-after-free class of problem structurally different from "wrong Java type,"
would need a live-handle registry this project has nowhere else either (not in C, C++, or Zig), and
is out of scope here.

Verified for real, comprehensively: rebuilt and ran a standalone Java harness covering every one of
the newly-hardened sites — a real, live entity handle of the *wrong* type (e.g. a genuine factory
object passed to `writeRaw`/`takeRaw`/`registerTypeSupport`/`destroyWaitSet`/
`destroyGuardCondition`/`cftMatchSample`) now throws `IllegalArgumentException` instead of
undefined behavior, an app-defined class implementing the public interface with a bogus `ptr_` is
now rejected the same way, `destroyWaitSet(null)`/`cftMatchSample(null, ...)` still behave exactly
as before (silent no-op / "no filter"), and 16 threads hammering `asZzddsFactory` concurrently on
first call (half with a real factory, half with a bogus app-defined one) completed without a
crash. `zig build`/`zig build test` clean throughout; `participant-config` and `discovery`
re-run end-to-end on Java afterward, both still pass.

---

## Examples cleanup list resolved — mostly already done, one real gap fixed (2026-08-20)

Followed up on `docs/design/dcps-api-coverage-audit.md`'s "Per-binding asymmetries" and
"Examples" cleanup list (written 2026-08-14) as a short follow-on to the `-Z`/`--datafrag-size`
work above. Re-checking against current code (not the audit's 2026-08-14 snapshot) found two
of the three per-binding asymmetries, the `shape` content-assertion gap, and the `WaitSet.
get_conditions()` gap **already resolved** — landed sometime during the presence/registry/
catchup/waitset PRs since the audit was written, just never reflected back into the audit doc
itself (now updated to say so, to stop it misleading whoever reads it next).

The one real, still-live gap: `zig/waitset`'s publisher and subscriber were the only example in
the whole repo still discarding `registerTypeSupport`'s return value (`_ =
zzdds.registerTypeSupport(...)`) — every other example (including every other `waitset` port:
`c`/`cpp`/`java`) checks it and hard-fails loudly on `false`. Fixed to match
(`zig/waitset/publisher.zig`/`subscriber.zig`). Verified via a rebuilt `zig build` and a real
single-process smoke run of both binaries past `registerTypeSupport` with no `FAIL` printed.

---

## Real, live bug found and fixed: `create_participant_ex`/`set_default_participant_config`/
`get_default_participant_config`'s exported C-ABI symbols used the wrong struct layout for every
non-Zig-native caller (2026-08-20)

Found while adding `-Z`/`--datafrag-size` to zzdds-examples' C/C++/Java `shape` ports (see the
"datafrag-size rolled out to every binding" entry below) — attempting the obvious implementation
(fetch the factory's current default config, override `rtps.fragment_size`, call
`create_participant_ex`) crashed for real on Java, and by code inspection affects C and C++ too,
never previously caught because nothing had called any of these three operations across the C-ABI
boundary before (`zig/shape`/`dds-rtps`'s own zzdds port both call the pure-Zig
`ZZDDS.DomainParticipantFactory` wrapper directly, never crossing it).

**Root cause, confirmed via a real JVM crash (`zzdds_UdpConfig.deinit` dereferencing garbage), not
just by inspection**: `zzdds.zzdds.DomainParticipantConfig` (`src/config/generated.zig`'s sibling —
the type `factory.zig`/`extensions.zig` actually operate on, imported as
`@import("zzdds_ext_generated").zzdds`) is a plain Zig `struct` (not `extern struct`) carrying a
hidden `_toml_applied: bool` bookkeeping field (added by zidl's `--zig-generate-toml-config`,
gating whether `deinit()` is allowed to free a struct's string/sequence fields — see zidl's own
roadmap for the field's purpose). The three exported C-ABI symbols
(`zzdds_DomainParticipantFactory_create_participant_ex`/`_set_default_participant_config`/
`_get_default_participant_config`, `src/c_abi/extensions.zig`'s generated wrappers) declare their
`config` parameter as `*zzdds.DomainParticipantConfig` — that same non-`extern`, `_toml_applied`-
carrying Zig type — while the *public* header (`zzdds.h`) declares `zzdds_DomainParticipantConfig`
(and every nested config struct) **without** `_toml_applied` at all, matching only the
IDL-declared fields. Every C/C++/Java caller builds a value using the header's (smaller, no
`_toml_applied`) layout; the exported function then reads/writes through it as the larger Zig-native
layout, and `factoryGetDefaultParticipantConfig`'s own `config.deinit(std.heap.c_allocator)` step
(called on the caller-supplied struct before overwriting it, per its own "must be zero-initialised
or c_allocator-owned" caller contract) ends up freeing through garbage field offsets.

Likely introduced in "Config File Improvements" (#54), which added `_toml_applied` to
`DomainParticipantConfig` and *also* added `get_default_participant_config`/
`set_default_participant_config` in the same PR — `create_participant_ex` itself predates that PR
(existed at `v0.2.0-zig.0.16.0`) and was very likely fine before it; #54 silently broke it for
every non-Zig caller without anyone noticing, since nothing exercised the cross-language path
until now.

**Blocks real functionality today**: any C/C++/Java caller passing a non-default
`DomainParticipantConfig` to any of these three operations is affected, not just the
`fragment_size` case that found it. The workaround used for `-Z`/`--periodic-announcement` in
`c/shape`/`cpp/shape`/`java/shape` (route through `zzdds_process_configure_from_file` — a plain
path string, no struct crossing — instead) sidesteps this specific gap but means those three ports
can't compose `--config` with `-Z`/`--periodic-announcement` in the same run (documented in each
port's own `--help`); `zig/shape` and `dds-rtps`'s own port aren't affected (pure-Zig callers,
never cross the C ABI) and do compose them.

**Not fixed here** — needs a real design decision, not a quick patch: either (a) make the C-ABI
codegen pass aware of `_toml_applied` and include it in the public header/struct too (changes the
public ABI), or (b) give `--zig-generate-toml-config` types a genuinely separate C-ABI-facing
struct that excludes internal-only bookkeeping fields, with an explicit conversion step at the
C-ABI boundary (more machinery, keeps the public header unchanged). Whoever picks this up should
start from `test/c_abi/bootstrap_test.zig`'s existing
`"support factory: get_default_participant_config on a custom-allocator factory doesn't mismatch
the caller's c_allocator-owned input"` test — it already exercises this function but only with a
pure-Zig-constructed `ZZDDS.DomainParticipantConfig{}` (correct layout), so it never had a chance
to catch this; a real regression test needs to go through the actual C-ABI struct shape a C/C++/Java
caller would build.

**Update (2026-08-20), confirmed via a dedicated example, not just inspection**: built
`zzdds-examples`' `participant-config` example (all four bindings) specifically to reproduce this
end-to-end — see `zzdds-examples/docs/design/participant-config-reference-app.md` for the full
writeup. Confirms this is genuinely **one root cause across all three non-Zig bindings**, not
three separate ones: `zzdds_jni.c`'s generated JNI glue is itself plain C, compiled against the
same public `zzdds.h` header C/C++ build against (not a separate, JNI-only struct shape as
originally suspected) — so Java crosses into the identical broken exported symbol with the
identical layout mismatch, just surfacing differently (a hard segfault inside
`zzdds_DomainParticipantConfig_free`'s `StringSeq.deinit`, called as `set_default_participant_
config`'s own JNI-wrapper post-call cleanup) than C/C++'s clean `RETCODE_OUT_OF_RESOURCES` failure
(a garbage string length making `DomainParticipantConfig.clone()`'s allocation fail rather than
crash). Also confirmed the same string-layout half of this bug (independent of `_toml_applied`,
see below) is real via a standalone C probe against `DDS_TopicBuiltinTopicData_free` — not
zzdds.idl-specific, and not yet confirmed per-operation for
`get_matched_publication_data`/`get_matched_subscription_data` specifically (same struct family,
inferred not yet individually reproduced; see the `discovery` example, not yet built).
`participant-config` is written to become the fix's regression test once this lands — right now
its programmatic-mode assertion is expected to fail/crash on `c`/`cpp`/`java`, and does.

**Fixed (2026-08-20), in zidl, released in `v0.3.7-zig.0.16.0`**: implemented option (b) above — zidl's
Zig backend (`src/backend/zig.zig`) now generates a genuinely `extern struct`-compatible "C-ABI
mirror" type (`{Name}CAbi`) for any struct that needs one (has `_toml_applied` added by *this*
invocation, or contains an unbounded string anywhere in its field tree), laid out to exactly match
what the `-b c` backend independently emits for the same IDL struct: unbounded strings as
`?[*:0]const u8`, `@optional` scalars stored as bare values gated by a `_present: u64` bitmask
(mirroring the C backend's own bit-assignment order), everything else unchanged. Generated
`{Name}FromCAbi`/`{Name}ToCAbi`/`{Name}CAbiFree` conversion functions convert between the mirror
and internal representations at the C-ABI boundary, allocating/freeing via `std.heap.c_allocator`.
`cApiExportTypeRef` (the exported-wrapper-facing type resolver) now points operation params/
returns at the mirror type instead of the internal one; `emitCApiOp` converts mirror↔internal
around the vtable call; the standalone per-struct `_free` export (`emitStructCApiFree`, generated
independently of `emitCApiOp` — the last bug found here, via a real SIGSEGV traced with `gdb bt
full` to `zzdds_DomainParticipantConfig_free` → `StringSeq.deinit`) now routes through the mirror
too. A cross-file subtlety: a struct declared in a different IDL file than the one setting
`--zig-generate-toml-config` must not be mirrored on that flag alone, since it's never walked by
this invocation's own `emitStruct` — fixed via a `toml_applied_structs` set populated only when
`emitStruct` itself adds the field.

Verified end-to-end against the real, previously-crashing repro: `zzdds-examples`'
`participant-config` programmatic mode now prints `Config round-trip OK: ...` and completes a full
3-sample reliable pub/sub exchange cleanly on **all three** previously-broken bindings (`c`, `cpp`,
`java`), rebuilt against a local zidl checkout with the fix. `zig build test` in both zidl and zzdds
pass clean, no leaks.

**Released (2026-08-20)**: zidl `v0.3.7-zig.0.16.0` (zidl PR #41) ships this fix, plus two rounds of
Greptile review findings fixed in the same PR before merge — see the dedicated entry below for the
full list. `zzdds/build.zig.zon` now pins that release (bumped from `v0.3.6-zig.0.16.0`); rebuilt
and re-verified `participant-config` against the real pinned release (not just a local checkout) on
all four bindings, still passing.

**Update (2026-08-20) — `dcps.idl` half also verified**: built `zzdds-examples`'
`discovery` example (all four bindings) specifically to exercise `get_discovered_topic_data`/
`get_matched_publication_data`/`get_matched_subscription_data` (the three `dcps.idl` operations
sharing the string-layout half of this bug, independent of `_toml_applied` — see the standalone
C probe against `DDS_TopicBuiltinTopicData_free` noted above). All three now round-trip correctly
on `c`/`cpp`/`java`, confirming the mirror mechanism generalizes with no extra per-struct handling
needed — re-verified against the real released `v0.3.7-zig.0.16.0`, not just the local checkout
used when this was first found. One pre-existing, unrelated flake found
while verifying `java/discovery`: `on_reliable_reader_ready` intermittently never fires on the
publisher side under back-to-back JVM startups in this sandbox (~2/7 runs) — A/B tested against
`java/participant-config` (no discovery calls, already known-good) at a similar failure rate on
fresh domains, confirming it's pre-existing Java handshake timing flakiness, not a regression from
this fix or the new example. See `zzdds-examples/docs/design/discovery-reference-app.md` for the
full writeup.

---

## Real zidl bug found and fixed: Java JNI `@optional` scalar marshaling crashed the JVM,
never previously exercised (2026-08-20)

Found in the same `-Z`/`--datafrag-size` rollout above, one step before the ABI bug: the *first*
call to `get_default_participant_config` from Java crashed immediately, inside
`zzdds_UdpConfig_from_java` (a `jni_CallIntMethod` on what turned out to be a NULL `jmethodID`).
Root cause, in zidl's Java backend (`src/backend/java.zig`, `StructMarshalGenerator`, the generator
behind every QoS/status/config struct's `_from_java`/`_fill_java` JNI glue — distinct from the
regular CDR-serialization generator, which already had correct `@optional` handling and has its
own passing tests): `emitMemberFromJava`/`emitMemberFillJava`'s `.scalar` case never checked
`m.annotations.is_optional` at all, always emitting the plain-primitive `GetMethodID(cls, "get_x",
"()I")`/`CallIntMethod` pattern — but an `@optional` scalar's real Java getter/setter is boxed
(`Integer`/`Short`/...) per `memberJavaType`, so `GetMethodID` silently fails to find a match and
returns NULL, and the next call dereferences it. Only reachable via `UdpConfig`'s five `@optional`
port/participant-id fields (the only `@optional` scalars anywhere in `dcps.idl`/`zzdds.idl`) —
never hit before because nothing had ever exercised this specific generator's output for a struct
with an `@optional` member from Java specifically.

Fixed with a boxed-aware branch mirroring the existing seq-scalar boxing pattern already used
elsewhere in the same file (`unboxMethodName`/`jniAccessorName`/`boxedClassName`, all pre-existing
helpers) plus the `_present` bitmask read/write (`out->_present |= (1ULL << bit)` /
`in->_present & (1ULL << bit)`), threading a running per-struct optional-bit-index counter through
`emitStruct`'s two member loops the same way the C backend's `optBitIdxForMember` already does.
Scoped deliberately to the `.scalar` shape only (matching what's actually declared in the IDL
today) — a `@optional` string/nested/seq member would need the same treatment extended to its own
branch, not implemented since nothing exercises it yet.

**Also found and fixed along the way, in the same generator**: `descriptor()`'s (`javaFieldDescriptor`)
return value was never freed at any of its four call sites in this generator (`.scalar`/`.enum_`/
`.nested_struct` in `emitMemberFromJava`, `.scalar` in `emitMemberFillJava`) — a real, live
allocator leak, confirmed via `testing.allocator` once this session's new regression test became
the *first* test to make `StructMarshalGenerator` emit a struct body (not just an `extern`
declaration) for a struct with a plain scalar member. Fixed with `defer self.alloc.free(desc)` at
each site.

New regression test: `"java: @optional scalar struct member gets boxed-type JNI marshaling in
StructMarshalGenerator"` (`src/backend/java.zig`) — constructs a standalone struct+interface pair
(not the real `zzdds.idl`, to isolate the generator), asserts the boxed descriptor strings and
`_present` bit are actually emitted. **Released in zidl `v0.3.7-zig.0.16.0`**, bundled into the
same PR (#41) as the C-ABI mirror-struct fix above — `zzdds/build.zig.zon` now pins that release.

---

## `-Z`/`--datafrag-size` rolled out to every `shape` port; `--periodic-announcement` was
silently broken everywhere, now genuinely wired (2026-08-20)

Follow-on from `docs/design/dds-rtps-interop-suite-audit.md`'s top action item (`dds-rtps`'s own
zzdds `shape_main.zig` port was missing `--datafrag-size`/`-Z`, present in `srcC`). Added there
first, then checked (per the audit's own framing: zzdds-examples' four `*/shape` ports are all
independently-maintained copies of the same CLI surface) whether the same gap existed in
`zig/shape`, `c/shape`, `cpp/shape`, `java/shape` — it did, in all four, so fixed all four the same
session rather than leaving three of four ports behind.

**Found in the process: `--periodic-announcement` has been a silent no-op in all five ports since
before this session**, not just `dds-rtps`'s port. Every one of them tried to set it via
`setenv("ZZDDS_PARTICIPANT_ANNOUNCEMENT_PERIOD_MS", ...)` before creating the factory — but
`src/config/resolve.zig`'s own module doc has explicitly disclaimed env-var-based config since
"Config File Improvements" (#54): *"Env vars are deliberately not part of this at all... An
application that wants env-driven tweaks can read them itself and mutate the resolved struct."*
Nothing in `zzdds` has read `ZZDDS_PARTICIPANT_ANNOUNCEMENT_PERIOD_MS` (or any env var) for
config purposes since then — confirmed via a real crash-free-but-silently-ineffective run before
the fix, and a real crash-free-and-effective run after. Fixed everywhere by routing through the
same real mechanism now used for `-Z` in each port (see below), replacing every dead `setenv`
call site.

**`dds-rtps`'s zig port and `zig/shape`** (pure-Zig, never cross the C ABI): a new
`dds.ParticipantOptions{ fragment_size, announcement_period_ms }` (documented in `dds-rtps`'s
`srcZig/dds.zig` vendor-agnostic contract) threaded into `createParticipant`, which builds a
`ZZDDS.DomainParticipantConfig` and calls `create_participant_ex` directly — safe here since it's
a pure-Zig call. `zig/shape`'s version additionally starts from
`get_default_participant_config`'s result (not a bare `.{}`) so it correctly composes with its
existing `--config` flag; `dds-rtps`'s port has no `--config` to compose with, so uses the simpler
`.{}`-literal start (also required to stay compatible with the `v0.2.0-zig.0.16.0` zzdds tag
`dds-rtps` pins, which predates `get_default_participant_config`/`set_default_participant_config`
entirely — confirmed against that tag's own `idl/zzdds.idl`).

**`c/shape`/`cpp/shape`/`java/shape`**: given the ABI bug above, none of these originally used
`create_participant_ex` at all — each wrote a small generated TOML file (just the
`[default_participant_config.rtps] fragment_size`/`[default_participant_config.participant]
announcement_period_ms` keys actually needed) and loaded it via `zzdds_process_configure_from_file`
(the same real API `c/shape`/`cpp/shape`'s pre-existing `--config` already used, and `java/shape`'s
`--config` *should* have been using — see below), the only one of the three extension operations
that takes a plain path string with no struct-crossing risk. `-Z`/`--periodic-announcement` and
`--config` were mutually exclusive in these three ports as a result (documented in each `--help`,
clear error if combined) since `zzdds_process_configure_from_file` can only run once per process
and merging arbitrary user TOML with a generated override wasn't worth building for an example.

**Update (2026-08-20) — simplified now that the ABI bug is fixed**: with the C-ABI mirror fix
verified (see below), the temp-file workaround is gone from all three ports — they now call
`create_participant_ex`/`get_default_participant_config` directly, exactly matching `zig/shape`'s
own composition logic (start from the factory's already-resolved default, reflecting `--config` if
any, then override just `fragment_size`/`announcement_period_ms`). `-Z`/`--periodic-announcement`
and `--config` compose correctly in all five ports now, no more mutual-exclusivity restriction.
Verified with a real built binary per port: all three print `Create topic:`/`Create writer for
topic:` with `--config`+`-Z`+`--periodic-announcement` combined in one run, no crash, no
`RETCODE_OUT_OF_RESOURCES` — re-confirmed against the real released `v0.3.7-zig.0.16.0` after
`zzdds`'s pin bump, not just the local checkout used while this was being written. A stray
`fdopen()` return-value check missing from the (now-deleted) temp-file code was also caught and
fixed before deletion, for the record.

**`java/shape` also got two independent fixes along the way**: its `--config` flag previously
worked around a missing JNI binding by staging the chosen file as `./zzdds.toml` (backup/restore
dance via a shutdown hook) since "no `zzdds_process_configure_from_file` JNI wrapper exists yet"
per its own MVP-note comment — closed for real by adding
`ZzddsRuntime.configureFromFile(String)` (`java_runtime/ZzddsRuntime.java`+
`zzdds_java_runtime.c`, a thin wrapper around `zzdds_process_configure_from_file`, no struct
crossing), which `--config` now also uses directly, deleting the staging workaround entirely.
Separately, `java/shape/build.py`'s `javac` classpath was missing the generated `io/zzdds/ext`
package (`hello_world`/`waitset`'s own `build.py` already include it) — harmless until any `shape`
change needed an `io.zzdds.ext.*` type, which this one did; fixed to match its sibling ports.

All five ports verified with a real built binary: `--help` text, an out-of-range `-Z` value
correctly rejected, a real participant created successfully with `-Z`/`--periodic-announcement`
set (individually and, where supported, together with `--config`), and the plain no-flags path
unaffected. Cross-process wire-level fragmentation behavior (two real processes actually
exchanging a `DATA_FRAG`-fragmented sample) could not be verified in this session's sandbox — UDP
multicast SPDP discovery doesn't work here at all, confirmed as a pre-existing environment
limitation via an identical baseline failure with no flags involved, not something introduced by
this change.

---

## Writer Liveliness Protocol (WLP) implemented (2026-08-19)

`DomainParticipant.assert_liveliness()` / `DataWriter.assert_liveliness()` previously only
updated local timestamps and never emitted RTPS wire traffic — a remote reader holding a finite
MANUAL_BY_PARTICIPANT or MANUAL_BY_TOPIC lease had no way to learn about an explicit assertion
unless the app also happened to write real data (found via Greptile review on the liveliness
notify-on-alive PR). Fixed with the real RTPS 2.5 §8.4.13 mechanism, not a workaround:

- `src/discovery/builtin_endpoint.zig` (new): `BuiltinPair`, a shared abstraction for RTPS builtin
  endpoint pairs matched by well-known EntityId (bitmask-gated matching + entity-ID dispatch).
  Extracted because SEDP already hand-duplicated this pattern internally across its
  publications/subscriptions pairs, and WLP would otherwise have been a third hand-rolled copy —
  XTypes and DDS-Security will each add more builtin endpoint pairs later and should build on this
  instead of re-deriving the pattern again. `SedpEndpoints` was refactored onto it first (pure,
  behavior-preserving refactor, verified against its own existing test suite unchanged) before WLP
  was built as a thin consumer. Deliberately does *not* cover SPDP (stateless/multicast,
  structurally different) or the wire codec (each protocol's payload shape differs too much for a
  shared codec to be a good fit).
- `src/discovery/wlp.zig` (new): `WlpEndpoints`, the `BuiltinParticipantMessageWriter/Reader` pair.
  Shares SEDP's metatraffic unicast listener rather than opening a second one on the same port
  (`SedpEndpoints.setWlpDispatch`) — the transport doesn't support two independent listeners on one
  port. Handles AUTOMATIC and MANUAL_BY_PARTICIPANT liveliness kinds via `ParticipantMessageData`
  (two orthogonal instances keyed by participantGuidPrefix+kind), driven periodically by
  `participant.zig`'s existing `checkTimers()` tick (`Discovery.Vtable.wlp_tick`) rather than a new
  thread, matching §8.7.2.2.3's literal algorithm (AUTOMATIC: periodic broadcast; MANUAL_BY_PARTICIPANT:
  periodic *check*, send only if asserted since the last check).
- MANUAL_BY_TOPIC is explicitly excluded from WLP by the spec (§8.4.13.5) — handled separately via
  an on-demand unsolicited Heartbeat with the RTPS LIVELINESS flag set
  (`StatefulWriter.sendLivelinessHeartbeat`, `AliveEvidence.manual_heartbeat`), the flag bit having
  already been parsed on receive but never set on send or consumed downstream before this.
- Deliberate simplifications, both noted in code: `BuiltinParticipantMessageReader` defaults to
  RELIABLE unconditionally (spec allows BEST_EFFORT via an extra SPDP `builtinEndpointQos` flag,
  not implemented); AUTOMATIC's send period uses `lease/3` floored at 100ms (spec only requires
  "faster than the smallest lease," no concrete divisor mandated).
- Found and fixed a real bug while writing the real-wire regression test (`test/dcps/wlp_loopback_test.zig`,
  two genuine `UdpTransport` participants, not a `DirectDiscovery`/`ManualClock` shortcut — those
  bypass WLP's wire mechanism entirely): the MANUAL_BY_PARTICIPANT periodic-check driver initially
  read `DataWriterImpl.liveliness_last_ns`, which `checkTimersFn`'s own lease-expiry self-check
  *also* resets (to rate-limit `on_liveliness_lost` to once per lease) — an unrelated side effect
  that made WLP see a false "just asserted" reading once per lease period with zero application
  activity, keeping remote readers alive forever regardless of whether `assert_liveliness()` was
  ever called. Fixed with a dedicated `wlp_last_assert_ns` field updated only by genuine
  write()/dispose()/unregister_instance()/assert_liveliness() calls, confirmed via the same
  regression test failing when reverted.

---

## Phase 33: dds-rtps Interop Validation — Complete

All four vendors were verified at 48/48 in Phase 33 CI. RTI Connext had one
intermittently failing run that was green after re-run; treated as a test-infrastructure
flake, not a wire issue.

*Completed in Phase 33:* self-interop CI job (48/48, gates release), zenzen vs zenzen
100%, FastDDS bidirectional 48/48, OpenDDS bidirectional 48/48, RTI Connext 48/48,
Cyclone DDS 48/48 on all non-CFT cases (`Cft_0` / `Cft_1` are
`SUB_UNSUPPORTED_FEATURE` in Cyclone's own shape_main — test-infra gap, not a zzdds
wire issue).

---

## WaitSet / condition example (2026-08-09/10) — all four bindings done

A new `zzdds-examples` example (`zig/waitset`, `cpp/waitset`) exercising `WaitSet`
and all four condition types (`GuardCondition`, `StatusCondition`,
`ReadCondition`, `QueryCondition`) together on one `WaitSet`, per-binding.
Found and fixed a cluster of real bugs, none reachable before because
nothing could construct a `WaitSet` through any binding until now.

**`WaitSet`/`GuardCondition` C-ABI + Zig-native construction — Done.**
`zzdds_create_waitset()`/`_with_allocator()`, `zzdds_create_guardcondition()`/
`_with_allocator()`, `zzdds_destroy_waitset()`/`_destroy_guardcondition()`,
and `zzdds_waitset_is_nil()`/`_guardcondition_is_nil()` added to
`src/c_abi/extensions.zig`/`zzdds_c.h`, mirroring `zzdds_create_factory()`'s
existing hand-written-bootstrap pattern exactly (both interfaces have no
factory operation in `dcps.idl` — per OMG spec, both are app-instantiated
directly). `zzdds.createWaitSet(alloc)`/`createGuardCondition(alloc)` added
to `src/raw_ops.zig` for pure-Zig callers, matching `registerTypeSupport`'s
existing shape. New `nil_waitset`/`nil_guardcondition` sentinels added to
`src/dcps/nil.zig` (previously didn't exist — nothing had ever needed a nil
fallback for either type). C++: `zzdds::create_waitset()`/
`create_guardcondition()` added to `zzdds_cpp.hpp` — thin `WaitSetSupport`/
`GuardConditionSupport` subclasses over the generated
`::DDS::WaitSetImpl`/`::DDS::GuardConditionImpl` adding the C-ABI teardown
call their `= default` destructors don't make (same reasoning as
`DomainParticipantFactorySupport`); no `--cpp-impl-override` needed since
`zzdds.idl` doesn't extend either interface. Verified past "compiles" at
every layer: `nm -D` confirms all new C-ABI symbols export; a standalone C
program and a standalone C++ program each do a real construct → attach →
trigger → `wait()` → detach → destroy cycle against the real built library.

**Real, live bug: condition/entity lifecycle safety — Done.** Before this,
`StatusConditionImpl`/`ReadConditionImpl`/`QueryConditionImpl` were freed
unconditionally by their owning entity/reader's teardown with no regard for
whether a `WaitSet` still had them attached, and `WaitSetImpl.deinit()`
never unregistered itself from conditions it still held — either direction
left a dangling pointer live in the other object. Never exercised before
because nothing could construct a `WaitSet` through any binding. Fixed
symmetrically in `src/dcps/waitset.zig`: a condition's own `deinit()` now
calls `WakeupList.invalidateAll()` before freeing itself, so every attached
`WaitSet` drops it from `conditions` instead of being left dangling;
`WaitSetImpl.deinit()` now calls a new `unregisterFromCondition()` (shared
with `vtDetach`) for every still-attached condition before freeing itself,
so a condition that outlives its `WaitSet` doesn't keep a stale
`WakeupHandle`/`DataNotifyFn` either. `ReadConditionImpl`/
`QueryConditionImpl` also gained a `remove_condition_fn` callback so a
reader's new `read_conditions` tracking list (added so `delete_datareader`
can safely tear down any conditions the app never explicitly deleted) stays
correct whether a condition is destroyed via `delete_readcondition()` or a
direct `.deinit()` call on the handle — both are valid in this codebase.
Found via getting a real crash, not by inspection, at every step: the first
version of the condition-side fix alone immediately crashed the *existing*
test suite (`WaitSetImpl.deinit()`'s own missing half of the fix, found by
the crash, not predicted in advance). New `test/dcps/waitset_lifecycle_test.zig`
covers both directions with real entities (not stub vtables) via
`IntraProcessDelivery`, including a genuine concurrent-access stress test
(background thread cycling `wait()` while the main thread repeatedly
creates/attaches/deletes real writers). `zig build test`/`test-tsan` both
green throughout.

**Real, live bug: `QueryCondition` deleted via its spec-correct `ReadCondition`
upcast corrupts memory — Done.** Found while adding
`zzdds.takeWithQueryConditionRaw` (below): `delete_readcondition(qc.as_ReadCondition())`
— the *only* spec-correct way to delete a `QueryCondition` through
`DataReader.delete_readcondition`, whose parameter type is `ReadCondition` —
dispatched through `ReadConditionImpl.deinit()` on `&qc.rc`, the `rc` field
*embedded inside* the larger `QueryConditionImpl` allocation, calling
`alloc.destroy(self)` on it as if it were its own separate heap allocation.
Confirmed via a real `DebugAllocator` "allocation size does not match free
size" crash. Fixed with a new `owner_qc: ?*QueryConditionImpl` back-pointer
on `ReadConditionImpl`, set only for the embedded `rc`; its `deinit()` now
checks this first and delegates to the real owner's `deinit()` instead of
destroying itself.

**Real, live bug: `WaitSetImpl.vtWait`'s two-pass count-then-fill loop races
against a condition's trigger value changing between passes — Done.** Found
via a real crash under real concurrent load (a `GuardCondition` set from a
background "watchdog" thread while `wait()` ran on another thread — exactly
the concurrency pattern this whole example was built partly to exercise):
`index out of bounds` writing into a buffer sized from the first
(*counting*) pass's result, once the second (*filling*) pass found MORE
triggered conditions than the first pass counted, because a condition's
trigger flipped in between. Fixed by collapsing the two passes into one,
appending to a growable `std.ArrayListUnmanaged(DDS.Condition)` and calling
`get_trigger_value()` exactly once per condition per `wait()` attempt — a
single pass can't observe cross-pass inconsistency. Separately,
`GuardConditionImpl.trigger` itself was a plain `bool` read/written with no
synchronization at all from what's explicitly meant to be an
arbitrary-application-thread-signaled field (`set_trigger_value`) — a
genuine data race independent of the two-pass bug, fixed by making it a
`std.atomic.Value(bool)` (acquire/release). Verified via a real crash
reproduction (C++ example, before the fix) and clean re-runs after (Zig and
C++ examples, both under plain builds and TSAN, 5+ consecutive runs each
with no crash/race).

**Real, live zidl bug (C++ backend): `WaitSet.attach_condition`/
`detach_condition`'s generated `Condition`-parameter `dynamic_cast` cascade
never included `ReadConditionImpl` — fixed in zidl.** See zidl's own
roadmap "C and C++ backends" for the full writeup — `collectBaseImplementors`
incorrectly reused `entity_base_ifaces` (a set scoped for a narrower,
unrelated question) to decide which interfaces are valid cascade
candidates, wrongly excluding `ReadCondition` even though `ReadConditionImpl`
is a real, independently-constructible class returned as-is by
`create_readcondition()` whenever the app doesn't ask for a
`QueryCondition`. Confirmed via a real crash
(`std::invalid_argument("zidl: incompatible entity implementation for
DDS::Condition")`) attaching a plain `ReadCondition` to a `WaitSet`.

**Real, live zidl bug (Zig backend): a `sequence<EntityInterface>`
typedef's C-ABI `_free` function used the wrong element size — fixed in
zidl.** See zidl's own roadmap "Zig backend" for the full writeup —
`DDS_ConditionSeq_free` (and every other `sequence<EntityInterface>`
typedef's generated free function) called the native `.deinit()`, which
frees using the *native* 16-byte `{ptr,vtable}` fat-pointer element stride —
correct for `ConditionSeq` values built directly in Zig, but every instance
a C/C++/Java caller actually holds (e.g. `WaitSet.wait()`'s own out-param)
was boxed to one 8-byte opaque pointer per element by the existing
entity-sequence C-ABI adaptation before ever crossing the ABI. Confirmed via
valgrind on a real crash (`munmap_chunk(): invalid pointer`, every single
call, not a rare race) inside a real `WaitSetImpl::wait()` C++ call — the
first real exercise of `wait()`'s C-ABI output path with actual attached
conditions since the entity-sequence boxing fix (`v0.3.2-zig.0.16.0`) shipped.

**Known, deliberately-not-fixed-yet gap: `WaitSet.wait()`/`get_conditions()`'s
returned `Condition` objects don't recover their original concrete type in
C++ (and, unverified, likely C/Java too), breaking identity comparison
against the originally-attached concrete handle.** Found while building
`cpp/waitset`: the generated C++ `WaitSetImpl::wait()`/`get_conditions()`
always wrap each returned element via `::DDS::ConditionImpl::_getOrCreate`
(the *base* interface's own default concrete class) — unlike entity
*parameter* adaptation (`attach_condition`'s own cascade, just fixed above),
there's no attempt to recover a more-derived candidate
(`GuardConditionImpl`/`StatusConditionImpl`/`ReadConditionImpl`/
`QueryConditionImpl`) on the *return* path. Since each condition-family
interface's C-ABI handle is independently cached per-*view*
(`GuardConditionImpl.gc_c_abi` vs `.cond_c_abi`, e.g. — see
`src/util/c_abi_handle.zig` and each condition impl's own fields in
`waitset.zig`), a `Condition` returned from `wait()` can never be
`std::shared_ptr`-identity-equal to (or `dynamic_pointer_cast`-recoverable
as) the concretely-typed shared_ptr the application originally attached,
even though both refer to the same underlying condition. `cpp/waitset`
works around this by branching on each held condition's own
`get_trigger_value()` directly instead of matching `wait()`'s returned list
— a legitimate, spec-compliant alternative, not a hack, but real
applications following the more common "iterate `active_conditions`" idiom
would hit this. A real fix needs either an output-path implementor cascade
mirroring the existing input-path one (determining which concrete class a
bare `DDS_Condition` handle was *really* boxed from isn't information the
handle alone carries — would need a runtime "what interface is this"
tag/query, or unifying per-view C-ABI handle caching so every view of the
same object boxes to the same address) — a real design question, not a
mechanical fix; out of scope for this round. Zig-native code is unaffected
(`zig/waitset` compares native `{ptr,vtable}` values directly, no boxing
involved) — this is a C-ABI-crossing-specific gap.

**Decision recorded (2026-08-12) — Phase 1 implemented the same day. See zidl's roadmap
"Binding design review: decision" for the full writeup, including the real implementation
trail (bugs found in hand-written C-ABI code the codegen sweep couldn't reach, the
`QueryConditionImpl` thunk-vtable resolution, and verification detail).** Root cause was the
per-view `CachedCAbiHandle` split named above (`gc_c_abi`/`cond_c_abi`, e.g.), not the C++
output path specifically — same root cause reachable at the raw C-ABI level too (see the
Python spike finding just above). Fix: a second, boxing-only `CAbiViews` indirection struct
per (`@shared_c_abi_box`-annotated) interface, nested per primary base via `extern struct`
offset-0 composition, letting a concrete impl collapse to one `CachedCAbiHandle` field
instead of one per view — no output-path cascade needed; `wait()`/`get_conditions()`'s
existing dispatch already returns the right box for free once boxing is unified at the
source. `QueryConditionImpl`'s embedded-`rc`-field pointer wrinkle (its `ReadCondition`/
`Condition` views now box `&qc`, not `&qc.rc`) is resolved via new thunk vtables safe to call
with `ctx = *QueryConditionImpl`. A real, C-ABI-level regression test (not just native Zig
dispatch) proves the fix in `zzdds/test/c_abi/bootstrap_test.zig`. Topic's `TopicDescription`
secondary-base view remains explicitly out of scope, permanently — no reported bug there and
the fix doesn't generalize to secondary bases.

**Phase 2 — Done (2026-08-12, same day).** Extended to every other entity impl
(`DomainParticipant`/`Publisher`/`Subscriber`/`DataWriter`/`DataReader`/`Topic`/
`TopicDescription`/`ContentFilteredTopic`/`DomainParticipantFactory`) plus, by deliberate
decision at the start of this pass, the `ZZDDS.*` vendor-extension layer (`zzdds.idl`'s
`DomainParticipantFactory`/`DomainParticipant`/`Topic`/`DataWriter`/`DataReader`) and
`nil.zig`'s nil-entity sentinels (never touched by Phase 1 — a real, crash-confirmed gap,
not just a theoretical one, once anything downstream started calling `unboxAsView` on a nil
handle). See zidl's roadmap "Binding design review: decision" Phase 2 entry for the full
implementation trail: a real zidl bug found and fixed along the way (cross-module
`@shared_c_abi_box` annotations were silently discarded by the IR builder's import fill
pass, the same class of bug `.bases` had already needed a similar carve-out for), the
`FactoryOwner`-vs-`DomainParticipantFactoryImpl` distinction (two genuinely different
objects, not one with extra views — collapsing them would have been a correctness bug, not
a fix), and a second real C-ABI-level regression test proving the fix across the full
3-level `Entity <- DataReader <- ZZDDS.DataReader` chain, including the dcps.idl/zzdds.idl
module boundary.

**The "unverified, likely C/Java too" above is now verified for C (2026-08-12),
via `zzdds-examples/spikes/python/` — see zidl's roadmap "Binding design review"
section for the full cross-language context.** Confirmed directly with `ctypes`
against the raw C-ABI, independent of any wrapper-caching layer (Python's probe
has none — a `DDS_Condition` handle is just a bare `c_void_p`): a `GuardCondition`
handle and its own `DDS_GuardCondition_as_DDS_Condition(gc)` view are two
genuinely different pointer values (confirmed, not assumed), and `get_conditions()`
returns exactly the *second* one, never the raw `GuardCondition` handle. So the
gap is real at the C-ABI level itself, not a C++-`_getOrCreate`-specific artifact
— it affects every binding using the plain opaque-handle model (C, and by the
same mechanism Go/Rust/Haskell's spikes, all of which pass raw handles with no
wrapper cache of their own), not just C++'s richer wrapper layer. One useful,
previously-unstated nuance found in the same check: comparing against the
*correctly-cast* view (`DDS_GuardCondition_as_DDS_Condition(gc)`, called once and
held) rather than the native-typed handle (`gc` itself) **does** match
`get_conditions()`'s result cleanly — `CachedCAbiHandle`'s "same view, asked for
repeatedly, gets the same box" guarantee holds correctly; the break is
specifically in comparing *across* views (native type vs. base type), not a
general loss of identity. A viable application-level (and C-ABI-only, no
per-language plumbing needed) workaround already exists — cast your own held
handle to the base view once and compare against that — but it's opt-in
knowledge, not automatic, matching this entry's own "real applications following
the more common iterate-`active_conditions` idiom would hit this" concern.

**`c/waitset` — Done, confirms the prediction below.** Ported straight from
`zig/waitset` once the C++ fixes above landed, using the same "check each
condition's own `get_trigger_value()` directly" pattern as `cpp/waitset`
(not confirmed C shares the identity gap that motivated it there, but
consistent either way). Built and ran clean on the very first attempt — no
new root-cause bugs, confirming the C-ABI/Zig-core fixes found via
`cpp/waitset` were the shared bottleneck. Verified the same way as the Zig
and C++ ports: 4+ consecutive clean runs, valgrind (0 errors, 0 leaks), and
a manual `-fsanitize=thread` build (no races).

**`java/waitset` — Done. `ZzddsRuntime.createWaitSet()`/`createGuardCondition()`/
`destroyWaitSet()`/`destroyGuardCondition()` added to `java_runtime/ZzddsRuntime.java`/
`zzdds_java_runtime.c`, mirroring `createFactory()`'s cached-jclass/jmethodID
bootstrap pattern exactly** (`WaitSetImpl`/`GuardConditionImpl`'s generated
Java classes already existed — nothing on the generated-entity side was
missing, only the bootstrap). `destroyWaitSet`/`destroyGuardCondition` are
new relative to the C/C++ pattern this mirrors: unlike `DomainParticipant`,
entity interfaces have no `deinit()` exposed as a callable Java method at
all, so — like the C/C++ layers needing `zzdds_destroy_waitset`/
`_guardcondition` — Java needed its own explicit destroy path too, or a
`WaitSet`/`GuardCondition` would have no way to be released from Java at
all.

**Real, live zidl bug (Java backend): `getFieldFromCdr` was a `return null;`
stub for a keyless topic — fixed in zidl.** See zidl's own roadmap "Java
backend" for the full writeup — the keyless-topic `--generate-zzdds-wrappers`
branch (added when that flag was extended past keyed structs) never called
the real field-extraction generator, only the keyed-struct branch did,
silently breaking `QueryCondition`/`ContentFilteredTopic` filtering for
every keyless topic in Java — confirmed live via `WaitsetSample` (keyless,
matching `hello_world`'s own convention). The C and C++ backends don't share
this gap; both call their own equivalent unconditionally. Confirmed fixed
via a real, minimal, targeted check (not just golden-diff): serialized a
real value to CDR bytes by hand and called the generated
`getFieldFromCdr(payload, "priority")` directly before and after the fix.

Built and ran clean on the first real run — no new root-cause bugs beyond
the `getFieldFromCdr` one above, consistent with `c/waitset`'s own
"confirms the prediction" note (the C-ABI/Zig-core fixes found via
`cpp/waitset` were the shared bottleneck for the two lower-level bindings;
Java's own remaining gap was backend-local and specific to it). 4 consecutive
clean runs. TSAN not attempted for Java — JVM+TSAN is a known-hard
combination in general (see this roadmap's existing TSan+Connext-flaky
precedent); left for Phase 7 (CI) to scope explicitly rather than assumed
here.

**All four bindings (`zig/waitset`, `cpp/waitset`, `c/waitset`,
`java/waitset`) done.** Five real bugs found and fixed across zzdds/zidl in
total (condition/entity lifecycle safety, the `QueryCondition`-via-
`ReadCondition`-upcast double-free, the `vtWait` two-pass race +
`GuardConditionImpl.trigger` data race, the C++ `dynamic_cast` cascade gap,
the `sequence<EntityInterface>` `_free` size mismatch, and the Java
`getFieldFromCdr` keyless-topic stub — six, actually, by final count). One
deeper design gap (condition identity doesn't round-trip through `wait()`'s
C-ABI boxing in C++, and by extension probably C/Java) is documented, not
silently worked around. The cross-binding smoke test
(`interop/waitset_cross_binding_smoke_test.py`) and CI TSAN coverage
(`examples-tsan` job in `zzdds/.github/workflows/ci.yml`, covering
`zig/waitset` and `cpp/waitset` since this landed, `c/waitset` added
2026-08-12) are both done — not planned work anymore. `java/waitset` is
deliberately left out of TSAN CI (JVM+TSAN is a known-hard combination, see
that job's own comment). The condition-identity gap itself, plus other
inheritance/C-ABI-boxing tradeoffs noticed while chasing it, are recorded as
a not-yet-started review item in zidl's own roadmap — see zidl's "Binding
design review: interfaces vs. impls, inheritance, and C-ABI identity"
section for the full writeup; not duplicated here.

---

**`take_w_condition` family + other typed reader/writer spec gaps closed
(2026-08-10).** Follow-on from the WaitSet/condition example above: the race
fix to `zig/waitset`'s subscriber (two independently-locked take calls
racing incoming data) raised the question of why the other three bindings
never had a real `take_w_condition` to hit the same race with in the first
place. Answer, confirmed against the DDS 1.4 spec directly: the entire
`read_w_condition`/`take_w_condition`/`read_next_instance_w_condition`/
`take_next_instance_w_condition` family was missing from every binding's
generated typed DataReader, plus several smaller gaps (batch
`read_instance`/`take_instance` for C/C++/Java; `get_key_value`/
`lookup_instance` and most of `register_instance`/`write_w_timestamp`/
`dispose_w_timestamp`/`unregister_w_timestamp` missing from Java
specifically; `register_instance_w_timestamp` missing everywhere). New zzdds
core: `DataReaderImpl.takeNextInstanceFiltered`/`readNextInstanceFiltered`
(`src/dcps/reader.zig`) — instance *selection* itself now respects the
condition's masks/query per spec, not just "the next instance with any
sample," extending `takeFiltered`/`readRaw`'s existing `maybe_qc` support
rather than needing new filter-evaluation logic. New C-ABI:
`zzdds_take_w_condition_raw`/`zzdds_read_w_condition_raw`,
`zzdds_take_next_instance_w_condition_raw`/
`zzdds_read_next_instance_w_condition_raw`,
`zzdds_take_n_instance_raw`/`zzdds_read_n_instance_raw` (`src/c_abi/
bootstrap.zig`) — all additive, no existing exported signature changed. Java
also gained genuinely new JNI native methods (`java_runtime/ZzddsRuntime
.java` + `zzdds_java_runtime.c`), not just codegen, since several of these
had no underlying capability there at all before. Full writeup (the spec
audit table, per-backend gap breakdown, and the explicit loan-variant
exclusion) lives in zidl's own roadmap under "Typed DataReader/DataWriter
spec completeness" — not duplicated here. All four `zzdds-examples/
{zig,c,cpp,java}/waitset` subscribers now use the real generated
`take_w_condition` uniformly; verified via `zig build test`/`test-tsan`,
Valgrind on the new C-ABI tests, and the full 8-pair cross-binding smoke
test.

---

**New C ABI export: `zzdds_cft_match_sample` (2026-08-06).** Found while
porting every remaining "stretch" CLI flag from `zig/shape` to `c/shape`/
`cpp/shape`/`java/shape` in zzdds-examples, specifically `--cft`: zzdds's own
internal ContentFilteredTopic filtering (`reader.zig`'s `cft_filter`) only
activates when `TypeSupport.get_field` is wired up, which none of
`zzdds_register_type_support`/`_ctx` (the only registration path every
C-ABI-based binding uses) ever sets — confirmed already true for Zig's own
`dds_impl.zig` earlier, but until now C/C++/Java had no way to invoke
zzdds's own filter parser/evaluator (`filter.zig`) themselves either, so the
only alternative would have been reimplementing the SQL-subset filter
grammar three separate times in three languages. Added `zzdds_cft_match_sample`
(`src/c_abi/extensions.zig`, declared in `zzdds_c.h`) instead: takes a
`DDS_ContentFilteredTopic` handle plus a `ctx`+field-getter-callback pair
(mirroring `filter_mod.FieldAccessor`'s shape) and calls
`ContentFilteredTopicImpl.matchSample` directly. `c/shape`/`cpp/shape` use it
via the plain C callback; `java/shape` gained a matching JNI native method
(`ZzddsRuntime.cftMatchSample`, `java_runtime/zzdds_java_runtime.c`) that
upcalls into a small Java `FieldAccessor` interface per field lookup. Real
unit test added (`extensions.zig`'s new `test "zzdds_cft_match_sample..."`)
constructing a real CFT and checking both a matching and non-matching
sample, not just a smoke call.

**Root-cause fix: `TypeSupport.get_field` now wired for every binding — automatic
CFT filtering, `zzdds_cft_match_sample` no longer required (2026-08-07).**
The entry above shipped a workaround (`zzdds_cft_match_sample` + per-app
manual re-check) rather than the real fix; this closes the actual gap.
`TypeSupport.get_field`'s signature gained the same `ctx: *anyopaque` first
parameter `compute_key_hash` already had (`src/dcps/participant.zig`), plus
a caller-supplied `scratch: []u8` buffer so a matched string value can be
copied out rather than returned as a pointer into a callback-local
deserialized value (the same dangling-pointer class as the
`data_representation` bug below) — see `filter.zig`'s new `CdrFieldGetter`/
`ScratchPool`. `zzdds_register_type_support`/`_ctx` (`zzdds_c.h`) gained a
`get_field_fn` parameter wired into the same per-registration adapter
`compute_key_hash_fn` already uses. zidl's Zig/C/C++ backends now generate
`getFieldFromCdr`/`_get_field_from_cdr` per topic struct (full deserialize,
not a selective parse — a filter expression can reference any simple-typed
member, not just `@key` ones); the Java backend generates a
`getFieldFromCdr` static method, resolved by `ZzddsRuntime.
registerTypeSupport` and invoked through a new JNI trampoline
(`zzdds_java_get_field_from_cdr_ctx`). All four `*/shape` ports' manual
`zzdds_cft_match_sample`/`cftMatchSample` re-check workarounds are deleted;
`--cft` now filters automatically at the reader layer, verified end-to-end
(cross-process, real UDP discovery) for all four. `zzdds_cft_match_sample`/
`ZzddsRuntime.cftMatchSample` themselves are kept, not deleted — documented
as a fallback for a type with no `get_field`/`getFieldFromCdr`, or for
testing an already-deserialized sample outside a live `DataReader`.

Java also needed an unrelated, narrower fix to unblock `create_contentfilteredtopic`
itself (separate from filtering activating): zidl's Java backend never
generated JNI marshaling for a bare `sequence<T>` used as an operation's own
parameter (only nested inside a struct member) — `expression_parameters:
StringSeq` hit exactly that gap, as did `create_multitopic`/
`get_discovered_participants`/`get_discovered_topics`. Fixed generally (a
new `SeqParamMarshalGenerator` in `java.zig`, plus refactoring
`paramIsSupportedValueStruct`/the cross-file-reference collector), not
special-cased to one operation.

**Real bug: `data_representation` QoS re-matching read a dangling pointer
after the entity that offered/requested it was created (2026-08-06).** Found
via the same stretch-flag work above, specifically `-x 2` (XCDR2)
intermittently failing to match even when both a writer and reader
correctly declared `[XCDR2_DATA_REPRESENTATION]` — confirmed via a live
repro (add debug prints at `writerQosSnapshot`/`readerQosSnapshot`'s call
sites; the *first* call at entity-creation time read the correct value,
a *later* call — triggered by matching against a newly-discovered remote
peer — read garbage). Root cause: `DomainParticipantImpl.pubCreateProtoWriter`/
`subCreateProtoReader` stored their `qos: DDS.DataWriterQos`/`DataReaderQos`
parameter into the `active_writers`/`active_readers` registry by shallow
value — for the one sequence-typed field added for XTypes support
(`data_representation.value`), that copies the buffer *pointer*, not the
bytes. The caller (in the C/C++ bindings' case, a C-ABI call originating
from a short-lived stack-local QoS struct) only guarantees that buffer valid
for the duration of the original `create_datawriter`/`create_datareader`
call; a later QoS re-check reads freed memory. `partition_names` already had
an identical bug fixed for it long ago (`dupePartitionNames`) — this was the
one QoS sequence field added since that didn't get the same treatment.
Fixed in `src/dcps/participant.zig`: clone `data_representation.value` into
zzdds-owned storage before storing it in `ActiveWriter`/`ActiveReader`, freed
at every teardown path `partition_names` already frees at
(`pubDestroyProtoWriter`/`subDestroyProtoReader`, and the participant-level
`deinit` sweep for any writers/readers that outlive their own `delete_*`
call). `zig build test` and every affected example binding (C, C++, cross-
binding against each other) re-verified clean after the fix.

**C ABI: plain-struct CDR functions (`_serialize`/`_deserialize`/`_skip`/`_default`) were
declared in `dcps.h` but not linkable from `libzzdds.so` — fixed in `build.zig`, blocked
on a zidl release before it actually takes effect.** Found while porting zzdds-examples'
`hello_world` to C (2026-08-04): `DDS_DataWriterQos_default` and its siblings for every
plain (non-entity) struct in `dcps.idl` — QoS policy structs, `SampleInfo`,
`PublicationMatchedStatus`, etc. — were declared in the installed header but had no body
anywhere in `libzzdds.so`. Root cause: `gen_dcps_c` generates `dcps.h` + `dcps_cdr.c` from
`dcps.idl`, installs `dcps.h`, but never added `dcps_cdr.c` as a source file to
`zzdds_lib` — the entity/vtable half of the C ABI (`create_topic`, `create_datawriter`,
...) is separately hand-integrated via zidl's `--generate-c-api` native-Zig path and *is*
correctly exported, which is what masked this. `DDS_DataWriterQos_free` was exported for
the same reason (native path); `_serialize`/`_deserialize`/`_skip`/`_default` weren't,
because they only ever existed in the uncompiled `dcps_cdr.c`. Confirmed nothing in
zzdds's own test suite exercised this either — `c_smoke_mod` only compiles its own
generated smoke type's CDR file, never `dcps_cdr.c`.

Naive fix attempt (just compile `dcps_cdr.c`/the `zzdds.idl` extension's own generated
`.c` into `zzdds_lib`) doesn't work as-is: confirmed via a real build, not by inspection —
25 duplicate-symbol link errors, one per QoS/status/config struct with a sequence field.
Every one of them is `_free`: the native `--zig-generate-c-api` path already exports
`_free` for these exact structs (see above), and it's the *only* function that overlaps —
`_serialize`/`_deserialize`/`_skip`/`_default` really were cleanly absent, confirmed by
the fact that removing just `_free` from the mix cleared every error. Landed as a new
zidl C-backend flag, `--c-no-free` (suppresses `{Type}_free()` prototype+body for a whole
generation pass), used on a **second, separate** `-b c --generate-interfaces` pass over
`dcps.idl`/`zzdds.idl` whose `.c` output is what's compiled into `zzdds_lib` — the
existing pass (unchanged, no `--c-no-free`) still produces the installed `dcps.h`/
`zzdds.h`, which correctly keeps declaring `_free` (it's real, just implemented
natively). One pass can't serve both purposes: the header must keep declaring `_free`,
the `.c` compiled into the `.so` must not redefine it.

Verified past the point of "compiles": `nm -D` confirms `_default`/`_serialize`/
`_deserialize`/`_skip` are now exported and `_free` is still exported exactly once (native
path, unchanged); `zig build test`/`test-bindings` all green including the Java
`on_reliable_reader_ready` smoke test; and a standalone C program serializing +
deserializing a real `DDS_DataWriterQos` (encap header written explicitly via
`zidl_cdr_write_encap`, matching how the generated topic wrappers already do it) round-
trips correctly with no crash, matching content. (First attempt at that standalone
verification skipped the encap-header step and both truncated and segfaulted on
`ZidlCdrReader`'s implicit `pos` starting at 4 — a bug in the throwaway test, not in the
fix; recorded here so it isn't mistaken for a real regression if rediscovered.)

**Active as of `v0.3.4-zig.0.16.0`** (the pin `zzdds`'s `build.zig.zon` currently resolves
to, bumped past `v0.3.1-zig.0.16.0` in PR #59/#60) — `--c-no-free` is understood by the
pinned zidl and this fix takes effect on a normal `zig build -Dc-binding=true`; no local
checkout needed. Recorded here at the time as "not active yet" against the then-current
`v0.3.1-zig.0.16.0` pin; left unresolved this long only because nothing revisited it after
the pin moved.

**C++ ABI: `create_datawriter`/`create_topic` couldn't return zzdds's own extended entity
classes — fixed in `build.zig` + `zzdds_cpp.hpp`, active as of `v0.3.4-zig.0.16.0`.** Also
found via the `hello_world` C++ port: the natural C++ idiom
for reaching `set_listener_ex`/`as_topic_description`
(`static_pointer_cast<zzdds::DataWriterImpl>(dw)`) was undefined behavior, because
`PublisherImpl::create_datawriter` (zzdds's own generated `dcps_impl.cpp`) always
constructed the base `DDS::DataWriterImpl`, never zzdds's own extended
`zzdds::DataWriterImpl` — confirmed by reproducing a segfault through a corrupted vtable,
not just by inspection.

Fixed using zidl's new `--cpp-impl-override`/`--cpp-impl-include` flags (see zidl's
`docs/roadmap.md` "C and C++ backends" for the generator-side mechanism), wired in
`build.zig`'s `gen_dcps_cpp_impl` invocation, pointing four interfaces at four new
hand-written `zzdds::detail` classes in `include/zzdds_cpp.hpp`: `DDS::Topic` →
`TopicSupport`, `DDS::DataWriter` → `DataWriterSupport`, `DDS::DataReader` →
`DataReaderSupport`, `DDS::DomainParticipant` → `DomainParticipantSupport`.
`DomainParticipantFactory` doesn't need an override — it already has its own working,
unrelated construction path (`zzdds::create_factory()` →
`detail::DomainParticipantFactorySupport`, hand-written, never goes through another
entity's factory method).

Each `*Support final : public zzdds::*Impl` class **composes** (not inherits) a private
`DDS::*Impl dds_` member and delegates every inherited base-interface method to it —
mirroring `DomainParticipantFactorySupport`'s pre-existing shape exactly. Composition, not
inheritance, because `zzdds::*Impl` (generated from `zzdds.idl` alone, via
`--cpp-generate-impl`) is abstract: entity interfaces don't get cross-module operation
flattening, so it only implements the *new* zzdds-specific methods (`set_listener_ex`,
`as_topic_description`, ...) — the inherited base ones (`write`, `dispose`, ...) are left
unimplemented, and multiple-inheriting both would create a genuine diamond on `DDS::Topic`
et al. since no virtual inheritance exists anywhere in the generated hierarchy.

**A subtlety found only by getting a real link/compile error, not by inspection**: each
`*Support` class also needs its own `friend DDS_Topic zidl_concrete_handle(const
TopicSupport&) noexcept { return self.dds_.native_handle(); }` overload (and equivalents
for the other three). Without it, ADL finds the *base* class's `zidl_concrete_handle`
friend (inherited from `zzdds::TopicImpl`, returning the zzdds-extension handle type, not
the base `DDS_Topic` handle `dcps_impl.cpp`'s call sites need) — a more-derived friend of
the same name in the `*Support` class itself wins overload resolution via exact-match
preference once added.

Verified past "compiles": zzdds's own `zig build test`/`test-bindings` (Java smoke test,
`cpp_allocator_smoke`, ...) green with no regressions; `cpp/hello_world` in
zzdds-examples now uses the natural C++ OO path with zero raw-C-ABI workarounds (removed);
full 6-pair cross-binding matrix (C++↔Zig, C++↔C, C++↔Java, both directions each) passes
on real UDP discovery, distinct domains per run.

**Active as of `v0.3.4-zig.0.16.0`** — same as the C ABI fix above: `--cpp-impl-override`/
`--cpp-impl-include` are understood by the pinned zidl and this fix takes effect on a
normal `zig build`; no local checkout needed. Recorded here at the time as "not active
yet" against the then-current `v0.3.1-zig.0.16.0` pin.

**C ABI naming: `zzdds_register_type_support_c`/`_ctx_c` renamed to
`zzdds_register_type_support`/`_ctx`, active as of `v0.3.4-zig.0.16.0`.** Found by
inspection while reviewing the `hello_world` examples for rough edges (2026-08-05): these
were the *only* two functions in all of `zzdds_c.h` with a `_c`
suffix — every other function (`zzdds_create_factory`, `zzdds_write_raw`, ...) has none,
despite being equally C-ABI. Not a meaningful marker, just an inconsistency; the suffix
also leaked into generated code, since zidl's C and C++ backends both hardcode a call to
`zzdds_register_type_support_c` by that exact name inside generated
`<Type>TypeSupport::register_type` / `<Type>_register_type` (`c.zig`/`cpp.zig`). Renamed
in `src/c_abi/typesupport.zig`, `zzdds_c.h`, and the two zidl backend call sites, plus
every doc/comment/test referencing the old names. Pin has since moved to
`v0.3.4-zig.0.16.0`, which emits the renamed call — verified against a local zidl
checkout in the meantime (`zzdds`'s own `zig build test`/`test-bindings`, plus all three
of `c/hello_world`, `cpp/hello_world`, and `java/hello_world` in zzdds-examples, built and
run standalone).

**Longer-term direction, not just this one flag list**: zidl's roadmap also records a
"pull implementation-specific codegen decisions into implementation-owned plugins"
direction — in practice, this means zzdds eventually owns a set of zidl plugins (one per
binding it ships) that supply exactly this kind of "which concrete class implements
interface X" policy, instead of zzdds's `build.zig` hand-listing `--cpp-impl-override`
flags and zidl core slowly accumulating more zzdds-shaped flags over time. Not started;
the flag-based mechanism above is intentionally being built to be pluggable-into later
(a plugin could emit the same flags programmatically), not superseded by it.

**Zig-native TypeSupport registration ergonomics + a real, live string-cleanup leak fix,
active as of `v0.3.4-zig.0.16.0`.** Found while reviewing the
`hello_world` examples for rough edges (2026-08-06): pure-Zig callers had to downcast
`participant.ptr` to `*DomainParticipantImpl` themselves to call `registerTypeSupport` —
every other binding (C/C++/Java) goes through zzdds's own C-ABI shim
(`zzdds_register_type_support`), which does that exact downcast internally, but nothing
equivalent existed for Zig. Fixed by adding `registerTypeSupport` to `src/raw_ops.zig`
(re-exported from `src/root.zig`), mirroring `registerInstanceRaw`'s existing shape exactly.

Separately, zidl's Zig backend never generated the equivalent of C/C++'s
`{Type}_compute_key_hash_from_cdr` — Zig callers had to hand-write the CDR-deserialize-then-
hash glue. Fixed via a new `computeKeyHashFromCdr(ctx: *anyopaque, payload: []const u8)
[16]u8` generated per topic struct (see zidl's roadmap "Zig backend" for the codegen side).
Unlike C (which resolves its allocator from a global, process-wide override defaulting to
malloc/free), this stays consistent with the rest of the Zig runtime's explicit-allocator
idiom: `ctx` is a `*const std.mem.Allocator`, supplied by the caller at registration time.

**While verifying this, found a real, live memory leak — not hypothetical, already
shipping**: zidl's Zig backend's `deinit()`/`clone()` generation only ever counted
unbounded *sequences* as needing cleanup, never plain unbounded `string`/`wstring` fields
(outside `--zig-generate-toml-config`) — a narrower version of a bug zidl already found and
fixed for the C backend (see zidl's roadmap "C backend: `{Type}_free()` is declared but
never given a body"), just never ported to Zig. Confirmed live in `dcps.idl` itself:
`TopicBuiltinTopicData`/`PublicationBuiltinTopicData`/`SubscriptionBuiltinTopicData` all
have plain unbounded `string name`/`type_name`/`topic_name` fields that `deinit()` (and
therefore the C-ABI `DDS_*BuiltinTopicData_free()` zzdds ships) silently never freed.
Fixed in zidl's `zig.zig` (see its own roadmap entry for the full design, including why a
member with a non-empty `@default` string needed a careful, narrow exclusion to avoid
trading a leak for a worse bug — freeing static string-literal storage). Verified against
real generated code: `TopicBuiltinTopicData.deinit()` now frees `name`/`type_name`; `zig
build test`/`test-bindings` (Java smoke test, `cpp_allocator_smoke`) green with no
regressions; a standalone test confirmed `computeKeyHashFromCdr` on a real keyed struct
with a variable-length key field no longer leaks.

**Active as of `v0.3.4-zig.0.16.0`** — same as the other zidl-flag-dependent fixes above:
`computeKeyHashFromCdr` and the widened cleanup are in the pinned zidl release.
`registerTypeSupport` (the `raw_ops.zig` addition) has *no* zidl dependency and was live
regardless of the pin from the start.

**Zig-native `setListenerEx` ergonomics — same gap, same fix shape as `registerTypeSupport`
above, no zidl dependency.** Found continuing the same `hello_world` review (2026-08-06):
`zig/hello_world` and `zig/shape` (zzdds-examples) both reached `set_listener_ex`
(`DataWriterListenerEx::on_reliable_reader_ready`) by downcasting `writer.ptr` straight to
`*DataWriterImpl` — the same category of gap `registerTypeSupport` closed, just for a
different call. C's C-ABI equivalent (`DDS_DataWriter_as_zzdds_DataWriter`) and Java's
(`ZzddsRuntime.asZzddsDataWriter`) both do a real vtable-identity check instead; Zig had
neither, even though the check itself already existed internally in
`c_abi/extensions.zig`, just never exposed.

Added `asZzddsTopic`/`asZzddsDataWriter`/`asZzddsDataReader`/`asZzddsDomainParticipant` to
`raw_ops.zig` (re-exported from `root.zig`), matching the C-ABI family of four (the fifth,
`DomainParticipantFactory`, doesn't need one — pure-Zig callers get it directly from
`zzdds.createFactory()`, never losing the type). Each does the same vtable check as its
C-ABI sibling and returns the properly-typed `zzdds.*` interface value (not a raw impl
pointer) — required making `participant_vtable`/`topic_vtable`/`writer_vtable`/
`reader_vtable` `pub` in `c_abi/extensions.zig` so both sides reference the same canonical
vtable instances rather than a second, address-distinct copy. No zidl dependency at all;
live today regardless of the pin. `zig/hello_world`/`zig/shape` (zzdds-examples) and
dds-rtps's own zzdds `shape_main` port all updated to call `zzdds.asZzddsDataWriter(dw)`
instead of downcasting.

Verified: new `raw_ops.zig` unit tests (real participant/topic/writer/reader through the
upcast, `set_listener_ex` actually called on the result; plus a negative case against the
nil sentinel) — `zig build test` 945/945, `test-bindings` green. `zig/hello_world`,
`zig/shape`, and dds-rtps's `shape_main` all rebuilt and run standalone (and, for the shape
ports, cross-binding against each other) over real UDP discovery with correct output.

**Found and fixed along the way: a standing Zig build-graph bug, not new to this
session.** `zig build` failed outright for `zig/hello_world` *and* `zig/shape`
(zzdds-examples) — and dds-rtps's own zzdds `shape_main` port — the moment `zzdds`'s own
`zidl` dependency was a `.path` dependency rather than a hashed release (exactly the state
needed to test any of zidl's unreleased fixes against a real Zig-native consumer, not just
zzdds's own test suite): `error: file exists in modules 'zidl_rt' and 'zidl_rt0'`. Root
cause: each of those consumers declared its *own*, separate top-level dependency on `zidl`
(to get `zidl_rt` + the `zidl` binary for their own IDL codegen) in addition to depending
on `zzdds`, which *also* depends on `zidl` internally. Zig's package manager doesn't
deduplicate two independent `.path` dependencies on the same directory declared by two
different `build.zig` files, even though they resolve to the identical files — each gets
instantiated as its own module instance, and the build fails the moment any single
compilation unit imports both. Never mattered before because `zzdds`'s own pin was only
ever flipped to a local path transiently, for verification, then reverted immediately.

Fixed by having `zzdds`'s own `build.zig` re-expose its already-resolved `zidl_rt` module
(via `b.modules.put`, reusing the exact same `*Module` instance zidl_dep.module("zidl_rt")`
returns — not a second, address-distinct copy) and the `zidl` executable (moved
`b.installArtifact(zidl_exe)` out of the `need_c_abi`-gated block, now unconditional — a
pure-Zig consumer needing only `zidl_rt` + the binary for its own codegen shouldn't have to
opt into the C/C++/Java binding pipeline to get them) as part of its own public
dependency/module surface. Consumers now get both *through* `zzdds`
(`zzdds_dep.artifact("zidl")` / `zzdds_dep.module("zidl_rt")`) instead of declaring their
own separate `zidl` dependency — guaranteeing only one `zidl` resolution ever exists in the
whole graph. `zig/hello_world`/`zig/shape` (zzdds-examples) and dds-rtps's `shape_main`
`build.zig`/`build.zig.zon` all updated to match; the now-dead direct `.zidl`
`build.zig.zon` entries removed (dds-rtps's pinned copy keeps a comment explaining it's
inert until its own `zzdds` pin is bumped past this fix, same "dormant" pattern as
everything else zidl-dependent in this session).

**DEADLINE/LIVELINESS QoS is now enforced automatically — previously nothing drove it at
all.** Found continuing the same `hello_world`/`shape_main` review (2026-08-06), while
auditing `writerNotifyDeadline`/`readerNotifyDeadline` (two more `dds_impl.zig` downcasts
found alongside `setListenerEx` above): `DomainParticipantImpl.checkTimers()`
(`participant.zig`) already correctly checks every active writer/reader's DEADLINE and
LIVELINESS periods and fires the right notifications — but nothing ever called it outside
tests using a `ManualClock`. `zzdds.createFactory()`'s bootstrap never spawned a timer
thread; `shape_main` (zzdds-examples' `zig/shape` and dds-rtps's own zzdds port) worked
around this by re-implementing its own parallel elapsed-time tracking and manually calling
the lower-level `notifyDeadlineMissed()` hook directly — not an ergonomics problem, a real
gap in automatic OMG-spec-mandated behavior that happened to be visible through the same
kind of downcast as the ergonomics fixes.

Fixed with a per-participant background thread (`DomainParticipantImpl.timer_thread`),
spawned at the end of `start()`, ticking every 100ms (`TIMER_CHECK_INTERVAL_MS`) and
calling `self.checkTimers()`. Not a new threading pattern for zzdds — `writer_sm.zig`
already lazily spawns a per-writer heartbeat thread on first match, `spdp.zig` already
eagerly spawns a per-participant SPDP re-announcement timer, and `UdpTransport`'s receive
threads are already unconditional — all four already-existing background threads follow
the identical "sleep in 50ms chunks checking an atomic stop flag" idiom, which this one
matches. See the new "Background thread usage" entry below for the broader thread-strategy
question this raised.

**Deliberately scoped to *one thread per participant*, not one thread per factory
iterating all its participants — found a real race with the latter before writing any
code, not after.** The first design considered was a single `FactoryOwner`-level thread
walking `stacks` and calling `checkTimers()` on each. Traced the actual teardown path
before implementing: `factory.zig`'s `vtDeleteParticipant` calls `p.deinit()` completely
outside any lock, and `DomainParticipantImpl.deinit()` itself deliberately does **not**
acquire `self.mu` (existing comment: publisher/subscriber teardown re-locks `mu`, so
holding it during `deinit()` would deadlock) — while `checkTimers()` *does* acquire
`self.mu`. A factory-level thread calling `checkTimers()` on a handle grabbed from
`FactoryOwner.stacks` would have no protection against that same participant being
mid-`deinit()` on another thread — a real use-after-free, not a theoretical one. Holding
`FactoryOwner.mu` across the call doesn't fix it either: `checkTimers()` fires listener
callbacks, and a callback calling back into `delete_participant`/`lookup_participant`
would self-deadlock on that same lock (the exact reason `deleteParticipant` already
releases `FactoryOwner.mu` before calling into the inner factory). Scoping the thread to
the participant's own lifetime instead — spawned in `start()`, stopped as the *first* line
of `deinit()`, before anything else is torn down — sidesteps the cross-object lifetime
problem entirely rather than adding new synchronization to work around it, and matches how
`writer_sm.zig`'s and `spdp.zig`'s existing timer threads are already scoped.

Verified past "compiles": `zig build test` (945/945) and `test-bindings` (Java smoke test,
`cpp_allocator_smoke`) green with no regressions. Real, not just unit-tested: rebuilt
`zig/hello_world`'s sibling `zig/shape` example with its own app-side
`writerNotifyDeadline`/`readerNotifyDeadline` calls *removed entirely* (along with the
manual elapsed-time tracking that fed them) and confirmed `on_offered_deadline_missed()`/
`on_requested_deadline_missed()` still fire correctly and repeatedly, unassisted, in both
`zig/shape` and dds-rtps's own zzdds `shape_main` port — plus re-verified the plain-match
and CFT-filtering scenarios from the `setListenerEx` fix still pass unchanged.

**Background thread usage — revisit holistically, not started.** Prompted directly by
adding the DEADLINE/LIVELINESS timer thread above: that's the *tenth* `std.Thread.spawn`
call site in zzdds, and — checked, not assumed — only five of the ten ever block on a
socket (`UdpTransport` recv ×2, `TcpTransport` recv ×2, `TcpTransport` accept ×1). The
other five are pure periodic-tick threads with no socket involved at all: the new
DEADLINE/LIVELINESS thread, `writer_sm.zig`'s per-writer heartbeat, `spdp.zig`'s
per-participant announcement timer, `transport/monitor/polling.zig`'s interface-change
poll, and `trace.zig`'s wire-trace flush. All five already share one idiom (sleep in 50ms
chunks checking an atomic stop flag, so shutdown stays responsive) — that consistency
happened by convention, one thread at a time, not by design.

Worth a dedicated pass to (at minimum) consolidate: do periodic-tick threads need to be
one-per-object at all, or could DEADLINE/LIVELINESS, the interface-change poll, and the
wire-trace flush share a single scheduler thread with multiple registered callbacks,
cutting thread count without changing semantics? (The heartbeat and SPDP timers are more
naturally per-object — heartbeat is lazily spawned only once a writer has a matched
reader, SPDP timing is participant-specific — so consolidating *those* two is a separate,
harder question, if it's worth doing at all.) Beyond consolidation: zzdds has never stated
an overall concurrency strategy — one-thread-per-concern has just been the default every
time a new periodic need came up. Worth deciding deliberately whether that stays the
model, or whether some/all of this should move to Zig's `std.Io` async/evented
abstractions instead (the same `Io` interface `zig/hello_world`'s portable sleep fix
already uses) — and if so, whether that's an outright replacement or a configurable choice
(thread-per-concern vs. a shared event loop) so different deployment targets (embedded/
real-time vs. a normal server process) can pick what fits. Not scoped further than this;
deciding the shape of that choice is the point of picking this up, not something to
pre-decide here.

**Resolved by the `v0.3.4-zig.0.16.0` pin bump (PR #59/#60).** At the time this was found,
`zig build install -Dc-binding=true` (and therefore `-Dcpp-binding=true`/
`-Djava-binding=true`, which imply it) failed outright against the then-pinned
`v0.3.1-zig.0.16.0` zidl release — `build.zig`'s `--c-no-free` pass (the Issue 1 fix, see
above) unconditionally passes that flag to whichever zidl the pin resolves to, and
`v0.3.1` didn't understand it (`error: unknown option: --c-no-free`). This contradicted
this roadmap's own earlier claim that Issue 1 was "dormant" against the pin — that claim
was never actually verified by running the command against a reverted pin, only reasoned
about; confirmed broken by actually running it. Left as a warning for whoever bumped the
pin next, budgeting for the fact that `-D{c,cpp,java}-binding=true` needed a real zidl
release containing `--c-no-free`/`--cpp-impl-override` before it would build at all, not
just before those specific fixes took effect. The pin has since moved to
`v0.3.4-zig.0.16.0`, which contains both flags — `-D{c,cpp,java}-binding=true` builds
clean today.

**C-ABI TypeSupport** — complete. `zzdds_register_type_support` in
`src/c_abi/typesupport.zig` bridges a C function pointer to the Zig `TypeSupport`
vtable via a heap-allocated `CKeyHashAdapter`. Pass the
`<Type>_compute_key_hash_from_cdr` function generated by `zidl -b c` as the callback;
pass `NULL` for keyless types. The `TypeSupport` vtable carries a `ctx: *anyopaque`
field so each registration gets its own adapter closure.

**Static and broker discovery plugins** — `src/discovery/interface.zig` and the config
schema reserve `static` and `broker` discovery kinds, but only SPDP/SEDP and direct in-process
discovery are implemented. Either implement static config loading and broker client support
or remove the advertised config surface before v1.

**MTU-aware fragment sizing** — `rtps.fragment_size` is a static config value today.
Add an interface-MTU/path-MTU aware default that accounts for IP, UDP, RTPS, and future
security overhead, while preserving the explicit override for deterministic tests.

**SEDP-traffic-seen heuristic** — Complete (PR #49). `sedp_seen: bool` added to
`KnownParticipant`, set via `SpdpEndpoints.markSedpSeen` when SEDP receives a
`DiscoveredWriterData`/`DiscoveredReaderData` from a participant. On a genuine (plausibly-spaced,
not same-SN/duplicate) SPDP re-announcement from a participant whose `sedp_seen` is still false,
`processSpdpPayload` sends a targeted unicast retransmit of our own SPDP announcement to that
peer's metatraffic unicast locators, recovering from SEDP packet loss on initial exchange
without waiting for a full announcement period.

**LocatorSelector abstraction — Phase 1 done** (per-proxy ranking; `StatefulWriter`'s
`ReaderProxy` and `StatefulReader`'s `WriterProxy`). `Locator.tier()`
(`src/transport/interface.zig`) classifies loopback/link-local/private/public reachability;
`transport/locator_selector.zig`'s `selectInto` ranks a proxy's own locator set — unicast
list wins over multicast list (unchanged), best reachability tier wins, address family is a
first-in-list tiebreak at equal tier, and same-tier/same-family ties are all kept (preserves
delivery to multi-homed peers, e.g. a reader advertising both a VPN and a LAN address). Each
`ReaderProxy`/`WriterProxy` caches the result in a `selected_locators` field, recomputed only
at construction and moved (not recomputed) on lease refresh — the GUID-scoped amortization
this roadmap item asked for. `effectiveLocators()`'s signature and all 12 call sites (10 in
`writer_sm.zig`, 2 in `reader_sm.zig`) are unchanged.

Filtering out locator kinds the active transport doesn't support, plus the one-time
per-kind debug log, turned out to already be fully implemented upstream of this work
(`discovery/interface.zig`'s `filterReachableLocators`, applied at every SPDP/SEDP
locator-ingestion point via `Transport.canReach()`, with `warnUnsupportedLocatorOnce` in
`spdp.zig`/`sedp.zig`) — not new work, just confirmed and left alone. Address-family
*enablement* (`ipv4_enabled`/`ipv6_enabled`) is enforced at that same upstream layer, not
re-checked by the selector.

Landing this surfaced a real, previously-masked transport bug: with `bind_wildcard=false`
(the default) and an explicit `participant_id` (which bypasses the
`autoAssignParticipantId` reservation-socket path), `UdpTransport` advertised 127.0.0.1 as
a reachable locator (`rebuildLocatorsLocked`'s unconditional loopback-advertise) without
ever binding a socket to it — `active_ifaces` excludes loopback interfaces, so the
non-wildcard per-interface socket loop never created one. Blasting to every locator masked
this (one of the other advertised addresses always had a real listening socket); ranking
that correctly prefers loopback as the best tier exposed it as silent, total data loss.
Fixed in `UdpTransport.vtListen`'s non-wildcard branch by explicitly binding 127.0.0.1
alongside the per-interface sockets, with a regression test (`"non-wildcard bind still
receives loopback traffic"` in `src/transport/udp.zig`).

`StatelessWriter.sendAll()` is intentionally **not** touched in this phase — its
`ReaderLocator` has no unicast/multicast split and is populated by SPDP's already-flattened
locator list; out of scope for the per-proxy ranking design.

Deferred, not precluded by this design:
- **Cross-proxy multicast fan-out grouping** ("N matched readers share a multicast group,
  send once") — needs a writer-level view across the whole matched-proxy set for a send
  event, which a per-proxy `effectiveLocators()` call can't express. Precedent for the
  grouping shape already exists in `src/rtps/protocol_adapters.zig` (`vtTakeEOCProxyInfos`/
  `vtSendCombinedEOCData`, the GROUP coherent-set EOC flush) — natural migration target if
  this is built.
- **NACK-aggregation / delayed-response repair batching** — separate, larger feature;
  `nack_response_delay`/`nack_suppression_duration` don't exist anywhere in the codebase yet.
  Would feed decisions into a future writer-level delivery planner rather than needing
  anything from the selector itself.

**GUID generation platform coverage** — the current fallback paths keep unsupported targets
building, but they are not production target support. For each supported OS, provide real
entropy, PID, and monotonic-clock implementations.

**Participant teardown can take several seconds under live reliability timers** — found
while fixing a real use-after-free (`SedpEndpoints.stop()` wasn't stopping/joining
`pub_writer`/`sub_writer`'s heartbeat threads before `discovery.stop()` returned, so
`DomainParticipantImpl.deinit()` could free participant memory while a heartbeat thread
was still scheduled to fire `onProbeResult` → `onParticipantLost` on it — fixed via a new
`StatefulWriter.stopHeartbeat()`, called from `SedpEndpoints.stop()`). Fixing that
crash exposed a separate, previously-masked issue: teardown can now take on the order of
`beginProbe`'s hardcoded 1-second probe deadline (`spdp.zig`'s `.deadline_ns = now_ns +
1_000_000_000`) per in-flight probe rather than exiting promptly — observed as an
occasional multi-second (not unbounded) delay in `loopback_test`, not a hang. Root cause
not fully chased down (which timer(s) specifically, why shutdown doesn't short-circuit
them) — worth a dedicated look so teardown is fast in all cases, not just crash-free.

*Partially addressed in PR #48 (Parallel Thread Join):* `UdpTransport`'s socket teardown
(`removeSockets`/`removeUnicastSockets`/`deinit`) previously called `SocketEntry.stop()`
(signal-then-join) sequentially per socket, making N bound sockets cost N sequential poll
waits — "previously the dominant cost in participant teardown" per the fix's own comment.
Split into `requestStop()` (signal only) and `joinAndClose()`; every matching socket is now
signaled before any is joined, so teardown cost is one bounded wait regardless of socket
count. The `beginProbe` 1-second-deadline-per-in-flight-probe cause above is a separate,
still-open root cause this PR did not touch.

*Small addition to this same budget (2026-08-06):* the new per-participant DEADLINE/
LIVELINESS timer thread (see "DEADLINE/LIVELINESS QoS is now enforced automatically"
below) adds up to ~50ms to every participant's `deinit()` — its stop flag is checked in
50ms sleep chunks, matching every other timer thread in the codebase, so a `join()` right
after setting the flag can wait that long in the worst case. Negligible next to the
multi-second issue above, but worth naming here so it isn't mistaken for a new mystery
delay if someone's specifically hunting sub-100ms teardown latency later.

**Language bindings** — see `docs/language-bindings.md` for the distribution model
(three-artifact structure, build flags, version coupling). Current status:

- **C ABI (`zzdds_c.h` + `libzzdds`)** — complete. Opaque handle + free-function surface
  generated by `zidl -b c --generate-interfaces`; C export wrappers from
  `zidl -b zig --zig-generate-c-api`; TypeSupport via `zzdds_register_type_support`.
  Build artifacts (`libzidl_cdr.a`, `zzdds.pc`, `zzdds-config.cmake`) installed by
  `zig build install`. See `docs/language-bindings.md` §"C binding API design".
- **C++ binding** — complete. `zidl -b cpp --generate-interfaces --cpp-generate-impl`
  generates `dcps.hpp` + `dcps_impl.hpp/cpp`. Typed topic wrappers (DataWriter/DataReader),
  listener base classes, CDR serialize/deserialize, and out-param QoS adaptation are all
  generated. The 11 method stubs that once remained in `dcps_impl.cpp` (6 `get_listener`,
  2 incompatible-QoS-status, 2 WaitSet, 1 `get_datareaders`) were fixed upstream in zidl's
  "C++ impl TODOs" (#21), which shipped in `v0.2.7-zig.0.16.0` — already included in the
  `v0.2.10-zig.0.16.0` zidl release zzdds currently pins (`build.zig.zon`). Verified against
  a real `zig build install`: the generated `zig-out/src/dcps_impl.cpp` has zero `TODO`
  markers.
- **Java binding** — done; zidl Java backend generates a real entity JNI bridge
  (unbox/box entities, full QoS/status struct marshaling, listener JNI
  upcalls) plus `--generate-zzdds-wrappers` typed DataWriter/DataReader
  classes with inline CDR. Verified with a real two-JVM-process example
  (`zzdds-java-example/`) and an in-process `test-bindings` smoke test.
  Remaining gaps: bare `sequence<T>` params (not inside a struct) on a few
  DCPS ops; `zzdds.idl`'s vendor extensions (cross-file type references
  aren't tracked by zidl's Java backend yet).
- **Python / .NET** — planned; inline CDR; C-ABI layer via ctypes / P/Invoke.
- **Rust** — planned; dual-mode (`pure` via `zidl-rs`; `zig-ffi` for embedded/perf).
  See zidl roadmap for Rust backend steps.

**Configurable allocation for embedded/real-time targets** — full plan, inventory, and
phase ordering now in `docs/design/allocator-strategy.md`; this entry is a summary pointer,
not the source of truth. zzdds has always aimed to let real-time and embedded deployments
supply their own allocation strategy (static pools, slab allocators) rather than being
locked to a default heap, but this hasn't been prioritized as an end-user-facing
configuration surface yet, in zzdds itself or in the generated bindings.

- **Tier 0 — C-ABI bootstrap injection (the actual blocking gap; not previously tracked).
  Done.** Verified by tracing the real allocation path: the Zig core was *already* 100%
  allocator-agnostic (`grep -rn "std\.heap\." src/` found zero hardcoded heap use outside
  `c_abi/` and the tiny fixed nil-singleton bookkeeping in `dcps/nil.zig`) — every object
  inherits `self.alloc` from whatever created it, exactly as Tier 1 below assumed. The gap
  was narrower and more concrete than "make it configurable somewhere":
  `zzdds_create_factory()` (`src/c_abi/extensions.zig`) was the *only* C-ABI bootstrap
  entry point, and its implementation hardcoded `const alloc = std.heap.c_allocator;`
  with zero parameters to override it. Added `zzdds_create_factory_with_allocator(const
  ZidlAllocator *allocator)` (`zzdds_create_factory()` is now a thin `NULL`-passing
  wrapper, preserving compatibility) plus a `zzdds_cpp.hpp` overload; see the design doc
  for the shared `ZidlAllocator` vtable ABI (defined zidl-side, in `zidl-cdr`, and reused
  here — not zzdds's own type) and why the bridging adapter must not itself heap-allocate.
  Verified two ways: a Zig-level test tracking real allocator calls through factory
  bootstrap and participant creation (`test/c_abi/bootstrap_test.zig`), and a standalone
  C++ program compiled/linked against the real built library and run — 83 allocations, 83
  frees, 0 outstanding. This one change was the highest-leverage item in the whole plan:
  because the core already did the right thing everywhere, it unlocks
  allocator-controlled participant/topic/writer/reader lifecycle *and* history-cache
  storage for both C and C++ callers at once, with no further zzdds-side work. Getting a
  real (not just compiled-in-isolation) C++ verification working surfaced four pre-existing
  bugs in zidl's C++ backend (cross-module `native_handle()` resolution, listener
  trampoline wrapping the wrong class, an `_getOrCreate` regression from this session's
  earlier entity-wrapper-identity work, and a scalar-typedef listener parameter
  mismatch) — all fixed; see the design doc and zidl's roadmap for details. In a tagged zidl
  release as of `v0.2.10-zig.0.16.0`, which zzdds now pins (`build.zig.zon`).
- **Tier 1 — structural/bookkeeping** (entity impl structs, and the entity-handle heap-boxing
  implemented on the zidl side — see "Entity handle ABI: heap-boxing" in the zidl roadmap).
  **Done** — see below; the remaining gap this tier originally described (making the
  already-correct `self.alloc` plumbing genuinely end-user-configurable from outside Zig) is
  what Tier 0 above actually closes.
  **Required, not optional**: every concrete impl now needs a `get_c_abi_handle` vtable
  implementation (zidl's generated vtables already declare this slot) that lazily creates and
  *caches* its own C-ABI handle — via `zidl_rt.boxEntity`, using `self.alloc` — reused on every
  subsequent call and freed in that same object's `deinit()`. This isn't just an allocator
  nicety: skipping the cache-and-reuse pattern (e.g. boxing fresh on every call) breaks handle
  identity for accessor operations and leaks a box on every call to a widened-view accessor
  (`get_entity()`, `lookup_topicdescription()`, etc.) — objects that return a widened view of
  themselves or another object need their own cache slot for that view too, freed the same way.

  **Done.** The `get_c_abi_handle` vtable slot shipped in zidl's C-backend opaque-handles
  work (#22), which has been in tagged releases since `v0.2.7-zig.0.16.0` — already included
  in the `v0.2.10-zig.0.16.0` release zzdds currently pins (`build.zig.zon`), no local-path
  checkout needed. A diagnostic build first surfaced 31 compile errors (29× missing `get_c_abi_handle`, 2×
  listener-dispatch sites in `subscriber.zig` needing to box entity args before firing a
  callback); the real implementation found 17 listener-dispatch sites total (writer.zig had
  4 more, reader.zig had ~10 more, matching the predicted pattern) and covers every hand-written
  vtable literal: all ~15 nil sentinels in `nil.zig`, `topic.zig`, `participant.zig`,
  `publisher.zig`, `subscriber.zig`, `reader.zig`, `writer.zig`, `waitset.zig`, `factory.zig`,
  and (once found necessary) `c_abi/extensions.zig`'s own `ZZDDS.*` vtables. A shared
  `CachedCAbiHandle` helper (`src/util/c_abi_handle.zig`) centralizes the lazy-box-and-reuse
  pattern; objects presenting more than one distinct (ptr, vtable) view of themselves (e.g.
  `TopicImpl` as `Topic`, `Entity`, and `TopicDescription`) got one cache field per view.
- **Tier 2 — data-plane** (history cache sample storage; CDR serialize/deserialize scratch
  buffers — the latter is the already-tracked `ZidlCdrAllocator` gap, see the zidl roadmap's
  Known Gaps). Deferred behind Tier 0: since Tier 0 already gives every subsystem one
  shared, caller-chosen allocator, this tier is specifically about wanting a *second,
  separate* allocator for the data plane — a real but strictly-secondary tuning knob, not a
  blocking gap. Don't build ahead of a real request for the split; see the design doc.
- **Tier 3 — per-entity-kind or per-topic overrides** (e.g. distinct pools for readers vs.
  writers). Explicitly deferred — plausible eventually as an optional override on top of
  Tier 1/2's default-from-parent, but not designed; don't build ahead of a real use case.

**C++ generated binding allocator injection** — a separate, harder axis from the tiers
above; full analysis (including a second, previously-untracked allocation surface found
while doing this session's `_getOrCreate` work — the wrapper objects themselves, not just
struct fields) now in `docs/design/allocator-strategy.md`'s "Phase 3/4" and "the C++
template problem" sections. Short version: `std::vector`/`std::string` inside
`--cpp-generate-impl` output use the global allocator unless parameterized, and C++
allocator customization is a compile-time template concern, not a runtime value — it can't
share any of the Tier 0-2 runtime vtable machinery. Three candidate designs identified
(template-parameterize generated types; standardize on `std::pmr::*`; or don't make
generated types allocator-aware at all and push unbounded-field topics toward bounded
types instead), each with different compatibility costs — needs a short design spike
before committing, flagged as the single riskiest item in the allocator plan.

**C++ entity wrapper identity** — Done, zidl-side (see "C++ backend: entity wrapper
identity" in the zidl roadmap for the design and verification). `ConcreteImplGenerator`
used to construct a fresh `std::make_shared<FooImpl>(_h)` on every entity-returning
operation, so e.g. calling `get_topic()` twice returned non-identity-equal wrapper objects
for the same entity (no leak — `shared_ptr` RAII still cleaned up correctly — just no
identity guarantee). Every entity `FooImpl` now has a cache-and-reuse `_getOrCreate` static
factory (`unordered_map<C-handle, weak_ptr<FooImpl>>` + mutex), and all four generation
sites that used to construct a wrapper directly (op return, attribute getter,
sequence-of-entities out-adaptation, listener-trampoline argument wrapping) route through
it. Nothing to do on zzdds's side — zzdds doesn't hand-write its own C++ bindings. In a
tagged zidl release as of `v0.2.10-zig.0.16.0`, which zzdds now pins (`build.zig.zon`).
Verified against zzdds's actual generated
`dcps_impl.cpp` (95 `_getOrCreate` call sites across ~35 entity classes) compiling cleanly
with `g++ -std=c++17 -Wall -Wextra -pthread`, plus a standalone runtime check of the exact
cache pattern confirming identity, expiry, and handle-reuse behavior all hold.

**`as_{Base}` upcast migration** — Done. Also part of zidl #22, in tagged releases since
`v0.2.7-zig.0.16.0` (currently-pinned `v0.2.10-zig.0.16.0` includes it — no local-path
checkout needed). zidl now generates the ~12 DDS-internal upcasts zzdds used to hand-write
(`DDS_Topic_as_DDS_Entity`,
`DDS_GuardCondition_as_DDS_Condition`, ...) plus, discovered mid-migration, the *upcast*
direction of the `ZZDDS.* ↔ DDS.*` conversions too (`zzdds_Topic_as_DDS_Topic` and 4 siblings)
— `zzdds.idl` declares real IDL bases (`interface Topic : DDS::Topic`) that were easy to miss.
Only the downcast direction (`DDS_Topic_as_zzdds_Topic` and siblings, requiring a runtime
vtable-identity check IDL can't express) stays hand-written in `c_abi/extensions.zig`. See
zidl's roadmap ("Zig backend: `as_{Base}` upcast vtable slot") for the generator-side design.

**DDS Security v1.2** — Authentication (PKI-DH), AccessControl, Cryptographic (AES-GCM).
First step: fix `Cryptographic.encode_payload` to use a tagged-union return (see
`docs/design/security-pipeline.md`).

**DDS-XTypes v1.3** — TypeObject/TypeIdentifier/TypeMapping; required for type-safe
cross-vendor type discovery.

**Transport dispatch-snapshot cap** — `UdpTransport` (`PortEntry.dispatch`) and
`TcpTransport` (`dispatchToHandlers`) snapshot registered handlers into a 64-element
stack array before calling them, so dispatch can release the handler lock without
holding it across callbacks. The cap is currently enforced when registering handlers.
64 handlers per port is sufficient for any realistic deployment today (one handler per
participant sharing the transport), but the design should be revisited before the
factory pattern makes it easy to spin up large numbers of participants. Options: a
small inline-storage type that falls back to a heap buffer only when the inline array
overflows (similar to a small-vector), or a two-phase dispatch that re-acquires the
lock between calls with a generation counter to detect concurrent mutations. The goal
is to remove the hard cap without introducing a heap allocation on the common path.

**`register_instance` side-effect optimization** — `zzdds_register_instance_raw`
is currently a pure function (FNV1a of the 16-byte MD5 key hash → `int32_t` handle;
no state stored, no side effects).  A complete implementation would pre-allocate the
instance's history cache entry, pre-warm SEDP discovery state, and enable a
`zzdds_write_raw_kind_w_handle` C ABI variant that accepts a pre-registered
`DDS_InstanceHandle_t` instead of a 16-byte key hash, skipping MD5 key hash
recomputation on the hot write path.  Meaningful for high-frequency writes (100k+/s)
on topics with non-trivial keys (string keys, multi-field keys); negligible for simple
scalar keys at typical sensor/video rates.  The C++ typed wrapper layer (see
`cpp_binding_improvements.md` B2) is already structured for this: it stores the key
hash at `register_instance` time and passes it through to the existing C ABI; when
the C ABI gains a handle-based write path, the wrapper can switch without any
user-visible API change.

**`swapRemove` / `orderedRemove` audit** — several hot paths use `orderedRemove` on
`ArrayListUnmanaged` to delete a single element from the middle of a list, which is O(N) per
call and O(N²) in loops.  The pattern is pre-existing and fine for the small lists seen
today (proxy counts, condition slots), but should be fixed before the codebase scales.  A
sweep of all `orderedRemove` call sites should replace them with `swapRemove` where order is
not semantically required, or with an indexed/hash structure where it is.  Existing tests
should catch any ordering dependency that is accidentally removed.

A specific instance worth addressing: `commitCoherentPendingLocked` in `reader.zig` uses
`coherent_committed.orderedRemove(0)` to pop the oldest committed set from the front of the
queue.  In the common late-join history-replay case where multiple coherent sets accumulate
before the first `begin_access`, each pop is O(N) in the remaining queue depth.  The fix is
to replace `ArrayListUnmanaged` with a head-index (`head: usize`) that advances instead of
shifting, or to use a ring-buffer structure.  Queue depths in practice are small (1–3 sets),
so this is a polish item rather than an urgent fix.

**Condvar-based blocking in setup paths** — `wait_for_historical_data` and any other
setup-time spin-poll (`std.time.sleep` in a retry loop) should be converted to condvar-based
blocking.  The pattern to look for: a loop that sleeps a fixed interval then re-checks a
shared flag.  Each such site should instead hold a `Mutex` + `Condvar` pair; the writer side
signals the condvar when the condition becomes true, and the waiter unblocks immediately
rather than sleeping up to one interval past the event.  `ManualClock`-driven tests in the
existing suite should be extended to cover the condvar path.

**Gap identified 2026-08-12, scoped 2026-08-13 (see the triage entry below) — not yet
implemented: "nearest enclosing non-null listener" fallback (DDS 1.4 §2.2.4.1.5, "Listener
Access to Plain Communication Status") — every entity's listener is fully independent
today.** Found while scoping the
binding-design-review work (see zidl's roadmap "Binding design review" section), not
discovered via a bug report. Per spec, when an entity's communication status changes (e.g. a
`DataReader`'s `on_data_available`), an implementation must invoke the *closest* installed,
non-null listener by walking up the containment hierarchy at the moment the event fires: the
entity's own listener first; if that entity has none installed (or the relevant callback
field is null), the parent's (`Subscriber`/`Publisher`); if that has none either, the
`DomainParticipant`'s. This is why `DomainParticipantListener` widens (via IDL inheritance)
`TopicListener`/`PublisherListener`/`SubscriberListener` into one combined interface — the
same widen-into-one-struct shape already implemented for `zzdds::DataWriterListenerEx`
extending `DDS::DataWriterListener` (see `writer.zig`'s `listener_ex_box`), just one level
higher and spec-mandated rather than a zzdds extension. It is *not* "listener code inherits
behavior" in an OOP sense — it's a runtime search-and-fallback rule the middleware is
responsible for performing; the callback that ends up running still receives the originating
entity (e.g. the `DataReader`) as its argument, even when it's the `Subscriber`'s or
`Participant`'s installed listener object whose code actually executes.

Confirmed unimplemented, not just unverified: grepped `writer.zig`/`reader.zig` for any
fallback-to-parent dispatch when an entity's own listener callback is null — none exists.
Each entity's `listener_box` is used strictly on its own; a `DataReader` with no listener
installed for `on_data_available`, whose `Subscriber` *does* have one installed, will not
have that `Subscriber`'s callback invoked today. This is a real DDS 1.4 conformance gap, not
a design choice recorded elsewhere in this roadmap — worth its own triage (fix vs.
deliberately defer, matching this roadmap's existing style for gaps like `MultiTopic`) rather
than being silently assumed complete. Relevant to, but distinct from, the binding-design C-ABI
review: implementing it later would introduce a new recurring pattern the review should be
aware even if it doesn't need to solve it now — a single physical listener struct (the
`Subscriber`'s, say) being invoked with a *different* entity's handle as its callback
argument (a `DataReader` it doesn't own), which is a new shape of "whose `ctx` is this" question
alongside the ones already catalogued for per-registration listener keepalive.

**Confirmed compatible with the binding design review's decision (2026-08-12), no design
change needed.** See zidl's roadmap "Binding design review: decision" — the listener
keepalive shape decided there keys per-registration, not per-listener-identity, specifically
because one listener object can already be registered on multiple entities today; a single
physical listener struct later serving as the "nearest enclosing" fallback for multiple
child entities is the same case under that same keying rule. This gap's own fix/defer triage
is still zzdds's own to do, independent of the binding review.

**Triage (2026-08-13): scoped, not implemented — smaller and more tractable than "not yet
triaged" suggested, but still a real multi-file change, not a quick patch.** Investigated
the actual dispatch code rather than reasoning from the spec alone, and found the
prerequisites mostly already in place:

- **Size**: ~19 direct `if (box.listener.on_X) |cb| cb(...)` dispatch sites would need the
  fallback treatment — `reader.zig` (12, across `on_data_available`/`on_requested_deadline_
  missed`/etc.), `writer.zig` (5), `subscriber.zig` (2, `vtNotifyDataReaders`'s own
  reader-listener dispatch — a *different* spec operation already doing something adjacent,
  see below). `topic.zig`'s `on_inconsistent_topic` and `subscriber.zig`'s own
  `on_data_on_readers` have **zero** firing sites today — not a fallback gap for those two
  specifically, a *prior*, separate gap (the underlying status detection isn't wired up at
  all yet), worth noting but out of scope here.
- **The hard part — cross-entity access — already has a working precedent in this
  codebase**: `Subscriber::notify_datareaders()`'s implementation (`subscriber.zig`'s
  `vtNotifyDataReaders`) already reaches into each of its `DataReader`s' listener boxes via
  `r.acquireListener()`, a `pub fn` on `DataReaderImpl` built exactly for safe cross-entity
  access (`listener_box.zig`'s `acquireLocked`, called while holding the *reader's* own
  lock, returning a refcounted handle the caller can read/dispatch through after releasing
  it — never holding a lock across the callback itself). The fallback chain needs the same
  pattern one level higher (reader → subscriber → participant, writer → publisher →
  participant) — `SubscriberImpl`/`PublisherImpl`/`DomainParticipantImpl` just need the same
  `pub fn acquireListener()` `DataReaderImpl` already has; nothing new to invent.
- **The other prerequisite — parent back-references — already exists too**: `DataReaderImpl.
  subscriber`, `DataWriterImpl.publisher`, `SubscriberImpl.participant`, `PublisherImpl.
  participant` are all plain fields already, needed for `get_subscriber()`/`get_publisher()`/
  `get_participant()` regardless. No new plumbing.
- **The IDL is already shaped for this**: `DomainParticipantListener : TopicListener,
  PublisherListener, SubscriberListener` and `SubscriberListener : DataReaderListener`/
  `PublisherListener : DataWriterListener` are real widened structs (`dcps.idl`), so every
  level's callback for a given status has the *identical* signature, including which entity
  is passed as the argument (always the originating child, e.g. `on_data_available(the_
  reader)`, never `self`) — no adapter/wrapper struct needed at any level, direct
  field-by-field reuse.
- **Locking is tractable if kept to the same discipline the existing code already uses**:
  acquire-snapshot-release at one level, fully release before moving to the next (never a
  chain of simultaneously-held locks) — matches `acquireLocked`'s own existing contract and
  `vtNotifyDataReaders`'s existing usage of it. This is the one place a fix could go wrong in
  a way this codebase has real scar tissue from (the `WaitSet` release-hook and listener-
  keepalive work earlier in this roadmap both needed careful lock-ordering to get right) —
  worth real test coverage (including a TSan pass, matching this roadmap's existing standard
  for lock-sensitive changes), not worth skipping care on just because the pattern exists.

**Real open questions before implementing (not blocking the triage decision, but blocking
starting the work casually):**
1. Does zzdds actually *prevent* deleting a `Subscriber`/`Publisher`/`DomainParticipant`
   while it still has live children? The fallback's safety assumption ("my parent is always
   valid while I exist") depends on this holding — worth confirming against the real
   `delete_contained_entities`/precondition-check code, not assumed from spec text.
2. Does the fallback need to respect each level's `set_listener(listener, mask)` mask, or
   purely the per-callback-field nullability (this section's current framing)? Real DDS
   implementations aren't fully uniform on this nuance — worth deciding and documenting
   explicitly rather than leaving it implicit, given how often this exact class of "which
   check governs dispatch" subtlety has bitten related work.
3. Worth a shared generic dispatch helper (comptime over the callback field name) instead of
   hand-writing the 3-level check at all ~19 sites? Strongly preferred for maintainability,
   but each `*Listener` struct's callbacks have different signatures (arg counts/types), so
   it's a real small design question, not a given.

**Recommendation: right-sized to schedule as a discrete follow-on, not to fix inline and not
to defer indefinitely.** It's a genuine DDS 1.4 conformance gap with a real, if niche, usage
pattern behind it (installing one participant-level listener as a catch-all instead of one
per entity) — worth doing. It's also a real multi-file, concurrency-sensitive change that
deserves its own focused pass (design the shared helper, answer the two open questions
above, touch ~19 call sites plus 3 new `pub fn acquireListener()`s, test including TSan) —
not something to fold into an unrelated change as a drive-by.

**Done (2026-08-13, same day).** Both open questions above resolved first (see
`docs/decisions.md`'s "Listener hierarchy fallback" entry for the full write-up): (1) zzdds
doesn't enforce the spec's `PRECONDITION_NOT_MET`-on-live-children precondition, but the
parent-alive assumption holds anyway because `delete_subscriber`/`_publisher`/`_participant`
cascade synchronously and never free the parent until every child's own `EntityQuiesce`-
gated `deinit()` returns; (2) the fallback respects each level's own `listener_mask`, not
just field-nullability, at every hop — matching every existing dispatch site's own
pre-existing gating convention applied uniformly instead of only at the origin entity. New
`src/util/listener_fallback.zig` (comptime-over-field-name `tryDispatch`/`peek`) backs
`DataReaderImpl.dispatchListener` → `SubscriberImpl.dispatchReaderFallback` →
`DomainParticipantImpl.dispatchFallback` and the symmetric writer/publisher chain, touching
all ~19 call sites (12 reader.zig, 4 real-status writer.zig sites — `on_reliable_reader_ready`
is a vendor extension with no participant-level equivalent, deliberately excluded — plus
`subscriber.zig`'s `notify_datareaders()` and its coherent-access batch-dispatch path, which
needed its own eager-resolve-then-deferred-fire design to keep the pre-existing
"never hold `subscriber.mu` across a user callback" discipline). Two real bugs found only via
a real crash/test failure, not by inspection: nil-sentinel parent pointers on standalone-
constructed test fixtures (fixed with `nil.isNil(...)` guards at every downcast) and the
status-with-counters call sites' pre-existing `if (fire)` gate still wrapping the whole
block including the new fallback call, silently defeating it whenever the origin's own mask
was clear — fixed by making the whole chain return `bool` ("did anything receive it") and
gating change-counter resets on that instead of the origin's own mask (which also fixed a
latent staleness bug: those sites hardcoded `total_count_change = 1` instead of reading the
accumulated field, previously masked by the old gate always keeping the two in sync). New
regression coverage in `test/dcps/listener_fallback_test.zig` using real two-participant
`IntraProcessDelivery` trees; confirmed to actually catch the bug by deliberately reverting
`dispatchListener` to its pre-fix form once and observing the expected test failures before
restoring. Full `zig build test`/`test-tsan`/`test-bindings` (C/C++/Java) green throughout.

**`WaitSet`-attached-condition release hook — Done (2026-08-12).** The gap this section's
own earlier "no C-ABI-visible signal at all" finding named (a binding relying on
`attach_condition()` implicitly keeping a reference alive gets no error when the condition
vanishes out from under it) now has a real fix: `zzdds_waitset_attach_condition_with_release`
(`src/c_abi/extensions.zig`, declared in `include/zzdds_c.h`), firing a caller-supplied
`release_fn` exactly once whichever way the attachment ends (explicit `detach_condition()`,
the `WaitSet` destroyed while attached, or the condition destroyed while attached). See
zidl's roadmap "Binding design review: decision" for the full implementation trail,
including the lock-ordering subtlety found while designing it (the release callback must
never fire while `WaitSetImpl.mu` is held, since it's arbitrary caller code that must be free
to reentrantly call back into the same `WaitSet`). Not yet wired into any binding's own
wrapper layer — see that section's own "explicitly not done" note.

**`zzdds_cpp.hpp`: hand-written glue joins the C++ shared-family `_getOrCreate` cache —
Done (2026-08-12).** zidl's C++ backend now collapses per-concrete-class `_getOrCreate`
caches into one shared cache per `@shared_c_abi_box` family (see zidl's roadmap "Binding
design review: decision" → "shared-family `_getOrCreate` cache") — but two zzdds-specific
things construct condition/entity wrappers *outside* any generated `_getOrCreate` at all,
so they needed their own changes to actually participate:
- `wrapGuardConditionHandle` (`detail::GuardConditionSupport`'s factory) now registers the
  object it constructs into `::DDS::ConditionImpl::_familyCache()` directly, keyed by
  `DDS_GuardCondition_as_DDS_Condition(handle)`. `GuardCondition` has no factory operation
  in dcps.idl (app-instantiated directly per spec) and so was never wrapped via any
  generated `_getOrCreate` — without this registration, `WaitSet::wait()`'s generic
  `ConditionImpl::_getOrCreate` would still construct an unrelated second object for the
  same handle, even with the shared cache in place on the generated side.
- `TopicSupport`/`DataWriterSupport`/`DataReaderSupport`/`DomainParticipantSupport`
  (zzdds.idl's four `--cpp-impl-override` classes, composing a fully-implemented
  `DDS::*Impl` rather than being constructed through the generated path) had each kept
  their own independent cache, same shape as the bug the generated-code fix closed. Now
  consult/populate `::DDS::EntityImpl`'s shared cache instead, recovering their own
  concrete type via `dynamic_pointer_cast` on a hit — needed for real, not just for
  consistency: `StatusCondition::get_entity()` returns a generic `DDS::Entity`, which could
  be the exact handle behind an app's already-held `zzdds::DataWriter`.

Verified: `zig build test` / `test-bindings` green, a standalone `g++ -c` compile of the
regenerated `dcps_impl.cpp` clean, and `zzdds-examples/cpp/waitset` rebuilt with its
`get_trigger_value()` workaround actually replaced by `wait()`-membership comparison — two
consecutive clean runs, zero `FAIL` lines, including through `GuardCondition` (the case
that specifically required this file's changes, not just the codegen fix).

**`java_runtime/zzdds_java_runtime.c`: `GuardCondition` joins the Java shared box-identity
cache — Done (2026-08-12, later the same day).** zidl's Java backend now gives
`zidl_java_box_<c_name>` a shared native (JNI weak-global-ref) cache per `@shared_c_abi_box`
family (see zidl's roadmap "Binding design review: decision" → "Java backend: native
weak-global-ref box cache") — the exact same "hand-written glue needs to participate too"
gap the C++ side hit above applies here too, for the same reason: `GuardCondition` has no
factory operation in dcps.idl, so `ZzddsRuntime.createGuardCondition()`'s native
implementation constructs its Java object directly, never through any generated box helper.
Fixed by having it call a new `extern`-declared `_zidl_family_DDS_Condition_
register_external` (emitted by zidl specifically for this case) right after construction,
registering itself into the same cache `WaitSet.wait()`'s generic
`zidl_java_box_DDS_Condition` consults. Unlike the C++ side, no `zzdds.idl`-extension
classes needed equivalent treatment — Java has no `--cpp-impl-override`-style hand-written
subclass mechanism; `zzdds.idl`'s own entity types go through the ordinary generated path
(itself only partially covered by the shared cache today — see zidl's roadmap entry on the
cross-file family-root limitation this fix's own bug-fix pass found and worked around, not
solved, for `Entity`'s family specifically).

Verified: `zig build test` / `test-bindings` green (including the Java smoke test), and
`zzdds-examples/java/waitset` rebuilt with its `get_trigger_value()` workaround actually
replaced by `List.contains()` membership checks — two consecutive clean runs, including
through `GuardCondition`'s registration path (the case that specifically required this
file's changes, not just the codegen fix).

**C++/Java wrapper layers now actually use the `WaitSet`-attached-condition release
hook — Done (2026-08-13).** The release hook itself (`zzdds_waitset_attach_condition_
with_release`, above) landed with an explicit "not adopted anywhere yet" caveat; asked to
close that.
- **`zzdds_cpp.hpp`**: `WaitSetSupport::attach_condition()` now uses the hook, holding a
  `shared_ptr<Condition>` keepalive per attached condition in an internal
  `std::unordered_map`, released via the hook's callback. `detach_condition()` didn't need
  an override — the inherited plain one already fires the same release callback, since
  it's the same underlying C-ABI attachment record either way.
- **`java_runtime/zzdds_java_runtime.c`**: no C++-style virtual override available for
  Java, and no `--java-impl-override` codegen mechanism exists for `dcps.idl`-level types
  (only zzdds.idl's vendor extensions have a C++ equivalent of that) — so this hooks in via
  JNI's `RegisterNatives`, overriding `WaitSetImpl`'s generated `n_attach_condition` native
  binding with a hand-written replacement holding a JNI global ref keepalive (a hand-rolled
  native linked list, same shape as the shared box-identity cache above, minus the
  weak-ref part). Registered lazily and exactly once (`pthread_once`) from
  `createWaitSet()`'s native implementation. Completely transparent to app code —
  `WaitSetImpl.java`'s public API is unchanged.

Both verified with real programs exercising actual object-lifetime behavior, not just
compiled: a standalone C++ program using `std::weak_ptr`, and a standalone Java program
using `WeakReference` + `System.gc()`, each observing the wrapper object's own lifetime
directly across four scenarios (survives after the app drops its own reference post-attach,
released on explicit detach, released when the `WaitSet` itself is destroyed while still
attached, no leaked second registration on a redundant re-attach). Both deliberately
re-broken (fix reverted, confirmed the same test fails at the expected assertion, restored)
before being considered verified, matching this whole review's own established discipline
for regression tests.

**`src/c_abi/extensions.zig`: Entity/TopicDescription family checked downcasts — Done
(2026-08-13), required companion to zidl PR #39's Java most-derived-box fix.** zidl's Java
backend generalized its sequence-only `_box_as_most_derived` dispatcher to bare (non-sequence)
entity-typed returns/attributes too (see zidl's roadmap, "PR #39 Greptile review"), which made
`StatusCondition::get_entity()`'s generated JNI bridge call `DDS_Entity_as_DDS_DomainParticipant`/
`_Topic`/`_Publisher`/`_DataWriter`/`_Subscriber`/`_DataReader` for the first time — these are
declared in the generated `dcps.h` (zidl declares a checked narrowing conversion for every
direct edge in an `@shared_c_abi_box` family) but, like the pre-existing `Condition` family
downcasts, zidl's C backend never generates a *body* for them (it has no visibility into which
concrete zzdds struct backs a given vtable) — left undefined because nothing had ever called
them: the only prior caller of this dispatch style was the sequence-only mechanism, exercised
solely by the `Condition` family (`WaitSet::wait()`'s `ConditionSeq`). Caught as an
`UnsatisfiedLinkError: undefined symbol` at `libzzdds_jni.so` load time, not a compile error —
the C-ABI declaration alone was enough to satisfy the generated caller's own compilation.

Fixed by hand-writing the six `DDS_Entity_as_DDS_*` downcasts plus three more for the
`TopicDescription` family (`DDS_TopicDescription_as_DDS_Topic`/`_ContentFilteredTopic`/
`_MultiTopic`, needed for the same reason once that family's own bare-`TopicDescription`
accessors were checked), mirroring the existing `DDS_Condition_as_DDS_*` pattern exactly:
unbox as the base interface view, compare `.vtable` against the concrete impl's own
(newly-`pub`) vtable constant, construct and box the derived view on a match, `null` otherwise.
`DDS_TopicDescription_as_DDS_MultiTopic` always returns `null` — `MultiTopic` is a permanent
nil-only stub in zzdds (no `MultiTopicImpl` exists), so no real handle can ever actually be one.

Verified: `zig build -Dc-binding=true -Dcpp-binding=true -Djava-binding=true install` and
`test-bindings` (all three bindings) clean; a dedicated `JavaSmoke.java` regression check
(`StatusCondition.get_entity()` cast to `DomainParticipant`, `== dpWriter` for identity)
added — see its own comment for why that specific call site is a cache-*hit* sanity check,
not a true miss reproduction. The actual `ClassCastException` scenario (a handle whose
*first-ever* Java-side box goes through the bare `Entity` accessor) was verified separately
with a scratchpad GC/`WeakReference`-forced cache-miss program, deliberately re-broken
(reverted zidl's fix, confirmed `EntityImpl` was returned and the cast threw
`ClassCastException`) and confirmed fixed (`DomainParticipantImpl` returned, cast succeeds) —
not committed to the permanent suite since it's inherently GC-timing-dependent, matching this
repo's existing preference for scratchpad-only GC-based lifetime proofs over CI-committed ones.

**PR #62 Greptile review (2026-08-13) — two real P1 races in `java_runtime/zzdds_java_runtime.c`,
both fixed.** Confidence 3/5, both findings confirmed real and reachable, not speculative.

1. **Keepalive insertion races release.** `zzdds_java_waitset_attach_condition` used to call
   `zzdds_waitset_attach_condition_with_release()` (registering the one-shot native release
   hook) *before* inserting its own bookkeeping node into the JNI-side keepalive list. If a
   concurrent `detach_condition`/condition-invalidate/`WaitSet` destroy fired the release
   callback in that window, the trampoline found no node to remove — and since a release is
   documented (and Zig-side enforced) to fire at most once, the node/global ref inserted
   moments later would never be cleaned up: a permanent JNI global-ref leak (pinning the
   `Condition` object forever) plus a leaked heap node. Fixed by building and inserting the
   keepalive node *before* registering the release hook — a release can only ever be possible
   once the Zig side has stored the hook, which now strictly happens after the node exists, so
   it can never observe a not-yet-inserted node. If the attach call itself then fails, the
   pre-inserted node/global-ref are removed again explicitly (the Zig side never stored the
   hook in that case, so no release will ever come to clean them up naturally).
2. **Shared JNI environment crosses threads.** `zzdds_java_ensure_waitset_natives_registered`
   wrote the calling thread's `JNIEnv` into a plain, unsynchronized global *before* calling
   `pthread_once` — `pthread_once` only guarantees its callback runs exactly once, not that
   it's the same thread that wrote the winning value, so two threads racing into
   `createWaitSet` for the first time could have the once-callback run using a `JNIEnv` from a
   *different* thread than the one that actually won the race — using another thread's
   `JNIEnv` is undefined behavior (can crash or corrupt the JVM). Fixed by having the once
   callback fetch its own `JNIEnv` via `zidl_java_get_env()` (backed by the thread-safe
   `JavaVM*`) instead of trusting a value stashed by a possibly-different thread; the callback
   now takes no `JNIEnv` parameter at all.

Verified: `zig build -Dc-binding=true -Dcpp-binding=true -Djava-binding=true install` and
`test-bindings` (all three bindings) clean.

**Update (2026-08-13, later the same day): a third real P1, found by Greptile's re-review
after the above two landed — confirmed and fixed.** Confidence rose to 4/5 once the first
two were fixed; the remaining finding is a genuine follow-on the fix #1 above didn't close.

3. **Concurrent attachments leak keepalives.** The "already tracked?" check and the node
   insertion were still two separate critical sections (fix #1 above only reordered
   insertion to happen before the release-hook registration *within* a single attach call —
   it didn't make the check-then-insert sequence atomic *across* concurrent calls). Two Java
   threads attaching the SAME condition to the SAME `WaitSet` for the first time could both
   pass the "not yet attached" check before either inserted its node. Both would then call
   `zzdds_waitset_attach_condition_with_release` — but the Zig side
   (`waitset.zig`'s `attachConditionWithRelease`) silently drops a second registration's
   `release_fn`/`ctx` for an already-attached condition rather than replacing the first's
   (documented, intentional — see that function's own doc comment), so the *losing* thread's
   node, JNI global reference, and `ctx` would never be cleaned up by any release: a
   permanent leak. Fixed by merging the check and the insertion into one critical section —
   only the thread that actually wins the mutex race ever observes "not yet attached" and
   inserts; every other concurrent caller for the same pair is guaranteed to observe it as
   already-tracked and takes the existing safe redundant-reattach path instead.

   Verified: `zig build -Dc-binding=true -Dcpp-binding=true -Djava-binding=true install` and
   `test-bindings` clean, plus a scratchpad stress test (200 rounds × 8 threads concurrently
   calling `attach_condition()` on the same freshly-created `GuardCondition`/`WaitSet` pair,
   then a single `detach_condition()`) — no crash, deadlock, or hang across 1,600 concurrent
   attach calls. Not a leak-counting instrument (the bug is a silent reference leak, not a
   crash, so a purely functional stress test can't directly disprove it) — correctness here
   rests on the fix itself being a textbook single-critical-section fix for a TOCTOU race,
   verified by inspection rather than empirically re-broken like the two GC-timing-dependent
   fixes above.

**Update (2026-08-13, later still): fix #3 above was itself incomplete — Greptile's
re-review caught the actual remaining window, now closed for real.** Confidence rose to 4/5
again; genuinely the same underlying bug as #3, one layer deeper.

4. **Hookless attachment leaks keepalive.** Fix #3 made the "already tracked?" check and the
   node *insertion* atomic, but the native attach-with-release-hook call
   (`zzdds_waitset_attach_condition_with_release`) still happened *after* releasing that
   lock. That left a window where the node was published (visible to
   `zzdds_java_waitset_keepalive_contains_locked`) before the actual Zig-side attachment
   record — with its release hook — existed. A second concurrent caller for the same
   (waitset, handle) pair could see "already attached" in that window, take the redundant
   plain-attach fast path, and *win the race* to create the real Zig-side record first — with
   no release hook at all (the plain path passes null/null). The first thread's own
   attach-with-release call then arrives to find the condition already attached (by the
   second thread's hookless attach) and, per `attachConditionWithRelease`'s documented
   behavior, silently drops the first thread's `release_fn`/`ctx` rather than replacing the
   existing hookless registration — permanently leaking the node, `ctx`, and JNI global
   reference the first thread had already inserted. Fixed by extending the single critical
   section from fix #3 to cover the *entire* claim-insert-register sequence, including the
   native attach-with-release call itself — every Java-side `attach_condition()` call funnels
   through this one function (the only entry point, via `RegisterNatives`), so holding the
   mutex across the whole sequence means no concurrent caller can ever observe a
   claimed-but-not-yet-hooked attachment. Safe to call into the Zig/C-ABI layer while holding
   this JNI-private mutex: the release trampoline never fires synchronously from within an
   attach call (only later, from a separate detach/invalidate/destroy, outside any
   zzdds-internal lock per its own doc comment), so there's no reentrancy or lock-order-
   inversion risk.

   Verified: `zig build -Dc-binding=true -Dcpp-binding=true -Djava-binding=true install` and
   `test-bindings` clean, plus the same 200-round × 8-thread concurrent-`attach_condition()`
   stress test as fix #3 rerun against this version — no crash, deadlock, or hang, confirming
   the wider critical section doesn't introduce one.

**Update (2026-08-13, later still): a fourth real P1, a different attach/detach interleaving
than #3/#4 above — fixed.** Confidence rose to 4/5 again.

5. **Stale keepalive creates hookless reattachment.** `WaitSetImpl.n_detach_condition` was
   never overridden — the plain, inherited native binding fires the same `release_fn` as an
   explicit detach either way, since it's the same underlying C-ABI attachment record (true,
   and still true). But *when* that release fires matters: it runs asynchronously, outside
   any zzdds-internal lock, strictly *after* the native attachment record is already removed
   (`waitset.zig`'s detach path unlocks `self.mu` before invoking `release_fn`) — leaving a
   window where this file's JNI-side keepalive node is stale: still present, but no longer
   backed by any real native attachment. A concurrent `attach_condition()` for the same
   (waitset, handle) racing into exactly that window sees "already attached" (the stale
   node), takes the redundant plain-attach fast path from fix #3/#4, and — since the real
   attachment is already gone — that plain call actually *succeeds* in creating a genuinely
   NEW native attachment, with no release hook at all (the plain path passes null/null).
   The condition wrapper can then be collected by the JVM while the WaitSet still natively
   references it — precisely the bug this whole keepalive mechanism exists to prevent.

   Fixed by overriding `n_detach_condition` too (same `RegisterNatives` mechanism as
   `n_attach_condition`): after an explicit detach succeeds, this file's own keepalive node
   is now removed *synchronously*, right there, instead of waiting for the async release
   callback to eventually get around to it. The node-removal logic itself was factored out
   into a shared `zzdds_java_waitset_keepalive_remove` helper, used by both the new detach
   override and the release trampoline — idempotent by construction (a `(waitset, handle)`
   search-and-remove), so it's safe for both to race to clean up the same node if a detach
   happens to overlap a WaitSet-destroy/condition-invalidate instead of just a plain detach:
   whichever gets the lock first wins, the other finds nothing and is a no-op.

   Verified: `zig build -Dc-binding=true -Dcpp-binding=true -Djava-binding=true install` and
   `test-bindings` clean, plus a dedicated scratchpad stress test — two threads racing
   `detach_condition()`/`attach_condition()` against each other on the same `GuardCondition`
   in opposite phase for 50 rounds, each round settling into a known "attached" final state,
   dropping the app's own strong reference, forcing a full GC, then verifying
   `get_conditions()` still returns exactly one working condition and `detach_condition()`
   still succeeds on it — no crash, and functional correctness held across every round. Not a
   direct reproduction of the specific "hookless attachment" symptom itself (constructing an
   assertion that only fails on a hookless-but-still-functioning attachment, distinct from a
   healthy one, would need deeper native introspection than this test does) — verified via
   heavy racing plus a final-state consistency check, same standard applied to fix #3/#4
   above, and the fix's correctness itself follows directly from the same synchronous-
   removal argument used for those.

**Update (2026-08-13, later still): fix #5 was itself racy — Greptile's fourth review round
found the actual remaining hole, and this time the fix is a root-cause redesign, not another
patch on the same JNI-side cache-checking approach.** Confidence stayed at 4/5.

6. **Stale keepalive survives native detach.** Fix #5's `n_detach_condition` override called
   the plain native detach, THEN separately removed its own JNI keepalive node — but those
   two steps aren't atomic with each other. Tracing through `waitset.zig`'s `vtDetach`
   revealed the real problem is one level deeper and can't be closed from the JNI side at
   all under the OLD design: `vtDetach` removes the attachment from `self.conditions` under
   `self.mu`, unlocks `self.mu`, and only THEN (still synchronously, on the detaching
   thread, but with no lock held) calls `fireRelease()`. A concurrent `attach_condition()`
   for the same condition can acquire the JNI keepalive lock in the gap between "self.mu
   unlocked" and "fireRelease() actually runs" — a gap entirely internal to `vtDetach`, with
   no JNI-side call boundary to hook a wider lock around. Confirmed by tracing the actual
   code, not assumed: an attempted "just hold the JNI mutex across the whole native detach
   call too" fix (mirroring fix #4's approach for attach) would have caused a genuine
   self-deadlock instead — `fireRelease` is documented as never safe to call while holding
   `self.mu` specifically so `release_fn` (arbitrary caller code) can reentrantly attach/detach
   without deadlocking, and the Java trampoline (like C++'s) locks the very same JNI mutex a
   wider critical section would already be holding.

   Root cause: the JNI (and, on inspection, C++ too — same pattern, same
   `keepalive_.count(h)`-then-act shape, not yet flagged by Greptile but equally broken)
   layer's "is this condition already attached" fast-path check was fundamentally the wrong
   tool — no ordering of a caller-side cache check against a concurrent attach/detach on
   another thread can ever be airtight when the cache and the real Zig-side state are guarded
   by two different locks that are never held together. Three review rounds (fixes #3, #4,
   #5) kept finding a new specific interleaving because each fix patched the *symptom* of
   that mismatch rather than removing the mismatch itself.

   Real fix: `WaitSetImpl.attachConditionWithRelease` (`waitset.zig`) and the C-ABI export
   `zzdds_waitset_attach_condition_with_release` (`extensions.zig`/`zzdds_c.h`) gained a new
   `out_accepted: ?*bool` / `bool *out_accepted` parameter, set atomically — under the same
   `self.mu` critical section as the dedup check itself — to whether THIS call's own
   `release_ctx`/`release_fn` was actually stored (`true`, a fresh registration) or discarded
   because the condition was already attached (`false`, a no-op duplicate). Deliberately does
   NOT fire `release_fn` synchronously for the discarded case (which would reopen the exact
   `self.mu` reentrancy hazard above) — it just reports the answer and lets the caller clean
   up its own already-allocated bookkeeping directly, on its own stack, no callback needed.
   Both C++ and Java were rewritten around this to always attempt the real
   with-release registration (no more pre-check, no more fast path) and trust
   `out_accepted`:
   - **Java** (`zzdds_java_runtime.c`): `zzdds_java_waitset_attach_condition` simplified
     drastically — no more shared keepalive linked list, mutex, or `n_detach_condition`
     override (all removed; fix #5's override is no longer needed at all under this design).
     Each attachment's `release_ctx` now owns its JNI global ref *directly*, so
     `release_trampoline` never looks anything up by a `(waitset, handle)` key a concurrent
     reattach could have already reused for a different registration.
   - **C++** (`zzdds_cpp.hpp`): `WaitSetSupport` lost its `mu_`/`keepalive_` map entirely —
     `ReleaseCtx` now owns the `shared_ptr<Condition>` keepalive directly, same shape as
     Java's redesign. This also closes C++'s own latent version of fix #3's original
     duplicate-leak race, discovered while redesigning around the shared root cause rather
     than by a separate Greptile finding against C++ specifically.

   Verified: `zig build test` (including two new/updated `bootstrap_test.zig` assertions
   directly exercising `out_accepted` — `true` on a fresh registration, `false` on a
   redundant duplicate) and `zig build -Dc-binding=true -Dcpp-binding=true -Djava-binding=true
   install`/`test-bindings` (all three bindings) all clean. Both scratchpad stress tests from
   fixes #3–#5 (200 rounds × 8-way concurrent same-condition attach; 50 rounds of racing
   detach/reattach with a final GC-survival check) rerun against this redesign — no crash,
   deadlock, or regression in either.

**CI: `ZZDDS_EXAMPLES_REF` bumped to track the merged zzdds-examples PR (2026-08-13).**
`.github/workflows/ci.yml`'s default pin moved to `6a856be513f4c8449e374972756abc5c915accee`
(zzdds-examples "Waitset identity fixes, retcode cleanup, spike reorg", #6) — the commit that
removed the `get_trigger_value()` waitset-example workarounds and normalized retcode checks to
match this PR's own C-ABI changes; CI would otherwise keep exercising the pre-fix example code
against the post-fix library.

**Update (2026-08-13, later still): that bump itself surfaced a real, missed regression —
`cpp/hello_world` — now fixed upstream and re-pinned.** The `zzdds-examples` CI job's
`interop/hello-world-cross-binding` step failed: every cross-binding pair with a C++
subscriber (`zig pub -> cpp sub`, `c pub -> cpp sub`, `java pub -> cpp sub`) failed
immediately with `FAIL: take() CDR error (rc=11)`. Root cause:
`cpp/hello_world/src/subscriber.cpp`'s `take()` polling loop still checked `if (rc != 0)
FAIL`, a leftover from the old ambiguous retcode convention — under the now-normalized
`DDS_ReturnCode_t` convention, `rc == 11` (`DDS_RETCODE_NO_DATA`) is the *normal*
"queue empty, stop polling" signal, not an error. The exact same bug class as
`c/hello_world/src/subscriber.c` and `cpp/custom-allocator` (both already fixed earlier in
this same retcode-normalization pass) — this one file was simply missed. Fixed in
zzdds-examples (commit `3338e67af4e8d46fa8569ceeafee2731f28978c2`, pushed directly to main)
by mirroring `c/hello_world/src/subscriber.c`'s exact pattern:
`if (rc == DDS_RETCODE_NO_DATA) break;` before the hard-fail check. Verified locally by
running `interop/hello_world_cross_binding_smoke_test.py` directly (the same script CI
runs) — all 12 cross-binding pairs pass. Also audited every other `take()`/`take_loaned()`
call site across zzdds-examples (C, C++, Java) for the same stale-check pattern; nothing
else affected. `ZZDDS_EXAMPLES_REF` re-pinned to this new commit.

**Test coverage: closed a real gap in `src/c_abi/extensions.zig`'s checked downcasts
(2026-08-13).** Codecov flagged this PR's patch coverage as low; pulled the CI `Coverage`
job's kcov artifact (`cobertura.xml`) for the closest available successful run and
cross-referenced its uncovered-line ranges against this PR's diff.
`src/c_abi/extensions.zig` stood out — 58% covered overall, the second-lowest file in the
repo after `nil.zig` (which is inherently low-value to chase: near-identical nil-singleton
boilerplate, not real logic) — and its uncovered ranges lined up almost exactly with the 13
checked-downcast functions this PR itself added (`DDS_Condition_as_DDS_GuardCondition`/
`_StatusCondition`/`_ReadCondition`, the six `DDS_Entity_as_DDS_*`, and the three
`DDS_TopicDescription_as_DDS_*`). Confirmed by grep: only ONE of the 13 (
`DDS_ReadCondition_as_DDS_QueryCondition`) had a real unit test before this — the other 12
were exercised, if at all, only indirectly via the Java smoke test's `StatusCondition.
get_entity()` call (`DDS_Entity_as_DDS_DomainParticipant` only), and that path is invisible
to kcov entirely (a separate JVM process calling into a separately-built `.so`, not a `zig
build emit-tests` binary) — so from the Zig suite's own coverage perspective, 12 of 13 were
completely dark.

Added three new tests to `test/c_abi/bootstrap_test.zig`, one per family, each exercising
both branches (real match recovers the same boxed handle the concrete type's own
`get_c_abi_handle` produces; a genuine mismatch returns `null`, not a false positive) using
the existing `Fixture` helper (already builds a full DomainParticipant/Topic/Publisher/
Subscriber/DataWriter/DataReader intraprocess pair) plus real `GuardCondition`/
`StatusCondition`/`ReadCondition`/`ContentFilteredTopic` instances — no new test
infrastructure needed. `zig build test` green.

Not chased further: `extensions.zig` still has real remaining gaps in its OOM/allocation-
failure error paths (e.g. `factoryCreateParticipant`'s `config_generated.toRuntimeConfig`
`catch` branches) — `testing.FailingAllocator` is an established pattern elsewhere in this
suite (`discovery_interface_test.zig`, `waitset_test.zig`, `cft_test.zig`) that could cover
these, but scoping and writing that is a separate, follow-up-sized task, not done here.
`nil.zig` (12% covered) is lower priority — the uncovered lines there are overwhelmingly
repetitive nil-singleton vtable wiring, not branchy logic worth a dedicated test per file.

**Update (2026-08-13, later still): a real gap the coverage pass' own `FailingAllocator`
suggestion turned up in practice — Greptile's next review round, not a coincidence.** The
"remaining OOM/allocation-failure error paths" note above was about `extensions.zig`'s
*other* functions; this one is in the Java WaitSet keepalive path fixes #3–#6 already
touched, and is worth calling out on its own.

7. **OOM creates hookless attachment.** `zzdds_java_waitset_attach_condition`'s own OOM
   fallbacks — `malloc` failing for the release context, or `NewGlobalRef` failing for the
   keepalive reference — degraded to a plain, hookless attach (still returning
   `DDS_RETCODE_OK`) rather than failing the call outright. Exactly backwards under memory
   pressure: the moment resources are tight enough that the keepalive can't be built is
   also the moment losing it matters most, and the caller had no way to tell "attached,
   protected" from "attached, silently unprotected" apart — both returned OK. Fixed by
   returning the real, standard `DDS_RETCODE_OUT_OF_RESOURCES` instead of falling back, for
   both failure points — mirroring how `attachConditionWithRelease`'s own `WAKEUP_SLOTS`-full
   case already refuses to silently succeed rather than reporting OK for an attachment it
   knows is incomplete. An attach that returns OK is now unconditionally a fully
   keepalive-protected one; a caller ignoring this specific non-OK code is no worse off than
   one ignoring any other `DDS_ReturnCode_t`. Simplified `zzdds_java_waitset_release_ctx`'s
   `global_ref` field to a non-optional invariant as a result — it's now always a real
   global ref by the time a ctx reaches the trampoline or the cleanup path, never a
   "maybe-NULL, OOM-degraded" value threading through both.

   Verified: `zig build -Dc-binding=true -Dcpp-binding=true -Djava-binding=true install` and
   `test-bindings` (all three bindings) clean, plus both existing concurrency stress tests
   (200-round concurrent-attach, 50-round detach/reattach race) rerun against this change —
   no crash, deadlock, or regression. Confirmed C++'s `WaitSetSupport::attach_condition()`
   doesn't share this bug: `new ReleaseCtx{...}` throws `std::bad_alloc` on failure rather
   than returning a null/degraded placeholder to silently proceed with, so there's no
   equivalent "OOM but attach anyway" path there to begin with.

---

## CI / release platform coverage gaps (follow-on, re-reviewed 2026-08-16)

Original audit of `build.zig`'s options, `scripts/run_deterministic_matrix.py`, `ci.yml`, and
`release.yml` against the platform/build-type matrix they actually exercise, prompted by a
review of PR #64 (2026-08-15). Re-reviewed 2026-08-16 against the just-merged TSAN/
DebugAllocator CI work (new `examples-tsan`, `self-interop-debug-allocator`, and
`vendor-interop-debug-allocator` jobs, plus the `test-linux` DebugAllocator lane) — all of it
Linux x86_64 only, confirmed line-by-line against the current `ci.yml`/`release.yml`. Every
gap below is unchanged from the original audit or, for TSan/DebugAllocator specifically,
larger in absolute footprint than when first written, since more Linux-only lanes now exist.
Not exhaustive-coverage nitpicking — these are the gaps judged to be real, actionable risk
for a DDS middleware library, re-ranked below given the concrete evidence the recent work
provided:

1. **DebugAllocator lane is untested outside Linux, and is the cheapest of these gaps to
   close.** Pure-Zig, zero OS/compiler dependency (unlike TSan or Valgrind below) —
   extending it to `test-other`'s Linux ARM64/macOS/Windows matrix is a one-line copy of
   `test-linux`'s existing `-Ddebug-allocator=true` step (`ci.yml`:73-74). Bumped to #1 on
   direct evidence: the just-merged DebugAllocator work found real allocator bugs on Linux;
   there's no reason to expect Windows/macOS libc allocator interactions are less
   bug-prone, and this is the lowest-effort way to find out.
2. **C/C++/Java bindings are validated on Linux x86_64 only — partially closed (PR #65,
   2026-08-17).** C/C++ now run on Linux ARM64, macOS, and Windows too. Java/JNI runs on
   Linux ARM64 and macOS. **Java/JNI on Windows is deferred, not achieved** — real bugs were
   found and fixed along the way (Windows has no rpath equivalent, so `-Djava.library.path`
   alone couldn't resolve `zzdds_jni.dll`'s dependency on `zzdds.dll`, fixed by installing
   both to the same directory and adding it to `PATH`; the JVM's default native thread stack
   was too small for this call path on Windows specifically, fixed with `-Xss8m`), but a
   third failure remains unresolved: `java.exe` exits with code 9 and zero output at the
   first JNI call, with no JVM crash report, no Windows Error Reporting event, and Defender
   ruled out as the cause. Explicit `-XX:ErrorFile`/`-XX:+CreateMinidumpOnCrash` flags still
   produced no crash file at all — conclusive evidence the JVM's crash handler never runs,
   consistent with something bypassing SEH entirely (Control Flow Guard mismatch between
   CFG-instrumented `jvm.dll` and non-CFG-instrumented `zig cc`-built DLLs is the leading,
   unconfirmed hypothesis). Diagnosing further needs a live debugger (WinDbg) on real Windows
   hardware, which CI can't provide. A self-contained investigation brief with the full
   chronological trail and suggested next steps was handed off separately (not committed to
   this repo — ask whoever's tracking this item for it). The remaining gap: JNI bridge,
   generated headers, and CMake/pkg-config install tree on Windows specifically still get no
   CI signal.
3. **TSan lane is Linux-only; macOS was attempted (PR #65, 2026-08-17) and blocked, not
   achieved.** Clang's ThreadSanitizer supports Linux and macOS (x86_64/ARM64) but has no
   real Windows support. macOS coverage looked like a realistic extension of the same
   justification as #1 (the recent TSan work found real races on Linux) — but even the
   minimal `test-tsan-self-check` segfaults with zero sanitizer output on `macos-latest`
   (Apple Silicon), before any application code runs. Diagnosed (from source, not verified
   on real macOS hardware — see `docs/design/ci-platform-coverage-expansion.md` item 3 for
   the full writeup) as a likely upstream Zig/LLVM issue: TSan's macOS startup path calls a
   private, undocumented Apple API (`pthread_introspection_hook_install`), and sanitizer
   runtimes breaking against private API drift after an OS/Xcode update is a well-established
   failure class, plausible here since GitHub's `macos-latest` image version moves
   independently of Zig's pinned LLVM release. Not something fixable from zzdds's CI config;
   revisit when Zig bundles a newer LLVM, or if someone can bisect on real macOS hardware.
4. **`ReleaseFast` is never built or run anywhere** — not in CI, not in release.yml. The
   optimize mode most production deployments would actually ship (safety checks stripped,
   UB instead of panics) is completely unverified. (`ReleaseSmall` likewise unused, lower
   priority.)
5. **Real vendor/self RTPS interop (Connext/Cyclone/CoreDX/self) runs only on Linux
   x86_64.** Wire-format, discovery, and CDR correctness against real vendors has no
   coverage on Windows, macOS, or ARM64.
6. **No Intel macOS coverage** — `macos-latest` in ci.yml/release.yml is Apple Silicon
   only; Intel Mac consumers get no signal.
7. **`release.yml` never builds a binding.** A tagged release could ship a binding
   regression that `main`'s own CI didn't happen to catch between last-green and the
   release trigger, since the release gate only requires a Linux x86_64 ReleaseSafe
   self-interop pass.
8. **No musl/static Linux target** — always glibc, always the native triple (`-Dtarget`
   is never actually cross-compiled anywhere). Alpine/statically-linked deployments are
   unvalidated.
9. **No prebuilt release binaries at all.** `release.yml` publishes a git tag, changelog,
   and `zig fetch` source URL only — no compiled `libzzdds.so`/`.dll`/`.dylib` is ever
   built, uploaded, or smoke-tested as a distributable artifact.
10. **Valgrind has no viable non-Linux equivalent** — unmaintained/unreliable on Apple
    Silicon, no native Windows support. Deprioritized to last: unlike DebugAllocator/TSan
    above, there isn't a cheap or even clearly achievable extension here; treat as
    effectively Linux-only permanently unless a specific non-Linux memory bug motivates
    revisiting the tooling choice.

Suggested first move if this gets picked up: item 1 (DebugAllocator on `test-other`) —
lowest effort, most direct evidence of payoff, and already-proven CI wiring to copy. Item 2
(bindings smoke tests on the 3-platform matrix) is next: the smoke tests and binding build
steps already exist and just aren't wired to run there yet.

---

## zzdds-examples repo split — revisit soon (2026-08-19)

**Priority: sort out a better solution for the sake of development velocity.** Not urgent
enough to drop everything for, but this has now caused real, repeated friction across
multiple example-development sessions and should not keep being worked around indefinitely.

**Why `zzdds-examples` is a separate repo today:** to keep the build/dependency footprint
small for a consumer who only wants the core DDS library plus a single binding (say, just
the C ABI) — they shouldn't need to clone or build four bindings' worth of example code,
CMake projects, and a JVM toolchain just to `zig fetch` the library. That goal is real and
still worth preserving.

**What it's actually costing us:** the examples exist specifically to exercise DCPS APIs
real applications use, which means writing a new example very often *finds* a real core bug
— at which point the example and the fix are tightly coupled, but live in different repos.
The workaround has been a temporary `.path` dependency in the example's `build.zig.zon`
pointing at a sibling core-fix worktree, landed as its own separate zzdds PR, with an
explicit "flip the example back to the normal dependency once merged" step. Concretely, in
one recent round (presence/registry/catchup examples, 2026-08-17/19):
- Three examples needed four separate core fixes (liveliness notify-on-alive, PID_LIVELINESS
  wire encoding, a `wait_for_historical_data()` vacuous-true bug, and an `EntityQuiesce`
  extension to the whole take/read/write API surface) before they could pass.
- The "flip back to the normal dependency" step was missed — the examples PR merged with
  three `build.zig.zon` files still pointing at a worktree that only exists on one machine,
  which will break `zzdds`'s own CI (`ZZDDS_EXAMPLES_REF`) the moment that ref is bumped,
  until a follow-up PR in `zzdds-examples` fixes it.
- `ZZDDS_EXAMPLES_REF` itself is a manually-maintained pin in `ci.yml` that goes stale the
  moment `zzdds-examples` merges anything without a coordinated follow-up bump here — the
  same class of drift `release.yml` vs `ci.yml` self-interop staleness hit once already.

**Leading option:** move `zzdds-examples` into an `examples/` subdirectory of this repo.
The footprint goal doesn't actually require a separate repo — a subdirectory with its own
`build.zig.zon`, never referenced by the core library's default `zig build`, and CI jobs
gated on path filters, should preserve "don't force a single-binding consumer to build
examples" while eliminating the cross-repo dependency dance entirely (a core fix and the
example that needed it become one atomic commit). Tradeoffs to weigh before committing:
CI duration/PR-review-unit size if example jobs aren't gated tightly, and what happens to
`zzdds-examples`' existing history/issues/stars if it's folded in. Needs its own planning
pass (repo restructuring, CI pipeline changes, any external links to the standalone repo)
before executing — not a quick change.

---

## Deferred / Out of Scope for v1

- **DDS-RPC** — deferred; no concrete use case yet.
- **DDS-XRCE** — embedded profile; separate project or downstream fork.
- **TRANSIENT / PERSISTENT durability** — requires a persistence service; deferred.
- **MultiTopic** — complex; deferred. `vtCreateMultiTopic` (`src/dcps/participant.zig`)
  always returns nil. Note for anyone touching binding marshaling near this: a binding's
  `create_multitopic` *marshaling* working correctly (argument/return plumbing across the
  C ABI or JNI boundary) is independent of this stub — a caller can get all the way to
  the nil return with no marshaling error, which is easy to mistake for partial
  functionality. It isn't; nothing behind `create_multitopic` works yet in any binding.
- **Retroactive unmatching for ignored publications/subscriptions** — the ignore APIs filter
  future discovery callbacks today. Ignoring an already-discovered publication or
  subscription is treated as a permitted no-op; actively removing existing RTPS proxies is
  deferred unless a use case needs stricter behavior.
- **Platform-specific InterfaceMonitors** — `monitor/netlink.zig` (Linux) and
  `monitor/pf_route.zig` (macOS) deferred; polling monitor is sufficient.
- **SHMEM transport** — deferred; UDP covers current use cases.
- **Other protocol/discovery plugins** — QUIC, MQTT, custom hardware channels, and
  mDNS/DNS-SD are extension points only; no v1 implementation is planned.
- **PKCS#11** — out of scope for v1; security plugin interface must not preclude it.

---

## Open Questions

**Key material storage.** File-based PEM certs to start when DDS Security is implemented.
HSM abstraction deferred.
