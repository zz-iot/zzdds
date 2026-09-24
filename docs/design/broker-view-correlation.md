# View request correlation and recovery

Status: F2 direction accepted, 2026-09-18. ViewRequest member 4 now carries the
client-assigned generation in the experimental IDL; the wire remains unfrozen. Builds on the [operation table](broker-operation-validation.md).

## Problem

The current VIEW_REQUEST contains mode and optional resume cursor, but replies identify
only a view_generation chosen elsewhere. The client cannot reliably attribute an early
state-stream record to a replacement request before its control-stream BEGIN arrives.
One outstanding request reduces concurrency but does not itself distinguish a delayed
reply from an abandoned request. The envelope's request_id is a logical message identity;
using it implicitly as a transaction identifier for all records would change its meaning.

Separately, a client can receive and RTPS-acknowledge a snapshot record, then fail to
retain its application staging. It must explicitly abandon that view; ordinary RTPS
repair cannot recover data whose delivery was already acknowledged.

## Options

1. Keep the existing fields and serialize whole view exchanges. Resolve an outstanding
   request before starting another, or reconnect when its outcome is uncertain. This
   minimizes wire changes but turns local snapshot failure into potentially expensive
   session recovery and a fresh origin upload. It still needs precise association and
   control-processing rules; a single-flight label alone is not sufficient.
2. Add a request identity echoed in response boundaries, retaining broker-assigned view
   generations. This preserves separate request and view concepts. However, early state
   records need that identity too or must remain unattributed bounded orphans until a
   boundary arrives. Multiple identifiers must stay consistent across every response.
3. Let the client allocate the session-local view generation in VIEW_REQUEST. Existing
   view-bearing replies echo it. This provides correlation even before BEGIN and uses
   the generation already present throughout snapshot/delta/presence messages. It changes
   generation ownership, so broker-initiated replacement and resume need explicit rules.

## Accepted initial design: option 3

ViewRequest has a required, nonzero u64 view_generation. The client starts at 1 and
increments it for each new logical request within an admitted session, including requests
for resume. Never wrap; recover with a fresh session if exhausted. Identical retries keep
both generation and request_id and exact request bytes. Session fencing scopes the counter;
this number is not a security credential or a store revision.

Maintain one desired view per session. A new generation supersedes older work; it does
not allocate another independently active subscription. The client retires its previous
staging before requesting the successor. The broker validates authorization and reserves
replacement resources before adopting the new request, then invalidates the old stream.
If it cannot admit replacement, return a correlated ERROR and leave the client unready;
the client must not silently resume a view it already abandoned. Any retained prior
installed records follow existing freshness and authorization rules, not staging lifetime.

The broker tracks the highest valid request generation and an outcome for the current
request. An older request cannot create new work. Same generation with different content
or request_id is a conflict. A newer valid request may skip numbers; monotonicity rather
than contiguity is required. Record failed/retired generations boundedly using high-water
state so forgetting a result does not make its request executable again. Within the same
generation, retransmission never selects a new snapshot cut or resets deadlines. If the
original response/history is no longer available, invalidate it and require a new generation.

All view-bearing output uses the generation supplied by its triggering request. The
client stages only its current requested generation, including RECORD/DELTA that precede
BEGIN. Older generations are ignored; unsolicited future generations are rejected without
allocating orphan state. BEGIN still validates the aggregate declared limits before
installation, and early items still consume the negotiated orphan budget.

## Resume and broker-initiated invalidation

ACCEPT selects snapshot versus resume eligibility, but does not start streaming a view.
The client sends VIEW_REQUEST after installing the accepted mapping. This also supplies
an established control message confirming receipt of ACCEPT. The cursor in that request
identifies the old baseline; view_generation identifies the new exchange. These fields
have deliberately different roles even if their numeric values happen to match.

