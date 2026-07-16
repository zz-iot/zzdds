# Zenzen DDS — Design Decisions

Stable decisions with rationale. These are invariants that new code should not
inadvertently violate. For implementation status see `docs/implementation_status.md`;
for future work see `docs/roadmap.md`.

---

## Architecture

**RTPS framing is not a plugin.**
The RTPS message format (headers, submessages, sequence numbers, GUIDs) is Zenzen DDS core.
Transport carries opaque RTPS byte buffers to/from locators. If a future zero-copy SHMEM
path needs to bypass RTPS framing entirely, that will be a separate "fast channel" plugin
added later — it won't change the existing plugin boundary.

**`DomainParticipantFactory` is not a singleton.**
It is an explicitly-constructed struct holding transport(s), discovery plugin, security
plugins, and config. Multiple factories can coexist in the same process (needed for tests
and for multi-domain applications).

**Allocator strategy: always explicit, no global allocator.**
Every call site that allocates accepts `std.mem.Allocator` explicitly. Users can bring an
arena allocator for sample-heavy paths. No global allocator is registered or assumed.

---

## Transport / Discovery

**NIC/multicast interface selection.**
`UdpConfig.interfaces` accepts interface names or IP addresses; empty = all interfaces.
One unicast socket per interface address (`bind_wildcard = false`, Cyclone style).
IPv4/IPv6 auto-detected per interface; hard override build flags available.

**SPDP lease expiry: immediate removal, no grace period.**
Matches Cyclone DDS and FastDDS behavior. RTPS §8.5.3.3 leaves this implementation-defined.
A grace period creates a window where dead participants trigger spurious retransmits.

**SPDP re-announcement semantics: edge-triggered.**
Re-announcements from known participants silently refresh `expires_ms` and locator data
only. No DCPS or SEDP callbacks fire unless the participant was previously expired
(`is_new = true` after lease expiry). This prevents history replay churn from
re-announcements during normal operation.

**RTPS ParameterList durations are RTPS durations, not DDS durations.**
DDS `Duration_t` is `sec + nanosec`, but RTPS 2.5 ParameterList duration values are
`seconds + fraction`, where `fraction` is in units of `1/2^32` seconds. SPDP/SEDP
decode wire durations as `RtpsDuration`, then convert to DDS `Duration` before lease
or QoS logic. Omitted `PID_DEADLINE` means DDS default infinite; explicit `{0,0}` means
RTPS `DURATION_ZERO` and is not normalized to infinite.

**BEST_EFFORT late-join replay is a TRANSIENT_LOCAL courtesy, not reliability.**
For TRANSIENT_LOCAL writers, `StatefulWriter` replays the current writer cache to a newly
matched BEST_EFFORT reader. This covers late joiners and in-process discovery races, but it
is still BEST_EFFORT: there is no heartbeat/acknack recovery after packet loss.

---

## RTPS State Machines

**`StatefulReader` RELIABLE delivery order: hold until contiguous (Side B).**
`handleData` buffers out-of-order payloads and fires `on_data` only when the sequence
number is the next expected one, then again for each SN that becomes contiguous as gaps
fill. BEST_EFFORT keeps immediate delivery. RTPS §8.4.8 requires in-order delivery for
RELIABLE; WaitSet/QueryCondition semantics depend on it.

**DATA_FRAG fragmentation happens at send time, not write time.**
The history cache stores the complete payload. Each `DATA_FRAG` submessage is built at
send time from a slice into `CacheChange.data`. This keeps the writer cache simple and
allows retransmit of individual fragments without re-serialization.

---

## DCPS

**History cache stores bytes, not typed structs.**
Both writer and reader caches hold serialized CDR payloads (`[]const u8`). Reasons:
1. NACK retransmit wraps cache bytes in DATA — no re-serialization needed.
2. One CDR payload serves all matched readers (no-security path).
3. The loan/zero-copy read API only makes sense with stored bytes.
4. DATA_FRAG reassembly accumulates byte fragments; no typed object until complete.
5. XTypes type evolution: a reader may hold a different schema version and deserialize
   with its own schema.

