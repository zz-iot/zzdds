# Concurrency and broker specification status

Status: agreed review revisions complete, 2026-09-28. Start with the
[handoff](specification-handoff.md) and [review decisions](review-decisions.md).

| Deliverable | State | Next milestone |
| --- | --- | --- |
| Concurrency behavioral contract | Accepted and reconciled, including D1/D7/D8 and fast-path specialization | Production vertical slice and generated binding validation |
| Broker behavioral and wire draft | Accepted and reconciled, draft 3 independently encoded | Client/server integration and deliberate wire freeze |
| Production/runtime/MCU support | Separate implementation work | Measured functionality, latency, memory and platform evidence |

The goal remains a generally useful configurable discovery mechanism, not a ROS 2-specific
product. Optional profiles compile out exclusive state; no claim that GROUP-disabled
builds need no ordinary lifecycle/history synchronization. Non-OMG controls belong on
zzdds.idl extensions with reasonable standard-API defaults.

Read [concurrency contract](concurrency-contract.md), [fast paths](concurrency-fast-paths.md),
[access/failure](prepared-read-conflicts.md), [API](concurrency-api-draft.md), then the
[migration plan](concurrency-migration-plan.md). For broker work use the
[implementer guide](broker-spec-guide.md), [closure ledger](broker-spec-closure.md) and
[implementation checklist](broker-implementation-checklist.md).

The [old status log](archive/review-baseline/concurrency-spec-status.md) preserves the
investigation chronology. Its old next steps and model counts do not reopen decisions.
