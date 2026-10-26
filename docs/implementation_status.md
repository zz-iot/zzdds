# Zenzen DDS — Implementation Status

Source-backed reference for what is and isn't implemented. See `docs/roadmap.md` for
planned work, `CHANGELOG.md` for the change history, and `docs/decisions.md` for stable
design decisions with rationale.

---

## Transport Layer

| Component | Status | Source |
|---|---|---|
| `UdpTransport` (IPv4 + IPv6) | Complete | `src/transport/udp.zig` |
| `MockTransport` (queued delivery, test harness) | Complete | `src/transport/mock.zig` |
| `MemoryTransport` (synchronous in-process) | Complete | `src/transport/memory.zig` |
| `LossyTransport` (wraps any transport, fault injection) | Complete | `src/transport/lossy.zig` |
| `InterfaceMonitor` (polling) | Complete | `src/transport/monitor/polling.zig` |
| `TcpTransport` (IPv4 + IPv6, length-prefix framing) | Complete | `src/transport/tcp.zig` |
| SHMEM transport | Not planned for v1 | — |

## Discovery

| Component | Status | Source |
|---|---|---|
| `SpdpSedpDiscovery` (SPDP + SEDP over UDP) | Complete | `src/discovery/spdp.zig`, `sedp.zig` |
| `DirectDiscovery` (in-process, synchronous) | Complete | `src/discovery/direct.zig` |
| Static config discovery | Not implemented | — |
| Centralized broker discovery | Not implemented | — |
| mDNS / DNS-SD discovery | Not implemented | Extension point only |

## RTPS Protocol

| Component | Status | Notes |
|---|---|---|
| Message framing (parser + builder) | Complete | `src/rtps/message/` |
| History cache (KEEP_LAST, KEEP_ALL) | Complete | `src/rtps/history.zig` |
| `StatefulWriter` / `StatefulReader` (reliable) | Complete | `src/rtps/writer_sm.zig`, `reader_sm.zig` |
| `StatelessWriter` / `StatelessReader` (best-effort) | Complete | Same files |
| HEARTBEAT / ACKNACK / GAP | Complete | |
| DATA_FRAG fragmentation + reassembly | Complete | `StatefulWriter` splits, `StatefulReader` reassembles |
| HEARTBEAT_FRAG / NACK_FRAG | Complete | Fragment ACK/retransmit; per-proxy stale-count suppression (§8.3.8.12–13) |
| `PID_COHERENT_SET` (0x0056) inline QoS | Complete | Emitted on coherent-set members; sets end on an end marker, a sample of another set or one outside any set; incomplete sets are discarded (RTPS 2.5 §8.7.6) |
| `PID_GROUP_SEQ_NUM` (0x0064) inline QoS | Complete | Emitted by Publisher on every write under ordered/coherent access; used to sort on `begin_access` |
| `PID_GROUP_COHERENT_SET` (0x0063) inline QoS | Complete | The group set's id, on every sample and End Coherent Set marker of a GROUP coherent set; the subscriber assembles group sets by it. Sent to every reader, whatever its vendor |
| `PID_WRITER_GROUP_INFO` (0x0065) inline QoS | Emitted only | On GROUP coherent-set samples and End Coherent Set markers; not checked against discovery on receive |
| Writer Liveliness Protocol (P2P endpoints) | Implemented (RELIABLE reader only) | `src/discovery/wlp.zig`; advertised via `BUILTIN_ENDPOINTS` in `src/dcps/participant.zig`. BEST_EFFORT reader path (§8.4.13.3) not implemented |

## DCPS

