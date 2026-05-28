# Zenzen DDS — Roadmap

Future work only. Completed work is in the git log. For current implementation status
see `docs/implementation_status.md`.

---

## Phase 33: dds-rtps Interop Validation — Complete

All four vendors verified at 48/48 on the merge CI run. RTI Connext had one
intermittently failing test that passed on the PR CI run before merge and was green again
after a re-run on main; treated as a test-infrastructure flake, not a wire issue.

*Completed in Phase 33:* self-interop CI job (48/48, gates release), zenzen vs zenzen
100%, FastDDS bidirectional 48/48, OpenDDS bidirectional 48/48, RTI Connext 48/48,
Cyclone DDS 48/48 on all non-CFT cases (`Cft_0` / `Cft_1` are
`SUB_UNSUPPORTED_FEATURE` in Cyclone's own shape_main — test-infra gap, not a zzdds
wire issue).

---

## Planned (after Phase 33)

**OMG Vendor ID registration** — both `pid.zig:ZZDDS_VENDOR_ID` and
`src/rtps/message/header.zig:VENDOR_ID` use the placeholder `{0x01, 0x23}`, and
`src/util/guid_gen.zig` already embeds `guidPrefix[0..2]` from that constant (compliant
with RTPS §9.3.1.5). The only remaining step is to register with OMG and update the
two-byte constant once a real ID is assigned. No structural changes needed.

**C-ABI TypeSupport** (prerequisite for non-Zig language bindings)

Zig-native TypeSupport (`participant.registerTypeSupport()` with `compute_key_hash` and
optional `get_field`) is fully implemented. What's still missing for non-Zig language
bindings is a stable C-ABI shim that maps C function pointers to the Zig TypeSupport
vtable, analogous to the pattern used for transport and security plugins.  This is
prerequisite for the C binding and everything downstream of it.

**Static and broker discovery plugins** — `src/discovery/interface.zig` and the config
schema reserve `static` and `broker` discovery kinds, but only SPDP/SEDP and direct in-process
discovery are implemented. Either implement static config loading and broker client support
or remove the advertised config surface before v1.


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

**SEDP-traffic-seen heuristic** — add `sedp_seen: bool` to `KnownParticipant`. On SPDP
re-announcements from a participant whose `sedp_seen` is still false, send a targeted unicast
retransmit of our own SPDP announcement. Recovers from SEDP packet loss on initial exchange
without waiting for a full announcement period.

**LocatorSelector abstraction** — replace the flat per-locator blast in
`StatelessWriter.sendAll()` (and `StatefulWriter`) with a selector that prefers loopback
for local peers and unicast over multicast when the remote is reachable unicast. A
GUID-to-selected-locator cache amortizes selection cost. When building the selector,
filter out locator kinds the active transport does not support rather than attempting
sends and swallowing the error; this eliminates the pty-buffer pressure that caused
Durability_17 failures against Connext. Pair with a one-time debug log (per unsupported
kind encountered) so that the locator kinds a vendor is advertising remain observable
when debugging interop issues without flooding production output.

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
