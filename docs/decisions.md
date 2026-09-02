# Zenzen DDS — Design Decisions

Stable decisions with rationale. These are invariants that new code should not
inadvertently violate. For implementation status see `docs/implementation_status.md`;
for future work see `docs/roadmap.md`; for the change history see `CHANGELOG.md`.

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
`loan()`/`return_loan()` are added. **Confirmed true**: the raw/loan API redesign
(2026-08-22, `docs/design/raw-loan-api.md`) added real loan-mode read (`take_raw`/
`read_raw` with `cdr_payloads._maximum == 0`, `return_loan_raw`) and a new write-loan
(`loan_raw`/`publish_loan_raw`/`return_loan_raw`) as a genuinely separate pin/refcount
mechanism (`reader.zig`'s `pinSamplesForLoan`/`takeSamplesForLoan`, `EntityQuiesce`-modeled)
sitting alongside `readRaw`/`takeFiltered`'s existing copy semantics, exactly as predicted
— `readRaw`'s own copy-returning behavior was untouched.

**Loans are raw *bytes*, not zero serialization (2026-08-27).** `take_raw`/`read_raw`/
`loan_raw` let the application serialize directly into, or read directly out of, an internal
CDR buffer — that saves the marshaling-boundary copy, and the bytes are still CDR. A loan
that hands back a pointer to an unserialized, fixed-layout native struct (as ROS2 RMW's
POD-only loan contract wants) is **out of scope**: it is fundamentally at odds with IDL as a
platform-agnostic data representation, and with the QoS, security, and RTPS wire assumptions
the rest of the stack relies on. Applications needing that class of performance should use a
mechanism that doesn't carry representation-independence, QoS, or security. Using SHMEM for
History Cache *storage* (still CDR) and a SHMEM transport alongside UDP/TCP remain possible
future work; neither implies zero serialization. See `docs/design/raw-loan-api.md`.

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
never been exercised before and silently dropped the base's methods. See `zidl/CHANGELOG.md`
and `zidl/docs/decisions.md` for the generator-side fix; it also uncovered that entity interfaces share
the same flattening code, which would have required unrelated new work in
`c_abi/extensions.zig` and hit an existing C++ backend limitation
(`error.MultipleNativeHandleBases`) — the zidl fix is deliberately scoped to only fill
cross-module content for `@callback` interfaces, leaving entity interfaces' cross-module
bases exactly as before (unexercised, matching today's shipped behavior).

**GROUP_PRESENTATION coherent sets: implement to spec.**
The zzdds implementation emits `PID_COHERENT_SET` (0x0056), `PID_GROUP_SEQ_NUM` (0x0064),
and `PID_GROUP_COHERENT_SET` (0x0063) inline QoS per RTPS 2.5 §9.6.3.7. The recurring
`dds-rtps` `CoherentSets_10/11/12/19/20/21` CI failures were investigated end to end
(2026-08-28, ~2,500 live runs + ~2,300 trace replays across CoreDX/Connext/self, both
directions, ReleaseSafe/TSan/DebugAllocator): **no zzdds defect.** Every failure is the
harness's `coherent_sets_w_instances` asserting a per-poll-cycle sample count (exactly 36),
which depends on the phase alignment of two unsynchronised sleep loops rather than the
coherent_access contract. The shipped `zzdds-0.2.0` binary flakes identically. Fixed by a
`coherent_sets_w_instances` rewrite (asserts per-instance ordering, no loss/dup, and
atomic per-instance coherent-set delivery over the whole run) PR'd to `omg-dds/dds-rtps` —
same spirit as their `95b6f62` "Added tolerance to the ordered_access test". No zzdds
wire-format change was needed. `CoherentSets_8` passes.

**Listener hierarchy fallback (DDS 1.4 §2.2.4.1.5): reader/writer own listener first,
then Subscriber/Publisher, then DomainParticipant — every level's `listener_mask`
respected, not just field-nullability.** Closes a real conformance gap: previously each
entity's listener was fully independent, so a `DataReader`/`DataWriter` with no listener
installed never had its `Subscriber`/`Publisher`'s or `DomainParticipant`'s listener
consulted even if one was installed for the same status. A new `src/util/listener_fallback.zig`
(`tryDispatch`/`peek`, comptime over the callback field name) is shared by
`DataReaderImpl.dispatchListener` → `SubscriberImpl.dispatchReaderFallback` →
`DomainParticipantImpl.dispatchFallback`, and symmetrically
`DataWriterImpl.dispatchListener` → `PublisherImpl.dispatchWriterFallback` →
`DomainParticipantImpl.dispatchFallback` (one shared terminal function — participant has
one box/mask for every status kind, widened over `Topic`/`Publisher`/`SubscriberListener`).
Mask semantics: a level is skipped unless *both* its own `listener_mask` includes the bit
*and* the relevant callback field is non-null — mirrors the gating every dispatch site
already applied to the origin entity, just applied uniformly at every level in the chain,
rather than treating the parent levels as field-nullability-only.

`WaitSet`-style factory-less entities aside, the parent-lifetime safety assumption ("the
Subscriber/Publisher/DomainParticipant a reader/writer downcasts to is still alive") holds
not because zzdds enforces DDS's `PRECONDITION_NOT_MET`-on-live-children precondition (it
doesn't — `delete_subscriber`/`delete_publisher`/`delete_participant` silently cascade,
tearing down every contained child synchronously) but because that cascade never frees the
parent's own storage until every child's `deinit()` (which itself blocks on the child's own
`EntityQuiesce` until any in-flight dispatch, including a fallback walk touching the parent,
completes) has returned — confirmed by reading `participant.zig`/`subscriber.zig`/
`publisher.zig`'s `deinit()` directly, not assumed from spec text.

Two real bugs found only via a real crash/test-failure, not by inspection: (1) test
fixtures and other standalone-constructed entities set `.subscriber`/`.publisher`/
`.participant` to `nil.nil_subscriber`/etc. (a real, first-class sentinel — see
`nil.zig`'s `isNil`) rather than a live parent; the fallback downcast crashed on it until
guarded with `nil.isNil(...)` checks at every hop. (2) The six/four status-with-counters
dispatch sites (`on_sample_rejected`, `on_requested_incompatible_qos`,
`on_subscription_matched`, `on_sample_lost`, `on_liveliness_changed`,
`on_requested_deadline_missed` in `reader.zig`; `on_publication_matched`,
`on_offered_incompatible_qos`, `on_offered_deadline_missed`, `on_liveliness_lost` in
`writer.zig`) still had their pre-fallback `if (self.listener_mask & bit != 0)`/`if (fire)`
gate wrapping the whole block — including the new fallback call — so the fallback chain
was unreachable whenever the origin entity's own mask was clear, defeating the fix for
every status except the simpler `on_data_available` sites. Fixed by making the whole
dispatch chain (`tryDispatch`/`dispatchListener`/`dispatchReaderFallback`/
`dispatchWriterFallback`/`dispatchFallback`) return `bool` ("did anything in the chain
actually receive it"), always attempting dispatch, and gating each site's
change-counter reset (`_total_change`/`status_changes`) on that return value instead of
the origin's own mask — also fixing a latent staleness bug the old gate masked: those
sites hardcoded `total_count_change = 1`/`delta` instead of the accumulated
`self.*_total_change` field, which only ever matched by coincidence because the old gate
guaranteed the field was always freshly reset before the next event.

New regression coverage: `test/dcps/listener_fallback_test.zig` (reader→Subscriber,
reader+Subscriber→DomainParticipant, reader's-own-listener-wins, writer→Publisher), using
real two-participant `IntraProcessDelivery` trees (not stub vtables) so parent
back-pointers are genuine. Confirmed to actually catch the bug by deliberately reverting
`DataReaderImpl.dispatchListener` to its pre-fix (no-fallback) form once and observing two
of the four tests fail with the expected `.none` result, before restoring. Full
`zig build test`/`test-tsan`/`test-bindings -Dc-binding=true -Dcpp-binding=true
-Djava-binding=true` green throughout.

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

**No env vars; no merge precedence — `create_participant`/factory calls always use exactly
the config object they're handed.** `resolveParticipantConfig()`/`resolveParticipantConfigFrom(alloc,
path)` and `resolveProcessConfig(alloc)`/`resolveProcessConfigFrom(alloc, path)`
(`src/config/resolve.zig`) each just return a concrete struct — defaults, or defaults with a
named TOML file applied over them. There is no further merging once you have that struct:
customizing it from there is plain field mutation, not a separate "programmatic overrides"
layer. Two things ruled this out on purpose:
- **No programmatic-overrides input type.** The only case where a separate overrides-as-input
  earns its keep over direct field mutation is "re-resolve repeatedly with sticky pins" (e.g.
  config-file hot-reload) — not planned, so it would be pure complexity with no payoff.
- **No environment variables at all.** Env vars are one value per process; `DomainParticipantConfig`
  is inherently per-participant/per-factory, and this codebase explicitly supports many of each
  per process — a flat env var has no way to say which one it's talking about. An app that wants
  env-driven tweaks reads them itself and mutates the resolved struct, same as any other override.

`resolveParticipantConfigFrom`/`resolveProcessConfigFrom` propagate every failure (missing file,
malformed TOML, a value that doesn't fit its field) — nothing is silently swallowed for an
explicitly-named path. The zero-arg `resolveProcessConfig` is the one exception: it tries
`./zzdds.toml`, and only `FileNotFound`/`AccessDenied` fall back to defaults; a file that
*exists* but fails to parse is still a real, propagated error, since that's far more likely a
real mistake than an intentional absence.

Process-wide config (`src/config/process.zig`) is a deliberate, singular exception to this
codebase's "not a singleton" stance (`factory.zig`'s own doc comment) — a process genuinely has
exactly one ambient environment/filesystem, unlike a `DomainParticipantConfig`. `zzdds_create_factory()`
lazily resolves and installs it at most once per process if the app never called
`zzdds_process_configure()` itself, then seeds the new factory's default participant config from it.

TOML itself has no null literal, by design (it's a config format, not a general data-interchange
one — that's also why there's no OMG-style "IDL-to-TOML" spec the way there is for XML/JSON).
A field you want left at its default is simply omitted from the file; there is no `= null`
override syntax.

The TOML (de)serialization code itself isn't hand-written: `zidl`'s `--zig-generate-toml-config`
backend flag generates `applyToml(alloc, table: anytype) !void` per IDL struct directly from
`idl/zzdds.idl`, so config coverage can never lag the schema the way a hand-maintained parser
could. `table` is duck-typed (`anytype`) — `zidl` has no compile-time dependency on any concrete
TOML parser; `zzdds`'s own `src/config/toml.zig` (a generic value-tree tokenizer, replacing the
old schema-specific `file.zig`) is what actually implements the expected accessor contract
(`getString`/`getBool`/`getInt`/`getFloat`/`getTable`/`getStringArray`).

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

---

## Versioning / Releases

**Pre-1.0: no source- or ABI-compatibility guarantee across releases.**
Any release may change the Zig API, the C ABI (`zzdds_c.h` + the zidl-generated C/C++
surface), the QoS/config schema, or the prebuilt-bundle layout — without a deprecation
cycle. The C ABI in particular is expected to stay in flux until both zzdds and Zig itself
mature toward a 1.0, which is a long way off. `--runtime-version <N>` (see
`language-bindings.md`) is deliberately unimplemented until there is a stable tier to pin;
there isn't one yet, and declaring one is not a near-term goal.

**Consumers pin an exact release.** A tag is `vX.Y.Z-zig.A.B.C` (package version + the
exact Zig toolchain it was built with — enforced in `release.yml`). Pin the exact tag for
`zig fetch`, or the exact per-platform bundle tarball for C/C++ / CMake consumers. Do not
track a branch or a version range.

**Downstream middleware owns its own compatibility mapping.** A consumer that re-exports
zzdds through its own stable-ish surface (e.g. an `rmw_zzdds`) is responsible for pinning a
specific zzdds release, carrying its own version/build metadata, and absorbing zzdds ABI
churn behind its own boundary — not for expecting zzdds to hold an interface for it.
