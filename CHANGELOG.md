# Changelog

Notable changes to Zenzen DDS, newest first. For current capability and known limitations
see [`docs/implementation_status.md`](docs/implementation_status.md); for planned work see
[`docs/roadmap.md`](docs/roadmap.md); for stable design decisions see
[`docs/decisions.md`](docs/decisions.md).

Dated entries (no release tags past `v0.2.1-zig.0.16.0`; `build.zig.zon` is
`0.2.1-zig.0.16.0-dev`).

## 2026-08-26

- **`zzdds-examples` folded into `examples/`.** The standalone `zz-iot/zzdds-examples` repo
  was merged into this repo at `examples/`, preserving history, so a core fix and the
  example that exercises it can land in one commit. `examples/` is absent from
  `build.zig.zon`'s `.paths` allowlist, so it stays out of the fetched tarball. CI's
  `examples`/`examples-tsan` jobs collapsed to one checkout; `ZZDDS_EXAMPLES_REF` removed.
  The standalone GitHub repo is not yet archived.

## 2026-08-22

- **Raw / loaned DataReader & DataWriter API redesigned.** The hand-written, C/C++-only
  `zzdds_*_raw` family is replaced by real `dcps.idl` operations generated across all four
  bindings (`take_raw`/`read_raw`/`take_next_instance_raw`/`read_next_instance_raw`/
  `return_loan_raw` on `DataReader`; `write_raw`/`loan_raw`/`publish_loan_raw`/
  `return_loan_raw` on `DataWriter`). `max_len == 0` signals loan-vs-copy, inferred from
  parameter shape. Loan-outstanding tracking added (CAS refcount pin table in `reader.zig`;
  single-owner counter in `writer.zig`) with `PRECONDITION_NOT_MET` fast-fail teardown.
  `take_loaned_raw` remains a raw-*byte* buffer loan (a copy out of reader history), not
  zero serialization — see `docs/design/raw-loan-api.md`.
- **`delete_contained_entities` now propagates preconditions.** Previously every level
  (`participant.zig`/`subscriber.zig`/`reader.zig`) hardcoded `RETCODE_OK` regardless of
  precondition state — a DDS 1.4 spec gap. Now a synchronous check-then-teardown pass fails
  all-or-nothing with `PRECONDITION_NOT_MET` before any child is torn down.
- Fixed the C/C++/Java typed reader family carrying a 3-field `zzdds_sample_info`/`Sample`
  instead of the 12-field spec `SampleInfo` (missing `source_timestamp` and every
  generation/rank field). Only Zig was correct before.

## 2026-08-20

