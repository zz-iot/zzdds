# Concurrency: operations

This is a current contract. Scope, decisions and implementation gates are in
[the single status index](../concurrency-broker-status.md). Validation results are maintained
only in [the evidence inventory](../../../test/design-models/README.md).
<a id="operation-result-mapping"></a>
## Remaining L5 operation results

<a id="operation-result-mapping--shared-effect-boundary"></a>
### Shared effect boundary

Keep effect commitment, result delivery and storage reclamation distinct. Before an
operation commits, a safely recognized logical close can resolve ALREADY_DELETED.
After commitment, later close does not undo the effect or replace success with a
false failure suggesting that the effect never occurred. Output-conversion failure
is separate and must preserve the operation's documented effects and release retained
resources. Never dereference a stale raw pointer to manufacture a deletion result.

Ordinary contention on context admission or a temporary subtree reservation is not
BAD_PARAMETER, PRECONDITION_NOT_MET, NO_DATA or resource exhaustion. Release execution
rights while waiting under the accepted progress contract. API preconditions are
checked again at the relevant effect boundary. A proven retained-rights dependency
can return ERROR under the existing dependency policy; do not reject merely because
an operation was invoked from a callback.

<a id="operation-result-mapping--mapping-table"></a>
### Mapping table

| Operation | Effect/result boundary | Required mapping |
| --- | --- | --- |
| write and timestamped write | Accepted history/instance installation and sequence commitment | Recoverable history-capacity blocking uses the operation's applicable QoS deadline; exhausted blocking budget is TIMEOUT. Failure to allocate required resources can be OUT_OF_RESOURCES. No ACK wait is added after local commit. |
| dispose/unregister and timestamped variants | Instance transition and required protocol-change publication commit together | Use the individual operation's DDS blocking/error rules; retain lifecycle metadata and preparation through admission. Do not mutate instance state then return a precommit failure because control-change storage was unavailable. |
| register_instance variants | Instance registration publication | Preserve handle-returning API shape: failure is HANDLE_NIL, not a ReturnCode_t disguised as a handle. Do not assign a remote-delivery meaning to successful registration. |
| read/take variants | Selection and sample-state/removal effects, together with safe output/loan ownership | With no eligible samples, NO_DATA; never wait for future samples. Internal ownership/presentation admission may wait without inventing a wait-for-data timeout. Invalid arguments and access-period violations retain their operation-specific errors. |
| loan publication | Loan ownership becomes visible atomically with lifecycle preconditions | A close/preflight race cannot publish an untracked loan. Reserve required result/loan storage before irreversible publication; ordinary reservation contention is not a failed loan precondition. |
| return_loan | Validate loan ownership and retire exactly that loan | Remains serviceable during subtree preflight. Follow DDS's no-loan behavior; do not blanket-reject valid non-loaned sequences or make every repeated call an error. Forged/mismatched outstanding loans follow defined validation rules. |
| set_listener | Publish replacement, then external retirement frontier if required | Preparation/capacity failure before publication leaves registration unchanged and returns the applicable error. After publication, retain required drain/cleanup capacity; do not time out an API without a timeout or roll back because a later close occurred. Callback/preparation-chain calls retain the accepted non-draining behavior. |
| single/parent/bulk delete | Validated logical close, followed by context-dependent drain | Real loan/condition/containment preconditions return PRECONDITION_NOT_MET. Ordinary preflight failure leaves the selected subtree unchanged. Reserve cleanup before commit. Never wait for a loan to be returned merely to make deletion preflight pass. |
| begin/end access and coherent publication controls | Accepted access ownership or coherent generation boundary | Preserve paired/nested-operation preconditions. No new arbitrary timeout for methods without one. End-coherent drains admitted local commit bookkeeping, not remote acknowledgments; it must not hold the coordinator through progress waits. |
| notify_datareaders | Accepted bounded traversal with child invocation commits | Existing ERROR/partial-progress rules apply. No rollback of completed child callbacks and no new timeout for ordinary contention. |