| Component | Status | Notes |
|---|---|---|
| `DomainParticipantFactory` | Complete | Not a singleton |
| `DomainParticipant` | Complete | |
| `Publisher` / `Subscriber` | Complete | `begin_coherent_changes`, `end_coherent_changes`, `suspend_publications`, `resume_publications` all implemented; `begin_access` / `end_access` implement ordered INSTANCE/TOPIC/GROUP sort; `suspend_publications` + `begin/end_coherent_changes` interplay is correct (suspension window re-armed atomically after each coherent flush) |
| `DataWriter` / `DataReader` | Complete | |
| `Topic` | Complete | |
| `ContentFilteredTopic` lifecycle + parser/evaluator | Complete | API, parser, evaluator, and delivery-time filtering all wired; types must register `TypeSupport.get_field` for field-level filtering. zzdds extension `set_filter_expression` changes the expression in place |
| `WaitSet` | Complete | |
| `ReadCondition` | Complete | |
| `QueryCondition` | Complete | State-mask + SQL expression evaluated at read/take time via `filter.zig`; requires `TypeSupport.get_field` for field access; without it all samples pass through |
| `StatusCondition` | Complete | |
| `GuardCondition` | Complete | |
| All 22 QoS policies represented + matched | Mostly complete | Runtime enforcement is broad, but keyed-instance behavior still has gaps; see known limitations |
| OWNERSHIP QoS enforcement | Partial | Per-instance when inline `PID_KEY_HASH` or registered `TypeSupport.compute_key_hash` is available; otherwise keyed samples collapse to the NIL instance handle |
| `on_publication_matched` / `on_subscription_matched` | Complete | `src/dcps/writer.zig:230-254`, `reader.zig:673-703` |
| `SampleLostStatus` / `on_sample_lost` | Complete | GAP-derived loss counting in `reader_sm.zig`; callback thread via `DataCallback.on_sample_lost` |
| `LivelinessChangedStatus` / `on_liveliness_changed` | Complete | Per-writer lease tracking in `DataReaderImpl`; expiry detected in `checkTimersFn` |
| `initial_peers` config wiring | Complete | `src/config/schema.zig`, `spdp.zig` |
| Instance lifecycle (ALIVE / DISPOSED / UNREGISTERED) | Complete | |
| `read()` / `take()` with all state filters | Complete | |
| `SampleInfo` core fields | Mostly complete | Sample/view/instance state, source timestamp, instance/publication handles, and `valid_data` are populated; sample/generation rank fields currently remain at defaults |
| `get_builtin_subscriber` / built-in topics | Complete | Built-in Subscriber/DataReaders exist; participant/publication/subscription/topic samples are pushed; `DCPSTopic` populated from `vtCreateTopic` and SEDP callbacks |
| `ignore_participant` | Complete | Removes from discovered list; adds to ignore list; subsequent SPDP announcements from that prefix are dropped |
| `ignore_topic` / `ignore_publication` / `ignore_subscription` | Complete | Filters future discovery callbacks; publication/subscription ignores do not retroactively remove already-matched proxies |
| `wait_for_historical_data` (TRANSIENT_LOCAL) | Complete | RELIABLE matched writers use a history floor from first HEARTBEAT; 1 ms poll with deadline; BEST_EFFORT has no guaranteed history wait |
| `get_discovered_participants` / `get_discovered_participant_data` | Complete | `participant.zig` |
| `get_discovered_topics` / `get_discovered_topic_data` | Complete | Populated from SEDP writer/reader callbacks; deduplicated by (topic_name, type_name); QoS subset from wire data |
| `contains_entity` | Complete | Checks participant, publishers, subscribers, topics, writers, readers |

## Security

| Component | Status | Notes |
|---|---|---|
| Security plugin interface | Complete | `src/security/interface.zig` |
| Noop pass-through | Complete | `src/security/noop.zig` |
| DDS Security v1.2 (Authentication, AccessControl, Cryptographic) | Not implemented | See `docs/design/security-pipeline.md` |

## XTypes

| Component | Status | Notes |
|---|---|---|
| `PID_TYPE_INFORMATION` in SEDP writer announcements | Available when `-Dxtypes=true` and `registerTypeInfo()` has data for the type | No TypeLookup service; reader announcements omit it |
| TypeLookup service | Not implemented | Remote XTypes type discovery not supported |

## Language Bindings

| Component | Status | Notes |
|---|---|---|
| C ABI (`zzdds_c.h` + `libzzdds`) | Complete | Opaque handle + free-function surface; DDS API header from `zidl -b c --generate-interfaces`; C export wrappers from `zidl -b zig --zig-generate-c-api` |
| TypeSupport C-ABI shim | Complete | `zzdds_register_type_support` in `src/c_abi/typesupport.zig`; bridges C `compute_key_hash_from_cdr` function pointer to Zig `TypeSupport` vtable |
| Build artifacts | Complete | `libzidl_cdr.a`, `zzdds.pc`, `zzdds-config.cmake` (with `find_library` for cross-platform) installed by `zig build install` |
| C++ binding (`dcps.hpp` + `dcps_impl.hpp/cpp`) | Complete | Generated by `zidl -b cpp --generate-interfaces --cpp-generate-impl`; typed DataWriter/DataReader wrappers, listener base classes, CDR, out-param QoS adaptation all done. The 11 `get_listener`/incompatible-QoS-status/WaitSet/`get_datareaders` stubs that once remained were fixed upstream in zidl; generated `dcps_impl.cpp` has zero `TODO` markers |
| Java binding | Majority complete | Generated by `zidl -b java --generate-interfaces --generate-zzdds-wrappers`; real entity JNI bridge (`dcps_jni.c`), full QoS/status struct marshaling, and listener JNI upcalls all done; `zzdds.idl`'s vendor extensions (`io.zzdds.ext`, incl. `DataWriterListenerEx`/`on_reliable_reader_ready`) are now generated and reachable from Java too, via zidl's cross-file Java type support; verified end-to-end with two separate JVM processes discovering, matching, and exchanging data over real UDP RTPS (`zzdds-java-example/`) plus an in-process smoke test gated on the RELIABLE protocol-ready handshake (`zig build -Djava-binding=true test-bindings`); a handful of DCPS operations taking a bare `sequence<T>` param directly (not inside a struct) throw `UnsupportedOperationException` |
| Python / .NET binding | Not implemented | Planned; inline CDR + C-ABI layer via ctypes / P/Invoke |
| Rust binding | Not implemented | Planned; see zidl roadmap for dual-mode (`pure` / `zig-ffi`) design |

