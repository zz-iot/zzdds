# Broker resource bounds and failure reporting: v1 scope

Status: narrowed v1 scope accepted, 2026-09-18. Specification only. The larger API
proposal below is deferred, not required to finish v1.

The [storage contract](broker-storage-contract.md) defines the required internal accounting
and byte-ownership rules without reviving the deferred public tuning APIs below.

## Required for v1

Discovery storage, pending work and cleanup are bounded. Reuse the common runtime's
resource ownership and existing configuration where practical. Reserve announcement,
completion and failure bookkeeping before accepting the work that needs it. Exhaustion
cannot silently discard required records, removals or unresolved failure state. Control
progress and retirement must remain possible when data queues are full.

Finite build/platform defaults and checked conversion/aggregate limits are required.
Derive wire ReceiveLimits from a feasible native storage plan; serialized bytes are not
a proxy for native memory consumption. Peer negotiation cannot enlarge local capacity.
Actual numeric defaults, derivation and supported scale must be documented and validated
with the implementation. This does not require six new public tuning knobs or a dedicated
resolved-resource-plan API. Expose additional settings only for a concrete deployment need.

Retain the accepted non-resetting participant discovery-status getter, readiness wait and
optional coalesced listener. A locally successful endpoint creation can later fail broker
registration without invalidating the local entity. Its unresolved advertisement failure
must remain observable in summary status and affect readiness as already specified.
Pending ordinary work is not failure, and READY is not a per-endpoint registration barrier.

Use bounded, rate-limited diagnostics/logging for affected entity GUID, origin revision,
operation and failure reason when known. No arbitrary remote strings or credentials are
required. Logs are not the authoritative error store and may coalesce; summary status may
not claim healthy synchronization merely because a log entry was dropped or no listener
is installed. Session-wide failures must not fabricate one rejection per local endpoint.

Retain internal unconfirmed-removal and recovery obligations after endpoint deletion until
commit, withdrawal or ownership fencing proves retirement safe. This requirement does not
imply retaining the deleted DDS object or exposing every obligation through a public API.
Clear failures only through the relevant generation's repair/retirement decision; stale
session completions cannot clear or recreate current errors. Existing callback, wait and
output ownership contracts apply without a new execution mechanism.

## Explicitly deferred

* The six-field BrokerResourceLimits public configuration group.
* A dedicated ResolvedBrokerConfig resource-plan getter.
* Per-record failure enumeration, cursors, retained diagnostic snapshots or restartable pages.
* New per-endpoint diagnostic listeners or registration barriers.

The v1 application can detect discovery failure and use bounded diagnostics to investigate;
it is not promised programmatic enumeration of every affected entity. These conveniences
may be added later without changing the core admission or reliable-delivery guarantees.

## Earlier expanded proposal — deferred reference only

The material below records design options, not active v1 requirements. Its suggested
getters, limits and pagination behavior must not be implemented merely to close W1.

## One resource plan, two kinds of limit

Broker discovery needs participant-local capacity ceilings as well as the runtime's shared
allocator and execution capacity. They are not independent memory pools by default.
Use the existing runtime/resource owner for actual storage; charge broker work to a
participant discovery resource scope within it. A configured ceiling is a maximum, not
a promise that shared backing resources will always be available.

Recommend a small application-facing BrokerResourceLimits group, embedded in broker Config:

| Optional field | Meaning |
| --- | --- |
| max_local_records | Current origin records plus retained removal/replacement obligations; participant and endpoint records both count |
| max_remote_records | Unique installed/staged remote records, counting retained distinct revisions during replacement |
| max_pending_operations | Admitted origin mutations/transactions awaiting completion or retirement |
| max_local_bytes | Broker-specific retained origin bytes, transaction/retry state and their diagnostics |
| max_remote_bytes | Broker-specific installed/staged view, presence and retained-revision state |
| max_control_bytes | Introduction/session/control/reassembly/output state, including progress/retirement reserve |