DDS 1.4 sections 2.2.2.4.2 and 2.2.2.5.3 define these per-operation results and
blocking behavior. In particular, write history-capacity blocking uses reliability's
max_blocking_time, while return_loan on valid collections that were not loaned is
permitted. These facts do not grant every operation an identical timeout/error set.
[OMG DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

<a id="operation-result-mapping--deadline-and-failure-classification"></a>
### Deadline and failure classification

Use one deadline for operations that actually have a specified blocking budget;
preparation/admission retries do not renew it. A timeout commits before an unresolved
mutation effect, not after installation. No deadline is introduced into read/take,
listener replacement, deletion or paired presentation controls by the concurrency
framework. Language conversion and cleanup can extend observed return latency;
max_wait/max_blocking_time must not be advertised as a hard real-time bound on all
foreign code and scheduling.

Distinguish a temporary shortage covered by a specified capacity wait from immediate
allocation failure. Do not flatten every resource failure into TIMEOUT, or return
OUT_OF_RESOURCES solely because an ordinary context turn is occupied. Exact writer
lifecycle-variant timeout coverage must be checked against its DDS operation text
when integrating generated/raw APIs; reusing write's implementation is not evidence
that its error contract applies unchanged.

An irrecoverably stopped runtime can fail an uncommitted operation with ERROR when
it removes indispensable progress. It does not invalidate a live object's purely
local operations or release-only cleanup. WaitSet's independent wake/guard behavior
remains its explicit exception. Already committed mutations still need retained
cleanup and result delivery; runtime shutdown cannot abandon them.

<a id="prepared-read-conflicts"></a>
## Prepared read/take: selection, claims and failure

<a id="prepared-read-conflicts--admission-and-conversion-capability"></a>
### Admission and conversion capability

Validate arguments, enablement, reader lifetime, masks, condition and presentation access
before effects. Bound candidate pins, output and restoration bookkeeping per reader and
runtime. Exhaustion before selection has no access effect. Select the entire collection
under the relevant reader/presentation ownership and capture its SampleInfo at that point.
Ranks and view state use that observation, not a later decode completion time.

Two paths share those semantics:

* Certified native: conversion and output transfer are non-reentrant and bounded. Validate
  representation, reserve all nested output/loan storage and ensure final transfer cannot
  fail before irreversible selection effects. Native language or library allocator alone
  is not certification. Conversion may then execute under reader rights without claims or
  retry. If these properties cannot be established, use the foreign path.
* Foreign: capture immutable payloads and commit READ/NOT_NEW state at selection. For take,
  install claims atomically with selection; for read, retain payload pins without hiding
  samples. Release protocol rights before conversion, cleanup or application code.

No stale-validation retry or conflict-exhaustion ERROR applies. Same-reader recursive
foreign preparation retains the explicit recursion guard; removing optimistic retries
alone does not authorize unbounded recursive conversion.

<a id="prepared-read-conflicts--claims-and-restoration"></a>
### Claims and restoration

A take claim hides its samples from other reads/takes and from condition evaluation; it
counts as consumption for the applicable shared GROUP access view. Payloads remain pinned
and logical history depth includes claims until normal eviction or expiry removes them.
A claim is not a new public loan and does not prevent lifecycle processing.

Successful conversion completes removal without a second eligibility selection. On failed
conversion, restore only samples still logically retained and eligible for restoration,
in their original ordering positions. Never resurrect an evicted/expired sample or deleted reader. A closed/replaced
presentation-access generation cannot be reopened. Retire claims and pins exactly
once. For a still-open captured GROUP bracket, release that claim's consumption reservation.
If the bracket closed, retire its consumption reservation without modifying a successor
view. Restore an otherwise retained sample to the reader cache; subsequent access periods
may admit it under their ordinary boundary/eligibility rules. Closing a bracket alone
must not turn failed conversion into permanent cache removal. Restoration is not a new
arrival that automatically bypasses a successor bracket's fixed admission boundary.

Restoration reevaluates conditions and signals waiters when predicates become true. It does
not create a new source sample or timestamp. Reevaluate normal data-availability notification
eligibility without inventing a new wire arrival. Instance lifecycle continues normally;
restoration never overwrites current instance state or generation counts.

READ and NOT_NEW changes committed at selection are never rolled back. A later lifecycle
rebirth can legitimately make an instance NEW again; delayed failure cleanup must not
reapply NOT_NEW to that new generation. Read failures have no claims to restore but keep
their selection-time state effects. Decode output from a failed conversion is discarded.

<a id="prepared-read-conflicts--observable-failure-contract"></a>
### Observable failure contract

Foreign-path failed takes may temporarily hide samples: a concurrent call may return
NO_DATA, followed by a later call obtaining restored samples without another arrival.
This failed-call isolation weakening is explicitly accepted. Normal history eviction,
expiry, close or another consumer can still prevent later recovery.

Known limitation for binding users: a foreign-conversion read/take that fails after
selection (including OOM or a conversion exception) leaves selected samples READ and
instances NOT_NEW. A later operation using NOT_READ or NEW masks, including equivalent
ReadCondition/QueryCondition masks, may skip data never delivered to the application.
Retry with ANY sample and view state masks when recovery is needed; this does not promise
that samples remain retained. Applications unable to tolerate this should avoid those
filters on such bindings. The certified native path is unaffected only when its complete
infallibility/non-reentrancy preconditions hold, not merely because it is C/C++/Zig.

Use existing ERROR/OUT_OF_RESOURCES and language exception mappings. Track effect phase
internally: no selection effects; selection state committed with claims restored or retired;
or successful consumption followed by output-publication failure. No new standard DDS
ReturnCode is introduced. A failure after successful final output transfer must not unclaim
or automatically repeat an already-completed take.

<a id="binding-access-failures"></a>
## Binding-visible prepared access failures

<a id="binding-access-failures--common-mapping"></a>
### Common mapping

| Condition | DDS ReturnCode result | Access effect |
| --- | --- | --- |
| Successful whole-batch commit and output transfer | OK | Committed |
| Valid fresh selection is empty | NO_DATA | None by this call |
| Proven allocation failure, or configured preparation storage limit exhausted | OUT_OF_RESOURCES | None |
| Truncated/invalid received representation or unsupported decoding of that representation | ERROR, decode diagnostic | None |
| Foreign conversion failure after selection | ERROR or OUT_OF_RESOURCES by cause; preserve language exceptions | READ/NOT_NEW retained; take claims restored only if still eligible |
| Same-reader recursive preparation in one synchronous chain | ERROR, recursion diagnostic | None |
| Recognized logical close before commit | ALREADY_DELETED | None |
| Existing argument, condition, access-period or enablement precondition fails | Existing operation-specific result | None |
| Unavoidable publication failure after commit | ERROR, or OUT_OF_RESOURCES for proven allocation failure; language exception rules below | Committed; output may be partial |

There is no stale-validation retry budget in the revised claim contract. The allocation/
decode no-effect rows apply before selection; after selection use the foreign-failure row.
Ordinary context contention is not storage exhaustion. No wait-for-data timeout is
introduced. An unsupported optional operation/profile keeps its applicable UNSUPPORTED
result; malformed incoming bytes do not make the caller's API arguments BAD_PARAMETER.
An inconsistent successful raw result (mismatched lengths, absent required storage)
is an internal ERROR, not NO_DATA. Normalize legitimate empty selections at the core
boundary; adapters must not infer arbitrary failures from empty output.

Map CDR TRUNCATED/INVALID to ERROR. For OVERFLOW, use retained failure provenance:
allocator failure or a legitimate bounded preparation resource refusal maps to
OUT_OF_RESOURCES; invalid wire lengths/arithmetic and internal sizing mistakes map
to ERROR. Until provenance exists, ambiguous OVERFLOW maps to ERROR, never a guessed
allocation diagnosis. Migration must supply explicit categories through a private
adapter result or an additive codec facility without renumbering existing CDR codes.

<a id="binding-access-failures--language-contracts"></a>
### Language contracts

<a id="binding-access-failures--zig-and-raw-c"></a>
#### Zig and raw C

Generated DDS ReturnCode operations return the table's codes. Internal Zig errors
are translated explicitly; no panic for recoverable preparation failure and no error
enum cast to a DDS integer. Prepare descriptors, SampleInfo and loan registration
before commitment. Publication uses non-failing stores to valid caller storage.
No temporary loan escapes on failure. Invalid/dangling caller pointers remain outside
this recoverable-failure guarantee.

C typed output follows the same temporary-then-transfer rule. Preserve documented
caller initialization and ownership requirements; do not overwrite owned fields and
leak them. Failure before commit leaves caller sample storage unchanged, with result
counts/loan outputs in their documented empty state. No C++ exception or Java pending
exception may unwind through the C ABI. Supported foreign hooks must communicate
failure explicitly through the private preparation protocol.

<a id="binding-access-failures--c"></a>
#### C++

ReturnCode methods map generated preparation std::bad_alloc to OUT_OF_RESOURCES and
recognized decode errors to ERROR. RAII owns all pins, partial typed values and raw
results across every exit. Ordinary generated output types must support a proven
non-throwing final transfer, or the path must document publication failure.

Exceptions from arbitrary application code (including output assignment) propagate
as their original C++ exception after cleanup. Do not silently catch every exception
and call it malformed input. At a C ABI bridge, capture the exception, unwind native
leases safely, then rethrow only after returning to the C++ boundary. No dependency
on allocating a diagnostic is allowed to make cleanup fail. Throwing destructors or
non-returning callbacks are outside the recoverable exception contract.

A failure before selection has no read/take effect. Foreign conversion failure after
selection retains state effects and restores eligible take claims under D7/D8. A publication exception after commit
may leave partial caller output and must never trigger automatic re-execution. A
ReturnCode-only caller must follow this documented distinction; it cannot infer
absence of effects from every non-OK code on arbitrary-output paths.

<a id="binding-access-failures--java"></a>
#### Java

Raw generated ReturnCode methods retain their numeric result for native DDS failures.
Java VM exceptions, including OutOfMemoryError, propagate unchanged; do not clear them
to return a misleading code, or allocate a replacement exception during OOM. JNI
must stop ordinary Java calls when an exception is pending and perform only legal
native/JNI cleanup. Caller List.clear/add failures preserve the original exception
and may leave partial list output after a committed access.

Typed convenience methods check the raw/prepared result explicitly. Genuine NO_DATA
remains null for a single sample or an empty array for a batch. Other DDS failures
throw a proposed unchecked zzdds AccessFailure carrying the DDS return code, a bounded
reason enum and effect phase (no selection effects, selection state committed, or consumption committed). Define shared public error
metadata in zzdds.idl, not dcps.idl; attach a Java cause in the binding when available.
Names/layout are integration work, not a new DDS ReturnCode or a standard DDS exception.

Recognized generated decode failures become AccessFailure(ERROR, decode, not committed).
Unrelated application exceptions and VM errors propagate unchanged. Do not classify
all RuntimeException instances as decoding errors. Fully prepare the normal returned
Sample/array before commit so returning its reference does not require allocation.
Arbitrary caller containers retain the weaker publication guarantee above. The custom
exception improves convenience API observability; standard APIs require no new setup.

<a id="binding-access-failures--batch-helper-compatibility"></a>
### Batch helper compatibility

C/C++ count-returning convenience helpers cannot carry a precise DDS failure without
an additional convention. Recommend additive result-and-count helpers: return a DDS
ReturnCode and write a count only on success (zero on NO_DATA/error). These are typed
binding helpers, not new methods on DCPS entity interfaces. Any shared public types
or entity extensions belong in zzdds.idl.

Retain legacy helpers as compatibility adapters: nonnegative success counts, zero
for genuine empty selection, negative for failure. They remain explicitly lossy and
are deprecated for code requiring a precise reason. Do not reinterpret old negative
CDR values as positive DDS codes or positive counts. Exact negative failure values
are not the new precise API; document changes to the previous empty/error behavior
in migration notes. Avoid a thread-local last-error mechanism: reentrant preparation
and evented execution make per-invocation results more reliable.

<a id="binding-access-failures--variant-coverage-and-migration-gates"></a>
### Variant coverage and migration gates

Apply the preparation boundary to single and batch read/take, instance and next-instance
selection, condition variants, raw copy and raw loan paths. Key-only invalid_data
samples still need correct key decoding. Validate condition ownership/generation,
instance/cursor eligibility, ranks, sample/view state and GROUP access dependencies
at selection; foreign conversion does not reselect after effects are committed. do not copy plain FIFO selection into every variant. A successful read
can change read/view state even though it retains payloads.

get_key_value, entity creation and WaitSet conversion share cleanup/error principles
but do not have read/take effects. They require their own result-publication audit;
this document does not silently change handle-returning APIs or loan-return rules.

Before production migration is accepted, targeted generated-binding tests must inject
allocation/decode failure before commit, invalidate a prepared selection, throw from
output publication, close during preparation, and verify cleanup exactly once. Cover
C/C++ batch counts, Java NO_DATA versus ERROR, valid_data=false, both loan modes and
condition/next-instance variants. Prove the actual generated non-throwing transfer and
preserve allocator/loan lifetime. These are implementation gates, not grounds for a
new scalar prototype.

<a id="binding-access-failures--required-binding-limitation-note"></a>
### Required binding limitation note

Carry the known-limitation paragraph from [prepared access](operations.md#prepared-read-conflicts)
into every binding using foreign conversion: failed access may retain READ/NOT_NEW;
NOT_READ/NEW filters can skip undelivered data; ANY-state retry is the workaround, subject
to normal retention. Certified native eligibility is capability-based, not language-based.

<a id="reader-variant-results"></a>
## Reader variants and preconditions

### Standard API preconditions

Conditions must belong to the reader; an ownership mismatch is PRECONDITION_NOT_MET.
Next-sample operations select unread samples. Invalid explicit instance handles can yield
BAD_PARAMETER; next-instance cursors need not identify currently retained instances.
Data and SampleInfo sequences must have matching input properties. Nonempty-capacity
borrowed input and excessive requested copy counts violate preconditions. GROUP ordered
access returns at most one sample. Access-period preconditions still apply. Loan return
validates the originating reader and matching result pair; valid non-loaned collections
are harmless. Loaned data and metadata remain immutable. Private raw allocation conventions
are an adapter boundary, not a replacement for these typed API rules.

These requirements follow the DDS 1.4 sample-access contracts (§§2.2.2.5.3.8–.20);
the cursor interpretation below explicitly records the textual inconsistency.


<a id="reader-variant-results--prepared-access-composition"></a>
### Prepared-access composition

For each operation, prepare an explicit variant descriptor: state masks or retained
condition, exact-instance restriction or cursor, sample bound, copy/loan ownership,
and presentation/access generation. Resolve instance identity independently of sample
availability. The descriptor determines eligibility and metadata dependencies; do not
reduce every variant to plain FIFO plus a final filter.

Validate preconditions without consuming samples or changing caller-owned collections.
At selection, validate the complete variant and capture SampleInfo under reader/access
ownership. The certified native path preflights all fallible work; the foreign path commits
READ/NOT_NEW and take claims, then decodes outside rights. Follow
[claim completion/restoration](operations.md#prepared-read-conflicts), without optimistic reselection.
Retain immutable returned SampleInfo independently of subsequent internal state changes.
A published loan pins storage, not continued eligibility for another consumer.

The existing GROUP access contract supplies access-period ownership. Do not create a
second epoch mechanism for prepared conversion. GROUP-disabled builds remove those
specific dependencies but retain ordinary sample/view state, condition, identity and
loan validation. No new timeout or listener exclusion policy follows from this audit.

<a id="reader-variant-results--cursor-interpretation-and-finish-line"></a>
### Cursor interpretation

Use strict advancement for both plain and condition next-instance operations.
This is the accepted zzdds interpretation of inconsistent DDS wording: the plain
operation specifies strict ordering while the condition variant explicitly says >=.
It is not an OMG erratum or a claim that the published wording is unambiguous.

Migration tests should cover foreign-reader/deleted conditions, query changes during
preparation, empty versus invalid explicit handles, retired next-instance cursors,
nearer-instance insertion, mismatched loans/copy results, repeated valid no-loan
return, GROUP one-sample ordering, and invalid_data metadata. They should exercise
the actual generated adapters and native core; no additional scalar model is needed.

<a id="reader-variant-results--cursor-follow-up-evidence"></a>
### Cursor follow-up evidence

With an ANY-state read condition, inclusive selection can repeatedly return the
same instance when callers feed back the last returned handle. Strict advancement
preserves iteration; callers wanting more samples of that instance select it explicitly.

<a id="writer-lifecycle-results"></a>
## Writer lifecycle results

### Standard API results

Write, dispose and unregister, including timestamped variants, use the applicable
write-style capacity rules: reliable capacity waits use max_blocking_time and expire
with TIMEOUT. OUT_OF_RESOURCES is permitted when waiting cannot free required capacity.
Registration retains its InstanceHandle_t signature; never encode a DDS error as a handle.
Registration is idempotent; lookup does not register. HANDLE_NIL is not a precise failure
code because the service may choose not to allocate a handle.

For write/dispose/unregister, detectable existing-handle/key mismatch is
PRECONDITION_NOT_MET; a detectable nonexistent handle is BAD_PARAMETER. Nil selects by
key. Unregister retires registration rather than only disposing the value. Timestamped
variants retain these rules. DDS 1.4 §§2.2.2.4.2.5–.14 does not establish a general error
precedence for simultaneous faults; ordinary validation remains operation-specific.


<a id="writer-lifecycle-results--contract-implications"></a>
### Contract implications

Use the existing writer admission ledger for lifecycle operations as well as data.
Reserve necessary instance/key metadata, control changes and output machinery before
commit. Resolve capacity waits with the applicable operation deadline; do not reset
it during retries or wait while retaining an execution turn. A capacity precheck is
insufficient when concurrent preparations can consume the same space.

Registration membership must be authoritative in the core writer lifetime, with
identity/generation validation at commit. Hash equality alone is not proof of a live
registration. Binding caches are derived conveniences. Concurrent registration of
one instance must resolve to one registration; an admitted unregister must not retire
a newer registration accidentally. Exact handle allocation/collision strategy is
implementation work, not fixed by this audit.

For the proposed implementation, failed implicit registration plus write must leave
no newly published registration or history effect. Explicit registration is its own
commit. Successful unregister retires registration atomically with required lifecycle
publication, honoring autodispose; retained key/control storage may outlive logical
retirement for protocol and cleanup obligations. Dispose alone does not retire the
registration. A later close or send failure does not undo a committed operation.

Preserve handle-returning APIs, mapping unsuccessful handle acquisition to HANDLE_NIL.
Keep detailed internal timeout/allocation diagnostics without requiring standard DDS
applications to use extensions. If precise application-facing registration results
are later exposed, place the additional interface in zzdds.idl. No new public API is
needed to adopt the concurrency rule here.

<a id="writer-ack-wait"></a>
## DataWriter acknowledgment wait: frontier and completion contract

<a id="writer-ack-wait--recommended-capture"></a>
### Recommended capture

After argument/lifetime validation, capture a committed writer sequence frontier and
its currently relevant reliable association generations under writer state ownership.
Do this at one logical boundary, not separate atomic loads of a DDS counter and a
later walk of a mutable RTPS proxy list. Include writes committed before the cut,
even if their API callers have not returned; exclude preparation/admission requests
that have not yet committed. Later writes never extend this wait.

Capture association generations with their actual protocol obligations through that
frontier. New matches after capture do not join. A reader's relevant start/range and
normal reliability relevance rules matter: do not demand receipt of every numeric
sequence before it became an applicable destination. Protocol acknowledgment is not
proof of application read/take, successful callback execution or retained sample
availability. GAP/history relevance semantics remain those of the reliability layer,
not special rules invented by this wait.

No relevant reliable associations means immediate OK. An application wanting to
wait for a reader to appear must use discovery/matching separately. Best-effort writers
return OK after normal argument/entity validation; this does not promise queued
best-effort sends have reached the network.

<a id="writer-ack-wait--association-changes-while-waiting"></a>
### Association changes while waiting

Recommend a fixed set whose obligations can be satisfied or retired:

* Valid ACK progress for a captured association satisfies its covered obligations.
* Logical unmatch retires that association's remaining obligations from the wait.
  If that was the last obligation, the wait can return OK. This means no covered
  obligations remain against the selected matches; it does not assert the departed
  reader received the data.
* Reappearance after unmatch creates a new association generation and does not revive
  the old obligation, even with the same GUID. Stale progress records cannot update
  another association lifetime. A transport reconnect or locator refresh alone does
  not retire an otherwise continuing association or reset the wait's target.
* Temporary transport failure does not count as acknowledgment or unmatch. Wait for
  legitimate protocol progress, actual association retirement, timeout or writer close.

Alternative: report ERROR if any selected reader departs before acknowledgment. This
provides a stronger outcome for the originally selected set, but makes routine discovery
churn fail a standard protocol wait. Another alternative retains a departed reader
until timeout, which cannot progress once its association no longer exists. The
recommended removal policy fits current-match reliability operation, with explicit
wording to avoid advertising end-to-end delivery assurance.

<a id="writer-ack-wait--deadline-close-and-completion-proposal"></a>
### Deadline, close and completion proposal

Use one monotonic absolute deadline derived from API entry. Initial capture checks
whether the predicate is already satisfied; a zero-duration call is a nonblocking
predicate check. If not satisfied and the deadline has passed, return TIMEOUT.
For an initially unsatisfied registered wait, each relevant state transition resolves
completion through the same request protocol:

* Before the deadline, the last covered obligation becoming satisfied/retired commits OK.
* At or after the deadline, an unresolved request commits TIMEOUT; a newly arriving
  ACK does not turn delayed timer service into extra waiting time.
* Writer logical close before deadline commits ALREADY_DELETED for a still-unresolved
  wait. Close must resolve that wait before proxy destruction; destroying all proxies
  must not accidentally make the empty-list predicate report success.
* An already committed result survives later ACKs, close and delayed wake delivery.
  Progress is observed at its state-transition boundary, not packet wire arrival time.
  At the exact deadline boundary, timeout wins for an unresolved registered wait.

The initial predicate check is an explicit polling rule, not a promise to reconstruct
when already-acknowledged data became complete before registration. Duration validation,
overflow-safe deadline construction and terminal request publication are required.
An irreversibly stopped runtime with a still-live writer is a separate proposed ERROR,
not ALREADY_DELETED. Manual-driver idleness is not runtime failure.

<a id="writer-ack-wait--callback-and-manual-progress"></a>
### Callback and manual progress

Allow this wait from callback/preparation chains with their rights retained. Protocol
ACK/repair, timers and lifecycle completion must progress without automatic callbacks
on the nested stack. Release writer turns and short metadata locks while waiting;
retain the writer, request and association obligations safely. Multiple independent
waiters can have different frontiers and deadlines; one wait does not consume ACK
state or reset another wait's progress.

There is no guarantee of success when delivery depends on application behavior,
including a remote reader making history space or an in-process callback releasing
resources. Infinite wait remains capable of application-level deadlock. Known internal
self-dependencies should be handled by the L5 dependency policy; do not infer one just
because a callback called wait_for_acknowledgments.

<a id="publisher-ack-wait"></a>
## Publisher acknowledgment wait: aggregation contract

<a id="publisher-ack-wait--recommended-scope-fixed-membership-per-writer-capture"></a>
### Recommended scope: fixed membership, per-writer capture

1. Derive one absolute monotonic deadline at API entry, after safe duration
   validation. Under lifecycle membership synchronization, capture and retain the
   currently contained reliable writer lifetimes. Later writers do not join.
2. Arrange one writer-owned capture for every selected writer. Each capture uses
   the accepted DataWriter contract: committed sequence frontier and relevant
   reliable association generations at one boundary. Establish each child completion
   record atomically with checking its predicate; ACK/close cannot be lost between
   checking and subscribing. Do not wait for one child's ACKs before capturing others.
3. Complete OK when every captured child obligation has completed OK. Child success
   is latched: later writes/matches/deletion do not reopen a completed child.
   No reliable writers means immediate OK after normal validation.

The result is a vector of per-writer cuts, not one globally simultaneous snapshot.
A write completed before API entry on a selected still-live writer is covered;
concurrent commits are covered if they precede that writer's capture. An association
matching after Publisher entry but before its writer capture can be included. After
that capture, later writes and matches cannot extend that child's target.

Alternative: one Publisher-wide instantaneous cut, including all writer association
state. This provides a stronger cross-writer snapshot, but requires coordinated
snapshot state, version retention or freezing multiple endpoint contexts. The existing
GROUP commit gate alone does not capture independently changing associations, and
requiring it in every small build would undermine the optional-profile requirement.
Recommend the vector contract initially. It is explicitly weaker than a global cut,
and must not be described as equivalent to one. Sequential *blocking* calls to the
public writer wait are also not equivalent: their late captures can include writes
made while earlier writers were waiting.

<a id="publisher-ack-wait--completion-timeout-and-lifecycle"></a>
### Completion, timeout and lifecycle

All capture, registration and ACK progress uses the original deadline. Never give
each child a fresh max_wait. For zero duration, perform a nonblocking collection of
available predicates; if obtaining a required writer capture would require waiting,
return TIMEOUT. This is not an atomic Publisher-wide poll. For finite calls, an
already satisfied initial aggregate may return OK under the accepted polling rule;
once registered as unsatisfied, no new completion at/after the deadline wins over
TIMEOUT. Capture requests that would need further waiting after expiry are cancelled.

Retain child terminal state independently of when the aggregation continuation runs.
Success before the deadline must not become timeout merely because the caller or
aggregator runs late. Child completions, parent close and expiry need one ordered
aggregate resolution protocol, including during capture; a naive later scan of
child flags is insufficient. Never publish success before all captures are accounted
for. Reserve capture/completion resources before making the request live; resource
failure returns OUT_OF_RESOURCES and unwinds internal registrations without changing
writer state. Concrete bounded storage and handoff design remains to be validated.

* Reader unmatch retires its obligation under the accepted writer policy.
* A selected writer closing before its own obligations complete fails the still-live
  Publisher wait with ERROR. This includes close between membership capture and its
  writer capture. Do not silently drop an unfinished writer from the set.
* A child already completed OK remains complete when that writer subsequently closes.
* Publisher logical close resolves a still-unresolved wait as ALREADY_DELETED before
  contained-writer teardown can instead report child ERROR or accidental success.
* A previously terminal aggregate result is immutable. At/after the deadline, an
  unresolved registered aggregate resolves TIMEOUT before accepting new progress.

ERROR for child loss distinguishes an interrupted operation from deletion of the
Publisher handle itself. Alternatives are propagating child ALREADY_DELETED (simpler
but ambiguous about which entity was deleted) or retiring the writer like a reader
unmatch (permits OK after destroying unacknowledged local history). Recommend ERROR.
This is an operation-specific policy, not a change to DataWriter close behavior.

<a id="publisher-ack-wait--suspension-coherent-changes-and-progress"></a>
### Suspension, coherent changes and progress

Include already committed changes even if transmission is deferred by suspension or
an open coherent set. Uncommitted preparations remain outside the capture. The wait
neither calls resume_publications nor ends a coherent set, and does not grow the
captured target to include later writes in that set. Required existing protocol
repair/metadata may still be needed to acknowledge the covered sequence range.

An ACK is not a promise that coherent data is accessible to the receiving application.
If an implementation can acknowledge captured data before coherent completion, this
wait can finish before end_coherent_changes. If sending/ACK progress is deferred,
completion can require another execution path to resume/end, or the call times out.
Do not reject a call merely because suspension/coherent depth is nonzero: the predicate
may already be satisfied, or another application thread may enable progress. Likewise,
do not invent an implicit flush guarantee for best-effort data.

The normal application sequence for a completed coherent batch is end, resume if
applicable, then ACK wait. The wait is neither a coherent transaction commit nor
remote application acknowledgment. Callback callers retain their accepted rights;
internal protocol, capture and lifecycle progress can run without automatic nested
callbacks. Release coordinator and writer turns before any wait. There is no promise
to resolve application deadlock when the only path to resume/end is after this call.

GROUP-disabled builds still need lightweight membership retention and ACK aggregation,
but not group sequence numbers, coherent-set state or a global commit gate solely
for this API. Work/storage scales with selected writers and their captured reliable
associations, not the number of subsequent writes; implementation must bound resources
and service captures fairly. No mandatory polling interval or new public API is needed.

<a id="historical-data-wait"></a>
## Historical-data wait contract

<a id="historical-data-wait--entry-and-completion"></a>
### Entry and completion

Perform normal argument, duration, enablement and lifetime validation first. Return OK
immediately for VOLATILE readers, BEST_EFFORT readers, or an empty captured set of known
relevant historical sources. Best-effort history may still arrive, but this API treats it
as having no historical-delivery obligation to await. OK on those paths is not proof of
receipt or discovery completeness. Warn at most once per reader lifetime on best-effort
historical wait; avoid allocation or unbounded logging on this path.

For non-VOLATILE RELIABLE readers capture source association lifetimes at one reader-owned
boundary. Later matches do not extend that invocation. Establish a finite history target
for each captured source; absence of its first target is not evidence of an empty history.
Use one absolute caller deadline. Zero duration polls; finite expiry returns TIMEOUT;
infinite duration does not disable close/interruption handling. No periodic polling thread
is required by this contract.

Completion requires protocol accounting through each captured boundary and final local
DDS receive processing of those obligations. RTPS receipt/ACK alone is insufficient:
queued decode, identity/admission checks and cache disposition must finish. Legitimate
filtering/GAP exclusions must be distinguished from lost/rejected required processing;
malformed or capacity-dropped required input cannot silently become completed history.
Retained coherent staging can finish receive processing without making a whole remote
coherent set visible. This wait does not end a remote set or promise future publications.

If a selected source unmatches before its target or protocol accounting is complete,
return ERROR unless another terminal outcome already won. If only safely retained local
processing remains, finish it using retained metadata despite unmatch. Completed sources
stay complete. Same-GUID rematch is a new association, not a substitute for interrupted
work. Reader close follows normal ALREADY_DELETED lifetime rules. Completion, timeout
and close resolve once under the shared request contract.

<a id="historical-data-wait--migration-and-evidence"></a>
### Migration and evidence

The current implementation's nonzero wait for a first match is replaced by immediate
empty-source OK. Record this and best-effort immediate success in the implementation's
CHANGELOG and binding guidance: applications requiring discovery readiness must wait for
that explicit predicate, not historical data on an unmatched reader.

The historical transfer model covers abstract retained processing and terminal ordering;
its pre-D1 best-effort scenarios are historical until updated. Real target establishment,
processing-failure accounting and supported-provider signals remain integration gates.
See [archived investigation](../archive/review-baseline/historical-data-wait.md) for evidence,
not controlling requirements. DDS describes historical receipt for nonvolatile readers;
D1 is the explicit zzdds no-obligation behavior, not a claim that ACK/history predicates
are interchangeable. [DDS 1.4 §2.2.2.5.3.32](https://www.omg.org/spec/DDS/1.4/PDF).

<a id="waitset-wait"></a>
## WaitSet waiting

<a id="waitset-wait--one-admitted-invocation-live-membership"></a>
### One admitted invocation, live membership

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

<a id="waitset-wait--level-observation-not-a-queue-of-trigger-events"></a>
### Level observation, not a queue of trigger events

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

<a id="waitset-wait--deadline-and-closure"></a>
### Deadline and closure

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

<a id="waitset-wait--progress-across-runtimes"></a>
### Progress across runtimes

Separate wake registration from permission to execute a runtime. A WaitSet accepts
conditions from multiple participants regardless of which runtime drives them.
Externally driven runtimes can notify it without the waiter executing their work.
Attaching a condition must not silently enlist an arbitrary foreign runtime into a
nested pump or grant permission to execute its callbacks.

Use the configured shared-runtime helping contract for standard API applications.
The construction-time policy and per-invocation default resolution are defined in
[WaitSet progress selection](#waitset-close-progress). A guard-only WaitSet needs no
participant. Attachment order never chooses or changes its runtime.

A callback waiter retains its execution rights and helps only permitted internal
protocol, condition, timer and lifecycle work, without automatic nested listeners.
A condition depending on that callback's later application actions can deadlock;
attachment alone does not reveal an inferable dependency. An idle or stopped foreign
runtime does not by itself fail the whole WaitSet: another condition or GuardCondition
may still trigger. Failure of the WaitSet's own indispensable wait/progress mechanism
resolves an unresolved wait as ERROR, as specified below.

<a id="waitset-result-ownership"></a>
## WaitSet result ownership across bindings

<a id="waitset-result-ownership--recommended-mechanism-retained-result-batch"></a>
### Recommended mechanism: retained result batch

Give a selected result an internal lease containing exact condition lifetimes,
attachment generations, native/C-box retention and any binding ownership anchors.
Acquire retention while the candidate is still protected by attachment/lifecycle
synchronization, before dropping locks. A later raw-pointer lookup cannot repair a
missed acquisition. A retained binding anchor must preserve the actual wrapper,
not reconstruct its identity from an adapter or multiple-inheritance base address.

Separate logical detach from physical retirement of the attachment ownership record.
Detach removes eligibility immediately. A selected batch can keep the ownership
record alive until it has transferred wrapper ownership to its output. Native pins
are still separately required: retaining a C++/Java wrapper does not necessarily
retain the native reader-owned condition during explicit deletion.

Prefer refcounting an internal ownership anchor that already holds the attachment's
shared_ptr/GlobalRef; do not run arbitrary retain/release hooks under metadata locks
or allocate a JNI GlobalRef on a protocol thread for each trigger. When a selected
batch is retired, final binding cleanup runs outside internal locks and uses the
proper JNI environment. Existing attachment release hooks remain exactly-once;
if the current public hook promises immediate release, use a separate versioned
internal anchor facility rather than silently delaying that existing callback.

The lease must span the complete binding operation:

* Native C/Zig path: protect selection and any native-to-C boxing through output
  publication. Standard raw handles remain borrowed after return; applications must
  coordinate explicit deletion with their subsequent use. Buffer _release does not
  acquire or release condition objects. A retained-result extension could later give
  raw callers explicit longer ownership, but is not necessary for standard APIs.
* C++: hold the lease until each selected wrapper has a strong shared_ptr in the
  output (or temporary output awaiting publication), then release it through RAII.
* Java: keep native and anchor retention through narrowing, boxing and list filling;
  establish strong Java output references before releasing. All JNI failure paths
  release the batch. Do not hold a thread-specific JNIEnv across migration.

A lease only inside the generated C function is insufficient for C++/Java: their
conversion continues after that function returns. Prefer an internal retained-result
entry point or explicit operation envelope used by those bindings, with guaranteed
release on success/exception. Avoid a global last-result slot or unkeyed thread-local
pin stack, both of which fail with reentrancy or concurrent WaitSets. The ordinary C
ABI and ConditionSeq layout need not change. Native C/Zig callers still need valid
object ownership when entering the operation; no mechanism makes arbitrary stale
handles callable.

Do not promise that a returned wrapper can operate on a logically deleted native
condition. Safe deleted-handle invocation requires the separate lifetime-aware handle
contract. In particular, a shared_ptr or Java reference protects wrapper storage, not
automatically the native DDS object's operational lifetime.

<a id="waitset-result-ownership--completion-versus-conversion-failure"></a>
### Completion versus conversion failure

Keep the terminal wait observation separate from delivery of its output. Once a
nonempty observation is committed, reset, detach, timeout and close cannot turn it
into a different wait outcome. But allocation/JNI/C++ conversion can still fail:
that is output-delivery failure, not TIMEOUT, and must release all leases without
clearing condition state or replaying a wait with a new deadline.

Recommend temporary output construction where supported, with defined cleanup on
failure; generic Java List implementations can throw or reenter during clear/add,
so do not promise transactional mutation of an arbitrary application-provided List.
Keep the WaitSet waiter slot until conversion/unwind completes, so same-WaitSet
reentrancy receives PRECONDITION_NOT_MET. Exact ReturnCode versus language-exception
mapping needs to follow the binding's error conventions and remains an implementation
contract item; today's generated panic is not the desired recoverable path.

<a id="waitset-close-progress"></a>
## WaitSet close and runtime helping

<a id="waitset-close-progress--explicit-close-separate-destruction"></a>
### Explicit close, separate destruction

Provide an idempotent, permanent, non-draining close operation on the zzdds WaitSet
extension interface. The standard WaitSet interface remains unchanged. A safely live
wrapper/handle can call close repeatedly and receive OK. Close is not a reset or a
one-shot interruption; a GuardCondition remains the standard reusable stop signal.

At the logical close boundary:

* Reject subsequent wait/attach/get_conditions/detach operations with ALREADY_DELETED
  on safely recognized closed lifetimes. Repeated close remains OK.
* Resolve an unresolved admitted wait as ALREADY_DELETED, subject to the accepted
  deadline arbitration. A previously committed result, including OK, is unchanged.
* Withdraw attachment eligibility and arrange notifier deregistration and ownership
  release. Closing the WaitSet does not delete its attached conditions.
* Preserve selected-result leases and retained in-flight operations until their
  conversions/cleanup finish. Logical close never waits for an application callback,
  conversion, or ownership-release hook to return.

Make logical close available without requiring destruction of the language object.
An application can close from a management thread, let its waiting thread return,
then destroy its wrapper. Destruction internally requests the same close transition
and relinquishes ownership; actual reclamation waits for outstanding internal leases.
This is not permission to destroy a C++ object concurrently with unprotected method
entry, or to invoke a freed raw handle. Valid caller ownership is required at entry.

A close ReturnCode reports logical closure, not that every release hook has run.
Final hooks run outside metadata locks and may require the configured cleanup executor
or a valid JNI environment. Mandatory cleanup capacity must be retained before close;
close cannot depend on allocating a new task after marking the object closed. The
runtime must drain accepted cleanup before destroying its backend resources. Optional
external quiescence APIs are not needed for this initial close operation.

Alternative: close waits until the active invocation and hooks finish. That makes
some external cleanup convenient, but risks self-wait during reentrant conversion or
hook execution and needs the callback-context distinctions used by entity deletion.
Use non-draining close consistently; normal wrapper/thread ownership supplies
the application's destruction ordering.

<a id="waitset-close-progress--stable-helping-policy"></a>
### Stable helping policy

A WaitSet needs a wake/deadline mechanism, but is not owned by a participant and need
not create a participant, socket or worker. Provide these construction policies:

| Policy | Permission granted to a waiting caller |
| --- | --- |
| Default shared runtime | Bounded internal helping on the configured default shared runtime only |
| Explicit runtime set | Bounded internal helping on the explicitly retained, finite selected runtime set |
| No helping | Observe conditions and block on notifications/deadline; runtime progress is supplied elsewhere |

Use Default shared runtime for standard construction. Resolve its runtime identity
at each successful wait admission, using a synchronized configuration snapshot, and
retain that identity until the invocation finishes output conversion or unwind.
Attachment order and configuration changes during that invocation do not retarget it.
If no default runtime exists, use no helping for that invocation, without creating
one merely for a guard-only wait. A later invocation can discover a subsequently
configured default. This per-invocation resolution is accepted and replaces the
earlier first-wait binding proposal.

The default policy is fixed on the WaitSet; its resolved runtime is fixed on the
invocation. Explicit-runtime and no-helping policies do not follow default changes.
Resolving and retaining the selected runtime must be safe against concurrent stop
or replacement; a pointer lookup followed by an unprotected retain is insufficient.
The runtime configuration specification must define the default explicitly, rather
than letting incidental factory creation or condition attachment order choose it.

Explicit configuration is construction-time, belongs in zzdds.idl, and does not
require corresponding methods on dcps.idl. Preserve ordinary factory-less language
construction through the bootstrap already used for WaitSet. A runtime reference
retains identity/storage; it does not grant ownership to shut down that runtime.
Do not select the first attached condition's runtime or enlist every runtime in the
process. No-helping remains useful for externally integrated loops and thread-affine
runtime backends. An explicit set must be validated for the selected build/backend's
helping capabilities at construction; unsupported configurations fail visibly.

Hosted default applications can rely on background progress. In a manual build,
waiting can drive permitted internal protocol/timer/condition work with bounded fair
turns, but cannot automatically dispatch nested application listeners. Callback
callers retain their accepted exclusion rights. Participants using other runtimes
still supply notifications, but require their own driver unless explicitly enlisted.

A finite set is sufficient for the initial policy; dynamic mutation during an active
wait is unnecessary. All helping shares the wait's absolute deadline and normal
runtime admission/budget rules. There is no mandatory thread hop for an already true
condition. The wait backend must remain usable for GuardCondition and timeout even
without any runtime configured.

<a id="waitset-close-progress--runtime-stop-is-not-waitset-close"></a>
### Runtime stop is not WaitSet close

Stopping one selected runtime removes its ability to make protocol progress; it does
not automatically close the WaitSet or make the whole wait fail. Another condition,
a GuardCondition, or the deadline can still resolve it. Do not implicitly substitute
a replacement runtime with the same configuration or address: retained identities
must distinguish lifetimes. A stopped selection remains inert for the rest of its
invocation. The next default-policy invocation resolves the then-current default
again. An explicitly selected stopped runtime is not automatically replaced; changing
that construction-time selection requires another WaitSet.

Only an irrecoverable failure of the WaitSet's own wake/deadline mechanism warrants
ERROR for its unresolved wait. Normal manual idleness, absence of a configured runtime
and runtime stop are not that failure. Close must have a retained path to wake a
waiter independently of the stopped runtime's ordinary work queue.
