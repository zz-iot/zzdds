# Request completion, reference retirement and storage reuse

Status: proposed internal contract, 2026-09-11. Refines the lifetime prerequisite
identified by the [integrated review](concurrency-prototype-review.md). The agreed
admission, cancellation and head-only ticket policies are unchanged. A separate bounded pool experiment now exercises part of this contract; the
integrated admission prototype still retains fixed IDs. No public API is selected.

## 1. Three distinct boundaries

| Boundary | Required condition | What becomes possible |
| --- | --- | --- |
| Result completion | Effect resolved; installation or abort bookkeeping complete; reservations/tickets settled; request-owned resources released or transferred to tracked owners | A waiter can observe/copy the immutable result and return according to the operation's semantics |
| Reference retirement | No queued, executing, registered, publishing or observing owner can access the request; it is detached from all indexes and lists | Begin destruction of remaining request-local storage |
| Slot reuse | Destruction complete and generation advanced under pool synchronization | Admit a new request into that slot |

Result completion does not imply reference retirement. Protocol stop does not
imply storage reclamation. An effect of COMMITTED is not yet result completion.
Use a separate completion predicate with release/acquire publication or the same
protecting lock; do not overload the effect enum. The result is immutable and
published once. Copy it while retaining the request, then release the observer.

Initial baseline: a completed abort has disposed of or transferred all preparation
ownership and retired its ticket/reservation. A completed write has installed and
transferred its sample to history and settled its ticket/reservation. If old payload
reclamation remains, a retained history/pin/reclamation owner accounts for it;
the request must not leave an untracked cleanup obligation. Operation-specific
postcommit waits remain distinct and may delay that operation's result completion.

## 2. Separate identity from order and lifetime

Use a stable pool control block with identities of the form `(pool, slot,
slot_generation)`. The pool component may be implicit when an enclosing retained
object unambiguously identifies it. Request and history-node pools have distinct
identities even if their storage is allocated together. Neither a naked pointer
nor a slot number is a public or durable identity.

Four counters have different purposes:

* Slot generation identifies successive occupants of one storage slot.
* Wait/continuation generation identifies successive registrations of one live request.
* Coherent control generation identifies the publication membership boundary.
* Ledger order identifies write admission order within an instance.

Reusing a slot must not change ledger ordering, coherent membership or sequence
numbers. Replace the prototype's `req[0..id]` order scan with explicit retained
instance-ledger links before enabling reuse. A ledger holds references until
unlinking; slot position has no ordering meaning. History must identify a node,
not refer back to a request record merely to recover sample identity. Sequence
metadata and immutable diagnostics can be copied without retaining the request.

Generation exhaustion must never wrap to a previously valid identity. Retire the
slot or fail further admission explicitly. Apply an equivalent no-alias rule to
wait generations; do not roll them over while an old notification can survive.
Exact widths and configured pool sizes are implementation choices, not settled
by this contract.

## 3. Reference acquisition and transfer

Pool metadata remains alive independently of individual entries. A lookup by a
non-owning handle first retains/accesses that stable control block, then validates
slot generation and liveness and acquires a reference under pool synchronization.
Only then may it dereference the entry. Generation validation followed by an
unprotected reference increment is forbidden: reuse could occur between them.
Initial implementation should use the admission/pool lock, not an improvised
lock-free reference acquisition algorithm.

An existing owner may transfer its reference without dropping it to zero. Creating
an additional owner requires a counted retain before publication. Destruction
cannot start while any such owner remains. Whether references are implemented as
counts, typed ownership records or embedded flags is secondary to conserving these
ownership obligations:

| Owner | Acquire/retain | Transfer or release |
| --- | --- | --- |
| Operation lifetime root | External admission succeeds | Release after immutable completion is published and all protocol obligations are settled or explicitly transferred |
| Result observer | Before returning/retaining the operation handle | Copy result or abandon observation, then release; abandonment does not imply cancellation |
| Instance ledger / resource or timer registration | Before linking/registering | Unlink under its owner's synchronization, then release or transfer to a continuation |
| Gate record / entitlement | Before joining FIFO | Transfer through queued/entitled/active states; release after unlink and gate retirement |
| Publication obligation | Before making a destination notification possible | Transfer into a queued event, or into retained retry state if publication is deferred |
| Ready event | Before publishing queue entry | Transfer to executor on dequeue; never drop and reacquire between pop and execution |
| Executor | By transfer from ready event or eligible direct admission | Publish any successor obligations first, then release its own reference |
| Detached cleanup job | Before releasing the owner that needed cleanup | Release after cleanup and its bounded completion publication |

