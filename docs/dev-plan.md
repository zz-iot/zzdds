# Zenzen DDS Development Plan

## Status Key
- ✓ Phase complete
- [x] Step complete
- [ ] Step pending / in progress

---

## Phase 0: Scaffolding ✓
- [x] Directory structure
- [x] CLAUDE.md
- [x] build.zig + build.zig.zon
- [x] idl/dcps.idl
- [x] zidl codegen step in build

## Phase 1: Foundation Types ✓
- [x] `rtps/guid.zig` — Guid, GuidPrefix, EntityId, predefined entity IDs
- [x] `rtps/locator.zig` — Locator union + LocatorWire (wire-format extern struct)
- [x] `rtps/sequence_number.zig` — SequenceNumber (i32 high + u32 low, RTPS §9.3.2)
- [x] `util/time.zig` — Duration_t, Time_t; RtpsTimestamp (u32 sec + u32 frac)
- [x] `qos/policy.zig` — all 22 QoS policies (DDS v1.4 §2.2.3)
- [x] `config/schema.zig` — Config struct hierarchy + defaults

## Phase 2: Plugin Interface Skeletons ✓
- [x] `transport/interface.zig` — Transport vtable, ReceiveHandler
- [x] `discovery/interface.zig` — Discovery vtable + Callbacks
- [x] `security/interface.zig` — SecurityPlugins vtable
- [x] `security/noop.zig` — no-op pass-through
- [x] `protocol/interface.zig` — ProtocolWriter/ProtocolReader vtables (DCPS ↔ RTPS seam)

## Phase 3: RTPS Message Layer ✓
- [x] `rtps/message/header.zig` — RTPS Header (protocol id, version, vendor, guid prefix)
- [x] `rtps/message/submessage.zig` — SubMessage header + all submessage types
- [x] `rtps/message/parser.zig` — parse RTPS messages from byte buffers
- [x] `rtps/message/builder.zig` — build RTPS messages into byte buffers (scatter-gather)

## Phase 4: UDP Transport ✓
- [x] `transport/interface.zig` — InterfaceMonitor vtable, ChangeCallback; `unicast_locators(out)`; `set_locator_change_handler()`
- [x] `transport/udp.zig` — unicast/multicast sockets; per-interface binding; live socket set via InterfaceMonitor; participant ID auto-assign
- [x] `transport/monitor/polling.zig` — default InterfaceMonitor: enumerate + diff every N ms
- [x] Build options: `enable_ipv4`, `enable_ipv6`, `enable_interface_monitor`

## Phase 5: History Cache + RTPS State Machines ✓
- [x] `rtps/history.zig` — HistoryCache (KEEP_LAST: oldest-evict; KEEP_ALL: explicit removal)
- [x] `rtps/writer_sm.zig` — StatelessWriter (SPDP best-effort) + StatefulWriter (reliable; ReaderProxy per matched reader; Heartbeat/NACK retransmit)
- [x] `rtps/reader_sm.zig` — StatelessReader (SPDP) + StatefulReader (reliable; WriterProxy per matched writer; AckNack; GAP handling)
- [x] `util/mutex.zig` — Mutex wrapper over pthread_mutex_t

## Phase 6: Discovery ✓
- [x] `rtps/pid.zig` — PID constants (Table 9.14) + BuiltinEndpointSet flags + vendor ID
- [x] `idl/rtps_discovery.idl` + build.zig `gen_rtps_disc` step (module: `zzdds_disc_generated`)
- [x] Consolidate Guid: `discovery/interface.zig` imports from `rtps/guid.zig`
- [x] `Locator_t → Locator` conversion helper (generated wire type → native union)
- [x] `dcps/qos_match.zig` — QosMatcher: `checkWriterReader` covers 7 endpoint-level policies
  (DURABILITY, DEADLINE, LATENCY_BUDGET, OWNERSHIP, LIVELINESS, RELIABILITY, DESTINATION_ORDER);
  `checkPresentation` and `checkPartition` as separate pub/sub-level checks. **[CORRECTED — Phase 19]**
  Does not cover all 22 policies; live discovery path does not yet call the matcher (tracked in Phase 20).
- [x] `discovery/spdp.zig` — SPDPdiscoveredParticipantData publication + reception; lease timers
- [x] `discovery/sedp.zig` — endpoint announcement; QoS matcher imported but not yet called in
  `handleEndpointChange`; proxies created unconditionally on topic+type match (tracked in Phase 20)

## Phase 7: DCPS Implementation (partial — see notes) **[CORRECTED — Phase 19]**
- [x] Verify generated DCPS interfaces compile
- [x] Wire StatefulWriter/Reader into ProtocolWriter/Reader vtables (`rtps/protocol_adapters.zig`)
- [x] `dcps/factory.zig` — DomainParticipantFactory (not a singleton)
- [x] `dcps/participant.zig` — DomainParticipant; TypeRegistry; built-in topics
- [x] `dcps/publisher.zig` + `dcps/writer.zig` — Publisher + DataWriter
- [x] `dcps/subscriber.zig` + `dcps/reader.zig` — Subscriber + DataReader
- [x] `dcps/topic.zig` — Topic; ContentFilteredTopic is a nil stub (`topic.zig:91-95`)
- [x] `dcps/waitset.zig` — WaitSet (spin-sleep `wait()`); ReadCondition working; QueryCondition,
  StatusCondition, GuardCondition are nil stubs

Working: DataWriter/DataReader basic write/read, Publisher/Subscriber lifecycle, loopback delivery.\
Stubs (tracked in Phase 21): `Topic.get_statuscondition()` returns nil; `DataReader.create_querycondition()`
returns nil; `DomainParticipant.get_builtin_subscriber()` returns nil; `create_contentfilteredtopic()`
returns nil; `get_discovered_participants/topics` return empty; DataWriter/DataReader status getters
(`get_liveliness_lost_status`, etc.) return zeroed structs; `WaitSet.wait()` is a spin-sleep loop.

## Phase 8: Configuration System ✓
- [x] `config/file.zig` — hand-written TOML parser (no external dependencies)
- [x] `config/resolve.zig` — merge: programmatic > env vars (ZZZDDS_*) > config file > defaults

## Phase 9: Cyclone DDS Wire Interop ✓
- [x] Cyclone DDS wire interop test suite (`zig build interop-test`)
  - [x] Zenzen DDS writer → Cyclone reader: CDR payload received correctly (`make test` Scenario 1)
  - [x] Cyclone writer → Zenzen DDS reader: payload received correctly (`make test` Scenario 2)
  - [x] SPDP/SEDP exchange end-to-end verified (full discovery + proxy establishment)
  - Key fixes: non-final AckNack retransmission (§8.3.7.1.2); multi-write retry for race window;
    startup-order workaround in interop Makefile (proper fix deferred to Phase 14)

## Phase 10: RTPS State Machine Behavioral Tests ✓
*Root cause of Phase 9 pain: the interop bug was in `handleAckNack`, which had zero test coverage.
 These tests assert protocol transitions (§8.4.9), not struct layout.*

- [x] **StatefulWriter AckNack handling** (`test/rtps/writer_sm_test.zig`)
  - Non-final AckNack + empty bitmap (numBits=0) retransmits all changes with SN ≥ base (§8.3.7.1.2)
  - Non-final AckNack + bitmap retransmits NACKed changes AND all changes ≥ base not in bitmap
  - Final AckNack + bitmap retransmits only explicitly NACKed sequence numbers
  - Final AckNack + empty bitmap (pure ACK) sends nothing
  - AckNack with base > writer's lastSN: nothing to retransmit, no crash
  - AckNack from unknown reader GUID: ignored
  - Multiple reader proxies: AckNack from reader A does not affect reader B's state

- [x] **StatefulWriter Heartbeat emission** (`test/rtps/writer_sm_test.zig`)
  - Heartbeat firstSN/lastSN reflect cache min/max after writes
  - Heartbeat firstSN=1, lastSN=0 when cache is empty (§8.3.8.6 Example 4)
  - Heartbeat count increments monotonically per send

- [x] **StatefulReader Heartbeat handling** (`test/rtps/reader_sm_test.zig`)
  - Non-final Heartbeat with missing SNs → AckNack with correct bitmap
  - Non-final Heartbeat with all SNs received → AckNack with empty bitmap (pure ACK)
  - Final Heartbeat (FinalFlag set) → no AckNack sent when all SNs received
  - Heartbeat from unknown writer GUID: ignored
  - Duplicate Heartbeat (same count): suppressed

- [x] **Count_t rollover** (§8.3.5.10, §9.3.2.1)
  - Implemented in `handleHeartbeat`: signed modular comparison `(i32)(new − old) > 0`
    (same technique as TCP sequence numbers in RFC 7323). Handles INT32_MAX → INT32_MIN rollover.
  - `WriterProxy.last_hb_count: ?i32` tracks the last accepted count (null = first HB).
  - Tests: duplicate (same count), stale (count < last), rollover (INT32_MAX → INT32_MIN accepted),
    re-delivery after rollover rejected.