## Wire Interop Verified

| Peer | Status | Scenarios |
|---|---|---|
| Cyclone DDS | Verified | bidirectional; 48/48 dds-rtps test suite |
| OpenDDS | Verified | pub/sub, fragmented |
| FastDDS | Verified | bidirectional; 48/48 dds-rtps test suite |
| RTI Connext | 89/89 (Connext→zzdds); 84/89 (zzdds→Connext) | 5 open interop gaps in the zzdds→Connext direction for GROUP_PRESENTATION scenarios |

## Test Coverage

`zig build test` runs the deterministic unit/integration suite, including Tier 1
unit tests, Tier 2 mock/intraprocess DCPS tests, and fuzz corpus regression tests.
See `docs/testing.md` for how to run the full suite.

---

## Known Limitations

**Generated key extraction for keyed topics.** `TypeSupport` registration is implemented
(`participant.registerTypeSupport()`). The receive path calls the registered `compute_key_hash`
when a sample arrives without an inline-QoS key hash. Applications must call
`registerTypeSupport` with their type's hash function (zidl-generated types expose this as
`MyType.computeKeyHash`); without it, keyed samples collapse to the same instance handle.

**Keyed-instance fallback for per-instance QoS/history.** `TIME_BASED_FILTER`, ownership,
SampleInfo state, and `KEEP_LAST` all operate per resolved instance handle. Key hash
resolution on the receive path follows: inline `PID_KEY_HASH` QoS (standard behavior of
real DDS peers) → registered `TypeSupport` fallback, picked by change kind (`compute_key_hash`
for a complete ALIVE sample, `compute_key_hash_key_only` for DISPOSE/UNREGISTER's genuine
key-only payload — see `resolveKeyHash` in `src/dcps/participant.zig`) → all-zeros (NIL) if
that kind's function wasn't registered. If neither wire key-hash nor TypeSupport is
available, keyed samples collapse to one fallback instance. The clean long-term answer for
that fallback is XTypes TypeLookup, which would allow key field layout to be discovered
from wire metadata without pre-registration.

**Transport scatter-gather not fully zero-copy.** The iovec list is assembled without
copying but is flattened to a `[65536]u8` stack buffer at the `Transport.send()` boundary.
The `Transport` vtable has no vectored-send method. See `docs/design/rtps-message-builder.md`.

**`encode_payload` allocates on the noop path.** The `Cryptographic.encode_payload`
interface writes into an `ArrayListUnmanaged` even in the noop case. A tagged-union return
would eliminate this allocation. Deferred until a real Cryptographic implementation is begun.

**MTU-aware fragment sizing.** `rtps.fragment_size` is static. There is no interface-MTU or
path-MTU based auto-calculation, so deployments must configure a conservative value manually
when they need to avoid IP-level fragmentation.

**GUID generation platform fallbacks.** `.random` uses OS entropy on Linux, BSD, and Apple
platforms, but unsupported OS tags fall back to a clock/counter-seeded CSPRNG. `.host_based`
uses PID/time on supported OSes and PID `0` plus a constant clock seed on unsupported OSes.
Add target-specific entropy, PID, and monotonic-clock support before claiming production
support for those targets.

**`PID_GROUP_DATA` wire value.** `pid.zig` defines `GROUP_DATA = 0x002D` per RTPS 2.5 Table 9.18.
The constant is present but not yet serialized in SEDP announcements; when GROUP_DATA serialization
is added, confirm that peers expect `0x002D` (not the historical `0x0056` used by some older
implementations).

