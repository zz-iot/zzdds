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

**BEST_EFFORT replay-on-new-proxy: not implemented.**
Interop tests use RELIABLE — the correct tool for guaranteed delivery. If BEST_EFFORT
replay is ever added, it should be an explicit policy choice, not a default behavior.

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

**ContentFilteredTopic: reader-side evaluator, not writer push-down.**
The SQL-subset parser/evaluator is local to the reader side and uses a `FieldAccessor`
provided by typed code. The generic `DataReader` does not yet call it automatically from
`read()` / `take()` because raw CDR payloads need generated field access. Writer-side or
transport push-down remains a future optimization if per-sample CPU cost becomes measurable.

**`DataReader.read()` semantics: copy first, loan upgrade path preserved.**
`readRaw()` is non-destructive: marks samples `READ_SAMPLE_STATE` in-place, returns
clones. The zero-copy loan upgrade path is preserved — no API changes needed when
`loan()`/`return_loan()` are added.

**QoS incompatibility notification: listener callbacks and StatusCondition, both.**
Per DDS spec §2.2.4. `on_offered_incompatible_qos` / `on_requested_incompatible_qos`
listeners are called; the corresponding `StatusCondition` is also set.

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
