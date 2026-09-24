# Concurrency contract: consolidated decision baseline

Status: v1 behavioral implementation baseline, 2026-09-17. This is the reading
entry point for accepted concurrency policy, not a production implementation or ABI
readiness claim. Detailed linked contracts govern operation-specific behavior.
See the [readiness review](concurrency-final-review.md) for scope and outstanding
implementation gates, and [status](concurrency-spec-status.md) for the broker handoff.

## Execution and ownership

Use a common internal progress engine for manual/single-thread and hosted execution.
Contexts execute in bounded turns without permanent worker assignment. Participant
control, individual readers and individual writers have distinct ownership; Publisher
and Subscriber coordinators own their narrow cross-endpoint responsibilities.
Explicit admission states leave room for later assigned-worker scheduling.

Do not hold endpoint/coordinator execution rights or metadata locks through resource
waits, network operations or application callbacks. Eligible inline execution preserves
the low-latency path; listener safety is not disabled by a performance build option.
Internal protocol progress is independent of automatic callback dispatch. Optional
profiles must compile out their exclusive machinery; GROUP-disabled builds do not
inherit group-view state solely to support ordinary operations.

Details: [owner/progress model](concurrency-model.md), [admission](admission-state-machine.md),
[prepared commits](commit-preparation.md), [request lifetime](request-lifetime.md).
The latter's concrete pool/interface proposals are not all frozen by this summary.

## Listeners and application access

Serialize the entity callback domain and identifiable shared listener object, with
explicit grouping available through extensions. Distinct reader listeners under one
Subscriber remain independent. Callback chains retain exclusion while blocking;
nested progress does not automatically dispatch another application listener.

Automatic statuses coalesce by kind, with first-eligible-pending order per source.
Claim consumes the applicable status; later changes survive according to the defined
getter/read/reset rules. Explicit notify_datareaders uses retained reader membership,
current eligibility, attached reader listeners regardless of mask, bounded synchronous
children and dependency-cycle rejection. Missing callbacks preserve pending status.

External listener replacement publishes and drains the retired registration frontier;
callback/preparation chains publish without a drain wait. Deletion uses the accepted
logical-close/application-access distinction and atomic subtree preflight. Recoverable
binding exceptions are contained; preparation validates current state before committing
an invocation attempt. Accepted retry budgets bound preparation churn.

