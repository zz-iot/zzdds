# WaitSet waiting: proposed concurrency and progress contract

Status: behavioral direction accepted, 2026-09-14. Single-invocation admission,
live attachments, level observation and scoped helping are accepted. Temporary result
ownership is also accepted and its bounded model is checked. Close and helping
configuration are finalized in the linked contract. Conversion mapping and concrete
runtime integration remain implementation follow-ups. The bounded request/wakeup
model is checked, including explicit-close behavior. See the
[binding ownership audit and model](waitset-result-ownership.md).

## Standards boundary

DDS 1.4 sections 2.2.2.1.6–7 define WaitSets independently of participants, permit
conditions from different participants, require a second waiting thread to receive
PRECONDITION_NOT_MET, and allow attachment during an active wait. Attaching a true
condition must wake that wait. Duplicate attachment has no effect; detaching an
absent condition returns PRECONDITION_NOT_MET. A successful wait returns the attached
conditions observed true. The timing and lifetime refinements below are zzdds proposals.
[OMG DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

## One admitted invocation, live membership

Use one admitted wait invocation per WaitSet, from admission through output publication
and release of its waiter slot. Reject another invocation with PRECONDITION_NOT_MET,
including same-chain recursion or a zero-timeout call while that slot is occupied.
This gives a precise rule slightly stronger than the standard's blocked-thread wording.
Executor migration does not create another waiter. Rejected callers do not mutate the
active invocation's request or output; normal argument validation still applies.

Attachments remain live throughout the wait. New conditions can participate; detach
or logical condition deletion withdraws their attachment generation. Reattachment is
a new generation, so an old queued wake cannot restore an old attachment. Duplicate
attachment does not create another entry or replace its retention registration.
An empty WaitSet can wait for a later attachment, guard activity after attachment,
or timeout. Removing its last condition does not return OK or delete the WaitSet.

## Level observation, not a queue of trigger events

A notification schedules a fresh condition scan. It is not a latched success and
neither wait nor notification clears a GuardCondition, status or reader state.
If another consumer resets a condition before this wait observes it, the wait can
continue. Applications needing a persistent signal keep a GuardCondition true until
handled, or keep the relevant application predicate true; do not rely on a brief pulse.

Collect all eligible attached conditions observed true in a successful scan, with no
promised ordering. Do not claim a simultaneous snapshot of independently changing
conditions from multiple participants. Each candidate needs a valid attachment
identity and safe condition reference while checked. Membership changes invalidate
uncommitted candidates; a retained committed result can refer to a condition later
detached or reset. The application must recheck/read its actual predicate after return.

A selected result becomes terminal only when its nonempty output and required lifetime
retention are secured. Before that point, errors or invalidation do not consume trigger
state. After that point, timeout or reset does not retroactively change OK. No
successful empty result is invented for a spurious wake or attachment change.

## Deadline and closure

Use one absolute monotonic deadline from API entry. Initial nonblocking inspection
can return already true conditions even for zero duration; otherwise expiry returns
TIMEOUT. Once the invocation is waiting, a wake before deadline is not sufficient:
a valid nonempty observation must commit before expiry. At/after expiry, an unresolved
registered wait returns TIMEOUT. Thus a delayed notification is unlike a previously
committed ACK completion. Scan/commit and expiry must share terminal arbitration.

Condition deletion withdraws eligibility and wakes a recheck; it does not yield
ALREADY_DELETED for the WaitSet. Explicit logical WaitSet close resolves an
unresolved admitted invocation as ALREADY_DELETED before its retained storage is
reclaimed. This needs a safe recognized WaitSet lifetime; calling through an already
freed binding object remains invalid. Previously committed success remains success.
An application can request ordinary cancellation using an attached GuardCondition;
that returns a normal triggered result, not a new standard cancellation return code.

Result lifetime is a required binding follow-up before this part is implementable:
attachment retention alone is insufficient if detach releases the last C++/Java
wrapper reference while a selected result is being converted or returned. A successful
result needs independent safe identity/retention through output conversion. This does
not promise that the underlying entity remains logically alive after concurrent delete.
Exact ownership after API return must follow each language's ConditionSeq/object
contract; do not quietly redefine raw C condition handles as owning references or
add an incompatible sequence layout. Resolve this before claiming safe concurrent
condition deletion across all bindings.

## Progress across runtimes

Separate wake registration from permission to execute a runtime. A WaitSet accepts
conditions from multiple participants regardless of which runtime drives them.
Externally driven runtimes can notify it without the waiter executing their work.
Attaching a condition must not silently enlist an arbitrary foreign runtime into a
nested pump or grant permission to execute its callbacks.

Recommend using the configured shared-runtime helping contract for standard API
applications. A manual-runtime application must supply its driver or explicitly
configure permitted helping; the concrete association/configuration surface is still
open and belongs in zzdds.idl where generated application API is needed. A guard-only
WaitSet needs no participant to exist. Do not infer a runtime from the first condition
and change execution behavior when attachment order changes.

A callback waiter retains its execution rights and helps only permitted internal
protocol, condition, timer and lifecycle work, without automatic nested listeners.
A condition depending on that callback's later application actions can deadlock;
attachment alone does not reveal an inferable dependency. An idle or stopped foreign
runtime does not by itself fail the whole WaitSet: another condition or GuardCondition
may still trigger. Failure of the WaitSet's own indispensable wait/progress mechanism
is a separate ERROR candidate to settle with runtime shutdown integration.

## Current source observations

`src/dcps/waitset.zig:359` uses a single-pass triggered-condition collection and a
condition-variable notification flag, including an allocation failure result. It
currently has no explicit active-waiter admission check in that routine and no
visible active-wait lifetime acquisition there. These are audit findings, not a
reproduced multiwait or destruction failure.

`attachConditionWithRelease` maintains attachment ownership hooks, rolls back wake
registration failures and retains GuardCondition lifetime. Its successful path does
not explicitly notify the WaitSet after attaching an already true condition; this
needs a targeted test against the registration helpers before claiming a reproduced
missed wake. `vtDetach` releases attachment hooks outside the membership lock.
Those hooks preserve attachment ownership, not automatically independent ownership
of the raw condition handles copied into a wait result.

Preserve existing lost-wakeup and single-pass allocation protections. The future
registration/check/sleep protocol must cover attach-true, detach/delete, trigger and
reset, stale generation wakes, waiter exit and close. Do not call arbitrary foreign
binding hooks while holding a WaitSet metadata lock.

## Decision and validation sequence

Single-invocation admission, live attachment generations, level-trigger observation
and scoped helping are accepted. The C/Zig, C++ and Java ownership audit led to the
accepted temporary result lease and its separate bounded model. The wakeup model
below checks request ordering. WaitSet close/configuration and concrete binding
integration remain; neither requires starting another full runtime prototype.

## Bounded wakeup validation (2026-09-14)

Run `python3 docs/design/waitset_wakeup_model.py`. Initially unattached/true passes
1,768 states and 5,220 transitions; initially attached/false passes 1,956 states and
5,834 transitions. Total: 3,724 scenario-states and 11,054 transitions, with seven
reachable outcome witnesses. The model starts with one admitted invocation and
separates scan, the gap before sleeping, sleep registration, wake service, terminal
result and output publication/slot release.

The model interleaves one trigger/reset, attachment and one detach/reattach generation,
condition deletion, proposed WaitSet close, logical deadline expiry, a second caller
and a spurious/stale attachment wake. Four negative controls catch missing attach
notification, clearing notification at park, interpreting wake as success, and
admitting a second caller. Every state has a path to terminal output publication;
this is not a fairness guarantee. The accepted behavioral direction needs no change.

The minimal abstract registration protocol is:

1. Consume the pending recheck hint before observing condition state.
2. Scan current eligible conditions; a valid retained nonempty result competes with
   expiry/close at the terminal boundary. With no result, prepare to sleep.
3. Under synchronization shared with notification, inspect the hint and register
   sleep atomically. If a notification arrived since observation, rescan instead.
4. A notification after sleep registration leaves a pending hint and schedules the
   waiter. Servicing it initiates a scan; it never manufactures OK.

The model makes hint consumption and scan one transition. Production can separate
them if notifications arriving during the scan remain pending; it must not clear
those notifications after scanning. A version counter can replace the boolean hint,
but the same registration ordering is required. Attach publication and registration
must also arrange a recheck of an already true level; registration alone is not
evidence that a subsequent level transition will occur.

This is abstract validation of required ordering, not a test of the current condvar
implementation. One condition is modeled, not multi-condition output assembly.
Zero-duration initial polling, clock equality/delayed timer delivery, allocation,
binding retention and output conversion are outside this model. Stale attachment
wakes are harmless recheck hints; stale *request-generation* wakes after a subsequent
wait begins still require runtime generation checks, not established by this
single-request model. The ownership model is separate; full composition is unproven.

Next settle the explicit-close lifecycle and how a factory-less WaitSet obtains its
permitted runtime-helping configuration. The behavioral and ownership models do not
choose a new application-visible shutdown/configuration API.
The [close and progress proposal](waitset-close-progress.md) recommends non-draining
explicit close and default/explicit/no-helping policies. These are now finalized:
default runtime resolution occurs at each wait admission and its selection stays
fixed through conversion or unwind. Close is idempotent and non-draining; configured
construction is a zzdds extension. Exact generated runtime types/bootstrap spelling
remain part of runtime IDL integration.