- [x] **SequenceNumber_t boundary cases** (`test/rtps/sequence_number_test.zig`)
  - SN arithmetic at high/low word boundary: `{high=0, low=0xFFFFFFFF}` + 1 → `{high=1, low=0}`
  - SequenceNumberSet.contains() near SN boundary (base close to u32 max)
  - SEQUENCENUMBER_UNKNOWN sentinel is not treated as a valid SN in comparisons

- [x] **GAP submessage handling** (`test/rtps/reader_sm_test.zig`)
  - GAP covering a contiguous range: reader advances past all SNs in range
  - GAP with bitmap (sparse not-available set): reader skips only listed SNs
  - GAP for already-received SN: idempotent (no double-delivery)

- [x] **WriterProxy state in StatefulReader** (`test/rtps/reader_sm_test.zig`)
  - Out-of-order DATA: buffered; AckNack bitmap reflects gap; delivered on gap fill
  - DATA with SN below `highestReceivedSN`: duplicate, discarded without re-delivery

## Phase 11: Rename ZounDDS → Zenzen DDS ✓
*The abbreviation ZZDDS / zzdds remains fine throughout.*

## Phase 12: Zig 0.16.0 Stable Migration ✓

- [x] Compile cleanly against stable 0.16.0 release (not dev build)
- [x] Address any new deprecations or API changes introduced between the dev snapshot and stable
  — none found; stable matched the dev snapshot exactly
- [x] Run full test suite; fix any failures
  — 170/170 tests pass; one `std.log.warn` → `std.log.debug` change in `replayHistoryToProxyLocked`
  to eliminate spurious "failed command" output from Zig 0.16.0's `--listen=-` test runner
- [x] Update CLAUDE.md "Quick Reference" zig path and "Zig 0.16.0-dev API Notes" section to
  reflect stable release

## Phase 13: Logging and Tracing Architecture ✓

Two independent systems. Design decisions resolved — see Resolved table below.

### Part A: `std.log` scope migration

- [x] Define named log scopes in `src/log.zig`:
  `zzdds_rtps`, `zzdds_spdp`, `zzdds_sedp`, `zzdds_transport`, `zzdds_dcps`
- [x] Convert all existing `std.log.*` calls throughout `src/` to use the appropriate scope
- [x] Document scope names and `scope_levels` usage pattern in CLAUDE.md:
  applications set `pub const std_options = std.Options{ .log_scope_levels = &.{...} }`
  in their root module for compile-time per-scope filtering; runtime filtering via `logFn` override

### Part B: Wire trace subsystem (`src/trace.zig`)

**Core types:**
- [x] `TraceEvent` — tagged union covering all RTPS submessage variants (both send and receive
  directions) plus a `skipped` variant for ring-buffer overflow accounting:
  - `send_data` / `recv_data` / `recv_data_dup` (duplicate discarded)
  - `send_heartbeat` / `recv_heartbeat` / `recv_heartbeat_dup` (stale count)
  - `send_acknack` / `recv_acknack`
  - `send_gap` / `recv_gap`
  - `recv_info_ts` / `recv_info_dst`
  - `skipped: struct { count: u64 }` — emitted by flush thread when ring overflowed
  All per-submessage variants carry typed fields (EntityId, SequenceNumber, SequenceNumberSet,
  GuidPrefix, flags) — no format strings, no allocation.
- [x] `GuidFilter` — `prefixes: []const GuidPrefix = &.{}` (empty = accept all);
  `matches(prefix) bool`; applied before sink dispatch; gated by
  `build_options.enable_guid_filter` (comptime false → filter check eliminated)

**Sink vtable:**
- [x] `Sink` vtable: `submit(*anyopaque, TraceEvent) void` + `deinit(*anyopaque) void`
- [x] `NoopSink` — zero-cost placeholder; default when wire trace is disabled
- [x] `AsyncRingSink` — MPSC fixed-size ring of `TraceEvent` structs; producer never blocks;
  if ring full: `dropped_count.fetchAdd(1, .monotonic)` and return.
  Optional flush thread: drains ring to a `std.Io.Writer`; when it catches up after a drop
  gap, emits a synthetic `skipped` event before the next real event.
- [x] `SyncSink` — serializes each event immediately to a `std.Io.Writer` (stderr or file);
  blocks the calling thread; no drops. Same serializer as `AsyncRingSink`'s flush thread.

**Output format:**
- [x] NDJSON serializer + text serializer: format enum on sink: `.ndjson` (default, for
  files/tooling) or `.text` (human-readable, for live stderr monitoring).

**Integration:**
- [x] `Tracer.submit(event: TraceEvent) void` — comptime-gated call site API:
  - When `enable_wire_trace = false`: `Tracer` is a zero-size struct; `submit` is a noop;
    entire call eliminated by dead-code elimination
  - When `enable_wire_trace = true` + `enable_guid_filter = true`: prefix check before dispatch
  - `tracer` field in each state machine; `setTracer()` method for wiring
- [x] `trace.submit()` calls in `StatefulWriter` (send path: `sendAll`, `sendHeartbeat`,
  `handleAckNack`, `sendChangeToAllLocked`, `replayHistoryToProxyLocked`)
- [x] `trace.submit()` calls in `StatefulReader` (receive path + discard path:
  `handleData` with dup detection, `handleHeartbeat` with stale-count detection,
  `handleGap`, `sendAckNackLocked`)
- [x] `StatelessWriter.sendAll` — `send_data` per change per locator
- [x] `setTracer()` wired through SPDP, SEDP, and `SpdpSedpDiscovery` (`combined.zig`)
- [x] `setTracer()` wired through `RtpsProtocolWriter` / `RtpsProtocolReader` adapters

**Configuration:**
- [x] `TraceConfig` struct: `sink: Sink = NoopSink.sink()`, `filter: GuidFilter = .{}`;
  comptime-inert (`TraceConfigInert`) when `enable_wire_trace = false`
- [x] `DomainParticipantFactoryImpl.trace_config: TraceConfig` field +
  `setTraceConfig(tc) void` method; tracer passed to all created participants and applied
  to every user-plane protocol adapter on creation
- [x] Build options: `-Denable-wire-trace` (default false), `-Denable-guid-filter`
  (default false; only meaningful with wire trace enabled)
- [x] Document `TraceConfig`, build options, and output format in CLAUDE.md

## Phase 14: SPDP Unicast Relay Fix ✓

- [x] SEDP `onReceive` (`src/discovery/sedp.zig`) discarded packets with source entity ID
  `spdp_builtin_participant_writer`; Cyclone sends unicast SPDP responses to the metatraffic
  unicast port (7410), which SEDP owns — these were silently dropped
- [x] Confirmed ZZDDS bug: RTPS §9.6.1.1 defines the metatraffic unicast port as carrying all
  metatraffic (SPDP + SEDP); Cyclone's behavior is spec-compliant, not an extension
- [x] Fix: `SpdpEndpoints.handleRelayedData` static wrapper; `SedpEndpoints.setSpdpRelay()`
  method + `spdp_relay_ctx/fn` fields; relay wired in `SpdpSedpDiscovery.init()`.
  No `interop_mode` guard needed — unconditional per the spec
- [x] Startup-order constraint in interop Makefile no longer required: ZZDDS can now receive
  unicast SPDP responses regardless of which participant starts first

## Phase 15: Interop Tests on RELIABLE ✓

Note: the SEDP → DCPS → RTPS `addMatchedReader` chain is already wired
(`participant.zig:onReaderDiscovered` → `aw.proto.addMatchedReader` → `protocol_adapters` →
`StatefulWriter.addMatchedReader`).  The replay-on-new-proxy path already exists.

Known gap: `onReaderDiscovered` does not call `qos_match.zig` — proxies are added regardless
of QoS compatibility.  Not a problem for this phase (both sides set to RELIABLE) but a latent
bug to fix before the match-listener phase.

- [x] Switch interop test writers/readers from BEST_EFFORT to RELIABLE; remove the 3× write
  retry loop in `zzdds_pub.zig`
- [x] Verify both interop scenarios pass cleanly with no retry logic (requires Cyclone checkout)

Rationale: VOLATILE writers make no spec commitment to deliver pre-match data; delivery of
cached samples to a new proxy is an implementation courtesy that holds as long as KEEP_LAST
depth hasn't evicted the sample.  For a single-write interop test this is reliable enough in
practice, and RELIABLE QoS gives the protocol the tools to recover if it isn't.

## Phase 16: ZZDDS-to-ZZDDS Loopback Test ✓
*We should have started here! But we learned more the hard way.*

- [x] Two DomainParticipants in the same test process, connected via loopback UDP (127.0.0.1)
- [x] Writer writes a CDR payload → reader delivers it → assert bytes match exactly
- [x] Exercises the full stack: SPDP → SEDP → QoS matching → DataWriter → transport → DataReader
- [x] Runs in `zig build test` with no external dependencies (no Cyclone, no FastDDS)
- [x] One test each for: BEST_EFFORT, RELIABLE, KEEP_LAST depth=1, KEEP_ALL
- [x] Serves as the regression baseline for all future protocol changes

