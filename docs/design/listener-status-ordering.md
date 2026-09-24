# Ordering and coalescing of listener statuses

Status: accepted initial L2 ordering/coalescing policy, 2026-09-11. Refines
listener-execution.md section 6; not implemented in production. Read-status reset rules and explicit delegation have
separate accepted contracts.

## Recommendation

Coalesce independently within each status kind. Order automatic notification
opportunities for one source entity by their first eligible pending change. At
claim, supply the current status aggregate and consume its changes atomically.
Do not preserve a historical argument snapshot for each event, or make one status
kind permanently higher priority than another.

This orders opportunities to observe state. It cannot order every change represented
inside an aggregate. A later update can be included in an earlier queued opportunity.

## Standards evidence

DDS 1.4 section 2.2.4.3.2 permits multiple same-kind changes to produce one callback
carrying current status. Sections 2.2.4.1–2.2.4.2 define individual counters and resets;
plain statuses reset before callback entry or through their specific getter.
SubscriptionMatchedStatus distinguishes cumulative matches from current matches and
changes since observation. These rules do not specify the proposed cross-kind queue
policy. [DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

## Accepted mechanism and observable scope

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
  recommend publishing a fresh opportunity then, without backdating it ahead of
  existing eligible work. This catch-up-on-registration behavior is zzdds policy
  proposed here; exact listener routing and nil semantics remain applicable.
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

## Concrete traces

Assume one reader, enabled callbacks throughout, no getters, and dispatch delayed
until the listed updates have accumulated. M denotes SUBSCRIPTION_MATCHED and D
DATA_AVAILABLE; these are different kinds, while match and unmatch both update M.

| Committed updates | Pending opportunities | Observation |
| --- | --- | --- |
| Match W; data; unmatch W | M, D | One M callback can report total_count_change=1, current_count=0, current_count_change=0; D follows if still eligible |
| Data; match W | D, M | D precedes M under this local policy; no fixed match priority |
| M callback claimed; data; another match | D, new M | First M arguments remain fixed; the second match belongs to the later M opportunity |
| Match; data; specific match-status getter | D | Getter consumes M changes; no historical M callback is replayed |
| Liveliness loss; data/state change; liveliness recovery | Liveliness, D | Liveliness callback reports current counts and accumulated deltas, which may net to zero |

The first row starts with no prior matches for clarity. Cached data may remain
readable after unmatching, subject to the reader's normal history/lifecycle rules.
A listener observing zero current matches before a data callback is not inherently
an inconsistency. The queue records when observation became pending; its arguments
can include state changes committed later than another kind's queue position.

Do not infer "unchanged" from zero net deltas. A loss followed by recovery can leave
counts and net changes at their previous values while the changed flag still records
unobserved transitions. That opportunity remains eligible until a legitimate reset.
Likewise the last handle represents the status's specified last relevant event,
not a list of every affected endpoint. Follow each status's own aggregation fields;
there is no generic sum-every-field operation.

## Alternatives and costs

A fixed kind priority is simple but arbitrary and can starve lower-priority kinds
under sustained traffic. Moving a coalesced opportunity to the tail on every update
can postpone a busy status indefinitely. A historical event log grows with traffic,
needs a new overflow contract, and would not be ordinary current-status observation.
The proposed first-pending order keeps storage proportional to entity/status kinds,
with independent bounded callback argument and admission storage requirements.

This is not an optional lossless event stream. If applications eventually need every
transition, that requires a separately specified extension rather than a promise
attached to standard DDS status callbacks.

## Current source and validation to follow

Reader `notifySubscriptionMatched`, `notifySampleLost`, and `notifyLivelinessChanged`
in src/dcps/reader.zig snapshot before dispatch and reset fields after callback return.
That structure cannot implement the proposed claim-time aggregation/reset contract:
intervening getters can make snapshots obsolete, and updates during callbacks can
be erased by return-time resets. Source inspection identifies the mismatch; this note
has not run production race tests or changed that implementation.

A focused fixture should exercise the table, zero-net-delta eligibility, getter
versus claim, changes during callback execution, registration readmission, and a hot
status yielding to an older different-kind opportunity. It must distinguish source
order from shared-identity admission and keep explicit delegation's exception visible.
The existing read-status fixture does not validate plain-status arithmetic or this
cross-kind policy. Decide the observable policy before extending that fixture.

## Bounded validation completed

Run `python3 docs/design/listener_plain_status_model.py`. Six scenarios explore
318 scenario-states and 570 transitions, interleaving fixed update sequences with
callback claim/return and one independent getter. The fixture checks conservation
of observed plus pending deltas, FIFO claim order, immutable claimed arguments,
queue membership and a completion path from every state. Explicit traces check
match/unmatch arithmetic and a hot kind rejoining behind another waiting kind.
Reachable witnesses cover zero-net-change dispatch, coalescing without queue movement,
getter withdrawal and new same-kind work surviving callback return.

The negative control resets at callback return and loses unobserved deltas from
an intervening update. This independently confirms why reset belongs at claim.

Scope: one entity, two always-enabled plain-status kinds, additive counter fields,
one getter, atomic status/admission transitions and finite arrivals. Liveliness
fields model changes relative to a baseline, not full writer membership. The second
kind is a generic plain status, not DATA_AVAILABLE; the earlier read-status model
covers read resets separately. Last handles, policy-count sequences, registration
changes, parent routing, shared-identity FIFO, explicit delegation, real threads and
infinite-arrival fairness are outside this fixture. Those remain integration checks;
no broader runtime prototype is required to accept this policy.
