# Broker specification closure ledger

Status: design baseline handoff, 2026-09-24. This is the current disposition of the
specification effort, not a claim of implemented broker support or frozen interoperability.

## Settled baseline

Concurrency behavior and migration direction remain settled within concurrency-final-review.md.
Broker v1 is cached discovery over configurable UDP/TCP, independent of ordinary directed/
multicast discovery, with same-participant local activity preserved. It uses standard domain
ID/tag and one logical service participant per served scope. WLP and user traffic remain
direct. Allocated relays, DDS Security protected-discovery integration, federation and
additional management APIs remain explicitly outside initial implementation scope.

| Item | Specification disposition | Remaining gate |
| --- | --- | --- |
| W1 Public behavior | Reviewed: Config-based creation, defaults, enablement, readiness/status/listener, return/lifetime rules; extra diagnostics/resource APIs deferred | Integrate declarations with generated IDL/ABI and validate bindings/default mapping before public API publication |
| W2 Operation semantics | 27 active operations accounted for; first admission vs retry, record scope/dependencies and phase-specific failures reconciled | Final independent-implementation read-through; implementation transition/negative-input tests |
| W3 Retention | Introduction/result/cookie horizons separated; ordered presence serials; registration-scoped close, bounded withdrawal/history, no identity blacklist | Implement accounting and expiry/fencing tests; old abstract model is not evidence for the full current handshake |
| W4 Bootstrap lifecycle | SPDP/PATH/REGISTER, endpoint confirmation, deadlines, whole-message preflight and oversize failure specified | Validate recipient-specific inline QoS, shared service ingress, transport/protection overhead and source-path behavior |
| W5 Byte compatibility | Concrete draft schema, direct vs enveloped body mapping, hashes, domain-tag strings and provisional registries; fixture evidence recorded | Deliberate assignment/profile freeze after the wire-affecting checks below |

W1–W4 behavioral decisions do not require more broad prototypes. Their implementation gates
must not turn into new API features. W5 is deliberately not labeled frozen.

## Wire-freeze blockers and non-blockers

1. **Introduction transport feasibility:** demonstrate recipient-specific SPDP inline context
   without changing canonical participant payloads per recipient. The
   [source review](broker-inline-context-feasibility.md) retains inline context with bounded
   internal extensions; send/receive integration evidence remains pending. A dedicated
   introduction sample would require a wire revision, not an automatic fallback.
2. **Protected/path profile:** the [provider contract](broker-path-provider-contract.md)
   now specifies the proposed bounded stateful-cookie baseline, validation/expiry/replay
   behavior and protection boundary. Provider and abuse-test evidence remains pending. Cookies are opaque to clients, so provider
   internals need not be a common client ABI; their size and path-binding contract must hold.
   Do not advertise public authenticated deployment or future DDS Security compatibility
   without its corresponding integration evidence.
3. **Assignments and compatibility:** the [assignment review](broker-wire-compatibility-review.md)
   checks active/reserved namespaces, member IDs, version boundaries and unknown-field rules.
   No renumbering resulted; production allocator/parser enforcement remains to be tested. A generated decoder's acceptance is not authority to omit required/duplicate
   member validation. Fix any wire-affecting discovery before frozen version 1.0 publication.
4. **Schema/implementation agreement:** the [storage contract](broker-storage-contract.md)
   specifies borrowed validation views, bounded immutable ownership, overlap accounting
   and generic generator requirements without changing wire layouts. Concrete mappings,
   exact byte agreement and peak-memory measurements remain implementation gates.

Actual performance numbers, production scheduler migration, default-capacity tuning and
full network/cross-binding regression execution are release/implementation gates, not
reasons to keep rewriting the design. Native domain-tag support is a required delivery
prerequisite. No additional implementation work is authorized merely by this ledger.

## Evidence and next deliverable

Current evidence: 20 codec tests and 49 independent byte/hash vectors passed after the
2026-09-23 refresh; all 27 active opcode/name pairs match the admission table. This final
editorial/scope/error pass changed no wire bytes and did not rerun network tests.

The [final handoff](specification-handoff.md) now separates settled behavior, concrete
implementation directions and remaining evidence. No additional product-policy decision
was identified. The directional design effort is complete; the gates above govern
implementation validation and compatibility publication, not another broad design cycle.
