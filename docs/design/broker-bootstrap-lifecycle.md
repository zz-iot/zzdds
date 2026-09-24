# Bootstrap sizing and endpoint lifecycle

Domain identity revision (2026-09-18): the accepted [standard domain identity decision](broker-domain-identity.md)
replaces broker realm with RTPS domain ID/tag. The experimental schema/fixtures now use the standard string representation.
Earlier realm-specific prose remains superseded; this is not a wire freeze.

Status: current SPDP-service W4 reconciliation, 2026-09-18. This replaces the retired
HELLO/CHALLENGE/OPEN sizing and lifecycle recommendations. The service sequence and
bounded introduction record are accepted; the exact size/deadline constraints below
are the resulting proposed implementation contract. No production transport measurement.

## Current encoded sizes

The generated-code fixture measures complete Frames, including encapsulation/padding,
but excluding RTPS, transport and security overhead. Each registration advertises two
endpoint pairs; PATH uses a 64-byte cookie. These are structural measurements, not
semantically authorized participants or a selected cookie cryptographic format.

| Domain-tag bytes (excluding NUL) | Selected features | Resume | REGISTER | ACCEPT | PATH_CHALLENGE / RESPONSE |
| --- | --- | --- | --- | --- | --- |
| 8 | 2 | No | 380 | 476 | 192 |
| 256 | 128 | Yes | 1240 | 1336 | 192 |

The current rejection fixture is 144 bytes including Frame. Native SPDP introductions
are not Frames: their total depends on the complete canonical participant payload,
directed inline context and RTPS/protection overhead. Do not use the small structural
SPDP golden fixture as an estimate of a real participant announcement.

A 1200-byte UDP payload budget cannot carry the larger ACCEPT even before wrappers.
Schema ceilings therefore do not guarantee an admissible exchange. Keep initial v1
bootstrap unfragmented, including directed SPDP service introductions; do not allocate
preadmission fragment reassembly state. Ordinary discovery retains its own policy.

Before sending, check the complete encoded message against the selected path budget.
For a UDP-payload ceiling, subtract RTPS and selected security overhead, not IP/UDP
headers a second time. TCP needs bounded sample/frame and input-buffer limits too,
but does not inherit UDP's datagram-size restriction. Neither transport may allocate
arbitrary schema maxima just because a peer supplied a length.

Client preflight covers its canonical SPDP plus directed request context, PATH_RESPONSE
when applicable, and actual REGISTER. Broker preflight covers PATH_CHALLENGE, canonical
SPDP plus offer context, and the selected ACCEPT **before committing admission**.
The client cannot know the broker's full SPDP size in advance. Broker inability to send
an offer can therefore appear as a bounded introduction timeout, not a guaranteed error
reply. Before path validation, aggregate anti-amplification limits apply in addition to
per-message size limits; server retransmission does not create new credit. Received-request
accounting and bounded provisional storage follow the
[path provider contract](broker-path-provider-contract.md).

No side may strip canonical SPDP fields, required features, domain-tag bytes, endpoint identity
or protection to force a fit. A client may omit an optional resume hint in a fresh attempt;
if it does, it must discard any assumption of accepted downstream resume. Compatible
feature selection may omit unneeded optional features. Do not silently change the
participant-wide capability advertisement for a single recipient. If a required exchange
still cannot fit, report a local size/configuration failure or bounded REGISTER rejection
where available. Do not silently fragment, switch transports or weaken security. Explicit
TCP configuration or a larger supported path budget remain deployment choices.

## Establishment ordering

1. Client reserves local endpoint identities and bounded attempt buffers; endpoints are
   not generally discoverable through native SEDP. REGISTER advertises CONTROL/STATE pairs after validated SPDP introduction.
2. Broker validates REGISTER and its live introduction, reserves session/endpoints/history/result capacity,
   and commits the admission atomically. Partial resource failure leaves no live session.
3. ACCEPT travels on the bootstrap binding. Broker installs incoming session validation
   but does not initiate established output before receipt confirmation.
4. Client validates ACCEPT, installs both endpoint mappings, then sends an established
   control request, normally ORIGIN_BEGIN or VIEW_REQUEST. Broker processes this valid
   control message as confirmation of receipt; it is not a separate lease renewal.
5. Established reliability and protocol work proceed. CONTROL/STATE remain independent;
   early state records may use bounded orphan staging once session identity is validated.
   They do not confirm ACCEPT by themselves. Reserve needed ACK/output state, and queue
   it until control confirmation rather than bypassing the establishment rule.
6. Unconfirmed establishment expires without indefinitely retaining endpoints or history.
   Fence work first, publish required withdrawal if any, retire attempts/results under
   their own bounds, and free actual storage after transport/runtime references complete.

