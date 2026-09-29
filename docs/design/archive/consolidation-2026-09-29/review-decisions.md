> Historical source snapshot, superseded by the consolidated contracts.
> Unaccepted alternatives and old completion statements below are not current policy.

# Review decisions and revision status

Status: agreed specification revisions complete, 2026-09-28. D1–D8 and review
dispositions are incorporated. Implementation/publication gates remain explicit; bounded
models do not establish production correctness.

| ID | Required direction | Scope |
| --- | --- | --- |
| D1 | VOLATILE, BEST_EFFORT and empty-known-source historical waits return OK after ordinary validation. Warn once per entity for best-effort historical wait and best-effort writer ACK wait. | v1; immediate success means no obligation, not receipt |
| D2 | Optional single-use registration continuity token, requested in REGISTER and returned in ACCEPT; rotate on replacement; no SPDP token or permanent ownership registry. | v1.1; not v1 blocker |
| D3 | Unfragmented UDP bootstrap; clear local oversize diagnostics naming interface restriction/TCP; no silent downgrade. | v1 |
| D4 | Operator disclosure ceiling; conservative topic/partition candidate filtering within it; clients may narrow or require filtering and refuse unsupported brokers. | zzdds broker v1 |
| D5 | Traditional insecure v1. Secure broker mode derives from eventual DDS Security, not a separate TLS/DTLS credential API. UDP path validation precedes expensive authentication. | Secure support gated on DDS Security |
| D6 | Cached discovery first, including future trusted secure caching; peer authentication remains independent. Opaque profile later. | v1 cached, insecure |
| D7 | Failed foreign-path take restores still-eligible claims; temporary invisibility is accepted. | Access contract |
| D8 | Foreign-path READ/NOT_NEW effects survive conversion failure; document ANY-state retry and its limits. | Access contract |

## Mechanism dispositions

* Default INSTANCE write must not inherit GROUP coordination. TOPIC coherent close needs
  retained sealing work and bounded capacity across successive unacknowledged sets.
* Certified non-reentrant access uses prevalidated/preallocated conversion; general foreign
  access uses claims, retained state effects and restoration. No optimistic retry budget.
* Hosted ordinary callers do not help by default; callback-chain waits and manual progress
  retain bounded internal helping. Background recovery never depends on a readiness waiter.
* Use ordered STATE boundaries/records and compact session-bound envelopes.
* Aggregate nonce-correlated freshness on STATE replaces chunked presence; exact frontiers,
  adaptive bounded exceptions, conservative clock grants and delayed reductions are explicit.
* Consolidate normative requirements and archive obsolete reasoning; maintained models use
  dedicated validation targets. Separate real SPDP/zidl fixes during merge preparation.

## Revision ledger

| Work | Status |
| --- | --- |
| D1 historical contract, D7/D8 access and result mapping | Complete; native/foreign split, retained state effects, eligible claim restoration, user binding limitation and migration notes |
| Fast paths, helping, cooperative profile | Complete; GROUP-only tickets, retained TOPIC sealing/reservations, hosted ordinary no-helping, bounded fairness and memory worksheet |
| D3–D6 API/security/filtering | Complete; insecure v1, DDS Security-derived future cached mode, operator ceiling and required topic/partition capabilities; unfragmented UDP diagnostics |
| Bounded mechanism validation | Review traces/models pass; 363 additional claim/condition schedules, 7 nested/multiwriter traces and 256 clock/horizon cases; exact scope in validation inventory |
| Wire/schema/fixtures | Draft 3 reconciled; 23 codec tests, 53 independent vectors, 27 operation mappings; 22 baseline identity checks and 2 shortcut counterexamples |
| Normative consolidation | Complete for review-affected contracts; obsolete investigations/ledgers archived with current-contract links |
| Validation targets | Dedicated Python runner and design CI; Zig prototypes removed from production test/coverage/TSan aggregates |
| Production-fix separation | Two reviewable patches and release-note scopes extracted; actual commit/PR split remains user-controlled packaging, not spec work |

The [validation inventory](../../../../test/design-models/README.md) is the evidence source.
[The handoff](specification-handoff.md) defines the finish line and
[merge preparation](review-merge-preparation.md) distinguishes existing production fixes
from these documentation/schema/model changes. No new production behavior is claimed.

## Refinements resolving review counterexamples

* Reserve marker completion capacity before a set's first effect; one command slot does
  not imply enough history for multiple unacknowledged markers. Bounded retained membership
  scanning and writer-local sealing complete sets even with no later write.
* Restore retained cache samples after foreign failure without reopening a closed GROUP
  view or undoing READ/NOT_NEW/later lifecycle state. Cache restoration and old-view
  consumption rollback are different operations.
* A later broker lease reduction cannot retroactively revoke an observer grant before
  delivery. Ordered STATE bounds the effect when applied; control health is not freshness.
* Freshness submits one logical query on reliable CONTROL. Transport repair retains its
  sequence/bytes; timeout uses a new nonce. Bounded server result history survives client
  abandonment, so new work may receive LIMIT. No serial/chunk replay cache returns.
* Final positional encoding requires exact selected grammar. A cursor resolves retained
  full identity, scope/policy/history; counts and ordering are explicitly not a checksum.

## Encoding/digest review checkpoint

The [generated comparison and digest audit](broker-encoding-and-digests.md) select final
established bodies/Envelope, mutable bootstrap, and removal of inventory/snapshot digests
with strict retained-baseline identity validation. Bootstrap hashes and raw-byte retention
remain. The historical three-way comparison passed; draft-3 schema and generated codec
migration now pass. See that disposition for current sizes, validation bounds and the
completed document reconciliation.
