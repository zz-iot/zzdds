# Remaining L5 operation results

Status: mapping direction accepted, 2026-09-15. Existing commit, loan, listener and
lifecycle decisions remain authoritative; exact variant/binding audit gates remain.
This is a contract checklist, not a claim that every production path conforms.

## Shared effect boundary

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

## Mapping table

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

## Deadline and failure classification

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

## Concrete audit gates before implementation completion

* Check generated C/Zig/C++/Java mappings for every variant, including nil handles,
  sequence ownership, allocation failure and exceptions after effect commitment.
* Check dispose/unregister publication and implicit instance registration for atomic
  failure behavior; do not conflate the local bookkeeping with remote delivery.
* Verify read/take copy-versus-loan publication against close and GROUP access rules,
  including condition validation and status changes.
* Verify release-only operations and mandatory cleanup survive stop/reservations.
* Preserve exact operation-specific preconditions rather than inventing one global
  error-priority ordering for unrelated invalid arguments and concurrent close.

The named existing models cover commit ordering, loans/preflight, listener retirement,
ACK waits, WaitSet and historical transfer pieces. They do not prove all mappings or
bindings. Add targeted integration tests for actual changed paths; another broad
prototype is unnecessary merely to restate these results.

The mapping direction is accepted. The [consolidated contract](concurrency-contract.md)
separates settled L5 policy from remaining runtime/API decisions and concrete audit
gates. Acceptance does not claim that all variant-specific mappings are implemented.

The [writer lifecycle audit](writer-lifecycle-results.md) now verifies the blocking
references and handle-error distinctions and records current registration/deadline
gaps. Reader variant review is recorded below; concrete migration tests remain.

The [reader variant audit](reader-variant-results.md) records condition ownership,
sequence/raw distinctions, result provenance and cursor dependencies. The condition
next-instance wording discrepancy is documented there; strict advancement is the
accepted zzdds interpretation, not an asserted OMG erratum.