- **Fixed a C-ABI struct-layout bug in `create_participant_ex` /
  `set_default_participant_config` / `get_default_participant_config`.** The exported
  wrappers declared their `config` parameter as the non-`extern` Zig type
  `zzdds.DomainParticipantConfig`, which carries a hidden `_toml_applied: bool` field, while
  the public header declared it without that field — so every C/C++/Java caller built a
  smaller struct that the wrapper then read/wrote through as the larger layout, and
  `factoryGetDefaultParticipantConfig`'s `config.deinit()` freed through garbage offsets
  (confirmed via a real JVM crash). Introduced by "Config File Improvements" (#54); never
  caught because no cross-language caller had exercised these three ops. Fixed via zidl's
  C-ABI mirror mechanism (`zidl v0.3.7`).
- **Fixed a zidl Java JNI `@optional` scalar marshaling crash** — `StructMarshalGenerator`'s
  `.scalar` case never checked `is_optional`, so it emitted `GetMethodID(cls, "get_x",
  "()I")` for a boxed `Integer` getter, got NULL, and the next call dereferenced it. Only
  reachable via `UdpConfig`'s five `@optional` port fields. Also fixed a live leak in the
  same generator (`javaFieldDescriptor` return value never freed at four sites). `zidl v0.3.7`.
- **Hardened `zzdds_java_runtime.c`'s JNI boundary** against `null`/invalid handle inputs.
  Audited all 21 `zzdds_java_unbox` and 4 `GetStringUTFChars` sites; added
  `zzdds_java_require_non_null` / `_require_utf_chars` helpers that throw a catchable
  `NullPointerException` (previously: a full JVM crash) naming the parameter. Three sites
  left unguarded where `null` has documented meaning (idempotent destroy; `cft == NULL` =
  "no filter").
- **`-Z` / `--datafrag-size` added to every `shape` port** (dds-rtps port + zzdds-examples
  `zig`/`c`/`cpp`/`java`). Found in the process that **`--periodic-announcement` had been a
  silent no-op in all five ports** — they set it via `setenv(...)` but `src/config/resolve.zig`
  stopped honouring env vars in "Config File Improvements" (#54). Rewired through the real
  config mechanism.

## 2026-08-19

- **Writer Liveliness Protocol implemented** (RTPS 2.5 §8.4.13).
  `DomainParticipant`/`DataWriter.assert_liveliness()` previously only updated local
  timestamps and never emitted wire traffic. New `src/discovery/builtin_endpoint.zig`
  (`BuiltinPair`, a shared abstraction for RTPS well-known-EntityId endpoint pairs; SEDP
  refactored onto it first) and `src/discovery/wlp.zig` (`WlpEndpoints`, the
  `BuiltinParticipantMessageWriter/Reader` pair, sharing SEDP's metatraffic listener,
  driven by `checkTimers()`). AUTOMATIC and MANUAL_BY_PARTICIPANT via `ParticipantMessageData`;
  MANUAL_BY_TOPIC via an on-demand Heartbeat with the RTPS LIVELINESS flag
  (`StatefulWriter.sendLivelinessHeartbeat`). Deliberate simplifications:
  `BuiltinParticipantMessageReader` is RELIABLE-only; AUTOMATIC send period is `lease/3`
  floored at 100ms. Real-wire regression test (`test/dcps/wlp_loopback_test.zig`, two real
  `UdpTransport` participants).

## 2026-08-16

- **CI extended to non-Linux platforms** (#65): DebugAllocator, C/C++/Java bindings, TSan,
  and ReleaseFast across the Linux ARM64 / macOS / Windows matrix, where feasible. Java/JNI
  on Windows and TSan on macOS were attempted and deferred — see the roadmap's "CI /
  Release Platform Coverage" section and the two investigation notes in `zz-dev`.

## 2026-08-13

- **Listener "nearest enclosing non-null listener" fallback (DDS 1.4 §2.2.4.1.5)
  implemented** — `src/util/listener_fallback.zig`, wired into `reader.zig`/`writer.zig`/
  `subscriber.zig` dispatch. When an entity's own listener callback is null, dispatch now
  walks up (reader → subscriber → participant) to the closest installed non-null listener,
  passing the originating entity as the callback argument.
- **C-ABI `WaitSet`-attached-condition release hook wired into the C++ and Java wrapper
  layers** — the memory-safety half was already internal; the wrappers now use the hook so
  a wrapper's own keep-alive can be released at the right time.
- **Five P1 races in `java_runtime/zzdds_java_runtime.c`** fixed (found across several
  Greptile review rounds on PR #62) — attach/detach interleavings and an OOM-but-proceed
  path in `WaitSetImpl.attach_condition`.
- **Closed a gap in `src/c_abi/extensions.zig`'s checked downcasts** (test coverage), and
  fixed a real gap the coverage pass's own `FailingAllocator` run surfaced. The OOM-path
  error branches in `factoryCreateParticipant` etc. remain untested — see roadmap.

## 2026-08-12

- **C-ABI entity/condition cross-view identity fixed at the root** (with zidl's
  `@shared_c_abi_box` / `CAbiViews` work). Phase 1: the Condition family. Phase 2: extended
  to every other entity impl. A `Condition` returned from `WaitSet.wait()` is now
  identity-comparable against a held condition's own upcast handle in C
  (`zzdds-examples/c/waitset` workaround removed) and C++ (via zidl's shared-family
  `_getOrCreate`; `cpp/waitset` workaround removed). Zig-native was never affected. See
  `zidl/docs/design/binding-c-abi-identity.md`.

## 2026-08-09 – 2026-08-10

- **`WaitSet` / condition example added** (`zzdds-examples/{zig,cpp,c,java}/waitset`),
  exercising `WaitSet` + all four condition types on one `WaitSet`. Surfaced and fixed a
  cluster of bugs unreachable before (nothing could construct a `WaitSet` through any
  binding):
  - `WaitSet` / `GuardCondition` C-ABI + Zig-native construction
    (`zzdds_create_waitset`/`_guardcondition` + `_with_allocator` + `_destroy` + `_is_nil`
    in `extensions.zig`; `zzdds.createWaitSet`/`createGuardCondition` in `raw_ops.zig`;
    `nil_waitset`/`nil_guardcondition` in `nil.zig`; `zzdds::create_waitset`/
    `create_guardcondition` in `zzdds_cpp.hpp`). Both interfaces have no factory op in
    `dcps.idl` per OMG spec.
  - Condition/entity lifecycle safety — a destroyed condition now drops cleanly from every
    attached `WaitSet`, no dangling pointer regardless of destruction order.
  - `QueryCondition` deleted via its spec-correct `ReadCondition` upcast corrupted memory
    (`deinit` reached the wrong object) — fixed with an `owner_qc` back-pointer.
  - `WaitSetImpl.vtWait`'s two-pass count-then-fill loop raced a concurrent
    attach/detach — fixed.
  - zidl C++ backend: `attach_condition`'s `dynamic_cast` cascade wrongly excluded
    `ReadCondition`; zidl Zig backend: a `sequence<EntityInterface>` out-param had
    corrupted binary layout (native fat-pointer passed where the C ABI expects one opaque
    pointer). Both fixed in zidl (`v0.3.5`).

## 2026-08-06

- **ContentFilteredTopic filtering now actually works in every binding.** No backend had
  ever emitted zzdds's `TypeSupport.get_field` hook, so CFT filtering silently never
  activated. `get_field` is now wired for every binding (needed a zidl `get_field_from_cdr`
  codegen change and a Java bare-`sequence<T>`-param JNI marshaling fix). New
  `zzdds_cft_match_sample` C-ABI export.
- **Fixed `data_representation` QoS re-matching reading a dangling pointer.**
- **Plain-struct CDR functions** (`_serialize`/`_deserialize`/`_skip`/`_default`) exposed
  across the C ABI (`zidl v0.3.4`).
- **C++ ABI: `create_datawriter` / `create_topic` can now return zzdds's own extended
  entity types** (not just the `DDS::` base) — via zidl's `--cpp-impl-override` /
  `--cpp-impl-include` (`zidl v0.3.4`).
- **`zzdds_register_type_support_c` / `_ctx_c`** renamed (dropping the `_c` suffix); added
  Zig-native `registerTypeSupport` / `setListenerEx` ergonomic wrappers in `raw_ops.zig`
  and fixed live string-cleanup leaks found while verifying them (`zidl v0.3.4`).
- **DEADLINE / LIVELINESS QoS now enforced automatically** — a per-participant timer thread
  (`DomainParticipantImpl.timer_thread` / `timerThreadFn`) periodically calls
  `checkTimers()`. Previously nothing drove it in production; callers had to pump it
  themselves. Scoped to one thread per participant.
- Fixed a standing Zig build-graph bug (unrelated to this work) found along the way.

## dds-rtps shape interop validation (Phase 33) — complete

The OMG **dds-rtps shape** interop suite (48 cases): self-interop CI job 48/48 (gates
release); zenzen↔zenzen 100%; FastDDS, OpenDDS, RTI Connext, Cyclone DDS all 48/48
bidirectional (Cyclone's two CFT cases are `SUB_UNSUPPORTED_FEATURE` in its own
`shape_main` — a test-infra gap, not a wire issue).

This does **not** cover GROUP_PRESENTATION coherent-set interop, which uses a separate,
larger suite — RTI Connext still has 5 open zzdds→Connext gaps there
(`CoherentSets_8/10/11/12`, `OrderedAccess_8`); see `docs/implementation_status.md` and the
roadmap's "DCPS / QoS" gaps.

## Earlier (through 2026-08-05)

Core RTPS 2.5 (SPDP/SEDP discovery, stateful reliable readers/writers, HEARTBEAT/ACKNACK,
fragmentation), the full DCPS entity model and all 22 QoS policies, ContentFilteredTopic /
QueryCondition SQL, pluggable UDP/TCP transport, the C / C++ / Java bindings (opaque-handle
C ABI, generated C++ impl classes, real JNI bridge), TypeSupport C-ABI shim, and the
configurable-allocation Tier 0/1 work (`zzdds_create_factory_with_allocator`, the
`get_c_abi_handle` cache). See git history for detail.
