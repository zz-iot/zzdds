> Historical source snapshot, superseded by the consolidated contracts.
> Unaccepted alternatives and old completion statements below are not current policy.

# Prepared read/take: selection, claims and failure

Status: revised behavioral contract, 2026-09-28, implementing user decisions D7/D8.
Replaces optimistic validation and the four-conflict ERROR budget. The old policy/model
is historical, not evidence for this replacement. See [decisions](review-decisions.md).

## Admission and conversion capability

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

## Claims and restoration

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

## Observable failure contract

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

## Acceptance traces

Check two takers with one failing; a successful read depending on an earlier failed read's
READ state; lifecycle rebirth; KEEP_LAST eviction; expiry; reader/access close; overlapping
GROUP consumers; restoration order; condition and WaitSet wake; and output failure after
consumption. Negative controls must detect rollback of READ state and restoration of an
evicted sample. Pin/claim capacity and partial nested output cleanup are independent bounds.
The review trace suite passes 363 claim/access/condition schedules, including two takers,
read-state dependence, eviction/expiry/deletion, rebirth, access close and restoration wake.
The earlier 24-order trace has negative controls for state rollback and resurrection.
These are abstract cache/predicate traces, not concrete QueryCondition evaluation, full
coherent wire assembly or generated conversion. The archived optimistic model cannot
establish the replacement contract; binding fault injection remains an implementation gate.
