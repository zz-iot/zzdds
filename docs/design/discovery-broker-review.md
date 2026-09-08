# Review of the centralized discovery broker spec

Status: review of `discovery-broker.md` revision 0.1, written 2026-09-08. This is a
design critique, not a counter-proposal. It assesses fit with the current `zzdds`
implementation (`74a9d52`), the roadmap, and `decisions.md`, and it recommends a
sequencing that lets broker design proceed in parallel without committing the project
to obligations it is not ready for.

## 1. Verdict

The design is sound and the plugin seam it targets is real. `src/discovery/interface.zig`
was written with a broker implementation in mind (`interface.zig:11` names it), the
`Discovery` vtable is already transport-agnostic, and the consistency model in the spec's
§5 (epoch / incarnation / owner_generation / origin_revision / delivery_seq / tombstones)
is the strongest part of the document — it is a consensus-free replicated-state-machine
design that avoids every classic relay trap (no republishing under origin GUIDs, no
impersonating the origin SEDP writer, broker transport identity kept distinct from entity
ownership).

The concerns are about **scope relative to project stage** and **collision with
unfinished scaling work**, not about the correctness of the design itself. As written, the
spec is a larger program than the roadmap slot it fills, it leans on RTPS reliability code
that has pending scaling caveats, and it is silent on the concurrency/embedded direction
the project has committed to.

## 2. Is it too soon?

Not for **design**. It is premature for **implementation of the broker client and a wire
freeze** until a few shared prerequisites land.

The spec is valuable right now precisely as design pressure: it is a concrete consumer
that forces decisions on the concurrency model, the transport channel/session abstraction,
and the lossless-codec work. Parallelizing that design effort is the right call.

What should *not* happen yet:

* **Freezing the broker wire protocol** before the transport channel/session abstraction
  (§4.3 below) is designed — the framing depends on it.
* **Building the broker client on today's RTPS reliability primitives** before the
  scaling cleanup the roadmap already lists (§4.1 below).
* **Baking a threading model into the broker client** before the "Concurrency model"
  design task (roadmap, *Design Tasks — not yet scoped*) produces a direction.

Two pieces of the spec's own §14 are safe to pull forward *now*, decoupled from the
broker, because the rest of the stack needs them anyway:

1. **Shared discovery codec + strict structural validation** (`discovery/codec/`,
   lossless raw-record retention). This is the same work required to replace the
   placeholder `QosSnapshot` (`interface.zig:34`) and to carry XTypes `TypeInformation`
   / `TypeIdentifier` through discovery untouched. Low rework risk; useful regardless of
   whether the broker ships.
2. **A transport channel/session concept.** The plain TCP-user-data path
   (`participant.zig:805`+) and the `DataLocatorReachability` shim already want this; it
   is not broker-specific.

Doing those first de-risks the broker and parallelizes cleanly. Both are now captured as
standalone tasks — `zz-dev/discovery-codec-handoff.md` and
`zz-dev/transport-channel-handoff.md` — to be specced, planned, and landed as separate PRs
ahead of any broker implementation. §10 has the sequencing.

## 3. What the spec gets right

* **Plugin boundary.** A `BrokerDiscovery` beside `SpdpSedpDiscovery` is how the
  `Discovery` seam was meant to be used. `interface.zig:11` and `docs/architecture.md`
  both anticipate it.