**Implementation notes:**
- `test/dcps/loopback_test.zig` — 4 tests via `runLoopback` helper
- Fixed TOCTOU in `autoAssignParticipantId`: probe-and-release is now hold-and-use —
  `tryBindPort` returns the bound fd; both reservation sockets are held as fields on
  `UdpTransport` until `vtListen` promotes them to wildcard receive sockets (0.0.0.0:port),
  eliminating the window between "port appears free" and "port is actually bound".
  Loopback test uses explicit participant IDs (0 and 1) as belt-and-suspenders.
- Fixed `StatefulReader.handleData` missing early return on duplicate SN — duplicates were
  falling through to `addReaderChange` and delivery, causing repeated samples
- Fixed `pubCreateProtoWriter` / `subCreateProtoReader` ignoring QoS history kind/depth
  (hardcoded `.keep_last, 1`); now reads from the DataWriterQos / DataReaderQos

## Phase 17: Testing Strategy ✓
*A planning-and-design phase, not an implementation phase. Output is a documented test plan.*

- [x] Define four test tiers: deterministic unit tests, mock-transport tests, live interop,
  and adversarial (fuzz + sanitizers)
- [x] Mock transport design: `MockTransport` vtable implementation with configurable drop/dupe,
  manual `deliver()` control, plugs in at the same seam as `UdpTransport`
- [x] Clock abstraction design: `Clock` vtable (`RealtimeClock`, `MonotonicClock`, `ManualClock`);
  `ManualClock.advance(ns)` drives timers without sleeping; RTOS-friendly
- [x] Fuzz targets identified: RTPS parser, PL-CDR/PID deserializer, CDR payload (future);
  focus on length-field vs. buffer-size validation as the primary attack surface
- [x] Tooling plan: GPA (already active), TSan (`sanitize_thread = true`), LLVM coverage,
  libFuzzer; no formal conformance harness (real interop is the bar)
- [x] CI structure: fast tier always (`zig build test`), TSan on PRs, interop + fuzz nightly
- [x] Documented in `docs/design/testing-strategy.md`

## Phase 18: OpenDDS Wire Interop ✓
*Mirrors the Cyclone interop structure; validates RTPS 2.5 compliance against a second major implementation.*

- [x] `test/interop/opendds_pub.cpp` + `opendds_sub.cpp` — OpenDDS 3.33 RTPS-only publisher and
  subscriber using the same `HelloWorldData` IDL type as the Cyclone scenarios
- [x] `opendds_idl` / `tao_idl` generated type-support files checked in
  (`HelloWorldDataC.*`, `HelloWorldDataS.*`, `HelloWorldDataTypeSupportImpl.*`)
- [x] Makefile targets `all-opendds`, `interop-test-opendds`; `OPENDDS_ROOT` env-var gate
  consistent with `CYCLONE_HOME` pattern
- [x] `build.zig` `interop-test-opendds` step: builds Zenzen DDS pub/sub binaries, then
  invokes `make interop-test-opendds`; run with `zig build interop-test-opendds`
- [x] Shared `rtps.ini` RTPS transport config used by OpenDDS side to disable built-in
  discovery and force RTPS-UDP transport
- [x] Scenario 3: Zenzen DDS writer → OpenDDS reader — CDR payload received and decoded correctly
- [x] Scenario 4: OpenDDS writer → Zenzen DDS reader — payload received and delivered correctly
- [x] Full SPDP/SEDP exchange verified across both scenarios

---

## Phase 19: Dev Plan Accuracy Pass ✓
*Reconcile the plan with actual code state as revealed by the 2026-04-18 code review.
The goal is an honest baseline for Phases 20–24, not a feature release.*

- [x] Correct the DATA_FRAG claim in the Phase 5 Resolved decisions table — reassembly was never
  implemented end-to-end; `StatefulWriter` returns `error.MessageTooLarge` for large payloads
  (`writer_sm.zig:42-51`); only parser-level submessage parsing exists
- [x] Correct the Phase 4 portability claim in Resolved decisions — `util/time.zig` and
  `transport/monitor/polling.zig` use `std.os.linux.*`; the codebase is currently
  POSIX/Linux-only despite the "cross-platform from day one" claim
- [x] Correct Phase 6 QoS matching claim — `qos_match.zig` covers 7 endpoint-level policies plus
  separate pub/sub-level checks; the live discovery path in `sedp.zig` and `participant.zig` does
  not call the matcher before creating proxies (tracked in Phase 20)
- [x] Mark Phase 7 DCPS as partially complete: working are DataWriter/DataReader basic write/read,
  Publisher/Subscriber, loopback delivery. Still stubs: `Topic.get_statuscondition()` (nil at
  `topic.zig:91-95`), `DataReader.create_querycondition()` (nil at `reader.zig:234-243`),
  `DomainParticipant.get_builtin_subscriber()` (nil at `participant.zig:847`),
  `create_contentfilteredtopic()` (nil at `participant.zig:915-919`), built-in discovery query
  APIs (`participant.zig:1037-1069`); DataWriter/DataReader status getters return zeroed structs;
  `WaitSet.wait()` is a spin-sleep loop

## Phase 20: QoS Matching in Live Discovery ✓
*Wire the existing `QosMatcher` into the live discovery path and propagate incompatibility status.*

- [x] `participant.zig:onWriterDiscovered()` / `onReaderDiscovered()` — gate proxy creation on QoS
  compatibility via `qm_mod.checkSnapshots`; QoS check happens here (not in sedp.zig, since the
  match is between local endpoint QoS and remote QoS snapshot; sedp.zig correctly forwards all
  discovered endpoints to DCPS)
- [x] Complete QoS policy checks — `checkWriterReader` already covered 7 endpoint-level policies
  + `checkPresentation` + `checkPartition` = all spec-required policies (DDS v1.4 §2.2.3 Table 2-3).
  Added `checkSnapshots` to `qos_match.zig` for QosSnapshot-based matching; covers DURABILITY,
  OWNERSHIP, LIVELINESS kind, RELIABILITY, DESTINATION_ORDER. DEADLINE/LATENCY_BUDGET/LIVELINESS
  lease_duration absent from QosSnapshot; tracked for Phase 22 QosSnapshot expansion.
- [x] Accurate status tracking: `DataWriter.incompat_total/last_policy` + `DataReader.incompat_total/
  last_policy` populated by `notifyIncompatibleQos`; `vtGetIncompatQos` returns real counters
- [x] `IncompatQosNotify` callback registered via `ParticipantCbs.register_incompat_qos` in
  `publisher.zig` / `subscriber.zig`; wired in `makePubCbs` / `makeSubCbs`
- [x] Listener callbacks: `on_requested_incompatible_qos` / `on_offered_incompatible_qos` fired
  when `listener_mask` includes the status bit; `status_changes` mask updated
- [x] Tests: 8 `checkSnapshots` unit tests in `qos_match.zig`; end-to-end loopback test
  "incompatible QoS — best_effort writer vs reliable reader" verifies proxy not created,
  both counters incremented, no sample delivered (228/228 pass)

## Phase 21: DCPS API Completeness ✓
*Implement the Phase 7 stubs that currently exist as nil returns or no-ops.*

### Pre-step: Discovery Correctness ✓ (complete before API Completeness work)

- [x] `spdp.zig:processSpdpPayload` — gate `on_participant_discovered` (DCPS) and
  `on_participant_discovered_sedp` (SEDP) on `is_new`; re-announcements from known
  participants silently refresh `expires_ms` and locator data only.
  SEDP's `participant_locs` map update remains unconditional (cheap, handles rare locator-change).
- [x] SEDP idempotency via initial AckNack: rather than guarding `addMatchedReader` /
  `addMatchedWriter` against duplicate calls (which would prevent re-discovery after lease expiry),
  the fix is an initial non-final AckNack in `StatefulReader.addMatchedWriter`. When a reader
  proxy is added, the reader immediately solicits data — writer retransmits any cached changes.
  This is spec-correct (RTPS §8.4.10.3) and works regardless of write-before-discovery timing.
  The old re-announce-replay churn is eliminated by the `is_new` gate above.
- [x] `StatefulReader.handleData` — RELIABLE readers buffer out-of-order changes per
  `WriterProxy.pending_changes` and fire `on_data` only when the sequence is contiguous.
  `deliverPendingLocked` flushes buffered changes after each in-order delivery, GAP, or
  virtual GAP (Heartbeat `first_sn > next_expected_sn` means early SNs are permanently
  evicted — KEEP_LAST scenario). BEST_EFFORT keeps immediate delivery.
  `StatefulWriter.handleAckNack` now sends a follow-up Heartbeat when data is retransmitted,
  so the reader learns `first_sn` and can advance its delivery watermark via the virtual GAP.
  Added `reliable: bool` parameter to `StatefulReader.init`, `RtpsProtocolReader.init`;
  participant passes `r_reliable` from QoS; SEDP internal readers use `reliable=false`.

### API Completeness