Details: [listener register](listener-execution.md#13-consolidated-decision-register-and-finish-line),
[bulk deletion](listener-bulk-deletion.md), [binding failure](listener-callback-failure.md).
Identity-domain scope and nesting composition are accepted as summarized below.

## Operation completion

Keep effect commitment, result delivery and reference reclamation distinct. Ordinary
context contention is not a failed API precondition. Only specified timed operations
get a blocking deadline; retries never restart it. Close before commitment can fail a
safely recognized lifetime, while close after commitment cannot undo the effect.
Read/take does not wait for future data. Loan return and retained cleanup remain
serviceable during lifecycle coordination. Bindings must distinguish delivery failure
from an operation that never committed.

The [operation-result mappings](operation-result-mapping.md) are accepted as the
mapping direction. The writer/reader variant audits and accepted binding failure contract refine it.
Actual generated conversion and production variant coverage remain implementation
gates, not evidence supplied by scalar models.

| Wait | Accepted scope/completion |
| --- | --- |
| Writer ACK | Fixed committed sequence and relevant association generations; ACK or logical unmatch retires obligations |
| Publisher ACK | Fixed writer membership, independent writer captures, one deadline; outstanding placeholders include uncaptured writers |
| WaitSet | One admitted invocation, live attachments, level observation and retained selected results; close is non-draining; default runtime resolved per invocation |
| Historical data | Known sources, empty-set OK, finite per-association history boundary; protocol accounting plus final DDS processing; missing best-effort evidence can wait until timeout or forever |

Each wait has its own close/departure rules and no general guarantee of arbitrary
application deadlock avoidance. See the [L5 matrix](blocking-wait-matrix.md) and linked
contracts for these distinctions. The reception/admission strengthening task is in
the [roadmap](../roadmap.md#discovery--rtps--transport); implementing it is not required
to finish this specification.

## Runtime and transport baseline

Runtime operational ownership is distinct from storage retention. Participants,
explicit owning runtime handles and explicitly configured factories keep a runtime
operational; default-following factories, the default registry, WaitSets and internal
work do not. The last operational owner initiates automatic retirement. Standard DDS
applications need no runtime shutdown call. Participant creation races retirement
under synchronized lookup/ownership admission and never revives a retiring generation.

Participants retain their chosen runtime; default replacement affects future selection,
not existing entities. WaitSets resolve the default for each admitted invocation.
Implicit default construction/retirement is distinct from an explicit stopped or
disabled selection. Runtime controls and configuration belong on zzdds interfaces.

Retirement transfers a retained obligation from a callback to its outer driver after
unwind. Ordinary manual teardown can exceed a turn budget; explicit nonblocking loop
integration instead retains a registered external progress obligation. Hosted shutdown
must retain an executor without self-joining. Stop recurrence, preserve cancellation
and completion service, and release backend resources before final identity storage.

Ingress must be processed inline, retained or copied within borrowed-buffer lifetime.
Output has explicit accepted/pending/completed/rejected ownership. Completion and
cancellation capacity is reserved independently of ordinary data capacity. UDP can drop
unadmitted datagrams; TCP preserves framing while pausing or explicitly failing the
channel. Shared resources follow actual resource ownership, not runtime identity alone.

Details: [runtime ownership](runtime-ownership.md), [retirement](runtime-retirement.md),
[transport/runtime boundary](transport-runtime-contract.md). Their bounded models
validate selected ordering properties; concrete backend implementation remains untested.

## Listener refinements and final review

The [readiness review](concurrency-final-review.md) closes the R1/R2/R3 policy gaps:
borrowed resources use retained anchors or tracked completion fences, RuntimeOwner
and RuntimeRef distinguish operational leases from observation, and prepared access
separates commitment from output delivery failure. Physical ABI support remains gated.

The [identity decision package](listener-identity-decision.md) is accepted: one domain
per shared core registry, binding-specific canonical identities separate from dispatch
context, creation-time positive finite participant nesting limits (build default eight),
and the minimum limit among active participants and the destination. Cross-runtime
calls preserve chain depth; distinct core copies do not silently share exclusion.

The [migration and acceptance plan](concurrency-migration-plan.md) orders production
work. The [bootstrap contract](runtime-bootstrap-contract.md) defines accepted descriptor
validation, rollback, resource ownership and clock compatibility. External attachment
precedes participants/I/O; live executor replacement is outside v1. Manual/hosted
implementations preserve the same listener and effect guarantees.

## Evidence and implementation boundary

Bounded models cover admission/commit, retirement, delegation, status, deletion,
result leases and wait races. Each proves only assertions within its finite abstraction;
counts across models are not integrated coverage or a production correctness proof.
Use the linked validation notes for scope and negative controls.

Production gates include real binding lifetime/exception transfer, operation-specific
error mapping, default lookup/retain versus shutdown, generation-safe wake and timer
publication, transport backpressure, malformed-input/resource fault injection, manual
and hosted progress tests, optional-profile builds and latency/size measurements.
Do not invent measured performance or size savings from the abstract architecture.

The final consistency review is recorded. Next reconcile the broker specification;
it need not await production refactoring or a complete MCU port.

## Extension surface consolidation

The [extension inventory](concurrency-extension-surface.md) separates accepted
ownership/default behavior and the selected writer-configuration, listener-group and
manual-driver surfaces from concrete ABI publication work. All new public entity controls belong in zzdds.idl.
The [reader audit](reader-variant-results.md) records accepted strict next-instance
advancement and implementation precondition/provenance requirements.