Counts and byte ceilings both apply. Define bytes in terms of charged native storage,
including indexing/metadata, not just serialized payload. These are discovery budgets,
not reader/writer user-sample history limits. Shared physical allocations are charged once
to a designated owner and retained until last use; moving a reference does not silently
escape accounting. Cross-source graph allocations shared with direct discovery must also
fit the common graph limits. A broker limit cannot evict still-valid direct-source evidence.

The exact typed fields should be optional unsigned long long values with checked native
conversion; zero is invalid for an enabled service. Unset selects build/platform defaults.
Limits cannot increase implementation/wire ceilings or permit arithmetic overflow.
Do not expose every ReceiveLimits wire member as a second application configuration tree.
Instead derive a feasible receive plan from these limits, transport frame bounds and local
record sizes. The implementation documents that derivation and reports its resolved plan.
A future expert override can be added without making it necessary for standard DDS use.

Wire byte limits count protocol bytes, not native bytes. Derivation must account for decoded
storage, simultaneous frames, staged view replacement, presence chunks and bounded output.
Advertising a maximum record/frame is not proof that every maximum can occur simultaneously;
aggregate transaction limits remain enforceable. Peer-proposed limits can reduce permitted
traffic, never enlarge local capacity. A peer limit too small for required local inventory
produces an explicit synchronization failure, not silently missing endpoints.

Reserve minimum control/completion/failure capacity at local creation. If it cannot be
reserved, fail construction even under allow-degraded. Before accepting endpoint creation
or a local update, reserve its required announcement bookkeeping; rejection before local
commit uses existing DDS return conventions. Shared-runtime scarcity later follows the
accepted bounded recovery/error policy. Full data queues cannot consume the reserved
capacity needed to record failures, terminate transactions or retire sessions.

A smaller budget is not permission to discard an assigned reliable record or unconfirmed
removal. Coalesce unsent work when allowed; otherwise refuse admission or use a fenced
fresh synchronization. Capacity-reducing live reconfiguration is out of v1. Broker server
administrative quotas are separate: per-scope/per-principal ceilings plus global limits.
A large client advertisement does not oblige the server to reserve unlimited resources.

## Defaults and resolved configuration

Keep the accepted behavioral defaults: ordinary SPDP when unconfigured; broker view ALL;
allow-degraded startup; explicit security policy when broker enabled; direct-only traffic.
Numeric capacity and timeout defaults remain finite, published build/platform values with
build-time overrides. This specification requires their validation and observability; it
must not turn an unmeasured memory size into a portable implementation promise.

Resolution order: generated build/platform defaults, configured factory defaults, then
explicit fields supplied through the established Config merge rules. Do not introduce a
second broker-only interpretation of omitted fields. Freeze the resolved plan at creation;
factory changes affect future participants. Protocol negotiation and current transport
conditions are observations, not mutation of the original application configuration.

Add a non-resetting zzdds participant getter returning a copied, bounded
ResolvedBrokerConfig: enabled state, selected behavioral settings, six local resource
limits, effective bootstrap deadlines/frame ceilings and the local derived ReceiveLimits.
It excludes credentials, handles and mutable runtime internals. Local resolved maxima and
peer-negotiated maxima must be labeled separately; negotiation can change across sessions.
The getter does not wait for a broker or require a listener. Binding result publication
and failure preservation follow the existing Config/output contract. Exact IDL composition
is a follow-up to acceptance, not another user-visible tuning choice.

The spec completion gate is concrete resolution rules, units, failure behavior and minimum
provider constraints. Publishing actual numeric defaults and proving the advertised memory
plan are implementation gates. require_ready always has a finite startup timeout; later
explicit infinite waits remain allowed. Retry backoff never extends a wait deadline.

## Current registration failures, not an event log

Recommend a bounded participant-level page getter for unresolved local record failures,
using the existing status listener only as a coalesced notification that state changed.
No per-writer listener or additional DCPS StatusMask is needed. This also covers endpoint
removals after the originating DDS object has been deleted.

