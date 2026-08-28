# Zenzen DDS — Roadmap

Forward-looking only: known gaps, planned features, and open design questions.

- Shipped work → [`../CHANGELOG.md`](../CHANGELOG.md)
- What exists today + its limitations → [`implementation_status.md`](implementation_status.md)
- Fleshed-out designs → [`design/`](design/)
- Rationale for stable decisions → [`decisions.md`](decisions.md)

> **Restructured 2026-08-27.** This file used to also hold dated shipped-work write-ups.
> Older references to sections that no longer exist here (e.g. *"WaitSet / condition
> example"*, *"Writer Liveliness Protocol implemented"*, *"DEADLINE/LIVELINESS QoS is now
> enforced automatically"*, *"Examples cleanup list resolved"*, the `create_participant_ex`
> C-ABI fix) now resolve to [`../CHANGELOG.md`](../CHANGELOG.md). *"Background thread usage"*
> is now the "Concurrency model" design task below. *"Binding design review: decision"* was a
> cross-reference to zidl; it now lives at
> `zidl/docs/design/binding-c-abi-identity.md`.

---

## Known Gaps & Deferred Work

### Discovery / RTPS / transport

- **Static and broker discovery plugins** — `src/discovery/interface.zig` and the config
  schema reserve `static` and `broker` discovery kinds, but only SPDP/SEDP and direct
  in-process discovery are implemented. Either implement static-config loading + broker
  client support, or remove the advertised config surface, before v1.
- **MTU-aware fragment sizing** — `rtps.fragment_size` is a static config value. Add an
  interface-MTU / path-MTU aware default (accounting for IP / UDP / RTPS / future security
  overhead) while keeping the explicit override for deterministic tests.
- **GUID generation platform coverage** — the fallback paths only keep unsupported targets
  building. For each supported OS, provide real entropy, PID, and monotonic-clock
  implementations.