- [x] `StatusCondition` — working implementation on all entity types (Participant, Publisher,
  Subscriber, Topic, DataWriter, DataReader); enable/disable status kinds; trigger fires on
  status change; push-notifies WaitSets via `WakeupList`; `Topic.get_statuscondition()` now
  returns a live `StatusConditionImpl`
- [x] `WaitSet.wait()` — condvar-based blocking with push notification; `WakeupList` used by
  Guard/Status conditions; `DataNotifyFn` round-trip through DataReader for ReadCondition;
  `util/condvar.zig` wraps `pthread_cond_t`; replaces spin-sleep; `ReadConditionImpl.init`
  takes `add_notify_fn` / `remove_notify_fn` fn pointers to avoid circular import
- [x] `DataReader.get_matched_publications()` / `get_matched_publication_data()` — populated
  from live `WriterProxy` list via `ProtocolReader.list_matched_writers`; GUID hashed to
  `InstanceHandle_t`; key set from GUID prefix
- [x] `DataWriter.get_matched_subscriptions()` / `get_matched_subscription_data()` — populated
  from live `ReaderProxy` list via `ProtocolWriter.list_matched_readers`; same GUID hash scheme
- [x] `DomainParticipant.get_discovered_participants()` / `get_discovered_participant_data()` —
  `discovered_participants: ArrayListUnmanaged(DiscoveredParticipant)` cache maintained by
  `onParticipantDiscovered` / `onParticipantLost`; skips self; deduplicates
- [x] `Subscriber.notify_datareaders()` — fires `on_data_available` listener on all readers
  that have registered for DATA_AVAILABLE_STATUS
- [x] `DataReader.wait_for_historical_data()` — returns `RETCODE_OK` for VOLATILE durability
  (no historical data to wait for); `RETCODE_UNSUPPORTED` for non-volatile (not yet implemented)
- [x] `DataReader.create_querycondition()` — `QueryConditionImpl` in `waitset.zig`; stores
  expression + parameters (owned copies); trigger is identical to ReadCondition (has pending
  data); `toCondition()` returns embedded `ReadConditionImpl` interface so WaitSet attachment
  works transparently. SQL-subset expression evaluation against CDR payloads deferred until
  typed DataReader wrappers exist.
- [x] `ContentFilteredTopic` — `ContentFilteredTopicImpl` in `topic.zig`; full lifecycle via
  `vtCreateCFTopic` / `vtDeleteCFTopic`; tracked in `DomainParticipantImpl.cft_topics`;
  `toTopicDescription()` wires it as a `DDS.TopicDescription` for `create_datareader()`;
  `get/set_expression_parameters` work; filter evaluation against CDR deferred (DataReader
  receives all samples for now).
- [x] `Subscriber.get_datareaders()` — mask filtering applied: includes only readers with pending
  data when `NOT_READ_SAMPLE_STATE`, `NEW_VIEW_STATE`, and `ALIVE_INSTANCE_STATE` are set;
  correctly returns empty when masks exclude those states (matches our simple pending-queue model).
- [x] `Publisher.wait_for_acknowledgments()` / `DataWriter.wait_for_acknowledgments()` —
  BEST_EFFORT → `RETCODE_OK` immediately; RELIABLE → poll-based with timeout (1 ms sleep).
  `ReaderProxy` gained `reliable: bool` field (from `MatchedReaderInfo.reliability`);
  `StatefulWriter.allProxiesAcked(target_sn)` excludes BEST_EFFORT proxies; `DataWriterImpl`
  tracks `last_sn`; `ProtocolWriter` vtable gained `all_acked(target_sn) bool`.
- [x] `DomainParticipant.get_builtin_subscriber()` — live built-in subscriber backed by
  DCPSParticipant / DCPSTopic / DCPSPublication / DCPSSubscription built-in topics.
  `BuiltinSubscriberState` in `participant.zig`: heap-allocated, holds `*SubscriberImpl` +
  four `*DataReaderImpl` instances backed by noop `ProtocolReader`s + embedded
  `BuiltinTopicDescImpl` (minimal `TopicDescription` vtable stubs). Created eagerly in
  `DomainParticipantImpl.init()` (null on OOM). Discovery callbacks
  (`onParticipantDiscovered`, `onWriterDiscovered`, `onReaderDiscovered`) release
  `participant.mu` before calling `DataReaderImpl.pushCdr()` so listener callbacks do not
  fire with the participant lock held. CDR serialized via `zidl_rt.CdrWriter(.xcdr1)`.
  `lookup_datareader()` on the builtin subscriber works; WaitSet/ReadCondition/listener
  notifications on discovery events work. SQL filter evaluation and `DCPSTopic` population
  deferred (the DCPSTopic reader exists but receives no samples until topic discovery is
  wired).

## Phase 22: Transport Robustness and Configuration Wiring ✓
*Fix concrete bugs and close the gap between configured values and actual runtime behavior.*

- [x] Fix `UdpTransport.init()` error-path leak: `PollingMonitor` allocated at `udp.zig:222-224`
  is not freed if `enumerate()` fails at `udp.zig:228`
- [x] SPDP unicast-reply jitter — fast-announce approach: on new-peer discovery, temporarily
  halve the announcement period for a 2×period window. Tracked via `fast_announce_until_ms`
  atomic field in `spdp.zig`; scales better than random jitter for large N.
- [ ] Note (known scaling issue): the SPDP `StatelessWriter` permanently accumulates one
  unicast locator per discovered participant (`spdp.zig:337-339`); after startup, every
  periodic SPDP announcement unicasts to all known peers in addition to multicast.
  For small N this is harmless. For large N, SPDP send traffic grows as O(N). Proper fix
  is a `LocatorSelector` abstraction (tracked in Planned section).
- [x] Stop advertising `0.0.0.0` as a unicast locator when interface enumeration returns nothing
  (`udp.zig:433-436`); log a warning and leave the locator list empty
- [x] `DomainParticipant.start()` — derive RTPS discovery ports, multicast locator, lease
  duration, and participant name from config + transport values; remove Phase 9-era hardcodes
- [x] Config file search — implement `~/.config/zzdds/config.toml` fallback in `findConfigFile()`
  (`resolve.zig:101-108`) to match the documented search order at `resolve.zig:9-13`
- [x] SEDP `retractWriter()` / `retractReader()` — send disposal/unregister announcement on
  endpoint removal; sends NOT_ALIVE_DISPOSED with `PID_STATUS_INFO` inline QoS; receive
  side detects disposal and fires `on_writer_lost` / `on_reader_lost`
- [x] IPv6 multicast leave on socket close (deferred at `udp.zig:890-893`)
- [x] Persistent per-interface send socket — open once at init rather than per-datagram in
  `sendUdp4()` / `sendUdp6()`
- [x] Fix trace accuracy: `recv_acknack.count` hardcoded to `0` in
  `StatefulWriter.handleAckNack()`; threaded actual count through all callers

## Phase 23: DATA_FRAG Deferral Cleanup ✓
*Formally defer full DATA_FRAG implementation until Phase 25; update plan accuracy.*

- [x] Update the Phase 5 Resolved decisions table entry to record the deferral decision:
  implementation deferred to Phase 25; Phase 24 adds a round-trip test that pins the
  current `error.MessageTooLarge` behavior so regressions are caught
- [x] Update CLAUDE.md implementation status

## Phase 24: Test Coverage and Tooling Gaps
*Close the most significant gaps between `docs/design/testing-strategy.md` and the actual test suite.*

- [x] SEDP test suite (`test/discovery/sedp_test.zig`): encode/decode round-trips, endpoint
  retract (retractWriter/retractReader fire on_writer_lost/on_reader_lost), SPDP+SEDP combined
  flow (pre-discovery replay, post-discovery delivery, proxy deduplication on re-announcement)
- [x] DCPS API test suite (`test/dcps/api_test.zig`): Participant lifecycle, Publisher/Subscriber/
  DataWriter/DataReader create/delete, Topic, WaitSet + condition trigger behavior, StatusCondition;
  also fixed `vtDeleteParticipant` to return `RETCODE_PRECONDITION_NOT_MET` when children exist
- [x] Config resolver env-precedence tests — `ZZDDS_*` overrides exercised in isolation from
  file/default layers; 6 tests added to `resolve.zig` covering integer/bool/enum parsing,
  invalid-value ignore, env-beats-default, and programmatic-beats-env precedence
- [x] Trace subsystem tests: `SyncSink` output correctness, `AsyncRingSink` drop accounting and
  `skipped` event emission, GUID filter pass/block, text vs NDJSON format; also fixed `trace.zig`
  to use `*std.Io.Writer` (was `std.io.AnyWriter`, non-existent in Zig 0.16.0 — latent bug)
- [x] `zig build test-tsan` step — `sanitize_thread = true`; TSan-clean for state-machine and
  discovery code; runs library self-tests, RTPS state machine tests, and DCPS tests under TSan
- [x] RTPS parser/builder coverage extended: ACKNACK, GAP, DATA, INFO_DST round-trip tests;
  addInfoTsInvalidate wire format test; 5 new tests in `builder.zig`
