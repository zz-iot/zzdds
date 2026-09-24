# Discovery broker v1: implementer entry point

Final design handoff: [scope, completion and remaining gates](specification-handoff.md),
2026-09-24.

Design baseline consolidated 2026-09-23. Read this page first. The public behavior and
protocol direction are settled; the wire profile remains provisional until the explicit
[freeze gates](broker-spec-closure.md#wire-freeze-blockers-and-non-blockers) are cleared.
This package is not a claim of a working broker or deployed wire compatibility.

## Intended behavior

Applications configure ordinary multicast, directed peers and a broker independently.
Broker-only is a preset. One broker authority may offer multiple UDP/TCP addresses;
control transport does not choose user-data transport. The broker distributes original
participant/endpoint discovery information. User traffic and native WLP remain direct.
There is no v1 forwarding/tunneling service, LAN gateway or cross-domain translation.

Scope is standard `(domain_id, domain_tag)`. A shared broker address selects a distinct
logical service participant for each administratively configured scope. Client and service
participant have matching domain identity. Logical participants may share workers/sockets;
no per-scope thread/process is required. Choosing a domain/tag is not authorization.

Directed SPDP introduces immutable participant information and vendor service capability/
request context. Plain UDP validates return reachability through PATH_CHALLENGE/RESPONSE;
already validated paths omit it. REGISTER consumes a bounded validated introduction;
ACCEPT establishes session/endpoint identities. Valid established control confirms receipt.
Fresh origin inventory is required for each new session, independently of downstream resume.

Local matching is independent of broker availability. Default allow_degraded startup
permits local operation while discovery progresses. require_ready is an explicit finite
construction wait and is rejected if the participant would be created disabled. READY
means the defined origin/view/freshness synchronization cut is satisfied, not that all
peers are alive, matched or reachable. Listeners never gate protocol completion.

## Reading order and controlling contracts

| Question | Controlling documents |
| --- | --- |
| Architecture and goals | [Overview](discovery-broker.md), with current details below |
| Runtime, callbacks, waits and lifetime | [Concurrency contract](concurrency-contract.md), [final review](concurrency-final-review.md), [migration plan](concurrency-migration-plan.md) |
| Application configuration/results | [Public API](broker-public-api.md), [API review](broker-public-api-review.md), [readiness](broker-readiness-contract.md), [narrowed resource scope](broker-resource-diagnostics.md) |
| Domain identity and shared service ingress | [Domain identity](broker-domain-identity.md), [multi-domain service](broker-multidomain-service.md) |
| Introduction, admission and endpoint lifecycle | [Sequence](broker-spdp-bootstrap.md), [introduction](broker-service-introduction.md), [inline-context feasibility](broker-inline-context-feasibility.md), [protection](broker-admission-protection.md), [path provider](broker-path-provider-contract.md), [lifecycle](broker-bootstrap-lifecycle.md), [rejection](broker-bootstrap-rejection.md) |
| Per-message legality and effects | [Operation table](broker-operation-validation.md) |
| Inventory, view and presence cross-message rules | [Inventory barrier](broker-inventory-barrier.md), [view correlation](broker-view-correlation.md), [presence completeness](broker-presence-completeness.md) |
| Retry and physical reclamation | [Retry retirement](broker-retry-retirement.md), [retention](broker-retention-review.md), with lifecycle deadlines above |
| Mixed discovery and original content | [Coexistence](broker-discovery-coexistence.md), [origin version](broker-origin-version-wire.md) |
| Bounded decoding and byte ownership | [Storage contract](broker-storage-contract.md), [resource scope](broker-resource-diagnostics.md) |
| Exact proposed bytes and assignments | [Byte baseline](broker-wire-bytes.md), [registry](broker-wire-registry.md), [compatibility review](broker-wire-compatibility-review.md), [metadata/endpoints](broker-wire-details.md), [experimental IDL](schema/broker-control-draft.idl) |
| Review disposition, evidence and remaining work | [Protocol review](broker-protocol-review.md), [closure ledger](broker-spec-closure.md), [implementation checklist](broker-implementation-checklist.md) |

Public ReturnCode rules are not wire error enums. The operation table governs phase and
effects; the registry/schema govern proposed layout. Neither generated decoder behavior
nor an old experiment overrides required validation. If current controlling documents
conflict, resolve and update them before implementation; do not select whichever is easiest.
Chronological counts and "next step" notes are evidence history, not additional requirements.

## Implementation guardrails

* Validate framing, required/unique fields, exact consumption, scope and identity before
  effects. Preserve raw discovery bytes/unknown optional content under explicit lifetime.
* Reserve mandatory outcomes and cleanup before admission. A transport ACK is neither
  COMMIT nor APPLIED; dropping assigned application records requires defined recovery.
* Distinguish unconsumed introduction expiry from result replay, UDP cookie retirement,
  establishment timeout and freshness leases. Duplicates extend none of these.
* Fence by authority/scope/session/generation, not GUID alone. Forget fully retired
  registrations safely; never reconstruct a session from a stale REGISTER or Envelope.
* Honor native domain/enablement rules and independent direct-source evidence. A broker
  withdrawal does not delete a separately justified direct match or invent DDS disposal.
* Use the shared runtime contract. Canonical listener identity, callback exclusion,
  external replacement quiescence and callback-chain non-draining replacement apply.

## Historical material and evidence limits

broker-wire-review.md retains the original R1–R5 reasoning; its old OPEN/credential
alternatives are history. broker-route-authority.md is superseded by direct-only v1 and
future allocated-relay direction. Expanded resource knobs and diagnostic pagination in
broker-resource-diagnostics.md are explicitly deferred. LegacyHello/Challenge/Open types
and their reserved opcodes are not supported messages. Do not implement two handshakes.

Current evidence is 20 codec tests, 49 independent vectors and mechanical coverage of
27 active operations, as recorded after the latest refresh. Older abstract models cover
the states they actually modeled, not the full revised bootstrap. No evidence here proves
public-internet security, native domain-tag implementation, future DDS Security integration,
performance targets or full production concurrency migration.

## Finish line

Use the closure ledger for the remaining wire/profile gates. The next work should resolve
those named gates or implement the documented contracts, not reopen broad concurrency
choices or expand management APIs. A trusted-network implementation cannot be presented
as authenticated public deployment. A consolidated design baseline can be reviewed now;
independently deployed implementations must wait for explicit wire/ABI publication rules.
