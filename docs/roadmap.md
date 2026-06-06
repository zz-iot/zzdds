# Zenzen DDS — Roadmap

Future work only. Completed work is in the git log. For current implementation status
see `docs/implementation_status.md`.

---

## Phase 33: dds-rtps Interop Validation — Complete

All four vendors were verified at 48/48 in Phase 33 CI. RTI Connext had one
intermittently failing run that was green after re-run; treated as a test-infrastructure
flake, not a wire issue.

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
entropy, PID, and monotonic-clock implementations; keep GUID-prefix vendor bytes aligned
with the OMG Vendor ID registration item above.

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

**Transport dispatch-snapshot cap** — `UdpTransport` (`PortEntry.dispatch`) and
`TcpTransport` (`dispatchToHandlers`) snapshot registered handlers into a 64-element
stack array before calling them, so dispatch can release the handler lock without
holding it across callbacks. The cap is currently enforced when registering handlers.
64 handlers per port is sufficient for any realistic deployment today (one handler per
participant sharing the transport), but the design should be revisited before the
factory pattern makes it easy to spin up large numbers of participants. Options: a
small inline-storage type that falls back to a heap buffer only when the inline array
overflows (similar to a small-vector), or a two-phase dispatch that re-acquires the
lock between calls with a generation counter to detect concurrent mutations. The goal
is to remove the hard cap without introducing a heap allocation on the common path.

**`swapRemove` / `orderedRemove` audit** — several hot paths use `orderedRemove` on
`ArrayListUnmanaged` to delete a single element from the middle of a list, which is O(N) per
call and O(N²) in loops.  The pattern is pre-existing and fine for the small lists seen
today (proxy counts, condition slots), but should be fixed before the codebase scales.  A
sweep of all `orderedRemove` call sites should replace them with `swapRemove` where order is
not semantically required, or with an indexed/hash structure where it is.  Existing tests
should catch any ordering dependency that is accidentally removed.

A specific instance worth addressing: `commitCoherentPendingLocked` in `reader.zig` uses
`coherent_committed.orderedRemove(0)` to pop the oldest committed set from the front of the
queue.  In the common late-join history-replay case where multiple coherent sets accumulate
before the first `begin_access`, each pop is O(N) in the remaining queue depth.  The fix is
to replace `ArrayListUnmanaged` with a head-index (`head: usize`) that advances instead of
shifting, or to use a ring-buffer structure.  Queue depths in practice are small (1–3 sets),
so this is a polish item rather than an urgent fix.

**Condvar-based blocking in setup paths** — `wait_for_historical_data` and any other
setup-time spin-poll (`std.time.sleep` in a retry loop) should be converted to condvar-based
blocking.  The pattern to look for: a loop that sleeps a fixed interval then re-checks a
shared flag.  Each such site should instead hold a `Mutex` + `Condvar` pair; the writer side
signals the condvar when the condition becomes true, and the waiter unblocks immediately
rather than sleeping up to one interval past the event.  `ManualClock`-driven tests in the
existing suite should be extended to cover the condvar path.

---

## Deferred / Out of Scope for v1

- **DDS-RPC** — deferred; no concrete use case yet.
- **DDS-XRCE** — embedded profile; separate project or downstream fork.
- **TRANSIENT / PERSISTENT durability** — requires a persistence service; deferred.
- **MultiTopic** — complex; deferred.
- **Retroactive unmatching for ignored publications/subscriptions** — the ignore APIs filter
  future discovery callbacks today. Ignoring an already-discovered publication or
  subscription is treated as a permitted no-op; actively removing existing RTPS proxies is
  deferred unless a use case needs stricter behavior.
- **Platform-specific InterfaceMonitors** — `monitor/netlink.zig` (Linux) and
  `monitor/pf_route.zig` (macOS) deferred; polling monitor is sufficient.
- **SHMEM transport** — deferred; UDP covers current use cases.
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
