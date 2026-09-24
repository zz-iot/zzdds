# Admission and request state transitions

Status: draft for discussion, 2026-09-10. The scheduling policy and shared runtime are agreed in [concurrency-model.md](concurrency-model.md); the representation and transitions here are proposed. This document specifies internal behavior, not public IDL or production guarantees. A test-only implementation now exercises a subset; see the [integrated review](concurrency-prototype-review.md). See [validation traces](admission-validation.md).

## 1. Separate state dimensions

Do not combine execution, lifecycle, resource ownership and API outcome into one enum. A closing context can still execute; a resource-reserved request can still be queued.

| Object | State dimension | Values |
| --- | --- | --- |
| Context | Lifecycle | OPEN, DRAINING, CLOSED |
| Context | Execution | IDLE, SCHEDULED, RUNNING |
| Request | Placement | NEW, READY, RUNNING, WAITING, RETIRING, DONE |
| Request | Effect | UNCOMMITTED, COMMIT_CLAIMED, COMMITTED, ABORT_CLAIMED |
| Request | Owned resources | Explicit payload/reference, reservation, ticket and completion-credit records |

SCHEDULED means one service obligation exists for a nonexecuting context. It need not mean a particular queue implementation. RUNNING can have a nonempty FIFO behind its executor. CLOSED means no remaining protocol work, not that all externally retained storage has been reclaimed.

## 2. Context admission and turn completion

All transitions below require a common admission synchronization protocol. A short gate is the baseline conceptual model; an atomic optimization must preserve the same ordering. Never invoke application code or block while holding the gate.

| Event | Preconditions | Transition |
| --- | --- | --- |
| Direct submission | OPEN, IDLE, no older ready work, runtime inline budget permits | Retain request; claim RUNNING and execute its first turn |
| Queued submission | Lifecycle permits operation, pending-storage credit available | Append READY at tail; if IDLE, make SCHEDULED and publish service obligation |
| Driver claim | SCHEDULED | Atomically claim RUNNING and remove oldest READY request |
| Turn yields runnable work | RUNNING | Append continuation at tail; relinquish owner and schedule remaining work |
| Turn waits | Predicate registered; RUNNING | Request becomes WAITING; relinquish owner and schedule other ready work |
| Turn finishes | Result/cleanup progress recorded; RUNNING | Release turn; SCHEDULED if FIFO nonempty, otherwise IDLE |
| Internal continuation during drain | DRAINING and continuation belongs to retained admitted operation | Admit using reserved internal credit; normal FIFO service |

A small batch may retain the executor between turns within a finite budget, always serving the oldest ready request. It must eventually return service to the runtime. Idle-check plus direct claim, enqueue plus scheduling, and owner-release plus ready detection must not have separate unsynchronized gaps. Newcomers cannot steal a scheduled context's turn by observing that no executor currently holds it.

Runtime queue publication must itself be allocation-free after admission. A design may use an embedded ready node or an explicit publication handshake; context-gate/runtime-gate ordering and the precise handshake must be specified before implementation. Do not assume two independent queue/flag stores establish the invariant.

## 3. Resource waits and reservations

Under the resource owner's rights, check eligibility and either reserve resources or register a waiter before releasing ownership. Wait records retain request identity and a wait-generation number. Resource release services the oldest eligible waiter, reserves its required resources, then makes its continuation READY. Wakeups for an obsolete wait generation are ignored without releasing a newer reservation.

A reservation has one owner and is consumed by commit or released by cleanup exactly once. New callers cannot use reserved capacity. Waiters stay within the configured pending-request budget even though absent from the ready FIFO. Multi-owner resource acquisition must release partial reservations or follow an audited acquisition protocol; fairness alone does not prevent a cycle of mutually held reservations. Exact eligibility and bounded waiter scanning remain open.

For cross-context notifications, the producer retains a preallocated completion record and publishes evidence; the destination applies it under its own rights. It does not mutate the destination's private protocol state directly. An operation can have several internal steps, but at most one executor advances its mutable continuation state at once.

## 4. Commit, cancellation and result delivery

Preparation, ready admission and resource reservation do not mean API success. Each operation defines an effect boundary. For a write, the proposed boundary is the irrevocable acceptance of its prepared change into history, with installation guaranteed by the reserved resources.

Before that boundary, cancellation and commit compete through one synchronized decision:

```text
UNCOMMITTED -> ABORT_CLAIMED  -> cleanup -> DONE(error/cancel/timeout)
UNCOMMITTED -> COMMIT_CLAIMED -> install -> COMMITTED -> completion -> DONE(result)
```