On accepted resume, keep the old verified snapshot cut/digest and delivery-sequence
position, and emit subsequent delivery/VIEW_SYNC under the new session-local generation.
Remap retained history consistently rather than requiring old serialized envelopes to
remain reusable. Snapshot fallback establishes sequence zero and a new snapshot baseline.
Readiness still requires fresh presence evidence and the fixed synchronization target;
resume does not refresh leases. This does not change fresh origin inventory on admission.

The broker does not invent a successor generation on interest/policy change or history
loss. It invalidates the current generation with RESYNC_REQUIRED, and the client requests
a newer one. Authorization revocation takes effect immediately at the broker: it must
not wait for the client to request another view before stopping forbidden disclosure.
The client must apply any required authorization withdrawal locally as specified by the
security/view policy; old cached records are not a reason to continue unauthorized use.

## Client-detected failure

Allow RESYNC_REQUIRED in both directions on the reliable control stream, using its
existing view_generation, reason and retry_after_ns fields. Do not overload a generic
ERROR with implicit view identity. C→broker means “I have abandoned this view; release
its work.” Broker→C means “this view is no longer usable; request a replacement.”
Neither direction creates a successor implicitly, and neither solicits a RESYNC reply.

A client that discards acknowledged staging marks that generation invalid and unready,
sends RESYNC_REQUIRED with retry_after_ns zero, then sends a newer VIEW_REQUEST after
its local backoff. Broker reception of the newer request also invalidates the old view,
so progress does not require a separate acknowledgment of invalidation. Ordered control
handling and generation checks protect both paths. Broker-originated retry hints retain
the existing bounded, non-deadline-extending semantics. Reasons use a restricted subset of the existing error registry: MALFORMED for invalid
assembly, UNSUPPORTED for required view semantics, LIMIT for staging/history capacity,
TRANSACTION_EXPIRED for timeout, CURSOR_UNAVAILABLE for lost baseline/history,
UNAUTHORIZED for disclosure-policy invalidation, and BACKEND_FAILURE for processing
failure. All other reasons reject. The receiver independently checks authorization and
legal recovery: a reason is not permission to renew or redisclose. UNAUTHORIZED and
UNSUPPORTED have zero retry hint; repeat only after a relevant policy/capability change.
All client-originated retry hints are zero. Malformed or uncorrelated invalidations do
not elicit another RESYNC_REQUIRED.

Late invalidations and APPLIED messages for old generations cannot affect a successor.
The broker may release old view repair history only after marking that view invalid;
it must not discard still-required delivery history while pretending the stream remains
valid. If the control path cannot deliver recovery, session failure remains the fallback.

## Cost and compatibility

The proposed wire change is one required ViewRequest member; existing view-bearing
messages already carry the correlation value. No extra round trip is required. A broker
must maintain a view-request high-water mark, and retained resume history needs rebinding
to the new generation. Independent arbitrary view subscriptions and broker-created view
generations are not supported by this initial model.

The wire is still unfrozen; this is now its baseline behavior.
It does not need a feature bit for compatibility with a deployed protocol that does not
yet exist. The IDL, registry, phase table and resume rules are updated together; generated-code
roundtrip checks establish encoding only, not implemented peer compatibility.

## Accepted trace expectations

* Request 1 is abandoned; its BEGIN arrives after request 2: ignore generation 1.
* Record for request 2 arrives before BEGIN 2: stage boundedly as request 2, not unknown work.
* Duplicate request 2 arrives after its snapshot cut was chosen: same result, no new cut.
* Conflicting request 2 arrives: reject; no replacement under an old generation.
* Client drops RTPS-acknowledged staging: invalidate 2, request 3; no expectation of repair for 2.
* Delayed RESYNC_REQUIRED/APPLIED 2 arrives after 3: no effect on 3.
* Resume old generation/cursor into a new session: rebind output to the new request,
  preserve valid baseline/delivery position, require fresh presence.
* Authorization changes mid-transfer: stop forbidden output immediately, invalidate view,
  rebuild only under current policy.

F2 is resolved at the contract level. These trace expectations still need executable
state-machine coverage; codec roundtrips do not establish asynchronous ordering safety.
