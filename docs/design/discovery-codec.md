# Generated discovery codec — IDL-defined RTPS ParameterList types, typed QoS end to end

Status: IMPLEMENTED for SEDP, revision 0.3, 2026-09-10 (spec written 2026-09-09). MUST /
SHOULD / MAY express requirements of the change, not additional OMG requirements.

Implementation notes (2026-09-10):
- SEDP encode/decode go through the generated codec (`idl/rtps_discovery.idl` →
  `--zig-pl-cdr`); `discovery/qos_adapter.zig` is the typed-QoS ⇄ wire-struct adapter.
  `disc.QosSnapshot`, `writerQosSnapshot`/`readerQosSnapshot`, `src/qos/policy.zig`, and
  `qos_match.checkWriterReader`/`checkPresentation` are deleted; matching is
  `qos_match.checkDiscovered` over the RTPS structs.
- SPDP encode/decode remain hand-rolled (no QoS; broker-retention swap deferred).
- `PID_TYPE_INFORMATION` (an opaque blob, no CDR length prefix) is the one parameter with
  no declared member — the SEDP writer wrapper injects it via `unknown_params`.
- Two zidl Zig-backend `@optional` codegen bugs surfaced when the codec was first *called*
  (it was previously built-but-unused): `@optional octet[N]` (array dimension lost) and
  `@optional sequence<>` (decode type mismatch + non-unwrapping `deinit`/`clone`). Fixed in
  zidl v0.3.14; `rtps_discovery.idl` uses the plain `@optional` forms.
- Two spec-legal wire deltas from the pre-codec hand encoders, documented in
  `test/discovery/wire_golden_test.zig` and `docs/decisions.md`; the live interop suite is
  the gate.

Rev 0.3 folds in the PR-A design spike (§S). Net: the IDL keeps bespoke RTPS ParameterList
structs (no embedding of `DDS::*QosPolicy`), and PR A loses two work items that turned out
to be already handled by `zidl_rt`.

## S. PR-A design spike findings (2026-09-09) — newest delta, read with §0

Five questions were open before committing to path (a). All resolved against the zidl
source (`35d7735`) and RTPS 2.5 (`OMG_specs/formal-22-04-01.pdf`). §0 below covers the
earlier rev-0.1 → rev-0.2 pivot.

