# Broker specification closure ledger

Status: agreed review revisions complete, 2026-09-28. The draft is an implementation
baseline, not frozen interoperability or a working broker.

| Area | Settled specification |
| --- | --- |
| Public behavior | Config-based extension creation, ordinary DDS defaults, allow-degraded startup, finite require_ready, same-participant independence, status/readiness/lifetime |
| Admission | Directed SPDP/PATH/REGISTER; insecure v1 GUID identity; finite path/introduction/result horizons; no live takeover, no permanent identity ban |
| Graph | Original SPDP/SEDP retention, standard domain ID/tag, operator disclosure ceiling, required topic/partition candidate capabilities |
| State and freshness | Ordered STATE transactions and aggregate markers, adaptive bounded exceptions, fixed synchronization cuts, conservative clock grants and explicit delayed-reduction limits |
| Encoding and resume | Draft 3 final established bodies/Envelope, mutable bootstrap, exact assembly without transaction digests, full retained-baseline identity |
| Runtime | Shared take-turns runtime; bounded reconciliation and independent recovery; accepted listener/ownership rules |
| Future scope | DDS Security-derived cached mode first; optional v1.1 continuity; opaque mode, relays and traversal later |

## Wire-freeze blockers and non-blockers

Before publishing wire 1.0, demonstrate directed inline introduction and transport plumbing,
strict parsing/borrowed storage, path-provider bounds, and exact independent compatibility.
Recheck provisional assignments after any wire-affecting finding. The complete
[implementation checklist](broker-implementation-checklist.md) names those tests.
Performance/default tuning and production integration are delivery work, not unresolved
architecture. Future secure-mode integration is a gate for that feature, not insecure v1.

## Evidence

23 generated codec tests, 53 independent vectors and all 27 registry/operation mappings
pass. The bounded freshness model explores 2,340 states; additional adaptive-clock and
resume-identity traces cover named requirements. These are not a complete protocol proof.
See [the validation inventory](../../test/design-models/README.md) and
[review decisions](review-decisions.md) for exact scope. The former closure ledger is
[archived](archive/review-baseline/broker-spec-closure.md).
