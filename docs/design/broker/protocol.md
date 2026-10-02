# Broker: protocol

Requirements use the [shared convention](../concurrency-broker-status.md#requirement-convention).
[The index](../concurrency-broker-status.md) owns scope and unresolved design items;
[the evidence inventory](../probes/README.md) records validation.

Transport obligations precede establishment and admission. Inventory/view synchronization,
leases/freshness, retention and the operation table define the established session.
The overview defines identities; the wire contract owns encoding and assignments.

## Transport and channel requirements

For UDP, bind the local channel before sending the directed SPDP service request. Reply
through the same socket/path, using the contacted service address as the reply source.
Wildcard-bound services must preserve the received destination address for replies or
reject that configuration. Address-family compatibility is not return-path validation.
Bind sessions to validated remote tuples and transport/channel lifetimes. One UDP socket
may carry several sessions; receiving on it does not authenticate any of them. A changed
tuple requires path validation, with at most bounded overlap with the old validated path.

Before validation, obey the introduction's bounded-state and at-most-1:1 response budget.
Bootstrap is unfragmented. Established samples may use bounded RTPS fragmentation; avoid
reliance on IP fragmentation. Respect the configured UDP payload budget, including all
protocol overhead, and support smaller limits/path-MTU adaptation. Bound aggregate and
per-session reassembly bytes, fragment counts, duplicate work and incomplete lifetimes.

UDP reliability must pace transmissions, use RTT-sensitive repair, cap in-flight bytes,
back off, and apply an aggregate congestion budget across all streams to a client.
Unlimited HEARTBEAT/NACK repair loops are not acceptable. Loss, blocked ICMP and delayed
ACKs must not cause unbounded traffic; fair repair must preserve healthy-session progress.

For TCP, the client initiates and the broker replies on that accepted connection through
Channel/sendOnChannel. Do not redial a NAT-translated source as a listening locator.
Disable reuse_connection_by_host for broker channels: equal NAT source IPs do not identify
a shared session or owner. Correlate admitted sessions and owner generations independently
of host identity; secure profiles additionally authenticate them.

Validate frame limits before allocation. Bound incomplete-frame time, send queues and
connect/write deadlines, with cancellation. A slow receiver must not block the discovery
store or other sessions. Cap STATE frame sizes to give CONTROL scheduling opportunities;
TCP byte-stream head-of-line blocking still applies. Separate priority connections are a
later negotiated capability. A reconnect requires admission/explicit resume before mutation;
a new connection generation does not establish graph consistency.

Use bounded shared ingress dispatch per service/transport registration, then demultiplex
sessions. Do not register one transport handler per session; the existing handler cap is
not a client-capacity mechanism. Close notifications must be correlated to retained
transport/channel/session identities. Ignore unknown or retired tokens; invalidate only
affected paths. TCP connection death, UDP socket death and remote lease expiry are distinct.
Deadlines detect stalls without waiting for an OS close indication. Identity retirement
must be bounded and safe against stale completions, not an unbounded socket graveyard.

The [runtime transport contract](../concurrency/runtime.md#transportruntime-ownership-and-backpressure)
owns ingress/output lifetime: not-accepted retains producer ownership, accepted output
pins immutable bytes through one terminal completion, and cancellation is not completion.
Local output completion, RTPS ACK, broker COMMIT and client APPLIED are distinct boundaries.
Output failure after store commit cannot turn a mutation into an uncommitted one.

<a id="spdp-based-broker-service-establishment"></a>
## SPDP-based broker service establishment

<a id="common-structure"></a>
### Common structure

Use ordinary SPDP participant information to introduce the client and configured broker.
A vendor parameter announces zzdds service roles, compatible versions and predefined
vendor service-introduction endpoints. A directed broker-service request parameter
identifies a client attempt/nonce and the requested service; treat it as relationship
context, never an alternate canonical participant capability record. Its exact parameter
The [wire contract](wire.md) defines provisional IDs, encoding and correlation hashes; cryptographic provider validation is a deployment gate.

Keep standard participant capabilities stable across recipients. Advertising support
never authorizes an association. Ordinary peers select SEDP; a configured broker service
relationship selects the vendor broker EDP and suppresses ordinary SEDP association on
that relationship. A broker service participant can consistently omit ordinary SEDP
endpoints. The configured service selects its logical participant with the client's domain ID/tag;
a mismatched offer or an unsolicited broker-capable peer is not selected
merely because it sends an advertisement. Bind service identity according to configuration
and any available authentication, not source address alone.

The introduction endpoint is best effort and bounded. It does not require ordinary SEDP
to discover itself, and receiving SPDP must not allocate full reliable broker streams or
publish a registered participant into the broker's distributed view. Keep provisional
introduction state separate from the admitted store. Capability-bearing advertisements
are parsed under strict size/CPU/rate limits before state allocation.

<a id="plain-udp-sequence"></a>
### Plain UDP sequence

1. Client sends directed SPDP to the configured broker service address using the bound
   local transport socket. Include normal participant capabilities and the vendor service
   request; continue separately configured multicast/direct-peer discovery independently.
2. Broker recognizes a supported service request. Before return validation, either send
   a compact challenge on the vendor introduction endpoint or drop within rate/budget
   limits. Do not respond with an arbitrarily larger full broker SPDP sample. Bind the
   challenge to the observed path, attempt, request content and expiry through a reviewed
   integrity mechanism; no admitted history/state allocation yet. Reserve bounded provisional
   request storage as specified in the [path provider contract](protocol.md#broker-path-validation-and-protection-provider-contract).
3. Client echoes the compact challenge in a service-validation message on that endpoint.
   Broker validates it, then returns its SPDP service advertisement on the validated
   path. The sender may cache only minimal provisional identification before this point.
4. Client sends REGISTER on the vendor introduction endpoint: exact service/version
   selection, scope/incarnation, requested limits/view/lease and proposed local control/
   state endpoint identities. Bind it to the validated attempt and both introductions.
5. Broker validates and reserves resources, checks identity conflict policy, and returns
   ACCEPT with session/generation, selected limits and broker endpoint identities. Retain
   bounded idempotent outcome/consumed-attempt protection before publishing admission.
6. Client installs the mappings and sends its first established control request. Then
   upload full origin participant/endpoint inventory, select downstream view and obtain
   freshness evidence using the existing contracts.

Steps 2–3 validate the path, not participant identity or origin liveliness. Exact anti-
amplification limits may require silence or an explicitly bounded retry, not a normal
large SPDP response. Because the broker advertisement is not yet known, the compact
challenge uses the agreed predefined introduction endpoint ID and correlates the directed
request. Its claimed GUID alone is not trusted authority. This is a zzdds extension
bootstrap carried over RTPS, not a claim of unmodified-SPDP challenge semantics.

This simple separation costs extra messages on plain UDP compared with an optimized
combined challenge/REGISTER exchange. It avoids carrying full offers twice and permits
transport-specific validation. Combining steps later is possible only if prevalidation
size and state bounds remain explicit; do not optimize round trips by quietly allocating
unbounded pending introductions.

<a id="tcp-sequence"></a>
### TCP sequence

1. Client opens the connection to the configured service and sends directed SPDP over
   that connection using existing RTPS/TCP framing. Apply connect/incomplete-frame bounds.
2. Broker replies with its SPDP service advertisement on the same accepted connection.
   TCP return reachability eliminates the UDP cookie exchange. It does not authenticate
   the participant or authorize the scope.
3. Client sends REGISTER, broker replies ACCEPT, and synchronization follows as above.

Do not redial locators from the client advertisement to deliver broker control traffic.
An established connection is the return path for this service association. Receiving
SPDP over TCP requires adapting current SPDP plumbing; the existing UDP-oriented listener
and initial-peer support do not establish that this sequence is already implemented.

<a id="coexistence-boundary"></a>
### Coexistence boundary

Separate ordinary initial peer addresses from broker-service addresses. Do not add
broker-introduced remote participants to ordinary SPDP/SEDP fan-out automatically.
Directly discovered peers follow configured normal discovery policy. Broker failure must
not erase independently valid direct discoveries. A peer appearing through both paths
needs shared identity with separately tracked provenance and freshness; authority/conflict
reconciliation follows the coexistence contract, not a last-packet-wins merge.

Broker configuration is a preset/collection of options, not a requirement for mutually
exclusive discovery. Internal adapters may remain modular. More than one configured
service address does not imply federation or multiple simultaneous authorities: preserve
v1's single-authority rule unless explicitly redesigned.

<a id="service-introduction-metadata-and-compact-registration"></a>
## Service introduction metadata and compact registration

<a id="separate-capability-directed-intent-and-registration"></a>
### Separate capability, directed intent and registration

| Object | Placement | Contents |
| --- | --- | --- |
| ServiceCapabilities | Vendor parameter in full canonical SPDP payload | Descriptor version; bounded service entries, each with service kind, client/server roles, supported protocol ranges/encodings and introduction writer/reader entity IDs |
| ServiceRequestContext | Vendor parameter in directed SPDP inline QoS | Descriptor version; service kind; random nonzero attempt ID and client nonce; scope comes from the canonical client SPDP payload |
| ServiceOfferContext | Vendor parameter in broker's directed SPDP reply inline QoS | Descriptor version; service kind; echoed attempt/nonce; fresh introduction ID; broker epoch; digests of client and server canonical introduction samples |
| PathChallenge / PathResponse | Samples on predefined vendor introduction endpoints | Attempt/nonce, digest of request context plus client sample, bounded opaque return-path cookie; response echoes the same challenge data |
| Register | Sample on introduction endpoint | Introduction ID, attempt/nonce, requested scope, origin incarnation, selected service/version/encoding/profile/features, receive limits, lease request, view mode, two local endpoint pairs and optional resume cursor |
| Accept | Sample on introduction endpoint | Introduction ID/attempt and registration digest; current epoch/session/generation, selected limits/features/profile/view, broker endpoint pairs, origin-inventory-required and optional downstream resume result |

Initial service kind is broker discovery. Future relay/connectivity services receive their
own descriptors and protocols; reserved capability names are not implemented endpoints.
ServiceCapabilities describe actual supported roles, not permission to connect. Scope
access is checked independently. Native standard built-in endpoint bits remain stable.

<a id="canonical-introduction-binding"></a>
### Canonical introduction binding

Digest the exact serialized SPDP sample bytes (including its encapsulation), not a decoded
projection. Keep the client sample chosen for the attempt immutable even if native SPDP
operational counters advance afterward. Registration binds that introduction; its subsequent
inventory may legitimately contain a newer committed participant version. Neither an old
introduction nor its sample hash can roll back the graph.

Use distinct hash domains for client sample, server sample, directed context and registration.
The offer reports the paired sample digests; the client validates them against the bounded
samples it retained. A changed offer requires a fresh introduction/attempt rather than
silently changing the interpretation of a retried Register. Exact domain strings and
encoding are specified in the [current registry](wire.md#spdp-service-revision)
and checked by independent fixtures. Hashes provide correlation,
not origin authentication. The configured binding/security policy supplies authority.

REGISTER carries an introduction ID instead of repeating full SPDP samples, a challenge,
or the complete capability lists. It selects a supported combination; the server checks
that selection against the retained introductions and current policy. Requested scope must
agree exactly with the introduced participant domain ID/tag. The selected broker
service participant has the same domain ID/tag, under the accepted
[multi-domain service arrangement](coexistence.md#multi-domain-broker-service-identities). Participant GUID comes
from the retained client sample; incarnation must agree with its origin-version metadata.
No second independent claimant GUID is necessary in Register.

<a id="bounded-validated-introduction-record"></a>
### Bounded validated introduction record

Maintain an ephemeral server introduction record after return-path validation, including
on TCP and already validated protected transports. It retains:

* service/binding/path generation, attempt/nonce and any authenticated principal;
* selected client/server introduction bytes or bounded validated descriptors plus exact
  digests, identity/version information and immutable offer bytes;
* fresh nonzero introduction ID, fixed expiry, state (offered/consumed/retired), and
  bounded admission result or consumed marker.

Reserve capacity before sending the offer; per-principal/path and global limits apply.
This is small bounded preadmission state after validation, not reliable stream/history or
registered discovery state. It replaces repeated large OPEN payloads with an explicit
memory-versus-bandwidth tradeoff. A reachable abusive client still needs rate limits and
quotas. Introduction ID is a lookup/correlation value, not a public ownership credential.
Never create a record in response to an unknown ID in REGISTER.

REGISTER atomically consumes the introduction. Same exact retry returns the same retained
result while valid; conflicting reuse fails. Unknown/expired IDs require a fresh introduction,
not reconstruction from the REGISTER. Keep IDs non-reusable within the relevant service
lifetime; use unpredictable identifiers with collision checking and epoch separation,
not a resettable small slot index that stale messages could reference. A replayed old
SPDP request after retirement may get a new introduction ID, but an old Register cannot
consume it. Clients only accept offers for their outstanding attempt on the intended binding.

This also supplies the missing cookie-free replay boundary for TCP/protected transports.
An admission result can retire after its bounded window and local references complete;
future Register against its absent introduction ID cannot execute. Negative outcomes consume
or retire the introduction too. Pressure must not resurrect a consumed introduction.
The random-ID nonreuse assumption and collision handling need explicit implementation tests.

Plain UDP still needs consumed path-challenge protection through cookie expiry. After a
valid path response, retain its correlation to the introduction so duplicates repeat the
same offer, not allocate more records. Expiry permits reclamation only after the old cookie
cannot recreate that introduction. TCP skips that path challenge entirely. A validated
UDP path change needs fresh validation; no reply destination comes from advertised locators.

<a id="limits-messages-and-lifecycle"></a>
### Limits, messages and lifecycle

This introduction removes the need for an unconditional application-level cookie and eliminates
full HELLO+CHALLENGE repetition. It does not prove messages fit every MTU: full SPDP may
contain many locators or vendor parameters. Directed introduction sample/context, server
reply and REGISTER each require encoded-size checks. Before validation the response budget
still forbids a larger full reply merely because it is SPDP. Do not silently strip canonical
origin fields to make the sample fit. The [current sizing contract](protocol.md#bootstrap-sizing-and-endpoint-lifecycle) requires unfragmented
bootstrap and explicit failure when the required exchange cannot fit.

Reliable CONTROL/STATE endpoint resources are reserved only when admitting REGISTER.
Local client endpoint pairs are proposed in REGISTER, not standard capability masks.
ACCEPT receipt confirmation and inventory/view/presence behavior retain the existing rules.
Scope authorization is checked before disclosing detailed broker service/claim information.
Local matching and independently configured ordinary discovery continue during any failure.

A failed introduction never becomes a distributed participant registration. Expiring one
must not remove an ordinary direct participant record learned independently from the same
GUID. Server SPDP lease expiry, admission timeout and registered broker presence remain
separate observations with explicit dependencies, not one shared timer.

<a id="broker-path-validation-and-protection-provider-contract"></a>
## Broker path validation and protection provider contract

<a id="plain-udp-bounded-pending-challenges"></a>
### Plain UDP: bounded pending challenges

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

<a id="binding-expiry-and-consumption"></a>
### Binding, expiry and consumption

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

<a id="reflection-and-admission-abuse"></a>
### Reflection and admission abuse

Before return validation, permit only a bounded challenge response to an eligible directed
SPDP request. The plain-UDP limit is **at most 1:1 UDP-payload response bytes to
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

<a id="connected-paths-and-future-security-integration"></a>
### Connected paths and future security integration

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
See [security and filtering](security-and-filtering.md#broker-security-profiles-and-disclosure).

<a id="bootstrap-sizing-and-endpoint-lifecycle"></a>
## Bootstrap sizing and endpoint lifecycle

<a id="current-encoded-sizes"></a>
### Whole-exchange preflight

The [evidence inventory](../probes/README.md) separates supported-v1
feature sizing from schema-ceiling stress fixtures. Measurements exclude RTPS/transport
wrappers; no fixture is a guarantee that canonical participant SPDP fits a deployment.

A 1200-byte UDP payload budget cannot carry every schema-ceiling ACCEPT even before wrappers.
Schema ceilings therefore do not guarantee an admissible exchange. Keep initial v1
bootstrap unfragmented, including directed SPDP service introductions; do not allocate
preadmission fragment reassembly state. Ordinary discovery retains its own policy.

At service enablement, preflight locally predictable bootstrap messages for each configured
scope/path: the broker's canonical SPDP/offer and maximum ACCEPT over the enabled, legal
feature/resume outcomes. Reject configurations whose required supported replies cannot fit
the chosen unfragmented budget, with an operator-visible size diagnostic. Reserve space
for configured wrapper overhead. This does not predict arbitrary remote client SPDP sizes.
At REGISTER, still preflight the exact selected ACCEPT before committing admission;
return bounded LIMIT/rejection when permitted, otherwise record the local failure and
allow the client's finite attempt timeout. Never install a session whose mandatory ACCEPT
is known to be unsendable. No silent feature stripping or transport switch.

The v1 selected feature set is drawn from IDs 1, 2 and 6, with 6 requiring 1. The 128-ID
stress case is not a legally selected v1 exchange; retain the bounded schema ceiling for
parsing/evolution tests rather than reducing it to an arbitrary value merely to fit a test.

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
[path provider contract](protocol.md#broker-path-validation-and-protection-provider-contract).

No side may strip canonical SPDP fields, required features, domain-tag bytes, endpoint identity
or protection to force a fit. A client may omit an optional resume hint in a fresh attempt;
if it does, it must discard any assumption of accepted downstream resume. Compatible
feature selection may omit unneeded optional features. Do not silently change the
participant-wide capability advertisement for a single recipient. If a required exchange
still cannot fit, report a local size/configuration failure or bounded REGISTER rejection
where available. Do not silently fragment, switch transports or weaken security. Explicit
TCP configuration or a larger supported path budget remain deployment choices.

<a id="establishment-ordering"></a>
### Establishment ordering

1. Client reserves local endpoint identities and bounded attempt buffers; endpoints are
   not generally discoverable through native SEDP. REGISTER advertises CONTROL/STATE pairs after validated SPDP introduction.
2. Broker validates REGISTER and its live introduction, reserves session/endpoints/history/result capacity,
   and commits the admission atomically. Partial resource failure leaves no live session.
3. ACCEPT travels on the bootstrap binding. Broker installs incoming session validation
   but does not initiate established output before receipt confirmation.
4. Client validates ACCEPT, installs both endpoint mappings, then sends an established
   control request, normally VIEW_REQUEST. ORIGIN_BEGIN is now STATE traffic and does not confirm ACCEPT. Broker processes this valid
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

<a id="deadline-relationships"></a>
### Deadline relationships

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

<a id="broker-admission-identity-and-reconnect"></a>
## Broker admission, identity and reconnect

<a id="registration-and-competing-connections"></a>
### Registration and competing connections

Serialize admission by (scope, participant GUID), not merely GUID plus incarnation:
a different incarnation must not bypass a live duplicate-GUID conflict. A registration
binds its incarnation, fresh session/generation, endpoint offers and transport association
(or UDP socket lifetime plus validated remote path). Treat an admitted but unconfirmed
session as occupying the registration until its finite establishment deadline expires.

* If the old registration has closed or expired, admit a new attempt under current
  deployment policy. No proof of historical ownership is required for unsecured use.
* In v1, if the old registration is still live, reject a competing attempt. In future
  secure integration, replacement requires an available
  authentication integration explicitly establishes continuity of that same participant
  and authorizes replacement. A shared broker login, copied GUID, certificate alone or
  client assertion does not establish this result.
* When authenticated replacement is supported, reserve all resources first, atomically
  fence the previous session, then commit the new session. Failed admission leaves the
  old registration unchanged. Do not add a mandatory custom credential to enable this.
* An integration that cannot establish continuity uses the same wait-for-close/expiry
  path as unsecured discovery. Initial v1 need not implement secure live replacement.

Use [ADMISSION_REJECT](protocol.md#bootstrap-rejection-reply) for a correlatable bootstrap
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

<a id="lost-accept-and-stale-work"></a>
### Lost ACCEPT and stale work

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
cannot authorize replacement and must be rejected as unsupported. No token authorizes replacement in v1. D2 schedules a client-requested, single-use
bearer continuity capability for v1.1; its rotation, binding and unresolved lost-reply
requirements are specified in [the scope contract](security-and-filtering.md#broker-security-profiles-and-disclosure).

<a id="admission-test-scenarios"></a>
### Admission test scenarios

Non-normative: concrete interleavings of the rules above, with the outcome each requires.
Executable broker tests cover each, including the callback/commit orderings. Each first
REGISTER presupposes a valid same-scope SPDP introduction. A registration token is
epoch/session/generation together; GUID alone is not a token.

| Scenario | Required result | Rule exercised |
| --- | --- | --- |
| REGISTER A accepted; ACCEPT lost; identical REGISTER A arrives on the same binding | Same recorded result, same generation, unchanged deadline | Retry cannot renew presence or allocate a second registration |
| ACCEPT lost; TCP closes; new binding submits REGISTER B | Withdraw A, admit B, fresh inventory/proof | The client needs nothing from the lost reply |
| ACCEPT lost; UDP peer silently disappears; REGISTER B arrives before A's deadline | Conflict; no replacement or deadline extension | B retries after A's finite establishment deadline; no silent takeover |
| Two initial REGISTER requests with the same GUID and different incarnations race | One succeeds; the other conflicts | Admission serializes by scope/GUID, so incarnation cannot bypass exclusion |
| Future secure integration: authenticated continuity permits B to replace live A | Reserve resources, fence A, install B atomically | Only B can commit afterwards; allocation failure leaves A intact |
| B has the same broker login or a copied certificate but no validated participant continuity | Conflict while A lives | Transport access is not replacement authority |
| A closes; B registers the same GUID; A's delayed close/timeout callback runs | B survives unchanged | Cleanup compares the registration token before withdrawal |
| A's queued mutation reaches the store after B replaces A | Reject A's stale token | No old-owner upsert into B's inventory |
| A expires; its delayed REGISTER arrives after the cached result was reclaimed | Reject the expired attempt/challenge or retired binding | Eviction cannot recreate a registration; a fresh attempt is required |
| A expires; fresh attempt B uses the same unsecured GUID/incarnation | Admit B under current deployment policy | No historical ownership reservation; fresh inventory/proof required |
| Participant CLOSE commits; the old session retries | Reject stale work or return the retained close result | No resurrection through old messages |
| Closed registration fully reclaimed; fresh admission uses the same identity | Admit under current policy with fresh session/inventory/proof | No epoch-long identity ban |
| Cached ACCEPT exists; authorization revoked or A superseded | No live success replay | A cached response does not bypass current validity |
| Rejected competing requests keep arriving | A's deadline unchanged | Rejection cannot keep a phantom owner alive |
| A legitimately remains live while B competes | A remains; B's caller deadline may expire | Bounded failure detection is not a promise to evict a healthy participant |
| A's registration is withdrawn while an observer is disconnected | Queue bounded withdrawal or invalidate the observer's view; freshness still expires | Reconnect cannot reactivate old records from a saved cursor |
| A new registration succeeds before its inventory commits | Not advertised as a complete participant graph | Admission is not READY or presence proof |

<a id="exact-introduction-and-registration-correlation"></a>
### Exact introduction and registration correlation

The [current registry](wire.md#spdp-service-revision) defines
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
only. TCP on the current connection omits this exchange; future protected paths require
explicit evidence of current return reachability before doing so. Never use advertised
locators as authority for the return destination or allow a valid cookie to recreate a
retired introduction. Keep consumed-cookie protection until all associated cookies expire.

<a id="bootstrap-rejection-reply"></a>
## Bootstrap rejection reply

<a id="fields-and-correlation"></a>
### Fields and correlation

Required fields: admission_attempt, client_nonce, rejected_operation (REGISTER=32),
reason (restricted below), retry_after_ns, request_digest. Attempt/nonce come
from the REGISTER being rejected. SPDP/path failures receive bounded silence in v1. No session, owner details, endpoints, credentials, diagnostic
strings or arbitrary reflected request bytes are returned.

request_digest is SHA-256 over ASCII `zzdds-broker/rejected-request/v1` plus one NUL,
u16 little-endian rejected operation, then u64 little-endian body length and the exact
triggering Frame.body bytes. It is correlation, not authentication. Validate uniqueness,
required fields and exact body bounds before trusting extracted request identifiers.
On the client, match an outstanding request's bytes, operation, attempt and nonce,
configured service, current binding and expected response path. Protected deployments
also require the authenticated association; never accept an unprotected rejection there.
Unsecured replies provide diagnostics, not protection against network impersonation.

<a id="reasons-and-retry-behavior"></a>
### Reasons and retry behavior

Use the existing numeric error registry, restricted to:

| Reason | Permitted request | Client behavior |
| --- | --- | --- |
| UNSUPPORTED | REGISTER | Stop this attempt; report incompatible version/feature/profile; no unchanged automatic retry |
| UNAUTHORIZED | REGISTER | Stop this attempt; require corrected credentials/policy before retry |
| OWNER_CONFLICT | REGISTER | Retry a fresh admission with backoff, within the caller's original deadline |
| LIMIT | REGISTER | Retry a fresh admission with backoff |
| BACKEND_FAILURE | REGISTER | Retry a fresh admission with backoff |
| TRANSACTION_EXPIRED | REGISTER | Restart admission with a fresh directed SPDP attempt and introduction |

All other codes reject the reply as invalid for this phase. retry_after_ns is zero for
UNSUPPORTED and UNAUTHORIZED. For retryable reasons, zero means no server hint, not
immediate spinning. A nonzero finite hint is a relative suggested delay; clamp it to
configured retry bounds, combine with local jitter/backoff, and never extend a caller's
absolute deadline. It does not promise when a competing participant will disappear.
No automatic retry changes the GUID or weakens security/required features.

A valid rejection ends this attempt. Duplicate rejected requests cannot later succeed
under that attempt; retain a bounded negative result or invalidate its introduction
so retry requires a fresh attempt. No rejection changes an existing participant's lease,
registration or readiness. An already accepted attempt is never turned into a rejected
operation because sending ACCEPT failed. Identical retries of a still-valid accepted
attempt replay ACCEPT. Once fenced/expired, an attempt may receive TRANSACTION_EXPIRED,
but this means its admission is no longer usable, not that it never succeeded.
An ACCEPT received before a delayed rejection makes the rejection irrelevant; no
bootstrap rejection can tear down an established session.

<a id="reply-eligibility-and-resource-limits"></a>
### Reply eligibility and resource limits

Malformed, uncorrelatable or incompatible fixed framing is silently dropped. Do not
answer a rejection with another rejection. Before disclosing OWNER_CONFLICT, validate
the source path and any configured scope authorization. Unauthorized callers must not
learn that a particular GUID is registered; use generic UNAUTHORIZED or silence.

Replies use the contacted service address and the request's channel/validated return
path, never request-supplied locators. Use non-fragmented best-effort bootstrap DATA.
No reliable endpoint/history is allocated just to reject a request. Bound output bytes,
rate, pending negative outcomes and work per path/principal and globally. Prior to path
validation, preserve the existing aggregate no-amplification budget: repeated requests
do not authorize unbounded cached reply retransmission. Include RTPS and protection
overhead in budgets. If the reply cannot fit the path/frame budget, or correlation,
authorization or rate checks fail, silence is valid. TCP uses the same bounded policy;
its existence is not scope authorization.

The baseline body is 120 bytes and its Frame is 144 bytes, excluding RTPS/transport/
security overhead; these sizes are checked by the current REGISTER rejection fixture, whose digest is
computed independently from the exact REGISTER body. The separate retired-OPEN fixture
remains historical and is not a valid current reply. Future
optional members must still fit the configured non-fragmented bootstrap budget. This
reply improves diagnosis where deliverable; it does not eliminate timeout-based failure
detection. Local activity remains available under allow-degraded startup.

<a id="origin-inventory-barrier-and-future-pipelining"></a>
## Origin inventory barrier and future pipelining

<a id="v1-admission-rule"></a>
### V1 admission rule

Capture an immutable inventory cut and close the client's mutation-send gate before
sending ORIGIN_BEGIN. Continue local endpoint activity; retain subsequent announcement
changes in bounded local pending state. Send the inventory records and ORIGIN_END, then
wait for the matching successful inventory COMMIT. Match session/owner generation,
inventory generation and the related inventory-completion request (ORIGIN_END). Only
that result opens the gate for post-cut MUTATE messages. RTPS ACK, local send completion,
ACCEPT, presence evidence, unrelated COMMIT and downstream READY targets cannot open it.

The broker accepts MUTATE only after the current session's inventory has committed and
while no replacement inventory is staging. Premature MUTATE is a protocol failure, not
implicit dependency staging: reject with an appropriate ERROR_MALFORMED / NEW_INVENTORY
recovery result, or fail the session if a safe correlated reply cannot be delivered.
No wire field needs to be added for this v1 rule. O in the operation table means this
current-session committed baseline, not retained inventory from an old connection.

A same-session replacement inventory also needs a boundary before its cut. Stop new
mutation submissions and resolve every previously transmitted mutation before sending
ORIGIN_BEGIN. Successful or definitively rejected outcomes suffice; an unknown outcome
does not. If the client cannot resolve outstanding work within its retry budget, recover
through a fresh session/inventory instead of letting delayed old mutations overlap a
replacement cut. Duplicate requests whose results remain retained never execute twice.
BEGIN now shares STATE ordering with records/mutations. Retain this outcome-drain rule
until replacement-result retirement is separately validated; transport order does not
prove whether an earlier application mutation committed.

Within one inventory generation, retry the same immutable cut/records/END and request
identities. Lost COMMIT is repaired through retained transaction results, without changing
origin revisions or recapturing that generation's cut. A rejection leaves the gate closed.
A fresh transaction or new session captures a new cut from authoritative local state.
Old-session results and delayed COMMIT from a superseded inventory cannot open the gate.
Same-session transaction failure/retirement must invalidate its staging before reuse;
new-session fencing is the fallback where the outcome cannot safely be established.

<a id="local-buffering-visibility-and-failure"></a>
### Local buffering, visibility and failure

Coalesce only unassigned announcement changes, preserving authoritative revisions and
required removals relative to the captured cut. An endpoint present in that cut and then
deleted needs a removal after commit. An endpoint created and deleted entirely after the
cut may need no announcement. Once a logical request/stream record is assigned, retain
its exact bytes for retry rather than silently rewriting it.

Charge pending bookkeeping to configured bounds. If it cannot represent the required
changes, fail/degrade synchronization and rebuild a fresh inventory using the recovery
rules; do not claim complete advertisement after dropping changes. Local entity creation
can still fail when its own resource reservation cannot be satisfied. The barrier does
not block local matching or data delivery and does not make local API success depend on
a broker round trip. It delays remote advertisement during registration or repair.

The broker may expose the committed cut before subsequent mutations arrive. This is
ordinary discovery lag, not atomic visibility of every local change made during upload.
The accepted fixed-target READY rule is unchanged: later pending changes are reported
separately, rather than extending the synchronization target indefinitely. Steady-state
mutations do not each wait on a new inventory barrier.

<a id="deferred-inventory-pipelining"></a>
### Deferred inventory pipelining

Keep the gate and pending-state ownership explicit in the client so a later policy can
release dependent mutations earlier. Keep the broker's inventory commit boundary explicit
so staged dependent work can be scheduled only after that boundary. These are design
seams, not a requirement to allocate inactive staging queues in v1 or embedded builds.

The follow-on must specify all of the following together:

* A negotiated feature with a minimum protocol version, plus a required dependency field
  on pipelined MUTATE identifying the exact inventory generation in the current session.
  Do not assign a feature number or advertise support before that contract is complete.
* The Envelope required_features entry and conditional required-member validation, so
  a v1 decoder cannot skip an optional field and accidentally apply work early. A new
  operation is also possible if it yields clearer compatibility; silent reinterpretation
  of current MUTATE is forbidden.
* Negotiated dependent-work item/byte limits and per-session/service quotas, deadlines,
  backpressure and failure replies. One valid dependency does not authorize unlimited
  precommit staging. Clients still retain sufficient retry state.
* Atomic release after inventory commit, deterministic revision ordering, and rejection
  of missing, failed, replaced or retired dependencies. In-flight work belonging to a
  previous inventory must not attach to its successor.
* Lost-result handling and a precise rule for pipelining across same-session replacement,
  including any required prior-mutation frontier. An inventory dependency alone does
  not solve the opposite boundary: old mutations racing a newer inventory cut.

Feature negotiation enables capability, not mandatory pipelining. A client may always
use the v1 COMMIT barrier; a peer without the extension uses it unchanged. No fallback
may transmit dependency-free early mutations. Measure registration/repair latency under
real RTT/churn before choosing default pipeline limits. Preserve identical committed
state, freshness and READY semantics for both execution policies.

## Origin inventory identity and recovery

Allow one active inventory per owner generation, with monotonically increasing inventory
generation on each record/boundary. Replacement inventory is authoritative at its cut:
remove omitted endpoints while retaining required revision high-water marks. Interrupted
staging expires without altering the last valid committed inventory. Initial activation
requires fresh origin proof; old expired inventory stays withdrawn. Inventory must not
reopen a closed participant. The inventory COMMIT barrier orders post-cut mutations.

Retain exact bytes/revisions for retries; a lost COMMIT does not cause a revision bump.
Fence old-owner commits against replacement under the same store commit ordering. A
commit before fencing can enter repair history; one after fencing cannot mutate the store.
After result retention expires, use revision/high-water state only when it establishes
the outcome; otherwise require inventory repair, never guess or replay side effects.
CLOSE is idempotent for its fenced registration. Recovery never requires recreating a
locally deleted endpoint to repair the graph.

## Snapshot installation and bounded convergence

Serialize accepted mutations within each scope. Capture a view at store cut C and buffer
applicable later changes while sending its ordered snapshot. END carries the fixed
ready-through target; validate exact assembly and dependencies before installation.
Stage and reconcile the old and replacement views in one serialized discovery commit,
then publish dependency-ordered matching/status work. Budget preparatory reconciliation
across turns; partial staging is not visible as a complete view. Identical retained
GUID/revision records must not generate artificial lost/found cycles.

The snapshot baseline is delivery sequence zero; post-cut deltas start at one and
use contiguous per-view delivery_seq. A gap blocks installation until
repair or replacement. APPLIED acknowledges an installed prefix, not receipt or staging;
listener completion is not required before APPLIED. Logical application is idempotent,
not exactly-once network delivery or simultaneous visibility across observers.

Bound snapshot/delta buffering in bytes and time. When churn outruns an attempt, send
RESYNC_REQUIRED, cancel staging and retry with backoff. Exhausting the configured retry
budget reports capacity failure rather than retrying forever. Reject views that exceed
negotiated limits and never report READY for a partial view.

<a id="view-request-correlation-and-recovery"></a>
## View request correlation and recovery

<a id="current-view-requests-and-retained-baseline-resume"></a>
### Current-view requests and retained-baseline resume

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

<a id="resume-and-broker-initiated-invalidation"></a>
### Resume and broker-initiated invalidation

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

<a id="client-detected-failure"></a>
### Client-detected failure

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

## Origin lease renewal

Origin registration renewals come from the participant discovery agent, not an independent
socket reader that could remain responsive while participant processing is stalled. The
broker issues a nonce challenge with a server-monotonic deadline. A timely valid proof
establishes an origin deadline no later than challenge-send time plus the negotiated lease;
duplicates do not extend it. Negotiate renewal margin for RTT and scheduling. TCP ACKs,
old SPDP bytes, replayed endpoint records and successful view resume never renew registration.

The negotiated cached-origin lease must not exceed a finite participant lease advertised
in preserved SPDP. A shorter advertised lease caps the existing broker deadline immediately
when the participant update commits. Infinite broker registration leases are rejected in v1,
even if another discovery mechanism supports infinite participant leases. Reject timer
combinations that cannot accommodate configured RTT/deadline margins. A snapshot grants no
fresh presence: activation requires corresponding unexpired proof and authorized installed
records. Native presence and writer liveliness remain separate authorities.


<a id="ordered-aggregate-freshness-revision"></a>
## Ordered aggregate freshness

<a id="state-ordering"></a>
### STATE ordering

Place ORIGIN_BEGIN/RECORD/END, MUTATE, SNAPSHOT_BEGIN/RECORD/END, DELTA, VIEW_SYNC and
freshness markers on the relevant reliable ordered STATE direction. CONTROL carries
requests, COMMIT/REJECT, origin lease traffic, errors and close. Application effects follow
STATE order, not merely RTPS receive order. Bootstrap confirmation still requires valid
established CONTROL, normally VIEW_REQUEST; ORIGIN_BEGIN no longer serves as that control
confirmation. Client submits confirming control before state; cross-stream preconfirmation
staging remains bounded and must not become ACK-and-forget.

Keep fresh inventory and its COMMIT barrier before post-cut mutations. Same-session
replacement can exploit STATE ordering but cannot assume previously failed/unknown outcomes
succeeded; define transaction retirement before relaxing its existing drain rule. Ordering
removes record-before-BEGIN staging within STATE, not all staging between STATE and CONTROL.

<a id="query-and-marker"></a>
### Query and marker

One outstanding nonce per observer session/view. Record local monotonic t0 at first send;
transport repairs retain it. Submit the logical query once; application timeout starts
a new nonce, as specified by [retry retirement](protocol.md#bounded-admission-and-freshness-retirement). Broker captures membership/freshness against an exact committed view
frontier, applies expiry evaluation using actual deadlines, and orders required withdrawals
before its marker. A scheduled but unprocessed expiration cannot receive fresh validity.
Build marker M(nonce, view_generation, frontier, H, exceptions) from immutable capture data.
A client applies it only after the covered STATE prefix is installed. It grants nothing to
later members or different incarnations. Failed/abandoned/old-session queries confer nothing.

H is a common remaining-lease horizon for non-exceptions, not a lower bound over exceptions.
Each exception names an origin incarnation and its remaining duration; zero grants no new
validity. Positive evidence extends an existing compatible deadline using max-merge. Expiry,
withdrawal, lease reduction and authorization revocation can invalidate evidence; a marker
cannot reverse already-applied authoritative changes.

Bound exceptions by negotiated Xmax AND encoded byte budget. Choose the largest useful H
not exceeding the configured target whose below-H origins fit both bounds; lower H when
necessary, including to zero. Never silently omit a required exception. If identity size
or other bounds prevent representation, use a safe lower horizon or explicit query failure.
No marker chunking. Empty views have an explicit correlated marker. An applied marker
accounts for the fixed readiness cut; zero evidence leaves unproved members inactive.

Compute conservative observer durations using the documented relative clock-rate tolerance;
define epsilon >= 0 such that broker clock rate / observer clock rate <= 1+epsilon
throughout the exchange and granted interval. Use c = 1/(1+epsilon), rounding duration
down, and deadlines t0 + c*remaining. This is a deployment clock-rate assumption, not
synchronized epochs. A platform unable to uphold it must invalidate grants across the
unaccounted interval (including suspend) or provide a suitable elapsed-time clock. Do not use
arrival time or refresh immutable durations on retransmission. Validate the clock assumption
and arithmetic; comparable monotonic epochs are not required. Consume the nonce on first
application. Duplicate responses cannot extend it. Marker bytes remain owned through normal
reliability obligations; at most one logical query does not mean zero retained output.

<a id="reductions-and-failure-semantics"></a>
### Reductions and failure semantics

A reduction decided before capture is reflected in ordered preceding state and evidence.
A later reduction is ordered after the marker and caps validity WHEN APPLIED. It cannot
retroactively shorten an observer's previously granted deadline before reaching that observer.
A stalled stream therefore expires under the earlier granted bound. Do not claim instant
revocation or that every observer deadline is always below a subsequently shortened broker
lease. This limitation also applies to delayed authorization notifications; prevent new
unauthorized disclosure immediately at the broker's output boundary.

Fresh sessions need fresh nonces even when resuming a view. Retained membership is not new
freshness. STATE backpressure prevents marker application and conservatively expires
records; independent CONTROL capacity must permit recovery. No control keepalive grants
freshness by itself.

<a id="cadence-and-scale"></a>
### Cadence and scale

A suggested initial default schedules refresh before expiry, targeting roughly half of
the common horizon, with finite minimum interval, bounded jitter and one outstanding query.
Account for short exception deadlines separately where useful. Rate limits take precedence
over endless immediate retry when H is tiny/zero. If the horizon is insufficient, conservative
expiry—including healthy origins sharing a reduced horizon—is an explicit consequence.
New membership may trigger an earlier rate-limited query. Neither one-period activation nor
READY latency is guaranteed without delivery/progress and capacity assumptions.

With N observers, exception cap K and actual query rates f_i, marker egress is bounded by
sum_i f_i * (fixed_marker_bytes + K*exception_bytes), plus discovery traffic and retransmits.
A shrinking horizon can increase f_i only to the configured cap. Healthy common-case cost
can approach O(N) per common refresh period; correlated failures do not justify an unbounded
exception list or query storm.

Naive capture scans cost O(sum_i f_i * view_size_i), even with compact output. Index shared
origin deadlines and view membership to reduce repeated work where worthwhile; charge
snapshots/indexing and bound reconciliation turns. Do not claim CPU scaling from egress
scaling. Benchmark steady state, one failing origin, correlated renewals, view churn and
restart separately. Exact capacities/cadence require implementation measurement.

<a id="bounded-admission-and-freshness-retirement"></a>
## Bounded admission and freshness retirement

<a id="admission-introduction-consumption-and-independent-replay-horizons"></a>
### Admission: introduction consumption and independent replay horizons

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
confirmation and resource retirement follow the [lifecycle contract](protocol.md#bootstrap-sizing-and-endpoint-lifecycle).
The earlier cookie-authorized OPEN experiment is historical, not the current handshake.

<a id="aggregate-freshness-reliable-delivery-and-bounded-result-lifetime"></a>
### Aggregate freshness: reliable delivery and bounded result lifetime

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

<a id="bounded-protocol-retention-and-reclamation"></a>
## Bounded protocol retention and reclamation

<a id="reclamation-inventory"></a>
### Reclamation inventory

These rules describe the accepted retirement structure; the compact-replay mechanisms
below still require concrete implementation contracts.
“Invalidate” means making all later lookups fail admission before freeing state; outstanding
local references may still require deferred memory release under the runtime contract.

| Retained state | Why retained | Safe retirement / pressure response |
| --- | --- | --- |
| Validated introduction, UDP cookie and REGISTER result | Return the same outcome; reject expired/replayed admission | Invalidate the attempt's admission capability before evicting its outcome. Expired challenges never execute; a surviving still-valid challenge needs negative/high-water state or retirement of its binding. Pressure refuses new work, never silently converts a duplicate into new admission. |
| Current registration/session | Fence mutations and cleanup to one owner | Remove from active lookup atomically, invalidate its queues/tasks and retain only necessary result/withdrawal dependencies. Unknown established sessions reject without allocating a replacement. Fresh session identity cannot reuse a still-referenced token. |
| Closed-registration result | Answer duplicate CLOSE; complete withdrawals safely | Retain within bounded result window and while dependencies require it, then reject old-session traffic through absence from active lookup. No epoch-long closed-identity reservation in v1. |
| Origin revision high-water/tombstones | Reject stale same-session updates and conflicting retries | Retain while the origin session and its mutation/inventory dependencies can reference them. If capacity cannot preserve needed revision history, force fenced new-session/full-inventory recovery. Never silently forget a tombstone while accepting old-session mutations. |
| Inventory staging/result | Atomic assembly and idempotent commit outcome | Fixed transaction deadline; retire generation before releasing staging. Keep result within retry budget or make outcome unavailable and require defined recovery. One active generation plus monotonic high-water avoids retaining every aborted transaction forever. |
| View snapshot/delta history | Deliver and resume an exact installed prefix | APPLIED advances retention only for its view; remove acknowledged entries when no other retained view needs them. Pressure invalidates affected views/cursors explicitly before dropping required history. Saved client cursor does not force indefinite server retention. |
| Removal delivery records | Tell observers to withdraw stale state | Retain until relevant views acknowledge or are invalidated. Disconnected observers rely on conservative presence expiry; do not keep a global removal forever solely because an observer vanished. |
| View request outcomes | Prevent old requests creating successor snapshots | Session-local monotonic request generation/high-water plus bounded current outcome. An older generation cannot restart; an unavailable result requires a newer generation. |
| Aggregate freshness capture/result | Immutable nonce-correlated result and reliable STATE output | Once-only reliable CONTROL admission, bounded retained output until ACK/retirement; new queries may get LIMIT. No application same-nonce retry on a new writer sequence. |
| In-flight transport/runtime references | Prevent use-after-free and stale completion effects | Logical invalidation first; memory release only after completions and observers relinquish references. Cancellation request is not completion. Bound outstanding work at submission. |

Across sessions, preserve origin revision monotonicity in the client as already required.
A new session's authoritative inventory establishes its baseline; old-session messages
cannot enter that namespace. Retained downstream history remains generation/cursor-bound
and cannot overwrite a newly installed replacement baseline.

<a id="resolved-compact-replay-rules"></a>
### Replay retention rules

REGISTER consumes a validated introduction. Unknown/retired introduction IDs never
reconstruct admission. A consumed result has its own replay deadline, separate from the
unconsumed introduction's expiry. Retain UDP consumed-cookie correlation until all
associated cookies expire; TCP/protected paths do not require that extra cookie guard.
Reserve result/guard capacity before effects. See [current lifecycle](protocol.md#bootstrap-sizing-and-endpoint-lifecycle).

Aggregate queries submit once on reliable CONTROL. RTPS admission sequence state prevents
repair from reconstructing capture; results retain exact bytes through STATE delivery.
Clients abandon timed-out nonces and never reuse them. See [retry retirement](protocol.md#bounded-admission-and-freshness-retirement)
for capacity refusal and stale-session handling; the old serial/chunk scheme is retired.

<a id="blacklists"></a>
### Blacklists

No automatic misbehavior, repeated-incompatibility or reconnect blacklist is required for
v1. Such admission policy may be added later, independently of protocol-state retention.
V1 still enforces quotas, rate/response budgets, bounded retry/backoff, current configured
authorization and rejection of stale sessions. None requires a permanent participant ban.
A future blacklist needs explicit scope, expiry/recovery and administrative policy; GUID
or source IP alone is not authenticated identity and shared NATs require care.

Retain consumed guards through challenge expiry and admit aggregate queries once
on reliable CONTROL. Configure finite horizons and validate bootstrap fit and endpoint
lifecycle before deployment. Presence-query serials and a separate sliding window are
not part of this protocol.

<a id="broker-operation-admission-and-effects"></a>
## Broker operation admission and effects

<a id="shared-validation-before-dispatch"></a>
### Shared validation before dispatch

Validate Frame bounds, encapsulation/options/padding, version, opcode and body encoding
before allocating decoded state. Validate required-member presence, singleton uniqueness,
unknown required members, exact consumption, sequence/aggregate bounds and arithmetic.
A successful generated deserialize does not establish these properties.

Bootstrap uses direct bodies and fixed version 1.0. Established traffic uses Envelope
and the selected version. Check scope, association/path, endpoint direction/class,
epoch/session/owner generation and negotiated features before effects. Recheck current
ownership at commit, not just receipt. Deferred callbacks carry the same registration
token; no old cleanup may remove a successor. Unknown optional fields cannot confer
unnegotiated behavior. Unsecured GUID identity does not bypass session checks.

Allocate/reserve operation state and mandatory result capacity before a state-changing
commit. Budgets cover per-operation, per-session and service aggregates. Resource refusal
is observable failure or session invalidation, never partial success. Frame receipt,
RTPS ACK, operation commit, APPLIED and listener completion are different boundaries.

The phases below are independent predicates, not a single linear state enum:

* **B**: bootstrap, including a recorded admission awaiting confirmation. Match the exact
  outstanding attempt/binding; no established Envelope is invented.
* **S**: current admitted session known to the client. The broker does not initiate
  established output until receipt of valid established control confirms ACCEPT receipt.
* **I**: an origin inventory generation is staging; **O**: current-session origin inventory
  committed. A session can stage a replacement while retaining a still-valid prior cut.
* **V**: a selected downstream view is staging or resumed; **A**: its baseline is installed.
  View synchronization and origin inventory can progress independently.
* **D**: closing/draining. No new work accepted; only bounded teardown/result handling.

Origin freshness and observer presence validity are additional predicates. S, O or A
alone never means fresh. READY is derived from the readiness contract; it is not a
permission required for all control traffic.

Streams: **boot** is best-effort fixed bootstrap; **ctl** reliable control; **state**
reliable record traffic. C = client, Bkr = broker. Native WLP uses direct participant
transports, not a broker stream.

Failure classes used below:

* **silent**: malformed/untrusted/stale uncorrelatable traffic; bounded diagnostics only.
* **bootstrap**: eligible ADMISSION_REJECT under its reply/disclosure budgets.
* **operation**: correlated REJECT or ERROR with no partial effect, or session failure
  if a safe mandatory result cannot be delivered.
* **view**: invalidate affected staging/view and request a fresh view; never skip a hole.

<a id="operation-table"></a>
### Operation table

Every row inherits the shared checks. “Same” below means identical logical request and
content within its valid retention window, not merely a repeated RTPS sequence number.

| Code / operation | Direction; stream; phase | Additional checks and permitted effect | Duplicate / failure behavior |
| --- | --- | --- | --- |
| 4 ACCEPT | Bkr→C; boot; B | Outstanding REGISTER/introduction binding, scope, selected limits/profile/view/features, fresh session/generation, broker endpoints; inventory-required true; resume cursor/outcome agree; credential absent. Install mapping, not READY. | Same result idempotent. Conflicting result for one attempt fails admission; late results cannot replace a newer attempt/session. |
| 5 ORIGIN_BEGIN | C→Bkr; state; S | Current owner, increasing inventory generation, local cut, one participant plus bounded endpoint count/bytes; one active generation. Reserve complete declared staging before accepting records on this ordered STATE transaction. | Same BEGIN does not reset deadline. Conflicting generation/content aborts affected transaction; operation failure. |
| 6 ORIGIN_RECORD | C→Bkr; state; S/I | Generation/index, exact record bounds, local participant/incarnation ownership, kind/GUID and revision validity. Stage only; require preceding BEGIN on the same ordered STATE stream. | Same index/bytes harmless; conflicting index invalidates inventory. No install before join with BEGIN/END. Operation failure. |
| 7 ORIGIN_END | C→Bkr; state; S/I | Generation/count; exact indexed set and byte total, ordering/dependencies, current fence and freshness activation rules. Atomic inventory replacement after full validation. | END follows records in STATE order; missing records at END fail the transaction. Same completed transaction returns retained result; no second commit or timeout extension. |
| 8 MUTATE | C→Bkr; state; S/O | Complete owned record, revision high-water check, valid change/metadata and dependent participant. Reserve store/delta/result capacity; commit only against current owner and correct inventory baseline. | Same revision/bytes idempotent; changed bytes at same revision conflict. No early mutation staging; the accepted F1 barrier applies. |
| 9 COMMIT | Bkr→C; ctl; S | related_request and commit kind match retained inventory/mutation/close operation; applicable entity/revision/generation agree, unused fields zero. Advance only that operation's committed frontier. | Duplicate harmless; unknown/stale correlation cannot clear current pending work. A successful result never implies view synchronization. |
| 10 REJECT | Bkr→C; ctl; S | Correlated origin operation, inventory generation or entity/revision as applicable, legal error/recovery action. Fail that uncommitted attempt; preserve authoritative local state for repair. | Cannot contradict an already committed result. Conflicting outcomes require session recovery, not rollback of committed store effects. |
| 11 VIEW_REQUEST | C→Bkr; ctl; S | Negotiated view mode; resume feature, retained baseline/cursor and authorization compatibility; non-resume cursor zero. Reserve snapshot/delta retention or select valid resume. | Same request must not create another view. Client-assigned generation increases for new requests; old/failed generations cannot restart work. Operation failure or snapshot fallback where permitted. |
| 12 SNAPSHOT_BEGIN | Bkr→C; state; S/V | View generation/cut, count/total budgets, selected authorized mode; empty downstream snapshot allowed. Reserve staging before records; establish this view generation in ordered STATE. | Same BEGIN idempotent without extending deadline; conflicting baseline invalidates view. |
| 13 SNAPSHOT_RECORD | Bkr→C; state; S/V | View/cut/index, complete record, entity dependencies and negotiated metadata semantics. Stage only; require the current preceding snapshot BEGIN. | Same index/bytes harmless; conflicting or over-budget data invalidates view. RTPS ACK cannot stand in for application retention. |
| 14 SNAPSHOT_END | Bkr→C; state; S/V | Matching generation/cut/count, complete ordered set and fixed ready-through target. Install baseline atomically; then apply subsequent STATE deltas contiguously. Activate only with fresh presence. | END follows snapshot records; incomplete assembly fails rather than waiting for overtaken records. Duplicate cannot reinstall or refresh presence. Invalid assembly causes view recovery. |
| 15 DELTA | Bkr→C; state; S/V/A | Current view, positive delivery sequence, kind-specific record/reason/revision/freshness fields. Require installed baseline or valid resumed baseline; apply only next contiguous sequence with valid dependencies. | Identical retained duplicate harmless; conflicts/gaps trigger bounded repair/resync. Withdrawals do not invent native dispose or origin revision. |
| 16 APPLIED | C→Bkr; ctl; S/V | Current view and retained baseline cut; monotonic contiguous applied sequence no greater than actually sent history. Advance retention cursor only. | Same/lower valid acknowledgment adds no effect. Cannot refresh lease, invent received state or acknowledge another view. Invalid claim is operation failure. |
| 17 VIEW_SYNC | Bkr→C; state; S/V/A | Accepted resume, current retained baseline/view, fixed ready-through target. Establish target for resumed synchronization. | Same target idempotent; conflicting target for one synchronization is invalid. Never substitutes for missing baseline or presence. |
| 18 RESYNC_REQUIRED | Either; ctl; S/V/A | Applicable view, recognized reason and bounded retry hint. Invalidate affected synchronization/cursor and start fresh view within existing deadlines. | Old view must not invalidate successor. Client-originated invalidation has zero retry hint; newer VIEW_REQUEST also retires predecessor. |
| 19 LEASE_CHALLENGE | Bkr→C; ctl; S | Current session, nonzero nonce, bounded outstanding-proof work. Return matching proof only while participant/registration is live. | Duplicate does not create new freshness or extend broker deadline. D phase must not renew. |
| 20 LEASE_PROOF | C→Bkr; ctl; S | Outstanding nonce, current owner, server-local send-time deadline and valid policy. Consume proof and update origin freshness according to lease contract. | Replayed/late/unsolicited proof never renews. Admission alone is not proof. |
| 33 FRESHNESS_QUERY | C→Bkr; ctl; S/V | Current view and nonzero outstanding nonce; bounded rate/capture state. Capture actual unexpired membership and queue its marker after required STATE withdrawals. | Submit once; RTPS repair retains sequence/bytes/t0 and admits capture once. Timeout uses a new nonce; retained result capacity may refuse new work. See retry retirement. |
| 34 FRESHNESS_MARKER | Bkr→C; state; S/V | Matching outstanding nonce/view; installed frontier; unique incarnation exceptions within Xmax and marker-byte bounds; valid common/exception durations. Apply evidence only to covered membership. | First application consumes nonce. Duplicate, abandoned and old-session markers cannot extend validity. Earlier authoritative changes prevail. |
| 25 CLOSE | C→Bkr; ctl; S/D | Exact participant incarnation/current owner. Reserve terminal/result/withdrawal state; atomically fence and withdraw dependent records. | Duplicate retained result returns CLOSED; old-owner CLOSE cannot remove replacement. Post-close limited reply handling is not a live session. |
| 26 CLOSED | Bkr→C; ctl; D | Outstanding CLOSE identity/request and valid reply binding; release remote-wait obligation. | Late/duplicate harmless. Local destruction already has its own bounded completion path and never requires this reply. |
| 27 STATUS | Either; ctl; S/D | Related request/generations if applicable, recognized informational code. Update bounded diagnostics only. | Coalescing allowed; cannot establish COMMIT, READY, lease or authority. Inapplicable fields zero. |
| 28 ERROR | Either; ctl; S/D | Correlated operation, paired optional entity/revision, permitted recovery and bounded hint. Apply only locally legal recovery; no error loops. | Never a preadmission response or retroactive REJECT after commit. Use generation-scoped RESYNC_REQUIRED for view invalidation; ERROR correlates request failure. |
| 29 ADMISSION_REJECT | Bkr→C; boot; B | Exact REGISTER digest, nonce/attempt/binding; restricted reason, phase and retry hint. End attempt, report or back off within original deadline. | Ignore after session accepted; cannot extend deadline or disclose incumbent details before reply authorization. |
| 30 PATH_CHALLENGE | Bkr→C; boot; B | Outstanding directed SPDP attempt/nonce/path digest; bounded nonempty cookie. | Echo exact body under response budget; no admission or native identity proof. |
| 31 PATH_RESPONSE | C→Bkr; boot; B | Verify path-bound cookie/digest/expiry before reserving validated introduction state. | Same valid response repeats the same retained offer; no repeated allocation. |
| 32 REGISTER | C→Bkr; boot; B | First admission: existing unconsumed unexpired introduction/binding, matching attempt/nonce/domain scope/incarnation, same-scope broker identity, valid selections/limits and two endpoint pairs. Reserve resources before consumption. Consumed introductions use retained-result/session validity, independent of the old introduction expiry. | Same bytes repeat valid result; conflict/expired/unknown ID rejects without reconstructing state. |

<a id="domain-scope-checks-at-record-boundaries"></a>
### Domain scope checks at record boundaries

The admitted scope is immutable standard domain ID/tag within the configured authority.
Both client and selected logical broker participant must advertise that scope in their
introduction. Broker-profile client SPDP requires explicit domain ID; absent domain tag
means empty. No source-port inference, case folding or realm alias selects scope.

REGISTER's requested scope must equal that retained scope. An established Envelope carries
no scope: the scope of the validated endpoint association it arrives on must equal the
retained scope. Equality does not itself authorize the principal. Recheck current
session/owner at commit. An Envelope arriving on another scope's association cannot select
this scope's store or return its contents.
Destination endpoint/association, introduction/session and scope must agree independently.

For an origin participant record, validate payload GUID/incarnation/domain identity against
the admitted origin. Domain identity cannot change by MUTATE or replacement inventory in
one session. For an endpoint record, validate endpoint identity and parent participant using
the record/key and registered parent's scope. SEDP records need not repeat domain fields;
absence is not permission to use another domain's same-GUID participant. Key-only removals
resolve exclusively against that retained origin/scope and the specified inline metadata.
Duplicate/contradictory singleton identity metadata is invalid, not last-value-wins.

A complete inventory contains its one admitted participant and owned endpoints; stage
out-of-order data boundedly but do not commit or activate endpoints without their validated
parent. A downstream snapshot/delta likewise validates participant domain identity and
endpoint-parent membership in the selected authorized view. Unknown parents remain staged
only within the existing budget/deadline; a failed dependency invalidates the transaction
or view, never silently installs an orphan. Broker withdrawal is distinct from origin REMOVE.
Resume must validate original authority/scope/baseline retention as well as cursor numbers;
a cursor from another scope cannot be rebound by changing its Envelope.

<a id="phase-appropriate-errors"></a>
### Phase-appropriate errors

| Input / phase | Permitted response / effect |
| --- | --- |
| Malformed fixed framing, uncorrelatable source, unknown session or wrong association | Bounded silence/diagnostic; no allocation of a replacement session and no reply to an advertised locator |
| SPDP service or PATH validation fails | Bounded silence in v1; no established ERROR and no ownership disclosure |
| Valid correlatable REGISTER cannot be admitted | ADMISSION_REJECT only under its restricted reason/path/authorization/size rules; otherwise silence |
| Valid current-session origin operation fails semantic validation before commit | Correlated REJECT/ERROR as defined by that operation; no partial store installation; retire the session if safe mandatory-result handling cannot be maintained |
| Snapshot/delta assembly or dependencies fail | Invalidate the affected view and use generation-scoped RESYNC_REQUIRED; no skipped delivery hole or fabricated APPLIED |
| Duplicate operation whose effect already committed | Retained outcome or defined expired-result recovery; never retroactive failure implying the effect did not occur |
| Invalid/unexpected rejection or error reply | No error-response loop; bounded diagnostic and locally justified recovery only |

A current-session scope/identity contradiction is not an instruction to route elsewhere.
Reject its effects and fail the affected operation/session under the existing policy; any
response must use the verified original association. Unknown/untrusted traffic cannot tear
down another session. Error-code availability in the registry does not authorize that code
in every phase. ADMISSION_REJECT and RESYNC_REQUIRED retain their explicit reason subsets.
