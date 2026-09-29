> Historical source snapshot, superseded by the consolidated contracts.
> Unaccepted alternatives and old completion statements below are not current policy.

# View request correlation and recovery

Status: accepted draft-3 view correlation, 2026-09-28. [Archived alternatives](../review-baseline/broker-view-correlation.md)
record the former cross-stream reasoning. Ordered STATE removes pre-BEGIN orphan staging;
client-assigned generations still distinguish abandoned/replaced requests and recovery.

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
client stages only its current requested generation. In revised STATE ordering,
RECORD/DELTA cannot precede their applicable BEGIN/baseline. Older generations are ignored; unsolicited future generations are rejected without
allocating orphan state. BEGIN still validates the aggregate declared limits before
installation, and preconfirmation traffic still consumes its independent bounded budget.

## Resume and broker-initiated invalidation

ACCEPT selects snapshot versus resume eligibility, but does not start streaming a view.
The client sends VIEW_REQUEST after installing the accepted mapping. This also supplies
an established control message confirming receipt of ACCEPT. The cursor in that request
identifies the old baseline; view_generation identifies the new exchange. These fields
have deliberately different roles even if their numeric values happen to match.

Resolve resume against the retained previous epoch/session/owner generation/view
generation/cut, scope, policy and contiguous history. Unknown identity requires snapshot
fallback; neither a matching cut alone nor a cursor assertion reconstructs missing state.
No transaction digest is carried. On accepted resume, keep the verified snapshot cut
and delivery-sequence position, and emit subsequent delivery/VIEW_SYNC under the new session-local generation.
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
* Record for request 2 arrives before BEGIN 2: reject the invalid STATE sequence; do not
  create orphan staging. This supersedes the earlier cross-stream staging proposal.
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
