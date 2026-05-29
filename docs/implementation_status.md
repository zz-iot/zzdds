# Zenzen DDS — Implementation Status

Source-backed reference for what is and isn't implemented. See `docs/roadmap.md` for
planned work. See `docs/decisions.md` for stable design decisions with rationale.

---

## Transport Layer

| Component | Status | Source |
|---|---|---|
| `UdpTransport` (IPv4 + IPv6) | Complete | `src/transport/udp.zig` |
| `MockTransport` (queued delivery, test harness) | Complete | `src/transport/mock.zig` |
| `MemoryTransport` (synchronous in-process) | Complete | `src/transport/memory.zig` |
| `LossyTransport` (wraps any transport, fault injection) | Complete | `src/transport/lossy.zig` |
| `InterfaceMonitor` (polling) | Complete | `src/transport/monitor/polling.zig` |
| TCP transport | Not planned for v1 | — |
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
| Writer Liveliness Protocol (P2P endpoints) | Entity IDs defined; endpoint not instantiated | `src/rtps/guid.zig:82-83` |

## DCPS

| Component | Status | Notes |
|---|---|---|
| `DomainParticipantFactory` | Complete | Not a singleton |
| `DomainParticipant` | Complete | |
| `Publisher` / `Subscriber` | Partial | `begin_coherent_changes`, `end_coherent_changes`, `suspend_publications`, `resume_publications` return `RETCODE_UNSUPPORTED` |
| `DataWriter` / `DataReader` | Complete | |
| `Topic` | Complete | |
| `ContentFilteredTopic` lifecycle + parser/evaluator | Complete | API, parser, evaluator, and delivery-time filtering all wired; types must register `TypeSupport.get_field` for field-level filtering |
| `WaitSet` | Complete | |
| `ReadCondition` | Complete | |
| `QueryCondition` | Complete | State-mask + SQL expression evaluated at read/take time via `filter.zig`; requires `TypeSupport.get_field` for field access; without it all samples pass through |
| `StatusCondition` | Complete | |
| `GuardCondition` | Complete | |
| All 22 QoS policies represented + matched | Mostly complete | Runtime enforcement is broad, but keyed-instance behavior still has gaps; see known limitations |
| OWNERSHIP QoS enforcement | Partial | Per-instance when `CacheChange.key_hash` is populated; generated key extraction/hash support is still needed |
| `on_publication_matched` / `on_subscription_matched` | Complete | `src/dcps/writer.zig:230-254`, `reader.zig:673-703` |
| `SampleLostStatus` / `on_sample_lost` | Complete | GAP-derived loss counting in `reader_sm.zig`; callback thread via `DataCallback.on_sample_lost` |
| `LivelinessChangedStatus` / `on_liveliness_changed` | Complete | Per-writer lease tracking in `DataReaderImpl`; expiry detected in `checkTimersFn` |
| `initial_peers` config wiring | Complete | `src/config/schema.zig`, `spdp.zig` |
| Instance lifecycle (ALIVE / DISPOSED / UNREGISTERED) | Complete | |
| `read()` / `take()` with all state filters | Complete | |
| `SampleInfo` (all fields) | Complete | |
| `get_builtin_subscriber` / built-in topics | Complete | Built-in Subscriber/DataReaders exist; participant/publication/subscription/topic samples are pushed; `DCPSTopic` populated from `vtCreateTopic` and SEDP callbacks |
| `ignore_participant` | Complete | Removes from discovered list; adds to ignore list; subsequent SPDP announcements from that prefix are dropped |
| `ignore_topic` / `ignore_publication` / `ignore_subscription` | Complete | Topic name stored and checked in discovery callbacks; publication/subscription handles stored and checked via `guidToHandle`; `ignore_topic` returns `BAD_PARAMETER` for unknown handles |
| `wait_for_historical_data` (TRANSIENT_LOCAL) | Complete | Per-matched-writer history floor from first HEARTBEAT; 1 ms poll with deadline |
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

## Wire Interop Verified

| Peer | Status | Scenarios |
|---|---|---|
| Cyclone DDS | Verified | pub/sub, fragmented (DATA_FRAG), all RELIABLE/BEST_EFFORT combos |
| OpenDDS | Verified | pub/sub, fragmented |
| FastDDS | Verified | bidirectional; all 48 dds-rtps test cases pass in both directions |
| RTI Connext | Planned (requires license) | — |

## Test Coverage

`zig build test` runs 400+ unit/integration tests, including Tier 1 unit tests,
Tier 2 mock/intraprocess DCPS tests, and fuzz corpus regression tests.
See `docs/testing.md` for how to run the full suite.

---

## Known Limitations

**Generated key extraction for keyed topics.** `TypeSupport` registration is implemented
(`participant.registerTypeSupport()`). The receive path calls the registered `compute_key_hash`
when a sample arrives without an inline-QoS key hash. Applications must call
`registerTypeSupport` with their type's hash function (zidl-generated types expose this as
`MyType.computeKeyHash`); without it, keyed samples collapse to the same instance handle.

**Per-instance timing/history accounting.** `TIME_BASED_FILTER` and RTPS `KEEP_LAST` are
both enforced per-instance at the DCPS layer. Key hash resolution on the receive path
follows: inline `PID_KEY_HASH` QoS (standard behavior of all real DDS implementations) →
registered `TypeSupport.compute_key_hash` → all-zeros (NIL). In practice the NIL fallback
is not reached: remote peers send inline `PID_KEY_HASH`, and Zig users with generated types
register TypeSupport. The clean long-term answer for the fallback is XTypes TypeLookup,
which would allow key field layout to be discovered from wire metadata without
pre-registration.

**Transport scatter-gather not fully zero-copy.** The iovec list is assembled without
copying but is flattened to a `[65536]u8` stack buffer at the `Transport.send()` boundary.
The `Transport` vtable has no vectored-send method. See `docs/design/rtps-message-builder.md`.

**`encode_payload` allocates on the noop path.** The `Cryptographic.encode_payload`
interface writes into an `ArrayListUnmanaged` even in the noop case. A tagged-union return
would eliminate this allocation. Deferred until a real Cryptographic implementation is begun.

**Config TOML coverage.** Not all `schema.zig` fields have environment variable (`ZZDDS_*`)
mappings. `resolve.zig` covers the most commonly used fields; a full audit is deferred.

**MTU-aware fragment sizing.** `rtps.fragment_size` is static. There is no interface-MTU or
path-MTU based auto-calculation, so deployments must configure a conservative value manually
when they need to avoid IP-level fragmentation.

**GUID generation platform fallbacks.** `.random` uses OS entropy on Linux, BSD, and Apple
platforms, but unsupported OS tags fall back to a clock/counter-seeded CSPRNG. `.host_based`
uses PID/time on supported OSes and PID `0` plus a constant clock seed on unsupported OSes.
Add target-specific entropy, PID, and monotonic-clock support before claiming production
support for those targets.

**Vendor ID placeholder pending OMG registration.** Both `pid.zig` and `src/rtps/message/header.zig`
use `{0x01, 0x23}` consistently, and `src/util/guid_gen.zig` already embeds those bytes into
`guidPrefix[0..2]` (RTPS §9.3.1.5). The sole remaining step is registering with OMG and updating
the two-byte constant.

**`PID_GROUP_DATA` wire value.** `pid.zig` defines `GROUP_DATA = 0x002D` per RTPS 2.5 Table 9.18.
The constant is present but not yet serialized in SEDP announcements; when GROUP_DATA serialization
is added, confirm that peers expect `0x002D` (not the historical `0x0056` used by some older
implementations).
