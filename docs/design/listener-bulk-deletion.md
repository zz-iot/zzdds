# Parent and bulk deletion contract

Status: initial bulk-deletion and descendant-frontier policies accepted, 2026-09-12. Single-reader callback/external return
rules are accepted separately. This proposal does not implement a subtree transaction.

## Standards boundary

DDS 1.4 distinguishes parent deletion from recursive contained-entity deletion.
Deleting a Publisher/Subscriber requires no attached writers/readers. Participant
and Subscriber delete_contained_entities recursively delete descendants, including
reader conditions, and report PRECONDITION_NOT_MET for a descendant that cannot be
deleted. The operation target survives contained-entity deletion. The cited text
does not expressly guarantee rollback of earlier children on failure.
[Sections 2.2.2.2.1.2, .4, .18 and 2.2.2.5.2.14](https://www.omg.org/spec/DDS/1.4/PDF).

## Accepted observable policy

1. Preserve strict single-parent deletion preconditions. Do not make
   delete_subscriber implicitly delete readers, or delete_publisher implicitly delete
   writers. Checking emptiness and closing parent creation admission must be ordered
   together so a new child cannot slip between them.
2. For delete_contained_entities, preflight and reserve the complete target subtree
   before any logical deletion. An ordinary precondition or preparation-capacity
   failure deletes nothing through this call. Independent concurrent operations can
   still have their own effects; failure does not promise the world stayed unchanged.
3. Conditions within that subtree are scheduled for deletion before their readers.
   Existing loans remain blockers and are never forcibly returned. Topic dependency
   checks must distinguish references removed by this same operation from references
   outside its target set. Optional profiles add their actual objects/preconditions;
   absent profiles need no placeholder machinery.
4. Commit logical deletion for the reserved target set, then retire resources. After
   commit, ordinary cleanup must not encounter a new resource/precondition failure:
   prepare essential retirement/publication capacity beforehand. Do not return a
   normal recoverable failure after silently deleting an arbitrary subset. This is
   a local logical-deletion guarantee, not atomic network announcements, destructors,
   arbitrary application side effects or recovery from process-fatal faults.
5. The root remains usable after delete_contained_entities. Its creation gate reopens
   after logical commit, before any external callback-drain wait. Concurrent later
   creation may therefore make it nonempty again before the deleting call returns.
   Applications requiring "empty, then delete parent" must coordinate creation with
   those calls. No endless rescan to capture newly created children is proposed.
6. Extend the accepted context distinction to the deleted set: external calls drain
   applicable application access through the deleted entities; any callback-chain
   call returns after logical commit without callback-drain waiting. A surviving
   root's unrelated listener activity is outside that drain. Claimed callbacks in
   the deleted set retain their resources and may enter/finish after asynchronous
   return. No later use of logically deleted public handles is authorized.

This policy favors predictable failure over the simpler delete-until-one-fails loop.
Its preparation cost grows with the target subtree and requires explicit bounded
storage. It does not require transaction support for ordinary sample processing.

## Concurrency requirements for preparation

A mere recursive precheck followed by a deletion loop is insufficient. Establish a
stable membership boundary and reservations against new blocking resources across
the selected subtree. Serialize overlapping lifecycle operations with a compatible
ancestor/descendant admission protocol. Inspect descendants without retaining a
parent lock while waiting for an endpoint turn or application callback.

Acquiring those reservations may temporarily delay creation or loan publication.
It must not wait for application-held loans to be returned: observe such a loan,
fail the preflight, and release reservations. Already admitted short publication
sections can finish or lose to reservation according to their ordered gate. Release
operations, including return_loan, must remain serviceable throughout preparation.

Preparation must not wait for whole callback lifetimes, and a conflicting callback
operation must not be forced into a dependency on its own completion. Define the
precise wait/retry or permitted error/nil result for concurrent creators and resource
publishers in the operation matrix. This admission algorithm/result mapping is an
explicit remaining design task, not an assertion established by the single-reader
model. Avoid rejecting ordinary reads/writes merely because an unrelated subtree
is preparing deletion.

On preflight failure release all reservations and wake affected work. On commit,
lookups and public admission must observe each target as deleted through a shared
commit decision or an equivalent audited protocol, even if physical list removal is
incremental. Pending callbacks and delegated candidates detach without keeping an
external drain dependent on an unrelated parent traversal. Drain includes applicable
older retired registration uses, not just the current listeners of the children.

An empty parent can still retain internal references to previously logically deleted
children. Its physical retirement must respect those references. Whether external
parent deletion also drains previously detached descendant application uses needs
an explicit frontier rule; do not infer that emptiness proves descendant quiescence.
This is especially important after callback-context child/bulk deletion.

## Concrete examples

* Subscriber with readers A and B, B has a loan: bulk deletion fails and this call
  deletes neither A nor B, nor their conditions.
* Same tree with conditions but no loans: conditions belong to the deletion plan;
  their existence alone does not reject the bulk operation.
* Creator races the membership reservation: publication before reservation joins
  the target set; publication after reopening creates a new surviving child. The
  operation does not promise an empty root against uncoordinated concurrent creators.
* Callback on A bulk-deletes its Subscriber's readers: A and B become logically
  deleted, but the Subscriber remains. A cannot use its deleted reader afterward;
  it can finish its application callback with retained lifetime protections.

## Source audit and scope of evidence

Current participant.vtDeleteSubscriber checks descendant loan preconditions and
then deinitializes the Subscriber; it lacks the required explicit nonempty-parent
rejection. Subscriber.vtDeleteContained prechecks, then reacquires its mutex for
teardown. Participant.vtDeleteContained also separates precheck from taking ownership
of the lists. Neither shape alone establishes reservations against new loans or
creation in the gap. Reader.vtDeleteContained currently returns OK without condition
teardown. These source observations are not executed conformance tests.

Implementation should preserve the intent of existing preflight failure handling,
while correcting parent emptiness, recursive condition handling and publication races.
The single-reader deletion model does not validate this hierarchy protocol.

Next validate the accepted detached-descendant frontier with bounded traces, then
check the subtree reservation protocol where it adds uncertainty beyond single-reader
admission. A full participant teardown transaction is not required for this phase. Writer-specific commit/closure and binding unwind outcomes
remain separate inputs to the final L4/L5 operation matrix.

## Detached-descendant retirement frontier: accepted refinement

The no-partial-logical-deletion direction for ordinary preflight failure is accepted
in discussion. The frontier refinement below is accepted. It is not implemented or validated by
the existing single-reader model.

### What an external parent deletion waits for

Include outstanding application-access obligations from the parent's own lifetime
and all descendant lifetimes previously attached to it, including descendants already
logically deleted and removed from public membership. This includes claimed callbacks
not yet entered, executing callbacks, admitted application operations, applicable old
listener registrations and final hooks that may access borrowed application state.
It is not limited to whatever child pointers remain in the live membership list.

The parent must still satisfy its standard logical-emptiness precondition. Detached
retiring children do not make it logically nonempty. Once the parent successfully
closes, external deletion drains the captured obligations; callback-context deletion
returns after close and carries those obligations forward to retained retirement.
A callback deleting its own already-empty parent must not wait on the descendant
obligation represented by that very callback.

Include descendant obligations transitively. If a reader is detached, then its
Subscriber is detached before the reader finishes, an external deletion of the
Participant must still cover that reader's outstanding application access. Ownership
of the retirement record may transfer or remain chained through a retained summary,
but public membership removal cannot sever the accounting path to the ancestor.

The guarantee is about middleware access through that ancestry. Sharing a listener
object with entities outside it does not make those other uses part of this drain.
Nor does it cover arbitrary application work that retained its own unrelated reference
to application state. Reclamation still requires the application to account for such
uses and prevent reinstallation elsewhere.

### Keep application quiescence separate from storage reclamation

A parent can remain physically retained by a child even after all application accesses
through that child have finished. The external wait predicate must therefore inspect
application-access obligations, not require the parent or child reference count to
reach zero. In particular, the deletion call's own safe reference and records retained
only for internal queue cleanup cannot block the application-access boundary.

Start the local close/cleanup work necessary to finish application-access hooks before
waiting. Detach or transfer internal ownership so that no hook covered by the barrier
is scheduled only by a final destructor that itself requires the waiting call to drop
its last reference. Hooks retaining independent owned state may retire under the
accepted quiescence rules; borrowed application accesses must actually finish.

This does not force every destructor to run early. It requires separating any
application-touching part from cleanup that can safely run later. Do not execute
application callbacks or hooks under ancestry/identity bookkeeping locks.

Current source illustrates why the distinction matters: reader.reallyDeinit releases
its listener box, then near its end releases its retained Subscriber reference
(src/dcps/reader.zig:633–636). Subscriber.reallyDeinit releases its own listener box
(src/dcps/subscriber.zig:228). Waiting for the parent's final reference count while
retaining the deletion call's reference would not provide a usable barrier. This is
source-level motivation, not proof that today's complete teardown has that deadlock.

### Bulk calls on a surviving root

Recommend that an external delete_contained_entities call drain both its newly
deleted descendants and previously detached descendants through a captured retirement
frontier. This makes an external bulk call useful even when public membership is
already empty following earlier callback-context deletion. The call must still pass
preflight for any current descendants before it can report successful cleanup.

Unlike deleting the root, a bulk call does not drain the surviving root's own unrelated
callbacks or listener registrations. A later external deletion of that root includes
those uses. The bulk call drains an actual descendant-sourced callback resolved to a
parent listener, but not an entire root traversal merely because it retained a stale
candidate for a deleted reader.

Capture the covered lifetimes when the bulk deletion commits; preexisting detached
retirement remains part of the captured set. New children created after the root's
creation gate reopens do not extend the wait, nor do their later retirements. Repeated
empty external bulk calls may capture successively newer frontiers. Callback-context
bulk calls still never become drain barriers, even with empty live membership.

### Required bookkeeping properties

* Assign stable descendant lifetime/retirement identity and publish ancestry coverage
  before that lifetime or an application-access obligation can be observed publicly.
  Do not discover old descendants by walking a live-only child list at deletion time.
* Order child detachment and parent frontier capture under a compatible lifecycle
  protocol: a child is either still covered as a live target or already covered as
  detached retirement, never temporarily absent from both.
* Closing a covered lifetime prevents new public claims. Continuations and release
  hooks that remain part of an existing covered use retain its obligation until the
  final application access finishes; transferring work cannot escape the frontier.
* A frontier can be implemented by retained records, counters with generations, or
  another bounded scheme. A maximum completed sequence alone is insufficient because
  newer retirements can finish before an older covered callback.
* Reclaim completed records; do not retain an unbounded history of every former child.
  Reserve essential retirement bookkeeping before admitting the resource that will
  require it. Capacity exhaustion must not force deletion to forget an obligation.
* Independent internal storage retention must not delay application quiescence. All
  wait publication and completion notification still require stale-generation-safe
  wake handling and progress without holding application exclusion needed by others.

### Traces to validate before freezing the algorithm

1. Reader A logically deletes itself; external deletion of its now-empty Subscriber
   cannot return until A and its final application-access hook finish.
2. A is detached, then Subscriber S is detached; Participant deletion still sees A.
3. Old retirement A is paused; newer B finishes. A barrier covering both cannot use
   B's completion as evidence that A finished.
4. Empty external bulk captures old A; a newly created child B later retires. A's
   completion satisfies this frontier without waiting for B.
5. A has no application uses left but still has an internal queue reference pinning
   its parent. The barrier can finish while safe physical reclamation remains pending.
6. Child detachment races frontier capture. Both orderings preserve coverage exactly
   once. Callback-context parent deletion observes the same closure accounting but
   performs no drain wait.

These traces test the proposed frontier, not full subtree reservation, creation API
error mapping, binding exception cleanup or network-level discovery retirement.

## Bounded frontier validation completed (2026-09-12)

Run `python3 docs/design/listener_frontier_model.py`. The abstract model explores
**385 states and 1,249 transitions**. Two old children can detach and finish their
callback/hook phases in either order. Their intermediate parent can detach when
logically empty. A surviving ancestor bulk call captures the old set and closes any
remaining old membership; a later child is created under the surviving scope, not
under the detached intermediate parent. Independent internal storage pins may remain
past application quiescence.

Every successful barrier return covers both old children's callback and final-hook
completion. The frontier remains fixed after capture and every reachable state has
a completion path under eventual callback/hook completion. Reachable witnesses show
that a later child does not extend the wait, old storage can remain pinned after
return, a detached intermediate parent preserves ancestry coverage, and newer
completion cannot hide an unfinished older child.

Two negative controls fail as intended:

* Live-membership-only capture: detach both old children, capture an empty list,
  return while their application uses remain active.
* Maximum-completed-ID readiness: the newer child's callback/hook finish, then the
  barrier returns despite the older child remaining active.

This model fixes ancestry coverage abstractly and makes capture/close atomic. It
validates the required set/readiness semantics, not an implementation of record
transfer, per-ancestor counters or incremental subtree reservation. It has no real
pointers, threads, wake queues, allocation failure or binding hooks. Callback-context
nonwaiting return was covered by the earlier single-reader fixture, not rerun here.
The bounded results support the accepted frontier while leaving its concrete
publication and lifetime protocol as implementation validation work.

## Subtree admission protocol: proposed initial mechanism

Status: proposed, 2026-09-12. This refines how to implement the accepted ordinary
failure guarantee; it does not claim that the frontier model tested reservations.

### One reservation before descendant inspection

Use a participant-local lifecycle coordinator with short metadata critical sections.
Publish one reservation for the selected root before inspecting its descendants.
The reservation freezes relevant structural publication through that root; it is
not a lock held while walking children or running callbacks. Ancestor checks ensure
that descendant publishers see the reservation without acquiring each child context
in turn. Disjoint subtree reservations may coexist; overlapping reservations queue
at the coordinator without owning part of either subtree.

The coordinator serializes publication of membership, conditions, loan obligations
and applicable cross-subtree references with reservation/commit decisions. Payload
preparation, deserialization, application callbacks and ordinary packet processing
remain in their existing contexts. This adds a short gate to loan publication, not a
participant execution turn around the full read or write. Its cost must be measured;
per-endpoint counters without a reservation handshake are not a correct substitute.

### Phases

1. **Prepare request storage:** retain the root and reserve a transaction record and
   completion/wake capacity. Do not hold endpoint execution rights while awaiting
   lifecycle admission. A queued overlapping request owns no subtree reservation.
2. **Reserve root:** under coordinator ownership, order the reservation against
   short publication commits. An already published child belongs to the target set;
   an uncommitted creator is held for recheck after reservation release. Capture
   stable membership/ancestry and prevent new loan obligations or conditions from
   being published on affected old descendants. A cross-subtree reference creator
   must check both its source publication and referenced target reservations.
3. **Inspect/plan:** walk the fixed hierarchy in bounded internal turns. Read relevant
   precondition metadata through the coordinator or retained snapshots maintained by
   that same publication protocol. Never wait for an application callback, held loan,
   arbitrary user allocator hook, network acknowledgment or a child execution turn
   while retaining the reservation. An observed blocking loan causes failure rather
   than a wait for return_loan. Allocate/prepare any remaining fallible plan storage
   outside locks; if that work could enter user code, prepare it before reservation
   instead. Failure releases the reservation and deletes nothing through this call.
4. **Commit or abort:** publish one immutable transaction decision. Abort restores
   publication admission. Commit makes the selected old lifetimes logically closed
   before reopening root creation. A root generation/transaction tag or equivalent
   shared close predicate must make closure visible to all old targets, even if
   physical unlinking is done incrementally. Tagging must include children of the
   surviving bulk root and cannot make later-created children inherit old closure.
5. **Retire/drain:** unlink and retire using reserved internal work capacity. Release
   the subtree reservation before external application-access quiescence waiting.
   Callback-context callers return after logical commit, with the accepted retirement
   obligations retained. The immutable close decision outlives the reservation and
   cannot disappear while an old target still relies on it for admission checks.

Inspection can observe resource releases: a loan already returned before its check
need not cause failure. A loan observed outstanding can cause failure even if another
thread returns it immediately afterwards. Failure is an observation, not a promise
that retry will also fail. Conditions in the target plan are deleted rather than
mistaken for external blockers. Ordinary valid publications cannot add a blocker
behind a successful inspection because reservation remains in force until decision.

### Which operations pause and which keep running

| Operation | Reservation behavior |
| --- | --- |
| Create child/condition or publish a new loan on an affected target | Wait uncommitted without owning a turn/partial publication; retry on abort, or recheck target lifetime on commit |
| Create under surviving bulk root after commit | May proceed as new generation work; does not join the old frontier |
| return_loan and other release-only cleanup | Remain serviceable; can remove blockers |
| Ordinary copy-out read/write or protocol work | No blanket suspension; any specific resource/structural commit it performs must use the relevant gate |
| Callback already executing, or claim before logical close | Continues with retained lifetime; reservation does not wait for it |
| Callback claim or public operation after logical close | Rejected/invalidated under the applicable operation contract |
| Overlapping delete/bulk request | Queue without a reservation; revalidate membership and lifetime when admitted |
| Unrelated subtree work | Continues, apart from brief shared coordinator metadata synchronization |

Do not expose transient reservation as PRECONDITION_NOT_MET or as an arbitrary nil
creation result. Preserve an operation's existing deadline if it has one; reservation
wait consumes that budget. On release, a still-live root creator retries, whereas a
creator/loan publisher targeting a deleted old entity resolves closure using its
operation-specific mapping. Exact closure/error codes remain in L5; no universal new
DDS error is introduced by this protocol.

### Why a callback can wait without creating a drain cycle

If callback A encounters a reserved subtree while trying to publish a loan, A releases
its endpoint turn/publication rights and waits. The deleting transaction inspects
metadata and reaches commit or abort without waiting for A to return. Only after
releasing the reservation may an external deleter wait for A's retirement. Thus A can
resume, observe the decision, and return. The deleting transaction must not use the
external drain as the condition for releasing the reservation.

For a manual driver, synchronous waiting may help bounded lifecycle-coordinator work
as internal progress, without invoking automatic callbacks. Another worker is not
required. Callback self-bulk-deletion follows the same internal path. If a proposed
implementation needs application execution to complete the reserved phase, it violates
this mechanism and must release/retry rather than waiting with the reservation held.
The ordinary no-protocol-lock-across-application-code requirement remains essential.

### Remaining validation and implementation tradeoffs

The simplifying cost is centralized metadata coordination within one participant.
It avoids partial acquisition of many endpoint execution contexts but does not remove
hierarchy bookkeeping, transaction storage, ancestor checks or short contention on
loan publication. Preserve ordinary per-reader/per-writer execution and independent
listeners. A later distributed reservation optimization must demonstrate the same
publication and dependency rules before replacing this baseline.

The next bounded model should include a reservation, two children, a creator, loan
publication/return, commit/abort and external drain. Check no partial deletion on
preflight failure, no new blocker after reserve, reopening before drain, and a queued
callback operation resuming after the transaction decision. Negative controls should
allow publication behind the scan and hold reservation until callback drain, exposing
respectively invalid close and a circular wait. This is the next experiment if the
mechanism is selected; no production changes are made by this document.

## Bounded subtree reservation experiment (2026-09-12)

The participant-local reservation direction was accepted for this experiment; concrete
coordinator representation and the remaining integration/result details are not frozen.
Run `python3 docs/design/subtree_reservation_model.py`.

| Initial resource state | States | Transitions |
| --- | ---: | ---: |
| No initial loan | 51 | 72 |
| One initial loan | 91 | 156 |

The model interleaves two-child sequential preflight with loan publication/return,
a callback waiting to publish, creation under the surviving root, logical commit,
abort and external callback drain. Each reachable state has a completion path under
finite work and eventual release assumptions. Abort deletes no targets; commit closes
both old targets together and never leaves a loan on a closed target. Creation before
reservation joins the target set, while creation after commit survives. A callback
held at publication can resume after commit, observe closure and finish before the
external deletion returns.

Both negative controls produce the expected failures:

* Allow publication during reservation: reserve, check both children, publish a loan,
  then commit from stale preflight results. A live loan remains on a closed child.
* Retain reservation through drain: reserve, check both children, commit; the callback
  cannot finish its publication attempt until reservation release, while release is
  waiting for that callback to finish. The model reaches a state with no progress.

This is evidence for the phase ordering and publication exclusion, not a concrete
mutex/queue implementation. It models one transaction and one creator, with a newly
created target having no additional blockers; no competing subtree reservations,
condition creation, cross-subtree topic references, allocation failure, real timing,
wake delivery, generation reuse or binding hooks are modeled. Callback-context
nonwaiting return and retirement frontiers have separate fixtures. No production
performance, starvation bound or complete teardown correctness follows from the
combined collection of bounded experiments.

Remaining integration tests must check overlapping ancestor/descendant reservations,
condition/reference publication, plan capacity failure and manual-driver helping.
The next application-visible contract topic can now be binding exception/unwind
behavior, followed by the L5 operation-specific wait/closure matrix. Another subtree
prototype is warranted only if those reviews expose a concrete policy uncertainty.
