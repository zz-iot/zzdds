# DataWriter acknowledgment wait: frontier and completion contract

Status: accepted L5 policy, bounded model checked, 2026-09-14. Scope is protocol acknowledgment for one
writer; Publisher aggregation and application acknowledgment extensions are separate.

## Standards boundary

DDS 1.4 section 2.2.2.4.2.15 makes best-effort writer waits immediately successful
and describes reliable acknowledgment completion versus max_wait timeout. It does
not explicitly specify the concurrent write/association snapshot algorithm below.
The fixed frontiers and departure policy are accepted zzdds interpretations.
[OMG DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

## Recommended capture

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

## Association changes while waiting

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

## Deadline, close and completion proposal

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

## Callback and manual progress

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

## Current source findings

writer.vtWaitForAck (src/dcps/writer.zig:895) captures an atomic last_sn, then calls
proto_writer.waitAllAcked. writer_sm.allProxiesAckedLocked (line 608) walks the current
proxy list on each check. Thus the write target is fixed but reader membership is
currently dynamic. Its numeric comparison does not itself use the reader's start
range. waitAllAcked checks success before timeout on every wake and returns only a
boolean, with no explicit close outcome in that routine.

write publication stores last_sn after proto_writer.write returns (writer.zig:335).
A completed prototype commit frontier should be the authoritative source in the new
architecture; separate wrapper metadata must not define a weaker boundary. Whether
concurrent production writes can publish that mirror out of sequence requires a
call-path audit; no such race is claimed as reproduced here.

These are source observations, not production behavior tests. The proposed contract
requires retained association identity, completion registration and close ordering,
not merely another condition-variable loop.

## Bounded validation

The user accepted the recommended policy before this experiment. Run
`python3 docs/design/writer_ack_wait_model.py`: 2,106 reachable states and 5,769
transitions pass, plus five initial predicate/polling cases. The model starts after
capture with one committed sequence and two reliable association generations. It
interleaves a later write, a new match, unmatch/rematch with the same GUID, old-generation
ACK records, logical deadline expiry, writer close and caller wake. A separate
captured-obligation ledger checks completion outcomes against the association-state
predicate. All seven requested outcome witnesses are reachable.

Negative controls detect live membership extending the target, treating proxy removal
on writer close as success, and substituting a rematched generation into the captured
set. Every unresolved state has a completion path; this is not a scheduler fairness
or production liveness proof. Deadline expiry is an atomic logical event: the model
checks both orderings with ACK/close, but not timer registration or delayed timer
service machinery. Caller wake can be delayed independently of result commitment.

The later-write event deliberately cannot change the captured sequence; this checks
the specified invariant, not concurrent sequence publication in production. Actual
RTPS ACKNACK range/GAP interpretation, pre-capture races, allocation failure, multiple
waiters and runtime shutdown still require implementation validation. No production
code changed and no end-to-end delivery or performance claim follows from this model.

## Next scope

Publisher scope must
be audited separately; do not automatically assume a set of independent writer waits
provides one coherent Publisher-wide capture or one shared timeout.
