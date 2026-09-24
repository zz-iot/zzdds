# Historical-data wait: scope and completion contract

Status: known-source scope, receive-processing completion and best-effort timeout
direction accepted; bounded transfer model checked, 2026-09-14. An empty captured
set returns OK regardless of timeout. Concrete provider evidence, receive-path
strengthening and runtime integration remain implementation work. No production change yet.

## Standards boundary

DDS 1.4 section 2.2.2.5.3.32 describes waiting for historical data on non-VOLATILE
readers, with OK for receipt and TIMEOUT for exceeding max_wait. It distinguishes
historical from continuing new publication but does not supply an explicit discovery
completion algorithm in this operation's description. The paragraph uses the label
PERSISTENCE; the implemented policy here is durability. Do not infer a new QoS policy
from that wording. [OMG DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

## Current behavior

`src/dcps/reader.zig:3157` returns OK for VOLATILE, otherwise polls every millisecond
using one deadline. A zero-duration call trusts the current historicalDelivered
predicate. Nonzero calls additionally require hasMatchedWriters, which is actually
an ever-matched flag, not current membership or proof of discovery completion.

`src/rtps/reader_sm.zig:1017` traverses current writer proxies and checks whether each
has an established history target and cumulative sequence accounting through that
target. Around line 909 the first heartbeat establishes history_floor_sn from its
last sequence. Later traffic therefore need not continually extend that target.
GAP processing also updates received sequence accounting. The DDS-level predicate
and ever-matched checks use separate protocol-lock acquisitions.

Consequences to investigate, not reproduced failures:

* An initially empty reader waits on a nonzero call but succeeds on a zero call.
* Once any writer has ever matched, an empty current set can count as complete.
* Current writer-list traversal makes membership dynamic while waiting.
* Neither an ever-matched flag nor the first heartbeat proves that all potential
  historical sources have been discovered.
* Protocol accounting can include GAPs; its relation to reader-cache acceptance,
  rejection, filtering and coherent visibility must be audited before promising
  successful historical receipt.

## First decision: discovery scope

Capture currently known relevant historical-transfer association
lifetimes at one reader-owned boundary. Later matches do not extend that invocation.
An empty captured set returns OK for both zero and nonzero durations, after normal
validation. This means completion for the selected known sources, not a claim that
no unknown source exists. A writer already selected but lacking a history boundary
remains pending; absence of its first heartbeat is not an empty history.

This accepted policy changes the current startup behavior. The user favors removing
the implicit discovery wait, consistent with an empty-obligation interpretation of
ACK waiting. This is a selected zzdds interpretation, not a demonstrated OMG
conformance violation in the existing implementation. Applications needing
specific publishers must establish their required matching/readiness predicate
before calling the historical wait. An arbitrary sleep or waiting for just one
writer is not a replacement for a known source set. A future broker could provide
an explicit discovery snapshot/fence for a defined scope, but this standard operation
must not imply global discovery completeness merely because a broker is configured.

Alternatives:

| Scope | Benefit | Limitation |
| --- | --- | --- |
| Known associations at capture (recommended) | Finite, explainable target independent of later discovery | Application must establish required sources for startup guarantees |
| Wait for first source, then capture | Convenient single-writer startup | First source does not establish completeness; empty domains wait until timeout |
| Include new sources while pending | Resembles current live-list behavior | Discovery churn extends work; the momentary empty/completed set is still not a discovery fence |

Keep VOLATILE's existing immediate OK after argument/lifetime validation as a
compatibility recommendation, without promising replay. Durability services and
other optional profiles must eventually identify their actual transfer sessions;
this snapshot proposal is not a claim that transient-local proxies implement them.

## Completion questions to resolve next

The source set alone is insufficient. Each selected transfer needs a finite history
boundary, distinct from later live traffic, and a completion state distinguishing:

* Relevant history accepted into DDS receive processing under its QoS.
* Legitimately excluded or no-longer-applicable changes.
* Irrecoverably missing required history or failed transfer.

A cumulative RTPS sequence frontier is useful evidence but is not by itself a
complete definition of these states. Do not automatically import ACK-wait's
unmatch-retirement-to-OK policy: a departing historical source may leave required
data unreceived. Recommend ERROR for a selected unfinished source that disappears,
subject to auditing normal GAP/retention behavior so expected durability semantics
are not mistaken for failure. A completed source stays completed after unmatch.
Same-GUID rematch must not revive the old transfer implicitly.

Similarly, completion must not depend on application callbacks finishing or samples
remaining forever in the cache after another consumer takes them. However, a local
resource rejection cannot be silently equated with successful admission. Repair and
cache admission must progress independently of notification where possible; finite
resource limits may require application consumption and can prevent completion.
Coherent presentation is a separate visibility constraint to reconcile explicitly.

Use the common single deadline, immutable terminal result and reader-close
ALREADY_DELETED direction. Initial state observation versus registered completion
follows the existing L5 boundary. Multiple calls should have independent targets
and must not consume shared history completion evidence. Unsupported durability or
best-effort completion guarantees must be identified rather than invented.

## Next work

Discovery scope is settled. Next trace heartbeat/GAP/receive-to-cache admission
and loss/rejection paths to specify finite transfer completion, including source
removal. Only then add a bounded model. No production behavior has changed in this
investigation, and the source audit does not establish interoperability conformance.

## Receive-path audit and completion choices (2026-09-14)

The source confirms separate transport and DDS processing boundaries:

* `reader_sm.deliverChangeLocked` records an in-order sequence in `received` before
  `cache.addReaderChange`, which can fail. Out-of-order samples also enter sequence
  accounting before eventual DDS processing. `deliverPendingLocked` catches cache
  insertion failure and only invokes the DDS callback if a cached change exists.
* `reader.onDataCb` returns void. Its initial payload duplication can fail and return;
  resource-limit rejection updates SAMPLE_REJECTED then returns. No admission result
  is returned to the RTPS caller. KEEP_LAST replacement is explicitly separate from
  rejection. Thus the existing cumulative frontier cannot certify successful cache
  admission, even though internal callbacks currently execute synchronously.
* Both explicit GAP and heartbeat first-sequence advancement can settle sequence
  accounting without receiving the corresponding payload.

These are source observations, not executed fault-injection tests. Do not turn this
wait audit into an unreviewed reliability-layer rewrite; the eventual internal handoff
must distinguish protocol accounting from DDS processing outcome regardless of how
ACK policy itself is implemented.

An important standards qualification: DDS's SAMPLE_REJECTED definition describes a
sample as received but rejected. Therefore, the word "received" in historical waiting
alone does not establish that rejection must fail the wait. A stricter admission
contract would be an explicit zzdds policy, not a demonstrated standard requirement.
[OMG DDS 1.4, sections 2.2.2.5.3.32 and 2.2.4.1](https://www.omg.org/spec/DDS/1.4/PDF).

RTPS 2.5's change-state model distinguishes received data from unavailable changes,
including filtered/removed cases. A bare cumulative frontier loses distinctions
relevant to a stronger completeness claim. Older wire information and the current
`handleGap` interface may not provide a reason sufficient to classify every gap.
Do not interpret every GAP as sample loss, or every GAP as successful payload receipt.
[OMG DDSI-RTPS 2.5, section 8.4.12](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

### Recommended next boundary: completed DDS processing, not retained cache contents

Recommend requiring covered DATA to finish DDS receive processing before the wait
completes, without requiring listener execution, application consumption, or continued
cache retention. This adds the missing internal handoff boundary but avoids turning
historical waiting into an application delivery receipt. Distinguish final processing
outcomes, including admitted, policy-excluded, rejected and failed, rather than using
one void callback plus a sequence counter as evidence for all of them.

There are two defensible policies for explicit DDS resource rejection:

| Policy | Meaning | Tradeoff |
| --- | --- | --- |
| Complete processing; report rejection through DDS status (recommended) | Data was received and processed; not all data necessarily entered the application cache | Matches the received/rejected distinction; applications needing usable history must also monitor loss/rejection |
| Fail this wait with ERROR | At least one covered relevant sample could not be admitted | Stronger startup assurance, but stricter than receipt alone and adds sticky per-transfer failure semantics |

This refines the earlier suggestion that cache rejection must not count as successful
admission: it still must not, but wait completion need not mean admission. Silent
allocation failure with no recorded outcome remains an internal failure and should
not masquerade as a completed DDS processing step. A retained retry is pending until
it completes or the deadline expires; no automatic application callback recursion is
introduced to release resources.

GAP and source-departure policies must be selected consistently with that meaning.
For a receipt/processing contract, normal protocol exclusion/unavailability can settle
transfer accounting while DDS loss/rejection statuses remain independent. An unfinished
selected association disappearing is distinguishable from a protocol-established
end of available history; ERROR remains the recommendation for that interruption.
Neither a global SAMPLE_LOST counter nor its resettable change count is sufficient to
attribute a failure to this captured transfer. Exact boundary establishment, ambiguous
GAP handling, coherent staging and best-effort transfer completion remain to settle.

The receive-processing direction is selected following discussion: complete explicit
DDS processing outcomes without promising successful admission of every sample.
Preserve outcome information so a future stricter completeness facility is possible;
no new public strict-wait API is selected. The production reception/admission audit
and strengthening work is tracked in the [roadmap](../roadmap.md#discovery--rtps--transport).
The concurrency spec defines ownership, handoff and completion requirements; finishing
the specification does not require implementing the entire receive-path refactor.

Next settle finite history-boundary establishment, GAP/unavailability accounting and
unfinished-source departure under this receive-processing interpretation. Coherent
staging and best-effort limitations must be stated before a bounded transfer model.

## Proposed finite transfer and departure rules

Status: direction accepted and bounded model checked after the receive-processing decision.
The initial concrete scope is reliable transient-local replay. Other durability
providers must supply equivalent explicit transfer identities/boundaries.

### Association-scoped boundary

Retain the initial history boundary for each association generation; do not establish
another boundary every time the application waits. For the current RTPS path, use
lastSN of the first valid applicable HEARTBEAT processed for that association as the
finite upper boundary H. If that boundary is already established when the wait captures
its source set, reuse it. Otherwise retain an unknown-boundary obligation until the
first qualifying heartbeat arrives, the deadline expires or the source is lost.

Validate source/association identity and heartbeat validity before using it. Merely
seeing DATA, a high sequence, an idle period or no pending fragments does not establish
that no older history remains. Later heartbeats and DATA beyond H do not extend this
transfer. The first heartbeat can include writes concurrent with discovery; this is a
practical association replay boundary, not an exact timestamp snapshot at reader enable.
Do not advertise the latter without a protocol that can establish it.

Use the heartbeat's firstSN and normal GAP/relevance information to settle unavailable
prefixes/ranges; do not demand delivery of every positive sequence number since writer
creation. Previously received covered DATA still needs its DDS processing outcome even
if a subsequent availability announcement no longer includes it. An empty valid history
range settles the protocol part, but does not erase already retained covered work.
Represent ranges compactly; a large advertised sequence number must not cause linear
allocation or scanning of every historical number.

### Two completion components

A selected source completes when both are satisfied:

1. Its boundary is known and all covered sequence obligations are protocol-accounted:
   valid DATA, valid exclusion/GAP, or valid unavailability information.
2. Every retained covered DATA item has reached a final DDS processing outcome.
   A queued handoff, fragment-incomplete sample or retained retry is still pending.

Keep outcome categories separate: received-and-processed, filtered, removed and
unavailability with unspecified reason. A GAP can settle an obligation without proving
payload receipt. An unspecified reason stays unspecified; do not infer filtering or
attribute a SAMPLE_LOST count merely from an undifferentiated GAP. Emit standard status
changes according to their own audited rules, not a new blanket rule invented by this
wait. Explicit DDS rejection is a completed processing outcome under the selected
contract, while unrecorded failure is not.

This matches the distinction in RTPS 2.5 section 8.4.12.3 between received data and
filtered/removed/unspecified unavailable changes; older peer information may not
identify a reason. The standard wait's OK is therefore documented here as completion
of the selected available-history processing, not certification of a lossless archive.
[OMG DDSI-RTPS 2.5](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

A protocol exclusion must not discard an already registered local processing obligation
just to make the wait complete. Conversely, normal application take, status reset or
KEEP_LAST replacement after processing does not reopen completion. Concurrent waiters
share retained transfer evidence but have independent request deadlines/results; reading
status counters cannot erase their evidence.

### Departure: remote dependency versus local work

Refine the earlier blanket unfinished-source ERROR recommendation:

* If the boundary is unknown, or covered protocol obligations remain unresolved,
  logical unmatch interrupts this selected transfer and resolves its pending wait as
  ERROR (unless the wait already timed out/closed/completed).
* If the boundary and protocol accounting are complete and only safely retained local
  DDS processing remains, unmatch does not fail the wait. Finish that local processing
  using retained association metadata, independently of the removed proxy's storage.
* A source already completed remains complete. Temporary transport loss is not logical
  unmatch and leaves the transfer pending. Same-GUID rematch creates a new generation,
  excluded from the already captured wait; it cannot silently replace the failed source.

Retain initial-transfer completion/failure evidence for the live association lifetime,
not only while a wait is currently registered. For removed generations, retain what
existing requests/local work need; later calls capture current associations, so an empty
set still returns OK. A future durability provider that can resume the same logical
transfer from another source needs an explicit continuity contract; plain rematch does
not establish it.

### Visibility and remaining scope

Admission into retained coherent staging may finish a receive-processing obligation
without making that sample application-visible. Historical waiting does not end a
remote publisher's coherent set or promise a completed Subscriber access view. Required
protocol/control processing through the captured boundary must finish, but no unlimited
future coherent publication is added to the target merely to force visibility.

Best-effort waiting is supported (user decision): lack of a usable history boundary
or completion evidence leaves the captured transfer pending. A finite max_wait returns
TIMEOUT if it cannot complete; an infinite duration can wait indefinitely. Do not
reject this operation solely because the reader is best-effort, promote its reliability,
invent repair guarantees, or treat silence as completion. Valid provider/protocol
evidence can complete it, but receiving a later best-effort sequence alone is not proof
that missing historical samples arrived or were legitimately excluded. The accepted
empty-source immediate OK rule still applies. Reader close and source-interruption
rules remain independent terminal paths; infinite duration does not disable them.

Reliable-transfer direction and best-effort timeout risk are accepted. The model below
checks their abstract completion ordering. Concrete provider signals and receive-path
integration require implementation validation; acceptance does not claim that current
best-effort accounting satisfies this contract. No production changes or conformance
results are claimed.

## Bounded transfer validation

Run `python3 docs/design/historical_transfer_model.py`. Three scenarios pass:

| Scenario | States | Transitions |
| --- | ---: | ---: |
| Finite wait, boundary/GAP evidence available | 50,904 | 158,940 |
| Finite wait, boundary evidence unavailable | 6,312 | 18,276 |
| Infinite wait, boundary evidence unavailable | 2,104 | 5,324 |

Total: 59,320 scenario-states and 182,540 transitions, with ten reachable outcome
witnesses. The model starts with one captured source and two sequence positions;
boundary establishment, DATA, GAP, local admission/rejection/exclusion/failure,
unmatch, later excluded association/traffic, silence, deadline, reader close and caller
wake interleave. An explicit disposition vector checks separate protocol-accounting
and local-pending masks. Previously terminal outcomes are immutable.

Five negative controls fail as intended:

* Protocol-only completion returns OK after receipt of both DATA items while both
  remain pending local processing.
* A GAP erasing local work returns OK with received DATA still unprocessed.
* Unconditional unmatch success reports OK even before boundary establishment.
* Unconditional unmatch failure reports ERROR despite complete protocol accounting
  and safely retained local processing that can finish without the source.
* Silence-based success reports OK without any boundary or transfer evidence.

No policy change was needed. Normal recorded rejection can complete processing,
whereas an internal failure resolves ERROR. GAP completion does not imply payload
receipt. A finite no-evidence wait can time out; an infinite one can remain pending
while reader/source remain live. Every unresolved state has a reader-close terminal
path, which is not a guarantee of eventual success or scheduler fairness.

The model assumes atomic source capture and a valid fixed boundary H=2 once known.
It does not parse or validate heartbeats/GAPs, model empty-source polling, multiple
source aggregation, fragment assembly, range scaling, actual rematch identity reuse,
coherent staging, timer registration, memory ownership or a concrete provider's
best-effort completion signal. The new-association event is intentionally excluded;
it does not prove generation-safe implementation. Wire provenance and the full
composition with receive/admission and runtime models require integration tests.

The operation's directional decisions are consolidated. Next return to the remaining
L5 read/write/lifecycle result mappings; production receive-path fixes remain the
separate roadmap task rather than a prerequisite to finishing the concurrency spec.
