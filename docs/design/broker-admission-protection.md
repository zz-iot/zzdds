# Broker admission, identity and reconnect

Status: reconciled with the accepted unsecured identity correction and reconnect
policy, 2026-09-17. Supersedes the earlier stable claim-secret proposal. Exact transcript
bytes remain draft; no authentication implementation or security conformance is claimed.

## Identity and protection are separate

Unsecured discovery uses the participant GUID as its identity. No participant ownership
secret or permanent ownership registry is required. GUID uniqueness is not a claim of
resistance to malicious impersonation. Incarnation and session/generation fields remain
protocol bookkeeping for lifetimes and stale work, not application credentials.

Where DDS Security authenticates participants, use its configured Authentication and
Access Control plugins, including their participant GUID and permissions results.
For certificate-based authentication this includes the handshake proving private-key
possession, not just receiving a certificate. A certificate can serve multiple participant
instances; matching certificate subjects alone is insufficient to establish continuity of
a particular live participant. See [DDS Security 1.2 §§9.3.2.11 and 10.3](https://www.omg.org/spec/DDS-SECURITY/1.2/PDF).

A broker authenticating a participant itself must participate in the appropriate security
exchanges. An opaque broker forwarding peer authentication cannot infer that it has
itself authenticated either participant. Native peer authentication, permissions and
protected discovery remain mandatory wherever configured. Cached plaintext discovery
must not be substituted for secure peer discovery.

TLS/DTLS can separately protect access to the broker service, including before DDS
Security is implemented. Such service authentication does not automatically establish
DDS participant identity. Require the deployment's configured protections and scope
permissions on every admission; never downgrade to unsecured operation on failure.
An unsecured DDS participant may still use a protected broker transport.

Use maintained protection providers. On protected associations, do not process broker
messages as early data; TLS 1.3 early data lacks inherent replay protection. Require
DTLS replay detection and retain application-level duplicate/session checks.
[TLS 1.3 §8](https://www.rfc-editor.org/rfc/rfc8446.html#section-8),
[DTLS 1.3 §3.4](https://www.rfc-editor.org/rfc/rfc9147.html#section-3.4).
Validated migration within a surviving DTLS association is not a new admission. A
connection ID alone does not validate a new return path; use provider-supported
[DTLS return-routability checks](https://www.rfc-editor.org/rfc/rfc9853.html) where available.
In unsecured UDP mode, validated source paths provide reachability, not authentication.

## Registration and competing connections

Serialize admission by (scope, participant GUID), not merely GUID plus incarnation:
a different incarnation must not bypass a live duplicate-GUID conflict. A registration
binds its incarnation, fresh session/generation, endpoint offers and transport association
(or UDP socket lifetime plus validated remote path). Treat an admitted but unconfirmed
session as occupying the registration until its finite establishment deadline expires.

* If the old registration has closed or expired, admit a new attempt under current
  deployment policy. No proof of historical ownership is required for unsecured use.
* If the old registration is still live, reject a competing attempt unless an available
  authentication integration explicitly establishes continuity of that same participant
  and authorizes replacement. A shared broker login, copied GUID, certificate alone or
  client assertion does not establish this result.
* When authenticated replacement is supported, reserve all resources first, atomically
  fence the previous session, then commit the new session. Failed admission leaves the
  old registration unchanged. Do not add a mandatory custom credential to enable this.
* An integration that cannot establish continuity uses the same wait-for-close/expiry
  path as unsecured discovery. Initial v1 need not implement secure live replacement.

Use [ADMISSION_REJECT](broker-bootstrap-rejection.md) for a correlatable bootstrap
conflict once reply/path/authorization checks permit it. Use OWNER_CONFLICT without
revealing incumbent details. Silence remains permitted under resource or response-budget
limits. Retry backoff never extends the client's original startup/wait deadline.

On confirmed TCP closure, explicit unregister, or a detected session failure, promptly
withdraw the registration and its endpoint records and fence its pending work. Silent
TCP failure and UDP disappearance require the configured finite failure/lease deadline.
Socket closure affects only registrations actually bound to that socket lifetime. A
path migration in the surviving validated session is not a disconnect. Removal must
propagate to observers; their existing fresh-presence bounds handle undelivered withdrawal.

Broker withdrawal does not destroy the local participant, create native user-topic
DISPOSE events, or invalidate independently supported discovery paths. Reconnecting the
same still-live participant retains its local GUID/incarnation and revision counters but
uploads fresh inventory. Once withdrawn, old inventory cannot become visible merely
because admission or downstream resume succeeds. Fresh inventory and proof are required.

Explicit participant CLOSE permanently invalidates that registration and all work derived
from its session; disconnect/expiry likewise fence old session traffic without deleting
the local participant. Retain closed-registration state only while session/result/replay,
withdrawal or runtime-reference obligations require it. Once fully retired, forget the
registration and permit a fresh admission using the same identity under current policy.
Old packets cannot create this admission. No epoch-long identity ban or automatic
misbehavior/incompatibility blacklist is required in v1. Rate limits, quotas, retry backoff
and configured authorization remain independent requirements.

## Lost ACCEPT and stale work

Identical REGISTER on the same binding within its retry window returns the recorded ACCEPT
without a new owner generation or lease extension. Conflicting reuse rejects. A new
binding uses a fresh attempt and endpoint offers. If the old registration still exists,
the conflict rule above applies even when the client never received its ACCEPT. It can
retry after the old binding closes or its establishment/failure deadline expires.

This deliberately trades immediate unsecured takeover for bounded recovery delay. Normal
lease activity from the old valid session may keep a genuine competing registration
alive indefinitely; the competing client's own startup/wait timeout still applies.
Rejected attempts and duplicate REGISTER never extend the old deadline.

Revocation, replacement, expiry and terminal close override cached success: an obsolete
ACCEPT must not be replayed as a live result. Reserve outcome resources before publishing
admission. After outcome eviction, prevent reexecution of its attempt through association
retirement or bounded challenge-expiry/replay state. Avoid unlimited attempt tombstones.

Every asynchronous close, timeout, commit, send completion and cleanup action carries
the session/generation it belongs to. In particular, an old connection's delayed close
must not remove a newly registered participant with the same GUID. Cleanup compares the
current registration token before withdrawing it. Established incoming packets validate
session/epoch/generation before any state effect; retired sessions cannot recreate records.
A delayed bootstrap request is handled by attempt/challenge validation, not that envelope.

REGISTER has no continuity credential. ACCEPT.continuity_credential is absent in v1.
Its draft member ID is reserved for a future negotiated extension; nonempty values
cannot authorize replacement and must be rejected as unsupported. No client-generated
claim secret, broker token rotation or lost-token recovery protocol is required.

## Exact introduction and registration correlation

The [current registry](broker-wire-registry.md#spdp-service-revision-2026-09-18) defines
all active digest inputs. Client/server SPDP hashes include the original encapsulated
payload; the path hash additionally binds inline representation and exact request value.
ACCEPT.transcript_binding uses the register/v1 domain, introduction ID and exact REGISTER
Frame.body (including DHEADER, excluding outer encapsulation/frame padding). The retired
hello/v1 and admission/v1 transcript algorithms are not active protocol alternatives.

Retain exact bounded bytes, including unknown optional fields; decoded reserialization
cannot establish identical-request correlation. Validate required/unique members and
body bounds before extracting identity or using hashes. The retained introduction binds
both SPDP samples, immutable standard domain scope, selected logical broker participant,
client identity/incarnation, service/path and configured security context. Scope and both
service participant identities must agree with the per-scope service contract.

The client checks ACCEPT selections, limits, endpoints and deadlines independently of
hash equality. Hashes correlate bytes; they are not authentication, ownership secrets or
portable authority on a different binding. Altered REGISTER bytes against one consumed
introduction are conflicting reuse, not an identical retry. No hash includes ACCEPT itself.

UDP cookies bind service identity/epoch, current return path, attempt/nonce, request digest
and finite expiry through a reviewed protection provider. They grant return reachability
only. TCP and already validated protected paths omit this exchange. Never use advertised
locators as authority for the return destination or allow a valid cookie to recreate a
retired introduction. Keep consumed-cookie protection until all associated cookies expire.

## Validation and remaining work

The [admission trace review](broker-admission-traces.md) checks loss, competing admission,
closure, expiry and delayed cleanup against these rules. This is a specification review,
not an executable transport/security test. Implementation requires strict parser checks,
bounded outcome retirement, provider integration and loss/reordering tests. Authentication
providers must explicitly document whether they can establish participant continuity;
transport authentication alone must not silently enable replacement.

The accepted [retry-retirement rules](broker-retry-retirement.md) require consumed-attempt
guards through challenge expiry, reserved before side effects. After full expiry a fresh
introduction may admit reused participant identity; an old REGISTER cannot execute
against an absent/retired introduction ID.

## Concrete path-provider baseline

The [path provider contract](broker-path-provider-contract.md) specifies bounded pending
SPDP storage, a proposed 32-byte stateful cookie within the existing 64-byte wire ceiling,
atomic consumption, expiry and protected-association requirements. A cookie is not a
stateless substitute for retaining the original announcement. Provider validation remains
an implementation gate.