* **Lossless payload retention (§5).** Correct, and a prerequisite the project already
  knows it needs. `QosSnapshot` is explicitly a placeholder ("kept as raw i32/u32 …
  Will be replaced by typed QoS"), and `spdp.zig` / `sedp.zig` discard unknown
  ParameterList members today. "Retain the complete owned byte representation; parsed
  indexes are disposable derivatives" is exactly what keeps the design XTypes- and
  Security-safe later.
* **User data stays direct; the broker is not a data router.** Correct scope boundary,
  consistent with `decisions.md` ("RTPS framing is not a plugin"; transport carries
  opaque buffers).
* **Two-profile split (`cached` vs `opaque_peer`).** Forward-compatible with the
  not-yet-built security pipeline (§7 below).
* **Performance honesty (§12).** "Centralization is not an unconditional performance
  improvement", "include workloads where the broker may lose", "do not market
  100k-client scalability from asymptotic analysis" — matches the project's culture.

## 4. Fit with the current implementation

### 4.1 RTPS reliability reuse vs. unfinished scaling work

The spec's §6.1 ("use RTPS DATA/DATA_FRAG and the existing reliability machinery for …
zzdds control endpoint pairs") and §6.2 ("assign independent RTPS sequence spaces to each
session's control/state writers") put a broker terminating many sessions directly on top
of primitives the roadmap already flags as not-ready-to-scale:

* **One heartbeat thread per `StatefulWriter`** (`src/rtps/writer_sm.zig:734`). Per-session
  writers multiply this one-to-one.
* **Unlock-before-send not applied on all paths** — `reader_sm.zig`'s
  `sendAckNackLocked` / proxy loop and `writer_sm.zig`'s `sendFragsToProxyLocked` still
  send under lock (roadmap, "Lock-order-cycle fix … not applied everywhere").
* **O(N²) `orderedRemove` hot paths** pending a sweep "before scaling" (roadmap).
* **Transport dispatch 64-handlers-per-port cap** (`transport/interface.zig:401`),
  already flagged for revisiting "before the factory pattern makes spinning up many
  participants easy."

§12 acknowledges the TCP receive-thread-per-connection problem but not the
writer/heartbeat-thread multiplication or the lock-order gaps. This is the single biggest
"does it fit?" issue: it fits the *interfaces* cleanly but lands on unfinished work.

Recommendation: the spec should either specify a slimmer reliable-stream primitive for
broker control/state (decoupled from the DCPS-coupled `StatefulWriter`/`StatefulReader`),
or explicitly gate broker scale claims on that cleanup landing first.

### 4.2 Concurrency and embedded model

The roadmap lists "Concurrency model" as an explicitly unscoped design task — zzdds has
never stated a strategy and already has ~10 `Thread.spawn` sites (`thread-model.md`). It
also commits to a future `DomainParticipant.drive(timeout)` single-threaded pump for
RTOS / bare-metal targets.

A broker client with RTT-sensitive repair, congestion budgets, reassembly timers, lease
challenge/response, and (later) DTLS is thread-heavy, and the spec says nothing about how
it degrades to an evented / single-threaded pump. Introducing this much machinery before
the unifying concurrency decision risks baking in another threading model to retrofit
later.

Recommendation: the spec should state that the broker client targets only the threaded
model in v1, and sketch the evented degradation path (or explicitly declare the broker
out of scope for the embedded `drive(timeout)` face).

### 4.3 Transport interface changes

§14's asks — "optional channel/session and ingress-context capabilities", accepted-
connection replies, disable host-only reuse — are additive but touch the `Transport`
vtable implemented by `udp.zig`, `tcp.zig`, `memory.zig`, `mock.zig`, `lossy.zig`, plus
`locator_selector.zig` and the protocol adapters. `connection_generation`
(`interface.zig:459`) is the only connection-lifecycle hook today and is deliberately
coarse. `reuse_connection_by_host` (`transport/tcp.zig:484`) must be disabled for broker
channels — the spec is right that equal source IP behind one NAT must not share a route.

Recommendation: scope the channel/session abstraction as its own preparatory change,
landed before the broker and justified independently by the plain TCP-data path.

### 4.4 Route resolver vs. `LocatorSelector`

§4 and §11 introduce a "route resolver" (advertised locator vs. currently-usable path)
and a `ConnectivityAgent`. This overlaps `transport/locator_selector.zig` (Phase-1
per-proxy ranking today; cross-proxy fan-out deferred). The spec should state whether the
route resolver sits above `LocatorSelector`, replaces it, or feeds candidates into it —
otherwise the stack ends up with two locator-ranking layers.

### 4.5 WLP forwarding plumbing

§8 correctly requires the broker to forward WLP only from real origin WLP output and never
to synthesize AUTOMATIC / MANUAL_BY_PARTICIPANT from its session timer. But WLP today has
no listener of its own — it shares SEDP's metatraffic unicast listener via the
`DiscoveredFanout` shim in `discovery/combined.zig`, and `BuiltinParticipantMessageReader`
is RELIABLE-only (roadmap). Extracting a clean "origin WLP output stream" tap for the
metatraffic router is real integration cost that §14 undersells.

## 5. Fit with roadmap and decisions

### 5.1 A new proprietary wire protocol and a versioning commitment

`decisions.md` → *Versioning / Releases*: "Pre-1.0: no source- or ABI-compatibility
guarantee across releases", and `--runtime-version` is deliberately unimplemented "until
there is a stable tier to pin."

The broker introduces the first zzdds-**proprietary network wire protocol** — SPDP/SEDP
are at least OMG-standardized — with an explicit protocol major/minor, a "wire freeze"
review, and "cross-version fixtures", because broker and clients deploy independently and
*will* version-skew. That is a materially stronger and longer-lived commitment than
anything currently in the tree. The spec's wire-freeze gating (§16) is the right instinct;
this review just makes explicit that it is a new *category* of obligation and should be a
conscious decision, not a side effect.

### 5.2 zidl dependency

§6.1 wants zidl-generated control IDL with "unknown optional members allowed, unknown
required features rejected", and proposes "XCDR2 mutable types subject to zidl round-trip
fixtures." zidl's mutable/appendable and must-understand support needs confirming against
`zidl/docs/roadmap.md` before this is a safe assumption. The spec hedges it appropriately,
but it is a real external dependency on the sibling repo.

### 5.3 Testing non-goals

`testing-strategy.md` lists network simulation (ns-3 / CORE) and spec-conformance
harnesses as explicit non-goals. §15 requires real network-namespace tests for the
NAT / return-path claims (unavoidable — in-memory cannot establish them) plus
2 / 100 / 1k / 10k-participant benchmark tiers. That is new CI infrastructure; "subject to
available hardware" does not cover the integration lift. Worth an explicit line item.

### 5.4 Config

§14's row for `config/schema.zig` is correct and consistent with `decisions.md`: config is
zidl-generated from `idl/zzdds.idl` via `--zig-generate-toml-config`, so the schema/IDL
source changes, not only generated output, and unsupported broker settings are rejected
explicitly (which is how `DiscoveryKind` already behaves — `schema.zig:194`,
`generated.zig:151`). `DiscoveryKind.broker` reaches the runtime enum today
(`generated.zig:155`) but `ParticipantStack.init` hardcodes `SpdpSedpDiscovery`
(`c_abi/extensions.zig:197`); tagged stack construction selected by config is the real
work. Note also that `decisions.md` rules out environment variables entirely — the spec's
revision-0.1 banner mentions "env codegen", which does not exist and should not be assumed.

## 6. XTYPES extensibility — solid

The lossless-payload requirement (§5) is the enabler and the layering is right: preserve
`TypeInformation` / `TypeIdentifier` / endpoint-availability metadata as opaque bytes now,
and once TypeLookup lands (roadmap, *DDS-XTypes v1.3 + TypeLookup*) route the four
TypeLookup service endpoints through the metatraffic router (§10.2) rather than having the
broker answer as the origin. Consistent with `thread-model.md` (reader announcements
deliberately omit `PID_TYPE_INFORMATION` today to avoid triggering OpenDDS TypeLookup).

Notes:

* The "index fails open — never suppress a potentially-matching endpoint on incomplete
  type knowledge" invariant (§8, §9) is what keeps `topic_candidates` mode XTypes-safe.
  DDS still requires topic-name equality for matching, so topic-name-only candidate
  selection does not create false negatives for assignable-but-differently-named types.
  Self-consistent.
* This does not help the keyed-instance-NIL gap (roadmap) — that still needs TypeLookup
  or mandatory `registerTypeSupport`. The spec does not claim otherwise; noted so the
  "broker + preserved metadata" story is not mistaken for a shortcut there.

## 7. SECURITY extensibility — well-handled, with one trade to internalize

The `cached` / `opaque_peer` split is the correct forward-compatible architecture, and
the spec is careful about the usual failure modes: not reusing standardized Security
builtin entity IDs (§6.1), citing `relay_only`'s actual semantics rather than treating it
as blanket republish authorization (§10.3), invariant 10 ("never silently fall back from
protected to plaintext"), and preserving whole protected messages without re-signing or
locator substitution (§10.3). `security-pipeline.md` is skeleton-only today, so this is
correctly framed as a future-integration dependency (§14 row).

The trade the spec states but that should be internalized: **`opaque_peer` reintroduces
O(N²) native peer associations** (§12). The scaling win is a `cached`-profile property,
and `cached` means trusting the broker with discovery plaintext. "Broker for a secure
large fleet" is therefore not a solved story in this design — it is explicitly deferred
as "a separate later design problem." A reasonable v1 boundary, but it means the broker's
headline benefit and full DDS Security are partly at odds until that later work.

## 8. Scope question — which use case is driving this

The roadmap's discovery gap is one bullet with a binary: implement static + broker client,
or remove the advertised config surface, before v1. The spec picks "implement" and expands
to a broker executable + client plugin + new wire protocol + connectivity agent +
ICE/STUN/TURN roadmap + fenced-HA roadmap.

The RTI Cloud Discovery Service comparison row points at the cheaper option — participant
rendezvous / SPDP-introductions-only — and the spec rejects it for the primary profile
because it "does not meet the endpoint-discovery scaling objective." That rejection
deserves a second look against the actual motivating use case:

* If the driver is **rmw_zzdds / ROS2 in k8s / cloud with no multicast**, the pain is
  multicast-less bootstrap plus NAT, which SPDP-introductions-only (Cloud Discovery style,
  native SEDP kept peer-to-peer) solves with far less machinery and no new consistency
  protocol.
* If the driver is genuinely **SEDP fan-out at thousands of endpoints**, the full cached
  design is justified — but it then forces `topic_candidates` mode (partial, explicitly
  lossy discovery views) onto application authors and onto the incompatible-QoS
  diagnostics story, because the default `all` mode is O(N·E) to every client and does
  not escape the thing a broker is bought to avoid.

This should be settled before endorsing the "reject participant-rendezvous" call. A
plausible outcome is that SPDP-introductions-only is retained as a first, smaller
deliverable and the cached profile follows once its prerequisites (§2) are in.

## 9. Smaller notes

* §14 cites `idl/rtps_discovery.idl` — exists, correct.
* `realm_id` is an entirely broker-only tenancy primitive with no native meaning; another
  config field that must be rejected-when-irrelevant outside broker mode.
* `broker_epoch` semantics (§5, §7.4) are clean, but an operator broker restart becoming a
  full fleet resync event is an operational property worth stating explicitly, not a bug.
* §13's `startup = require_ready` / `allow_degraded` maps well onto the existing
  `wait_discovery_ready`-style surface; "neither silently enables multicast fallback" is
  the right guarantee.

## 10. Recommended sequencing

1. **Now, in parallel, low rework risk:**
   * Shared discovery codec + strict structural validation + lossless raw-record model
     (`discovery/codec/`). Doubles as the `QosSnapshot` replacement groundwork and the
     XTypes carry-through.
   * Transport channel/session + ingress-context abstraction, justified by the plain
     TCP-data path; `reuse_connection_by_host` disabled for such channels.
   * Continue maturing the broker spec against those two as they take shape. Resolve the
     §8 use-case question. Do not freeze the wire protocol.

2. **After the concurrency-model design task produces a direction:**
   * Broker client threading model and its evented/embedded degradation statement.
   * Decision on slim reliable-stream primitive vs. reuse of `StatefulWriter`/`Reader`,
     informed by the roadmap scaling-cleanup status.

3. **Then:**
   * Tagged `ParticipantStack` construction by `DiscoveryKind`; a minimal
     SPDP-introductions-only broker as the first functional deliverable if §8 lands that
     way.
   * Cached profile, wire freeze with cross-version fixtures, netns test infrastructure.

4. **As those features arrive:** XTypes TypeLookup routing and `opaque_peer` DDS Security,
   per the spec's own phases 5–6.
