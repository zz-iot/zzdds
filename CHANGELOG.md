# Changelog

Notable changes to Zenzen DDS, newest first. For current capability and known limitations
see [`docs/implementation_status.md`](docs/implementation_status.md); for planned work see
[`docs/roadmap.md`](docs/roadmap.md); for stable design decisions see
[`docs/decisions.md`](docs/decisions.md).

Dated entries (no release tags past `v0.2.1-zig.0.16.0`; `build.zig.zon` is
`0.2.1-zig.0.16.0-dev`).

## 2026-09-03

- **Release workflow — first real run shook out two `package-libs` bugs.** That job
  (`release.yml`-only, never exercised by `ci.yml`) had shipped unrun since 2026-08-28.
  1. **`Verify install tree is complete` false negative.** The dynamic-lib probe was
     `if ! ls <4 candidate paths> 2>/dev/null | grep -q .` under `set -o pipefail`; on any
     one platform 3 of the 4 paths are absent so `ls` exits non-zero, `pipefail` propagates
     that over grep's success, and `!` inverts it to a bogus "no dynamic libzzdds found" —
     with `libzzdds.{so,dylib,dll}` sitting right there. Replaced with a `test -f` loop.
     Also added `--summary all` to the install build.
  2. **macOS static archive not linkable by Apple `ld64`.** The `libzidl_cdr.a` that
     `Step.Compile`'s GNU-format archiver writes has member offsets Apple's linker rejects
     (`64-bit mach-o member 'zidl_cdr.o' not 8-byte aligned`). `zig cc` (LLD) tolerates it —
     so `test-bindings` never saw it — but the new prebuilt-bundle consume check, which
     links with Apple clang/ld, did. `build.zig` now installs the macOS `libzidl_cdr.a` by
     re-packing the object with the `zig ar` subcommand (`--format=darwin`, 8-byte
     aligned) instead of `b.installArtifact`; the internally-linked `zidl_cdr` static lib
     is unchanged. Fixes a local `zig build install` on macOS and a macOS bundle
     cross-compiled from another host, not just the release runner. (ziglang/zig#1981;
     Linux `ar` output is fine.)
- **Convention — dry-run `release.yml` before merging any change to it.** Documented in the
  workflow header and `docs/binding-release-plan.md`: run it from the PR branch with
  `dry_run: true` (skips `publish`) and confirm `test`, `self-interop`, and all four
  `package-libs` legs pass, since `package-libs` is release-only.

## 2026-09-02

- **Pinned `zidl` v0.3.12-zig.0.16.0** (`build.zig.zon`) — the selective-parse family
  (`deserialize_selected` / `KEY_FIELD_MASK` / `skipPrimitives`) that rewires
  `get_key_value` and `get_field_from_cdr` off the key-only deserializer. The
  `lifecycle_churn` `instance` scenario now **asserts** `get_key_value`'s returned
  `subject_id` (non-leading `@key`) on both the writer and reader sides — it was
  call-only-not-asserted while the fix was unreleased. Verified: 8 threads × 6 s, plus
  ThreadSanitizer, clean; full stress suite green.
- **Fix — keyed writers now always send inline `PID_KEY_HASH`; a present all-zero hash is
  honoured.** Two connected key-hash bugs the `instance` stress scenario exposed for a
  zero-valued key (`subject_id == 0`):
  1. `writer_sm.zig` suppressed the inline `PID_KEY_HASH` parameter whenever the computed
     hash was all-zero bytes — indistinguishable from "keyless topic" but also true for a
     legitimate zero key. A subscriber then had to reconstruct the per-instance hash from
     the payload.
  2. `resolveKeyHash` treated a *received* all-zero hash as "absent, recompute" rather
     than as the value the writer sent.
  Now: `TypeSupport` gains `has_key`; `pubCreateProtoWriter` marks the RTPS `StatefulWriter`
  keyed (via new `setKeyed` / adapter passthrough); a keyed writer emits `PID_KEY_HASH` on
  every DATA/DATA_FRAG including an all-zero key (`writer_sm.zig` `inlineKeyHash` helper).
  `decodeKeyHash` returns `?[16]u8` and `resolveKeyHash` returns a *present* hash verbatim,
  even all-zero. The C-ABI `zzdds_register_type_support{,_ctx}` infer `has_key` from a
  non-NULL `compute_key_hash_fn` (per their documented contract); Zig-native callers set it
  explicitly (stress harness updated). Regression: `test/dcps/type_support_test.zig` — a
  keyed writer's zero-key sample routes by the wire hash and bypasses `key_hash_fn`, with a
  control test showing the unchanged non-`has_key` fallback. Verified by re-breaking.
- **Known follow-up.** `TypeSupport.compute_key_hash`'s contract is "full CDR payload in,
  hash out", but zidl's generated `computeKeyHashFromCdr` runs the key-only deserializer,
  so a non-`has_key` fallback still misreads a non-leading `@key` from a non-zzdds peer that
  omits the inline hash. Completion — route the fallback through
  `deserialize_selected(KEY_FIELD_MASK)` on a full payload, K-flag-gated — needs a
  `TypeSupport.compute_key_hash` signature change (`is_key_only: bool`) rippling to the
  C ABI mirror and a further zidl release, so it is a follow-up beyond the v0.3.12 bump.
  Tracked in `docs/roadmap.md` "Selective CDR parse — deferred follow-ups".