One record may represent several states through ownership transfer; this table
does not require a separate atomic counter for every row. Independent live edges
must still be independently accounted for. An executing operation cannot advance
mutable continuation state concurrently with another executor. Reference safety
does not grant execution rights or authorize producer mutation of destination state.

Reference counters and continuation capacities are bounded. Admission reserves
needed internal completion capacity before publishing the request. Later mandatory
cleanup may not fail because external work exhausted the pool. Coalescing is valid
only with a retained producer/publication obligation and a synchronized predicate.
Queue duplication must not create uncounted references or double releases.

## 4. Cancellation, obsolete notifications and completion

Cancellation still competes with commit at the protected effect boundary. Winning
cancellation initiates retirement; it does not free request storage or revoke
references held by another executor. A gate/ready notification already published
can remain queued as a tombstone, retaining its target until consumed. Alternatively
it can be unlinked under the relevant owner's rights and have that reference
released there. Never release merely because an unlink was requested.

A dequeued event retains both the request and its destination lifetime. It checks
the request identity and applicable wait/entitlement generation under the destination
protocol. If obsolete, it performs no request-state mutation and releases only
its own ownership. It must not release a newer reservation, clear a newer scheduled
flag or retire a newer gate entitlement. Re-registering a wait publishes a new
wait generation before making new notifications eligible.

For the initial baseline, **a queued reference prevents slot reuse**. An owning
notification therefore cannot legitimately name an already-reused slot; a mismatch
in that case is an invariant failure, not routine cancellation. Obsolete wait
notifications for the same live request are expected. A late non-owning handle can
legitimately fail lookup after reuse. Keep those two cases distinct in tests.

Completion is published while the operation root or executor still owns the record.
Observer registration and completion recheck share synchronization, as do wake
publication and sleeping. Completing between observation and wait arming must not
lose the wake. An asynchronous user retaining a completed result handle can keep
a slot occupied; bounded capacity must report this rather than silently recycle it.
A synchronous wrapper can copy its result and drop the handle before returning.
Neither behavior introduces a new standard DDS API.

## 5. History nodes, payloads and replacement reservations

Node lifecycle is independent of request lifecycle. Preparation owns the new node;
commit transfers it to history. Pins/loans and transport use, where applicable,
retain node/payload ownership directly rather than retaining the completed write
request. Detach removes the history owner; it does not invalidate existing pins.
No node slot or payload buffer can be reused while such an owner exists.

A replacement reservation is a logical slot entitlement, not ownership of the old
payload. Its victim locator includes the node generation and is examined only
under writer ownership while history retains that node. Policy removal converts
the reservation to free-but-reserved and clears its victim link in the same
protected transition, before dropping history ownership. A deferred task needing
to dereference the old node must retain it separately; the locator alone provides
no memory safety. Cancellation releases its reservation without resurrecting or
removing independently managed history.

When the final data owner releases a detached node, transfer it to reclamation
ownership before publishing any deferred destructor task. Reclamation must not
resurrect a zero-reference object by incrementing an already-dead record. Separate
"no data owners" from "safe to reuse": a queued or running destructor still owns
the node. Finish payload destruction outside protocol/admission locks, then publish
physical-capacity release and reusable-slot availability through retained bounded
completion storage. Do not let a waiter spend physical credit before reclamation
actually makes it available.

This enables moving allocation/free out of the admission mutex later, but does not
itself specify that executor or allocator adapter. Multi-stage preparation rollback
uses the same ownership ledger: every successful stage is either transferred to
the next stage or reclaimed after failure, including failure before any ticket exists.

## 6. Reusable-state decision and teardown

A request becomes eligible for reclamation only when completion is published,
all protocol ownership edges are gone, all observers have released it, and no
list/index references it. The final release records a reclaiming state under pool
synchronization. Destruction runs with retained pool/allocator lifetime; publish
FREE and advance slot generation only after it finishes. No new lookup succeeds
while reclaiming. Allocation into FREE fully initializes the new record before
publishing its handle or linking it into admission structures.

Endpoint/control/runtime lifetimes form explicit teardown obligations. A context
must remain accessible while destination events or executors retain it. Avoid
self-sustaining ownership cycles: the runtime's pool registry is not itself an
extra per-entry reference that an entry must release. An owning pool/control block
is destroyed only when its outstanding-entry/job/observer counts and external
owners permit it; exact storage layout may combine these counters.

Protocol stop drains all admitted protocol work, including stale notifications.
Outstanding loans may still retain storage afterwards. Reclamation service and the
allocator/control block must therefore outlive protocol stop. A manual driver must
still be able to service reclamation, or final-release cleanup must have a defined
safe synchronous path. Do not enqueue work onto workers that have been destroyed.
The initial contract requires explicit reclamation completion before destroying
the pool; it does not require hidden threads, waiting inside callbacks, or recursive
protocol execution. Whether a public destroy operation reports outstanding owners
or follows another allowed deletion policy remains a separate API decision.

