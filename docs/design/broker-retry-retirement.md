# Bounded admission and freshness retirement

Status: draft-3 contract, 2026-09-28. Fully retired registrations may be forgotten.

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

## Aggregate freshness: reliable delivery and bounded result lifetime

Draft 3 uses one outstanding FRESHNESS_QUERY nonce per session/view, not query serials
or chunk slots. Submit each logical query once to the reliable CONTROL stream. RTPS
retransmission retains the same writer sequence and payload; ordered ingress admits it
once. Freshness has no application-level same-nonce resubmission on a new RTPS sequence.
The client abandons a timed-out query and uses a new nonce for its next rate-limited query.
It must never reuse a nonce within a session. This narrows “retry” in the aggregate
contract to transport repair, preserving the original t0 and immutable result bytes.

Server ingress records its admitted CONTROL sequence before dispatching capture work.
Reserve bounded capture/result/STATE-output capacity first. An admitted query owns one
immutable result until transfer into reliable STATE history; normal ACK/retirement frees
that history. Replacement queries may find that budget occupied and receive LIMIT; one
outstanding client query is not permission for unlimited retained server answers.
A superseded/expired query cannot regenerate a different result through RTPS repair.
A stream whose sequence/repair state has been lost must recover the session, not recreate
admissions from arbitrary delayed samples. No unbounded retired-nonce table is needed.

Known duplicate logical nonce misuse is a protocol error, but validity does not depend
on remembering every old nonce forever: a conforming client only accepts its currently
outstanding nonce, consumes it once, and never moves t0 on a retry. A malicious client
cannot obtain stronger authentication or access by choosing a nonce; rate and allocation
bounds apply independently. A newer view/session rejects all older result associations.

## Required implementation traces

* REGISTER result retires before its cookie: old REGISTER/PATH_RESPONSE cannot reexecute.
* Cookie guard retires after expiry: absent introduction/token cannot reconstruct state.
* Capacity full: refusal before admission, no overflow allocation or lost guard.
* Same CONTROL writer sequence repaired twice: capture is admitted once.
* First query times out while its result remains retained: new query may get LIMIT;
  the old result cannot satisfy the new nonce or extend the old deadline.
* ACK releases result storage; later stream repair cannot admit the old sequence again.
* Session replacement fences queued capture, output and close work.

The historical `probes/broker_retry_retirement.py` serial/chunk model is archived evidence,
not validation of aggregate query admission. Current bounded freshness models check nonce
consumption and stale-session results; concrete RTPS ingress/history integration remains
a release gate. [Bootstrap lifecycle](broker-bootstrap-lifecycle.md) controls the separate
introduction/result/cookie horizons.