- **Release prep — prebuilt-bundle consume check.** `release.yml`'s `package-libs` job used
  to verify only the *contents* of the install tree it built, in place. It now also extracts
  the finished per-platform tarball into an unrelated directory and drives a real downstream
  consume of it (`scripts/verify_release_bundle.py` + committed fixtures under
  `test/release-bundle/`): structural completeness, pkg-config / CMake-package
  relocatability (no baked-in absolute build path), the bundled `bin/zidl` runs, and
  `find_package(ZZDDS)` + `pkg-config` build `examples/{c,cpp}/hello_world` and a minimal
  consumer against the *relocated* prefix — on Linux the hello_world pair also exchanges its
  10 samples. This is the consumption path `rmw_zzdds` (and any C/C++ CMake consumer) takes;
  the in-tree `test-bindings` step never exercised a moved prefix. Linux: full; macOS:
  `--skip-example-run` (skips only the live-UDP pair run — `cmake_consumer` still links and
  runs against `libzzdds.dylib`). Windows keeps the structural check only: the generated
  `zzdds-config.cmake` / `zzdds.pc` are POSIX-shaped (search `lib/` for the shared lib, no
  `IMPORTED_IMPLIB`, `bin/zidl` not `bin/zidl.exe`), so `find_package(ZZDDS)` can't configure
  a bundle there yet — tracked in `docs/roadmap.md` "CI / Release Platform Coverage".
