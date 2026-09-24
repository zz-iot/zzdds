# Callback failure and binding unwind policy

Status: post-entry exception policy accepted, 2026-09-14; pre-entry preparation remains open. This note specifies failure after listener
entry and identifies the separate pre-entry conversion boundary. No generator or
production runtime changes are made here.

## Accepted post-entry behavior

Catch a recoverable language exception at the generated listener bridge, report a
bounded internal failure outcome, and return normally through the C ABI. The core
then completes the invocation's normal ownership cleanup. Do not depend on language
unwinding through Zig frames to release execution rights or retirement obligations.

| Context | Accepted result after contained listener exception |
| --- | --- |
| Automatic callback | Report failure, release invocation ownership, continue normal scheduling |
| Explicit delegated child | Complete cleanup, stop this delegation batch and return ERROR to its immediate caller |
| Callback catches its own exception and returns normally | Ordinary successful callback completion |

Do not retry the failed invocation, restore already-consumed status, undo application
side effects, implicitly delete the entity or automatically remove the listener.
A callback that throws has already entered and may have read samples, published data,
replaced its listener or logically deleted entities. Those effects remain committed.
New status changes during execution retain their normal pending state. Later fresh
notifications may invoke the same listener again; repeated failure diagnostics must
be bounded/rate-limited without erasing DDS status information.

This default contains propagation; it does not prove that the application's state
is usable after an exception. Applications needing termination or recovery sequencing
should handle that inside their listener or a future explicit failure-policy extension.
Such controls belong in zzdds.idl and must not change ordinary callback signatures
on dcps.idl. No new mandatory application listener methods are proposed.

An inner notify_datareaders returning ERROR is still different from its caller
throwing. If the caller handles that ERROR and returns normally, the outer operation
may succeed, as already accepted. If the caller itself throws, its own invocation
fails and the immediate containing delegation observes that failure.

## Binding boundary and ownership

C++ generated trampolines should contain a try/catch boundary around callback entry
(and classify failures from adaptation separately). Adding noexcept alone would
terminate on an escaping exception rather than report it. Exception-disabled builds
cannot promise interception of exceptions; supported callbacks there must return
normally. Abort/terminate, undefined behavior and nonlocal jumps across the bridge
are outside recoverable cleanup guarantees. Raw C callbacks must not longjmp over
core frames; Zig callback panics are not modeled as recoverable error returns.