- [x] QoS matcher tests covering all 22 policies — 39 tests in `qos_match.zig` cover all 9
  compatibility-relevant policies: DURABILITY, DEADLINE, LATENCY_BUDGET, OWNERSHIP, LIVELINESS,
  RELIABILITY, DESTINATION_ORDER (checkWriterReader/checkSnapshots), PRESENTATION, PARTITION;
  remaining 13 policies are not RxO and require no compatibility test
- [x] MockTransport-based DCPS integration tests (`test/dcps/mock_loopback_test.zig`): 4 tests
  (BEST_EFFORT, RELIABLE, RELIABLE KEEP_ALL, incompatible QoS) run full SPDP → SEDP → data delivery
  using MockNetwork + deliverAll() poll loop; decouple CI from real sockets; pass under TSan
- [x] Interop scenario manifests: `[MILESTONE]` / `[PASS]` / `[FAIL]` structured log markers added
  to `test/interop/zzdds_pub.zig` and `zzdds_sub.zig`; markers cover PARTICIPANT start, SEDP match,
  DATA write, and final pass/fail outcome so failures narrow the search space without manual
  reproduction
- [x] Artifact bundles on interop failure: `test/interop/Makefile` now captures stdout+stderr for
  every process to `logs/s<N>_<name>.log`; foreground processes also stream live via `tee`; on
  failure the background-process log is dumped to stdout for CI capture; `make bundle-artifacts`
  tarballs the logs directory for post-mortem analysis; `make clean-logs` removes them
- [x] DATA_FRAG acceptance-gate test (`test/rtps/frag_roundtrip_test.zig`): 3 tests pin the
  current Phase 24 behavior: `sendIovecs` returns `error.MessageTooLarge` for payloads >
  `MAX_SEND_BYTES` (65536), succeeds for payloads ≤ `MAX_SEND_BYTES`; Phase 25 replaces
  `sendIovecs` with a fragment-aware sender and changes the expectError to success

## Phase 25: DATA_FRAG Fragmentation ✓
*Implement the full writer/reader fragmentation path; the Phase 24 round-trip test becomes the acceptance gate.*

- [x] `RtpsConfig.fragment_size: u16 = 16384` added to `config/schema.zig`; configurable default,
  MTU-aware auto-calculation deferred.
- [x] `DEFAULT_FRAG_SIZE: u16 = 16384` and `frag_size: u16` field in `StatefulWriter`; init takes
  frag_size parameter; when `data.len > frag_size`, splits into `DATA_FRAG` submessages via
  `builder.addDataFrag()`; `HEARTBEAT_FRAG` sent after last fragment.
- [x] `handleNackFrag` on `StatefulWriter`: retransmits specific requested fragments + HEARTBEAT_FRAG;
  `builder.addHeartbeatFrag` and `builder.addNackFrag` added to `message/builder.zig`.
- [x] `ReassemblyEntry` with `std.DynamicBitSet` (no fragment count cap) on `WriterProxy` in
  `StatefulReader`; reassembly keyed by `SequenceNumber`; `handleDataFrag` assembles and fires
  `on_data` callback on completion; `handleHeartbeatFrag` + `sendNackFragLocked` handle recovery.
- [x] `handle_nack_frag` added to `ProtocolWriter.Vtable`; `handle_data_frag` and
  `handle_heartbeat_frag` added to `ProtocolReader.Vtable`; wired through `protocol_adapters.zig`.
- [x] `.data_frag`, `.heartbeat_frag`, `.nack_frag` arms wired in `participant.zig`
  `userDataOnReceive`; `config.rtps.fragment_size` passed to `RtpsProtocolWriter.init`.
- [x] `sedp.zig`: both `StatefulWriter.init` calls updated to pass `DEFAULT_FRAG_SIZE`.
- [x] `test/rtps/frag_roundtrip_test.zig`: old `error.MessageTooLarge` gate replaced with four
  end-to-end round-trip tests (BEST_EFFORT, RELIABLE, boundary, multi-sample); `sendIovecs`
  boundary tests retained.
- [x] `test/rtps/mock_transport_test.zig`: `.data_frag`, `.heartbeat_frag`, `.nack_frag` arms added
  to `ReaderDispatch`/`WriterDispatch`; all existing `StatefulWriter.init` calls updated.

Deferred to a future phase:
- Cyclone DDS and OpenDDS interop scenario with a fragmented payload (needs `matchedWriterCount` fix first)
- NACK_FRAG retransmit drop scenario (drop individual fragments, verify recovery via NACK_FRAG loop)
- Reassembly timeout / garbage-collect entries on `NOT_ALIVE_DISPOSED`

---

## Phase 26: Interop Compilation Fix + matchedWriterCount
*Fix the pre-existing `matchedWriterCount` compilation error in `test/interop/zzdds_sub.zig` that
prevents the interop test binary from building, then validate that the fragmented-payload interop
scenario works end-to-end.*

- [x] Add `matchedWriterCount()` (or equivalent) to `DataReaderImpl` / the DCPS DataReader vtable,
  or fix the call site in `test/interop/zzdds_sub.zig` if the method was renamed
- [x] Confirm `zig build` produces no errors (the lone remaining compilation failure)
- [x] Run `zig build interop-test-cyclone` with a payload > `frag_size` to exercise the
  DATA_FRAG path end-to-end against Cyclone DDS
- [x] Complete bi-directional DATA_FRAG interop matrix (Cyclone S1–S4, OpenDDS S3–S6):
  S3=Zenzen DDS TX frag→Cyclone, S4=Cyclone TX frag→Zenzen DDS, S5=Zenzen DDS TX frag→OpenDDS,
  S6=OpenDDS TX frag→Zenzen DDS; Cyclone default 1344 B, OpenDDS hardcoded 1024 B

---

## Phase 27: `ignore_participant()` DCPS API (Partial) ✓
*Implement the normative DDS v1.4 §2.2.2.2.1.28 ignore API.*

- [x] `ignore_participant(handle)` on `DomainParticipant`: add an ignore-list (set of GUID prefixes)
  to `DomainParticipantImpl`; SPDP silently discards announcements from ignored prefixes without
  firing discovery callbacks or creating SEDP proxies
- [x] `ignore_topic()`, `ignore_publication()`, `ignore_subscription()` stubs (normative; can be
  no-ops initially with a note that full filter-on-delivery is a future phase)
- [x] Unit tests: ignored participant does not appear in discovered-participant cache; matched
  writer/reader callbacks do not fire for endpoints under an ignored participant

---

## Phase 28: CI/CD ✓
*Both zidl and zzdds are in GitHub repositories with GitHub Actions CI.*

- [x] zidl repository published to GitHub; GitHub Actions CI configured
- [x] zzdds repository published to GitHub; GitHub Actions CI configured
- [x] Cross-platform matrix: Linux and macOS on both x86_64 and arm64; Windows on x86_64 and arm64
- [x] `zig build test` runs cleanly across all targets in CI

---

## Phase 29: IntraProcessDelivery Infrastructure
*Introduce `MemoryTransport` and `DirectDiscovery` to enable fast, deterministic, network-free
testing of the full RTPS/DCPS stack. Foundation for Phases 30–31.*

- [x] `src/transport/memory.zig` — `MemoryTransport`: factory-scoped channel map (`port → ReceiveHandler`);
  `listen()` registers a handler; `send()` looks up and calls `on_receive` synchronously;
  multicast not needed (DirectDiscovery bypasses SPDP/SEDP); `unicastLocators()` returns synthetic
  locators using the standard port formula (7410 + 2*id for domain 0). Also fixed
  `writer_sm.zig:sendChangeToAllLocked` to guard inline Heartbeat with `if (rp.reliable)` —
  BEST_EFFORT proxies never AckNack, so sending them a Heartbeat was both spec-wrong and would
  deadlock synchronous delivery by re-entering writer.mu.
- [x] `src/discovery/direct.zig` — `DirectDiscovery` + `DiscoveryBus`: shared registry across
  all participants; `announceWriter()` / `announceReader()` immediately invoke
  `on_writer_discovered` / `on_reader_discovered` on all other registered participants synchronously;
  `retractWriter()` / `retractReader()` fire `on_writer_lost` / `on_reader_lost`; `stop()` retracts
  all endpoints; late-joiner support (new participant learns existing endpoints on `start()`)
- [x] `src/delivery/intraprocess.zig` — `IntraProcessDelivery` bundle: owns `MemoryBus` +
  `DiscoveryBus`; `newTransport()` / `newDiscovery()` create per-participant instances; factory
  interface (`init(transport, discovery, ...)`) unchanged — each participant factory gets its own
  transport+discovery pair from the shared delivery bundle
- [x] Tests updated to use `IntraProcessDelivery` where existing tests use `MockTransport` manually;
  `MockTransport` retained as-is for protocol-level drop/dupe testing

**Naming note:** `MemoryTransport` (mechanism-named, pairs with future `SharedMemoryTransport`) and
`DirectDiscovery` (style-named, contrasts with `SpdpSedpDiscovery`) intentionally follow different
conventions. `IntraProcessDelivery` is the user-facing name that signals their shared scope.

---