- **Release prep — musl / static Linux target lane.** `-Dtarget` was never actually
  cross-compiled anywhere in CI. New `zig build test -Dtarget=x86_64-linux-musl` step in
  `run_deterministic_matrix.py` (so `ci.yml`'s `test-linux` covers it) and `release.yml`'s
  `test` job (Linux x86_64 only). A `-linux-musl` binary is statically linked and runs
  natively on the glibc runner, so this executes the full suite (1076/1076), proving zzdds
  is musl-clean for Alpine / static-binary / container consumers. In
  `run_deterministic_matrix.py` the step is gated to x86_64-Linux hosts (elsewhere the
  cross-built binaries can't run, and Zig would silently skip them); CI's `ubuntu-latest`
  runs it unconditionally. `aarch64-linux-musl` (needs qemu) and a static-archive `libzzdds`
  bundle variant remain deferred — `docs/roadmap.md` "CI / Release Platform Coverage".
- **Release prep — GitHub-release notes now come from `CHANGELOG.md`.** `release.yml`'s
  `publish` job built its release body from raw `git log --pretty=%s` subjects. It now
  quotes the `CHANGELOG.md` sections added since the previous release tag —
  `scripts/extract_changelog.py` emits the leading run of sections whose heading is not
  present in `CHANGELOG.md` as of that tag (whole-heading, not date, comparison), falling
  back to the leading date-headed run when the tag predates the file, and to raw commit
  subjects only if that yields nothing. Always appends a `compare` link. Two releases on
  the *same calendar day* under one `## <date>` heading aren't distinguished — the second
  gets the git-log fallback (fine for a hotfix; the notes are hand-editable).
- **Decision recorded — pre-1.0 has no stability guarantee.** `docs/decisions.md` gains a
  "Versioning / Releases" section: any release may break the Zig API, the C ABI, the
  QoS/config schema, or the bundle layout, with no deprecation cycle; the C ABI stays in
  flux until zzdds and Zig mature toward a distant 1.0; `--runtime-version <N>` stays
  unimplemented until there is a tier worth pinning. Consumers pin an exact
  `vX.Y.Z-zig.A.B.C` tag / bundle; downstream middleware (e.g. `rmw_zzdds`) owns its own
  version mapping and absorbs zzdds churn behind its own boundary. `release.yml`'s release
  notes now carry a matching "Stability" section.
- **Fix — the installed `zzdds.pc` / `zzdds-config.cmake` version now tracks `build.zig.zon`.**
  `build.zig` carried a second, hand-maintained `zzdds_version` string (stuck at
  `0.1.1-zig.0.16.0-dev`) that stamped the `Version:` field of the generated pkg-config and
  CMake package files — so a consumer's `pkg-config --modversion zzdds` reported a version
  two minors behind the actual package. It now reads `@import("build.zig.zon").version`, the
  same field `release.yml` bumps at tag time.

## 2026-08-30

- **Stress tests — five new `lifecycle_churn` churn scenarios.** On top of
  `entities`/`reentrant`: `waitset` (threads attach/detach Read/QueryConditions on a
  shared WaitSet while a waiter is in `wait()` and a waker flips a GuardCondition;
  includes a deliberate delete-while-attached), `listener` (participant + publisher +
  subscriber listeners installed; per-iteration `set_listener` swaps incl. `null` racing
  entity teardown and event delivery), `cft` (a shared long-lived ContentFilteredTopic
  hammered with `set_expression_parameters` while its reader is drained, alongside
  unique-name CFT + reader lifecycle churn), `participants` (N threads each churning a
  whole participant on one shared domain, listeners at every level, writer/reader
  fan-in/fan-out — the participant level of the §2.2.4.1.5 fallback under teardown), and
  `instance` (per-thread writer; `register_instance` / `write` / `dispose` /
  `unregister_instance` / `get_key_value` / `lookup_instance` churn with a shared reader
  fan-in). All gating in the `stress` CI job; `listener` and `cft` also run under
  ThreadSanitizer. See `stress-tests/README.md`. The `instance` scenario surfaced two
  pre-existing bugs: the concurrent-`write()` race (next entry, fixed here) and
  `get_key_value` decoding the wrong key for a non-leading `@key` member — fixed in zidl
  (a *selective-parse family*: `deserialize_selected(KEY_FIELD_MASK)` decodes just the
  `@key` members and skips the rest, all four backends), landing here with the zidl
  v0.3.12 `build.zig.zon` bump; the scenario's `get_key_value` value assertion is staged
  for that PR (`zz-dev/zidl-v0.3.12-pin-bump-followups.md`).
- **Fix — concurrent `write()` on a single `DataWriter` was unsynchronised.**
  `DataWriterImpl.writeRaw` updated `last_sn` and the `get_key_value` key registry (a
  `HashMapUnmanaged`) with no lock, so two application threads calling `write()` /
  `dispose()` / `unregister_instance()` on the same writer — spec-legal — raced on the
  map's grow/insert and could abort on its `SafetyLock` (found by `instance` under
  ThreadSanitizer). The RTPS layer under `proto_writer` was already internally locked; now
  `last_sn` is a `std.atomic.Value` and the key registry is guarded by a dedicated
  `key_registry_mu`. `docs/design/thread-model.md` documents the guarantee. Regression:
  `test/dcps/writer_vtable_test.zig` — 6 threads × 40 keyed `write_raw` calls on one
  writer plus a concurrent `getKeyValueRaw` poller; also runs in the `test-tsan` lane.
- **Fix — unsynchronised `listener_mask` (data race).** `listener_mask` was a plain
  `u32` written unlocked by `set_listener` and read unlocked by the discovery/timer
  dispatch path (`listener_mu` only ever covered the `ListenerBox` swap beside it).
  Every *runtime* access in `src/dcps/{writer,reader,publisher,subscriber,participant,
  topic}.zig` is now `@atomicLoad`/`@atomicStore` `.monotonic`; struct-literal
  initialisers stay plain. Found by the `listener` scenario under TSan.
- **Fix — CFT `set_expression_parameters` use-after-free.** `ContentFilteredTopicImpl`
  had no synchronisation on `expr_params`: `set_expression_parameters` frees the old
  parameter strings + backing array and swaps in the new list while the receive thread's
  `matchSample` is mid-`filter_mod.eval` holding those strings by reference (SEGV in
  `parseFloat`). New `params_lock: Mutex` on the impl, held across `matchSample`'s eval
  and around the swap in `set_expression_parameters` / the read in
  `get_expression_parameters`. Found by the `cft` scenario (~40% repro at 12 threads).

## 2026-08-29

- **CI flake fix — unique DDS domain per test binary.** `zig build test` runs the ~29
  participant-creating test binaries as parallel Run steps; they all stood up participants
  on domain 0 and contended for the same fixed RTPS ports (SPDP multicast 7400, metatraffic
  unicast), so on slow runners (ARM64, DebugAllocator/TSan lanes) the loser hit
  `error.BindFailed`, discovery stalled, and a loopback test timed out. `build.zig` now
  gives each test binary's Run step a distinct `ZZDDS_TEST_DOMAIN_BASE` (per-lane counter,
  see `addTestRun`); the new `test/support/domain.zig` reads it, and every DCPS/C-ABI test's
  `create_participant` (plus `loopback_test` / `wlp_loopback_test`'s hand-wired
  `UdpTransport.init` / `SpdpSedpDiscovery.init`) uses `test_domain.get()`. Distinct domains
  map to disjoint port sets (250-port stride). `mock_loopback_test` is unchanged (it never
  binds a real socket).
- **CI flake fix — `tcp_transport_test` reconnect race.** "connectionGeneration increments
  on reconnect" replaced a fixed `sleepMs(100)` (a guess at how long the local TCP stack
  takes to process a peer FIN) with a poll-until-observed loop: drive the reconnecting
  `send()` until a new `TcpConnection` is seen, or a 5 s deadline. Same invariant asserted,
  no magic constant.
- **`ReleaseSmall` CI lane.** New `zig build test-release-small` runs the unit suite at
  `-OReleaseSmall`, wired into `run_deterministic_matrix.py` and `release.yml` (Linux
  x86_64). It forces the LLVM backend to work around a Zig 0.16 self-hosted-x86_64 codegen
  bug — read-only globals emitted without alignment at `-OReleaseSmall` — that is fixed on
  Zig 0.17 master; switch back to the plain self-hosted backend at the 0.17 bump. See
  `docs/design/ci-platform-coverage-expansion.md`.

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