**Per-change heap allocation for history cache.**
Simple, correct, easy to audit. Future upgrade path: slab/pool per topic (bounded
fragmentation) or ring-buffer of fixed-size blocks (embedded targets). Neither upgrade
requires changes to the `CacheChange` interface.

**ContentFilteredTopic and QueryCondition: reader-side evaluator, not writer push-down.**
The SQL-subset parser/evaluator is local to the reader side and uses a `FieldAccessor`
provided by typed code. `ContentFilteredTopic` filtering runs before samples enter the
reader pending queue when the type has registered `TypeSupport.get_field`; `QueryCondition`
expressions run at `read()` / `take()` time using the same accessor. Without a field
accessor, expressions pass samples through. Writer-side or transport push-down remains a
future optimization if per-sample CPU cost becomes measurable.

**`DataReader.read()` semantics: copy first, loan upgrade path preserved.**
`readRaw()` is non-destructive: marks samples `READ_SAMPLE_STATE` in-place, returns
clones. The zero-copy loan upgrade path is preserved — no API changes needed when
`loan()`/`return_loan()` are added.

**QoS incompatibility notification: listener callbacks and StatusCondition, both.**
Per DDS spec §2.2.4. `on_offered_incompatible_qos` / `on_requested_incompatible_qos`
listeners are called; the corresponding `StatusCondition` is also set.

**RELIABLE readiness (`on_reliable_reader_ready`): separate listener interface,
listener-only, no StatusCondition.**
`on_publication_matched` fires on bare SEDP discovery per spec; users actually want "I can
write now and expect delivery," which needs the AckNack/Heartbeat handshake. Rather than
changing `on_publication_matched`'s spec-implied semantics (a compliance regression), the
signal is a new, additive extended listener interface: `zzdds::DataWriterListenerEx :
DDS::DataWriterListener`, adding `on_reliable_reader_ready(reader_handle, is_ready)`, set via
a new `zzdds::DataWriter::set_listener_ex()` alongside the standard `set_listener()`. Both
setters populate the same unified storage (`DataWriterImpl.listener_ex`) so the two OMG
status callbacks and the extension callback are always dispatched from one place.

Per-proxy correlation state: `ReaderProxy.first_sent_hb_first_sn` (recorded once, at match
time, from the firstSN the initial Heartbeat to that proxy will carry) and
`protocol_ready: bool` (sticky). A RELIABLE proxy becomes ready when an incoming AckNack's
`nack_set.base` (next-expected SN) reaches that floor — deliberately `base`, not
`highest_sn` (cumulative ack): for an empty-cache writer the floor is 1 (the empty-Heartbeat
convention), which `highest_sn` can never reach since nothing was ever written, but a
caught-up reader's AckNack still legitimately reports `base=1` ("I have nothing, next
expect SN 1"), which correctly satisfies the handshake. BEST_EFFORT proxies never AckNack,
so they become ready immediately at match instead. The callback fires from
`StatefulWriter`/`handleAckNack` and `addMatchedReader` only after `mu` is released, mirroring
the existing `probe_result_fn` liveness-probe pattern.

Deliberately **not** wired into `DDS.StatusMask`/`StatusCondition`/waitset: this is a vendor
extension signal, not an OMG-defined status kind, and inventing a vendor-reserved
`StatusMask` bit was judged out of scope for this feature. Listener-only, matching the
decision's own framing ("add a new listener interface/method", not "add a new status kind").

