# Zenzen DDS — Roadmap

Future work only. Completed work is in the git log. For current implementation status
see `docs/implementation_status.md`.

---

## Phase 33: dds-rtps Self-Interop Validation

- **`zig build self-interop` step** — invoke the dds-rtps Python harness
  (`test_suite.py`) automatically with zenzen_dds as both pub and sub process; emit
  structured results (PASS/FAIL/TIMEOUT per test case) and exit non-zero on any failure.

- **`Ownership_4` / keyed-instance interop** — `DataReaderImpl` now tracks ownership in
  an `owner_map` keyed by `InstanceHandle_t`, but generated/interop paths still need
  reliable key extraction so each keyed sample carries a non-nil `key_hash`.

  **Prerequisite:** `deserializeKey` + `computeKeyHash` in `zidl-rt` (see
  `zidl/docs/roadmap.md`). Once available, zzdds changes:
  - Compute key hashes via generated `deserializeKey` + `computeKeyHash` at write and
    receive boundaries when inline key hash is absent.
  - Use the resulting instance handle consistently for OWNERSHIP, `SampleInfo`, and
    resource-limit accounting.
  - Convert `TIME_BASED_FILTER` (`tbf_last_ns`) and `KEEP_LAST` depth tracking from global
    state to per-instance state.

- **`Cft_0`, `Cft_1`** — ContentFilteredTopic expression evaluation against external peers.
  The parser/evaluator is implemented (`src/dcps/filter.zig`), but generic `DataReader`
  filtering still needs a typed `FieldAccessor` or generated deserializer hook so
  `read()` / `take()` can apply expressions automatically instead of requiring manual
  post-take filtering.

- **zenzen vs zenzen 100%** — all 48 dds-rtps test cases pass with both sides running
  zenzen_dds; gate: no self-interop regressions permitted from this point forward.

- **zenzen vs Cyclone 100%** — full run with Cyclone as peer; confirm same 100% pass rate.

- **Vendor ID registration and cleanup** — register Zenzen DDS vendor ID with OMG before
  publishing dds-rtps results. Also reconcile current placeholders (`Header.VENDOR_ID`
  uses `0x0123`, SPDP `ZZDDS_VENDOR_ID` uses `0x9999`) and update GUID-prefix generation
  so `guidPrefix[0..2]` matches the registered vendor ID.

---

## Planned (after Phase 33)

**TypeSupport callback registration** (prerequisite for language bindings)

The application registers a type with the participant via C-ABI function pointers:
```c
typedef struct {
    const char *type_name;
    int  (*serialize)(const void *sample, uint8_t *buf, size_t *len);
    int  (*deserialize)(const uint8_t *buf, size_t len, void *sample_out);
    void (*key_hash)(const uint8_t *buf, size_t len, uint8_t hash[16]);
} ZzddsTypeSupport;
```
`participant.registerType(ZzddsTypeSupport)` stores callbacks by type name. The receive
path calls `key_hash` instead of relying on the optional inline QoS `key_hash` field.
For Zig-native types, a thin wrapper adapts the generated `computeKeyHash`. This is the
prerequisite for all non-Zig language bindings.

**`initial_peers` config wiring** — `discovery.initial_peers` is schema-defined and
documented in `docs/architecture.md` but is not connected in `src/discovery/spdp.zig`.
When wired, the SPDP writer should send unicast announcements to each listed locator at
startup, before the first multicast interval fires.

**Static and broker discovery plugins** — `src/discovery/interface.zig` and the config
schema reserve `static` and `broker` discovery kinds, but only SPDP/SEDP and direct in-process
discovery are implemented. Either implement static config loading and broker client support
or remove the advertised config surface before v1.

**NACK_FRAG / HEARTBEAT_FRAG stale-count suppression** — The RTPS spec requires that
receivers ignore NACK_FRAG and HEARTBEAT_FRAG submessages whose `count` is not strictly
greater than the last accepted `count`. Both handlers currently ignore the `count`
parameter (`src/rtps/writer_sm.zig:792`, `src/rtps/reader_sm.zig:461`). Add per-proxy
`last_nack_frag_count` / `last_hb_frag_count` tracking and drop stale submessages.

**MTU-aware fragment sizing** — `rtps.fragment_size` is a static config value today.
Add an interface-MTU/path-MTU aware default that accounts for IP, UDP, RTPS, and future
security overhead, while preserving the explicit override for deterministic tests.

**`wait_for_historical_data` for TRANSIENT_LOCAL** — `DataReader.wait_for_historical_data()`
currently returns `RETCODE_UNSUPPORTED` (`src/dcps/reader.zig:959-962`). The correct
behavior is to block until the reader has received all history from every matched
TRANSIENT_LOCAL writer, or the timeout expires. Prerequisite: reliable history delivery
must be fully flushed before the call returns.

