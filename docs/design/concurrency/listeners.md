# Concurrency: listeners

Requirements use the [shared convention](../concurrency-broker-status.md#requirement-convention).
[The index](../concurrency-broker-status.md) owns scope and unresolved design items;
[the evidence inventory](../../../test/design-models/README.md) records validation.

The contract covers exclusion and identity, preparation/dispatch failure, status routing,
explicit delegation, then replacement and deletion. Application-facing configuration
is defined in the extension API; no callback-group configuration is needed for the defaults.

<a id="listener-execution-contract"></a>
## Listener execution contract

<a id="purpose-and-api-boundary"></a>
### Purpose and API boundary

Provide predictable callback serialization, ordering and lifetime behavior while preserving direct, low-latency delivery. Standard DDS-only applications must get useful defaults without using extension methods. Threaded and application-driven backends must implement the same observable listener contract; their placement and timing may differ.

OMG operations belong in `dcps.idl`. New application controls for callback groups, executors, affinity, or driving progress belong on zzdds extension entity interfaces in `idl/zzdds.idl`. Generate bindings from that IDL rather than hand-editing generated surfaces. No public listener-identity accessor is required. Internal binding support for identity must not require inventing an operation on an OMG interface.

Distinct reader listeners under the same Subscriber remain independent by default. A shared listener or an explicitly configured group can provide broader serialization. A Subscriber is not automatically one execution group for all its children.

<a id="omg-boundary"></a>
### OMG boundary

DDS 1.4 §§2.2.4.2–2.2.4.3 define status reset behavior, the most-specific enabled listener for plain statuses, subscriber-level precedence for data notifications, and permitted aggregation of status changes. These sections do not prescribe a general listener-object mutex or executor. This contract adds an explicit execution contract while preserving those semantics. [DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

`Subscriber::notify_datareaders()` invokes eligible reader listeners and is expressly intended for use from `on_data_on_readers()`. Explicit delegation therefore needs distinct treatment from accidental callback re-entry. Callback count is not sample count: DDS does not require a callback for every individual change. [DDS 1.4 §§2.2.2.5.2.11, 2.2.4.3.2](https://www.omg.org/spec/DDS/1.4/PDF).

Do not describe this contract as an OMG-mandated threading model or as proof of general DDS conformance. Data access ordering and coherent presentation remain responsibilities of DDS history/presentation processing, not of the callback scheduler.

<a id="terms"></a>
### Terms

| Term | Meaning |
| --- | --- |
| Entity generation | A particular live entity lifetime; prevents pending work from targeting a reused handle |
| Listener identity | A stable identity for one application listener instance across methods and registrations |
| Registration generation | One installation of a listener and mask on an entity |
| Callback group | Explicit shared exclusion domain for listeners that access related application state |
| Dispatch eligibility | Relevant status is pending, listener selection is valid, and ordering/lifetime conditions permit invocation |
| Execution rights | Scheduler ownership of the entity, listener and optional group needed for a callback |
| Automatic invocation | Callback initiated by middleware status/data processing, including nested protocol pumping |
| Explicit delegation | Application-requested listener invocation through `notify_datareaders()` |

Serialization means no overlapping automatic invocations in a shared exclusion domain. Non-reentrancy also excludes nesting on the same thread. Neither implies fixed thread affinity. Execution rights are scheduler state, not entity/protocol mutexes held while executing user code.

<a id="default-behavior"></a>
### Default behavior

Requirements:

1. Automatic callbacks for one entity are serialized across methods, including callbacks resolved through parent listeners.
2. Automatic callbacks to the same identifiable listener instance are serialized across registrations and methods. Shared listener identity across bindings is a release gate, not a property supplied by today's `ListenerBox`.
3. Different listeners on different entities may execute concurrently unless explicitly grouped. Sibling readers do not inherit subscriber-wide exclusion.
4. A blocking operation inside a callback does not implicitly release its execution rights or permit automatic re-entry.
5. Eligible automatic callbacks run inline by default when execution rights are immediately available and there is no earlier pending work they must follow. No mandatory worker handoff or queue allocation is introduced on the uncontended path.
6. No stable OS-thread affinity is promised by the default. A later callback may execute on another worker after the previous one finishes.
7. Notifications reflect committed DDS state. No user callback runs while an entity, history, transport, or protocol-state mutex is held.
8. Listener and entity lifetime protections remain in force while a callback executes or explicit delegation retains them.

The blanket lock rule in item 7 is a target requirement and requires a call-chain audit. Dropping the reader lock is insufficient if the caller still holds a participant or subscriber lock.

<a id="inline-path-and-pending-work"></a>
### Inline path and pending work

The dispatch boundary must obey this sequence; its queue representation is an implementation choice:

1. Under state ownership, commit the relevant state change, update status/conditions and publish notification eligibility/order.
2. Select the applicable listener through DDS routing rules. Atomically coordinate eligibility, registration generation and execution-right acquisition.
3. If immediately eligible, consume the appropriate status at the dispatch boundary, retain required objects, release internal locks and invoke inline.
4. Otherwise retain bounded pending status work. Do not block a receive worker waiting to enter a busy listener.
5. On callback return, release execution rights and recheck pending work without a lost-wakeup window. Continue inline within a fairness budget or schedule continuation.

Multiple overlapping exclusion domains require an all-or-retry reservation protocol or equivalent scheduler coordination. Do not acquire blocking listener/group locks one at a time across user code. New arrivals cannot bypass already eligible earlier work merely because they arrived on a faster worker.

Pending work should normally identify an entity/status and relevant generations, rather than copy an unlimited event log. Allocate reusable pending storage at entity/registration creation where practical. Overload must not silently erase accumulated status counters or cause unbounded allocation. Precise limits and failure reporting require the resource-policy design.

A low-latency build must not disable serialization, ordering or lifetime guarantees. Build-time specialization may eliminate synchronization only when exclusive execution is established, including interrupt/other-core boundaries. Different executor availability or default placement is acceptable; different safety semantics are not.

Inline-when-eligible is the initial placement policy. Future designated-executor or
application-controlled dispatch may constrain placement but cannot relax exclusion;
those extensions are outside the first shipped surface.

<a id="creation-time-explicit-groups"></a>
### Creation-time explicit groups

The [extension surface](extension-api.md#concurrency-extension-surface) records optional fixed
entity group membership through creation Configs. Listener replacement preserves
membership; groups supplement shared-listener identity exclusion and may span
runtimes in one core. No parent-to-child inheritance or thread affinity is implied.
Existing same-chain explicit delegation remains permitted under its admission rules.

<a id="listener-identity"></a>
## Listener identity

<a id="canonical-identity-requirements"></a>
### Canonical identity requirements

A loaded core instance means the concrete core identity-registry
instance shared by its bindings, not merely a library filename or an OS process;
independently instantiated/static-linked registries are separate domains. Internal
keys must include their identity kind/namespace (native context, C++ complete object,
or Java VM/object token) to prevent accidental numeric collisions. Cross-binding
aliases require deliberate canonicalization; pointer equality across unrelated
namespaces does not establish shared object identity.

Reinstalling the same live listener while an old registration is retiring must find the
same exclusion record. Registry removal occurs only after registrations, active chains,
pending uses and claims retire under registry synchronization. Address reuse obtains a
new generation; it cannot make destruction of a still-used application object safe.
Cross-runtime exclusion release signals retained destination wake obligations without
recursively driving that runtime or invoking application code under registry locks.

The scope has a deliberate cost: sharing a listener across participants/runtimes
couples their callback admission, so a slow callback can delay another registration
of that object. Unrelated listener identities retain independent execution. Registry
metadata synchronization is short-lived; scope does not introduce a global callback
lock or authorize a waiter to drive an otherwise unpermitted runtime. A dependency
can be tracked across runtimes without granting execution permission there.

1. **One default identity domain per loaded core library instance.** All its factories,
   runtimes and participants use that domain automatically. Separate loaded core
   copies are separate domains; do not claim universal process-wide exclusion.
   Cross-copy domain federation is deferred. An optional configuration must not
   silently weaken standard-only shared-listener exclusion.
2. **Object identity, not callback implementation identity.** Raw C/Zig registrations
   with the same non-null application context share an identity independently of
   their callback tables. Null contexts get per-registration identities and per-entity
   exclusion, not an implicit global gate. C++ adapters supply complete application
   object identity across supported interface views. Java adapters canonicalize the
   actual Java object within its VM; separate wrapper allocations and identity-hash
   collisions cannot split or merge listener identities incorrectly.
3. **Dispatch context and identity key are separate.** Preserve the exact pointer
   required by each callback trampoline even when its canonical exclusion identity
   differs. Never replace an adjusted C++ base pointer with a complete-object pointer
   and pass it to a trampoline expecting the original base. Metadata identifying
   the binding/key namespace prevents accidental collisions between VM/object tokens
   and unrelated native addresses. Cross-language aliasing requires explicit adapter
   metadata expressing the common object; arbitrary foreign wrappers are not inferred.
4. **Retained identity on the hot path.** Canonicalize at registration and retain
   the record through dispatch/admission. Callback entry does not perform a Java
   object search, C++ identity discovery or fresh registry allocation. Registry
   synchronization protects lookup/retirement; it never spans application callbacks.
   One-thread builds may specialize synchronization only under the existing complete
   execution-exclusivity requirement. The default scope does not mandate a shared
   worker pool or participant-wide callback serialization.
5. **One chain across supported runtime/binding crossings.** Explicit synchronous
   delegation carries chain identity, inherited rights, active recursion frames and
   depth into the destination runtime. Identity-domain dependency tracking and
   callback-context setter detection use that same scope. A posted asynchronous task
   or application-spawned thread does not inherit rights by causal association.
   Cross-runtime admission retains a destination wake obligation; it cannot assume
   that another worker exists, nor recursively invoke arbitrary callbacks there.
6. **Bounded lifetime and failure.** Identity records retire only after registrations,
   claims and pending internal users release them. Generation reuse cannot substitute
   for lifetime protection. Registration capacity failure preserves the installed
   registration; setter resource-failure mapping is an [open API item](../concurrency-broker-status.md#open-design-items). Internal stale
   records surviving external quiescence must contain no borrowed application access.

<a id="participant-nesting-limits"></a>
#### Participant nesting limits

Fix each participant's positive finite nesting limit at creation. Standard-only
creation uses the build-time default (initially eight). Explicit configuration belongs
in `zzdds.idl` or its generated participant configuration surface. Distinguish a
build's configurable default from its supported maximum capacity; validate the value
before publishing the participant. Zero is invalid, rather than a hidden unlimited
or delegation-disabled mode. Exact configuration failure mapping follows its API.

For each nested call, count total active `notify_datareaders` frames plus
one, and compare against the smallest participant limit represented in the active
callback/delegation chain, including the destination participant. Include the root
callback's participant even if it has no active `notify_datareaders` frame yet.
Ordinary external entry has no root callback and initially uses the destination's
limit. On unwind, remove the departing frames' restrictions. Sibling child callbacks
within one traversal do not consume additional delegation depth.

Examples: A with limit two may delegate into B with limit eight at depth two, but
cannot proceed to depth three while A remains active. Entering B with limit one at
depth two fails immediately. Returning from B restores the enclosing participants'
limits. A root callback with limit one can make the ordinary first delegation call,
but its child cannot start another. Cross-runtime calls do not reset the count.

This is a resource contract for library-tracked nesting; it does not bound arbitrary
application recursion, callback stack frames or the total dependency graph. Fixing
configuration at creation avoids retroactively invalidating active calls and gives
storage sizing a stable bound. Live mutation can be a later extension if justified.

<a id="binding-identity-and-ownership"></a>
### Binding identity and ownership

Dispatch context, canonical identity and application ownership are separate. The
identity and nesting rules above are required. Descriptor layout/version negotiation
is an [open ABI item](../concurrency-broker-status.md#open-design-items).

Preserve the current dispatch context exactly as required by each generated trampoline.
Supply canonical identity independently at registration, retain the resolved exclusion
record for callbacks, and track binding-resource ownership separately. An identity
record is not ownership of a borrowed application object.

**Conforming approach — C++ identity.** Registration-time `dynamic_cast<void*>(this)` is a candidate
for obtaining complete-object identity while retaining the adjusted ListenerBase
pointer for dispatch. It needs no new application override or common virtual base.
Constructor/destructor registration and multiple-inheritance/interface-view tests
must be addressed before selecting the implementation. Separate forwarding objects
remain distinct unless an adapter explicitly supplies common identity or the
application groups them. This is not an entity-wrapper identity mechanism.

**Conforming approach — Java identity.** Prefer binding-owned canonicalization of actual object identity over a
mandatory application superclass containing a native handle. Registration-time lookup
and reference bookkeeping keep this work off the callback path. Raw C/Zig retain
application-context identity defaults. Canonical tokens must have an explicit namespace
and lifetime; they cannot alias unrelated native or VM objects accidentally.

A separate identity field, versioned registration descriptor or identity-query hook
remain ABI alternatives. Appending a field to existing generated callback structs
is not automatically binary-compatible. Resolve layout/version negotiation and
failure ownership in an implementation plan rather than changing OMG interfaces.
New application controls remain in `zzdds.idl`; generated internal metadata does not
require an application identity accessor.

Entity identity continues to derive from the native entity lifetime, including its
existing shared C-ABI box/interface-view machinery. Listener identity derives from
the application object through the binding. Unifying their dispatch representations
is not a prerequisite for implementing either identity contract.

<a id="callback-failure-and-binding-unwind-policy"></a>
## Callback failure and binding unwind policy

<a id="failure-after-dispatch-commit"></a>
### Failure after dispatch commit

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
on dcps.idl. No new mandatory application listener methods are required.

An inner notify_datareaders returning ERROR is still different from its caller
throwing. If the caller handles that ERROR and returns normally, the outer operation
may succeed, as already accepted. If the caller itself throws, its own invocation
fails and the immediate containing delegation observes that failure.

<a id="binding-boundary-and-ownership"></a>
### Binding boundary and ownership

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

A void-return callback ABI requires an internal
invocation-outcome mechanism: for example, a scoped per-invocation record accessible
to generated bridges, or a versioned descriptor outcome hook. It must distinguish
nested invocations, restore the outer frame on return, and carry the same explicit
chain across supported binding/runtime transitions. One sticky thread-wide error
flag is insufficient. Exact ABI shape is tracked with identity metadata in the index; no raw
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

<a id="preparation-before-dispatch"></a>
### Preparation before dispatch

Prepare/validate/commit with bounded retries is required. Preparation retains chain
identity and application-access obligations, but not callback execution rights.
The final-entry and retry rules below apply to every binding.

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

Preparation may run foreign adaptation code, but must not access mutable application
listener state without independent protection. It has not acquired listener execution
rights merely by retaining identity or application lifetime.

The version must distinguish updates and consumption, including zero-net changes.
A status getter or another dispatch invalidates a prepared aggregate. Comparison of
counter values alone is insufficient. Replacement/deletion invalidates unclaimed
preparation; any remaining cleanup retains its application-access obligation through
its last relevant access. A prepared argument is not a callback claim and does not
permit invocation on a retired registration.

<a id="retry-and-placement-rules"></a>
#### Retry and placement rules

Limit preparation/revalidation attempts per service turn. Automatic work retains
pending status and yields for a later scheduling opportunity; resource-failure retries
must use bounded backoff or an explicit resource wake, not immediate busy spinning.
Do not silently disable the listener or erase the notification. Explicit delegation
also has a finite total preparation-retry budget for each candidate; exhaustion stops
the batch with ERROR, preserving unconsumed status and earlier child effects.

Ordinary waiting for busy callback rights is not itself a failed preparation attempt.
A wake may require revalidation and another preparation if state changed, but must not
turn mere contention into a busy error. Release scarce prepared resources while waiting
where necessary, without falsely marking the candidate handled. The extension API defines the finite retry defaults and configuration. Any finite retry rule means that
continuous state interference can cause explicit ERROR rather than guaranteeing
progress at the cost of an unbounded preparation loop.

JNI local references and other thread-affine preparation cannot migrate to a different
worker unchecked. Prepare and commit on the appropriate thread, discard/reprepare on
migration, or explicitly use transferable retained representations. Executor placement
is a constraint on the prepared invocation, not permission to reuse a foreign JNIEnv.

<a id="preparation-recursion-and-final-entry"></a>
### Preparation recursion and final entry

<a id="extend-the-recursion-guard-across-preparation"></a>
#### Extend the recursion guard across preparation

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

<a id="final-entry-cannot-provide-a-universal-body-start-proof"></a>
#### Final entry cannot provide a universal body-start proof

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

No-consumption on failure applies before dispatch commit. It cannot be promised for
every language-runtime failure at final entry. Do not describe uncertain entry as a proven application exception.
Diagnostics should distinguish preparation failure, known application failure where
available, and committed invocation failure with unknown entry.

A callback's committed status observation is not sample consumption. A failed entry
can leave samples available through normal access, but must not manufacture a new
status notification solely to replay the failed invocation. New independent status
changes remain pending normally. This makes failure semantics consistent across
thread placement without guessing whether application side effects occurred.

<a id="retry-scheduling"></a>
### Retry scheduling

Retry limits are finite configuration bounds, not measured latency or memory guarantees.

Numeric defaults and construction-time validation belong in
[ParticipantConcurrencyConfig](extension-api.md#runtime-ownership-and-selection).
Manual drivers expose retry deadlines through the normal timer/progress interface;
retry timers do not create a helper thread.

The per-turn count applies to actual preparation work. The explicit cumulative budget
counts stale validation, not waiting for execution rights or releasing thread-affine
prepared objects solely because a worker changes. Check deletion/ineligibility before
charging a stale retry: an ineligible target is skipped, not converted into an error.
A still-eligible candidate that reaches its configured stale-validation limit returns ERROR without
another attempt. Replacement does not reset that candidate's cumulative budget.
Each new explicit call starts a new budget; application retry loops remain application
behavior. Count work across all turns/binding transitions of the same candidate.

<a id="distinguish-the-causes"></a>
#### Distinguish the causes

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

<a id="ordering-and-coalescing-of-listener-statuses"></a>
## Ordering and coalescing of listener statuses

<a id="status-ordering-requirements"></a>
### Status ordering requirements

* Maintain accumulated status independently of automatic callback eligibility.
  Each source entity/status kind has at most one unclaimed notification opportunity,
  plus any invocation already claimed. An update to an existing pending opportunity
  changes its eventual aggregate without moving its queue position.
* Assign a local order when a kind first becomes pending and eligible for automatic
  delivery. For continuously eligible opportunities from the same source entity,
  admit older ones first. Simultaneous multi-status publication uses a deterministic
  internal tie order; do not turn that tie into a public fixed status priority.
* A status with no selected automatic callback retains its DDS state but has no
  automatic admission reservation blocking other kinds. If later made deliverable,
  publish a fresh opportunity without backdating it ahead of existing eligible work.
  Catch-up on registration follows the same routing and nil-listener rules.
* Snapshot arguments and reset the selected kind's deltas/changed flag at actual
  claim, under its status-consumption synchronization. A specific getter can win
  first and invalidate the pending opportunity. A subsequent change gets a fresh
  opportunity. Callback return releases execution rights, not status state.
* A new change after claim can create another pending opportunity behind work already
  waiting. Repeated traffic in one kind cannot keep an old queue position across
  successive invocations. Actual scheduler service and callback return are still
  required for progress; no bounded latency follows from this policy alone.
* Replacing the selected registration withdraws its admission as already required.
  If still deliverable, readmission gets a fresh position. Status counters survive
  that change. Mask changes, parent routing changes and status consumption must all
  invalidate obsolete admission without losing the accumulated state.

Status aggregation follows each DDS status's fields, not a generic sum. Zero net count
change does not erase unobserved transitions, and last-handle fields are not event lists.
Updates during a callback create new pending work that callback return cannot clear.
Unchanged unread cache contents alone must not produce a self-sustaining DATA_AVAILABLE
callback loop. Commit required association/history changes before dependent notification
eligibility; this does not promise one match callback before every data callback.

Local order is attached to the source entity, even when a parent listener handles
its plain status. Sharing a listener across different entities supplies exclusion
and callback-admission FIFO, not a global ordering of those entities' state changes.
No extra Subscriber-wide serialization of sibling reader listeners is introduced.

Explicit `notify_datareaders` remains application-directed with its accepted admission
and inheritance rules. It does not acquire a new requirement to dispatch older plain
status callbacks first. Existing conflicting admission obligations still apply.
Subscriber DATA_ON_READERS routing also remains distinct from a reader's local plain
status ordering. Consequently no universal match-before-data callback guarantee is
made, even though association/history state required for processing must already be
committed before dependent notification eligibility is published.

<a id="delegation-membership-and-notification-boundary"></a>
## Delegation membership and notification boundary

<a id="traversal-contract"></a>
### Traversal contract

1. After entry recursion/depth checks, capture the Subscriber's contained reader
   entity lifetimes at one membership boundary. Retain safe internal handles for
   traversal, not borrowed application listener pointers. Readers created afterwards
   belong to a later call; deletion/recreation cannot substitute a new entity with a
   reused handle. Reserve traversal capacity before invoking any child. If that
   fails, return the accepted capacity ERROR without invoking children.
2. Visit each captured reader once. No application-visible cross-reader traversal
   order is promised. This does not relax FIFO callback admission or presentation
   data-access requirements; callback order is not the ordered GROUP sample list.
3. Skip a reader if it is no longer live, has no applicable attached callback, or
   its DATA_AVAILABLE status is no longer changed. Do not use the Subscriber's
   DATA_ON_READERS flag as a gate for this explicit operation. Explicit delegation
   selects reader callbacks, with no fallback into another Subscriber callback.
   The accepted [selection policy](listeners.md#explicit-delegation-listener-selection-audit) ignores the reader
   listener mask for explicit delegation. An absent/null callback is skipped without
   consuming reader or Subscriber status; there is no parent fallback.
4. If waiting for rights, consume no status. Replacement withdraws old admission
   and rechecks the same candidate as already agreed. A status reset while waiting
   must also cause eligibility recheck and withdrawal if the candidate is now
   ineligible; it must not leave the caller blocked solely on an obsolete notification.
   Such withdrawal needs a published wake/recheck obligation in the implementation.
5. At final claim, coordinate current eligibility, registration retention, callback
   rights and the required status reset as one ordered dispatch boundary. A failed
   claim consumes nothing. Successful claim commits one invocation; application entry
   follows outside internal locks. Replacement after claim obeys accepted retirement
   rules. Another application thread may read between claim and actual entry, so a
   claimed callback is not a promise that a later read will return data.
6. Advance after invocation or skip; never revisit that reader in this call. A new
   change before claim may coalesce into this invocation, even if it occurred after
   membership capture or after an intervening read reset. A change after claim is
   newer notification state. Callback return must not clear it. Subsequent legitimate
   read/take or callback activity can still reset it according to DDS rules.
7. OK means the finite membership traversal completed under these rechecks. It does
   not mean all reader flags are now clear, all samples consumed, or all notifications
   arriving before return were handled. Admission errors retain accepted partial
   completion semantics. There is no hidden delegated remainder after return.

An already skipped reader that becomes eligible later is not revisited. New changes
continue through ordinary notification/status handling, subject to Subscriber routing
and independent consumption. Do not guarantee another automatic callback for every
unprocessed change. Applications needing to drain samples should use their data-access
loop, not infer draining from a successful notification traversal.

<a id="reader-and-subscriber-status-coordination"></a>
### Reader and Subscriber status coordination

DATA_AVAILABLE and DATA_ON_READERS have distinct reset rules. A reader callback
or read/take resets the Subscriber flag as well as the applicable reader flag;
entering a Subscriber callback resets its own flag without clearing all reader flags.
Therefore DATA_ON_READERS must not be reconstructed as the OR of pending reader flags.
[OMG DDS 1.4, section 2.2.4.2.2](https://www.omg.org/spec/DDS/1.4/PDF).

Reader-local notification state and the narrow Subscriber status coordinator need
an ordered publication/reset protocol. This does not require moving reader history
or all sibling callback execution into a Subscriber context. Generation counters or
another equivalent scheme must distinguish a change before a reset from one after
it; unconditional cleanup on callback return is insufficient. Concrete synchronization
is an implementation decision requiring traces across two readers.

For example: B changes, then A's callback is claimed. The Subscriber flag can reset
at A's claim while B's reader flag remains changed. If B changes again after that
claim, the Subscriber flag becomes changed again; A's later return must not erase
that change. A later legitimate reset by another reader remains allowed. This is a
status-observation boundary, not an obligation to deliver every arrival as a callback.

Polling get_status_changes is not the same operation as consuming a plain status via
its specific getter. Do not generalize the existing plain-status getter discussion
into a rule that every inspection clears DATA_AVAILABLE. The reader read/take and
callback paths need their own exact reset audit, including unsuccessful access cases.

<a id="explicit-delegation-listener-selection-audit"></a>
## Explicit delegation callback selection

<a id="selection-table-for-zzdds"></a>
### Selection table for zzdds

Assume a live retained reader, current changed DATA_AVAILABLE, and successful admission.

| Attached reader callback | DATA_AVAILABLE mask | Explicit action |
| --- | --- | --- |
| Present | Enabled | Invoke attached callback |
| Present | Disabled | Invoke attached callback |
| Absent/null | Either | Skip without consuming status; no parent fallback |

If status is no longer changed, skip regardless of mask. StatusCondition enabled
statuses are a separate setting and do not select listener callbacks. A non-null
application listener whose method intentionally does nothing is still an invocation
and consumes status at the normal claim boundary.

A mask-only replacement still creates a new registration under the accepted
replacement contract. Pending admission withdraws and retries against that generation;
being masked out no longer makes the explicit callback ineligible. This does not
relax recursion, rights, depth or quiescence rules.

<a id="absent-callbacks"></a>
### Absent callbacks

Skip an absent/null callback without consuming its pending status. The skip itself
resets neither reader DATA_AVAILABLE nor Subscriber DATA_ON_READERS; another real
callback or read/take can still legitimately reset status. A real attached callback
that intentionally does nothing is invoked and consumes status at the normal claim
boundary. Generated bindings must preserve this distinction between absence and an
application no-op method.

A Subscriber can combine
listener-driven readers with readers handled through polling or WaitSets. Explicit
notification traversal should not consume status merely because no callback is
attached to one of those readers. Missing callbacks therefore produce no warning by
default. This preserves notification state, not a private sample or history snapshot.

<a id="explicit-reader-listener-delegation"></a>
## Explicit reader-listener delegation

<a id="delegation-requirements"></a>
### Delegation requirements

1. Capture a bounded retained set of candidates. The accepted
   [notification boundary](listeners.md#delegation-membership-and-notification-boundary) fixes reader membership
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

Dependency checking must include earlier FIFO admission reservations as well as active
owners. A queued chain may hold no new rights yet still block a later claimant. If a
registration or required-rights set changes while waiting, withdraw the old admission and
recheck dependency/cycle rules before publishing a replacement; do not mutate a queued
claim into an unchecked dependency. Bound graph storage and wake obligations, and report
capacity exhaustion through the delegation ERROR mapping.

The partial-progress rule is a real API tradeoff. Acquiring the whole batch first
could reduce pre-dispatch failures but broadens callback exclusion and still cannot
make arbitrary application callbacks transactional. Ordinary automatic notification does not acquire every listener in a Subscriber.

<a id="recursion-and-failure"></a>
### Recursion and failure

<a id="supported-explicit-nesting"></a>
#### Supported explicit nesting

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

<a id="bounded-nesting"></a>
#### Bounded nesting

Apply the [participant nesting rule](#participant-nesting-limits):
count the whole chain against its smallest active participant limit, including the root
callback and destination. Reject before capture or status consumption if the next frame
would exceed the limit. Standard and explicitly configured calls have identical rules;
crossing a runtime does not create another allowance. This bounds delegation frames,
not batch size, wait duration, arbitrary stack use or dependency-graph size.

<a id="return-and-partial-completion-rules"></a>
#### Return and partial-completion rules

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

<a id="listener-replacement-and-quiescence"></a>
## Listener replacement and quiescence

<a id="replacement-completion"></a>
### Replacement completion

From ordinary application code outside a zzdds callback chain, successful
`set_listener` publishes the replacement and waits for all relevant uses through
a captured registration-generation frontier to retire. It returns with no remaining
application listener/context access through those retired registrations on that
entity. The newly installed registration can remain active. This is an application
lifetime boundary, not a claim that every stale scheduler record has been freed.
Stale records left behind must no longer dereference the retired listener/context.
Any release hooks that can access it must also have completed or transferred valid
independent ownership before quiescence is reported.

From **any** zzdds callback chain, including callbacks on another entity or runtime
in the same identity domain, replacement publishes without waiting for callback
retirement. Already claimed invocations may finish. Unclaimed pending notifications
must reevaluate against the current listener/mask. A claim immediately preceding
replacement can enter application code afterwards: asynchronous replacement is not
a promise about the wall-clock time of the last callback entry.

The old application-owned listener must survive that deferred retirement. In
particular, successful self-replacement does not authorize destroying the object
whose method is still executing. Shared identity exclusion persists while old
invocations/registrations retain it. New pending work does not bypass that exclusion.

The operation does not wait while holding entity, protocol, listener-identity or
registry locks. Any helping/wakeup logic follows the runtime progress contract.
A single-thread manual driver incurs no callback-drain wait outside a callback
when no previous callback is in flight. This is not an OS-thread-per-listener design.

The callback-context distinction is an execution-chain property, not a comparison
of the target entity with the current callback's entity. Restricting the exception
to self-replacement still allows A's callback to wait for B while B waits for A.
Implementation needs a common scope across bindings/runtimes; foreign application
threads causally spawned by a callback are not automatically detectable as that
callback chain.

<a id="why-the-frontier-includes-previously-retired-registrations"></a>
### Why the frontier includes previously retired registrations

Consider A replacing itself with B from a callback. A is retired but still running.
Another thread then clears B. Waiting only for B would allow the clear to return
while A still accesses old application state. Instead, the external clear captures
all registration generations through B and waits for their applicable uses,
including A. Registrations installed concurrently after the captured frontier do
not extend that wait. Return is a lifetime statement about that frontier; it does
not assert that the entity's current listener still equals the caller's argument
if another setter subsequently changed it.

Retirement bookkeeping must be bounded. Prepare all needed storage before committing
a registration change; failure must leave the previous registration intact. The
[open API items](../concurrency-broker-status.md#open-design-items) track the permitted
resource-failure return mapping. No TIMEOUT is added to standard `set_listener`;
this operation has no finite return-time guarantee if a callback never returns.

<a id="standard-only-ownership-pattern"></a>
### Standard-only ownership pattern

A management thread can clear or replace every registration that uses an old
application-owned listener, wait for those setter calls to return, and then destroy
that listener, provided the application prevents concurrent reinstallation and has
no other users of the object. Parent listener registrations count too: descendant
fallback dispatch retains the actual selected parent registration.

A callback may request replacement immediately and hand final reclamation to such
a management path. The management path can perform a subsequent setter operation
on the affected entity to drain the earlier frontier. On a single-thread application,
perform this management step after the callback returns. No zzdds extension is
required for this pattern. An extension would make nonblocking retirement tracking
more convenient, especially when callers do not wish to issue another setter.

This does not mean clearing one reader makes a listener shared with another reader
safe to destroy. Identity-wide object lifetime and per-entity registration retirement
are different. Concurrent shared-object registration/destruction remains an
application ownership responsibility.

External quiescence remains a blocking operation: callers must not retain an
application lock or wait dependency that the retiring callback needs. The library
can prevent its own self/cross-callback drain waits, not arbitrary application
cycles such as a callback joining a management thread that is draining that callback.

<a id="datareader-deletion-callback-and-return-boundary"></a>
## DataReader deletion: callback and return boundary

<a id="initial-behavior"></a>
### Initial behavior

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

<a id="admission-preconditions-and-operation-races"></a>
### Admission, preconditions and operation races

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
return ALREADY_DELETED for a recognized already-closed target, retaining
PRECONDITION_NOT_MET for a live target owned elsewhere. Arbitrary stale raw pointers
cannot be made safe merely by reading a generation field in freed memory. Binding
handles need safe lookup/retention or the documented application synchronization rule.

A retained delegation candidate does not itself block external deletion. Pending
candidate records must detach from application state and permit skipping the reader;
only an actual claimed invocation/application use contributes to the drain boundary.
Otherwise a suspended parent traversal could prevent deletion even after its pending
child was invalidated.

<a id="lifetime-consequence-of-callback-context-deletion"></a>
### Lifetime consequence of callback-context deletion

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

<a id="parent-and-bulk-deletion-contract"></a>
## Parent and bulk deletion contract

<a id="logical-deletion-requirements"></a>
### Logical deletion requirements

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
   those calls. Do not rescan indefinitely to capture newly created children.
6. Extend the accepted context distinction to the deleted set: external calls drain
   applicable application access through the deleted entities; any callback-chain
   call returns after logical commit without callback-drain waiting. A surviving
   root's unrelated listener activity is outside that drain. Claimed callbacks in
   the deleted set retain their resources and may enter/finish after asynchronous
   return. No later use of logically deleted public handles is authorized.

This policy favors predictable failure over the simpler delete-until-one-fails loop.
Its preparation cost grows with the target subtree and requires explicit bounded
storage. It does not require transaction support for ordinary sample processing.

<a id="concurrency-requirements-for-preparation"></a>
### Concurrency requirements for preparation

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
publishers in the operation matrix. The [subtree reservation protocol](#subtree-admission-protocol)
below defines admission and retry behavior; operation-specific result mapping is
owned by [operations](operations.md). Avoid rejecting ordinary reads/writes merely because an unrelated subtree
is preparing deletion.

On preflight failure release all reservations and wake affected work. On commit,
lookups and public admission must observe each target as deleted through a shared
commit decision or an equivalent audited protocol, even if physical list removal is
incremental. Pending callbacks and delegated candidates detach without keeping an
external drain dependent on an unrelated parent traversal. Drain includes applicable
older retired registration uses, not just the current listeners of the children.

An empty parent can still retain internal references to previously logically deleted
children. Its physical retirement must respect those references. External
parent deletion also drains previously detached descendant application uses under
the frontier rule below; emptiness does not prove descendant quiescence.
This is especially important after callback-context child/bulk deletion.

<a id="descendant-retirement-frontiers"></a>
### Descendant retirement frontiers

<a id="what-an-external-parent-deletion-waits-for"></a>
#### What an external parent deletion waits for

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

<a id="keep-application-quiescence-separate-from-storage-reclamation"></a>
#### Keep application quiescence separate from storage reclamation

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

<a id="bulk-calls-on-a-surviving-root"></a>
#### Bulk calls on a surviving root

An external delete_contained_entities call must drain both its newly
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

<a id="required-bookkeeping-properties"></a>
#### Required bookkeeping properties

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

<a id="subtree-admission-protocol"></a>
### Subtree admission protocol

<a id="one-reservation-before-descendant-inspection"></a>
#### One reservation before descendant inspection

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

<a id="phases"></a>
#### Phases

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

<a id="which-operations-pause-and-which-keep-running"></a>
#### Which operations pause and which keep running

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
operation-specific mapping. The [operations contract](operations.md) owns closure/error results; no universal new
DDS error is introduced by this protocol.

<a id="why-a-callback-can-wait-without-creating-a-drain-cycle"></a>
#### Why a callback can wait without creating a drain cycle

If callback A encounters a reserved subtree while trying to publish a loan, A releases
its endpoint turn/publication rights and waits. The deleting transaction inspects
metadata and reaches commit or abort without waiting for A to return. Only after
releasing the reservation may an external deleter wait for A's retirement. Thus A can
resume, observe the decision, and return. The deleting transaction must not use the
external drain as the condition for releasing the reservation.

For a manual driver, synchronous waiting may help bounded lifecycle-coordinator work
as internal progress, without invoking automatic callbacks. Another worker is not
required. Callback self-bulk-deletion follows the same internal path. If an
implementation needs application execution to complete the reserved phase, it violates
this mechanism and must release/retry rather than waiting with the reservation held.
The ordinary no-protocol-lock-across-application-code requirement remains essential.