- **Participant teardown can take several seconds** under live reliability timers.
  `beginProbe`'s hardcoded 1-second deadline per in-flight probe is a still-open root cause
  (PR #48 only fixed `UdpTransport` socket teardown). Worth a dedicated look so teardown is
  fast in all cases.
- **LocatorSelector is Phase 1 only** (per-proxy ranking). Deferred, not precluded:
  cross-proxy multicast fan-out grouping (send once for N readers sharing a multicast
  group; needs a writer-level view across the matched-proxy set; migration target
  `src/rtps/protocol_adapters.zig`); NACK-aggregation / delayed-response repair batching
  (`nack_response_delay` / `nack_suppression_duration` don't exist yet).
  `StatelessWriter.sendAll()` is intentionally not covered by the per-proxy design.
- **Transport dispatch-snapshot 64-handlers-per-port hard cap** — revisit before the
  factory pattern makes spinning up many participants easy. A small-vector inline-then-heap
  scheme, or two-phase dispatch with a generation counter, without a common-path heap alloc.
- **WLP: `BuiltinParticipantMessageReader` is RELIABLE-only** — the spec's optional
  BEST_EFFORT reader path (§8.4.13.3), including advertising
  `BEST_EFFORT_PARTICIPANT_MESSAGE_DATA_READER` in `builtinEndpointQos`, is not implemented.
  (AUTOMATIC's `lease/3`-floored-at-100ms send period is a deliberate simplification, not a
  gap.)
- **One downstream listener per port** — SPDP's single `sedp_ctx` slot is fanned out to
  SEDP + WLP via a shim, and WLP shares SEDP's metatraffic unicast listener rather than
  opening its own. A deliberate workaround for a transport that can't bind two independent
  listeners to one port.
- **Lock-order-cycle fix (unlock-before-send) not applied everywhere** — `sendAckNackLocked`
  / `handleHeartbeat`'s proxy-loop path (`reader_sm.zig`) and fragmented-change sends
  (`sendFragsToProxyLocked`, `writer_sm.zig`) still send under lock. Out of scope for the
  original fix; a mirror pass is needed.
- **`orderedRemove` / `swapRemove` audit** — several hot paths do O(N) middle-of-list
  removal (O(N²) in loops). Sweep all call sites before scaling; `commitCoherentPendingLocked`
  in `reader.zig` (`coherent_committed.orderedRemove(0)`) should become a head-index or ring
  buffer.
- **Setup-path spin-polls** (`wait_for_historical_data`, any fixed-interval
  sleep-then-recheck loop) should convert to `Mutex` + `Condvar` blocking; extend
  `ManualClock` tests to cover the condvar path.
- **`zzdds_register_instance_raw` is a pure function** (FNV1a of the key hash). A full
  implementation would pre-allocate the instance's history-cache entry, pre-warm SEDP
  discovery state, and add a `zzdds_write_raw_kind_w_handle` variant that takes a
  pre-registered handle to skip the MD5 key-hash recompute on the write hot path.
- **`PID_GROUP_DATA` (0x002D)** is defined but not serialized in SEDP announcements.
- **SPDP liveness probe has no retry** — a participant that goes silent while a probe is in
  flight is evicted on the first probe deadline.
- **TCP transport has no multicast** (`vtJoinMulticast` → `error.UnsupportedOperation`), and
  there is no "TCP for discovery too" mode — SPDP/SEDP stay on UDP even when the user-data
  transport is TCP.
- **Transport scatter-gather (`sendmsg`)** — the `Transport` vtable has no vectored-send
  entry point; `MessageBuilder`'s iovec list is flattened into a single `[65536]u8` stack
  buffer at the transport boundary before every send. See
  `design/rtps-message-builder.md`.

### DCPS / QoS

- **Keyed-instance handle without a wire key-hash** — without an inline `PID_KEY_HASH` or a
  registered `TypeSupport.compute_key_hash`, keyed samples all collapse to the NIL instance
  handle, so per-instance QoS (OWNERSHIP arbitration, KEEP_LAST-per-instance eviction,
  instance-state tracking) degrades to treating the topic as single-instance. The clean
  long-term fix is XTypes TypeLookup (below); a nearer-term option is to require
  `registerTypeSupport` for keyed topics and error rather than silently degrade. See
  `implementation_status.md` "Known Limitations" and `design/history-cache.md`.
- **`on_inconsistent_topic` and `on_data_on_readers` have zero firing sites** — the
  underlying status detection is not wired up.
- **`SampleInfo` `sample_rank` / `generation_rank` / `absolute_generation_rank`** stay at
  their defaults.
- **`wait_for_historical_data` on a BEST_EFFORT reader** has no guaranteed history wait.
- **Loan-mode `read/take_*_w_condition` retrofit** — `max_len == 0` loan-vs-copy signalling
  for the `_w_condition` family is a separate, not-yet-done retrofit (`idl/dcps.idl:1114`).
- **`@standalone` interface annotation is inert** — placed so a future validation pass has
  something to check; no codegen reads it (`idl/dcps.idl:283`).
- **`dds-rtps` `CoherentSets_1x/2x` flakiness is a test-harness issue, not zzdds** —
  `coherent_sets_w_instances` asserted a poll-timing coincidence (exactly 36 samples per
  read cycle). ~2,500 runs found no ordering/loss/tear faults in any direction or build.
  Fix PR'd to `omg-dds/dds-rtps`. See `implementation_status.md` / `decisions.md`.

### Bindings

- **Java: a few DCPS ops taking a bare `sequence<T>` parameter** (not inside a struct) throw
  `UnsupportedOperationException` (`get_datareaders`, some batch ops). `zzdds.idl`
  vendor-extension / cross-file type refs in zidl's Java backend may be partly stale versus
  later CFT / cross-file fixes — verify.
- **JNI: no stale-handle detection** — `zzdds_java_require_instance_of` accepts a
  correctly-typed wrapper whose native entity was already destroyed (a use-after-free
  class). Would need a live-handle registry, which no binding has.
- **zidl Java `@optional` scalar JNI marshaling fix is `.scalar`-only** — `@optional`
  string / nested-struct / sequence members would need the same treatment.
- **CFT filtering is not spec-compliant across all bindings yet** — the runtime `cft_filter`
  machinery works, but backends do not all generate a real `get_field_from_cdr` callback,
  so CFT/QueryCondition without a registered `TypeSupport.get_field` accessor passes all
  samples through (`raw_ops.zig:637`; see `decisions.md`).
- **`--runtime-version <N>`** zidl flag for API-tier pinning is not implemented; relevant
  once the first stable API tier is declared.
- **Idiomatic Zig binding** — a future generated `dcps_zig.zig` (closure-based listeners,
  slice-friendly QoS builders) is not built; Zig callers use the native fat-pointer vtable
  directly. `language-bindings.md`.
- **FFI bool-width mismatch risk** for hand-written, header-independent bindings of every
  zzdds C function returning `bool` (`*_is_nil`, `*_get_trigger_value`, …).
- **Example: `--publisher-matches` / `--subscriber-matches`** are parsed then silently
  ignored in all four `shape` ports (no reference implementation defines their semantics).
- **Example: Java listener replacement leaks the old JNI global reference** — a second
  `set_listener`-style call on an entity doesn't release the previous one
  (`examples/java/listener-pubsub`).

### Allocator strategy (`design/allocator-strategy.md` is source of truth)

- **Tier 2 — data-plane allocator** (a second, separate allocator for history-cache sample
  storage + CDR serialize/deserialize scratch). Blocked on the CDR-layer allocator scoping
  design task (below). Don't build ahead of a real request for the split.
- **Tier 3 — per-entity-kind / per-topic overrides** (distinct pools for readers vs.
  writers). Not designed; don't build ahead of a use case.
- **C++ generated-binding allocator injection** — `std::vector` / `std::string` in
  `--cpp-generate-impl` output use the global allocator unless `--cpp-pmr-containers` is
  passed. The remaining design question (template-parameterize generated types / standardize
  on `std::pmr` / push unbounded-field topics to bounded types) is flagged as the single
  riskiest item in the allocator plan. Also: zidl's C++ union codegen doesn't emit the
  ctor/dtor that unions with non-trivially-constructible members (`std::string`,
  `std::vector`, …) need.
- **"Zero malloc" needs an explicit definition** — not defaulted to the strongest reading.
- **History-cache per-change heap allocation** — future path: slab/pool per topic, or a
  ring-buffer of fixed-size blocks for embedded targets. `decisions.md`,
  `design/history-cache.md`.
- **Two embedded showcase apps** (`zzdds-embedded-c-example/`, `zzdds-embedded-cpp-example/`)
  are proposed, not built (M1 = bounded fields; M2 = unbounded string/sequence), along with
  an `LD_PRELOAD` malloc/new abort shim as a CI acceptance test for them.
- **Generated-class lifecycle** — the app-owned boxed-buffer allocator match is not
  structurally enforced (correct only while an entity's `_with_allocator` allocator equals
  the process-wide one; closing it needs `{Type}_free()` to take an entity parameter, a
  C-ABI shape change). `--audit-lifecycle` is a diagnostic, not a build gate, and is not
  CI-enforced. A future GC'd binding needs a codegen-generated Category-2 (`GuardCondition`)
  identity-cache registration hook. `design/generated-class-lifecycle-design.md`.

### Testing

- **`src/c_abi/extensions.zig` OOM / allocation-failure error paths are untested** (e.g.
  `factoryCreateParticipant`'s `toRuntimeConfig` catch branches) — a `testing.FailingAllocator`
  follow-up.
- **`nil.zig` is at 12% test coverage** (repetitive nil-singleton vtable wiring; low
  priority).
- **Loan use-after-free safety is enforced only by source-comment discipline**, not by a
  test — worth revisiting if this project ever gets an ASan test step.
- **No `zig build test-fuzz-bin` step** — runnable libFuzzer executables must be built
  manually (deliberate). Future fuzz targets: `fuzz_cdr_payload.zig` (low priority until
  typed binding layers exist), and the authentication / crypto layers as DDS Security is
  built.
- **Reference-app "deliberately out of scope" items** (each documented in
  `examples/docs/design/`): `run.py`-style cross-binding pass/fail harnesses (discovery,
  participant-config); the `wait_for_historical_data`-should-time-out negative case
  (catchup); `assert_liveliness()` + AUTOMATIC/MANUAL_BY_PARTICIPANT + `on_liveliness_lost`
  (presence); `*_w_timestamp` symmetry + batch instance ops (registry); Java's
  `instance_state` on the batch-take family.
- **Non-goal (recorded, not planned):** a spec-conformance harness, network simulation
  (ns-3 / CORE), and formal verification / safety certification (DO-178C, IEC 61508, ISO
  26262) — long-term concerns, not built. `design/testing-strategy.md`.

---

## Planned Features

### DDS Security v1.2 (formal/25-03-06)

The security plugin interface is a skeleton — only no-op pass-through implementations exist
(`src/security/interface.zig`, `noop.zig`); the whole transformation pipeline described in
`design/security-pipeline.md` is intended future design. Scope: Authentication (PKI-DH),
AccessControl, Cryptographic (AES-GCM), across payload / submessage / RTPS-message
protection. First step: change `Cryptographic.encode_payload` to a tagged-union return so
the noop path doesn't allocate. Note: "serialize once, N readers" breaks under
payload/submessage protection (per-reader session keys); mitigation is shared governance /
multicast-group keys. A pooled encryption scratch buffer in `MessageBuilder` is part of the
planned path. Security-handshake interop testing follows when the plugin exists.

### DDS-XTypes v1.3 + TypeLookup

TypeObject / TypeIdentifier / TypeMapping, for type-safe cross-vendor type discovery. There
is no TypeLookup service today, so `PID_TYPE_INFORMATION` is emitted only on writer
announcements (advertising it without a working TypeLookup stalls OpenDDS) and omitted from
reader announcements (the GET_TYPES round-trip isn't implemented). This is also the clean
long-term fix for the keyed-instance-NIL gap above. Remaining TypeSupport work: the C-ABI /
non-Zig binding bridge, then TypeLookup integration. `design/thread-model.md`.

### Configurable allocation for embedded/real-time targets

Full plan, inventory, and phase ordering in
[`design/allocator-strategy.md`](design/allocator-strategy.md). Tier 0 (C-ABI bootstrap
injection — `zzdds_create_factory_with_allocator`) and Tier 1 (the `get_c_abi_handle` cache)
are done. Remaining: Tiers 2 & 3 and the C++ generated-binding injection design (see Known
Gaps above), plus the embedded showcase apps.

### Cross-binding DCPS API test-coverage buildout

[`design/dcps-api-coverage-audit.md`](design/dcps-api-coverage-audit.md) inventories the
DCPS operations, statuses, and QoS behaviours with zero or unverified coverage across the
four example bindings, and proposes two new test tiers on top of the existing Tier 1–4
model:

- **Integration tier** — liveliness / status marshaling per binding; SAMPLE_REJECTED /
  SAMPLE_LOST; `enable()` / `autoenable_created_entities=false`; late-joiner durability
  replay; `ignore_*` across two processes; runtime `set_expression_parameters` CFT
  reconfiguration; coherent/ordered grouping atomicity across multiple writers;
  `_w_timestamp` source-timestamp propagation; `delete_contained_entities` across the C-ABI.
- **Stress tier** — reentrant-listener / entity-lifecycle churn; WaitSet/Condition churn
  under load; listener-fallback chain under load; many-participant SPDP/SEDP fan-in/out;
  rapid DataWriter/DataReader create/delete during SEDP matching. Plus a loaned-read example
  (loan lifecycle has zero C/C++ coverage today — nothing stops a C/C++ caller reading a
  returned loan).

Harness is Python, reusing the examples' `_common.py` pattern.

### Language bindings — Python / .NET / Rust

Distribution model in [`language-bindings.md`](language-bindings.md). The zidl backends that
generate these don't exist yet — see `zidl/docs/roadmap.md`.

- **Python / .NET** — inline CDR; C-ABI layer via ctypes / P/Invoke.
- **Rust** — dual-mode: `pure` (via `zidl-rs`) and `zig-ffi` (for embedded/perf).

### dds-rtps interop suite — upstream coverage gaps

[`design/dds-rtps-interop-suite-audit.md`](design/dds-rtps-interop-suite-audit.md) records
areas the upstream OMG dds-rtps test suite doesn't exercise (RESOURCE_LIMITS,
TRANSIENT/PERSISTENT durability behaviour, `--datafrag-size`, KEEP_LAST eviction, deadline
re-arming, multi-topic, post-match ownership re-arbitration, BEST_EFFORT / MTU-boundary
large data, XCDR1/2 content round-trip). These are gaps in the *upstream* suite, not zzdds
work items — revisit only if we upstream fixes or need the coverage for our own validation.

---

## Design Tasks — not yet scoped

### Concurrency model

zzdds has never stated an overall concurrency strategy — one-thread-per-concern has been the
default every time a new periodic need came up (the DEADLINE/LIVELINESS timer thread is the
tenth `std.Thread.spawn` site; five of the ten are pure periodic-tick threads with no
socket). The intended direction, to be validated by this task: support **both** a
direct-threading model and an evented model, user-selectable (build-time configuration is
acceptable if a runtime switch proves impractical). The design must account for:

- **RTOS and bare-metal embedded targets** — no OS threads; the evented path degrades to a
  single-threaded `drive(timeout)` pump (see the next entry — the embedded face of this
  same decision).
- **Test strategy across build configurations** — correctness (ordering, liveliness,
  teardown, no races) must be verified for every supported concurrency config; today's TSan
  lane assumes the threaded model.
- **Thread consolidation** as a sub-item — whether the periodic-tick threads
  (DEADLINE/LIVELINESS, interface-change poll, wire-trace flush; possibly heartbeat and
  SPDP) collapse onto one scheduler regardless of the model chosen.

Output: a design doc; the roadmap keeps a pointer.

### Single-threaded / embedded `drive(timeout)` API

Even a minimal two-participant setup runs several background threads. An embedded target
needs a `DomainParticipant.drive(timeout)` that pumps transport polling + `checkTimers()`
from the caller's loop with no threads spawned. The design keeps this possible (non-blocking
transport seams, explicit `checkTimers()`) but nothing implements it. Scoped together with
the concurrency-model task above.

### CDR-layer allocator scoping vs. the entity layer

There is a real seam between two allocator layers that Tier 2/3 sit on top of:

- The **entity layer** already takes per-entity allocators
  (`zzdds_create_factory_with_allocator`, the `_with_allocator` entity constructors).
- The **CDR layer** (`zidl-cdr`, used to decode string/sequence fields inside samples) is a
  single **process-wide** global by an explicit zidl design decision — a decoded field is
  later freed by a generated `{Type}_free()` with no per-call context.

Consequences to resolve: (1) Tier 2's "separate data-plane allocator" premise is only
partly achievable while CDR-decoded field storage is process-wide; (2) the
generated-class-lifecycle doc documents a correctness hazard when an entity's
`_with_allocator` allocator differs from the process-wide CDR one. Options span promoting
the CDR allocator to per-participant (a zidl API change), constraining entity allocators to
always equal the process-wide CDR one, or splitting "scratch/temp" from "owned sample field
storage". Output: a design doc.

### zidl plugin architecture

zzdds owning a set of zidl binding plugins that supply "which concrete class implements
interface X", instead of `build.zig` hand-listing `--cpp-impl-override` flags. Feasibility
and shape are open — see `zidl/docs/roadmap.md` "Plugin architecture".

---

## CI / Release Platform Coverage

Audit of `build.zig` options, `scripts/run_deterministic_matrix.py`, `ci.yml`, and
`release.yml` against the platform/build-type matrix they exercise. Original ranking
2026-08-16; progress notes below from PR #65 (2026-08-18) and the 2026-08-28 CI pass.

### Landed

- **DebugAllocator lane on `test-other`** (PR #65) — `zig build test -Ddebug-allocator=true`
  now runs on Linux ARM64, macOS ARM64, and Windows x86_64, additive to `test-linux`'s
  existing step.
- **`ReleaseFast` built and tested** (PR #65) — `run_deterministic_matrix.py` gained a
  `release-fast` step (so `test-linux` covers it on Linux x86_64) and `release.yml`'s `test`
  job runs `zig build test -Doptimize=ReleaseFast` on all four platforms.
- **C/C++ binding smoke tests everywhere** (PR #65 for `ci.yml`; 2026-08-28 for `release.yml`)
  — `zig build test-bindings -Dc-binding -Dcpp-binding` runs on all `test-other` /
  `release.yml` `test` platforms (Java added on Linux ARM64 + macOS; Java-on-Windows
  deferred, see below).
- **Prebuilt library bundles** (2026-08-28) — `release.yml`'s new `package-libs` job builds
  the C/C++ install tree (dynamic `libzzdds` + static `libzidl_cdr` + headers + pkgconfig +
  CMake package files) on each of the four release platforms, verifies completeness, and
  uploads a per-platform tarball that `publish` attaches to the GitHub release. Functional
  coverage of the bundled libraries is the `test` job's `test-bindings` step.

### Deferred (investigation trails exist)

- **Java/JNI binding smoke test on Windows** — `java.exe` exits code 9 with no crash file at
  the first JNI call; leading hypothesis is a Control Flow Guard mismatch between `jvm.dll`
  and the zig-cc-built zzdds DLLs. Needs WinDbg on real Windows hardware. Trail:
  `zz-dev/windows-jni-crash-investigation.md`.
- **TSan lane on macOS ARM64** — even `test-tsan-self-check` segfaults before app code;
  likely an upstream Zig/LLVM `libtsan` gap (`pthread_introspection_hook_install` private-API
  drift). Revisit when Zig bundles a newer LLVM. Trail:
  `zz-dev/macos-tsan-crash-investigation.md`. (TSan on Windows: Clang/LLVM has no supported
  target. Extending `examples-tsan` to macOS is a separate follow-up.)
- **`ReleaseSmall` gate** — attempted 2026-08-28, **not viable yet**. `zig build test
  -Doptimize=ReleaseSmall` produces 37 `panic: incorrect alignment` crashes, all in
  `bootstrap_test` and `typesupport_test`, all through `zidl-rt`'s
  `entity_box.zig` `unboxAsView` (`@alignCast(box.vtable)`) on the C-ABI shared-box /
  WaitSet / TypeSupport paths. `Debug`, `ReleaseSafe`, and `ReleaseFast` are all clean — so
  this is a real latent alignment bug surfaced only by ReleaseSmall's layout, not a
  test-depends-on-a-safety-panic issue. Root-cause before gating on ReleaseSmall.

### Still open, ranked

1. **Real vendor/self RTPS interop** (Connext / Cyclone / CoreDX / self) runs only on Linux
   x86_64 — no wire / discovery / CDR coverage on Windows, macOS, or ARM64.
2. **No Intel macOS coverage** — `macos-latest` is Apple Silicon only.
3. **No musl / static Linux target** — always glibc, always the native triple; `-Dtarget`
   is never actually cross-compiled.
4. **Valgrind has no viable non-Linux equivalent** — treat as Linux-only unless a specific
   non-Linux memory bug motivates revisiting.

---

## Deferred / Out of Scope for v1

- **DDS-RPC** — deferred; no concrete use case yet.
- **DDS-XRCE** — embedded profile; a separate project or downstream fork.
- **TRANSIENT / PERSISTENT durability** — requires a persistence service; deferred.
- **MultiTopic** — complex; deferred. `vtCreateMultiTopic` (`src/dcps/participant.zig`)
  always returns nil and no `MultiTopicImpl` exists. A binding's `create_multitopic`
  *marshaling* can work correctly all the way to the nil return with no error — easy to
  mistake for partial functionality. It isn't; nothing behind it works in any binding.
- **Retroactive unmatching for ignored publications/subscriptions** — the ignore APIs
  filter future discovery callbacks; ignoring an already-discovered endpoint is a permitted
  no-op. Actively removing existing RTPS proxies is deferred unless a use case needs it.
- **Platform-specific InterfaceMonitors** — `monitor/netlink.zig` (Linux),
  `monitor/pf_route.zig` (macOS/BSD), `monitor/windows.zig` (NotifyIpInterfaceChange) —
  deferred; the polling monitor is sufficient.
- **True zero-copy (zero serialization) / raw native-representation (POD) loans** — out of
  scope, not just deferred. A loan that hands the application a pointer to an unserialized,
  fixed-layout native struct is fundamentally at odds with IDL as a platform-agnostic data
  representation, and with the QoS, security, and RTPS wire assumptions the rest of the
  stack relies on. Applications needing that class of performance should use a mechanism
  that doesn't carry representation-independence, QoS, or security. The **raw-byte loan**
  APIs (`take_raw`/`read_raw`/`loan_raw` — the application serializes directly into, or
  reads directly out of, an internal CDR buffer) stay and are the supported "avoid a copy"
  path.
- **SHMEM transport** — not in v1; UDP covers current use cases. Possible later, alongside
  UDP/TCP. Using SHMEM for the RTPS History Cache *storage* (with RTPS/UDP scaffolding, as
  Connext does) is also possible future work; neither implies zero serialization. Locator
  kinds, PIDs, and protocol-interface hooks exist as scaffolding
  (`src/transport/interface.zig`, `src/rtps/pid.zig`, `src/protocol/interface.zig`).
- **Other protocol/discovery plugins** — QUIC, MQTT, custom hardware channels, and
  mDNS/DNS-SD are extension points only; no v1 implementation is planned.
- **PKCS#11** — out of scope for v1; the security plugin interface must not preclude it.
- **Standalone `zz-iot/zzdds-examples` GitHub repo** — not yet archived/deleted after the
  fold into `examples/` (0 stars/issues/PRs, so no audience being misdirected).

---

## Open Questions

- **Key material storage** — file-based PEM certs to start when DDS Security is implemented;
  HSM abstraction deferred.
