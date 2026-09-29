# Concurrency and discovery broker specification

This is the single entry point and decision index for the concurrency/broker design.
The contracts below describe an implementation baseline. They do not claim a migrated
production runtime, a working broker, frozen ABI/wire compatibility, or measured latency
and MCU footprint. Historical investigations are explicitly non-normative.

## Contracts and responsibility

| Subject | Authoritative home |
| --- | --- |
| Execution ownership, admission, reservations, progress and fast paths | [Concurrency architecture](concurrency/architecture.md) |
| Listener identity, ordering, preparation, delegation and quiescence | [Listeners](concurrency/listeners.md) |
| Read/take, effects/results, ACK/history/WaitSet waits and variants | [Operations](concurrency/operations.md) |
| Runtime ownership, bootstrap, resources, driving, retirement and transport | [Runtime](concurrency/runtime.md) |
| Non-OMG concurrency configuration and API declarations | [Extension API](concurrency/extension-api.md) |
| Broker purpose, deployment scope and implementation sequence | [Broker overview](broker/overview.md) |
| Bootstrap, admission, transactions, freshness, retirement and operation legality | [Broker protocol](broker/protocol.md) |
| Encoding, assignments, metadata, versioning and byte ownership | [Broker wire](broker/wire.md) and [experimental schema](schema/broker-control-draft.idl) |
| Broker Config, status, readiness, diagnostics and enablement | [Broker API](broker/api.md) |
| Insecure v1, future secure cached mode, disclosure and continuity | [Security and filtering](broker/security-and-filtering.md) |
| Native/broker coexistence, domain identity and origin revisions | [Coexistence](broker/coexistence.md) |

The subject contracts own behavior; the API documents own declaration/default spelling;
the schema owns provisional numeric assignments. Examples and implementation approaches
must preserve those rules but do not select one internal container or scheduler algorithm.
Source snapshots and superseded proposals in `archive/` explain history only. If a future
implementation exposes a contradiction, resolve the named rule instead of silently choosing
an easier behavior or reopening unrelated architecture.

## Accepted review decisions

| Decision | Contract |
| --- | --- |
| D1 | After ordinary validation, VOLATILE, BEST_EFFORT and empty-known-source historical waits return OK with no receipt guarantee. Warn once per entity for best-effort history/ACK waits. Record the behavior change when implemented. |
| D2 | Optional single-use registration continuity capability is v1.1. Bind it to scope/GUID/incarnation/current registration; rotate on replacement. No SPDP token, permanent ownership registry or v1 live takeover. Lost replacement outcomes need their v1.1 protocol. |
| D3 | UDP bootstrap stays unfragmented. Preflight complete messages; diagnose local oversize and offer explicit interface restriction/TCP configuration. No stripping, hidden fragmentation or transport fallback. |
| D4 | Operator disclosure ceiling comes first; clients may require conservative topic/partition candidate filtering and refuse unsupported service. No silent ALL fallback or type/QoS suppression of diagnostics. |
| D5 | V1 is insecure cached discovery. Future secure broker operation derives from participant DDS Security, including explicit vendor-endpoint protection and UDP/TCP evidence. No separate required TLS/DTLS-first credential API or plaintext fallback. |
| D6 | Cached mode first, including eventual trusted secure caching; peer identity/permissions/user-data protection remain independent. Opaque mode and relays are later work. |
| D7 | Foreign-path failed take restores eligible retained claims, allowing temporary invisibility/NO_DATA. It never resurrects expired/evicted/deleted data or an old access bracket. |
| D8 | Foreign selection-time READ/NOT_NEW effects survive failure; cleanup does not overwrite lifecycle rebirth. Binding users receive the NOT_READ/NEW limitation and ANY-state recovery guidance. |

Other settled directions: take-turns participant/endpoint contexts; shared manual/hosted
runtime; callback exclusion without mandatory worker hops; ordinary hosted callers do not
help; GROUP-only Publisher tickets; retained TOPIC seal work with per-set completion
capacity; optional profiles remove exclusive machinery; standard DDS APIs keep useful
defaults and automatic last-owner runtime cleanup. Non-OMG public controls belong in
zzdds.idl. Broker WLP and user traffic remain direct in v1.

Draft 3 uses ordered STATE transactions/aggregate freshness, final established bodies,
mutable bootstrap and retained-baseline identity without transaction digests. Original
SPDP/SEDP bytes and bootstrap correlation hashes remain. Delayed reductions cannot
retroactively revoke observer grants before delivery. Fairness, storage and output remain
bounded independently of these wire simplifications.

## Implementation and publication gates

| Gate | Evidence required before the associated claim |
| --- | --- |
| Concurrency | Real queue/publication/memory-order correctness, cancellation, callback exclusion, claim restoration, conditions, manual/hosted retirement and bounded fairness |
| Optional presentation | Actual TOPIC markers and repair; GROUP coherent visibility, history/lifespan interactions and incomplete-set handling. Concurrency invariants do not supply the entire optional wire profile. |
| Bindings and ABI | Generated zzdds.idl extensions, generic zidl reference/Config ownership, nil/default/error behavior, mixed file configuration and language exception/cleanup tests |
| Broker introduction | Recipient-specific inline SPDP context with unchanged canonical payload; both transport ingress paths, domain ID/tag, bounded whole-message sizing and same-source replies |
| Parsing/storage | Required/unique mutable members, exact final extent, malformed/oversize nested bodies, retained bytes, allocation failure, bounded reassembly and native peak-memory accounting |
| Broker state machine | Loss/reorder/duplicate/expiry tests across PATH/REGISTER/inventory/view/freshness/close, retained resume identity, local activity during outage and direct-source coexistence |
| Deployment | Rate/CPU/storage abuse bounds, entropy/path-provider behavior, filter correctness, platform coverage and measured latency/footprint/scale |
| Publication | Explicit assignment/version review after wire-affecting findings; independent peer compatibility before frozen wire/ABI promises |

The first implementation slice is a bounded reliable reader/writer pair with manual and
hosted progress, listeners, waits and automatic retirement. Broker integration can proceed
against the same ownership interfaces without waiting for every optional profile. Start
with one scope, fresh inventory, view/readiness, reconnect and local matching during outage;
then implement required candidate filtering and both advertised control transports.
No automatic authorization to refactor production or publish releases follows from this index.

## Evidence and review provenance

[Test/design-models/README.md](../../test/design-models/README.md) is the sole current
inventory of executed checks, counts, fixture sizes and limitations. Maintained model and
wire checks run separately from production tests. Historical Python models are in
[the consolidation archive](archive/consolidation-2026-09-29/README.md), next to source notes.
Do not aggregate independent model counts into a full-system correctness claim.

The root [revision review](../../concurrency_and_broker_spec_revision_review.md) and
[reply](../../concurrency_and_broker_spec_revision_review_reply.md) record the consolidation
scope, review dispositions and packaging recommendations. Commit/PR splitting is process
work recorded there; there is no second design-status or merge-preparation ledger.