A client should submit confirming control before state traffic, but delivery can reorder.
If early state cannot be retained within the preconfirmation budget, fail/degrade that
session rather than ACK-and-forget application-required records. The protocol needs no
new confirmation opcode or round trip. Native RTPS acknowledgments carry endpoint IDs,
not the broker Envelope: endpoint identities and channel/path checks must prevent an old
ACK from mutating replacement stream state. Endpoint reuse cannot rely on a guessed
network packet lifetime; use fresh identities or a demonstrated equivalent protection.

## Deadline relationships

Each owner uses its monotonic clock. Wire durations are finite bounds, not foreign
clock timestamps; duplicate traffic never restarts a timer.

| Deadline | Starts | Expiry effect |
| --- | --- | --- |
| UDP path-cookie validity | Broker challenge issue | Cookie can no longer validate a response or recreate introduction state |
| Validated introduction lifetime | Broker reserves introduction, before sending offer | Unconsumed introduction cannot admit REGISTER; no effect on independently learned direct discovery |
| Admission-result retry window | Broker atomically commits outcome | Result may cease to be replayable; unknown/retired introduction never reconstructs a session |
| Unconfirmed establishment | Broker admission commit | Retire session if no valid confirming control arrived |
| UDP consumed-cookie retention | Successful validation, covering all equivalent issued cookies still usable | Retire only after cookie validity and related reply/runtime obligations end |
| Client attempt/startup deadline | Client's original local attempt/startup start | Stop that attempt/wait; late replies and backoff cannot reset it |
| Origin lease | Broker challenge-send time for valid origin proof | Withdraw registration on expiry; introduction, ACCEPT and retransmission are not origin freshness |

Introduction expiry is an **admission** cutoff, not a second session lease. If REGISTER
consumed a live introduction before expiry, a duplicate may replay its retained outcome
until the outcome's own deadline, subject to the session still being usable. Keep that
consumed result separate from an offered record; an offer's expiry must not erase a still
promised admission result. Reserve this capacity before consuming the introduction.

Use admission_retry_window <= establishment_timeout. Revocation, disconnect, close or
replacement can invalidate cached success sooner. Result retention never authorizes
restoring the session. After result retirement, an old REGISTER requires a fresh SPDP
introduction; its old ID cannot be reconstructed from request bytes. No lifetime identity
blacklist is needed. Storage with outstanding transport/runtime references retires only
after those references complete, even after its protocol deadline has passed.

For UDP, introduction retirement does not make a still-valid consumed cookie reusable.
Keep the cookie-to-introduction correlation, or an equivalent consumed marker, until all
associated cookies expire; after the introduction is gone, a duplicate response must not
allocate a replacement. A fresh SPDP attempt can obtain a new cookie/introduction within
normal quotas. TCP/protected paths need no such cookie guard, but retain introduction-ID
nonreuse and outcome rules. A binding/path change requires the appropriate fresh validation.

ACCEPT durations do not reveal how much broker-local time remains. The client retains
its first REGISTER send time and original startup/retry bounds, sends confirming control
promptly, and does not begin a fresh full establishment interval at ACCEPT receipt. The
broker independently enforces its absolute deadline. Conservative client timeout can
occasionally abandon an otherwise live admission; finite establishment cleanup resolves
that case. Delayed ACCEPT must never revive an abandoned attempt.

All preadmission phases also have finite local deadlines and capacity/rate bounds.
Exhaustion may cause silence; readiness and failure policy must tolerate it. Numerical
defaults require realistic RTT/scheduling and provider measurements, not merely positive
durations. Timing out a broker attempt does not disable local matching or independent
discovery under allow-degraded startup.

## Evidence and remaining implementation gates

The 20-test codec suite checks current registration/reply golden bytes, hash framing and
size profiles. The obsolete HELLO/OPEN sizing test was removed; the retired-OPEN rejection fixture
remains explicitly historical. Independent
Python encoders verify 49 vectors across registration, service, origin and earlier wire
fixtures. This is no evidence of real network MTU, cryptography or endpoint retirement.

Implementation must test: duplicate REGISTER across introduction expiry; result retirement
followed by stale REGISTER; late ACCEPT after client abandonment; consumed-cookie replay
after introduction reclamation; admission failure before ACCEPT capacity/size reservation;
and confirmation exactly at the establishment deadline using a single ordered decision.
These are production acceptance traces, not claims of an implemented state machine.
Cookie provider, recipient-specific SPDP inline context, protected-message overhead,
and runtime/socket integration remain explicit gates before wire freeze.