This document does not select atomic cancel-all versus close-then-cancel shutdown
semantics. Either choice must preserve already-claimed commit resources and these
retained lifetimes. No extension belongs in `dcps.idl`; any future nonstandard
runtime/result configuration belongs on `zzdds.idl` extension interfaces, with
safe default ownership for standard-only applications.

## 7. Validation traces and next executable slice

| Trace | Required result |
| --- | --- |
| Cancel entitled request; stale commit event retires logical work; cleanup event remains | Result can complete, but slot remains occupied until event and observer references retire |
| Pop event; pause executor; cancellation and observer release occur elsewhere | Popped event still owns request/context; no reuse until executor releases |
| Unregister wait G, register G+1; consume old G notification | No mutation of G+1 registration, reservation or wake obligation; release only old event ownership |
| Finish A and release all owners; reuse slot for B; use old non-owning A handle | Protected lookup fails without touching B or freed storage |
| Copy B's result and release request; keep committed sample pinned | Request can recycle independently; node/payload cannot recycle until detach and final pin retirement |
| Remove reserved victim; delay old node reclamation; prepare successor | Logical slot remains reserved; physical credit remains unavailable until reclamation completes |
| Last pin release after protocol stop | Defined reclamation path remains available; allocator/control block remains alive |
| Observer registration races completion and sleeping | Result is found by recheck or signaled; observer reference covers all accesses |
| Generation or internal-reference capacity exhausted | Explicit failure before unsafe publication; no wraparound or dropped mandatory completion |

These are design traces, not new executed model results. Existing tests establish
only the retained-record examples cited by the integrated review. The next bounded
experiment should use a tiny request pool and a separate tiny node pool, explicit
references and generations under the existing mutex, and independent ledger order.
Exercise at least two uses of the same slot, delayed popped/queued events, two wait
generations, a retained result observer and a pinned node after request reuse.
Include deliberate negative controls for dropping an event reference at dequeue
and for omitting generation validation on non-owning lookup. Do not introduce
lock-free reclamation, public IDL, or production pool sizing as part of that slice.

## 8. Bounded pool experiment

`test/concurrency/lifetime_pool.zig` now implements a separate two-request/two-node
pool with four retained event records. The existing deterministic and threaded
runners include its tests, so it follows the same standalone and repository build
wiring. The integrated admission engine is unchanged; this is not yet a replacement
for its request/history storage.

A single mutex protects lookup-and-retain, publication and final release. Request
roots, logical ledger membership, observers, wait registrations and queued/popped
events carry explicit reference counts. A separate monotonically increasing order
keeps a recycled lower slot from overtaking an older request in a higher slot;
this tiny experiment scans two records, rather than implementing production ledger
links. Node resident/pin/reclaiming states retain storage independently of requests.
Scalar node destruction has an explicit delayed completion step, with no allocator
or physical destructor work. Request scalar destruction is immediate on final
release. The control block remains alive until joined teardown.

Tests cover queued and popped ownership independently, result observers, obsolete
wait notifications, request reuse while a detached node remains pinned, blocked
node reuse until reclamation completes, bounded event/observer capacity and request/
wait generation exhaustion. An eight-bit generation makes exhaustion directly
testable; it is not a production-width recommendation. Node and event generations
also fail closed in the implementation, but their exhaustion is not separately
exercised. A threaded checkpoint pauses a popped event while another thread
completes the request and releases the observer, then verifies reuse remains blocked
until that executor releases its reference.

Two opt-in fault modes are confined to this test-only module. Dropping the event
reference at dequeue allows premature request reuse and is caught as DanglingEvent
without dereferencing unsafe storage. Skipping generation validation in observer
lookup wrongly retains the replacement request and produces an explicit witness.
These are constructed negative controls, not evidence of a production memory fault.

The experiment omits automatic wait/wake observer delivery, coherent gate/ticket
integration, cancellation arbitration, actual history indexes, context/runtime
reference chains, variable payloads and allocator-backed deferred destruction.
Balanced observer/pin ownership is a caller precondition; handles are copyable,
not unique ownership tokens. Reference safety here is not a proof of full runtime
lifetime correctness. The admission engine now integrates explicit queue/executor/gate/observer reference
transfers and a structural ownership audit; see the [prototype record](concurrency-prototype.md#integrated-readygate-ownership-slice).
The engine now also has independent node identities with actual node reuse, explicit
admission order and checked request handles. Integrated request-slot reuse and
allocator work outside the admission mutex remain implementation/validation backlog.
See the [specification status map](concurrency-spec-status.md) before extending the
experiment further.