Implementing this required a zidl generator fix: cross-module `@callback interface`
inheritance (a `zzdds.idl` callback interface inheriting a `dcps.idl` one via `import`) had
never been exercised before and silently dropped the base's methods. See the zidl repo's
`docs/roadmap.md` for the generator-side fix; it also uncovered that entity interfaces share
the same flattening code, which would have required unrelated new work in
`c_abi/extensions.zig` and hit an existing C++ backend limitation
(`error.MultipleNativeHandleBases`) — the zidl fix is deliberately scoped to only fill
cross-module content for `@callback` interfaces, leaving entity interfaces' cross-module
bases exactly as before (unexercised, matching today's shipped behavior).

**GROUP_PRESENTATION coherent sets: implement to spec.**
The zzdds implementation emits `PID_COHERENT_SET` (0x0056), `PID_GROUP_SEQ_NUM` (0x0064),
and `PID_GROUP_COHERENT_SET` (0x0063) inline QoS per RTPS 2.5 §9.6.3.7. Five test cases
currently fail in the zzdds→Connext direction (`CoherentSets_8/10/11/12`,
`OrderedAccess_8`); the Connext→zzdds direction is 89/89. The interop gap is under
investigation — vendor binaries in CI may not reflect the latest implementation. No
wire-format changes are planned until the root cause is confirmed; deviating from the
spec to chase a binary snapshot would risk breaking other vendor interop.

**SPDP liveness probe: EMA interval + 3× silence threshold, directed SEDP HBs.**
When `FinalInstanceState_2` requires detecting participant exit without a BYE (e.g.,
RTI Connext announces `lease_duration=100s` and exits silently), a poll-based lease
timeout is too slow. The probe design: SPDP tracks inter-announcement intervals via an
EMA (`observed_interval_ns`); silence ≥ `min(3 × observed_interval, 5s)` triggers a
directed non-final HEARTBEAT to the peer's SEDP reader proxies via the SEDP reliable
channel. An ACKNACK within the probe deadline (~1s) confirms liveness; no response
triggers eviction and `on_participant_lost`. Lock ordering: `spdp.mu` → `writer.mu`
(sequentially, never nested); probe callbacks are fired after releasing `writer.mu`.

---

## Logging and Tracing

**Two independent observability systems.**
1. `std.log.scoped` — diagnostic text. Compile-time scope/level filtering via
   `scope_levels`; runtime override via `logFn`. Scopes: `zzdds_rtps`, `zzdds_spdp`,
   `zzdds_sedp`, `zzdds_transport`, `zzdds_dcps`.
2. `src/trace.zig` — structured RTPS wire events. Comptime-gated by `-Dwire-trace`;
   `Tracer` is zero-size and all calls are dead-code eliminated when disabled. `Sink`
   vtable with `SyncSink`, `AsyncRingSink`, `NoopSink`. NDJSON or text output.

These are independent because diagnostic logging and wire tracing have different
audiences (developers vs. protocol analyzers) and different verbosity profiles.

---

## Configuration

**Precedence order (highest to lowest):**
Programmatic API → Environment variables (`ZZDDS_*`) → Config file (TOML) → Built-in defaults.

Config file search: `$ZZDDS_CONFIG` → `./zzdds.toml` → `~/.config/zzdds/config.toml`.

**GUID prefix strategy: `.random` default, `.host_based` optional.**
`.random`: 12 OS-entropy bytes on supported platforms, with a clock/counter fallback on
unsupported targets. `.host_based`: process start timestamp + PID + counter — useful for
Wireshark correlation and deterministic tests. Both paths embed `ZZDDS_VENDOR_ID` into
`guidPrefix[0..2]` (RTPS §9.3.1.5); see `src/util/guid_gen.zig`.

---

## Build System

**Conditional compilation via build options, not runtime flags.**
`-Dipv4`, `-Dipv6`, `-Dinterface-monitor`, `-Dwire-trace`, `-Dguid-filter`,
`-Dxtypes`, `-Dcontent-subscription-profile`. Dead-code elimination removes unused
paths at compile time — no runtime overhead, no `#ifdef`-style branching at call sites.
