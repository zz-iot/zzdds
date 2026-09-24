# Service introduction metadata and compact registration

Domain identity revision (2026-09-18): the accepted [standard domain identity decision](broker-domain-identity.md)
replaces broker realm with RTPS domain ID/tag. The experimental schema/fixtures now use the standard string representation.
Earlier realm-specific prose remains superseded; this is not a wire freeze.

Status: SPDP service sequence and bounded introduction-record direction accepted,
2026-09-18. Experimental schema now contains service descriptors/context, PATH_CHALLENGE/
RESPONSE and REGISTER. Exact wire/provider integration remains unfrozen; old handshake
fixtures are historical, not active protocol support.

## Separate capability, directed intent and registration

| Object | Placement | Proposed contents |
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

## Why directed context belongs in inline QoS

A standard participant announcement has one canonical payload/version. Adding different
broker-request parameters to that payload for different recipients risks producing two
contents for one cached native sample/sequence. Putting directed context in inline QoS
keeps the participant's serialized discovery sample unchanged while carrying per-exchange
metadata on the particular transmission. Both vendor context parameters are optional to
legacy readers and excluded from origin canonical-content comparison.

This is a proposed zzdds extension using the inline ParameterList mechanism, not a claim
that current SPDP code already emits or retains it. Direct receive handling must inspect
context independently of canonical-payload deduplication: repeating the same participant
sample may carry a new service attempt. Inline data must not be indiscriminately attached
to multicast retransmission or stored in the canonical payload cache. The [source feasibility review](broker-inline-context-feasibility.md) retains this path
with bounded internal send/receive changes. A dedicated introduction request sample would
require a separately reviewed wire revision, not an automatic fallback; never vary the
cached payload under one native sequence.

ServiceCapabilities are persistent participant metadata and do belong in canonical origin
content. Changing them advances origin_revision. Directed attempts, offers and path cookies
do not. Both sample and context are subject to the containing transport/security profile;
plaintext inline metadata must not be used to bypass future DDS Security requirements.

## Canonical introduction binding

Digest the exact serialized SPDP sample bytes (including its encapsulation), not a decoded
projection. Keep the client sample chosen for the attempt immutable even if native SPDP
operational counters advance afterward. Registration binds that introduction; its subsequent
inventory may legitimately contain a newer committed participant version. Neither an old
introduction nor its sample hash can roll back the graph.

Use distinct hash domains for client sample, server sample, directed context and registration.
The offer reports the paired sample digests; the client validates them against the bounded
samples it retained. A changed offer requires a fresh introduction/attempt rather than
silently changing the interpretation of a retried Register. Exact domain strings and
encoding are specified in the [current registry](broker-wire-registry.md#spdp-service-revision-2026-09-18)
and checked by independent fixtures. Hashes provide correlation,
not origin authentication. The configured binding/security policy supplies authority.

REGISTER carries an introduction ID instead of repeating full SPDP samples, a challenge,
or the complete capability lists. It selects a supported combination; the server checks
that selection against the retained introductions and current policy. Requested scope must
agree exactly with the introduced participant domain ID/tag. The selected broker
service participant has the same domain ID/tag, under the accepted
[multi-domain service arrangement](broker-multidomain-service.md). Participant GUID comes
from the retained client sample; incarnation must agree with its origin-version metadata.
No second independent claimant GUID is necessary in Register.

## Bounded validated introduction record

Recommend an ephemeral server introduction record after return-path validation, including
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

## Limits, messages and lifecycle

This proposal removes the need for an unconditional application-level cookie and eliminates
full HELLO+CHALLENGE repetition. It does not prove messages fit every MTU: full SPDP may
contain many locators or vendor parameters. Directed introduction sample/context, server
reply and REGISTER each require encoded-size checks. Before validation the response budget
still forbids a larger full reply merely because it is SPDP. Do not silently strip canonical
origin fields to make the sample fit. The [current sizing contract](broker-bootstrap-lifecycle.md) requires unfragmented
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

## Review outcome and next decision

Recommend these placements and the bounded validated introduction record. The main cost
is retaining a small amount of preadmission state after reachability validation; the benefit
is a compact REGISTER, consistent TCP/UDP treatment and straightforward replay retirement
without a compulsory cookie on already validated transports. This tradeoff is accepted; old opcodes 1–3 are reserved and new schema types are
experimental. Native ParameterList and registration/hash fixtures now pass; production
implementation remains pending.

Implementation evidence needed: recipient-specific inline context, identical canonical
sample bytes, retries after introduction/result expiry, duplicate UDP validation, and
capacity refusal without phantom registrations. The codec evidence is summarized in the [lifecycle review](broker-bootstrap-lifecycle.md);
it does not exercise these production lifecycle requirements.
