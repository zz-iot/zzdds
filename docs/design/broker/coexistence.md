# Broker: coexistence

Requirements use the [shared convention](../concurrency-broker-status.md#requirement-convention).
[The index](../concurrency-broker-status.md) owns scope and unresolved design items;
[the evidence inventory](../probes/README.md) records validation.
<a id="standard-domain-identity-replaces-broker-realm"></a>
## Standard domain identity replaces broker realm

<a id="standard-basis"></a>
### Standard basis

OMG DDSI-RTPS 2.5 defines domainTag in SPDPdiscoveredParticipantData (Table 8.78).
Section 8.5.5.1 checks both domainId and domainTag before configuring ordinary SEDP
associations. Table 9.18 assigns PID_DOMAIN_TAG=0x4014, type string<256>; Table 9.19
defaults an absent tag to the empty string. PID_DOMAIN_ID=0x000f defaults, when absent,
to the receiving participant's domain ID. These are OMG RTPS definitions, not an
RTI-specific extension. Source: https://www.omg.org/spec/DDSI-RTPS/2.5/PDF

The tag is an exact, case-sensitive string, not a wildcard partition expression.
No normalization, truncation, domain translation or broker-local alias is permitted.
The native CDR string encoding includes its length and terminating NUL; the old realm
sequence-of-octets encoding is not a compatible substitute. Validate the standard bound
and termination through the generated codec and public configuration conversion.
The 0x4000 flag in the PID requires correct handling by a receiver that does not
understand it. An older implementation cannot be assumed to support nonempty tags.
Neither domain IDs/tags nor Partition QoS are authentication or access control.

<a id="public-configuration"></a>
### Public configuration

Add `@default("") string<256> tag;` to zzdds::DomainConfig alongside id, and carry it
through native configuration, generated bindings and TOML. Illustrative TOML syntax:

```toml
[domain]
id = 0
tag = "production"

[discovery]
kind = "broker"

[discovery.broker]
addresses = ["tcp://discovery.example.net:7443"]
```

The same domain tag applies with ordinary multicast, directed SPDP, mixed discovery,
or broker-only discovery. No broker realm field remains. Empty-tag defaults preserve
existing untagged deployments. Configuration is immutable for participant lifetime;
factory default changes affect future participants. Keep configuration on zzdds.idl
because the existing DomainConfig is its public configuration surface; do not invent
a new DCPS operation solely to expose an RTPS participant property.

<a id="native-implementation-requirement"></a>
### Native implementation requirement

Inspection found no domainTag/domain_tag/PID_DOMAIN_TAG support in src, idl or tests.
At inspection, the generated SPDP schema lacked both domainTag and domainId, and the
wrapper assigned its local domain_id argument irrespective of input. The first native
change now adds optional domainId decoding, unconditional outgoing domainId and rejection
of explicit foreign domains before SPDP cache/locator updates. Domain-tag support remains
pending; this partial change does not complete the domain-identity requirement.
Native support is therefore a broker prerequisite:

1. Add standard optional domainId/domainTag parameters to rtps_discovery.idl and regenerate.
   Always emit our domain ID, including domain zero, regardless of port/address selection.
   Decode absence using the specified defaults; preserve an explicit remote domain ID.
   This fallback is receiver-domain context, not reverse mapping from a source port.
2. Propagate configured tag through participant construction, announcements, owned remote
   data and cleanup. Emit nonempty tags; omission of empty tags retains default-wire
   interoperability. Keep codec decoding distinct from local association eligibility.
3. Check resolved domain identity before remote cache installation, locator learning,
   lease refresh, SEDP/WLP association and application notification. Review early SEDP
   receive paths so an excluded participant cannot create endpoint matches anyway.
4. Apply the same domain rule to other native discovery paths (including direct/in-process
   discovery), without changing the guaranteed same-participant matching path.
5. Cover absent/empty/equal/unequal tags, explicit domain mismatch, both byte orders,
   malformed/duplicate strings, upper bounds and unknown must-understand behavior.
   Test two participants sharing sockets/network/domain ID with different tags, plus
   default untagged compatibility and configuration/binding roundtrips.

Do not call support complete merely because the codec can retain an unknown PID.

<a id="broker-reconciliation-requirement"></a>
### Broker reconciliation requirement

Scope becomes `(domain_id, domain_tag)` within the configured broker authority. Partition
matching continues within that scope. Admission authorization can restrict these standard
identifiers without inventing another discovery namespace. Multi-tenant administrative
isolation remains deferred; choosing a tag is not authorization to join that scope.

Derive the requested scope from the immutable client SPDP introduction. Remove
requested_realm from ServiceRequestContext: it need not repeat the participant's domain.
Replace ScopeValue.realm with a standard-bounded string domain_tag, retaining domain_id;
all registration/envelope scope fields must agree with the retained introduction. Broker
cache, ownership, view, digest and resume handling must use this resolved scope consistently.
A nonempty tag must not disappear on retransmission, broker reannouncement or local graph
installation. Missing domain IDs need explicit resolution against the configured contacted
service/domain context; a multi-domain broker must not guess an absent origin domain.
The zzdds broker profile should require an explicit origin domain ID in its introduction.

A broker service administers configured domain identities using a distinct logical RTPS
participant per scope, with shared listeners/runtime. Client and selected broker participant
must agree on domain ID/tag. Service ingress selects the identity before ordinary peer
installation; it does not authorize cross-domain associations. See the accepted
[multi-domain service arrangement](coexistence.md#multi-domain-broker-service-identities).

The experimental ScopeValue now uses string<256> domain_tag followed by domain_id;
ServiceRequestContext no longer carries requested_realm. Independent fixtures use CDR
string length including its NUL terminator, not the old realm octet sequence. Service SPDP
fixtures include explicit domain ID and domain tag in both byte orders. Native admission
and interoperability tests remain implementation gates.

Validation of the domain-ID increment: `zig build test-discovery` passes 47/47 tests
with pinned zidl 0.3.17. Coverage includes unconditional domain-zero wire emission,
explicit LE/BE remote IDs, missing-ID receiver fallback, and foreign-domain rejection
without installation or refresh. This does not validate domainTag, full-suite behavior,
live cross-vendor interoperability or the remaining early-SEDP admission boundary.

<a id="multi-domain-broker-service-identities"></a>
## Multi-domain broker service identities

<a id="choice"></a>
### Choice

One configured broker address may serve many `(domain_id, domain_tag)` scopes. Two designs
can implement this without forwarding user data or translating participant domains:

| Design | Advantages | Costs |
| --- | --- | --- |
| One broker RTPS participant across all served scopes; custom endpoints explicitly permit cross-domain association | Fewest participant identities and canonical SPDP records; direct mapping to a central service | Requires a permanent exception for service associations; harder to align future domain-specific DDS Security governance; service identity and application domain identity differ |
| One logical broker RTPS participant per served scope, sharing service listeners/runtime | Client and broker service participant have identical domain identity; preserves ordinary domain eligibility and stable per-GUID SPDP; accommodates domain-specific governance more naturally | Per-active-scope GUID, SPDP sample and endpoint state; broker ingress must select the right participant; bounded creation/retirement policy required |

Use the second design. A logical participant is a protocol identity, not a required
thread, process, socket, independent store or full public DDS object. Implementation may
share runtime workers, network listeners, timers and storage while preserving identity and
per-scope accounting. Cost grows with served scopes, not one extra participant per client.

<a id="standard-boundary"></a>
### Standard boundary

RTPS 2.5 §8.5.1 permits vendor-specific discovery protocols. Section 8.5.5.1 checks domain
ID/tag before ordinary SEDP associations. Neither section standardizes this broker service.
The contract keeps same-domain service associations rather than assuming the
vendor-extension permission proves arbitrary cross-domain DDS Security compatibility.
Source: https://www.omg.org/spec/DDSI-RTPS/2.5/PDF

Each broker participant has one immutable domain identity and distinct GUID prefix. It
never sends different domain IDs/tags under the same participant GUID depending on the
recipient. Its canonical SPDP describes itself; origin participant records in the broker
store retain their original GUIDs and domain identity. The broker service participant is
not inserted into the distributed application inventory merely because it serves clients.

<a id="shared-ingress-and-bootstrap"></a>
### Shared ingress and bootstrap

1. A client sends its canonical SPDP plus directed service-request context to the configured
   address. Explicit PID_DOMAIN_ID is required for this broker profile; absent domainTag
   resolves to empty. There is no requested_realm and no port-to-domain inference.
2. A bounded service ingress parser obtains the requested standard domain identity. It
   checks framing, service kind, configured served-scope policy and path/resource limits.
   This is routing of a provisional introduction, not ordinary participant installation.
3. Plain UDP path validation uses the existing predefined introduction endpoints. Before
   advertising a service GUID, choose an existing configured scope identity; do not create
   an unbounded population of participants on unauthenticated requests. TCP/protected
   transport follows the already accepted validation sequence.
4. The broker responds using its logical participant for that exact scope. The offer binds
   the immutable client/server samples and existing introduction IDs/digests. The client
   checks the offered server domain identity as well as configured service authority,
   path binding, supported service and attempt correlation.
5. REGISTER/ACCEPT and established CONTROL/STATE endpoints belong to that same logical
   participant. Admission atomically binds authority, domain scope, both participant
   identities, introduction, session and owner generation. Established traffic cannot
   retarget the scope through an Envelope field or a different destination GUID.

Initial v1 policy: administratively configure a finite set of served scopes and
allocate their lightweight identities before accepting introductions. Do not auto-create a
scope merely because a client requests a new tag. Unknown/disallowed preadmission scope
gets bounded silence under existing response policy; local activity and finite client
startup behavior are unchanged. Dynamic scope provisioning is optional later work.

Different domains/tags may use the same UDP/TCP listen address. After bootstrap, route
using validated association plus destination endpoint identity, not GUID prefix alone or
an untrusted scope field. Introduction parsing and path-validation work have global as
well as per-scope budgets. Unknown scope must not allocate reliable endpoint/history state.
This mechanism does not add an extra round trip or require applications to know the broker
participant GUID in advance.

<a id="isolation-and-lifecycle"></a>
### Isolation and lifecycle

Ordinary multicast/directed peer processing retains domain equality checks. A service
request does not enable native SEDP/WLP or user endpoint association with the broker,
even when its domain matches. Service capabilities alone do not authorize a client to
use an unsolicited broker. Authorization applies to the requested domain scope.

Cache lookup, participant ownership, inventory, downstream views, presence queries and
resume cursors are confined to the admitted scope. Same names or overlapping partitions
across scopes cannot merge their views. Identical GUID bytes in separate scopes must not
alias ingress/session tables; a client changing its immutable domain requires a new
participant lifetime. No domain-changing update exists within a registered session.

Share a broker epoch across scopes if desired; epoch alone is never a lookup or authority
key. If a logical service participant is recreated, use fresh identity/generation fencing,
retire old endpoint associations, and require fresh introduction/session establishment.
One scope's removal must not close sessions in another scope or remove independently
justified direct-discovery state. No ordinary SPDP lease refresh extends broker ownership.

Future DDS Security remains an integration gate: each logical participant must satisfy its
scope's governance and permissions, including identity/authentication endpoints and safe
bootstrap ordering. This arrangement allows domain-specific policy but does not prove
that future secure discovery can use today's plaintext service messages unchanged.
Transport credentials may be shared administratively; that does not grant cross-domain
DDS permissions or replace participant authentication.

<a id="reconciliation-of-direct-and-broker-discovery"></a>
## Reconciliation of direct and broker discovery

<a id="one-graph-separately-retained-evidence"></a>
### One graph, separately retained evidence

Use one participant/endpoint graph and one matching/lifecycle path. Identify entities by
GUID, with origin incarnation where it can be established; track direct and broker evidence
beneath that identity rather than installing two independent entities. The broker source
is scoped to authority, session/view and freshness; direct evidence carries native origin,
writer/sequence provenance and its own participant lease. Multicast and directed SPDP
are paths to direct evidence, not separate participants.

One source disappearing removes only its evidence. Emit an unmatched/removal transition
only when no permitted evidence sustains the effective entity, or an authoritative origin
removal/security decision requires it. Installing equivalent evidence twice must not create
duplicate matched callbacks, samples in built-in topic views or extra native WLP associations.
Changes to effective QoS still use the normal DDS compatibility/status rules.

Liveness and content version are different. A fresh broker presence proof cannot turn an
older endpoint definition into the newest one. A direct packet's arrival time likewise
does not prove that its endpoint payload is newer than an already installed broker record.
Never compare a broker delivery sequence with a native RTPS writer sequence.

<a id="the-difficult-case-comparing-updates-across-paths"></a>
### The difficult case: comparing updates across paths

Example: direct SEDP installs endpoint revision 8; a delayed broker view still contains
revision 7. After direct discovery expires, blindly preferring the surviving source would
roll the endpoint back. “Prefer direct while available” postpones rather than solves this.

Use a shared origin version for zzdds participants on both paths. This identifies
newest admitted origin state independently of path, rather than using packet arrival
order or a fixed preference that could roll back after source loss. Reuse the broker's
per-entity origin_revision, generated once when local discovery state changes, and expose
it plus the participant incarnation through vendor parameters in direct SPDP/SEDP records.
The same revision describes the same logical state in broker inventory/mutations. Periodic
reannouncement, retransmission, lease renewal and broker reconnect do not increment it;
a real discovery-state change does. Runtime-only directed service-request metadata is not
part of this canonical state version. Counter overflow requires defined identity renewal,
not wrapping. The [wire contract](wire.md) defines provisional encoding/assignments; generated integration is a publication gate.

Standard peers may ignore these optional vendor parameters. Do not claim the extension
itself authenticates the revision: unsecured operation remains unsecured. Secure installs
must validate the relevant origin and permissions under their configured security profile.
A trusted plaintext broker cannot override native protected discovery merely with a large
revision number. The cached and future secure-peer profiles remain distinct.

A native writer GUID/sequence can establish equality/order only when both records really
refer to the same originating writer lifetime and sample. It is useful evidence, not a
universal replacement for the shared revision: some broker records have no corresponding
native sample, and different built-in writers have independent sequence spaces.

<a id="selecting-content-and-freshness"></a>
### Selecting content and freshness

Within a recognized incarnation, retain the highest validated origin revision and its
canonical semantic content. A lower revision cannot replace it even when that source is
currently fresher. Same revision with different canonical content is a conflict, reported
without last-arrival selection. Compare normalized discovery meaning, not transport-specific
padding or parameter order; retain original source bytes separately for fidelity. Unknown
optional fields must not be silently treated as equal if their differing values could
change an extension's meaning; the exact equivalence policy is a follow-up wire obligation.

An installed version remains active only with appropriate current evidence supporting that
version and participant identity. Old-version evidence must not indefinitely sustain newer
content it has never attested. If only stale/incomparable records remain, leave the entity
inactive pending refreshed discovery instead of silently rolling it back. This can sacrifice
availability during disagreement, but avoids incorrect matching/QoS behavior. Equivalent
same-version evidence allows seamless source expiry without an unmatched/matched cycle.

The selected record's locator values remain origin data. Route selection can use eligible
validated paths, but must not blindly union locators from stale versions or different
incarnations. Installing broker records does not start unsolicited direct SPDP/SEDP fan-out;
ordinary direct discoveries still follow configured peer policy.

<a id="removal-is-not-source-loss"></a>
### Removal is not source loss

* Broker view filtering, broker disconnect, registration expiry or direct lease expiry
  withdraw only the relevant evidence. They are not origin endpoint deletion.
* A validated origin endpoint REMOVE/dispose is an origin lifecycle event. With comparable
  revisions it defeats lower-revision advertisements on every path. Retain its high-water
  protection while any retained evidence could revive the old entity.
* Correct v1 origins never recreate a deleted endpoint under the same endpoint GUID. This
  already accepted rule simplifies delayed deletion handling; a newly created endpoint
  uses a fresh GUID.
* Participant disconnect is not participant deletion. A new admitted registration may use
  the same still-live identity after old obligations retire; do not turn a source timeout
  into the identity blacklist we rejected.
* Security denial is enforced according to the governing authorization, never bypassed by
  discovering the same GUID through an unsecured source.

Bound evidence/tombstone storage per participant/source. Retiring a source means invalidating
its replay/session/native-writer dependencies before freeing needed ordering guards. If
retention cannot safely reconcile conflicting evidence, force source resynchronization or
report bounded resource failure; do not drop the guard and choose whatever arrives next.

<a id="peers-without-the-shared-revision-extension"></a>
### Peers without the shared revision extension

Ordinary direct discovery of non-zzdds peers continues normally. V1 does not automatically
import those peers into the broker, so the common direct-only case needs no vendor version.
Broker publication still comes only from the admitted origin's own participant/endpoints;
never upload the union of everything the client learned from other peers. This prevents
loops and avoids an implicit LAN gateway/federation feature.

If both sources nevertheless describe one identity without comparable provenance, merge
only demonstrably equivalent content under a policy that does not bypass security. For
differing content, report the conflict and avoid automatic cross-source overwrite/failover.
A fixed-authority policy could be an explicit later option, but is not equivalent to a
proof that the preferred source is newer. Independent unrelated participants colliding on
a GUID must not be merged merely because the GUID bytes match.

<a id="origin-update-boundary"></a>
### Origin update boundary

Create one immutable logical discovery version at the local entity's committed update
boundary. Allocate its next origin revision once, and let both direct announcements and
broker inventory/mutations reference that version. Do not allocate separate revisions in
the two serializers or their send callbacks. A failed preparation that publishes nothing
must not expose a partial version; skipped counter values are harmless, reuse of a
published revision for changed content is not.

A broker inventory captures the committed versions at its cut. Subsequent local changes
create newer versions and enter the existing post-inventory COMMIT queue. Native direct
discovery may advertise them earlier; receivers use origin revision rather than channel
arrival to resolve the resulting difference. Broker outage, reconnect or adding a new
observer does not itself create a new origin revision.

An endpoint removal is a committed origin version with the next revision. Preserve that
version for direct deletion signaling and broker REMOVE retry as needed. Source expiry,
filtered-view withdrawal and unavailable presence results must not increment origin
revision or manufacture that deletion. Recreating an endpoint uses a fresh GUID; it does
not reset revisions under the deleted GUID. Incarnation/revision comparisons remain scoped
to the proper participant identity and validated provenance.

<a id="direct-source-versus-broker-origin-decoding"></a>
### Direct-source versus broker-origin decoding

The raw/typed codec boundary is required:
For a broker-delivered OriginRecord, validate embedded participant identity against its
record origin, never the enclosing broker RTPS prefix. Do not let a direct-SPDP decoder's
source-prefix preference silently rewrite conflicting broker records. Preserve exact
source bytes and reject inconsistent origin evidence before installation. An unsecured
RTPS header is not authenticated identity; effective INFO_SRC and configured protection
remain separate checks. All installation/rematching paths honor current enable/ignore/QoS
policy, even when the underlying discovery evidence remains cached.

<a id="origin-version-placement-and-canonical-discovery-content"></a>
## Origin-version placement and canonical discovery content

<a id="placement"></a>
### Placement

Use a vendor-specific, optional-to-legacy-readers origin-version parameter carrying
participant incarnation (16 octets) and per-entity origin_revision (unsigned 64-bit).
Both must be nonzero under the zzdds extension contract. Parameter body is CDR using
the containing ParameterList's byte order, with alignment origin at its value start:
incarnation at offset 0 and revision at offset 16, total 24 bytes. No nested encapsulation.
The key remains the standard participant/endpoint GUID; no GUID is duplicated here.
The provisional assignment 0x8003 avoids existing zzdds locator PIDs 0x8001/0x8002.
Its vendor bit is set and must-understand bit clear, allowing legacy readers to ignore
the extension. Interpretation is scoped to the zzdds vendor/profile, not arbitrary
vendors reusing the same vendor-specific PID. This is not an OMG allocation.

| Native announcement | Version parameter location |
| --- | --- |
| Full SPDP participant data | Serialized discovery ParameterList |
| Full SEDP publication/subscription data | Serialized discovery ParameterList |
| Key-only participant/endpoint dispose or unregister | DATA inline-QoS ParameterList; serialized key payload remains standard |
| Key-hash-only lifecycle message | Inline QoS, alongside existing native key/status information; resolve key unambiguously |

RTPS restricts key-only built-in discovery payloads to PID_PARTICIPANT_GUID or
PID_ENDPOINT_GUID, respectively. Its inline-QoS ParameterList has vendor extension
handling. The placement above is our extension design using those mechanisms, not an
OMG-defined origin-version field.
[RTPS 2.5 §§9.6.2.2, 9.6.3, 9.6.4](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

Use one semantic parameter definition in both allowed locations. For full messages,
inline-only metadata is not a substitute for the payload parameter in the initial
zzdds profile. If both locations contain it, require exact decoded agreement. Duplicate
singleton occurrences, wrong lengths, zero values or disagreement reject versioned
installation. A peer lacking the parameter remains a legacy peer; do not fabricate an
origin revision from arrival time or assume it is older than revision 1.

Fragmented full announcements retain version metadata within the reassembled payload;
key-only lifecycle messages are small and should not require fragmentation. If the native
transport supports a fragmented lifecycle form, its inline metadata must be validated
and retained through reassembly under the RTPS rules before installation. Fragment receipt
is not authorization to apply a deletion early.

A broker OriginRecord repeats incarnation/revision in its envelope fields for indexing
and ordering. Where native origin metadata is present, require equality. For retained
native deletions, preserve original inline QoS in change_metadata and validate its version
against the OriginRecord. A locally constructed broker removal without a native sample
still gets its version from the common local origin-update boundary. It must not invent
native status/sequence provenance. If direct deletion is also emitted, it uses that same
origin version, regardless of the relative transmission times.

<a id="what-the-revision-versions"></a>
### What the revision versions

Version canonical entity discovery content, not the serialized packet or an observation's
freshness. Define a typed comparison projection for each supported record kind:

* Participant: identity, protocol/vendor identity, domain/tag where present, built-in
  capabilities and QoS, metatraffic/default locators, advertised lease duration, user data,
  entity name and other recognized persistent discovery properties.
* Writer/reader: identity, parent/group identity, topic/type identity and type information,
  endpoint locators, advertised QoS, content-filter properties and other recognized
  persistent endpoint metadata.
* Lifecycle state: the origin's alive/remove transition and relevant native dispose/
  unregister meaning. A source withdrawal is never an origin lifecycle transition.

Exclude RTPS writer sequence, timestamps, transport headers, encapsulation representation,
legal serialization padding and ordering between distinct independent PIDs. Treat absent
recognized parameters according to their specified effective defaults; do not invent a
default where the applicable profile requires presence. Retain ordered sequences and
repeated parameter values in their defined order unless their specification explicitly
permits set-like equivalence. In particular, do not sort every locator/QoS sequence merely
to make comparison convenient. A conservative extra conflict is safer than hiding a change.

Exclude the version parameter itself from content comparison (compare it as provenance),
and separate directed broker-service request context from canonical origin content. The
exact list of excluded zzdds service PIDs will be assigned with the revised handshake.
An unknown vendor parameter is not automatically service context.

<a id="native-operational-fields"></a>
### Native operational fields

SPDP manualLivelinessCount is an operational assertion counter, not a persistent discovery
configuration revision. A changed counter can accompany the same origin revision. Process
it under native liveliness ordering/freshness rules on a direct source. Cached broker
replay of that value must not generate a fresh assertion. Likewise repeated SPDP reception
may refresh the direct participant lease without changing canonical content, while broker
freshness comes from the broker presence contract. Neither observation rewrites origin
revision or changes the other source's deadline.

This requires splitting operational receive handling from canonical entity installation.
Do not skip all processing just because an announcement has the already installed origin
revision. Conversely, accepting a new operational counter is not permission to roll back
persistent QoS/locators from an older origin revision. The native protocol's own acceptance
rules still apply. Exact field classification must be reflected in the implementation's
per-record comparator and tests; excluding arbitrary fields would be a correctness bug.

<a id="unknown-fields-and-byte-preservation"></a>
### Unknown fields and byte preservation

For recognized content, compare decoded effective values. For unknown optional content,
retain PID, multiplicity, order among repeats, value bytes and source encoding context.
Conservatively treat differing opaque values or encoding contexts as incomparable/conflict
at the same revision. Do not guess how to normalize an unknown structure or erase its
bytes to force equivalence. This may reject semantically equivalent opaque data encoded
in different byte orders; an extension-specific comparator can later remove that false
conflict. Unknown required semantics continue to prevent installation.

Keep three distinct rules:

1. Native/broker source bytes are retained unchanged for fidelity.
2. A retry of the same broker logical request retains exactly the same OriginRecord bytes.
3. Cross-source version equivalence uses the canonical projection above, not byte equality
   of entire packets and not arbitrary reserialization of unknown fields.

For each committed origin revision, the origin retains a stable broker representation
for retries and any inventory reupload needing that version. Later native reannouncements
may contain changed operational counters while preserving the same canonical content.
They do not replace the retained broker record under the same revision. If that retained
representation cannot be supplied after local reclamation, use a defined recovery contract;
do not silently send different record bytes at an existing revision. Representation
lifetime/accounting must be included in the origin implementation, not a broker-only cache.