## Phase 30: UDP Transport Architecture ✓
*Decouple send-socket lifetime from listen-socket lifetime; introduce fan-out port dispatch with
refcounted registration; add explicit port-override configuration. Prerequisite for multi-participant
shared-transport and single-port firewall deployments. Must land before C language bindings freeze
the Transport vtable.*

- [x] **Stable send-socket lifetime** — `send_fd_v4`/`send_fd_v6` are owned by the transport from
  `init()` to `deinit()` and never promoted to a listen-socket fd. Remove the promotion logic from
  `vtListen` (`udp.zig:760,776-783`) and `onIfaceChange` (`udp.zig:613-621`). When a unicast
  listen socket is created for an interface, configure `IP_MULTICAST_IF` directly on the owned send
  socket so multicast sends use the correct outgoing interface. The `vtSend` lock-free read of
  `send_fd_v4`/`v6` is unchanged; those atomics now never hold a stale closed fd.
- [x] **send_fd reset patch (Option A)** — as an immediate stop-gap applied before the full Option B
  work: in `removeSockets` and `removeUnicastSockets`, when a removed socket's fd matches
  `send_fd_v4` or `send_fd_v6`, reset the atomic back to the owned send fd. Eliminates the EBADF
  teardown warnings in loopback and interop tests. Superseded (and removed) once Option B lands.
- [x] **Fan-out port dispatch** — `port_handlers: AutoHashMapUnmanaged(u32, ReceiveHandler)` →
  `port_entries: AutoHashMapUnmanaged(u32, *PortEntry)` where `PortEntry` holds an
  `ArrayListUnmanaged(ReceiveHandler)` and a per-port dispatcher `ReceiveHandler`. `vtListen`:
  `getOrCreate` the `PortEntry`, append the caller's handler; create sockets only when the first
  handler registers. `vtUnlisten`: remove the handler by `ctx` identity; tear down sockets only
  when the last handler deregisters. The per-port dispatcher snapshots the handler list under `mu`
  then calls each handler without `mu` (same snapshot pattern as `DiscoveryBus`). `SocketEntry`
  continues to hold a single `ReceiveHandler` — it points to the port's dispatcher, not directly
  to any participant callback. `onIfaceChange` uses `port_entries` as the authoritative set of
  active ports. `Transport.unlisten` vtable signature extended to accept the `ReceiveHandler` being
  deregistered; all vtable implementations and call sites updated.
- [x] **Port configuration additions** — `UdpConfig`:
  - `meta_unicast_port: ?u16 = null` — when non-null, bypasses the RTPS §9.6.1.1 formula for the
    metatraffic unicast port entirely; participant ID auto-assign still runs (needed for data port
    unless also overridden), but the formula result for the meta port is ignored
  - `data_unicast_port: ?u16 = null` — same bypass for the default unicast (user data) port
  - `data_port_separate: bool = true` — when `false`, `participant.zig:start()` skips the second
    `transport.listen()` call for the data unicast port; all user data traffic flows through the
    metatraffic unicast socket. Breaks RTPS §8.7.7 interoperability with spec-compliant peers but
    is correct for single-port firewall deployments where all participants are zenzen_dds.
  - `bind_wildcard: bool = false` (previously unimplemented) — now wired up in `vtListen`:
    creates one 0.0.0.0 / :: socket per enabled family instead of per-interface sockets.
- [x] **Multi-participant shared-transport test** — `fan-out port dispatch delivers to all
  registered handlers` and `two participants share one UdpTransport; independent teardown` in
  `src/transport/udp.zig`; both use `bind_wildcard = true` for deterministic loopback delivery.
  Verifies fan-out dispatch, per-handler deregistration, and send_fd validity after partial teardown.

---

## Phase 31: DCPS Conformance — QoS Runtime Behaviors
*Implement and test QoS policies that have runtime behavioral effects beyond matching.
All tests use `IntraProcessDelivery`. Timer infrastructure for deadline/liveliness is part of
this phase's implementation scope.*

### Clock infrastructure refactor (prerequisite for DEADLINE/LIVELINESS)
*Using CLOCK_REALTIME for internal timers is a correctness bug: NTP steps and leap seconds can
make elapsed-time checks go backwards, falsely triggering or suppressing deadline/liveliness events.
This refactor must land before DEADLINE or LIVELINESS are implemented.*

- [x] **Upgrade `Clock` vtable to nanosecond precision** — replaced `now_ms`/`sleep_ms` with
  `now_ns`/`sleep_ns`; updated all call sites (`realtimeClock`, `ManualClock`, SPDP timer,
  `writer.zig` RELIABLE resource-limits poll).
- [x] **Add `monotonicClock()`** — backed by `CLOCK_MONOTONIC` on POSIX and QPC on Windows.
  SPDP timer now defaults to `monotonicClock()` instead of `realtimeClock()`.
- [x] **Add `boottimeClock()`** — Linux: `CLOCK_BOOTTIME`; other platforms: falls back to
  `CLOCK_MONOTONIC`. Accounts for suspend time; relevant for liveliness lease expiry.
- [x] **Two clock slots in participant config** — `wire_clock: Clock` (default: `realtimeClock()`,
  used for `RtpsTimestamp.now()`) and `timer_clock: Clock` (default: `monotonicClock()`, used for
  all internal interval timers). RTOS users supply a custom `Clock` for `timer_clock`. Implemented
  via `clock_registry` in `DomainParticipantFactoryImpl`; `config.participant.timer_clock_name`
  selects the clock; defaults to `monotonicClock()` when name is empty or unregistered.
- [x] **Switch internal timers to `timer_clock`** — SPDP heartbeat timer switched to
  `monotonicClock()`. DEADLINE/LIVELINESS timers use the injected `timer_clock`.

### QoS runtime policies
- [x] **OWNERSHIP + OWNERSHIP_STRENGTH** — exclusive ownership: only the highest-strength matched
  writer delivers samples; writes from lower-strength writers are silently dropped at the reader.
  Ownership transfer when active writer's strength drops below a newly matched writer's strength.
  Fixed root bug: `getChange(sn)` in history cache matched by SN only, returning the wrong writer's
  entry when multiple writers share the same SN. Added `getChangeForWriter(writer_guid, sn)` and
  updated all call sites in `reader_sm.zig::deliverChangeLocked`.
- [x] **RESOURCE_LIMITS** — `max_samples`, `max_instances`, `max_samples_per_instance`; writes
  beyond limits return `RETCODE_OUT_OF_RESOURCES` (BEST_EFFORT) or block until space available
  (RELIABLE, with timeout).
- [x] **TIME_BASED_FILTER** — reader suppresses samples arriving faster than `minimum_separation`;
  only the most recent sample within each window is delivered.
  Also fixed: `userDataOnReceive` now tracks INFO_TS submessages and passes the writer's source
  timestamp through to `handleIncomingChange` instead of always substituting `RtpsTimestamp.now()`.
- [x] **DEADLINE** — `DataWriter`: fires `on_offered_deadline_missed` when `write()` is not called
  within `deadline.period`; `DataReader`: fires `on_requested_deadline_missed` when no sample
  arrives within `deadline.period`. Per-writer/reader `last_write_ns`/`last_received_ns` atomics;
  `participant.checkTimers()` drives expiry checks. `durationIsActive()` treats both `{0,0}` and
  `DURATION_INFINITE` as "disabled".
- [x] **LIVELINESS** — `AUTOMATIC`: asserts on `write()`; `MANUAL_BY_PARTICIPANT`: asserts via
  `participant.assert_liveliness()`; `MANUAL_BY_TOPIC`: asserts via `writer.assert_liveliness()`.
  Fires `on_liveliness_lost` when lease expires. `vtAssertLiveliness` fully implemented.
  Reader-side `on_liveliness_changed` deferred to Phase 32 (requires cross-participant tracking).
- [x] Tests: `TimerFixture` + `ManualClock` drives deterministic timer assertions; 9 tests covering
  DEADLINE (writer, reader, inactive) and LIVELINESS (AUTOMATIC, MANUAL_BY_PARTICIPANT,
  MANUAL_BY_TOPIC, inactive) in `test/dcps/qos_runtime_test.zig`.

---

## Phase 32: DCPS Conformance — Instance Lifecycle and Read/Take Semantics
*Implement SampleInfo, instance state machine, read/take filter semantics, ContentFilteredTopic
expression evaluation, and listener completeness. Resolves the `on_publication_matched` open question.*

- [x] **SampleInfo fields** — `sample_state` (NOT_READ on arrival), `view_state` (NEW_VIEW_STATE
  for first sample per instance, NEW_VIEW_STATE on resurrection after NOT_ALIVE; NOT_NEW_VIEW_STATE
  otherwise), `instance_state` (ALIVE/NOT_ALIVE_DISPOSED/NOT_ALIVE_NO_WRITERS), `source_timestamp`
  from wire, `instance_handle` (FNV-1a of key hash), `publication_handle` (FNV-1a of writer GUID),
  `valid_data` (true for ALIVE, false for NOT_ALIVE_*). Reader tracks `seen_instances` map for
  view_state and resurrection detection.
