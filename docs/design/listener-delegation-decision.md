# Explicit reader-listener delegation: contention investigation

Status: accepted initial admission, replacement/removal, recursion and error policy,
2026-09-11, with participant-configurable nesting and build-time defaults.
Bounded models completed; production implementation and the remaining details below
are not complete.
Refines L3 of [listener-execution.md](listener-execution.md).

## Standards boundary and current source

DDS 1.4 section 2.2.2.5.2.11 describes `notify_datareaders` invoking attached reader
listeners with changed DATA_AVAILABLE status, and identifies use from the subscriber
callback. It does not specify a contended callback-exclusion algorithm. Preserving
synchronous completion here is our proposed zzdds contract; the paragraph does not
explicitly prescribe a thread or a complete scheduling/return-time model.

The general return-code rules in section 2.2.1.1 permit ERROR and ILLEGAL_OPERATION;
PRECONDITION_NOT_MET and TIMEOUT are not among the universally allowed codes and
are not expressly added by the notify_datareaders paragraph. Do not introduce an
unreviewed busy/timeout/precondition code. [DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

The current `Subscriber.vtNotifyDataReaders` iterates readers under `subscriber.mu`
and calls their generic listener dispatcher. It does not establish the proposed
retained membership, eligibility, callback rights or lock-free application-call
boundary. Generic parent fallback also requires an audit: explicit reader delegation
must select the reader callbacks required by this operation, not accidentally recurse
through the ordinary subscriber notification hierarchy.

## The conflict to resolve

Assume independently executing callback chains A and B each retain their own
callback exclusion. A requests synchronous delegation requiring B's rights, while
B requests delegation requiring A's rights. Waiting both ways deadlocks. Additional
workers cannot resolve this ownership cycle. Releasing A/B exclusion while waiting
would contradict the accepted no-automatic-reentry rule. Invoking despite exclusion
would violate shared-listener serialization. Returning OK with pending work would
change the proposed synchronous meaning.

This is not a reason to serialize all sibling readers by default. It is a reason
to define the supported synchronous dependency graph and failure boundary.

## Alternatives and recommendation

| Option | Tradeoff |
| --- | --- |
| Defer busy children and return OK | Easy progress but weakens synchronous delegation; awkward lifetime/access-bracket meaning for parent code after return |
| Reject all contention from callbacks | Avoids waits but makes the intended parent-to-reader operation fail merely because another listener is briefly busy |
| Reserve all potential child rights before entering the parent callback | Can avoid a narrow same-subscriber cycle, but broadens exclusion before the application even asks to delegate; dynamic/shared cross-subscriber listeners still complicate it |
| Track synchronous callback dependencies and reject cycles | Preserves useful waiting and independent readers; adds bounded dependency bookkeeping and explicit failure/partial-progress semantics |

Accepted direction: the fourth option, supported by the bounded experiments below.
It is not a guarantee to detect arbitrary
application lock, thread-join or GuardCondition dependencies.

## Accepted observable direction

1. Capture a bounded retained set of candidates. The accepted
   [notification boundary](listener-notification-boundary.md) fixes reader membership
   once and observes current status per dispatch claim; it does not freeze historical
   notification generations for the whole batch.
   Reader creation and later notifications do not make this invocation chase an
   unbounded moving target. Reevaluate deletion, registration and eligibility before
   each invocation; do not call a retired registration or manufacture a historical
   callback after another consumer has cleared the relevant status.
2. Delegate synchronously, one eligible child invocation at a time. Acquire its
   entity/listener/group callback rights as an all-or-retry unit. Inherit rights
   already held by the same explicit callback chain where appropriate; this permits
   a shared parent/reader listener object with different methods to nest explicitly.
   No protocol, subscriber or registry mutex remains held across application code.
3. If another chain owns required rights, register the dependency and wake obligation
   atomically with admission. Wait only if the known dependency graph remains
   acyclic. The waiter retains its own callback rights, while protocol progress and
   unrelated callbacks can continue according to runtime policy.
4. A new dependency that closes a known cycle fails rather than waiting. Use the
   accepted ERROR mapping below with a diagnostic explaining the dependency.
   Mere temporary contention is not an error. Recursive delegation and nesting
   capacity use the same return code with distinct diagnostic reasons.
5. Successful return means the retained batch has been processed: callbacks invoked
   synchronously, or candidates found no longer eligible under the defined recheck.
   No successful return with undisclosed queued delegated callbacks. This does not
   guarantee the application consumed samples or that no new data has arrived.
6. An error may follow earlier completed child callbacks. Those application effects
   cannot be rolled back. Do not consume statuses for children that were not invoked;
   leave them eligible for subsequent handling. Do not report all-or-nothing behavior.

The partial-progress rule is a real API tradeoff. Acquiring the whole batch first
could reduce pre-dispatch failures but broadens callback exclusion and still cannot
make arbitrary application callbacks transactional. No requirement to acquire an
entire subscriber's listeners is proposed for ordinary automatic notification.

## Accepted recursion, nesting and failure policy

This section records the accepted initial policy. It defines nesting without claiming that the
two-chain models validate deeper stacks.

### Supported explicit nesting

Permit delegation from a callback to a different Subscriber, subject to ordinary
admission and a bounded chain depth. Keep the intended
`on_data_on_readers -> notify_datareaders -> on_data_available` path available,
including when one object implements both listener methods. Explicit nesting can
also enter the same listener object for a different reader; the application asked
for that synchronous nesting. Other chains and automatic invocations remain excluded.

Maintain two generation-aware active sets on the execution chain:

* Active `notify_datareaders` Subscriber entity lifetimes. Reject a call targeting a
  Subscriber already in this set at API entry, before starting another traversal.
* Active reader `on_data_available` invocations, keyed by reader entity lifetime and
  callback kind. After eligibility recheck, reject an attempt to invoke an already
  active reader callback. Listener replacement does not evade this check: registration
  generation and listener identity are not the recursion key.

The second check matters when an automatically invoked reader callback calls its
Subscriber's `notify_datareaders` without an enclosing delegation. That call is
allowed to process other eligible readers; it fails if it reaches an eligible
invocation of its own active reader. An ineligible candidate is skipped normally.
Do not silently skip an eligible recursive target and return success.

Only concurrently active frames count. Sequential delegation after a previous call
returns is allowed. Application code that repeatedly calls without consuming data
or resolving an error can still loop; these rules do not police arbitrary user code.
Direct application calls to listener methods are outside middleware tracking.

### Bounded nesting

Use a default maximum of **8 simultaneously active `notify_datareaders`
frames per execution chain**, configurable per participant with a build-time-changeable
default. The first call, whether external or callback-originated,
counts as one; sequential children in its batch do not each add a frame. At the default, a ninth
call fails at entry before capturing candidates, claiming rights or consuming status.
Eight is an initial engineering default, not a measured stack-safety result.

Expose the setting through participant configuration in the zzdds extension surface,
not DDS QoS or `dcps.idl`. Standard-only applications inherit the build's default.
A value of one still supports normal Subscriber-to-reader delegation, but rejects
further nesting from those children. Keep the configured bound finite and distinguish
the default from any build-imposed storage ceiling. Document supported values and
validate configuration before use; exact generated configuration/API shape remains
to be specified. Do not create a fresh allowance when a chain crosses a runtime.

Accepted configuration refinement (2026-09-15): fix the value at participant
creation and applying the smallest limit of participants represented by active chain
frames, including the proposed target. Count total chain depth against that limit,
then restore the enclosing bound on unwind. This avoids bypass through another
participant. This cross-participant composition rule is accepted.
The [concrete identity/configuration package](listener-identity-decision.md#concrete-v1-decision-package)
refines this to include the root callback's participant even before it has an active
delegation frame, and gives creation-time validation and cross-participant examples.

This bounds library-tracked delegation depth, not arbitrary application stack use,
batch size, wait duration or graph size. Those require separate resource bounds.
The same configured limit and failure semantics apply to manual and threaded drivers.

### Return and partial-completion rules

For a valid live Subscriber, use the following mappings. Existing standard
entity-validity errors remain applicable and are not replaced by this table.

| Situation | Result |
| --- | --- |
| Retained batch processed, including empty or now-ineligible candidates | OK |
| Temporary contention with an acyclic tracked dependency | Wait, then continue rechecking admission |
| Subscriber recursion or eligible active-reader recursion | ERROR; recursion diagnostic |
| Configured nesting limit reached | ERROR; depth-limit diagnostic |
| Ownership/FIFO dependency cycle | ERROR; dependency-cycle diagnostic |
| Required candidate/admission bookkeeping cannot be reserved within its bound | ERROR; capacity diagnostic |

Use ERROR consistently for these implementation rejection cases. DDS 1.4
section 2.2.1.1 permits it generally; this avoids relying on the more restrictive
description of ILLEGAL_OPERATION for conditions that disappear after unwinding.
Do not introduce PRECONDITION_NOT_MET, TIMEOUT or OUT_OF_RESOURCES for this operation
without additional standards justification. These particular mappings are zzdds
policy, not return behavior prescribed by OMG for delegation.
[DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

Stop the current batch at the first admission failure. Retire its pending admission
before returning; do not leave a child queued to execute on behalf of that failed
call. Earlier callbacks and their status consumption remain committed. Untouched
candidates retain their normal eligibility, subject to independent consumers or
replacement. No rollback, automatic retry, or guarantee of a later automatic
callback is implied. In particular, subscriber-level routing may require another
application delegation call to handle those readers.

An inner delegation's error is returned to its immediate caller. Listener callbacks
have no DDS return code for forwarding that result: if the application handles or
ignores it and returns normally, the outer traversal can continue and return OK.
Do not propagate a hidden chain-wide error or retry inside a callback that still
holds the same obstructing rights.

Provide bounded, optional diagnostics containing the reason, affected entity
generations and configured limit or relevant dependency identifiers. Diagnostics
must not invoke another listener or call application logging code under internal
locks. A future programmatic diagnostic interface belongs in `zzdds.idl`; ordinary
DDS-only callers can rely on the documented return/partial-completion contract.
Binding-specific callback exceptions and unwinding remain a separate contract;
this table does not imply that arbitrary exceptions can safely cross an ABI.

### Acceptance traces for implementation

Cover ordinary shared-object parent/child nesting; different-Subscriber nesting up
to the limit and rejection one level beyond it; A -> B -> A Subscriber recursion;
automatic reader entry followed by self-targeted delegation; replacement of that
active reader's listener; sequential calls after unwinding; and an inner error
handled by a callback while the outer call succeeds. For every rejection, verify
unchanged status for uninvoked candidates, complete wait withdrawal, and preserved
effects of earlier children. These are future implementation checks, not results
of the existing two-chain models.

## Interaction with existing decisions

* The parent callback retains exclusion while waiting. Nested helping does not
  automatically dispatch unrelated callbacks on that stack.
* Explicit child calls remain part of the callback chain for replacement semantics;
  their `set_listener` calls are therefore asynchronous under the accepted contract.
* Pending, unclaimed target registrations may be replaced; restart the applicable
  admission/eligibility check. Already claimed invocations retain their generation.
  Result/cancellation paths retire wait edges and wake obligations exactly once.
* GROUP callback access guards remain retained through the delegated batch. They
  do not turn shared consumption into a private sample snapshot. Non-GROUP builds
  need no GROUP access machinery merely to perform delegation.
* FIFO admission itself can create dependencies on earlier queued callback work.
  A graph containing only currently executing listener owners is insufficient.
  Waiting for older reservations/eligible turns must be represented too, or the
  scheduler must use another audited protocol that prevents such cycles.

## Evidence needed before selecting the mechanism

### Completed admission experiment

Run `python3 docs/design/listener_delegation_model.py`. The model explores 83
scenarios: every disjoint initial ownership of two exclusion rights by two chains,
every nonempty one-child target pair, and two additional two-child batch scenarios.
Result: **1,481 scenario-states, 1,928 transitions**. Every explored state preserves
exclusive ownership, queue membership and an acyclic dependency graph, and has a
path to both parent callbacks returning. Witnesses cover inherited rights,
opposite-direction delegation and an earlier child completing before cycle rejection.

The owner-only negative control reaches a deadlock in two publications:

1. A holds X. B queues a callback requiring both X and Y; it holds neither while waiting.
2. A delegates to a child requiring Y. Y is free, but B has FIFO priority for it.
3. A waits for B's queued admission; B waits for A to release X.

Including the queue edge rejects A's delegation before publishing that wait. A can
then return and release X, allowing B to run. The example requires no simultaneous
active ownership by B and cannot be detected from active owners alone.

The modeled FIFO rule is per conflicting **additional** right: a waiter depends on
older queued requests for rights it still needs. Already held rights remain inherited
by explicit child calls; queued requests cannot revoke that ownership. Claiming all
additional rights, publishing a wait, and checking the complete graph are atomic
transitions in this model. Admission cannot gain a new untracked prerequisite after
the check. A production queue/graph design must preserve these properties, including
when registration changes alter the required rights.

This supports retaining dependency-aware synchronous delegation as the recommendation.
It does not validate a concrete lock algorithm, graph storage bound, fairness under
infinite arrivals, latency, or arbitrary application dependencies. Completion paths
assume runnable application callbacks eventually return; they are existential checks,
not a scheduling fairness proof. Roots are initially active, child calls do not
delegate further, and there are only two chains and two rights.

Replacement, cancellation/deletion, stale wakes, active-reader recursion, status
consumption and cross-runtime identity are deliberately outside this experiment.
Their transition/lifetime rules still need review before the full mechanism is
selected. In particular, removing a pending request must remove its queue obligations;
changing its target must perform fresh admission and cycle checking.

### Remaining evidence

The replacement/removal admission experiment below is complete. Active-reader
recursion, larger graphs and deeper explicit nesting remain validation requirements,
along with concrete retirement, stale-wakeup and queue implementation behavior.

### Replacement and removal follow-up

Run `python3 docs/design/listener_delegation_retirement_model.py`. This extends the
admission model with one external registration replacement or target removal,
interleaved with publication, claim, callback completion and parent return. It
enumerates **648 scenarios, 27,448 scenario-states and 46,058 transitions**. Checks
cover exclusion, queue membership, acyclic dependencies, claims against the current
generation, preservation of already claimed generations, and a completion path from
every state including after the external event. Registration generations are scalar
identifiers here, not a model of application memory or release hooks.

The negative control changes a waiting child's required rights without withdrawing
its queue entry or checking admission again. A holds X, B queues X+Y, and A queues
a child needing inherited X. Replacing that child's target with Y creates A -> B
through FIFO and B -> A through ownership. Replacement must not silently introduce
such an unchecked dependency.

Accepted initial transition contract:

* **Replacement before claim:** invalidate and withdraw the old admission, including
  its queue obligations. Preserve the retained reader/notification candidate and
  recheck it against the current registration and mask. If still eligible, obtain a
  fresh queue position and run ordinary cycle-checked admission. Replacement must
  not fail merely because this later delegation attempt encounters a cycle; that
  failure belongs to the delegation operation. Retrying does not consume its status.
* **Removal/ineligibility before claim:** withdraw admission and skip that candidate.
  Cancellation of an internal attempt also withdraws admission, but the containing
  operation's cancellation result is a separate policy. This experiment treats
  removal as a skip; it does not approve DDS entity deletion from arbitrary contexts
  or define deletion/cancellation return codes.
* **Claim before replacement/removal:** the invocation keeps its claimed registration
  and rights until completion. It can enter application code after publication of
  the change. External setter quiescence still waits for its applicable frontier;
  callback-context replacement still does not wait. Claim and invalidation need one
  ordered synchronization boundary, not two independent eligibility checks.
* **Wait retirement:** invalidate the attempt's wake generation and detach its queue
  obligations before admitting a replacement attempt. Reevaluate affected waiters
  and arrange progress when withdrawal removes their last blocker. A delayed wake
  identifies an attempt, not just an entity or reused slot; it cannot claim, cancel,
  or complete a newer attempt. Scheduler records surviving quiescence must not
  dereference retired application listener state.

Fresh FIFO position is the conservative baseline even when replacement happens to
retain the same identity. Preserving priority is a possible later optimization only
with an audited equivalence rule. Repeated application replacement can repeatedly
restart admission; this proposal makes no starvation guarantee under endless changes.
The retained candidate batch remains bounded even though an individual call's wait
duration is not thereby bounded.

The model makes withdrawal atomic and derives dependency edges from current queue
and ownership state. It therefore validates the abstract cleanup rule, not an
incrementally maintained graph or actual wake delivery. It does not model stale wake
records, cancellation racing a release hook, arbitrary generation reuse, or repeated
replacement. Those need implementation tests; the earlier retirement fixture covers
the separate frontier rule. No additional public API is introduced by these rules.

Unresolved design details include the precise candidate/notification cut, progress
across runtimes, concrete queue edge representation and diagnostic plumbing.
The [notification-boundary proposal](listener-notification-boundary.md) now provides
the accepted membership/current-status choice and identifies the Subscriber reset
interaction and pending-status withdrawal requirement. A bounded status fixture
provides initial evidence; production coordination remains unimplemented.
Participant configuration shape and cross-participant limit composition remain open.
The accepted [selection policy](listener-selection-audit.md) bypasses reader masks
for explicit delegation, selects attached reader callbacks only, and skips missing
callbacks without consuming status. The nil behavior intentionally differs from the
audited OpenSplice/OpenDDS behavior.
The specification must not advertise a proven
cycle-free implementation until those edges are covered. Identity-domain scope
across runtimes must match the scope of tracked middleware dependencies.