Each diagnostic entry is a value containing:

* participant incarnation, record kind, entity GUID and affected origin revision;
* operation kind (UPSERT/REMOVE/inventory-level), bounded failure category and local/remote
  attribution; no arbitrary remote diagnostic string;
* evidence session/owner generation, retry-pending flag and participant status revision
  at the last change. Session-wide failures remain in the summary, not copied per endpoint.

These fields identify protocol obligations, not borrowed entity pointers or a promise that
the entity is still alive. An inventory-wide failure without a trustworthy record identity
uses an explicit inventory-level entry; do not invent per-record blame. Endpoint QoS/type
matching incompatibility is not broker registration rejection and retains DDS status rules.

Reserve diagnostic bookkeeping with the work it describes. At most one current entry per
retained failing obligation/revision; no unbounded list of repeated retry errors. Older
failure remains while its obligation still exists, even if a newer local revision is pending.
It clears only on a generation-checked repair/commit, confirmed withdrawal, or retirement
that proves the obligation no longer exists. A timeout or listener invocation does not clear
it. A separate historical log may drop/coalesce entries; current unresolved state may not.

An old-session rejection cannot fail new-session work merely because GUID/revision match.
Reconnection may change a known failed obligation to pending repair once the old ownership
is conclusively fenced, but cannot claim the new inventory has committed. Ready/pending/
rejected counts and diagnostic changes are published coherently. The summary alone remains
sufficient to detect unresolved failure when the application never requests details.

## Bounded enumeration proposal

Use caller-selected page capacity up to a fixed generated bound and a small value cursor.
The first request captures the current diagnostic-set revision; each subsequent request
supplies it and the last returned stable key. Return entries in deterministic key order.
All pages within that revision are coherent. If the set changes between pages, report an
explicit RESTART_REQUIRED page outcome; do not mix generations or retain server-side
snapshots indefinitely. Pagination has no remote round trip and pins no deleted entities.
The revision changes only when diagnostics change, not on unrelated phase/lease updates.

A single page is copied atomically under participant admission, then published using the
shared output contract. Invalid capacity/cursor returns BAD_PARAMETER; recognized close
returns ALREADY_DELETED; allocation failure returns OUT_OF_RESOURCES, leaving caller output
unchanged. RESTART_REQUIRED is a successful local observation with empty entries and a
fresh enumeration start, not a generic DDS error or a hidden blocking retry loop.
Under continuous diagnostic churn a full scan may repeatedly restart; summary status and
individual pages still work. This deliberate v1 limitation avoids retained diagnostic
snapshot pools. A cursor is not a credential and cannot reference another participant
lifetime; validate lifetime identity as well as revision/key.

Initial proposal: `get_discovery_failures(request, inout page) -> ReturnCode_t` on
zzdds::DomainParticipant, with bounded value-only request/page types. Page rows describe
current state, not a new registration barrier. Their output ownership is generated normally;
no callback-bound pointer, adapter identity parameter or manual free convention is added.

## Acceptance traces and next review

* Broker unavailable at startup: local entities work; summary reports transport/backoff;
  no fabricated per-endpoint rejections fill the diagnostic budget.
* Broker rejects one writer revision: writer remains locally valid; current failure is
  visible without a listener and readiness reflects the unresolved advertisement failure.
* Writer is deleted before removal commits: GUID/revision diagnostic remains inspectable
  without retaining the writer object; retirement removes it only when justified.
* New revision/session repairs the record: stale rejection cannot overwrite repaired state.
* Failure storage is full: new work cannot be admitted without its bookkeeping reservation.
* Diagnostics change during enumeration: explicit restart, no falsely coherent merged page.
* Participant shares a runtime: its local ceilings do not silently increase shared capacity
  or steal another participant's guaranteed progress reserve.

Review the compact resource-limit group and restartable current-failure enumeration before
finalizing IDL. No prototype or production change is needed to choose this contract.
