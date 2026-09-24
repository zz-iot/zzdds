# Presence proof completeness during view churn

Status: F3 accepted and incorporated in experimental IDL, 2026-09-18.
Wire remains unfrozen; codec evidence is not state-machine validation.
The [presence contract](discovery-broker.md#8-presence-liveliness-and-freshness) already
requires nonce correlation and conservative observer deadlines. This document addresses
what a complete answer means, rather than changing that freshness algorithm.

## Distinguish delivery completeness from fresh membership

Receiving every numbered chunk proves delivery of a particular answer. It does not prove
that an omitted participant was deleted, nor that participants introduced afterward have
fresh evidence. Discovery membership comes from the installed snapshot/delta stream;
presence evidence can activate only records authorized by that installed view.

Do not make READY depend on every participant in a continuously moving graph acquiring
new proof simultaneously. Use the fixed synchronization target already in the readiness
contract. Subsequent additions need their own evidence but do not move that target.
Ordinary remote expiry is not itself a failure of an otherwise synchronized client.

## Alternatives

* Treat a full-view query as an evolving list, letting later chunks incorporate newer
  participants and lease renewals. This minimizes snapshotting but makes duplicate chunks,
  empty replies and completion ambiguous. It can keep moving the completion target.
* Capture a finite answer at one view-stream frontier, then transmit immutable chunks.
  This makes retries and completion precise, at the cost of bounded retained proof data.
* Only allow explicit participant subsets. This simplifies membership accounting and
  bounds individual answers naturally, but removes the existing full-view optimization
  and requires more client-side batching for large views.

Use the second approach, with explicit subsets retained as the scalable fallback.

## Proposed answer boundary

PresenceProof member 6 is view_delivery_seq. It identifies a committed prefix of this view's
snapshot-plus-delta stream, not an unrelated global store cut. The snapshot baseline is
sequence zero; accepted resume uses its retained sequence space. All chunks for a nonce
share this frontier. Choose a frontier whose membership the broker can identify under
current authorization; queue later membership changes after that boundary. Do not claim
that merely allocated or partially committed deltas constitute the frontier.

At answer construction, capture a finite set of requested participants visible at that
frontier and the corresponding origin freshness/deadline evidence. Calculate remaining
lease at that capture time. Do not refresh remaining durations while serializing later
chunks or retrying. This may conservatively expire slow replies, which is safe. Do not
include identities whose disclosure is no longer authorized, even if an older retained
frontier would include them. If authorization changes during output, cancel the answer
and invalidate/rebuild the view rather than continue disclosing an obsolete captured set.

The client may retain early proof chunks within its staging budget but cannot interpret
the answer as membership-complete until its installed view reaches the answer frontier.
A proof cannot install an endpoint or create view membership. Later withdrawals, lease
reductions, incarnation changes and authorization restrictions override captured proof.
The existing incarnation/freshness-generation guards still apply.

## Explicit negative evidence

For an explicit subset, return exactly one result for each distinct requested participant
identity: either current positive freshness evidence or an explicit unavailable result.
For full-view queries, return exactly one result for each participant in the authorized
membership at the reported frontier, including currently unavailable participants still
represented in that prefix. Absent identities outside that frontier are not asserted dead.

PresenceEntry carries a required availability discriminator: AVAILABLE = 1 or
UNAVAILABLE = 2. Zero and unknown values reject. Positive entries carry
freshness generation and finite positive remaining lease. Unavailable entries carry zero
remaining lease and zero freshness generation; zero is an absence marker, not a freshness
generation that may override existing evidence. Available entries require a nonzero
freshness generation. They mean only “this answer provides no usable fresh
evidence.” They do not authorize withdrawal, revoke existing independent evidence or
prove the participant was destroyed. Do not expose why an unauthorized identity is absent.

The receiver must not discard an existing, still-valid proof merely because a different
query reports unavailable. Explicit discovery removal/lease-reduction and local expiry
remain the ways to shorten validity. New records with unavailable evidence stay inactive.
A fixed synchronization target is accounted for when each participant is either validly
proved, withdrawn by installed discovery changes, or explicitly evaluated as unavailable
and left inactive. Availability is not a promise of remote reachability or writer liveliness.
This clarifies READY as a synchronized, freshly evaluated view, not a guarantee that every
cached participant is active. This is the accepted READY interpretation.

## Bounded assembly and query lifetime

ReceiveLimits now includes maximum_presence_queries, maximum_presence_entries,
maximum_presence_bytes and maximum_presence_chunks. These bound outstanding queries,
identities per answer, total encoded proof-body bytes (including repeated chunk headers),
and chunks respectively; per-chunk IDL capacity alone is insufficient. Charge immutable
answers and client assembly against per-session and service limits before promising
completion. Counts/byte arithmetic must be checked before allocation. Full-view answers
that cannot fit fail with correlated LIMIT; the client may use bounded explicit subsets
without changing the fixed synchronization target. Failure is not an empty success.

For empty full-view membership, send one chunk with index zero, count one and no entries.
There is no zero-chunk success inferred from silence. Otherwise chunks are indexed
0..count-1, with deterministic participant-identity ordering and no duplicate identities
across chunks. All chunks agree on nonce, view generation, frontier and chunk count.
Subset completeness compares identities to the retained request; full-view completeness
compares them to the installed membership at the frontier (or retained bounded membership
information if the client has already advanced). Do not require unbounded historical
reconstruction: if that membership cannot be checked, fail the query and retry a current
bounded subset instead of guessing completeness.

An identical duplicate chunk does not refresh time or add capacity credit. Conflicting
chunks invalidate the whole answer. The observer records one local send time and finite
deadline per nonce; retransmissions keep both. Preserve t0 + remaining_lease, including
clock-tolerance adjustments, rather than receive_time + remaining_lease. A replay cannot
refresh proof. A new query uses a new nonce and may observe new origin renewals.

Discarding acknowledged proof chunks requires query-level recovery with a new nonce;
RTPS repair cannot retrieve application-discarded state. On broker result expiry, return
correlated TRANSACTION_EXPIRED rather than reconstruct different chunks under the same
nonce. Discard late chunks from retired nonces/generations. A failed presence query alone
does not require uploading origin inventory or rebuilding a valid discovery baseline.

## Required trace cases

* Empty view: one explicit empty chunk, no wait for a nonexistent participant.
* Participant added after captured frontier: not missing from the answer; later query
  gates its activation without extending the earlier synchronization target.
* Participant removed after capture: installed withdrawal wins over delayed positive proof.
* Lease renewal while chunks are sent: existing answer stays immutable; new nonce can
  obtain the renewal evidence.
* One subset member unavailable: explicit inactive result, no fabricated removal.
* Full reply exceeds negotiated budget: LIMIT, then bounded subset queries; no silent truncation.
* Last chunk lost: query remains incomplete; retries preserve its original deadline.
* Client advances beyond frontier and cannot verify old full membership: retry current
  subsets, not unbounded retention or optimistic completeness.

The follow-up implementation will need strict field/aggregate validation and executable
fake-clock/churn tests. The contract resolves F3; asynchronous fake-clock/churn tests remain implementation
work, not evidence supplied by serialization tests.


## Limit negotiation and completion details

All four limits are positive and bounded by local policy; choose effective session limits
no greater than the client offer or broker capacity. Do not enlarge a client offer in
ACCEPT. maximum_presence_entries is an aggregate answer bound; the per-chunk schema
ceiling remains 256 and explicit query subsets also have a 256-identity schema ceiling.
maximum_presence_chunks must accommodate the chosen partitioning within byte limits;
each actual Frame must separately fit the negotiated frame budget. A valid full-view
answer may exceed one chunk, but never any aggregate limit. Broker local/global budgets
may still refuse work with LIMIT. A client falls back to subsets sized to all applicable
bounds, rather than assuming the schema ceiling is an affordable allocation.

Reserve a bounded identity set for the fixed readiness target. Subset batches may observe
different newer frontiers but must account for that fixed set; unrelated additions do
not extend it. Each result must still match the currently installed incarnation and view.
Unavailable results count as evaluated only from a complete valid answer received before
its original query deadline. They are not retained as reusable negative lease evidence.
A positive result whose conservative deadline has already elapsed cannot activate state;
leave the participant inactive. A fully validated timely answer still accounts for its
identity without inventing freshness. Incomplete/timed-out answers do not establish
completeness, even if some chunks individually contained usable positive evidence.

Discard duplicate chunks without recharging their retained storage; compare their exact
contents. Current query retries reuse an immutable retained answer. Once retired, a nonce
must not be reconstructed as a different answer; its bounded replay/outcome retention
implementation remains part of checklist W3, not an unbounded result-cache requirement.

[Retry retirement](broker-retry-retirement.md) now supplies query_serial in both query
and proof. Admit new serials in reliable control-stream order before parallel answer
work. Retired serials cannot reconstruct answers; active slots may complete out of order.
Nonce freshness correlation remains mandatory and is not replaced by the serial.
