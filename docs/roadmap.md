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
- **SPDP's single downstream slot** — SPDP's single `sedp_ctx` slot is fanned out to SEDP +
  WLP via a shim (`combined.zig`'s `DiscoveredFanout`). Still current. WLP itself sharing
  SEDP's metatraffic unicast listener rather than opening its own is *not* a transport
  limitation, though — `vtListen` has supported a second `listen()` call sharing one
  `PortEntry` via `addHandler` since the initial commit (see
  `docs/design/rtps-submessage-routing.md` §6; `participant.zig`'s `userDataOnReceive`
  does exactly this for the same port as of 2026-09-16). WLP is a reasonable candidate to
  migrate onto a plain second `listen()` call, decoupling it from SEDP's internals — small,
  low-risk, not yet done.
- **Entity-ID-based RTPS submessage routing** — today, every handler registered on a port
  independently re-parses the full raw message and filters for entity IDs it owns
  (`sedp.zig`'s `onReceive`, `participant.zig`'s `userDataOnReceive`). A single shared
  parse, routing each decoded submessage to the one handler responsible for its entity ID
  (builtin vs. user, cheaply classified from the entity kind's own bit pattern — see the
  doc), would remove the redundant parsing and make which physical port a peer sends to
  irrelevant. Bigger than it looks: changes `ReceiveHandler`'s contract everywhere it's
  implemented. Not scheduled. `design/rtps-submessage-routing.md`.
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
  - *Mitigated for zzdds→zzdds:* a writer whose `TypeSupport.has_key` is set now emits an
    inline `PID_KEY_HASH` on **every** sample (RTPS §8.7.9), including a zero-valued key —
    previously suppressed as all-zeros — so the subscriber routes by the wire hash and
    never reconstructs one from the payload. `resolveKeyHash` also now honours a *present*
    all-zero `PID_KEY_HASH` instead of treating it as "recompute".
  - *Fixed for a non-zzdds peer omitting the inline hash* (2026-09-14, zidl pin →
    `v0.3.17`): `resolveKeyHash` now dispatches on change kind — `TypeSupport.compute_key_hash`
    (zidl's `computeKeyHashFromCdr`, `deserializeSelected(KEY_FIELD_MASK)`-based, reads a
    non-leading `@key` correctly) for ALIVE, `TypeSupport.compute_key_hash_key_only` (zidl's
    `computeKeyHashFromCdrKeyOnly`) for DISPOSE/UNREGISTER's genuine key-only payload. Wired
    end to end: the C-ABI surface every binding registers through
    (`zzdds_register_type_support`/`_ctx`) carries the new function pointer, the C/C++ zidl
    backends' generated registration wrapper passes it, Java's JNI bridge resolves it by
    reflection, and every one of zzdds's own `examples/`/`stress-tests/` registrations
    passes it — see `CHANGELOG.md` 2026-09-14. Closed; not a gap anymore.

### Selective CDR parse (`deserialize_selected`) — deferred follow-ups

zidl v0.3.12 adds a mask-driven selective parser (`deserialize_selected(want)` /
`KEY_FIELD_MASK` / `field_index`, `skipPrimitives` fast path) across all four backends, and
rewires `get_key_value` and `get_field_from_cdr` onto it. Three refinements
were deliberately left out of that change; none is a regression (each is a new capability
or an optimisation on an already-improved path):

- **Batched one-pass multi-field filter reads** — a CFT/QueryCondition referencing N fields
  currently does N `deserialize_selected` walks (one per field reference). Resolve the
  filter AST's whole referenced-field set to one `FieldMask` at condition-creation and do a
  single walk per sample. Needs a `filter_mod` `FieldAccessor` API change (pull API → cache
  the parse, or pre-resolve fields in `eval`). Impact of deferring: a redundant struct walk
  per extra referenced field per sample — pure CPU, proportional to filter complexity × rate.
- **Nested field paths (`a.b.c`) in filter expressions** — the DDS filter grammar (DDS 1.4
  Annex A) allows dotted member navigation and `[n]` subscripts; zzdds only supports
  top-level simple members (always has — `get_field_from_cdr` / `classifyFilterFieldKind`).
  Needs grammar/parser/AST/evaluator changes in `filter_mod` plus a `Spec`-tree form of
  `deserialize_selected` for selective descent (the `u64` mask primitive was built to
  accept this later without rework). ~1 day with full-decode of wanted nested structs,
  ~2 days fully selective. Impact of deferring: a nested field reference silently never
  matches (unknown field → `eval` passes the sample) — a pre-existing gap.
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
- **`--runtime-version <N>`** zidl flag for API-tier pinning is not implemented, and
  deliberately stays that way pre-1.0 — there is no stable API tier to pin and declaring one
  is not a near-term goal (`decisions.md` → Versioning / Releases). Consumers pin an exact
  release instead.
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
  participant-config); `assert_liveliness()` + AUTOMATIC/MANUAL_BY_PARTICIPANT +
  `on_liveliness_lost` (presence); `*_w_timestamp` symmetry + batch instance ops (registry);
  Java's `instance_state` on the batch-take family. The `wait_for_historical_data`-should-
  time-out negative case left out of `catchup` itself is no longer on this list — it's
  covered by the `wait-for-historical-data` Integration-tier scenario instead (see
  `docs/design/dcps-api-coverage-audit.md`).
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

### Discovery/association race testing — resolved via `on_reliable_writer_ready`

[`design/discovery-association-race-testing.md`](design/discovery-association-race-testing.md)
— **resolved 2026-09-18.** Found via a real bug (during rmw_zzdds CI flake
investigation) that first looked like a `StatefulWriter.addMatchedReader` correctness
defect (a newly-matched VOLATILE reader's `start_sn` set from the writer's own cache
position at match time, silently excluding a sample the application wrote right after
seeing itself "matched" from the reader side alone, before the writer's own asymmetric
discovery caught up). Working through the fix design concluded this is actually correct
VOLATILE-durability behavior — no `start_sn` fix exists or is needed. The real fix:
`DataReaderListenerEx.on_reliable_writer_ready`, a new reader-side extended-listener
callback (symmetric to the existing writer-side `on_reliable_reader_ready`) that fires
once a matched RELIABLE writer has been observed to actually register this reader (a
HEARTBEAT whose RTPS §8.3.7.5 `readerId` names it specifically, real wire behavior
already sent by `StatefulWriter`; immediately at match for BEST_EFFORT). Landed in
zzdds core (IDL, `reader_sm.zig`, `protocol/interface.zig`,
`rtps/protocol_adapters.zig`, `dcps/participant.zig`, `dcps/reader.zig`,
`dcps/subscriber.zig`, `c_abi/extensions.zig`), full test coverage
(`test/rtps/reader_sm_test.zig`, `test/dcps/mock_loopback_test.zig`), `zig build test`
and `test-tsan` both clean, C/C++/Java bindings all build clean. **Deferred, separate
follow-on:** `rmw_zzdds`'s `rmw_service_server_is_available()` actually registering and
consuming this new listener in place of its current
`rmw_subscription_count_matched_publishers` check — needs a zzdds release first. The
test-infrastructure proposals in the design doc (scenario matrix, shared verification
utility, `MockNetwork`-based pinned-order tests) remain useful groundwork for the
broader discovery/association race space independent of the superseded `start_sn`
framing.

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