**S1 — RTPS vs DDS `Duration_t` in embedded QoS policies → do NOT embed.**
`idl/dcps.idl` carries zero extensibility annotations, so every `DDS::*QosPolicy` is
`@final`, and its `Duration_t` is DDS `{ long sec; unsigned long nanosec; }`. If
`PublicationBuiltinTopicData` embedded `DDS::DeadlineQosPolicy`, the generated
`serializePlCdr` would recurse into `DeadlineQosPolicy.serialize` and put `{sec, nanosec}`
on the wire — but RTPS ParameterList durations, and zzdds's documented contract
(`docs/decisions.md` → *Transport / Discovery*: "SPDP/SEDP decode wire durations as
`RtpsDuration`"), are `{ long seconds; unsigned long fraction }` (fraction = 1/2³²s). Same
8 bytes, different second word.
*Decision:* the discovery IDL types stay **bespoke RTPS ParameterList structs** — their
own members, RTPS `Duration_t`, `@id(PID)`, `@pl_repeated` — not `PublicationBuiltinTopicData`
re-expressed as an embed of DDS QoS structs. They may *reference DDS enums*
(`DDS::ReliabilityQosPolicyKind` instead of a bare `unsigned long`) for readability, which
is the only remaining reason to compile them into the same module as `dcps.idl`, and that
is optional. This pulls type *modelling* back toward rev 0.1's shape while keeping every
rev 0.2 win: the codec is generated, unknowns are retained losslessly, `QosSnapshot` and
`src/qos/policy.zig` are deleted, and matching runs on a typed representation.

**S2 — `@pl_retain_unknown` is a cheap, precedented backend addition.**
`ir.TypeAnnotations` (`src/ir/types.zig:62`) already carries struct-level flags —
`extensibility`, `is_topic`, `is_nested` — and `@nested` already gates codegen exactly the
way we need (`is_nested` → "suppress DataWriter/DataReader generation"). Adding
`pl_retain_unknown: bool` is one field there plus one branch in
`interpretTypeAnnotations` (`src/ir/builder.zig:1105`). The backend change is localized to
the `else =>` arm of the generated `deserializeFromPlCdr` (`src/backend/zig.zig:~4085`) and
a replay loop before `writePlSentinel` in `serializePlCdr`.
*Decision:* generate an `unknown_params: []RawParam` field (`RawParam{ pid: u16, bytes:
[]u8 }`, a new `zidl_rt` type) plus `deinit`/`clone` coverage. **No generated `raw_encoded`
field** — whole-record byte retention is caller-side and free: the SEDP/SPDP decode input
slice (`ch.data`) *is* the record, encap header included, so the callback's borrowed
`raw_parameter_list` points straight at it and only a retaining consumer (the broker)
copies.

**S3 — must-understand bit is `0x4000`; `0x8000` is vendor. Confirmed against the spec.**
RTPS 2.5 §9.6.4, Table 9.6 (ParameterId subspaces), verbatim:
`ParameterId & 0x8000` → "Vendor-specific ParameterId";
`ParameterId & 0x4000` → "If the ParameterId is not recognized, treat it as an error …
ignore the Submessage".
So `must_understand = (pid & 0x4000) != 0`, `vendor_specific = (pid & 0x8000) != 0`. The
`packages/zidl-rt/src/cdr.zig:1122` doc comment ("bit 15=must_understand, bit 14=vendor")
is **backwards** — fix it in PR A. The generated `_p.pid & 0x3FFF` PID-extraction mask is
correct (strips both flag bits). Note the spec also sanctions "treat as an incompatible
QoS" for an unrecognized must-understand PID in *endpoint* data — so strict-mode
`error.UnknownMustUnderstand` is right for SPDP and structural failures, and a SEDP-endpoint
caller may instead map it to a no-match; the codec returns the error, the adapter decides.

**S4 — encapsulation header + big-endian are already handled by `zidl_rt`; drop the BE
work item.** `CdrReader.init(data)` (`packages/zidl-rt/src/cdr.zig:790`) parses the 4-byte
encap header itself: it accepts `PL_CDR_LE` (`0x0003`) **and `PL_CDR_BE` (`0x0002`)**, sets
`byte_order`, and positions `pos = 4`. `readPlParam` reads via the endian-aware `readU16`,
so big-endian ParameterLists already decode correctly. The caller wrapper is just
`var r = try CdrReader.init(payload); try T.deserializeFromPlCdr(&out, &r, alloc, mode);`.
`PlCdrWriter` stays LE-only — zzdds only ever emits LE, matching today. **PR A no longer
needs a "big-endian PL_CDR reader" step.**

**S5 — `@mutable` struct embedding a `@final` struct / enum already serializes it as the
PID value.** `emitWriteForTypeRef` (`src/backend/zig.zig:5623`) emits `try
T.serialize(writer, x)` for a named-struct member and `try writer.writeU32(@intFromEnum(x))`
for an enum, inside the `reservePlParam`/`patchPlParam` bracket. The current (unused)
`rtps_discovery.zig` already does this for `@final Duration_t` / `ProtocolVersion_t`. So
referencing DDS enums from the discovery structs (S1) needs **no backend change**; the
question was only ever about embedding whole *policy structs*, which S1 rules out anyway.

Scope effect: PR A drops the BE-reader item and the encap-handling worry; PR B's IDL step
becomes "expand `rtps_discovery.idl` with bespoke RTPS structs" rather than "merge builtin
topic data into `dcps.idl`", which removes all `dcps.idl` churn and its risk.

## 0. What changed from revision 0.1

Rev 0.1 proposed a hand-written `src/discovery/codec/` module that wrapped the existing
`QosSnapshot` projection and added raw-byte retention *alongside* it, explicitly deferring
typed QoS.

That was the minimum-viable slice. It leaves three lossy / orphaned representations in the
tree (`QosSnapshot`, `src/qos/policy.zig`, the built-but-unused `zzdds_disc_generated`
module) and a hand-rolled parser that the project would keep tripping over. zzdds is still
in build-functionality mode; a larger PR that lands real, finished structure is worth more
than a fast incremental one that leaves broken pieces behind.

**Revised direction (path a):**

1. **Revive `idl/rtps_discovery.idl`** and generate the SPDP/SEDP PL_CDR codec with zidl's
   `--zig-pl-cdr` backend instead of hand-rolling it.
2. **Extend zidl's PL_CDR backend** with the three things it is missing for RTPS wire use:
   lossless unknown-parameter retention, must-understand enforcement, and strict structural
   validation.
3. **Delete `QosSnapshot`** and its `writerQosSnapshot` / `readerQosSnapshot` /
   `checkSnapshots` machinery. Discovery and QoS matching consume the generated
   `DDS.*Qos` types directly.
4. **Retire `src/qos/policy.zig`** and `qos_match.checkWriterReader` (both orphans);
   `checkSnapshots` becomes `checkDiscovered` over the generated RTPS structs.
5. Retire the hand-rolled `spdp.zig` / `sedp.zig` PL_CDR parsers.

This spans two repos (zidl then zzdds) as two sequential PRs — §7.

## 1. Current state: four QoS/codec representations, two of them dead weight

| # | Representation | Where | Status |
| --- | --- | --- | --- |
| A | `DDS.DataWriterQos` / `DDS.DataReaderQos` / all 22 `DDS.*QosPolicy` | `zzdds_generated` module — zidl Zig backend from `idl/dcps.idl` | **Live.** The API type *and* the DCPS storage type (`dcps/writer.zig:73` `qos: DDS.DataWriterQos`). C/C++/Java bindings marshal their idiomatic structs to/from the C-backend view of this same layout; Zig core + C ABI share the `extern struct` with no conversion. |
| B | `disc.QosSnapshot` | `discovery/interface.zig:34`, hand-rolled | **Live, lossy, to delete.** Flat `i32`/`u32`/`bool` projection of ~11 policies with INFINITE sentinels. Built by `participant.zig:writerQosSnapshot` / `readerQosSnapshot` (`:1718` / `:1756`). Consumed by SEDP wire encode/decode and `qos_match.checkSnapshots` (`:137`). Carries a "will be replaced by typed QoS" comment. |
| C | `qos.DataWriterQos` + `qos.*` (22 policies) | `src/qos/policy.zig`, hand-rolled 2026-05-18 | **Orphan, to delete.** Idiomatic snake_case Zig QoS + a typed matcher `qos_match.checkWriterReader` (`:78`). Only `qos_match.zig`'s own unit tests call it. `sedp.zig:24` imports it as `qos_mod` and never uses it. An early clean-typed-QoS attempt superseded by A, never removed. |
| D | `SPDPdiscoveredParticipantData` / `DiscoveredWriterData` / `DiscoveredReaderData` + `serializePlCdr` / `deserializeFromPlCdr` | `zzdds_disc_generated` module — zidl `--zig-pl-cdr` from `idl/rtps_discovery.idl` | **Built, wired into `zzdds`'s imports, unused.** One stale comment reference (`rtps/locator.zig:34`). `idl/rtps_discovery.idl` untouched since PR #9. This is the codec we are reviving. |

Plus the hand-rolled parsers that actually run: `sedp.zig:458` `decodeEndpoint`,
`spdp.zig:923` `decodeSpdpParticipant`, `sedp.zig:1292` `guidFromDisposalPayload`, and the
matching encoders (`encodeWriterData` `:211`, `encodeReaderData` `:345`,
`encodeSpdpParticipant` `spdp.zig:838`, `encodeEndpointDisposalPayload` `:1324`).

### Why `QosSnapshot` was hand-rolled (and why that reasoning no longer holds)

* **Not a DDS type.** There was no IDL for "the SEDP subset, denormalized, with `i32`
  sentinels." — *Resolved by:* `idl/rtps_discovery.idl` already defines
  `Discovered{Writer,Reader}Data` / `SPDPdiscoveredParticipantData` as the IDL for exactly
  the SEDP/SPDP ParameterList; they just need expanding (§4).
* **Dependency cut.** `discovery/interface.zig` avoided importing the ~346 KB generated
  `DDS.zig`. — *Resolved by:* the generated discovery module (D) is small and self-contained
  (its own `Locator_t` / `Duration_t`); nothing in the discovery path needs `DDS.zig`.
* **Different serialization.** SEDP PL_CDR is per-PID, not a CDR dump of `DataWriterQos`.
  — *Resolved by:* `--zig-pl-cdr` emits exactly the per-PID ParameterList encoding, keyed
  by `@id(PID)`, with `@pl_repeated` for the repeated-locator convention.

## 2. zidl's PL_CDR backend: what exists, what is missing

From `zidl/docs/implementation_status.md` §"PL_CDR (`--zig-pl-cdr`)" and the generated
`rtps_discovery.zig` (`35d7735`):

**Exists:**

* `serializePlCdr(writer: *PlCdrWriter, value)` / `deserializeFromPlCdr(out, reader, alloc)`
  for `@mutable` structs.
* PID = `@id(N)`; `@optional` member ⇒ serialize skips when null, deserialize assigns when
  the PID is seen; `@pl_repeated sequence<T>` ⇒ one PID entry per element.
* Classic RTPS PL_CDR: `PlCdrWriter` wraps `CdrWriter(.xcdr1)`, encapsulation `0x0003`
  (`PL_CDR_LE`), 2-byte PID + 2-byte length + value + pad-to-4, `PID_SENTINEL` terminator.
* `zidl_rt.CdrReader.readPlParam()` → `PlParam{ pid: u16 (raw, flag bits kept), byte_len:
  u16, end_pos: usize }`; generated code switches on `pid & 0x3FFF` and calls
  `seekTo(p.end_pos)` after each parameter.

**Missing for RTPS wire use:**

1. **Unknown-parameter retention.** The generated `else =>` arm is `else => {}` +
   `seekTo` — unknown PIDs are silently dropped, exactly like the hand-rolled parsers. No
   way to round-trip a vendor extension or an unmodelled QoS policy.
2. **Must-understand enforcement.** The `pid & 0x4000` flag is masked off and ignored on
   the PL_CDR path. (It *is* honoured on the separate XCDR2 EMHEADER path —
   `if (_emh.must_understand) return error.UnknownMustUnderstand;` — but that code is not
   reached for classic PL_CDR.)
3. **Strict structural validation.** Malformed length, missing sentinel, misaligned
   parameter: today these surface only as a generic `error.EndOfStream` from the reader, or
   not at all.

Items 1–3 are the substantive PR-A backend work. Two things that *looked* like gaps in
rev 0.2 turned out to be non-issues (spike §S4): `zidl_rt.CdrReader.init` already parses
the encapsulation header and already decodes big-endian (`PL_CDR_BE`, `0x0002`)
ParameterLists via its endian-aware reads. Whole-record byte retention needs no generated
field either — the decode input slice *is* the record (§S2).

## 3. Target architecture

### 3.1 IDL: bespoke RTPS ParameterList structs (spike §S1)

`idl/rtps_discovery.idl` is expanded and revived; its `SPDPdiscoveredParticipantData` /
`DiscoveredWriterData` / `DiscoveredReaderData` stay **bespoke `@mutable` RTPS structs** —
their own members, `@id(PID)`, `@pl_repeated`, RTPS `Locator_t`, RTPS `Duration_t`. They do
**not** embed `DDS::*QosPolicy` structs: those are `@final` and carry DDS `Duration_t`
(`{sec, nanosec}`), which the generated `serializePlCdr` would put on the wire in place of
RTPS `{sec, fraction}` (§S1). QoS *kind* members may be typed as the DDS enums
(`DDS::ReliabilityQosPolicyKind` rather than a bare `unsigned long`) for readability — that
needs no backend change (§S5) and is the only reason to compile these types into the same
module as `dcps.idl`; doing so is optional and can follow.

`zzdds_disc_generated` stays a distinct module (or is merged into `zzdds_generated` only if
the enum-typing is pursued). `dcps.idl` is **not** modified.

### 3.2 RTPS vs DDS `Duration_t`

Distinct types, as today. The discovery structs use RTPS `Duration_t`
`{ long seconds; unsigned long fraction }`; `DDS.*QosPolicy` uses DDS `Duration_t`
`{ long sec; unsigned long nanosec }`. The adapter (§3.5) converts, both directions, with
the INFINITE sentinel on each side. ~4 duration fields per endpoint (deadline,
latency_budget, liveliness lease, lifespan), 1 on the participant (lease). This conversion
is already in the tree (`sedp.zig` `readDeadlineDuration` / `writeRtpsDuration`,
`RtpsDuration.fromDuration` / `.toDuration`); it moves into the adapter.

### 3.3 Lossless retention (zidl backend feature — spike §S2)

A struct-level annotation `@pl_retain_unknown` (added next to the existing `@nested` /
`@topic` handling in `ir.TypeAnnotations`) makes the `--zig-pl-cdr` backend emit, on a
`@mutable` struct:

```zig
/// Unknown parameters preserved verbatim, in wire order. Owned; freed by deinit().
unknown_params: []zidl_rt.RawParam = &.{},   // RawParam{ pid: u16, bytes: []u8 }  — value bytes, no PID/len header
```

* `deserializeFromPlCdr`'s `else =>` arm: instead of only `seekTo(_p.end_pos)`, dup the
  value bytes and append `RawParam{ _p.pid, … }`.
* `serializePlCdr`: after the modelled members and before `writePlSentinel`, replay each
  `unknown_params` entry via a new `PlCdrWriter.writeRawParam(pid, bytes)`. RTPS does not
  mandate PID order, so appending retained unknowns is spec-legal.
* `deinit` / `clone` extend to cover the field (the backend's `structNeedsCleanup` path).

**No generated `raw_encoded` field.** Whole-record byte retention is caller-side and free:
the SEDP/SPDP decode input (`ch.data`) is exactly the record — encapsulation header
included — so the callback's borrowed `raw_parameter_list` (§6) points straight at it, and
only a consumer that retains records past the callback (the broker) copies.

### 3.4 Strict / lenient

`deserializeFromPlCdr(out, reader, alloc, mode)` gains a `mode: enum { lenient, strict }`:

* **lenient** — current behaviour: `seekTo` past unknowns (plus retention if
  `@pl_retain_unknown`), ignore the must-understand flag, tolerate a truncated tail.
  Native SPDP/SEDP path.
* **strict** — typed errors: `error.TruncatedParameter`, `error.MisalignedParameter`,
  `error.MissingSentinel`, `error.UnknownMustUnderstand` (unknown PID with `pid & 0x4000`),
  `error.DuplicateParameter` (a non-`@pl_repeated` member's PID seen twice). For the broker
  and any future untrusted-network ingest. Not selected by the native path in PR B.

### 3.5 The thin zzdds adapter

`participant.zig` gains `writerDiscoveredData(dw, presentation) disc.DiscoveredWriterData`
and `readerDiscoveredData(dr, presentation)`, replacing `writerQosSnapshot` /
`readerQosSnapshot` one-for-one. These:

* map each `DDS.*QosPolicy` field out of `dw.qos` into the corresponding RTPS struct member
  (enum → enum or `u32`; scalars direct);
* pull `presentation` from the parent `PublisherImpl` / `SubscriberImpl` (as today — a
  Publisher/Subscriber-level policy, not on the writer/reader QoS);
* keep the normalizations that live in `writerQosSnapshot` today and do not disappear:
  codegen `{0,0}` duration ⇒ RTPS `DURATION_INFINITE`; `KEEP_LAST` depth `< 1` ⇒ `1`;
  reader side advertises XCDR2 acceptance when `data_representation` is unset (interop
  behaviour, `reprFromQos`);
* convert DDS `Duration_t` ⇒ RTPS `Duration_t`;
* decide `@optional` present-vs-null: a policy at its spec default is left null so the PID
  is omitted, matching today's conditional emit (`encodeWriterData` omits `PID_DEADLINE` /
  `PID_LIFESPAN` / `PID_PRESENTATION` / non-default `PID_LIVELINESS` /
  `PID_OWNERSHIP_STRENGTH`). Always-emitted policies (`RELIABILITY`, `DURABILITY`,
  `DESTINATION_ORDER`, `HISTORY`, `OWNERSHIP`) are non-`@optional` members.

~25 lines — the same mapping logic as `writerQosSnapshot`, but the target is a *generated*
struct whose `serializePlCdr` is the authoritative wire encoder and which retains unknowns.
Only this one direction (`DDS.*Qos` → discovered-data) is needed: SEDP announce uses it,
and local-side matching uses it. The decode side produces `DiscoveredWriterData` straight
from the wire — no conversion back to `DDS.*Qos`.

### 3.6 Matching

`checkSnapshots(offered: disc.QosSnapshot, requested: disc.QosSnapshot)` becomes
`checkDiscovered(offered: *const disc.DiscoveredWriterData, requested: *const
disc.DiscoveredReaderData)` — same rules, reading the generated RTPS struct's members
instead of the flat `QosSnapshot`. The four `participant.zig` call sites (`:2320`, `:2492`,
`:2792`, `:2927`) pass the remote decoded struct and the local struct from §3.5.
`checkPresentation` / `checkPartition` adjust to the same structs.

`qos_match.checkWriterReader` and `src/qos/policy.zig` (representation **C** — an orphan,
only its own tests call it) are **deleted outright**, not ported: `checkDiscovered` over
the generated RTPS structs is the single typed matcher. `QosSnapshot`, `writerQosSnapshot`,
`readerQosSnapshot`, and the dead `qos_mod` import in `sedp.zig` are deleted.

*Note on "typed QoS":* the discovered-data structs are IDL-generated, wire-authoritative
`Discovered{Writer,Reader}Data` (RTPS `DCPSPublication` / `DCPSSubscription` builtin topic
data) with real (de)serialize and lossless retention — not a hand-rolled lossy projection.
That is the typed representation for the discovery path. Folding the *DCPS* path onto the
same structs (so `writer.zig` stores one type end to end) remains possible later but is not
required here and is not blocked by anything this PR does.

### 3.7 SPDP / SEDP state machines

Unchanged. `spdp.zig` / `sedp.zig` already isolate encode/decode behind
`encode*` / `decode*` functions that the reader/writer state machines call. Only those
function bodies change — from hand-rolled TLV walking to
`var r = try zidl_rt.CdrReader.init(ch.data); try Disc.DiscoveredWriterData.deserializeFromPlCdr(&out, &r, alloc, .lenient);`
plus the §3.5 adapter (decode) / `.serializePlCdr` into a `PlCdrWriter` (encode). The
`handleEndpointChange` / participant-discovered callback wiring, locator filtering,
probe/lease logic: untouched.

### 3.8 Disposal payload

`guidFromDisposalPayload` becomes a decode of a one-field `@mutable struct` (`@id(0x005A)
octet endpointGuid[16];`) reusing the generated path, or stays as the existing ~15-line
scan. Low stakes — decide during PR B; leaning "tiny generated struct" for consistency.

### 3.9 Boundary summary

| Generated (zidl) | Hand-written (zzdds) |
| --- | --- |
| PL_CDR TLV walk, PID dispatch, `@pl_repeated` locator handling, `PID_SENTINEL` | SPDP/SEDP state machines, listener/probe/lease logic |
| Encapsulation-header parse + LE/BE endianness (`CdrReader.init`, already there) | `DDS.*Qos` → `Discovered{Writer,Reader}Data` adapter (§3.5, one direction) |
| Unknown-param retention (`unknown_params`), must-understand enforcement, strict structural errors | `checkDiscovered` matching rules over the generated RTPS structs |
| `Discovered{Writer,Reader}Data` / `SPDPdiscoveredParticipantData` (de)serialize | DDS⇄RTPS `Duration_t` conversion; the decode-input wrapper (`CdrReader.init` + call) |

## 4. IDL coverage gap

`idl/rtps_discovery.idl` today is far thinner than what SEDP encodes. Reviving it means
bringing `DiscoveredWriterData` / `DiscoveredReaderData` up to full coverage. Missing
versus `sedp.zig` today:

* **Endpoint QoS PIDs not present:** `PID_HISTORY` (0x0040), `PID_PRESENTATION` (0x0021),
  `PID_LIFESPAN` (0x002B), `PID_DATA_REPRESENTATION` (0x0073), `PID_USER_DATA` on endpoints
  (0x002C), `PID_LIVELINESS` *lease duration* (only `livelinessKind` is modelled — the
  8-byte duration is dropped), `PID_DEADLINE` on the writer (reader-only today),
  `PID_PARTITION` on the writer.
* **Identity:** `PID_GROUP_GUID` (0x0052) for GROUP-scope coherent sets.
* **Bugs in the current IDL to fix:** `DiscoveredReaderData.partition` is `@id(0x0035)` —
  that is `PID_PARTITION_LEGACY`; the emit value must be `0x0029` (accept `0x0035` on
  read). `SPDPdiscoveredParticipantData.defaultUnicastLocatorList` is `@id(0x002F)` —
  `0x002F` is the *endpoint* unicast PID; SPDP default unicast is `PID_DEFAULT_UNICAST_LOCATOR`
  `0x0031`.
* **Lower priority / not emitted today anyway:** `PID_TOPIC_DATA` (0x002E),
  `PID_GROUP_DATA` (0x002D), `PID_DURABILITY_SERVICE` (0x001E),
  `PID_TIME_BASED_FILTER` (0x0004), `PID_RESOURCE_LIMITS` (0x0041),
  `PID_TRANSPORT_PRIORITY` (0x0049). These now round-trip via retention (§3.3) whether or
  not they get modelled fields; modelling them is independent follow-up.
* **SPDP:** mostly complete. Audit `PID_PARTICIPANT_MANUAL_LIVELINESS_COUNT` (0x0034);
  `builtinEndpointQos` (0x0077) is present.

Because unmodelled PIDs are now retained losslessly, "full coverage" means *the PIDs zzdds
acts on*, not *every PID a peer might send* — the bar is lower than a from-scratch parser.

## 5. Decisions on rev 0.1's open questions (revised)

| Question | rev 0.3 decision |
| --- | --- |
| Hand-rolled `src/discovery/codec/` module | **Dropped.** The codec is generated by zidl `--zig-pl-cdr` from `idl/rtps_discovery.idl`. |
| Whole-list blob vs per-parameter ranges | `unknown_params` (`{pid, bytes}` per retained parameter) is the *generated* field. Whole-record bytes are **not** a generated field — the decode input slice is the record, so a byte-exact re-emit is `@memcpy` of that slice, caller-side (§S2). |
| Where raw bytes hang | `unknown_params` owned by the generated decoded struct (`deinit` frees it). The callback path exposes the borrowed decode-input slice as `raw_parameter_list` (§6). |
| `QosSnapshot` | **Deleted**, replaced by the generated `Discovered{Writer,Reader}Data` structs. |
| `src/qos/policy.zig` | **Deleted outright** (orphan — only its own tests use it). `checkWriterReader` deleted with it; `checkDiscovered` over the generated RTPS structs is the single matcher. |
| Typed QoS "later" | **Now**, for the discovery path — the generated RTPS structs. DCPS-path unification stays optional (§3.6). |
| Strict vs lenient default | Native path stays **lenient** (skip + retain unknowns, tolerate truncated tail). Strict is opt-in — `deserializeFromPlCdr(…, mode)` — used by the broker PR, not the native path. |
| Fuzz target | Retarget `test/fuzz/fuzz_plcdr.zig` at the generated decoder + a decode→re-encode byte-exactness invariant; zidl gets its own PL_CDR retention/strict fuzz in `zidl-rt`. |
| Must-understand flag bit | **Resolved (§S3):** `pid & 0x4000` = must-understand, `pid & 0x8000` = vendor (RTPS 2.5 §9.6.4, Table 9.6). The `zidl_rt/cdr.zig:1122` comment is backwards — fixed in PR A. |
| Big-endian PL_CDR | **Resolved (§S4):** `CdrReader.init` already accepts `PL_CDR_BE` and decodes endian-aware. No PR-A work. Writer stays LE-only (zzdds only emits LE). |

## 6. Raw bytes on the callback path

`WriterData` / `ReaderData` / `ParticipantData` (`discovery/interface.zig`) gain:

```zig
/// The endpoint/participant's complete discovery ParameterList as received,
/// encapsulation header included. Borrowed — valid only for the duration of the
/// on_*_discovered callback. A consumer that retains it (a discovery broker) MUST
/// copy. Empty for plugins that carry no raw bytes (direct.zig; static, later).
raw_parameter_list: []const u8 = &.{},
```

Points straight at the decode-input slice (`ch.data`). Populated for `WriterData` /
`ReaderData` from `handleEndpointChange` (ephemeral, never persisted — safe). Left empty on
`ParticipantData` in this PR: `ParticipantData` is persisted in `KnownParticipant`
(`spdp.zig:595`), so a borrowed slice cannot live there; safe population (own a copy on
`KnownParticipant`, or set-then-clear around the callback) is a broker-PR lifetime
decision. Documented as "valid solely in `on_participant_discovered`".

The native DCPS consumer ignores the field — zero cost, zero behaviour change.

## 7. Cross-repo sequencing — two PRs

### PR A — zidl: PL_CDR backend — retention + strict + must-understand

Scoped down by the spike: no big-endian reader work (§S4), no `raw_encoded` field (§S2).

1. `zidl_rt` (`packages/zidl-rt/src/cdr.zig`): a `RawParam{ pid: u16, bytes: []u8 }` type;
   `PlParam` value-slice accessor for the `else =>` arm; `PlCdrWriter.writeRawParam(pid,
   bytes)`; strict-error returns on the PL_CDR read path
   (`error.TruncatedParameter` / `MisalignedParameter` / `MissingSentinel`). Fix the
   backwards `PlParam` flag-bit doc comment (`:1122`).
2. IR: `pl_retain_unknown: bool` on `ir.TypeAnnotations` (`src/ir/types.zig:62`) + one
   branch in `interpretTypeAnnotations` (`src/ir/builder.zig:1105`).
3. Backend (`src/backend/zig.zig`, PL_CDR path ~`:3920`): when the struct has
   `@pl_retain_unknown`, emit `unknown_params`, retain in the `else =>` arm, replay before
   `writePlSentinel`, and cover it in `deinit`/`clone`.
4. Backend: `mode: enum { lenient, strict }` parameter on `deserializeFromPlCdr`; in
   strict, `if ((_p.pid & 0x4000) != 0) return error.UnknownMustUnderstand` in `else =>`,
   plus the structural checks and duplicate-non-`@pl_repeated`-PID detection.
5. Tests: `zidl-rt` + backend-codegen round-trip incl. retained unknowns replayed in
   order; must-understand positive/negative; each strict error; a PL_CDR fuzz target.
   `docs/implementation_status.md`, `docs/features.md`, `docs/annotations.md`
   (`@pl_retain_unknown`), `docs/decisions.md`, roadmap.
6. Release: zidl version bump; note the capability in `CHANGELOG.md`.

### PR B — zzdds: adopt the generated codec, delete representations B and C

1. Bump the zidl pin in `build.zig.zon`; `zig build` regen check.
2. **IDL — `idl/rtps_discovery.idl`:** expand `DiscoveredWriterData` / `DiscoveredReaderData`
   / `SPDPdiscoveredParticipantData` to full §4 PID coverage as bespoke `@mutable` RTPS
   structs (own members, `@id(PID)`, `@pl_repeated`, RTPS `Locator_t` / `Duration_t`; QoS
   *kind* members may be DDS enums); fix the two existing PID bugs (`@id(0x0035)`→`0x0029`,
   SPDP default-unicast `@id(0x002F)`→`0x0031`); mark the three structs
   `@pl_retain_unknown`. `dcps.idl` is **not** touched. `zzdds_disc_generated` stays a
   distinct module.
3. **Golden wire fixtures** — before swapping anything: capture current `encodeWriterData`
   / `encodeReaderData` / `encodeSpdpParticipant` / `encodeEndpointDisposalPayload` output
   as checked-in hex across default QoS and every conditionally-emitted PID
   (`test/discovery/wire_golden_test.zig`). The "wire output did not move" contract.
4. Swap `spdp.zig` / `sedp.zig` encode + decode bodies to `CdrReader.init` +
   `serializePlCdr` / `deserializeFromPlCdr` + the §3.5 adapter. Delete the hand-rolled
   `readU16LE` / `readLocator` / `readString` / `readDeadlineDuration` / `writePidHdr` /
   `PLCDR_LE_ENCAP` and the TLV loops. `guidFromDisposalPayload` per §3.8.
5. Delete `disc.QosSnapshot`, `participant.zig:writerQosSnapshot` / `readerQosSnapshot`;
   `qos_match.checkSnapshots` → `checkDiscovered` over the generated structs.
6. Delete `src/qos/policy.zig`, `qos_match.checkWriterReader`, and the dead `qos_mod`
   import in `sedp.zig`. Adjust `checkPresentation` / `checkPartition` to the generated
   structs; rewire the four `participant.zig` call sites.
7. `raw_parameter_list` on the callback structs (§6), pointing at the decode input.
8. Retarget `test/fuzz/fuzz_plcdr.zig` at the generated decoder + a decode→re-encode
   byte-exactness invariant; drop SEDP payloads into the corpus.
9. `docs/decisions.md` (discovery codec is IDL-generated; typed discovery QoS via the RTPS
   structs; retention + strict mode; `QosSnapshot` and `qos/policy.zig` removed);
   `docs/roadmap.md` (close the shared-codec / strict-validation / `fuzz_cdr_payload.zig`
   items). Delete the stale `interface.zig:31` comment.

## 8. Verification

### PR A (zidl)

* Round-trip: `deserializeFromPlCdr` → `serializePlCdr` byte-exact (LE), including
  retained-unknown parameters reproduced in order. Big-endian *decode* covered by a
  `CdrReader.init(PL_CDR_BE …)` case (already-existing behaviour, add a regression test).
* Must-understand: unknown ignorable PID passes lenient and strict; unknown must-understand
  PID passes lenient, `error.UnknownMustUnderstand` in strict.
* Strict structural: truncated / misaligned / missing-sentinel / duplicate-non-`@pl_repeated`
  each have a positive and negative case.
* Fuzz: no panic / OOB for any input in either mode.

### PR B (zzdds)

* `test/discovery/wire_golden_test.zig` (commit before the swap): every encoder's output
  equals its checked-in hex, across default QoS and every conditionally-emitted PID. The
  swap must not move a byte.
* `sedp_test.zig`, `spdp_lease_test.zig` pass unchanged.
* **Matching parity:** `checkDiscovered` over the generated RTPS structs returns the same
  verdict as the deleted `checkSnapshots` for the entire existing matcher test matrix
  (port the cases, keep both green during the transition commit, then drop the old ones).
* New: decode → re-encode is byte-exact for real captured Connext / Cyclone / OpenDDS SPDP
  and SEDP records (fixtures under `test/discovery/` and `test/fuzz/corpus/plcdr/`),
  including vendor PIDs, `PID_TYPE_INFORMATION`, and non-default QoS — proves retention.
* `zig build test` and the live interop suite (`interoperability_report.py`) green.
* `zig build test-tsan` clean (the codec swap touches the SEDP decode path — see
  `project-rtps-proto-quiesce` territory).

## 9. Risks and watch-items

* **Two-repo lockstep.** PR B is blocked on a zidl release. Keep PR A tightly scoped.
* **Conditional-PID omission.** Today's hand encoder omits a policy PID when the value is
  the spec default. The generated serializer omits an `@optional` member when null, so the
  adapter (§3.5) must set the member null at the default — this logic is preserved from
  `writerQosSnapshot`, not lost, but it is the most error-prone part of the byte-exactness
  goal. The golden fixtures (§7 PR B step 3) are the guard.
* **Decode-side spec defaults for omitted PIDs.** The mirror of the point above: a foreign
  peer omits a policy PID when it keeps the spec default (Connext omits `PID_RELIABILITY`
  for its default-RELIABLE writer). The generated `deserializeFromPlCdr` leaves the
  non-`@optional` `reliability` member zero-initialised (`kind == 0`, an invalid wire
  value), which `checkDiscovered` would read as *weaker than BEST_EFFORT* → spurious
  `INCOMPATIBLE_QOS`. The old hand parser seeded RTPS defaults as it went; the generated
  decoder does not. `sedp.zig` `handleEndpointChange` re-seeds `reliability.kind` after
  decode — `0 → 2` (RELIABLE) on the writer branch, `0 → 1` (BEST_EFFORT) on the reader
  branch, per RTPS 2.5 §8.5.4.2/§8.5.4.3. Other omitted policies (durability, ownership,
  destination-order, history) already decode to `0`, which is their spec-default ordinal,
  so they need no re-seed. Caught by the live interop gate, not the golden fixtures (those
  drive zzdds's own always-emitting encoder).
* **RTPS vs DDS `Duration_t`** (§3.2) appears anywhere a duration crosses the adapter — 4
  fields per endpoint, `{sec, nanosec}` → `{sec, fraction}`, INFINITE sentinel on both
  sides. The reason the discovery structs can't just embed `DDS::*QosPolicy` (§S1).
* **`@pl_repeated` deserialize is O(n²)** in the generated reader (`alloc(len+1)` +
  `@memcpy` per element). Fine for the handful of locators an endpoint carries; note it,
  do not fix it here.
* **XTypes / Security blobs** (`PID_TYPE_INFORMATION`, future secure-discovery PIDs) now
  round-trip through retention with no code — a positive, and a fixture case.
* **PARTITION decode edges.** Two things a hand-parse of the decoded struct must get
  right. (1) A peer that sends `PID_PARTITION` as the legacy PID `0x0035` lands it in
  `unknown_params` (the generated switch keys on `@id` `0x0029`). `sedp.zig`
  `legacyPartitionSeq` parses that retained value as a CDR `sequence<string>` — and must
  read its sequence count and string lengths with the **payload's byte order**, since
  retained param bytes are stored verbatim and `CdrReader` accepts `PL_CDR_BE` too
  (`DecodedEndpoint.little_endian` carries it). (2) `partition` is an unbounded
  `sequence<string>`; materialising it (declared member or legacy) into a fixed stack
  buffer silently drops names past the cap and breaks matching for an endpoint that
  advertises many partitions. `partitionNamesOwned` heap-allocates to the actual count
  (freed after the callback; the consumer deep-copies). Both are `sedp_test.zig` /
  in-file `sedp.zig` regression cases.
* **`@pl_retain_unknown` touches `deinit`/`clone` codegen.** The retained-slice field means
  structs that were previously cleanup-free now need a generated `deinit` — verify the
  backend's `structNeedsCleanup` path picks that up and that `clone` deep-copies
  `unknown_params`.

## 10. Still explicitly deferred

* The discovery broker and any broker wire protocol.
* PL_CDR in non-Zig zidl backends (`zidl/docs/roadmap.md`: not planned).
* XCDR2 (`PL_CDR2`, `0x000B`) discovery encapsulation.
* XTypes TypeLookup service.
* Modelling the low-priority PIDs in §4 that zzdds does not act on (they round-trip via
  retention regardless).

## 11. Pointers

* Rev 0.1 (superseded): this file's git history.
* Broker review: `docs/design/discovery-broker-review.md` §2, §3, §10 (branch `broker_spec`).
* Broker spec: `docs/design/discovery-broker.md` §5, §14 (branch `broker_spec`).
* zidl: `docs/implementation_status.md` §"PL_CDR"; `src/backend/zig.zig` PL_CDR path
  (~`:3920`), `emitWriteForTypeRef` (`:5623`); `src/ir/types.zig:62` (`TypeAnnotations`),
  `src/ir/builder.zig:1105` (`interpretTypeAnnotations`); `packages/zidl-rt/src/cdr.zig`
  (`PlParam` `:1121`, `readPlParam` `:1137`, `CdrReader.init` `:790`, `PlCdrWriter` `:643`);
  generated `rtps_discovery.zig`.
* `idl/rtps_discovery.idl`, `idl/dcps.idl` (QoS policy structs; all `@final`, DDS `Duration_t`).
* `src/dcps/qos_match.zig` (`checkWriterReader` `:78` [orphan], `checkSnapshots` `:137`),
  `src/dcps/participant.zig` (`writerQosSnapshot` `:1718`, 4 `checkSnapshots` call sites
  `:2320` `:2492` `:2792` `:2927`).
* `docs/decisions.md` → *Transport / Discovery* (RTPS vs DDS `Duration_t`).
* RTPS 2.5 (`OMG_specs/formal-22-04-01.pdf`) §8.5 (discovery), §9.4.2.11 / §9.6.2
  (ParameterList PSM), **§9.6.4 Table 9.6** (ParameterId flag bits — §S3). DDS 1.4 §2.2.5
  (built-in topics).