COMMIT_CLAIMED is an internal irrevocable commitment, not yet permission to advertise a sample on the wire or expose it through another owner's state. All validation, fallible allocation and necessary reservations precede this transition. Installation after it must be finite local work, without waits, callbacks or further fallible resource acquisition. The completion result is published only after installation and required bookkeeping. Operation-specific postcommit waits, such as acknowledgment waits, retain their own result semantics; a generic cancellation rule cannot erase an already committed effect.

Cancellation after COMMIT_CLAIMED loses the precommit race. A caller may not return a preadmission timeout and later discover that its sample was published. Before claiming commit, check the operation deadline at the same protected decision boundary. Scheduling delay can delay reporting a timeout; this policy promises no hard wall-clock return bound.

After ABORT_CLAIMED no executor may commit the request. It enters RETIRING while owners release reservations, tickets and references. A waiting caller can be notified only when returning cannot invalidate retained memory or leave untracked cleanup. The initial safe baseline completes cleanup before returning; separately retained asynchronous cleanup is a possible later optimization. Terminal result publication occurs once, with result writes visible before the waiter observes completion.

Publisher tickets complicate this boundary: assigning group order before writer installation makes cancellation require a sequence-reservation retirement protocol. The candidate below instead leaves tickets unnumbered. It supersedes early discussion of tickets fixing group sequence numbers, and the user accepted the unnumbered-ticket/short-gate approach on 2026-09-10; ticket issuance is not successful DDS history admission.

### 4.1 Agreed: unnumbered tickets and bounded group commit

A ticket records control generation, permitted coherent membership and one outstanding completion obligation. It does not allocate a writer sequence number or group sequence number. All storage and continuation credits are reserved before the ticket is issued. Cancellation before commit retires the ticket and releases storage without creating a sequence hole. Final coherent close counts actual committed changes, not tickets issued.

The candidate final write transition holds writer execution rights and briefly claims a Publisher group-commit gate. Under that gate it validates ticket/deadline/cancellation state, claims commit, assigns writer/group sequence numbers and installs the prepared cache entry. Only then does it publish group progress and release the gate. The first committed member establishes the group's first sequence identifier. Empty/cancelled-only sets and end-marker sequencing need explicit treatment in the wire algorithm. GROUP sequence numbering also applies outside coherent brackets where required by the configured presentation scope.

The group-commit gate owns only shared sequencing/commit metadata, not general Publisher execution. This is an explicit proposed exception to the baseline one-owner-at-a-time rule: writer-local installation overlaps ownership of a narrow shared gate. It requires an audited acquisition graph. No path holding this gate may enter or wait for a writer/participant/coordinator context. Network work, allocation, history scans/eviction cleanup and callbacks are excluded. Preallocate a directly installable history node/slot and defer reclamation work. Gate contention must release writer rights and register a retry without lost wakeups or busy spinning; queued gate claimants need fair service consistent with the accepted admission policy. The FIFO entitlement proposal is described in [commit preparation](commit-preparation.md); its test-only implementation does not establish production contention behavior.

Coherent close stops new tickets for G, then waits without coordinator execution rights for every G ticket to commit or abort and retire. Existing G tickets remain valid during the drain; tickets for subsequent publication cannot overtake the sealed boundary. A committed ticket reports its installed result through retained completion storage. Delayed retirement can delay close but cannot make uninstalled data appear committed.

The narrow gate prevents a dangerous schedule: writer A reserves GSN 10 and stalls before installation, while writer B installs GSN 11 and publishes group progress that could let receivers infer 10 is absent. Group progress snapshots must be taken consistently with installed writer ranges; stale precommit heartbeat construction must not be combined with a newer group watermark. This requirement applies to initial sends, repair and heartbeat construction, not just the counter increment.

Alternative: keep strictly separate owners, with numbered reservations plus installation acknowledgments and a safe advertised progress frontier. That avoids the overlapping gate but requires bounded reservation tracking, cancellation-hole handling and a wire-order proof. The bounded group-commit gate is selected, with the validation requirements below. The alternative is not selected; production synchronization and wire behavior have not been tested. Group-specific gate/state compiles out when GROUP support is absent; non-GROUP Publisher controls retain their own required coordination.

### 4.2 Commit-gate validation findings

The finite [Python design model](commit_gate_model.py) was run on 2026-09-10: 172 reachable states and 370 transitions passed its assertions. It starts with two preissued unnumbered tickets and explores FIFO claim, split claim/install, cancellation, close, ticket retirement and one immutable progress snapshot. Assertions cover single gate ownership, no cancelled installation, no duplicate installation, sealed implies all tickets retired, snapshot consistency, and existence of a path to seal from every state. The latter is not a proof of termination under all schedules. It omits writer-context acquisition, actual atomics, new ticket admission, membership changes, resource exhaustion, sequence wrap, network/RTPS reader behavior and performance. A separate constructed counterexample demonstrates that reading old history then a new watermark is inconsistent; it is not a full wire-level interoperability test.