- **Integration tier** — landed in `integration-tests/` (structure, cross-binding matrix
  strategy, and the full scenario backlog spec'd in
  [`design/integration-test-tier.md`](design/integration-test-tier.md)), CI-gated in
  `ci.yml`. Scenario #1, **coherent/ordered access grouping atomicity across multiple
  writers**, is done: `coherent-sets`, all four bindings, the same 8-pair cross-binding
  subset `raw-loan` uses. Building it found and fixed a real bug — not in discovery
  (an initial hypothesis pointing at SPDP's `beginProbe`/participant-lost path turned out to
  be a red herring, ruled out with live instrumentation) but in `DataReaderImpl.hasPendingDataFn`
  (`src/dcps/reader.zig`): a GROUP-scope coherent set is promoted into `pending` only by
  `begin_access()` → `commitCoherentPendingLocked`, but the app only calls `begin_access()`
  once a `WaitSet` wakes it — and the trigger only checked `pending`, not
  `coherent_committed_ready`. Once the first coherent set drained back to empty, the
  `WaitSet` would never wake again even with further complete sets sitting in
  `coherent_committed`, permanently starving a `wait() -> begin_access() -> take() ->
  end_access()` loop after its first iteration. One-line fix (`hasPendingDataFn` now also
  checks `coherent_committed_ready`); verified via the direct pub/sub repro (hung
  reproducibly before, clean 20/20 after) and the full cross-binding harness. Scenario #2,
  **`delete_contained_entities` bulk-teardown correctness**, is also done: a "session"
  builds a small entity tree (2 DataWriters, a plain DataReader, a
  ContentFilteredTopic-backed DataReader, a WaitSet-attached ReadCondition) then tears it
  all down in one `delete_contained_entities()` call instead of deleting each child first.
  Found and fixed a real bug: `DomainParticipantImpl.vtDeleteContained`
  (`src/dcps/participant.zig`) drained `publishers`/`subscribers`/`topics` but never
  `cft_topics` — `delete_contained_entities()` reported RETCODE_OK while leaving a
  ContentFilteredTopic behind, so the immediately-following `delete_participant()` always
  failed with PRECONDITION_NOT_MET for any app that had created one. One-line fix
  (mirroring the exact drain-outside-lock pattern the participant's own `deinit()` already
  used for `cft_topics`); verified the same way — direct repro failed with
  PRECONDITION_NOT_MET before, passed cleanly after, deliberately re-broken once to confirm
  the fix is load-bearing. Scenario #3, **SAMPLE_REJECTED / SAMPLE_LOST**, is also done:
  `sample-rejected-lost` -- a "slow consumer" scenario with three topics.
  `RejectedTopic` (RELIABLE, KEEP_ALL): a reader with tight `resource_limits`
  (`max_samples`/`max_samples_per_instance` = 3) deliberately never drains until it has
  confirmed rejection, so the publisher's 5 back-to-back writes overflow it (2 rejected, 3
  buffered — asserted as a count-conservation invariant, not a hardcoded split).
  `LostTopic` (RELIABLE, KEEP_LAST depth=1, TRANSIENT_LOCAL): the writer writes+evicts 5
  samples *before* any reader is matched at all, and the subscriber deliberately defers
  creating that reader until a `SyncTopic` signal confirms the publisher is done — a
  genuine, deterministic late-join gap, not a real-time ack race. An earlier version of
  this scenario tried racing fast writes against an *already-matched* reader (hoping
  `writer_sm.zig`'s KEEP_LAST-eviction GAP-notification would fire); it didn't, because
  localhost round-trips are fast enough that each sample got acked before the next write
  evicted it — a good example of the same "looked solid on paper, wrong in practice"
  lesson scenario #1's SPDP hypothesis taught. No zzdds core bug found this time — the
  mechanisms (`RESOURCE_LIMITS` rejection, HEARTBEAT-implied-gap loss detection) both
  worked exactly as documented once the scenario itself was designed correctly. Scenario
  #4, **`enable()`/`autoenable_created_entities`**, turned out not to be a test-coverage
  gap at all: `vtEnable` was a uniform no-op (`return RETCODE_OK`) across every entity
  type, with no `NOT_ENABLED` precondition anywhere and every entity fully
  live/discoverable the instant it's constructed regardless of QoS. Done end to end
  (2026-09-21): real semantics landed first, then the `enable-defer` Integration-tier
  scenario built against them (`integration-tests/{c,cpp,java,zig}/enable-defer`, same
  8-pair cross-binding matrix as scenarios #1-#3) — a "configuration phase" app that builds
  a disabled Publisher+DataWriter tree, proves `write()` on the still-disabled writer fails
  and enabling a child before its own factory returns `PRECONDITION_NOT_MET`, then enables
  top-down and confirms a live peer observes zero matching beforehand and clean
  matching/data exchange immediately after.
  - **Root-cause bug found in the process**: generated `EntityFactoryQosPolicy{}.autoenable_created_entities`
    defaulted to `false` — inverted from the DDS spec's `true` — because `idl/dcps.idl`'s
    field had no `@default` annotation, so zidl emitted the type's zero-value. Fixed with
    `@default(TRUE)`; harmless until real gating landed (the field was never read anywhere
    in `src/` before this), but would have silently made every entity in every example
    disabled-by-default the moment gating went live. Found and fixed one real fallout:
    `examples/c/shape/src/shape_main.c` builds its QoS via `memset(..., 0, ...)` then sets
    only the fields it cares about — the one place in the whole tree relying on the old
    (wrong) zeroed default.
  - **`enabled: std.atomic.Value(bool)`** added to all six entity impl types
    (`src/dcps/{participant,publisher,subscriber,reader,writer,topic}.zig`), seeded from
    the *parent's* `entity_factory.autoenable_created_entities` QoS at construction. Real
    `enable()`: no-op if already enabled, `PRECONDITION_NOT_MET` if the parent isn't itself
    enabled (spec: can't enable a child before its factory), otherwise flips the flag and
    performs the previously-deferred wire action (participant: `start()`; writer/reader:
    the SEDP publication/subscription announcement). `NOT_ENABLED` precondition guard added
    across ~90 non-exempt operation call sites (spec exempts `set/get_qos`,
    `set/get_listener`, `get_statuscondition`, `get_status_changes`, `enable`,
    `get_instance_handle`).
  - **Two design mistakes caught and fixed during implementation, not assumed away**: (1) a
    participant's own enabled state must come from the *factory's* QoS
    (`DomainParticipantFactoryQos.entity_factory`), not the `DomainParticipantQos` being
    applied to the new participant (which governs its children, not itself); (2) gating the
    six `create_*` factory operations on the *caller's* own enabled state would have made it
    impossible to ever build a disabled entity tree at all — the entire point of
    `autoenable_created_entities=false`. Caught via a failing test proving the opposite
    should work, not assumed correct.
  - Deferring only the outbound SEDP announcement (not the surrounding proto-writer/
    incompat-QoS/matched-notify bookkeeping) was confirmed empirically sufficient to prevent
    all discovery/matching while disabled — new mock-transport test,
    `test/dcps/mock_loopback_test.zig`. Verified by deliberately removing the guard once
    (exactly one test failed) and restoring it.
  - `zig build test` 1122/1122, `examples/run_all.py --strict` and
    `integration-tests/run_all.py --strict` (existing 3 scenarios, 24 pairs) both clean —
    zero regression from a change touching every entity's construction path.
  - **Deliberately left ungated, disclosed not overlooked**: `get_domain_id`/`get_current_time`
    (participant), `get_type_name`/`get_name` (topic) — harmless static getters, no clean
    `NOT_ENABLED`-compatible sentinel for their return types. `ContentFilteredTopic`'s own
    operations — it's a `TopicDescription`, not a spec `Entity`, so it has no `enable()`
    semantics at all.
  - **Building the `enable-defer` scenario found the "worth revisiting" judgment call above
    was actually wrong, and fixed it**: gating `set/get_default_datawriter_qos` (and the
    analogous default-QoS/`copy_from_topic_qos` family on Publisher, Subscriber, and
    DomainParticipant) behind `NOT_ENABLED` broke exactly the workflow ENTITY_FACTORY exists
    for — a disabled Publisher's own `get_default_datawriter_qos()` returned
    `NOT_ENABLED` and left the output struct entirely uninitialized; a caller that (like the
    scenario's own first draft) didn't check the return code got a writer built from garbage
    QoS instead of a clear error to act on. Same reasoning as `create_datawriter` itself not
    being gated on the Publisher's own state: default-QoS/copy-from-topic operations
    configure *future children*, they don't operate the entity itself. Un-gated the six
    default-QoS operations plus `copy_from_topic_qos` on Publisher/Subscriber, and the
    `get_participant`/`get_topic`/`get_publisher`/`get_subscriber` navigational getters
    (same "pure accessor, no side effect" category as the already-exempt
    `get_instance_handle`) across all six entity types.
  - **Two more real bugs found and fixed while building the scenario, unrelated to the
    gating audit above**: (1) `onReaderDiscovered`/`onWriterDiscovered`
    (`src/dcps/participant.zig`) matched a newly-discovered remote reader/writer against
    *every* local `active_writers`/`active_readers` entry regardless of that entry's own
    `enabled` state — a disabled writer that never announced itself could still be
    incorrectly matched (and its `on_publication_matched` incorrectly fired) purely because
    a compatible remote reader happened to be discovered first. Fixed by skipping disabled
    entries in both scan loops. (2) `DataWriterImpl.writeRaw` (`src/dcps/writer.zig`) — the
    native-Zig call path (via `raw_ops.zig`, used by every zidl-generated Zig `write()`/
    `dispose()`/`unregister_instance()`) bypassed the `NOT_ENABLED` guard entirely; only the
    C-ABI's `vtWriteRaw` checked it before delegating to this same function. A disabled
    writer's native-Zig `write()` silently succeeded instead of erroring. Fixed by adding
    the same one-line check inside `writeRaw` itself, protecting every caller of it, not
    just the C-ABI entry point.
  - `zig build test` 1122/1122, `examples/run_all.py --strict`, and
    `integration-tests/run_all.py --strict` (all 4 scenarios, 32 cross-binding pairs) all
    clean.

  Scenario #5, **`wait_for_historical_data`**, is also done — see the "Reference-app
  'deliberately out of scope' items" note above for the negative-case detail it closes.
  Scenario #6, **`ignore_participant`/`ignore_topic`/`ignore_publication`/
  `ignore_subscription`**, is also done, as `ignore-entities` — the only scenario in this
  tier needing three processes (ignorer/peer/bystander), since `ignore_participant()` would
  blackhole a whole participant `peer` needs to keep serving the other three ops. Central
  design fact the scenario is built around: `ignore_topic`/`ignore_publication`/
  `ignore_subscription` are a strictly one-sided, local filter (DDS spec: "locally
  ignore") — the non-ignoring side legitimately keeps reporting itself matched, so every
  assertion lives on the ignoring side alone. Found and fixed a real bug in the process:
  `participant.zig`'s retroactive-match scan (`subAnnounceProtoReader`/
  `pubAnnounceProtoWriter`, run when a new local reader/writer is created, to match it
  against an already-discovered remote entity) never checked the ignore lists — so a
  remote entity discovered *before* being ignored stayed retroactively matchable to a
  local entity created *after* the ignore call, exactly backwards from the ignore
  operations' contract. A Zig-unit-test mock reproduction attempt (in `ignore_test.zig`)
  didn't reliably exercise the retroactive-match path at all (reverted, unused); the real
  cross-process scenario caught it directly. Fixed by mirroring the live-discovery
  callbacks' own three ignore-list guards into both retroactive scans.

  A second, unrelated bug surfaced afterward as intermittent interop-test failures that
  first looked like a networking/port-collision issue (it was not — `ss -ulnp` during a
  live failure showed clean, non-colliding port allocation across every process). The real
  cause was two-fold: (1) a genuine harness-ordering bug — `ignore_entities_cross_binding_test.py`
  started `peer` and `bystander` concurrently, so `get_discovered_participants()`'s
  `handles[0]` was ambiguous between the two (no ordering guarantee across simultaneously-
  discovered participants); fixed with a strict 3-phase startup (ignorer alone → bystander →
  peer only once ignorer confirms `ignore_participant()`) across all 4 bindings' harnesses.
  (2) The real, 100%-reproducible bug once (1) was fixed and isolated: `ignorer.c`/
  `ignorer.cpp` only called `fflush(stdout)` after their *first* marker print
  (`"ready for bystander."`); every later marker (`"ignore_participant() applied..."`, etc.)
  was left in glibc's fully-buffered (non-tty) stdio buffer, invisible to the log file the
  Python harness's `wait_for_marker()` polls live. The C/C++ ignorer was in fact discovering
  and correctly ignoring bystander every time (confirmed with temporary
  `std.debug.print` instrumentation in `participant.zig`'s `onParticipantDiscovered`/
  `vtGetDiscoveredParticipants`/`vtIgnoreParticipant`, all shared, binding-agnostic core
  code) — the harness just never saw the marker before timing out and killing the process,
  which discarded the unflushed buffer. Zig's `std.debug.print` and Java's `println` don't
  have this failure mode, which is why only C/C++-as-ignorer triples ever failed. Fixed by
  adding `fflush(stdout)` after every required marker `printf`/`std::printf` in both files.
  Also tried and reverted an `IFF_RUNNING` check in `src/transport/monitor/polling.zig`'s
  interface enumeration (theory: a carrier-down interface like `docker0` could be picked
  first for `IP_MULTICAST_IF`) — reverted because this VM's real, working `eth0` also
  reports no `IFF_RUNNING` bit despite `ip link show` showing `LOWER_UP`, so the check
  excluded every non-loopback interface here and made things worse; left as a comment for
  future reference rather than landed. `zig build test` 1123/1123 clean throughout; the
  fixed scenario reran clean twice in a row, 8/8 cross-binding triples each time. See
  `integration-tests/README.md` for the full scenario writeup.

  Scenario #7, runtime **`set_expression_parameters` CFT reconfiguration**, is also done,
  as `cft-reconfigure` — behavioral correctness (does changing parameters without
  recreating the CFT actually re-filter subsequent samples), distinct from the stress
  `cft` scenario's concurrency-safety coverage. Also closes the CFT introspection gap the
  API audit flagged as completely untested (`get_filter_expression`/
  `get_expression_parameters`/`get_related_topic` — "CFT is set once at creation, never
  read back or changed"). Two processes (publisher/subscriber) writing two batches (seq
  0..4, then 5..9) around a live `set_expression_parameters()` call on the same CFT/reader
  — no recreation. Core assertion: the filtered reader's final set is *exactly* `{5..9}`,
  proving both that subsequent samples are genuinely re-filtered against the new parameter
  and that already-dropped samples (seq=3,4, both `>=` the *new* threshold) are never
  retroactively delivered — CFT filtering is a one-time decision at receive time, not
  replayed against history. Found a real Zig-native-binding gotcha (not a zzdds core bug):
  the raw `zzdds.registerTypeSupport()` call Zig-native apps use directly (bypassing the
  generated `TypeSupport.register()` wrapper C/C++/Java go through) doesn't wire up
  `TypeSupport.get_field` automatically — without it, a CFT reader silently receives
  everything unfiltered, no error anywhere. Every zidl-generated Zig type provides a
  matching `getFieldFromCdr` for exactly this; must be passed explicitly. Found because
  C/C++/Java all worked immediately while the Zig port's filtered reader passed everything
  through unfiltered on the first run. Also bumped `MATCH_TIMEOUT_MS` (40s, not this
  tier's usual 20s) and the subscriber's matching `WITNESS_TIMEOUT_MS` (45s): this
  scenario waits for two readers to match (witness + filtered), and showed intermittent
  timeouts specifically as the first Java pair run right after a from-scratch 4-binding
  rebuild (JVM cold-start contending with residual build-tail CPU/IO load) — reproduced
  twice at the default 20s, clean 3/3 after the bump. `zig build test` clean; the fixed
  scenario reran clean 3 times in a row, 8/8 cross-binding pairs each time. See
  `integration-tests/README.md` for the full scenario writeup.

  Scenario #8, the **`_w_timestamp` family** (`write_w_timestamp`/`dispose_w_timestamp`),
  is also done, as `source-timestamp` — does an explicit, caller-supplied source timestamp
  genuinely propagate to `SampleInfo.source_timestamp` on the receiving side, or does
  something silently substitute "now"? Two processes writing 5 samples with fabricated,
  deterministic explicit timestamps (~11.5 days since epoch — nowhere near real wall-clock
  time, so a substitution bug shows up as an immediate wrong-value failure, not a flaky
  near-miss), then disposing the instance with its own distinct explicit timestamp
  including a nonzero nanosecond component. **Found and fixed a real zzdds core bug on the
  very first real cross-process run**: `src/util/time.zig`'s `RtpsTimestamp.fromTime()`/
  `.toTime()` (and `RtpsDuration.fromDuration()`) used plain truncating division for the
  RTPS wire fraction↔nanosecond conversion (fraction = 1/2^32-second units); composing
  floor(floor(x)) across the round trip systematically lost ~1ns for nearly any nonzero
  nanosecond value — the dispose sample's explicit nanosecond `123456789` came back as
  `123456788`. `RtpsDuration.toDuration()` already did this correctly (round-to-nearest +
  carry-into-seconds handling); the fix brought the other three conversions in line with
  it. Zero-nanosecond writes never triggered this (0 is trivially exact either way) — only
  the dispose call's nonzero nanosecond exposed it. `zig build test` clean; the fixed
  scenario reran clean twice, 8/8 cross-binding pairs each time. See
  `integration-tests/README.md` for the full scenario writeup.

  Scenario #9, the last item in the backlog, **`on_liveliness_lost`/AUTOMATIC/
  MANUAL_BY_PARTICIPANT**, is also done, as `liveliness-lost` — closing out the whole
  Integration-tier spec doc's scenario list. Liveliness/status marshaling per binding is
  substantially covered by the `presence` example (see "Reference-app" note above under
  Testing) — cross-process, all 4 bindings + 8 same/cross-binding pairs, found and fixed 4
  real bugs including a wire-level one (`PID_LIVELINESS` never encoded) — but `presence`
  deliberately left out `on_liveliness_lost`/`get_liveliness_lost_status` and the
  AUTOMATIC/MANUAL_BY_PARTICIPANT kinds to stay a single-scenario example
  (`examples/docs/design/presence-reference-app.md`, "Deliberately out of scope"). Two
  DataWriters (AUTOMATIC, MANUAL_BY_PARTICIPANT, both `lease_duration=2s`) write
  continuously at the same cadence the whole run, never calling `assert_liveliness()` —
  targeting a sharper question than "did a writer go silent": *what counts* as a
  liveliness assertion differs by kind, and it's easy to invert. AUTOMATIC's own `write()`s
  should keep it alive forever (never fires); MANUAL_BY_PARTICIPANT should lose liveliness
  anyway, *despite* writing the entire time, since `write()` doesn't count for that kind —
  confirmed correct on the very first real run, both at the writer's own
  `on_liveliness_lost`/`get_liveliness_lost_status()` and, independently, at the reader's
  own `on_liveliness_changed`, extending `presence`'s MANUAL_BY_TOPIC-only reader-side
  coverage to these two kinds. Found a real bug in the C++ port's own harness code (not
  zzdds): the first draft's `create_writer()`/`create_reader()` helper functions
  constructed the listener `shared_ptr` as a local variable that died the moment the
  helper returned, segfaulting both processes the instant SEDP matching tried to fire a
  callback into the now-dangling listener — fixed by having `main()` construct and hold
  the listeners itself. Also bumped `MATCH_TIMEOUT_MS` (40s, not this tier's usual 20s,
  same precedent as `cft-reconfigure`: two writers/readers per process, twice the SEDP
  work) after the same environment-contention-driven "0 matched" timeout `cft-reconfigure`
  saw under a from-scratch 4-binding rebuild; isolated reruns reliably clean (3/3),
  full-suite reruns clean 2/3 with every failure a pure timing miss, never wrong data.
  `zig build test` clean. A full `run_all.py --strict` pass across all 9 scenarios is the
  heaviest cumulative-load run this suite does; the first attempt hit the same
  environment-contention "0 matched" timing miss in both `cft-reconfigure` and
  `liveliness-lost` (never together before — this is a new, heavier watermark than any
  prior run in this session), and both reran clean standalone immediately after with no
  code changes. Treat a lone "0 matched" failure in either of these two on a full
  `run_all.py --strict` run as this same known category, not a regression, unless it
  reproduces on an immediate standalone rerun too. See
  `integration-tests/README.md` for the full scenario writeup.
- **Stress tier** — landed in `stress-tests/` as seven `lifecycle_churn` scenarios
  (`reentrant`, `entities`, `waitset`, `listener`, `cft`, `participants`, `instance`) plus
  the `entity_lifecycle_stress` multi-process port. Found + fixed three concurrency bugs
  (discovery/teardown UAF, unsynchronised `listener_mask`, CFT param UAF) and
  unsynchronised concurrent single-writer `write()`. The `instance` scenario also surfaced
  two key-hash correctness bugs: (1) `get_key_value` decoding a full stored sample with the
  key-only deserializer (zidl codegen, all four backends) — fixed in zidl via the
  selective-parse family; landed here with the zidl v0.3.12 pin, the scenario now asserts
  the returned key value; (2) `resolveKeyHash` misroute
  for a zero-valued key — mitigated (keyed writers now always send inline `PID_KEY_HASH`;
  present all-zero hash honoured), with the full-payload path itself fixed 2026-09-14 (see
  "Keyed-instance handle without a wire key-hash" above). See `stress-tests/README.md`.
  Remaining stress ideas: a
  scenario that also churns the reader-side WaitSet/condition graph under participant
  churn; a Bench-style discovery-latency measurement (explicitly out of scope for this
  tier). Plus a loaned-read/write example — the raw/loan API has been real, IDL-generated
  `dcps.idl` operations across **all four** bindings since the 2026-08-22 redesign (not a
  C/C++-only hand-written family anymore; see `design/raw-loan-api.md`), and is
  unit/smoke-tested internally (`writer_vtable_test.zig`/`reader_vtable_test.zig`,
  `JavaSmoke.java`), but **no `examples/` port in any of the 4 bindings** demonstrates
  `take_raw`/`read_raw`/`loan_raw`/`publish_loan_raw` yet — C/C++ have zero exercise even
  internally (nothing stops a C/C++ caller reading a buffer after returning the loan). A
  genuine candidate for a `presence`-style example built cross-binding from the start.

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

### Internal (same-participant) notification mechanism

Found 2026-09-22 via a packet-capture investigation into flaky match-timeout integration
tests: `combined.zig`'s `self_data` bootstrap (needed so a participant's own SEDP builtin
writer gets a matched-reader-proxy for its own SEDP builtin reader — otherwise same-process
publication/subscription discovery never transmits at all, see its comment) feeds the local
participant's own announcement through `builtin_endpoint.zig`'s `matchRemote`, the exact
path used for genuinely remote peers. That proxy is safe to construct — a participant
legitimately needs a matched-reader-proxy pointing back at itself — but it's addressed and
driven exactly like a remote one: real UDP sends, the same `HB_INTERVAL_MS`-cadenced
keepalive heartbeat thread, the same ACKNACK retry protocol. A `WriterProxy`/`ReaderProxy.
is_local` flag (set in `matchRemote` when `remote.guid.prefix` equals the local participant's
own prefix) closes the worst of it for now — self-matched proxies are excluded from the
periodic heartbeat thread, from liveness probing, and from the one-shot match-time AckNack —
but this is a narrow, contained fix, not a real solution: DATA delivery to these proxies
(and, most likely, to other same-process consumers of builtin discovery topic samples more
generally — SPDP/SEDP participant/publication/subscription data is itself just a stream of
notifications an in-process reader happens to also be interested in) still goes through the
same lossy-media-oriented RTPS reliable-writer machinery underneath: CDR encoding, real
socket sends over loopback, and (per this same investigation) real, measurable loss under
CPU contention with second-scale recovery latency — for data that never needed to leave the
process.

RTPS's HEARTBEAT/ACKNACK/NACK_FRAG retry protocol exists to recover from loss on a genuinely
lossy transport. A same-participant match can't lose anything that way, so reusing that
machinery for it is architecturally the wrong tool — same-process delivery should be a
lossless, direct notification, not a reliable-transport retry loop pointed at itself.

Before implementing a replacement, this needs a real requirements pass, not just a mechanism
swap:

- **Scope**: which internal update paths are actually "internal" in this sense? Builtin
  discovery data (SPDP/SEDP samples reaching a participant's own builtin readers) is the
  case this was found from; same-participant *user*-topic matching (a writer and reader on
  the same participant/topic) is architecturally identical and likely belongs in scope too.
- **Ordering/delivery guarantees** a notification mechanism must provide to stay
  behaviorally equivalent to what the RTPS path gives "for free" today — in particular
  history/TRANSIENT_LOCAL replay and coherent-set semantics, which the current design gets
  from the shared writer_sm/reader_sm state machine rather than anything bespoke.
  `MemoryTransport`/`IntraProcessDelivery` (used by zzdds's own conformance-testing harness)
  is *not* this mechanism as it stands — it substitutes the transport but still drives the
  full reliable-writer state machine (heartbeat threads, ACKNACK) on top, so it doesn't
  eliminate the keepalive/retry traffic this task is about.
- **Migration path**: how existing call sites (builtin discovery matching today) port onto
  it once it exists, without a flag day that has to touch every QoS/fragmentation/
  coherent-set code path at once.

Output: a design doc (performance/requirements first, then shape), followed by a phased
port of the internal call sites identified above once it lands.

### Discovery bootstrap latency: a structural ~1.5s tax, not just contention

Found 2026-09-22, same pcap investigation as the self-match fix above (see
[[project-self-match-notification-fix]] in agent memory for the session narrative), but this
is a **separate, more fundamental** finding than that one. The self-match fix and the
CPU-contention flake explanation both concerned *worse-than-baseline* behavior — heavier
traffic, or real UDP loss under induced load. This finding is about the *baseline itself*:
on a completely idle system, with two freshly-started `liveliness-lost` zig↔zig processes and
nothing else running, full cross-process discovery + match still consistently took **~1.5
seconds** — for literally 2 processes and 4 user-level entities on loopback. That is far
slower than it has any right to be, and the mechanism turned out to be structural, not
incidental.

**What's confirmed** (via direct pcap byte-level decode — `rtps_pcap.py`'s own conversation
grouping is not reliable enough alone here, see the gotcha below):

- Both participants send their first SPDP announcement within single-digit milliseconds of
  process start (observed: +4-9ms in multiple runs), whether processes are launched with an
  artificial stagger or back-to-back (tested both — the effect reproduces either way, so it
  is *not* a test-harness launch-order artifact).
- Neither side's real cross-process SEDP proxy (confirmed via matching on **both** sender
  prefix and `INFO_DST`, not just the generic builtin `readerId`/`writerId` — see gotcha
  below) reacts to the other's writer at all until the *second* SPDP fast-announce cycle,
  observed consistently in the 1507-1612ms range across runs.
- `announcement_period_ms` defaults to 3000ms (`src/config/schema.zig:46`); SPDP's
  fast-announce mode (`src/discovery/spdp.zig`, `fast_announce_until_ns`, active for the
  first `2 * announcement_period_ms` after start) halves that to a **1500ms** resend
  interval. The observed ~1.5s stall lines up with this exactly, every time.
- There is no faster recovery path once a first announcement is missed. The one accelerant
  that exists — `spdp.zig`'s "SEDP-traffic-seen heuristic" (unicast retransmit directly to a
  peer that keeps re-announcing over SPDP but has never sent real SEDP traffic) — is itself
  gated on waiting for the peer's *next* periodic/fast-announce cycle to fire before it can
  trigger. So the floor recovery time from a missed first announcement is the fast-announce
  half-period (1.5s), regardless of how small the timing skew that caused the miss actually
  was.

**Working theory** (not yet proven at the code level — next investigator should verify this
directly, e.g. with targeted logging around `transport.listen()`/`joinMulticast()` completion
vs. the immediate-announcement send in `spdp.zig`'s `start()`): each participant's own
"join multicast, then send immediate announcement" sequence completes at a slightly different
wall-clock moment (ordinary OS/scheduling variance between two independently-starting
processes, on the order of single-digit milliseconds). If participant B's multicast join
hasn't completed yet at the exact instant A's first announcement goes out, B misses it — and
because A won't try again for another 1.5s (fast-announce half-period), B is stuck waiting
that whole interval even though the actual race window that caused the miss was only a few
milliseconds wide. If true, the fix is straightforward in shape (though needs real
measurement to size correctly): a much shorter *initial* retry cadence during the discovery
bootstrap window — e.g. resend every 100-250ms for the first second or two, then back off to
the steady-state fast-announce/normal rate — would let two participants catch each other's
presence almost immediately in the common case, instead of eating a near-fixed 1.5s tax on
nearly every fresh two-participant discovery.

**Why this matters beyond "it'd be nice if it were faster"**: this baseline cost stacks with
whatever additional delay real contention/loss adds on top of it (see the self-match fix
memory entry's flake investigation), and is very likely a meaningful fraction of why
`cft-reconfigure`/`liveliness-lost` need `MATCH_TIMEOUT_MS=40000` at all — a budget sized to
absorb worst-case contention-driven retries *on top of* a baseline that's already ~1.5s+ just
from this bootstrap gap, before any loss has happened. The user explicitly does not want the
current large timeouts shortened until this gets fixed — see that memory entry's "can we
shorten the timeouts" follow-up, empirically answered "no" for the same reason.

**Scope for the future work this item requests**: a proper discovery-timing test suite,
covering at minimum:
- Wall-clock time from process start to full match, idle system, at 2-participant baseline
  scale and stepped up to whatever participant count is realistic for real deployments —
  confirm whether the ~1.5s tax is roughly constant regardless of scale, or gets worse as
  more simultaneously-starting participants compete for the same race window.
- The same measurement under induced CPU contention (methodology from this session: N busy
  `while true; do :; done` loops pinned to available cores, watch `/proc/loadavg`), to
  separate the *baseline* structural cost measured here from the *additional* contention-driven
  cost investigated separately.
- A/B comparison of the current 1.5s initial retry interval against candidate shorter
  intervals, checking both the actual latency improvement and any steady-state multicast
  traffic-volume cost of resending more aggressively during the bootstrap window.
- Once a fix lands and is validated by this suite: revisit `MATCH_TIMEOUT_MS` in
  `integration-tests/{c,cpp,java,zig}/{cft-reconfigure,liveliness-lost}` — very likely
  shortenable at that point, per the user's explicit preference.

**Investigation tooling notes for whoever picks this up**:
- `dds-rtps/rtps_pcap.py` (`list`/`show`/`compare` CLI) is the right tool, but its
  conversation grouping keys on the generic builtin `readerId`/`writerId` (identical across
  *every* participant for builtin endpoints) plus `INFO_DST` when present — for a message
  with `INFO_DST` absent (its own `no_info_dst`/`[*]` marker), it cannot always disambiguate
  which of several plausible real participants a packet belongs to, since it discards raw
  IP:port in `_strip_link` (`rtps_pcap.py:489-511`). When precision matters (as it did for
  this finding), decode the relevant frames directly with `dpkt`, matching on **both** the
  RTPS message header's own source prefix **and** the `INFO_DST` submessage's payload, not
  submessage-level entity IDs alone.
- `dumpcap`'s captured link-layer type is **not consistent** across invocations on this
  system's `lo` interface — observed both `DLT_LINUX_SLL` (113) and plain `DLT_EN10MB` (1)
  across different capture sessions of the identical `dumpcap -i lo` command. Always check
  `dpkt.pcapng.Reader.datalink()` before writing a raw parser; `rtps_pcap.py` itself already
  dispatches on this correctly, a hand-rolled verification script must too.

---

## CI / Release Platform Coverage

Audit of `build.zig` options, `scripts/run_deterministic_matrix.py`, `ci.yml`, and
`release.yml` against the platform/build-type matrix they exercise. Original ranking
2026-08-16; progress notes below from PR #65 (2026-08-18), the 2026-08-28 CI pass, and the
2026-09-02 release-prep pass (musl lane + prebuilt-bundle consume check + CHANGELOG-sourced
release notes).

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
- **Prebuilt-bundle consume check** (2026-09-02) — `package-libs` now also extracts the
  finished tarball into an unrelated directory and drives a real downstream consume of it via
  `scripts/verify_release_bundle.py`: `find_package(ZZDDS)` + pkg-config resolve from the
  *relocated* prefix, the bundled `bin/zidl` runs, and `examples/{c,cpp}/hello_world` + a
  minimal consumer compile, link and (Linux) exchange samples against it. Catches broken
  CMake package files / pkg-config relocatability / rpath|install-name that the in-tree
  `test-bindings` step (CMAKE_PREFIX_PATH pointed straight at the live `zig-out`) can't see.
  Linux runs the full path; macOS skips only the live-UDP hello_world pair run
  (`--skip-example-run`). Windows gets the structural check only — the generated
  `zzdds-config.cmake` / `zzdds.pc` are POSIX-shaped, so `find_package(ZZDDS)` can't
  configure there yet (see "Still open" below).
- **musl / static Linux target lane** (2026-09-02) — `zig build test -Dtarget=x86_64-linux-musl`
  now runs in `run_deterministic_matrix.py` (so `ci.yml`'s `test-linux` covers it) and
  `release.yml`'s `test` job (Linux x86_64 only). A `-linux-musl` binary is statically linked
  and runs natively on the glibc runner, so this is full-suite execution coverage
  (1076/1076), not just a build check — closes "`-Dtarget` is never actually cross-compiled".
- **Release notes sourced from `CHANGELOG.md`** (2026-09-02) — `release.yml`'s `publish` job
  builds the GitHub-release body from the curated, date-headed `CHANGELOG.md` sections
  written since the previous release tag (`scripts/extract_changelog.py`), falling back to
  raw commit subjects only if that yields nothing, and always appending a `compare` link.
- **macOS bundle links with the Apple toolchain** (2026-09-03) — the prebuilt-bundle consume
  check building `examples/{c,cpp}/hello_world` with Apple clang/clang++ shook out two macOS
  packaging defects, both worked around in `build.zig` (details in `CHANGELOG.md`): the
  static `libzidl_cdr.a` re-packed with `zig ar --format=darwin` for `ld64` 8-byte
  alignment (ziglang/zig#1981), and `libzzdds.dylib`'s export trie post-processed to drop a
  spuriously-exported `___dso_handle` that broke Apple ld-prime C++ consumers
  (`scripts/fix_macos_dylib_exports.sh`; ziglang/zig#24370). macOS builds also default to a
  13.0 deployment floor instead of the build host's OS version. **Both workarounds are
  upstream Zig bugs — revisit deleting them at a Zig bump.**
- **`ReleaseSmall` lane** (2026-08-29) — new `zig build test-release-small` step runs the
  whole unit suite at `-OReleaseSmall`, wired into `run_deterministic_matrix.py` (so
  `ci.yml`'s `test-linux` covers it) and `release.yml`'s `test` job (Linux x86_64 only).
  The step **forces the LLVM backend** to sidestep a Zig 0.16 self-hosted-x86_64 codegen bug
  (misaligned read-only globals at `-OReleaseSmall` — see the Deferred note below and the
  step's `build.zig` comment). **At the Zig 0.17 bump: delete `test-release-small` and
  replace it with a plain `zig build test -Doptimize=ReleaseSmall` step on the normal
  self-hosted backend, broadened to the whole `release.yml` matrix** — the bug is fixed on
  0.17.

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
- **Self-hosted `-OReleaseSmall` on Zig 0.16 — upstream codegen bug, worked around above.**
  Zig 0.16.0's self-hosted x86_64 backend, *only* at `-OReleaseSmall`, emits read-only
  global constants with no alignment: `&SomeImpl.views` (an `extern struct` `CAbiViews`,
  `@alignOf` 8) and every `*_vtable` global land at odd `.rodata` addresses, and `zidl-rt`'s
  `@alignCast(box.vtable)` traps it (`panic: incorrect alignment`, ~37 C-ABI tests).
  `-OReleaseFast`, the LLVM backend, and Debug/ReleaseSafe are all fine. Not a zzdds/zidl
  defect; **fixed on `zig-0.17.0-dev.1902`**, not in any stable release (0.16.0, tagged
  2026-04-13, is latest; no matching upstream issue found). The `ReleaseSmall` lane
  (see *Landed*) sidesteps it by forcing the LLVM backend until the 0.17 bump. Minimal repro
  + full trail: `zz-dev/releasesmall-misaligned-rodata-investigation.md`.

### Still open, ranked

1. **Real vendor/self RTPS interop** (Connext / Cyclone / CoreDX / self) runs only on Linux
   x86_64 — no wire / discovery / CDR coverage on Windows, macOS, or ARM64.
2. **No Intel macOS coverage** — `macos-latest` is Apple Silicon only.
3. **musl coverage is x86_64-only, and there is no static-`libzzdds` bundle** — the new lane
   (see *Landed*) cross-builds and runs `x86_64-linux-musl`; `aarch64-linux-musl` would need
   qemu to execute. Separately, `build.zig` still only builds `libzzdds` as a shared library
   (`.linkage = .dynamic`, no `-Dlinkage` option), so there's no static-archive/musl variant
   in `package-libs`' bundle set — deferred until a concrete consumer asks for one.
4. **The generated CMake/pkg-config package is POSIX-only** — `build.zig`'s
   `zzdds-config.cmake` searches `lib/` for the shared library (the Windows DLL installs to
   `bin/`), sets no `IMPORTED_IMPLIB` for the import lib, and hard-codes `bin/zidl` (not
   `bin/zidl.exe`); `zzdds.pc` is likewise `-l`-style. So a Windows consumer can't
   `find_package(ZZDDS)` a bundle yet — `package-libs` ships the Windows tarball with the
   structural check only, and `verify_release_bundle.py` is not run there. Fix: platform-aware
   generation in `build.zig` + turn the Windows arm of the consume check back on.
5. **Valgrind has no viable non-Linux equivalent** — treat as Linux-only unless a specific
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
- **Make `InterfaceMonitor` a real, complete thing for zzdds** — three related gaps, bundled
  as one future initiative rather than three scattered items, because they share a root
  cause (only the polling backend exists, item 1 below) and a natural landing order (backends
  first, then the two consumers that would actually benefit from them):
  1. **Platform-specific backends** — `monitor/netlink.zig` (Linux), `monitor/pf_route.zig`
     (macOS/BSD), `monitor/windows.zig` (NotifyIpInterfaceChange) — deferred; the polling
     monitor is sufficient today. `InterfaceMonitor.Vtable` itself (`interface.zig:350`,
     `start`/`stop`/`enumerate`/`deinit`) needs no change — a backend is a drop-in `ctx`+
     `vtable` pair, exactly like `PollingMonitor` is today. Contract any of the three must
     satisfy: (a) **deliver, don't just detect** — `on_change(cb.ctx)` fires from the
     backend's own detection thread promptly after the underlying kernel event (netlink
     `RTM_NEWADDR`/`RTM_DELADDR`, PF_ROUTE `RTM_NEWADDR`/`RTM_DELADDR`, Windows
     `MibAddressInstanceChange`), not batched behind an arbitrary delay — a small, bounded
     coalescing window (10-50ms) to absorb a burst of near-simultaneous address changes is
     fine, since it's a fixed, documented latency floor, categorically different from
     polling's unbounded-until-next-tick latency; (b) **fall back to `PollingMonitor` on init
     failure, don't fail hard** — `polling.zig`'s own doc comment already states the intent
     ("the polling monitor is still available as a fallback and for testing", `:7`-`:9`); a
     permission failure opening a netlink/PF_ROUTE socket (e.g. a locked-down container) or an
     unsupported OS version must transparently construct a `PollingMonitor` instead of failing
     transport construction; (c) **`enumerate()` stays the single source of truth** — a
     backend may internally track structured per-address add/remove events, but must still
     answer `enumerate()` with a full, current snapshot on demand (as
     `PollingMonitor.vtEnumerate`, `:325`, does today), so every consumer's diff logic
     re-derives added/removed sets from two `enumerate()` snapshots rather than trusting a
     backend to hand over pre-diffed events — keeps reconciliation logic (and its bugs, its
     tests) in one place per consumer regardless of backend.
  2. **TCP gains topology awareness.** `design/transport-channel.md` revision 0.2 (superseded
     by 0.3, kept in git history) worked out a concrete design, deliberately not carried into
     the shipped spec or the transport-channel PR: `TcpConfig` has no keepalive, connect
     timeout, or write deadline (`config/schema.zig` `TcpConfig`, `:70`-`:86`), so a TCP
     connection whose local interface disappears is invisible until the OS's own unbounded
     passive failure detection eventually fires (commonly tens of minutes on Linux with
     default `tcp_retries2` and no keepalive). `TcpTransport.vtSetLocatorChangeHandler`
     (`tcp.zig:723`) already stores a `locator_change_handler` that is silently never
     invoked — grepped, zero `.on_change(` call sites in the file — dead plumbing this work
     would complete rather than invent. The worked-out approach: give `TcpTransport` its own
     `InterfaceMonitor` (optional-injection, mirroring `UdpTransport.init`'s existing `mon:
     ?InterfaceMonitor` parameter, `udp.zig:492`-`503`); track each connection's concrete
     local address via `getsockname()` (already used at `tcp.zig:661`,`:667` for a different
     purpose) right after `connect()`/`accept()` succeeds; on a topology event, fire
     `locator_change_handler` when the listen address itself is affected and proactively
     shut down any connection whose local address just disappeared, instead of waiting on the
     OS. The transport-channel work (`design/transport-channel.md` §5) built the API this
     should fire through — `ReceiveHandler.on_channel_closed` — so landing this needs no
     further Channel-side API change; it only needs to call the existing connection-close
     path (`closeConnFdOnce`) at the right moment.
  3. **Shared `InterfaceMonitor` instance across a participant's transports.** Once (2) gives
     TCP its own monitor, having UDP and TCP each own an independent instance (two polling
     threads, or eventually two netlink sockets, doing redundant work) is correct but
     wasteful. Sharing one instance is blocked on the same constructor-chain plumbing noted
     in (2)'s design: reaching UDP's concrete monitor from where TCP is constructed
     (`participant.zig`'s `owned_tcp_transport`, built inside `DomainParticipantImpl.init`)
     needs a new parameter threaded through `DomainParticipantFactoryImpl.init` and
     `DomainParticipantImpl.init`, rippling through at least the six call sites in
     `raw_ops.zig`/`c_abi/extensions.zig` that construct a factory directly. Do this at the
     same time as (2), not before it — no reason to duplicate the monitor for even one
     release cycle if the constructor plumbing is being touched anyway.

  None of the three is required for or blocked by the transport-channel work
  (`design/transport-channel.md`) — that spec ships `Channel`/`sendOnChannel` for both
  transports and `on_channel_closed` firing from paths that already exist today (TCP natural
  connection death; UDP's existing, pre-existing interface-monitor-driven socket teardown).
  This item is what makes TCP's own local-interface-loss detection prompt, which today it
  is not — deliberately out of scope for that PR, deliberately tracked here instead.
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
