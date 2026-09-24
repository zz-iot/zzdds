# Publisher acknowledgment wait: aggregation contract

Status: accepted L5 policy; bounded aggregation model checked, 2026-09-14.

## Standards and source audit

DDS 1.4 section 2.2.2.4.1.12 defines acknowledgment waiting across reliable writers.
Sections 2.2.2.4.1.8–11 describe suspension as an optional batching hint and coherent
boundaries as application-controlled operations. These sections do not explicitly
choose a concurrent membership/capture algorithm or require an ACK wait to resume
publication or close a coherent set. The choices below are accepted zzdds policy.
[OMG DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

Current `src/dcps/publisher.zig:655` polls every 1 ms. Each iteration holds the
Publisher mutex while traversing its current writers and calling `w.allAcked()`.
That helper (`src/dcps/writer.zig:426`) loads the latest wrapper `last_sn` on each
call. Thus neither writer membership nor write targets are fixed for the call.
The Publisher loop uses one deadline, but checks success before expiry on each
iteration and has no explicit close outcome. These are source observations, not
reproduced concurrent execution failures.

## Recommended scope: fixed membership, per-writer capture

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

## Completion, timeout and lifecycle

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

## Suspension, coherent changes and progress

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

## Bounded validation and implementation requirements

The user accepted the vector capture policy and accompanying lifecycle/suspension
rules before this experiment. Run `python3 docs/design/publisher_ack_wait_model.py`.
Two scenarios pass: initially unsuspended (5,826 states, 14,725 transitions) and
initially suspended (7,166 states, 18,237 transitions). Totals are 12,992
scenario-states and 32,962 transitions; overlapping states across scenarios are
not deduplicated. Ten outcome witnesses are reachable.

The model starts with fixed membership of two writers, each with one committed
sequence. It interleaves independent captures/ACKs, a second commit on one writer,
an excluded later writer, child/parent close, one logical deadline, external resume,
aggregation notification and caller wake. An explicit child-state vector checks a
separate remaining-obligation counter. Invariants cover fixed captured targets,
latched child success, immutable aggregate results and safe caller delivery.

Three faulty variants are detected:

* Omitting uncaptured writers from accounting returns OK after only A is captured
  and acknowledged, while B remains uncaptured.
* Resolving success only when an aggregation notification is serviced lets parent
  close replace success after both children completed. An additional directed trace
  demonstrates the corresponding false TIMEOUT when expiry precedes notification.
* Resolving child teardown before Publisher close returns ERROR instead of
  ALREADY_DELETED.

Consequently, every selected writer needs an outstanding placeholder before capture
dispatch. Its slot retires once on successful capture/completion or participates in
terminal failure/cancellation. Capture completion and ACK completion must feed the
same aggregate arbitration protocol; the last successful slot commits OK there.
Notification only delivers an already determined result. No policy change was needed.

This is finite abstract ordering validation, not production implementation testing.
The deadline is a logical event, and external resume abstracts the release of a
send dependency; there is no RTPS coherent-marker implementation in this model.
Initial zero-duration polling, resource allocation, cancellation reclamation, actual
timer registration, capture fairness, association churn and the concrete atomic/lock
handoff remain implementation validation work. Writer-level association semantics
have their separate model; the two models do not prove their full composition.
Every unresolved state has a completion path, not a guarantee of scheduler fairness.

## Next scope

Proceed to WaitSet and historical-data waits in the L5 matrix. A new full runtime
prototype is not required to settle the Publisher ACK policy.
