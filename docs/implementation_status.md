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
| HEARTBEAT_FRAG / NACK_FRAG | Partial | Fragment ACK/retransmit works; stale-count suppression is not implemented |
| Writer Liveliness Protocol (P2P endpoints) | Entity IDs defined; endpoint not instantiated | `src/rtps/guid.zig:82-83` |

## DCPS

| Component | Status | Notes |
|---|---|---|
| `DomainParticipantFactory` | Complete | Not a singleton |
| `DomainParticipant` | Complete | |
| `Publisher` / `Subscriber` | Partial | `begin_coherent_changes`, `end_coherent_changes`, `suspend_publications`, `resume_publications` return `RETCODE_UNSUPPORTED` |
| `DataWriter` / `DataReader` | Complete | |
| `Topic` | Complete | |
| `ContentFilteredTopic` lifecycle + parser/evaluator | Partial | API, expression storage, parser, and manual evaluator are present; automatic filtering in `DataReader.read()` / `take()` is not wired yet |
| `WaitSet` | Complete | |
| `ReadCondition` | Complete | |
| `QueryCondition` | Partial | State-mask condition + query string/parameter storage; SQL expression evaluation is deferred |
| `StatusCondition` | Complete | |
| `GuardCondition` | Complete | |
| All 22 QoS policies represented + matched | Mostly complete | Runtime enforcement is broad, but keyed-instance behavior still has gaps; see known limitations |
| OWNERSHIP QoS enforcement | Partial | Per-instance when `CacheChange.key_hash` is populated; generated key extraction/hash support is still needed |
| `on_publication_matched` / `on_subscription_matched` | Complete | `src/dcps/writer.zig:230-254`, `reader.zig:673-703` |
| Instance lifecycle (ALIVE / DISPOSED / UNREGISTERED) | Complete | |
| `read()` / `take()` with all state filters | Complete | |
| `SampleInfo` (all fields) | Complete | |
| `get_builtin_subscriber` / built-in topics | Partial | Built-in Subscriber/DataReaders exist; participant/publication/subscription samples are pushed from discovery callbacks; `DCPSTopic` is not populated |
| `ignore_topic` / `ignore_publication` / `ignore_subscription` | Normative stubs returning `OK` | |
| `wait_for_historical_data` (TRANSIENT_LOCAL) | Returns `RETCODE_UNSUPPORTED` | `reader.zig:959-962` |
| `get_discovered_topics` / `get_discovered_topic_data` / `contains_entity` | Not implemented | Topic APIs return empty/`BAD_PARAMETER`; `contains_entity` always returns `false` |

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
| FastDDS | Planned | — |
| RTI Connext | Planned (requires license) | — |

## Test Coverage

`zig build test` runs 400+ unit/integration tests, including Tier 1 unit tests,
Tier 2 mock/intraprocess DCPS tests, and fuzz corpus regression tests.
See `docs/testing.md` for how to run the full suite.

---

## Known Limitations

**Generated key extraction for keyed topics.** `DataReader` now uses an `owner_map`
keyed by `InstanceHandle_t`, so OWNERSHIP is per-instance when incoming changes carry a
real `key_hash`. The remaining gap is generated key extraction/hash generation for typed
samples and interop paths. Until `zidl-rt` provides `deserializeKey` / `computeKeyHash`,
keyed samples that arrive with the nil key hash collapse to the same instance handle.

**Per-instance timing/history accounting.** `TIME_BASED_FILTER` (`tbf_last_ns`) is still
global per reader, and RTPS `KEEP_LAST` depth is still global per history cache. Both
should become per-instance once generated key extraction is available throughout the data
path.

**Content-filter integration.** `ContentFilteredTopic` and `QueryCondition` can store and
parse expressions, and `ContentFilteredTopicImpl.matchSample()` can evaluate an expression
against a supplied `FieldAccessor`. The generic `DataReader` does not yet deserialize raw
CDR samples and apply those expressions automatically during `read()` / `take()`.

**Fragment control stale-count suppression.** `HEARTBEAT_FRAG` and `NACK_FRAG` are parsed
and acted on, but their handlers currently ignore the RTPS `count` field. Stale or duplicate
fragment-control submessages can therefore trigger redundant NACKs/retransmits until
per-proxy count tracking is added.

**Built-in topic coverage.** `get_builtin_subscriber()` returns a real built-in Subscriber
when initialization succeeds, and discovery callbacks push `DCPSParticipant`,
`DCPSPublication`, and `DCPSSubscription` samples. `DCPSTopic` is created but not populated;
`get_discovered_topics()` returns an empty sequence; `get_discovered_topic_data()` returns
`BAD_PARAMETER`; `contains_entity()` always returns `false`.

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

**Vendor ID placeholders are inconsistent.** The RTPS message header currently uses
`{0x01, 0x23}`, SPDP writes `{0x99, 0x99}`, and GUID prefix generation does not force the
prefix's first two bytes to match either placeholder. Register a real vendor ID and make
these paths agree before publishing interop results.

**`initial_peers` config not connected.** `discovery.initial_peers` is present in the
configuration schema and documented in `docs/architecture.md`, but `src/discovery/spdp.zig`
does not read it. SPDP discovery relies entirely on multicast; unicast peer targeting at
startup is not yet implemented.

**`PID_COHERENT_SET` / `PID_GROUP_DATA` conflict.** `pid.zig` notes that `0x0056` is
assigned to both `COHERENT_SET` and `GROUP_DATA` in some spec versions. The current
implementation uses `0x0056` for `GROUP_DATA`. Verify against RTPS 2.5 §Table 9.14.
