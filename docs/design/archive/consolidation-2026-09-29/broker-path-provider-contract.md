> Historical source snapshot, superseded by the consolidated contracts.
> Unaccepted alternatives and old completion statements below are not current policy.

# Broker path validation and protection provider contract

Proposed v1 implementation baseline, 2026-09-24. This resolves the provider boundary
without changing message layouts or adding public configuration methods. Integration,
entropy/provider review and abuse tests remain required before claiming deployment support.

## Plain UDP: bounded pending challenges

PATH_RESPONSE echoes challenge data, not the original client SPDP. A request digest cannot
recover that sample. Consequently the current exchange is not a stateless bootstrap:
reserve a bounded pending-challenge record before sending PATH_CHALLENGE. Retain the
original client sample and request context (or the validated descriptor plus exact hashes
and bytes required by the introduction contract), source identity, selected scope/service,
observed path, attempt/nonce, request digest and absolute expiry. This is provisional
storage only: no participant installation, SEDP association or reliable history.

Use explicit global byte/count bounds plus per-path bounds and issue/verification rate
limits. Apply length/framing checks before copying. Exhaustion drops new work without
allocating overflow state or evicting consumed guards. Reserving a pending record does
not promise eventual admission. If an unconsumed record is evicted, its cookie immediately
becomes invalid and a late response receives silence; the client retries within its
existing attempt/startup policy. Prefer expiry over eviction when capacity permits.

The initial provider uses a **32-byte cryptographically random opaque cookie**, generated
by a maintained platform/provider CSPRNG, with collision detection among retained records.
Fail closed on entropy failure. The wire remains nonempty opaque octets bounded at 64;
clients echo exactly and neither interpret nor require the server's 32-byte choice.
The value identifies a pending record and is accepted only on its bound path. It does
not encode identity, scope or timestamps; those reside in bounded server state. Never
log the token or use a predictable table index as its replacement.

No custom MAC/encryption format is needed for this stateful provider. Cookie-key rotation
therefore does not apply. A future authenticated self-contained cookie provider may use
the same opaque wire field, but must meet all these binding/consumption rules and specify
its own reviewed key rotation and overlap bounds; it cannot recover absent SPDP content
from a digest or remove the need for consumed-attempt state. It is not an alternate v1
implementation requirement.

## Binding, expiry and consumption

The record binds the current broker epoch, logical service participant and domain scope;
local socket/listener generation and destination address/port; observed remote address/
port (including address family and relevant IPv6 interface scope); client identity,
attempt/nonce and exact service-path digest. Normalize addresses consistently. Advertised
locators cannot replace the observed return destination. Restart/socket replacement
invalidates pending records; persistent restore is not part of v1.

1. A duplicate identical SPDP request on the same binding returns the existing challenge
   subject to response budgets, with the same cookie and original expiry. Changed content
   under a live attempt/nonce does not overwrite the retained request.
2. On PATH_RESPONSE, check strict framing and echoed fields, opaque token, live record,
   path and absolute deadline. Lookup never creates missing state. At `now >= expiry`
   validation fails. Invalid/unknown/expired responses produce bounded silence.
3. Reserve the validated introduction, reply capacity and consumed-cookie guard before
   atomically changing pending to consumed. Concurrent responses must produce at most one
   introduction. Allocation failure leaves no partially published introduction; a pending
   request may retry before its unchanged expiry.
4. A consumed response may replay its same retained offer while that introduction remains
   usable. It cannot create a new introduction, extend any deadline, renew origin presence
   or revive a retired result/session. After introduction retirement it receives silence.
5. Retain the guard until cookie expiry and outstanding reply/runtime references finish.
   This provider issues only one cookie per retained challenge. Any future provider that
   issues equivalent cookies must cover all of their acceptance horizons with its guard.

Expiry uses the broker's monotonic clock, starts at initial issue and has a finite,
configured maximum. Clients need no shared clock or cookie expiry field. Numeric timeout
and capacity defaults are deployment/build choices to validate against realistic RTTs;
this does not leave their finiteness, start point or non-extension behavior optional.
A lost pending record requires another challenge. Fresh cookies never make old tokens
valid again. Close and restart must fence outstanding asynchronous validation work.

## Reflection and admission abuse

Before return validation, permit only a bounded challenge response to an eligible directed
SPDP request. The proposed plain-UDP limit is **at most 1:1 UDP-payload response bytes to
eligible received request bytes**, counting complete RTPS messages. Charge sends, including
retries, to bounded per-path and global budgets; multiple requests in one datagram cannot
each claim its entire byte length. Invalid PATH_RESPONSE contributes no credit. Server
retransmission creates no credit. If a challenge cannot fit the available budget, remain
silent; do not pad requests automatically or fragment bootstrap messages.

New received retransmissions may supply new byte credit, but never reset absolute expiry
or global/per-path rate limits. This is a zzdds policy, not a claimed RTPS requirement.
Provider handshake traffic also needs its provider's own prevalidation limits. Where it
shares a socket, account for that traffic explicitly rather than assuming broker limits
cover it. Limit both output bandwidth and parser/verification work.

A cookie makes off-path spoofed-source admission harder; it does not stop a reachable
attacker, authenticate a participant, prove endpoint reachability or authorize domain
access. Global storage bounds remain mandatory even if source addresses are varied.
After validation, introduction/session quotas, finite deadlines and service authorization
still apply. No identity blacklist or permanent ownership record is introduced.

## Connected paths and future security integration

The internal provider supplies a generation-fenced association/path handle, current
return-path validation and bounded send overhead. TCP supplies return reachability on
that connection; UDP uses the challenge above. Neither authenticates the participant.
V1 supports traditional insecure cached discovery and has no mandatory TLS/DTLS provider.

Future DDS Security integration adds distinct authentication, permissions and protection
results, not one `secure` boolean. It must protect the vendor endpoints explicitly and
validate UDP return reachability before expensive security work. No plaintext fallback.
Broker messages cannot bypass required authentication via ordinary SPDP endpoint matching.
No authenticated support may be advertised before actual UDP and TCP integration tests.

Skip PATH only with evidence for the current return path. A connection ID or an
authenticated packet from a new address alone is insufficient. If validated migration
is unsupported, use fresh association/introduction. Closure/revocation fences bound work;
key updates cannot erase replay guards or silently change authorization. Optional transport
security is later scope and must document its own early-data/replay/migration behavior.
See [security and filtering](broker-security-and-filtering.md).

## Acceptance evidence required

Test concurrent duplicate consumption; unknown/altered token and every changed binding
field; exact expiry; lost challenge/offer; early pending eviction; replay after introduction
retirement; restart/socket-generation replacement; allocation failure at each reservation;
CSPRNG failure/collision handling; and byte/rate accounting under repeated/spoofed traffic.
Verify retained memory remains bounded when sources vary. For later secure support, additionally test revoked protection, unvalidated migration,
handshake overhead and missing-security-support failures.

Existing codec vectors demonstrate the opaque field's capacity, not these properties.
The 64-byte-cookie sizing fixture is a ceiling exercise and stays valid even though the
proposed stateful provider emits 32 bytes. This document changes no schema or golden bytes.