- [x] **Instance lifecycle** — `DataWriterImpl.disposeRaw()` sends NOT_ALIVE_DISPOSED; `unregisterRaw()`
  sends NOT_ALIVE_DISPOSED or NOT_ALIVE_UNREGISTERED per `autodispose_unregistered_instances` flag.
  Fixed `userDataOnReceive` to parse `status_info` inline QoS → ChangeKind (previously hardcoded to
  ALIVE). Fixed `vtHandleIncomingChange` in protocol_adapters to pass kind to CacheChange. Tests
  cover first-sample, second-sample, dispose, resurrection, and unregister (both autodispose modes).
- [x] **Read/take semantics** — `readRaw()` non-destructive: marks samples READ_SAMPLE_STATE
  in-place, returns clones; `takeFiltered()` removes matching samples in a single-pass compaction.
  Both accept `(sample_mask, view_mask, instance_mask, max_samples, maybe_ih)` masks.
  `takeRaw()` retained as a zero-filter convenience. Tests in `test/dcps/read_take_test.zig` cover
  non-destructive read, READ-state marking, NOT_READ filter, max_samples, view_state filter,
  instance_state filter, and empty-queue edge case.
- [ ] **ContentFilteredTopic expression evaluation** — SQL-subset filter evaluated against CDR
  payloads at the reader; currently all samples delivered regardless of filter expression
- [ ] **`on_publication_matched` / `on_subscription_matched`** — implement the readiness contract
  for RELIABLE writers (per the open question below); BEST_EFFORT fires immediately on SEDP/direct
  discovery; add per-proxy readiness state machine and test suite
- [ ] **Remaining listener status kinds** — audit all status getters that return zeroed structs;
  implement or explicitly stub with `RETCODE_UNSUPPORTED` and a plan note
- [ ] Tests: instance lifecycle state machine transitions; read/take with all state filter
  combinations; CFT expression evaluation; matched/unmatched listener callbacks

---

## Phase 33: dds-rtps Self-Interop Validation
*Run the OMG dds-rtps conformance suite with zenzen_dds vs zenzen_dds to validate the full RTPS stack
against itself before measuring against external peers. All 7 known failures from the April 2026
Cyclone run are DCPS-layer issues resolved by Phases 31–32.*

- [ ] **`zig build self-interop` step** — invoke the dds-rtps Python harness
  (`/storage/tsimpson/code/dds-rtps/test_suite.py`) automatically with zenzen_dds as both pub and sub
  process; emit structured results (PASS/FAIL/TIMEOUT per test case) and exit non-zero on any failure
- **Known failures resolved before this phase:**
  - [x] `Ownership_1`, `Ownership_3` — passing (resolved by Phase 31 OWNERSHIP runtime enforcement)
  - [x] `Partition_0`, `Partition_1`, `Partition_2` — passing (Partition QoS enforcement: PID_PARTITION
    encode/decode in SEDP, `checkPartition` in `onWriterDiscovered` / `onReaderDiscovered`, Partition QoS
    wired through publisher/subscriber announce callbacks)
- **Remaining failures:**
  - [ ] `Ownership_4` — per-instance ownership: current implementation tracks a single `current_owner:
    ?Guid` globally per DataReaderImpl; the test exercises multiple instances (colors) where each instance
    must elect its owner independently.

    **Prerequisite — zidl `deserializeKey` + `computeKeyHash` generation**: the middleware must compute
    instance handles from raw CDR bytes at receive time. This requires:
    1. zidl generates `deserializeKey` (reads only `@key` members from a CDR stream) and
       `computeKeyHash` (produces a 16-byte RTPS §9.6.3.8 instance handle) for all backends.
    2. zzdds uses these at the DCPS receive path to compute instance handles reliably instead of
       depending on the SHOULD (not SHALL) inline QoS `key_hash` field.

    See `zidl/docs/roadmap.md` §"Priority: deserializeKey + computeKeyHash" for the zidl-side plan.

    **zzdds changes after zidl lands:**
    - `DataReaderImpl`: replace `current_owner: ?Guid` with `owner_map: AutoHashMap(InstanceHandle_t, ?Guid)`
      keyed by instance handle.
    - DCPS receive path: compute instance handle via `deserializeKey` + `computeKeyHash` on the raw
      CDR payload; store on `CacheChange` so downstream logic (ownership check, TBF, resource limits,
      view state) all use the same computed handle.
    - `TIME_BASED_FILTER` (`tbf_last_ns`): same fix — currently global, should be per-instance.
    - `KEEP_LAST` history depth: per-instance tracking (currently global; noted in `history.zig`).

  - [ ] `Cft_0`, `Cft_1` — ContentFilteredTopic expression evaluation (Phase 32)

- [ ] **zenzen vs zenzen 100%** — all 48 test cases pass with both sides running zenzen_dds;
  gate: no self-interop regressions permitted from this point forward
- [ ] **zenzen vs Cyclone 100%** — repeat full run with Cyclone as the peer; confirm same 100%
  pass rate; document any new failures as regressions (all pre-existing failures should be closed
  by Phases 31–32)
- [ ] **Vendor ID registration** — register Zenzen DDS vendor ID with OMG (currently using a
  placeholder) before publishing dds-rtps results or submitting to the official results repo;
  note: existing binary committed to dds-rtps is sufficient for self-testing but uses unregistered
  vendor ID

---

## Planned (unnumbered — sequenced after Phase 33)
*These phases are committed but their exact scope will be refined as numbered phases are completed.*

- **TypeSupport callback registration (prerequisite for C/C++/Java language bindings)** —
  When non-Zig language bindings are added, the middleware core (Zig) receives raw CDR bytes from
  the network and must compute instance handles without having the Zig-generated type available.
  Two complementary mechanisms are planned:

  **Option A — TypeSupport callback registration (near-term, required for language bindings)**:
  The application registers a type with the participant via a registration call that includes
  C-ABI-compatible function pointers:
  ```c
  typedef struct {
      const char *type_name;
      int  (*serialize)(const void *sample, uint8_t *buf, size_t *len);
      int  (*deserialize)(const uint8_t *buf, size_t len, void *sample_out);
      void (*key_hash)(const uint8_t *buf, size_t len, uint8_t hash[16]);
  } ZzddsTypeSupport;
  ```
  `participant.registerType(ZzddsTypeSupport)` stores the callbacks by type name.
  The receive path calls `key_hash` to get the instance handle instead of reading inline QoS.
  For Zig-native types, a thin wrapper adapts the generated `computeKeyHash` to this ABI.
  For C/C++/Java bindings, the generated `Foo_compute_key_hash` is the direct implementation.
  `registerTypeInfo` (XTYPES blob) becomes one field of this broader registration struct.
  XTYPES support remains a build option (`-Dxtypes=true`); the type_info_cdr field is null
  when XTYPES is disabled, so the registration struct is usable without carrying TypeObject overhead.

  **Option B — XTYPES dynamic type interpretation (future, for remote type discovery)**:
  When a remote participant announces a type whose source is unavailable locally, zzdds
  interprets the TypeObject (which encodes `IS_KEY` flags per member, see `zig_typeobject.zig`)
  to extract key fields from CDR bytes at runtime — no generated code required.
  This is the correct mechanism for cross-vendor interoperability with unknown types.
  Depends on `build_opts.xtypes = true`; Option A still required for local type registration
  even when Option B is enabled.

- **FastDDS wire interop** — same HelloWorldData topic as Cyclone and OpenDDS interop; both scenarios;
  deferred until after Phase 31 so interop failures are clearly attributable to RTPS/discovery
  rather than DCPS-layer bugs
- **SEDP-traffic-seen heuristic** — add `sedp_seen: bool` to `KnownParticipant`; set when
  any SEDP message arrives from that GUID prefix. On each SPDP re-announcement from a
  known participant whose `sedp_seen` is still false, send a targeted unicast retransmit
  of our own SPDP announcement to that participant. Recovers from SEDP packet loss on
  the initial exchange without waiting for a full announcement period.
- **LocatorSelector abstraction** — replace the flat per-locator blast in
  `StatelessWriter.sendAll()` (and eventually `StatefulWriter`) with a selector that
  ranks candidate locators per remote GUID: prefer loopback when the remote advertises
  an address on a local interface; prefer a single unicast over multicast when the
  remote is reachable unicast; eventually support runtime per-locator latency tracking
  to break ties. A GUID-to-selected-locator cache amortizes selection cost across writes.
- **~~Platform portability~~** ✓ — portable equivalents for `util/time.zig` and
  `transport/monitor/polling.zig` implemented; CI validates Linux and macOS on x86_64 and
  arm64, and Windows on x86_64 and arm64. Further portability work deferred until Zig's
  cross-platform support matures. `monitor/pf_route.zig` and `monitor/netlink.zig` remain
  deferred (polling monitor is sufficient; see Deferred section).
