# DataReader deletion: callback and return boundary

Status: initial single-reader deletion direction accepted, 2026-09-12. Scope is one reader deleted through
its owning Subscriber. Parent/bulk deletion and binding unwinding remain separate
follow-ups. No production implementation is implied.

## Standards boundary

DDS 1.4 section 2.2.2.5.2.6 rejects deletion through a different Subscriber, attached
ReadConditions/QueryConditions, and outstanding read/take loans, using
PRECONDITION_NOT_MET. Section 2.2.1.1 makes use of deleted entities erroneous and
calls for ALREADY_DELETED where detectable. These passages do not specify our
callback-drain return boundary. [DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

## Accepted initial behavior

Use one logical deletion boundary followed by retained retirement. External deletion
waits for applicable application access to quiesce; deletion from any callback chain
commits without waiting for callback drain. Apply the context distinction consistently
with accepted listener replacement, including callbacks on other readers/runtimes.

| Caller | Successful return means |
| --- | --- |
| Ordinary application code | Reader is logically deleted; no remaining admitted application operations or callback/context accesses through that reader, including applicable retired registration hooks |
| Any zzdds callback chain | Reader is logically deleted; unclaimed work cannot start; previously claimed invocations/operations may still finish with retained state |

Physical storage may outlive either return due to safe internal retirement. External
return does not wait for remote peers to acknowledge discovery disposal or for every
stale scheduler record to be freed. Remaining internal records must have independent
ownership and cannot access reclaimed application state.

Claimed callbacks may enter after callback-context deletion returns, just as with
callback-context listener replacement. The deleting callback may finish using its
own application state, but deletion does not license subsequent public operations
on the deleted reader. Retaining its internal storage is not keeping its API alive.

The accepted choice permits logical deletion from any callback chain, including
self-deletion, without callback-drain waiting. External deletion provides the stronger
application-access quiescence boundary. Successful callback-context deletion does not
authorize destruction of borrowed listener state or further public use of the reader.
The operation-race refinements below still need their named validation and result
mapping; acceptance does not imply that those implementation details are complete.

## Admission, preconditions and operation races

1. Resolve a safe reader lifetime through the owning Subscriber. Wrong live owner,
   attached conditions or outstanding loans fail without removing the reader or
   retiring its listener. Do not auto-return loans or auto-delete conditions as a
   side effect of single-reader deletion.
2. Coordinate final precondition checks with the operation gate for loan/condition
   publication and logical close. A new loan or condition cannot slip between a
   successful check and close. If its publication wins first, deletion fails; if
   close wins, publication is rejected. A precheck followed by unrelated teardown
   is insufficient.
3. On successful close, remove membership, close new operation/callback claims,
   retire the installed registration, invalidate pending notification/delegation
   attempts, and publish wakes for operations affected by closure. Retain any
   resources necessary for already committed effects and safe completion.
4. Admitted work is not unconditionally allowed to create resources after close.
   An admitted read that has not committed a loan cannot publish one after close.
   Committed operations finish with their retained resources; uncommitted operations
   resolve closure under an operation-specific result rule. That result matrix is
   required before implementation; this note does not assign a universal cancellation
   code to every DDS operation.
5. External waiting holds no Subscriber, reader, identity or protocol mutex and does
   not retain an execution turn needed by retirement. Include prior retired listener
   generations, not just the installation current at deletion. Callback-context
   callers never wait for another callback to drain merely because the target differs
   from their own reader.

Concurrent deletion must have a single close winner and no double protocol teardown.
Calls that safely resolved the lifetime before close need a documented loser result;
recommend ALREADY_DELETED for a recognized already-closed target, retaining
PRECONDITION_NOT_MET for a live target owned elsewhere. Arbitrary stale raw pointers
cannot be made safe merely by reading a generation field in freed memory. Binding
handles need safe lookup/retention or the documented application synchronization rule.

A retained delegation candidate does not itself block external deletion. Pending
candidate records must detach from application state and permit skipping the reader;
only an actual claimed invocation/application use contributes to the drain boundary.
Otherwise a suspended parent traversal could prevent deletion even after its pending
child was invalidated.

## Lifetime consequence of callback-context deletion

This case is less convenient than asynchronous listener replacement: once deleted,
the application cannot call set_listener on that reader to establish a later barrier.
Do not suggest retrying deletion or clearing a deleted reader as a reclamation method.

The standard-only recommendation for borrowed listener state is to hand deletion to
a management path, let external deletion drain, then reclaim the object after all its
other registrations/users are retired. Avoid a callback joining that management path
while the path waits for the callback. On a single-thread driver, management can run
after the outer callback has returned.

Immediate callback-context deletion is useful when the application already has an
independent lifetime arrangement, such as long-lived listener state. It does not
make successful self-deletion permission to destroy the executing listener. A later
asynchronous retirement token extension in zzdds.idl could make reclamation easier;
it is not required to use the management pattern.

This boundary covers callbacks sourced by the reader, including parent fallback
invocations already claimed for it. It does not quiesce every use of a shared listener
on other entities, or an entire Subscriber traversal merely because that traversal
once included the reader.

## Alternatives

Always wait would deadlock self-deletion and cross-callback deletion. Always defer
would provide no standard external return-time lifetime boundary. Reject all
callback-context deletion is simpler and remains an alternative, but removes useful
logical-close behavior already supported in part by retained teardown. The recommended
context-sensitive choice matches setter behavior while documenting its different
post-deletion reclamation consequences.

## Current source findings and validation needed

Subscriber.vtDeleteDataReader (src/dcps/subscriber.zig:435) holds subscriber.mu,
checks the reader precondition, removes membership, destroys the protocol reader and
calls deinit. Wrong-owner lookup currently returns BAD_PARAMETER. Reader
checkDeletePrecondition (src/dcps/reader.zig:2369) checks outstanding_loans only;
attached condition validation is absent from that helper. The entire condition and
loan publication path still needs review before claiming atomic deletion admission.

Reader.deinit uses EntityQuiesce.beginTeardown, which closes acquisition and releases
the alive reference; final deinit can run on the last retaining caller. This supplies
part of retained reclamation, not the proposed external drain barrier. EntityQuiesce
explicitly cannot protect an already dangling pointer at acquisition. Existing source
comments describe historical lock assumptions; they are not proof of current complete
call-chain safety. No production race test was run in this investigation.

Next validate decision traces: precondition failure leaves membership intact; loan or
condition publication versus close has one winner; pending child withdrawal does not
block deletion; claimed callback paused before entry; old retired registration still
active; self- and cross-reader deletion; external deletion versus operation completion;
and concurrent deletion. Parent/bulk deletion needs its own transaction/partial-effect
contract. Exception cleanup must release all retained rights/references even when
application callback execution fails. These are follow-ups, not guarantees established
by the existing listener admission models.

## Initial bounded validation (2026-09-12)

Run `python3 docs/design/listener_deletion_model.py`.

| Caller scenario | States | Transitions |
| --- | ---: | ---: |
| External deletion | 62 | 145 |
| Deletion from another callback context | 77 | 188 |
| Self-deletion while the target callback is entered | 69 | 152 |

The model separates callback claim, application entry, completion and a final
callback-context access hook. One admitted loan publisher and one condition creator
race deletion, with resource release and closed-operation rejection represented.
Successful close never coexists with a published loan/condition; publication after
close is rejected. Unclaimed callbacks are withdrawn at close. External successful
return requires callback/hook retirement and completion of the modeled admitted
operations. Callback-context return can precede a claimed callback's entry or occur
while the target callback remains active. Every reachable state has a completion
path under finite activity and eventual callback/resource release assumptions.

For self-deletion, returning from the callback without successfully deleting is also
a valid terminal outcome: this covers a caller giving up when resource preconditions
fail. It is not counted as successful deletion. Failed precondition checks leave
state unchanged; their no-progress self-loops are omitted from the graph.

The negative control splits precondition checking from close. It finds
`precheck -> loan publication -> close using stale precheck`, leaving a deleted
reader with a live loan. An analogous condition-publication witness is also checked.
This supports one coordinated publication/close boundary, not merely an early loan
count check. A resource published before close must cause failure until released;
an admitted publisher overtaken by close must finish without publishing.

Limits: scalar abstract state, atomic close and invalidation, one callback, one
resource of each kind, and no actual object pointers, allocation or OS threads.
The hook models a final callback-related context access, not the full registry
retirement frontier. Membership detachment, multiple retired registrations, two
simultaneous deleters, bulk deletion, status/WaitSet wake delivery, binding unwinding
and exact interrupted-operation return codes remain integration or follow-up work.
The other-callback scenario models the caller classification, not two interacting
callback dependency graphs. No production teardown or lifetime safety is claimed
from these bounded results.