Java generated trampolines must inspect pending JNI exceptions at fallible JNI steps
and after invocation, capture/report a callback-local failure and clear the pending
exception before returning control to core processing. JNI exceptions do not unwind
native frames automatically; only restricted JNI operations are permitted with an
exception pending. Local reference frames and thread attachment ownership require
explicit cleanup. Do not clear an unrelated pending exception at callback entry or
continue normal conversion after a failed lookup/allocation.
[JNI design, exception handling](https://docs.oracle.com/en/java/javase/24/docs/specs/jni/design.html#exception-handling).

The callback ABI currently returns void. A bridge therefore needs an internal
invocation-outcome mechanism: for example, a scoped per-invocation record accessible
to generated bridges, or a versioned descriptor outcome hook. It must distinguish
nested invocations, restore the outer frame on return, and carry the same explicit
chain across supported binding/runtime transitions. One sticky thread-wide error
flag is insufficient. Exact ABI shape is open alongside identity metadata; no raw
exception object is required to cross the ABI or be retained after reporting.

Cleanup has one structured epilogue on every recoverable path: retire the active
invocation frame, release callback rights/access guards and retained arguments,
settle applicable references/hooks, then publish wakes and failure reporting without
internal locks spanning application code. Do not drop the application-access drain
obligation before cleanup that can still touch borrowed listener state has finished.
A diagnostic record must not keep a borrowed listener pointer alive implicitly or
reenter a listener while its rights remain held. Basic failure reason/entity-generation
reporting must work even if richer diagnostic allocation fails.

A throwing release hook is not equivalent to a failed listener method: catching it
does not establish that the hook completed its ownership duties. Require lifecycle
release hooks to complete without throwing. Violations cannot be reported as successful
quiescence unless remaining access/ownership is independently proven; they need a
binding fatal-error policy, not a silent success path. This constraint belongs in
the binding ownership contract and requires explicit documentation.

## Pre-entry failures remain a separate boundary

Failure to attach a Java thread, box arguments, allocate storage or resolve a method
can occur before the application listener is called. Do not label those as completed
listener invocations or silently consume status contrary to the accepted uninvoked
candidate rule. Prepare required binding resources before the final status-consumption
commit, then revalidate registration/status at commit. Fallible or application-running
argument construction must occur outside core locks. Mutable status snapshots may
require reconstruction or a supported prepared representation before final claim.

The exact prepare/claim/entry handshake needs its own bounded design review: an
unconditional "restore the old counters" rollback could overwrite newer changes or
duplicate changes already consumed by a concurrent getter. This note does not solve
that problem by treating an allocation failure as an application exception. Explicit
pre-entry failure should return ERROR without invoking that child; automatic retry
and resource backoff must be bounded and avoid a hot failure loop. Their detailed
policy remains open until the handshake is specified.

## Current source findings

zidl/src/backend/cpp.zig::emitListenerBridgeMethods emits a direct call through the
ListenerBase trampoline without a catch boundary. Wrapper adaptation can also occur
in that call expression. Therefore current generated C++ bridges do not supply the
proposed failure containment/outcome protocol.

zidl/src/backend/java.zig::emitTrampoline checks after CallVoidMethod and currently
prints/describes and clears an exception, but communicates no outcome to the core.
Earlier FindClass/GetMethodID/NewObject/boxing steps do not each establish the needed
failure checks in this emitter, and it emits no local-reference-frame boundary here.
A missing JNIEnv simply returns. These are source observations, not executed JNI or
C++ exception tests. Core ListenerBox retention alone cannot fix these bridge semantics.

## Next decision and validation boundary

The contained-exception default is accepted: automatic scheduling continues,
explicit delegation returns ERROR with partial progress, and listeners remain installed.
Next specify the pre-entry preparation handshake before implementing tests for status
consumption versus adaptation failure. Binding integration tests should cover throw
after side effects, nested delegation failure, replacement/deletion then throw, JNI
conversion failure, later invocation on the same worker, and hook retirement while an
external deletion waits. Fatal/nonlocal exits are not part of a recoverable test claim.

## Accepted initial preparation protocol (2026-09-14)

The discussion selected optimistic prepare/validate/commit, bounded retry, and
callback-chain lifetime/reentrancy handling during preparation. This supersedes the
open direction above, while leaving the final invocation failure boundary and exact
retry budget as named refinements. No implementation or model results are claimed.

1. Retain a candidate entity lifetime and current registration, and snapshot the
   applicable status with a validation version. Capturing does not reset status.
2. Prepare binding arguments and required storage outside internal locks and without
   holding callback execution rights merely to perform conversion. The preparation
   carries a retained application-access obligation and execution-chain context.
3. At final admission, validate entity lifetime, selected registration, eligibility,
   status version and execution rights together. For a valid candidate, claim the
   callback and reset status at the same ordered boundary. Invoke with the already
   prepared arguments after releasing internal locks.
4. If validation fails, consume nothing. Recheck whether the candidate is still
   eligible; skip if no longer eligible, otherwise refresh preparation within the
   bounded retry policy. Binding conversion/allocation failure returns an explicit
   failure outcome rather than pretending a callback occurred.

The version must distinguish updates and consumption, including zero-net changes.
A status getter or another dispatch invalidates a prepared aggregate. Comparison of
counter values alone is insufficient. Replacement/deletion invalidates unclaimed
preparation; any remaining cleanup retains its application-access obligation through
its last relevant access. A prepared argument is not a callback claim and does not
permit invocation on a retired registration.

### Retry and placement rules

Limit preparation/revalidation attempts per service turn. Automatic work retains
pending status and yields for a later scheduling opportunity; resource-failure retries
must use bounded backoff or an explicit resource wake, not immediate busy spinning.
Do not silently disable the listener or erase the notification. Explicit delegation
also has a finite total preparation-retry budget for each candidate; exhaustion stops
the batch with ERROR, preserving unconsumed status and earlier child effects.

Ordinary waiting for busy callback rights is not itself a failed preparation attempt.
A wake may require revalidation and another preparation if state changed, but must not
turn mere contention into a busy error. Release scarce prepared resources while waiting
where necessary, without falsely marking the candidate handled. Exact retry counts,
resource retry delay and visibility/configuration are still to be specified; no
numeric default was selected in the discussion. Any finite retry rule means that
continuous state interference can cause explicit ERROR rather than guaranteeing
progress at the cost of an unbounded preparation loop.

JNI local references and other thread-affine preparation cannot migrate to a different
worker unchecked. Prepare and commit on the appropriate thread, discard/reprepare on
migration, or explicitly use transferable retained representations. Executor placement
is a constraint on the prepared invocation, not permission to reuse a foreign JNIEnv.

### Preparation's execution-chain boundary

Foreign constructors/adapters can re-enter the library. During those calls, install
the same chain classification used for callback-context replacement and deletion:
reentrant management calls publish/close without waiting for the preparation itself
to retire. An external management caller still waits for relevant preparation access
to finish before claiming quiescence. Carry this classification across supported
binding/runtime crossings, and unwind it reliably on every recoverable exit.

Preparation does not mean the application listener method has entered; it does not
consume status or automatically inherit new listener exclusion rights. The generated
preparation implementation must not access mutable application listener state without
its own appropriate protection. Listener method recursion and binding-preparation
recursion are not interchangeable: whether reentrant explicit delegation during
constructor/adaptation execution needs an additional preparation recursion guard is
a remaining boundedness review. Do not assume active-reader callback checks already
cover a reader callback that has not entered yet.

### Final invocation boundary still requiring review

All ordinary fallible allocation, method lookup and argument conversion must finish
before final commit. After commit, dispatch enters the prepared bridge. Post-entry
application exceptions follow the accepted containment policy and do not undo status.
Failures at the final native-to-language entry itself need explicit classification;
a VM failure before the listener body is not automatically a post-entry application
exception. Do not promise a safe status rollback across concurrent getters/new changes.
This boundary and preparation recursion are the next narrow review, before a fixture
or ABI implementation freezes the protocol.

## Preparation recursion and final entry audit (2026-09-14)

Status: preparation recursion protection and irrevocable dispatch-attempt boundary
accepted, 2026-09-14. Implementation and bounded validation remain outstanding.

### Extend the recursion guard across preparation

Register a chain-local active dispatch frame keyed by entity lifetime and callback
kind before any foreign argument preparation. Keep it through preparation, validation,
invocation and foreign cleanup. A nested explicit delegation attempting that same
entity/kind fails with the existing recursion ERROR, even if the listener method has
not entered. Replacement does not evade the key. Sequential retries reuse the frame
without increasing nesting; they must not recursively call the preparation routine.
Different targets can still nest through explicit delegation within the accepted
chain-depth limit. Automatic callbacks remain prohibited on a nested pump stack.

For example, automatic preparation for reader A constructs a wrapper whose code
calls notify_datareaders. If that traversal reaches A, reject its attempt before
preparing A again. It may have handled earlier eligible other readers, so existing
partial-completion semantics apply. This closes a hole that an entered-listener-only
recursion guard misses. The dispatch frame tracks recursion and lifetime, not exclusive
rights over the listener during argument construction. Independent chains still use
ordinary admission; any duplicate prepared observations revalidate before claim.

The Java marshaler currently emits constructors and setter method calls during
_fill_java (for example nested-struct and string handling around lines 7080–7097 of
zidl/src/backend/java.zig). The trampoline also boxes entity arguments. These calls
justify treating conversion as foreign execution rather than assuming it is a pure
native copy. The audit does not assert that every generated setter currently reenters
DDS; the protocol must remain sound if an allowed adapter or initialization path does.

### Final entry cannot provide a universal body-start proof

The current Java bridge calls CallVoidMethod and then checks for a pending exception.
That interface reports an invocation exception; it does not return a separate marker
proving the first instruction of the application's listener body ran. Inspecting the
exception type or stack trace is not a reliable general entry protocol. An additional
Java dispatcher could provide more markers but would still have a boundary before
the final user-method invocation. C++ bridging also must not claim recovery from
terminate, stack failure or other fatal behavior merely because try/catch is present.
[JNI method invocation](https://docs.oracle.com/en/java/javase/24/docs/specs/jni/functions.html#calltypemethod-routines-calltypemethoda-routines-calltypemethodv-routines).

Treat status consumption commit as an **irrevocable dispatch attempt**, with
these explicit outcomes:

* Preparation or final validation fails before commit: no status consumption and no
  callback attempt. Preserve the accepted recheck/retry or ERROR behavior.
* Commit succeeds: prepared arguments and rights are fixed, status is consumed, and
  the bridge makes the final invocation attempt without intervening ordinary fallible
  conversion or admission cancellation. Replacement/deletion cannot revoke this claim.
* Invocation reports an exception/failure after commit: record failed dispatch, clean
  up and apply automatic reporting or explicit ERROR. Do not restore consumed status
  or replay the invocation, even when actual listener-body entry cannot be established.

This is a deliberate qualification of the earlier "no consumption if the listener
never ran" wording. That guarantee remains valid for preparation/validation failures;
it cannot be promised for every language-runtime failure at final entry with the
current bridges. Do not describe uncertain entry as a proven application exception.
Diagnostics should distinguish preparation failure, known application failure where
available, and committed invocation failure with unknown entry.

A callback's committed status observation is not sample consumption. A failed entry
can leave samples available through normal access, but must not manufacture a new
status notification solely to replay the failed invocation. New independent status
changes remain pending normally. This makes failure semantics consistent across
thread placement without guessing whether application side effects occurred.

The alternative is a larger language-entry/status-consumption handshake, with explicit
coordination of concurrent getters and user-body dispatch. It increases binding/core
coupling and still needs a precise boundary for fatal or asynchronous runtime failure.
The committed-attempt contract is the accepted initial choice, including this
qualification of the earlier listener-body-entry guarantee.

### Next validation

Use a bounded prepare/validate/commit fixture covering version change, getter reset,
preparation failure, retry exhaustion, recursive preparation, and final invocation
failure. Assert consumption only on commit, no rollback after commit, no duplicate
entry caused by failure, preservation of newer changes, and frame cleanup on every
recoverable path. Binding tests must additionally inject JNI/C++ failures; a scalar
model cannot establish runtime entry behavior. Exact retry budgets remain open.

## Bounded preparation validation completed (2026-09-14)

Run `python3 docs/design/listener_preparation_model.py`. The fixture explores
**584 states and 995 transitions**, with two permitted preparation snapshots, two
status updates and one getter. The snapshot limit is an experiment bound, not a
selected production default. Initial validation exposed that one update plus a
getter could not exercise exhaustion while leaving status eligible; the fixture
therefore includes two updates and asserts that exhaustion is actually reachable.

All five outcomes occur: successful invocation, invocation failure, preparation
failure, ineligibility skip and retry exhaustion. Checks establish observed-plus-
pending counter conservation, at most one commit, unchanged status on precommit
failure/retry, immutable claim arguments and retained frame/access bookkeeping
through cleanup. Every reachable state has a path to terminal cleanup under finite
external activity. A same-target recursive preparation attempt is rejected while
its outer frame remains retained; new changes can survive committed invocation
failure and cleanup.

Two negative controls demonstrate the expected violations:

* Ignore snapshot version: capture, new change, prepare, commit stale arguments;
  the newer unobserved change is lost.
* Restore a committed snapshot on invocation failure: already-consumed changes become
  pending again, violating the irrevocable-attempt rule and permitting duplicate
  observation even without another intervening consumer.

Scope: one scalar status/candidate, atomic snapshot/validation/commit, explicit-call
failure outcomes and finite retries. The recursion check is a single nested attempt,
not a full multi-target recursion model. No real foreign constructors, ABI outcome
record, Java thread affinity, listener replacement/deletion, right contention,
registration generation reuse, resource backoff or OS wake behavior are implemented.
The access record is boolean ownership bookkeeping, not a reclamation implementation.
Existing retirement/delegation fixtures cover separate slices; their composition
still needs binding/runtime integration tests. Actual final listener-body entry is
intentionally not inferred from a committed attempt.

Next choose the finite retry limits and automatic retry/resource-wake policy as part
of the runtime progress/resource configuration contract, then complete L5's audited
operation-specific waits and closure results. No further preparation model expansion
is required unless that work exposes a new observable-policy uncertainty.

## Retry defaults and scheduling: accepted configuration (2026-09-14)

The preparation mechanism, numeric defaults and scheduling details in this section
are accepted as the initial configuration. Values are engineering starting
points, not measured latency or embedded-memory guarantees.

| Setting | Proposed default | Meaning |
| --- | ---: | --- |
| Preparation attempts per service turn | 2 | Maximum snapshot/convert/validate attempts before yielding execution |
| Stale validations per explicit candidate | 8 | Maximum failed status/registration validations across turns before ERROR |
| Automatic preparation-failure retry delay | 1 ms initially, doubling to 1 s maximum | Fallback when conversion/resource failure has no dependable resource-ready signal |

Configure these per participant at creation through the zzdds configuration surface,
with build-time-changeable defaults and finite supported bounds. No dcps.idl or
standard QoS additions are implied. Require positive counts/delays and initial delay
no greater than the cap. Manual drivers expose the next retry deadline through the
normal timer/progress interface; retry timers do not create a helper thread.

The per-turn count applies to actual preparation work. The explicit cumulative budget
counts stale validation, not waiting for execution rights or releasing thread-affine
prepared objects solely because a worker changes. Check deletion/ineligibility before
charging a stale retry: an ineligible target is skipped, not converted into an error.
A still-eligible candidate that reaches eight stale validations returns ERROR without
another attempt. Replacement does not reset that candidate's cumulative budget.
Each new explicit call starts a new budget; application retry loops remain application
behavior. Count work across all turns/binding transitions of the same candidate.

### Distinguish the causes

* **Status/registration changed during preparation:** automatic work refreshes within
  its turn budget, then yields at the tail of runnable preparation work. Keep its
  existing eligible notification/admission age where the accepted ordering permits;
  scheduler service position is distinct from notification age. Registration changes
  still require fresh admission. Do not clear the status or reset counters on retry.
* **Callback rights busy:** follow the existing admission/wake protocol. Do not retry
  conversion in a tight loop while rights remain unavailable or count wait duration
  as stale validation. The fast path still prepares and claims inline when eligible.
* **Recoverable conversion/resource failure:** explicit delegation reports ERROR
  immediately with prior effects retained. Automatic notification stays pending and
  arms one bounded retry obligation, preferably a generation-safe resource-ready
  wake. Without dependable notification, use the capped timer above.
* **Committed invocation fails:** use the accepted exception reporting/ERROR policy;
  never schedule a replay of the consumed notification. A genuinely newer change is
  independently eligible.

New data does not bypass an existing resource-failure backoff or create another timer
for the same pending opportunity. Successful preparation resets the failure delay;
ordinary new arrivals do not. Replacing the listener invalidates old wake tokens and
permits a new registration attempt, but must not duplicate retained work. Resource
notifications can request an earlier attempt, coalesced and subject to normal runtime
service budgets. They must not synchronously dispatch callbacks from the resource
release path. Resource-waiting opportunities retain status but do not reserve scarce
callback rights or block unrelated entities' admission.

A known structural bridge error (missing method, incompatible descriptor, invalid
binding setup) is not transient memory pressure. Report it distinctly and suppress
blind timer retries for that unchanged broken configuration. Reattempt on relevant
registration/configuration repair or explicit application delegation, reporting ERROR
if still broken. This does not remove the installed listener or consume its status;
it is a visible dispatch fault, not a silent automatic unregistration. Exact diagnostic
surfacing belongs to the binding/runtime reporting interface.

### Fairness and remaining performance limits

A failed preparation turn must give other runnable contexts/preparations a service
opportunity before being serviced again. Resource backoff prevents persistent memory
failure from consuming every scheduling round. Two attempts is a work-count bound,
not a wall-clock bound on Java constructors or other foreign code. No deadline can
preempt arbitrary application code. Stable fixed-size native arguments normally
need one attempt and no timer, allocation or mandatory worker handoff introduced by
this retry policy.

The same-entity notification ordering guarantee remains: a continuously eligible
older opportunity is not silently bypassed by newer kinds merely because its status
changes often. Consequently sustained interference can delay later same-entity
notifications. This is an acknowledged limit of the accepted first-pending policy,
not a reason to fabricate stale callback arguments. Resource/structural failure
eligibility and any stronger bypass policy must be explicit rather than an accidental
scheduler optimization. Unrelated entities still receive normal service.

Next fold these accepted retry timers, resource wakes and operation-specific
deadlines into the L5 wait/closure matrix. Numeric benchmark tuning and actual timer/backoff tests belong to implementation;
the earlier scalar fixture does not claim validation of these new values.
