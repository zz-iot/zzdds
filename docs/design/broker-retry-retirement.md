# Bounded admission and presence retry retirement

Status: accepted retry-retirement direction, 2026-09-18. Experimental IDL now
includes PresenceQuery member 5 and PresenceProof member 7 for query_serial. Preserves the
accepted rule that fully retired registrations can be forgotten without identity bans.

## Admission: introduction consumption and independent replay horizons

An unconsumed introduction admits REGISTER only before its fixed expiry and on its
validated binding. Atomic consumption reserves session/result capacity before effects.
Same exact REGISTER against a consumed introduction follows its retained outcome and
session-validity rules, not the old unconsumed-introduction deadline. It never allocates
a second session, advances owner generation or renews a lease. Conflicting reuse fails.

After the result's retry deadline, an old REGISTER cannot execute again: an absent or
retired introduction ID never reconstructs admission. Results may retire only after their
promised window and dependent runtime references permit it. Logical invalidation precedes
physical reclamation. Introduction IDs are epoch-separated and not reused; no permanent
participant-GUID blacklist is required. A revoked session cannot replay usable success.

For UDP, a still-valid path cookie can outlive the introduction/result. Reserve a bounded
consumed-cookie-to-introduction correlation before issuing the first offer. Duplicates
repeat that same offer while valid, or reject/drop after it retires; they cannot create
another introduction. Keep the correlation or a consumed marker through all applicable
cookie expiries, regardless of introduction storage pressure. Capacity refusal precedes
promising success. TCP/protected paths do not require a cookie guard, but the introduction
and outcome rules still apply. Duplicate traffic never extends any deadline.

Fresh SPDP attempts after retirement may obtain fresh introduction IDs under normal
policy. They cannot make old REGISTER bytes valid. Detailed timer origins, endpoint
confirmation and resource retirement follow the [lifecycle contract](broker-bootstrap-lifecycle.md).
The earlier cookie-authorized OPEN experiment is historical, not the current handshake.

## Presence: ordered query serial plus bounded active answers

Use a positive session-local query_serial in PRESENCE_QUERY and echo it
in every PRESENCE_PROOF. Keep the random nonce for the existing freshness correlation;
the serial supplies compact request ordering. No new acknowledgment operation is needed.

The reliable control stream is already ordered. Process query admission serially in its
session context, before dispatching expensive answer construction. The client allocates
increasing serials when submitting new queries to that stream, starting at 1. It may
skip values but never wrap. Retries retain serial, nonce, request_id and exact body.
Multiple admitted queries may compute/complete out of order within the negotiated cap.

Server state consists of highest_seen_serial and at most maximum_presence_queries active
query/result slots. On receipt:

1. If a slot exists for this serial, verify exact request identity/content. Return the
   same immutable answer, or retain the in-progress operation, without resetting deadlines.
   Conflicting reuse fails and never replaces the original slot.
2. If no slot exists and serial <= highest_seen_serial, the query is stale. Return bounded
   correlated TRANSACTION_EXPIRED or drop under the response policy; never reconstruct it.
3. Otherwise advance highest_seen_serial before dispatch. Reserve a slot and answer budget;
   if resources/policy refuse it, return correlated failure and leave no executable gap.
   Retry after failure uses a new serial and nonce, not the rejected query.

Because no lower new serial can arrive later on the ordered control stream, one high-water
number protects retired requests even when answers finish out of order. This would not
be valid if query admission were moved to the unordered peer/data path, or if worker
completion order were mistaken for control-stream admission order. Keep that invariant
explicit. Future transports must preserve it or negotiate a different window protocol.

Slots have finite fixed server retention deadlines. The client retains its own original
send time and query deadline; no cross-host absolute timestamp comparison is needed.
A client timeout retires that query locally. Late chunks cannot be attached to a newer
query merely because the view or participant set matches. A server retaining a timed-out
client query temporarily costs bounded capacity, not indefinite work. If capacity remains
occupied, new queries may receive LIMIT until expiry; apply backoff. An explicit query
release/ack could optimize this later, but is not required for correctness.

Client proof acceptance matches session, view, serial and nonce, then the existing chunk,
frontier, identity and deadline checks. A new serial with an old nonce is invalid client
behavior; implementations must generate a new nonce for every new logical query. Zero
and overflow are invalid; serial exhaustion requires fresh-session recovery. Existing
maximum_presence_queries bounds retained slots, not a promise that every new query can
be admitted while completed results remain within their retention windows.

## Alternatives and cost

Keeping only random nonces requires a retired-nonce set or session retirement whenever
safe replay retention fills. A sliding serial window supports unordered arrival, but adds
gap/window state unnecessary on the current control stream. The recommended high-water
scheme costs two u64 wire fields (one in each message type), a counter and bounded slots.
Consumed-cookie retirement itself adds no extra field beyond the accepted introduction protocol; its cost is bounded guard storage and
potential admission/query refusal under load. Neither is an identity blacklist.

## Trace expectations before implementation

* REGISTER succeeds, result bytes expire, original cookie remains valid: neither stale REGISTER nor PATH_RESPONSE can reexecute admission.
* Guard reclaimed after all cookies expire: stale REGISTER fails on absent introduction; stale PATH_RESPONSE fails cookie validity.
* Quota full: no successful admission without a reserved guard.
* Query 1 computes slowly; query 2 completes first: both remain independently valid slots.
* Query 2 slot retires; its duplicate arrives while query 1 remains: high-water rejects 2.
* Query 3 denied for capacity; retried unchanged after capacity frees: still rejected;
  a new query 4 is eligible.
* Reply to timed-out query arrives during a newer query: serial/nonce mismatch prevents reuse.

The bounded abstract model in probes/broker_retry_retirement.py predates the current
SPDP introduction protocol. It supplies evidence for ordered query retirement and the
older consumed-cookie abstraction, not execution of the current REGISTER/introduction
state machine or all traces above. Current introduction/result/cookie horizons are
specified in the lifecycle contract; implementation needs new transition tests for them.