- **C language binding** — zidl C backend + Zenzen DDS vtable implementations; stable ABI
- **C++ language binding** — zidl C++ backend; value-type wrappers over C ABI
- **Java language binding** — zidl Java backend; JNI bridge
- **Python / .NET bindings** — zidl backends; likely community-contributed
- **DDS-XTypes v1.3** — TypeObject/TypeIdentifier/TypeMapping; needed for type-safe language bindings
- **DDS Security v1.2** — Authentication (PKI-DH), AccessControl, Cryptographic (AES-GCM);
  fix `Cryptographic.encode_payload` tagged-union return first

---

## Open Questions

### Active (resolve before the noted phase)

- **Before Phase 31: Clock abstraction adoption is partial.**
  `SpdpEndpoints` exposes `setClock()` and uses the injected clock for lease checks
  (`spdp.zig:163-166,353-374`), but the SPDP timer thread still sleeps via `time_mod.sleepNs()`
  (`spdp.zig:335-351`). Phase 31 adds DEADLINE and LIVELINESS timer infrastructure to the DCPS
  layer; that work should use injectable clock/timer abstractions from the start so deadline/
  liveliness tests are deterministic without real sleeps.

- **Before Phase 32: `on_publication_matched` readiness contract for RELIABLE writers.**
  The DDS spec fires `on_publication_matched` on SEDP discovery, but users universally expect "I can
  write now and expect delivery." For RELIABLE this gap causes write-before-reader-ready bugs.
  Proposed default: fire on the first AckNack received from a reader proxy that correlates with a
  Heartbeat we already sent to that proxy (i.e., the AckNack base ≥ our first sent Heartbeat's
  firstSN). This guards against preemptive AckNacks sent by some implementations during proxy setup.
  Per-proxy state needed: `first_sent_hb_first_sn: ?SequenceNumber` (null until first HB sent).
  Fire matched when AckNack.base > first_sent_hb_first_sn (reader has acked at least up to that point).
  For BEST_EFFORT: fire immediately on SEDP discovery (no handshake exists).
  Escape hatch: `matched_ready_policy = .protocol_ready` (default) | `.spec_minimum` (fire on SEDP).
  Open edges before implementing:
  - Multiple concurrent readers: each ReaderProxy tracks its own readiness independently; the
    DataWriter's `PublicationMatchedStatus.current_count` increments per-proxy as each becomes ready.
  - Traffic minimization: the initial Heartbeat to a new proxy should be sent promptly on proxy
    creation (not waiting for the periodic HB timer) so round-trip latency is bounded.
  - Do not use vendor detection to fast-path ZZDDS-to-ZZDDS matching — the inter-version
    fragility cost outweighs the benefit; the HB round-trip is already fast.
  - This will need its own state machine test suite covering: normal ready sequence, preemptive
    AckNack arrives before HB sent, AckNack base below threshold, multiple proxies in various
    states, proxy removed before becoming ready.

- **Before Security phases:** Key material storage — file-based PEM certs to start. HSM abstraction deferred.
- **Before Security phases:** PKCS#11 — out of scope for v1; security plugin interface must not preclude it.

### Resolved
| Question | Decision |
|----------|----------|
| Phase 4: NIC/multicast interface selection | `UdpConfig.interfaces` accepts names or IPs; empty = all. One unicast socket per interface address (`bind_wildcard = false`, Cyclone style). IPv4/IPv6 auto-detected per interface; hard override flags available. |
| Phase 4: Platform portability scope | **[COMPLETED — Phase 28]** Linux, macOS, and Windows on x86_64 and arm64 all validated in CI. Further portability work (platform-specific interface monitors, etc.) deferred until Zig matures. |
| Phase 5: History cache allocator strategy | Per-change heap allocation (simple; upgrade to slab/ring-buffer if needed under load). |
| Phase 5: DATA_FRAG reassembly | **[IMPLEMENTED — Phase 25]** Full writer-side fragmentation and reader-side reassembly implemented. `StatefulWriter` splits payloads larger than `frag_size` (default 16384, configurable via `RtpsConfig`) into `DATA_FRAG` submessages and sends `HEARTBEAT_FRAG`. `StatefulReader` accumulates fragments in a `std.DynamicBitSet`-backed reassembly buffer (no fragment count cap); fires `on_data` when complete; handles `HEARTBEAT_FRAG` / `NACK_FRAG` recovery. Wired through `ProtocolWriter`/`ProtocolReader` vtables and `participant.zig` dispatcher. Four end-to-end round-trip tests pass. |
| Phase 5: Inline QoS size | Follow RTPS §9.6.2. |
| Phase 6: SPDP lease expiry behavior | Immediate removal, no grace period. Matches Cyclone + FastDDS. Spec (§8.5.3.3) leaves this implementation-defined. |
| Phase 6: GUID prefix strategy | `.random` default (12 OS-entropy bytes); `.host_based` optional (IP+PID+timestamp) for Wireshark/deterministic tests. |
| Phase 6: qos_match.zig placement | Pulled into Phase 6 prerequisites — SEDP cannot determine endpoint compatibility without it (RTPS §8.5.4). **[CORRECTED — Phase 19]** The matcher exists but covers only 7 of 22 endpoint-level policies; the live discovery path in `sedp.zig` and `participant.zig` does not yet call it. Wiring tracked in Phase 20. |
| Phase 7: QoS incompatibility notification | Via listener callbacks + StatusCondition (both, per DDS spec §2.2.4). **[CORRECTED — Phase 19]** Not implemented. Live discovery creates proxies regardless of QoS compatibility; status getters return zeroed structs. Tracked in Phase 20. |
| Phase 7: ContentFilteredTopic evaluator | Inline in DataReader.read/take (simpler; push-down is a future optimization). |
| Phase 7: DataReader.read() semantics | Loan-based API; first implementation copies. Zero-copy upgrade path preserved. |
| Phase 13: Logging/tracing architecture | Two independent systems: (1) `std.log.scoped` for diagnostic text (compile-time scope/level filtering via `scope_levels`; runtime via `logFn` override); (2) `src/trace.zig` for wire events (typed `TraceEvent` union, comptime-gated by `enable_wire_trace`, `Sink` vtable with `NoopSink`/`AsyncRingSink`/`SyncSink`, NDJSON output). GUID filter (`GuidFilter`, `enable_guid_filter`) included in Phase 13. Sink configured via `TraceConfig` on `DomainParticipantFactory`. |
| Phase 14: SPDP unicast relay policy | ZZDDS bug, not a Cyclone extension. RTPS §9.6.1.1 defines the metatraffic unicast port as carrying all metatraffic; no `interop_mode` guard needed. Fixed unconditionally via SEDP → SPDP relay callback. |
| Phase 15: BEST_EFFORT replay-on-new-proxy | Not implemented. Interop tests switched to RELIABLE instead — correct tool for guaranteed delivery, exercises a more meaningful code path, eliminates the timing-sensitivity retry hack. BEST_EFFORT replay deferred; if ever added it should be an explicit policy choice, not a default. |
| Phase 21 pre-step: `StatefulReader` RELIABLE delivery order | **Side B — hold until contiguous.** RELIABLE means in-SN-order delivery. `handleData` must buffer out-of-order payloads and fire `on_data` only when the SN is the next expected one; fire again for each SN that becomes contiguous when a gap fills. BEST_EFFORT keeps immediate delivery. RTPS §8.4.8 requires this; WaitSet/QueryCondition semantics depend on it. Implemented in Phase 21 pre-step. |
| Phase 21 pre-step: SPDP re-announcement `on_participant_discovered` semantics | **Edge-triggered — gate on `is_new`.** Re-announcements from known participants silently refresh `expires_ms` and locator data only; no DCPS or SEDP callbacks fire. Lease expiry (`checkLeases`) already correctly sets `is_new = true` when a participant re-appears after expiry. SEDP `onParticipantDiscovered` made idempotent (skip add if proxy already exists) to prevent history replay churn. Discovery response strategy (N² unicast burst, fast-announce period, SEDP-not-seen heuristic) tracked in Phase 22 and Planned section. |

---

## Deferred / Out-of-Scope for v1
- **DDS-RPC v1.0** (formal/17-04-01): design must not preclude it. IDL `interface` operations → request/reply topic pairs eventually.
- **XRCE profile** (formal/20-02-01): deferred; see `packages/zidl/CLAUDE.md` for constraints.
- **TRANSIENT / PERSISTENT durability**: persistence service plugin interface only; no implementation.
- **MultiTopic** (ContentSubscriptionProfile): deferred; basic ContentFilteredTopic only.
- **Group access presentation scope**: deferred.
- **Platform-specific InterfaceMonitors**: `monitor/netlink.zig` (Linux), `monitor/pf_route.zig` (macOS/BSD), `monitor/windows.zig` — polling default is sufficient for now.
- **TCP / SHMEM transports**: future `TransportPlugin` implementations; the `DeliveryPlugin` taxonomy
  (`IntraProcessDelivery`, `RtpsUdpDelivery`, `RtpsTcpDelivery`, `SharedMemoryDelivery`, etc.) and
  naming conventions (`MemoryTransport`, `SharedMemoryTransport`) are resolved — implementation deferred.
- **Java / C# language bindings**: C first (via zidl C backend), then C++.
- **wstring CDR in transport payloads**: follows zidl's existing wstring support.