**Built-in topic and discovered-topic completion** — `get_builtin_subscriber()` exposes
in-memory DataReaders and discovery callbacks push participant/publication/subscription
samples. Finish `DCPSTopic`, `get_discovered_topics()`, `get_discovered_topic_data()`, and
`contains_entity()` from the participant discovery state.

**FastDDS wire interop** — HelloWorldData pub/sub and fragmented scenarios. Deferred until
the dds-rtps self-interop suite confirms the RTPS/DCPS stack is clean.

**SEDP-traffic-seen heuristic** — add `sedp_seen: bool` to `KnownParticipant`. On SPDP
re-announcements from a participant whose `sedp_seen` is still false, send a targeted unicast
retransmit of our own SPDP announcement. Recovers from SEDP packet loss on initial exchange
without waiting for a full announcement period.

**LocatorSelector abstraction** — replace the flat per-locator blast in
`StatelessWriter.sendAll()` (and `StatefulWriter`) with a selector that prefers loopback
for local peers and unicast over multicast when the remote is reachable unicast. A
GUID-to-selected-locator cache amortizes selection cost.

**GUID generation platform coverage** — the current fallback paths keep unsupported targets
building, but they are not production target support. For each supported OS, provide real
entropy, PID, and monotonic-clock implementations; align GUID-prefix vendor bytes with the
registered VendorId work in Phase 33.

**`on_publication_matched` RELIABLE readiness contract** — current implementation fires
on SEDP discovery. A protocol-ready contract would fire on the first AckNack from a reader
proxy that correlates with a Heartbeat already sent to that proxy (AckNack base ≥ first
sent Heartbeat's firstSN). Per-proxy state: `first_sent_hb_first_sn: ?SequenceNumber`.
For BEST_EFFORT: fire immediately on discovery (no handshake). See `docs/decisions.md`
for the full analysis.

**Language bindings** (after TypeSupport registration):
- C binding: zidl C backend + stable ABI
- C++ binding: zidl C++ backend; value-type wrappers over C ABI
- Java binding: zidl Java backend; JNI bridge
- Python / .NET: likely community-contributed

**DDS Security v1.2** — Authentication (PKI-DH), AccessControl, Cryptographic (AES-GCM).
First step: fix `Cryptographic.encode_payload` to use a tagged-union return (see
`docs/design/security-pipeline.md`).

**DDS-XTypes v1.3** — TypeObject/TypeIdentifier/TypeMapping; required for type-safe
cross-vendor type discovery.

---

## Deferred / Out of Scope for v1

- **DDS-RPC** — deferred; no concrete use case yet.
- **DDS-XRCE** — embedded profile; separate project or downstream fork.
- **TRANSIENT / PERSISTENT durability** — requires a persistence service; deferred.
- **MultiTopic** — complex; deferred.
- **Coherent changes and publication suspension** — `Publisher.begin_coherent_changes()`,
  `end_coherent_changes()`, `suspend_publications()`, and `resume_publications()` all return
  `RETCODE_UNSUPPORTED`. Full implementation requires GROUP-scope coherent delivery tracking;
  deferred alongside GroupPresentation.
- **`ignore_topic` / `ignore_publication` / `ignore_subscription`** — current normative stubs
  return `RETCODE_OK` per spec (ignoring an already-discovered entity is permitted to be a
  no-op). Full filter-on-delivery at the receive path is deferred.
- **GroupPresentation** (PRESENTATION QoS `access_scope = GROUP`) — deferred.
- **Platform-specific InterfaceMonitors** — `monitor/netlink.zig` (Linux) and
  `monitor/pf_route.zig` (macOS) deferred; polling monitor is sufficient.
- **TCP / SHMEM transports** — deferred; UDP covers current use cases.
- **Other protocol/discovery plugins** — QUIC, MQTT, custom hardware channels, and
  mDNS/DNS-SD are extension points only; no v1 implementation is planned.
- **PKCS#11** — out of scope for v1; security plugin interface must not preclude it.

---

## Open Questions

**`on_publication_matched` RELIABLE readiness contract.** The DDS spec fires on SEDP
discovery, but users expect "I can write now." The protocol-ready approach described above
is the preferred solution. Open edges:
- Multiple concurrent readers: each `ReaderProxy` tracks readiness independently; `current_count`
  increments per-proxy as each becomes ready.
- Traffic minimization: initial Heartbeat to a new proxy should be sent promptly on proxy
  creation (not waiting for the periodic HB timer).
- No vendor detection to fast-path ZZDDS-to-ZZDDS matching — inter-version fragility
  cost outweighs the benefit.

**Key material storage.** File-based PEM certs to start when DDS Security is implemented.
HSM abstraction deferred.
