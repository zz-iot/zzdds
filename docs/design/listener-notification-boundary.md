# Delegation membership and notification boundary

Status: accepted initial membership/current-status boundary, 2026-09-11. Admission, recursion and error
policies are accepted separately in [listener-delegation-decision.md](listener-delegation-decision.md).
This note records observable boundaries; no production implementation is implied.

## Recommendation

Freeze reader membership once; observe each reader's current notification state at
its dispatch claim. Visit each retained reader at most once per call. Do not freeze
all reader statuses at API entry or revisit readers until the Subscriber is quiet.
This refines the earlier tentative phrase "candidate readers/notification generations":
notification generations protect consumption and stale work, rather than selecting
an immutable historical notification batch.

| Choice | Consequence |
| --- | --- |
| Snapshot membership and all pending notifications together | Stronger historical cut, but requires coordinated status capture across reader owners and reconciliation with intervening consumption |
| Snapshot membership; check current status per reader | Finite traversal, local status coordination, useful coalescing; arrival timing can affect which callbacks this call invokes |
| Continue rescanning until no reader is pending | Can chase continuous traffic indefinitely and repeatedly invoke the same reader |

The middle choice is recommended. A callback is an opportunity to inspect current
reader state; this operation does not supply a private sample snapshot.

## Standards boundary

DDS 1.4 section 2.2.2.5.2.11 targets attached reader listeners whose DATA_AVAILABLE
status is changed. Sections 2.2.4.2.2 and 2.2.4.3.2 define read-status resets and
Subscriber-first automatic routing. They do not define a concurrent membership cut
for this operation. The snapshot/claim boundaries below are zzdds policy.
[OMG DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

## Accepted traversal contract

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
   The accepted [selection policy](listener-selection-audit.md) ignores the reader
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

## Reader and Subscriber status coordination

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

## Boundedness and implementation evidence still needed

An initial retained membership list costs O(number of contained readers) traversal
and handle storage per active call. Capacity failure must not silently truncate it.
A stable membership cursor or sparse notification index is allowed only if it retains
these membership and current-status semantics. No all-reader lock is required across
callbacks; no per-arrival event log or GROUP-only snapshot machinery is required.

Review these finite traces before implementing the boundary:

* New reader after membership capture: excluded, including reused storage identity.
* Initially quiet captured reader changes before its turn: one callback if still eligible.
* Read/take resets status while a child waits: recheck/withdraw; no obsolete invocation.
* Reset followed by a new change before claim: may invoke once for current status.
* Arrival after claim or after this reader's turn: return must not erase it or rescan.
* Automatic dispatch wins the same pending status: explicit dispatch rechecks, avoiding
  duplicate consumption; a later change can legitimately make it eligible again.
* Two-reader Subscriber reset ordering as described above.
* Empty batch, no attached listener, replacement during wait and partial error.

These are proposed trace requirements, not executed tests. The existing admission
models intentionally omit status state. The next useful validation is a small status
transition fixture after this observable policy is accepted, rather than extending
queue lifetime machinery first.

## Initial status experiment

`python3 docs/design/listener_status_model.py` passes 16 scenarios, 803
scenario-states and 1,374 transitions. It explores two fixed member readers,
one traversal, one new arrival, one independent read/reset, and release of
contending callback rights. Every state has a completion path. Checks cover
at-most-once invocation, claim-time status consumption, no consumption while waiting,
and no status reset at callback return. Reachable witnesses demonstrate withdrawal
while rights remain busy, a clear Subscriber flag with a pending reader flag, and
preservation of an arrival during a callback.

The negative control resets status on callback return and loses a change arriving
between claim and return. This supports the ordered claim/reset boundary; it does
not test real wake delivery, generation storage, automatic routing, membership
mutation, registration lifetime, masks, or the synchronization of two owner contexts.
The read event represents an access that legitimately resets status; it makes no
claim about unsuccessful read variants. Remaining trace requirements above still
apply to implementation validation. No larger runtime prototype is required to
accept this boundary.