**`dds-rtps` `CoherentSets_10/11/12/19/20/21` flakiness — mostly a zzdds subscriber bug,
fixed 2026-10-07.** A zzdds subscriber committed a writer's in-progress coherent set when
a HEARTBEAT said it had every sample written so far. Vendor writers that send each sample
as it is written send such HEARTBEATs mid-set, so sets were split across
`begin_access`/`end_access` cycles, mostly the first sets after matching (later ones were
protected once the writer's first end-of-set marker arrived). A 2026-08-28 campaign had
attributed these failures to the harness's per-cycle sample counts; its analysis checked
whole-run ordering and per-instance atomicity after start-up and missed the split first
sets. With another implementation publishing, 4 of 10 local runs failed before the fix and 0 of 20
after. The harness check also assumes all DataWriters match at once (see the roadmap,
which also lists the failure modes not yet explained). `CoherentSets_8` passes.
`OrderedAccess_8` was not re-examined; RTI added timing tolerance to
`ordered_access_w_instances` upstream in Aug 2026 (`95b6f62`).

**GROUP coherent sets to subscribers of two other implementations.** zzdds sends GROUP
sets as RTPS 2.5 §8.7.6 defines them to every reader: each sample carries
`PID_GROUP_COHERENT_SET`, and every writer ends the set with an End Coherent Set marker.
Subscribers of two other implementations deliver nothing from such sets.
- One receives and acknowledges every sample and delivers none. It ends its own group sets
  with vendor-specific parameters, not the §8.7.6 marker, and numbers them through
  `PID_ORIGINAL_WRITER_INFO`. Adding that parameter, or `PID_COHERENT_SET` (either the
  writer's set or SEQUENCENUMBER_UNKNOWN) on the marker, doesn't help; leaving
  `PID_GROUP_COHERENT_SET` off the samples is the only change seen to make it deliver.
- The other drops every End Coherent Set marker, as a DATA with no payload, unless it
  carries `PID_COHERENT_SET` naming the writer's part of the set (as §9.6.4.3 Table 9.23
  shows), so it never acknowledges the markers and never ends a group set. Sent that form,
  it delivered single-topic group sets but not three-topic ones, while another
  implementation took the same marker as a member of the open set (§9.6.4.2 Table 9.22);
  zzdds doesn't send it.

Until 2026-10-12 zzdds left `PID_GROUP_COHERENT_SET` out
for those two (by vendor id, which §8.7.6 does not allow), so they took each writer's part
as a set of its own: data arrived, but a group set could be split across two reads.

**TOPIC and INSTANCE coherent sets to one other implementation.** zzdds ends each
TOPIC- or INSTANCE-scope set with a DATA that has no payload (§9.6.4.2 Table 9.22). The
subscriber of one other implementation drops that marker, with or without
`PID_COHERENT_SET`=SEQUENCENUMBER_UNKNOWN. Its reliable reader therefore never records the
marker's sequence number, its ACKNACK base stops at the first marker for the rest of the
session, and zzdds resends every marker on each ACKNACK. Nothing from that sequence
number on is ever acknowledged. The subscriber ends a set only when the next set's first
sample arrives, and commits whatever it holds at that point. A repaired sample that
arrives after a later one in the same set is left out of its set, which happens
intermittently in the multi-topic CoherentSets tests. Leaving out the marker for that
reader isn't possible on its own, because the marker's sequence number belongs to the
writer and is shared by every reader.

**SPDP liveness probe fires directed HBs on SEDP reliable channels.** When SPDP silence
exceeds `min(3 × observed_interval, 5 s)`, the SPDP layer triggers a directed non-final
HEARTBEAT to the peer's SEDP reader proxies. If no ACKNACK arrives before the probe deadline
(~1 s), the participant is evicted and `on_participant_lost` fires. This path is tested and
works correctly, but sets `probe_active` on the `KnownParticipant` record, which prevents a
second probe from firing before the first resolves. A participant that goes silent while a
probe is in flight will be evicted on the first probe deadline — there is no probe retry.
Losing a participant drops its SEDP and WLP built-in proxies, so if it returns its endpoints
are announced and matched again.

### Experimental typesupport library management

The opt-in `-Dtypesupport-library=true` option uses pinned zidl v0.3.22 and exposes
the native Zig loader, export inspection/selection, immutable participant registration and
generation replacement/retirement. Readers retain providers through physical
teardown, and complete samples use checked provider processing before protocol
admission. Linux has native validation; macOS/Windows backends are implemented and
cross-compiled but still await native qualification. The API uses the restricted
experimental zidl wire ABI;
it does not provide TypeLookup, general assignability or live schema migration.
See [typesupport libraries](typesupport-libraries.md) for ownership, build flags,
validation coverage and the exact supported scope. A runnable two-provider
example checks separate-process UDP delivery and independent Fast DDS reception
for keyed and keyless types using explicit XCDR1 QoS. Static provider registration
can be built without OS dynamic loading. A PR-triggered and manually dispatchable native platform workflow uses
the pinned release, with C ABI, retirement and UDP checks.