The source audit found that `history.zig::addWriterChange` allocates after incrementing the sequence counter, scans/evicts KEEP_LAST entries and performs a fallible append. It cannot be used unchanged inside this commit gate. A reserved directly installable entry, constant bounded metadata updates and deferred reclamation are prerequisites. The inspected `writer_sm.zig` heartbeat path constructs ordinary first/last-SN heartbeats and sends under writer ownership; it does not establish the proposed group-progress snapshot protocol.

Required gate-handoff refinement: FIFO turn entitlement is distinct from holding the metadata gate. A waiting writer owns no gate while reacquiring writer execution rights. The head claimant is made runnable using retained capacity, obtains its writer turn, and then attempts the short gate claim. Other commits do not overtake that entitlement; cancellation transfers it exactly once. No executor waits or spins under writer rights. If a metadata reader temporarily prevents acquisition, retry registration must avoid lost wakeups. Group metadata snapshots must also receive bounded service; a commit-only fairness guarantee is insufficient.

This produces possible head-of-line delay when the entitled writer is busy, but no ownership cycle provided writer turns are bounded, callbacks execute outside writer rights, and gate holders never acquire another context. A preempted actual gate holder still delays all group commits: finite algorithmic work is not a hard real-time guarantee. Progress-snapshot construction must copy coherent metadata and release rights before serialization/send; delayed packets must not replace one field with a newer value. Full membership, eviction, end-marker and repair semantics still need wire-level validation.

Outcome: the user accepted the unnumbered-ticket/short-gate approach with these conditions on 2026-09-10. It is not production-validated. The executable model supports the abstract cancellation/close mechanism; the production dual-admission handshake and history representation remain open. The [prototype](concurrency-prototype.md) exercises FIFO entitlement and bounded scalar storage with explicit limitations.

The next implementation contract is drafted in [commit preparation and handoff](commit-preparation.md). Its exact representation remains proposed.

The proposed [request lifetime and reuse contract](request-lifetime.md) separates
result completion, reference retirement and reusable storage. It specifies retained
notification/observer ownership and independent request/node identities; these
mechanisms are not yet implemented in the fixed-record prototype.

## 5. Waiter sleep and shared runtime progress

A synchronous caller observes its retained request and helps its shared runtime within the accepted budgets. It never needs to resume a private stack frame inside an unfinished protocol transition. Supported callback waits help protocol work while retaining callback exclusion.

Sleeping needs a predicate/wakeup handshake: register wake interest, recheck completion/ready work/due timers, and atomically arm the wait relative to producers, or use an equivalent monotonic wake sequence protocol. Completion before registration must be found by the recheck; completion afterwards must wake the waiter. Spurious wakes recheck predicates. Select the earliest relevant operation or runtime timer deadline.

The shared runtime is the progress domain, not one global executor. Multiworker ready-queue ownership and per-context admission still guarantee a single executor per context. WaitSets across runtimes, public runtime construction and callback delegation rules remain outside this draft.

## 6. Closing

OPEN -> DRAINING closes applicable new external admission at one defined point. New external requests ordered after that point are rejected according to the API; earlier queued but uncommitted requests follow that operation's cancel-or-drain policy. Accepted commits and mandatory internal completions remain serviceable using retained credits. Lifecycle close and commit claim must be ordered so neither invalidates resources promised to the other.

DRAINING -> CLOSED requires no ready/running protocol work, no registered protocol waits, and no outstanding internal publication/ticket obligations. External loans or callback references can delay reclamation independently. Destruction cannot wait for its own callback. Runtime shutdown must keep servicing drain work rather than stopping workers first. Public deletion preconditions and exact cancel-or-drain choices remain operation-specific.

## 7. Required executable checks

Model the following interleavings before production refactoring: enqueue versus owner release; two claims of SCHEDULED; capacity release versus waiter registration; stale wake after cancellation/re-wait; cancellation versus commit claim; close versus commit claim; external queue exhaustion with completion publication; final ticket completion versus close wait registration; and runtime sleep versus completion.

Assert one executor per context, one terminal result per request, conservation of credits/reservations/references, no commit after abort wins, and eventual service of continuously ready work under fair finite turns. Exercise with one driver and multiple executors. A subset now has deterministic and threaded coverage in the [prototype](concurrency-prototype.md); the [integrated review](concurrency-prototype-review.md) records coverage and remaining gaps. Unnumbered ticket semantics are selected. Production admission/publication, reusable references and full coherent wire behavior still require validation.
