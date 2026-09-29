# Broker: wire

This is a current contract. Scope, decisions and implementation gates are in
[the single status index](../concurrency-broker-status.md). Validation results are maintained
only in [the evidence inventory](../../../test/design-models/README.md).
<a id="broker-wire-bytes"></a>
## Broker wire byte baseline

<a id="broker-wire-bytes--fixed-sample-wrapper"></a>
### Fixed sample wrapper

The outermost serialized object is final Frame. Use little-endian PLAIN_CDR2 with
encapsulation identifier bytes `00 07`. XTypes associates the encapsulation with the
outermost object's extensibility, not types stored within its fields; mutable standalone
types use a different identifier. This is why the broker Frame can carry mutable body
bytes without being a top-level mutable object.
[OMG DDS-XTypes 1.3, section 7.6.3.1.2 / table 60](https://www.omg.org/spec/DDS-XTypes/1.3/PDF).

Proposed major/minor baseline is 1.0; bootstrap framing remains invariant while
negotiating the supported application protocol version. All multibyte Frame fields
except the encapsulation identifier are little-endian.

| Offset from serialized sample start | Bytes | Meaning |
| --- | --- | --- |
| 0 | 2 | `00 07`, outer final XCDR2 little-endian encapsulation |
| 2 | 1 | Zero, reserved encapsulation options |
| 3 | 1 | Terminal padding count p (0–3); other bits zero in this profile |
| 4 | 8 | ASCII `ZZDBRK03` (`5a 5a 44 42 52 4b 30 33`), no terminator |
| 12 | 2 | Protocol major |
| 14 | 2 | Selected protocol minor; bootstrap request uses baseline grammar |
| 16 | 2 | Operation registry code |
| 18 | 2 | Body encoding 1: the broker baseline XCDR2 LE body mapping |
| 20 | 4 | Body byte count n, excluding terminal padding |
| 24 | n | Body bytes |
| 24+n | p | Zero padding to a 4-byte boundary, p = (-n) mod 4 |

The encapsulation padding count follows XTypes' payload-end convention. The broker
profile requires zero reserved bits and zero emitted padding. Validate total size as
24+n+p with checked/bounded arithmetic. Reject truncation, trailing bytes, impossible
lengths, unsupported encoding/version and mismatched padding. Operation/phase validation
is additional to Frame validation. Limits include all wrapper bytes; RTPS headers and
transport/security overhead are separately accounted for by channel budgets.

TCP's existing big-endian transport length prefixes the complete RTPS transport message,
not this Frame alone. UDP carries its usual RTPS message. DATA_FRAG fragments the complete
serialized sample for established traffic only; reassemble under bounded accounting
before interpreting its body. Bootstrap Frames and SPDP service introductions remain
unfragmented under the lifecycle contract; this paragraph does not permit preadmission
reassembly.
No second stream delimiter or ad hoc checksum is introduced.

<a id="broker-wire-bytes--body-origins-and-exact-bytes"></a>
### Body origins and exact bytes

ACCEPT, ADMISSION_REJECT, PATH_CHALLENGE, PATH_RESPONSE and REGISTER bodies are
their direct mutable type encodings (PATH_RESPONSE echoes PathChallenge). Other active
operations carry
final positional Envelope encodings, whose operation_body octet sequence contains the selected
operation's final positional encoding. These byte blobs have no encapsulation headers. Each
independently serialized blob starts its alignment origin at its own byte zero; it is
not aligned according to where its octets happen to land in the containing sequence.
Ordinary nested typed struct fields follow XCDR2 alignment within their containing stream.

Body encoding 1 selects this mapping; it is not an RTPS encapsulation ID. Immutable
record_bytes likewise contain the baseline final OriginRecord encoding without an
encapsulation header. change_metadata contains the final MetadataList encoding without
an encapsulation header. Original discovery_payload includes its original encapsulation
and is preserved unchanged, including its source byte order and parameter padding.

Assign draft discovery_encoding 1 to retained RTPS PL_CDR little-endian payload and 2
to its big-endian counterpart. Verify the declared encoding against retained bytes;
unknown negotiated future encodings must not be parsed as this baseline. Internal
canonical record alignment padding is zero. Absent native-sequence state uses zero
sequence and writer GUID, distinct from a fabricated native publication.

<a id="broker-wire-bytes--transaction-assembly-without-digests"></a>
### Transaction assembly without digests

Draft 3 carries no inventory/snapshot digest in END, APPLIED or ResumeCursor.
Validate exact indexed record membership, unique entity keys, deterministic order,
count and declared byte total; END follows its records on ordered STATE. Preserve exact
record bytes for duplicate/conflict checks. Empty downstream snapshots are valid; an
origin inventory includes exactly one participant record and cannot be empty.

Participant records precede dependent endpoints. Within each class, sort by participant
GUID, incarnation bytes, record kind and entity GUID using unsigned byte/integer order.
Indices cover exactly [0, count). Identical same-index retransmissions are harmless;
conflicting bytes invalidate the transaction. Sum record lengths with checked arithmetic
and match the declared byte total. Reject RECORD before BEGIN and incomplete END rather
than assembling orphan records across STATE boundaries. Deadline or capacity failure
aborts staging and requires explicit recovery; partial assembly never publishes a view.

APPLIED resolves the current session/view baseline and snapshot cut, with a contiguous
frontier no greater than sent history. Resume resolves the full retained previous
epoch/session/owner generation/view generation/cut and checks scope, policy and history.
Missing state requires snapshot fallback, never reconstruction from a cursor. These
checks do not provide a checksum against storage/assembly corruption. See the
[encoding and digest disposition](wire.md#broker-encoding-and-digests).

SPDP, path and REGISTER/rejection correlation hashes remain unchanged in purpose;
none authenticates an insecure sender. Historical transaction hash vectors are archived
under `archive/review-baseline/transaction-digests/` and are not draft-3 wire requirements.

<a id="broker-wire-bytes--draft-revision-3-migration"></a>
### Draft revision 3 migration

The magic change rejects draft 1/2 before body decoding. Selected protocol remains
provisional 1.0 and encoding 1; do not accept old layouts under the new magic.
Bootstrap bodies remain mutable. Established Envelope and bodies are final positional
layouts: no DHEADER/member headers, unknown-field skipping or trailing extensions.
A layout change requires a separately negotiated mapping/version. Bootstrap mutable
required-member/duplicate checks and native metadata extensibility remain necessary.

Envelope contains request ID, required features and operation body, in schema order.
Resolve scope/epoch/session/owner generation from a validated endpoint/channel association
and retain them in queued descriptors. Stale endpoints cannot establish a new association;
never fall back to GUID alone. Requests without a logical ID use the specified zero value.

With empty required features, the marker Frame length is 92 + 40*N bytes for N
exceptions. Derive N from the smaller negotiated marker/frame byte cap, not only the
schema exception ceiling. Measured example sizes belong in the evidence inventory.

Final ErrorBody intentionally retains @optional fields. Each has its XCDR2 presence
flag followed by the aligned value when present; no mutable member header is emitted.
The independent present/absent vectors check both layouts. Final schema members carry
no @id or @must_understand annotation, and receive no unknown-member skipping semantics.

<a id="broker-wire-registry"></a>
## Broker wire registry and body mapping

<a id="broker-wire-registry--operation-registry"></a>
### Operation registry

| Draft code | Operation | Body type | Direction |
| --- | --- | --- | --- |
| 4 | ACCEPT | AcceptReply | Broker to client |
| 5 | ORIGIN_BEGIN | InventoryBegin | Client to broker |
| 6 | ORIGIN_RECORD | InventoryRecord | Client to broker |
| 7 | ORIGIN_END | InventoryEnd | Client to broker |
| 8 | MUTATE | Mutation | Client to broker |
| 9 | COMMIT | CommitReply | Broker to client |
| 10 | REJECT | RejectReply | Broker to client |
| 11 | VIEW_REQUEST | ViewRequest | Client to broker |
| 12 | SNAPSHOT_BEGIN | ViewBegin | Broker to client |
| 13 | SNAPSHOT_RECORD | ViewRecord | Broker to client |
| 14 | SNAPSHOT_END | ViewEnd | Broker to client |
| 15 | DELTA | Delta | Broker to client |
| 16 | APPLIED | Applied | Client to broker |
| 17 | VIEW_SYNC | ViewSync | Broker to client |
| 18 | RESYNC_REQUIRED | ResyncRequired | Either admitted peer |
| 19 | LEASE_CHALLENGE | LeaseChallenge | Broker to client |
| 20 | LEASE_PROOF | LeaseProof | Client to broker |
| 33 | FRESHNESS_QUERY | FreshnessQuery | Client to broker, CONTROL |
| 34 | FRESHNESS_MARKER | FreshnessMarker | Broker to client, ordered STATE |
| 25 | CLOSE | CloseRequest | Client to broker |
| 26 | CLOSED | ClosedReply | Broker to client |
| 27 | STATUS | StatusBody | Either admitted peer |
| 28 | ERROR | ErrorBody | Either admitted peer |
| 29 | ADMISSION_REJECT | AdmissionReject | Broker to client, REGISTER rejection only |
| 30 | PATH_CHALLENGE | PathChallenge | Broker to client, unvalidated UDP path |
| 31 | PATH_RESPONSE | PathChallenge (exact echo) | Client to broker |
| 32 | REGISTER | RegisterRequest | Client to broker, validated introduction |

Retired presence opcodes 21/22 are reserved; no chunked presence grammar is supported
in draft revision 3 (`ZZDBRK03`). Codes 4 and 29–32 carry introduction bodies directly in Frame. Retired codes 1–3
are reserved and unsupported. All remaining operations use
the final positional established Envelope and final operation bodies. Bootstrap bodies
remain mutable; final layouts require exact consumption and cannot gain trailing fields
without a negotiated mapping change. [ADMISSION_REJECT](protocol.md#broker-bootstrap-rejection) supplies
bounded preadmission diagnostics; silence remains permitted when reply checks fail.
Established ERROR is never used for bootstrap. Identical REGISTER against a consumed introduction returns its recorded ACCEPT while
the result and session remain valid; first-admission expiry is a separate check. Origin/snapshot items are state traffic; admission,
results, origin leases and status are control traffic. Inventory/snapshot boundaries,
VIEW_SYNC and aggregate freshness markers share ordered STATE with records. Opcode values 23/24 are
reserved and unsupported; no peer-metatraffic forwarding service exists in v1. Priority does not establish cross-stream order.

<a id="broker-wire-registry--other-registries-and-shape-validation"></a>
### Other registries and shape validation

The schema supplies experimental constants for record/change/delta kinds, recovery
actions, failure categories, downstream outcomes, commit kinds, view/profile/channel
classes, service classes, metadata tags, features, removal reasons and informational
status codes. Zero is invalid for a required discriminator; where this draft explicitly
marks a field inapplicable it must be zero/empty rather than carrying unvalidated data.
Unknown codes reject required behavior. Known reserved future features are not thereby
implemented: opaque profile, TypeLookup and Security routes remain unavailable until
negotiated and actually supported.

* COMMIT for inventory uses inventory_generation and zero entity/revision; mutation
  uses entity/revision and zero inventory_generation; CLOSE uses the matching participant
  identity and zero inventory_generation. CLOSED is the normal close response; a peer
  must not require receiving both forms to finish the operation.
* ViewRequest carries a client-assigned, strictly increasing session-local generation
  for every new request. Retries retain generation/request ID/bytes. View-bearing replies
  echo it; the resume cursor identifies the old baseline independently.
* A ViewRequest without resume has an all-zero cursor. With resume it carries the prior
  baseline/cursor and asserts retained state. ACCEPT checks the selected outcome against
  optional resumed_cursor presence. Resolve the full prior epoch/session/owner generation/
  view generation/cut against retained scope, policy and contiguous history; absent state
  requires snapshot fallback. No transaction digest is carried. Current v1 always requires fresh origin inventory.
* DELTA UPSERT carries a complete record matching entity/revision and no removal reason.
  REMOVE/VIEW_WITHDRAW carry no upsert record and an explicit reason. A lease reduction
  carries participant/freshness generation; obtain fresh nonce-bound presence evidence
  before extending validity. Until that evidence arrives, conservatively invalidate the
  prior lease bound rather than infer a new deadline from reception time.
* FreshnessQuery has view generation and nonce; at most one is outstanding per view/session.
  FreshnessMarker has that correlation, exact view frontier, common horizon and bounded
  incarnation-specific exceptions. No chunk index/count, query serial or availability enum.
  Zero exception duration grants no new evidence. Apply after the corresponding STATE cut.
* ErrorBody retry hints apply only to actions permitting retry and never reset deadlines.
  Optional entity/revision fields must be paired when describing a particular mutation.
  StatusBody is informational and never substitutes for COMMIT, APPLIED or freshness.
* Scope uses standard domain ID and exact domain-tag string; no implicit Unicode, case or
  domain normalization is introduced. GUID/nonce/digest arrays are byte strings, not
  host-endian integers. Negative native sequence values are invalid when present;
  absent native sequence fields have canonical zero values.

<a id="broker-wire-registry--record-metadata-encoding-proposal"></a>
### Record metadata encoding proposal

OriginRecord.change_metadata contains a baseline XCDR2 little-endian MetadataList,
without a nested encapsulation header. MetadataEntry holds tag, required flag and
opaque value. Entries sort by numeric tag; baseline tags are singleton and duplicates
reject. Preserve unknown optional entries and their values; unknown required entries
prevent semantic installation. Aggregate encoded metadata must fit the 16 KiB ceiling,
not merely each individual value. The 64-entry limit is an additional bound.

KEY_REPRESENTATION describes the retained key encoding; STATUS_INFO retains original
status bytes; INLINE_QOS retains the original inline ParameterList representation.
Their exact value grammar and feature/endpoint rules are proposed in
[the detailed wire rules](wire.md#broker-wire-details), with golden fixtures. Never reconstruct
raw discovery payloads from these fields or substitute broker expiry reasons for native
status. Empty metadata is an encoded empty list, not an ambiguous arbitrary byte sequence.

<a id="broker-wire-registry--spdp-service-revision"></a>
### SPDP service revision

Provisional optional vendor PIDs: capabilities 0x8004 (canonical full SPDP payload),
directed request 0x8005 and offer 0x8006 (inline QoS only). These follow origin-version
0x8003 and existing locator PIDs 0x8001/0x8002. Parameter values use CDR with the containing
list's byte order and no nested encapsulation. descriptor_version is 1; service kind 1
is broker discovery. Role flags CLIENT=1 and SERVER=2 may combine; other bits reject.
Descriptors are unique by service kind; unsupported service offers do not create sessions.

REGISTER replaces full HELLO/CHALLENGE repetition. Exactly two endpoint pairs remain
CONTROL/STATE. Requested selections must be permitted by both introductions and local
requirements; ACCEPT cannot silently drop selected requirements or change protocol/profile.
Offer/current policy incompatibility requires a fresh attempt. PATH cookies are bounded
at 64 bytes in the new draft, nonempty where used; no cryptographic format is selected.
Validated TCP/protected paths omit this exchange. LegacyHello/LegacyChallenge/LegacyOpenRequest
exist solely for historical fixture comparison and have no active operation codes.

ACCEPT member 23 echoes introduction_id. Its transcript_binding is now the registration
binding below, not the retired HELLO/OPEN hash. ADMISSION_REJECT rejected_operation must
be REGISTER=32; uncorrelatable SPDP/path failures remain bounded silence in initial v1.
The former OPEN rejection vector is explicitly historical and not a valid current reply.

Define H(label, blobs...) as SHA-256 of ASCII label plus one NUL, followed by each blob's
u64 little-endian byte length and exact bytes. Proposed labels:

* `zzdds-broker/client-spdp/v1` and `zzdds-broker/server-spdp/v1`: corresponding original
  encapsulated SPDP payload, excluding submessage/inline-QoS context.
* `zzdds-broker/service-path/v1`: client SPDP payload, two-byte big-endian inline ParameterList
  representation identifier (00 02 or 00 03), and exact ServiceRequestContext parameter value bytes, including terminal padding
  counted by parameterLength (excluding the four-byte PID/length header). Senders use
  zero padding; receivers hash the received bytes, without reserializing the value.
* `zzdds-broker/register/v1`: introduction_id then exact REGISTER Frame.body bytes.
  This is ACCEPT.transcript_binding. Stored introduction state binds both sample digests,
  service context and transport/path identity; the hash alone is not authentication.

PathChallenge.request_digest uses the service-path hash; PATH_RESPONSE echoes its exact
body. The inline representation identifier above is hash context, not an added wire
encapsulation. AdmissionReject retains its rejected-request hash algorithm with opcode 32
and exact REGISTER bytes. Fresh generations of these exchanges require new identifiers;
retired/unknown introduction IDs never reconstruct server state from REGISTER.

<a id="broker-wire-registry--accepted-domain-identity-wire-revision"></a>
### domain identity wire revision

ScopeValue is final XCDR2: string<256> domain_tag, then unsigned long domain_id.
The string length includes the terminating NUL; the bound excludes that terminator.
ServiceRequestContext now ends after client_nonce (36 value bytes in CDR1); scope
comes from the immutable introduced SPDP sample. There is no requested_realm.
SPDP fixtures include standard PID_DOMAIN_ID=0x000f and PID_DOMAIN_TAG=0x4014 in
both byte orders, with identical client/server scope and distinct GUIDs. The path-hash
algorithm remains unchanged, binding that sample and exact inline request bytes.
Because the current request value is aligned already, its fixture has no terminal
padding; padding inclusion remains the general hash rule. Old realm-era hash values
are replaced, not retained as a second supported encoding. No production ABI was frozen.

Revised generated sizes with two endpoint pairs: 8-byte tag/two features/no resume:
REGISTER 380, ACCEPT 476; 256-byte tag/128 features/resume: REGISTER 1240, ACCEPT 1336.
These include Frame encoding, exclude transport/RTPS/security, and are not complete
semantically authorized sessions. Whole-exchange preflight remains mandatory.

<a id="broker-wire-details"></a>
## Broker metadata, negotiation and endpoint

<a id="broker-wire-details--metadata-values"></a>
### Metadata values

The outer MetadataList is XCDR2 little-endian without encapsulation. Each value
below is a byte grammar with no implicit alignment or encapsulation. The surrounding
sequence length supplies its length. Known tags are singleton, ascending, and required
must be true: skipping their meaning could change lifecycle interpretation. Unknown
optional tags remain opaque; unknown required tags prevent installation. Reject wrong
lengths, malformed lists and inconsistent redundant evidence before changing state.

| Tag | Exact value bytes | Meaning |
| --- | --- | --- |
| KEY_REPRESENTATION (1) | Two-byte little-endian discriminator: 1 full data, 2 key-only payload, 3 inline key hash | Describes the retained native discovery sample, not the broker operation |
| STATUS_INFO (2) | Exactly four original StatusInfo octets | No integer byte swapping; preserve all bits |
| INLINE_QOS (3) | One byte byte-order selector (0 big-endian, 1 little-endian), followed immediately by the original ParameterList through its four-byte PID_SENTINEL | No encapsulation or submessage header; selector records source submessage endianness |

INLINE_QOS preserves parameter order, unknown parameters and padding. Parse parameter
headers using its selector, check lengths and sentinel within the enclosing value,
and reject trailing bytes. Do not apply broker little-endian rules to this list.
The original list's first parameter is its alignment origin, despite the one-byte
selector preceding it in the metadata value. The list may contain only the sentinel.

For retained native samples, KEY_REPRESENTATION is mandatory. Full data and key-only
forms retain their original encapsulated discovery payload, whose encoding must agree
with discovery_encoding. Inline-hash form has an empty payload and requires INLINE_QOS
containing exactly one 16-byte PID_KEY_HASH; discovery_encoding remains the applicable
PL_CDR profile, not an encoding of the hash. A hash is not generally reversible: resolve
it against an unambiguous admitted identity or reject; never invent a GUID from a hash.
Full/key-only decoded identity must agree with EntityKey. Key-only/hash-only evidence
cannot install an UPSERT. A broker-native removal without a retained native sample may
have empty payload and empty metadata; its EntityKey/revision is authoritative.

When inline QoS contains PID_STATUS_INFO, STATUS_INFO must also be present and agree
byte-for-byte. STATUS_INFO without INLINE_QOS is allowed for an origin-generated native
status; it must never be synthesized from a broker lease expiry or view withdrawal.
Reject duplicate status/key-hash parameters in this broker profile. Validate native
lifecycle meaning against change_kind; presence of an unknown reserved status bit alone
is not an error. Absence of status does not imply a native dispose. Byte retention is
not a claim that the cached profile can transparently process DDS Security traffic.

RTPS defines StatusInfo as four octets and KeyHash as sixteen octets, and defines
key-only discovery ParameterLists separately from full samples. These rules motivate
keeping original bytes separate from broker lifecycle reasons.
[RTPS 2.5, §§9.6.2.2, 9.6.4.8–9](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

<a id="broker-wire-details--version-and-feature-selection"></a>
### Version and feature selection

Bootstrap Frames always carry header version 1.0 and body encoding 1. SPDP service descriptors' version
ranges negotiate the established protocol, not the bootstrap layout. Thus a future
established minor can be selected without guessing how to parse introduction metadata. Major bootstrap
changes need a separate bootstrap discriminator/magic and are outside this draft.
Select the highest mutually supported major, then highest mutually supported minor,
that satisfies both sides' required behavior and implemented dependencies. Reject
inverted/overlapping ranges and duplicate or unsorted feature IDs. A required feature
must also be offered. Unknown offered features can be omitted; unknown required
features fail negotiation. Selected features must be an implemented, policy-permitted
subset of the offer, contain all requirements, and satisfy the following matrix.

| Feature | Earliest established version | Dependencies / initial availability |
| --- | --- | --- |
| TOPIC_CANDIDATES (1) | 1.0 | CACHED profile; required zzdds-broker capability, negotiated for other implementations |
| DOWNSTREAM_RESUME (2) | 1.0 | CACHED profile, retained baseline and broker history; optional capability |
| TOPIC_PARTITION_CANDIDATES (6) | 1.0 draft revision 3 | Requires TOPIC_CANDIDATES; required when view mode 3 is requested |
| OPAQUE_PEER (3) | Unassigned | Reserved; must not be selected in initial v1 |
| TYPE_LOOKUP_ROUTE (4) | Unassigned | Reserved pending service contract; must not be selected in initial v1 |
| SECURITY_ROUTE (5) | Unassigned | Reserved pending service/security contract; must not be selected in initial v1 |

CACHED, VIEW_ALL, fresh inventory/snapshot recovery, lease/presence proofs are baseline requirements, not opt-out feature bits. A recognized reservation
is not an implemented feature. A cached record may retain type information without
claiming the TypeLookup routing service. No feature implies successful peer reachability.

If the application selected a candidate mode, missing feature 1 (or 6 for mode 3)
fails admission; do not switch to VIEW_ALL. A client configured for ALL needs neither. Without feature 2, omit resume_hint, do not request
resume, and require SNAPSHOT_REQUIRED with no resumed cursor. An optional resume hint
may be declined even when feature 2 is selected. Feature selection never skips fresh
origin inventory. Per-envelope required_features must be a subset of selected features;
operation semantics must also be permitted even when that list is empty. Unnegotiated
operations/features reject without side effects; optional mutable members do not bypass
that rule. Established Envelope Frames use the selected version and encoding. Bootstrap replies
(including retained ACCEPT retries) keep bootstrap version 1.0 and encoding 1. Reconnect
renegotiates; it does not inherit the old session's capability set implicitly.

<a id="broker-wire-details--rtps-endpoint-identities-and-directions"></a>
### RTPS endpoint identities and directions

RTPS reserves entityKind's high bits 01 for vendor-specific entities. This draft uses
vendor no-key writer 0x43 and reader 0x44, and leaves standard SPDP/SEDP endpoint IDs and
BuiltinEndpointSet bits untouched. These are zzdds extension assignments, not OMG
standard broker endpoints. [RTPS 2.5, §9.3.1.2](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

The proposed bootstrap entity key is the three octets 7a 00 01: writer ID 7a 00 01 43,
reader ID 7a 00 01 44. Each side uses its own participant prefix. A configured broker
address may initially have an unknown prefix; directed SPDP starts introduction on
its native endpoint. PATH validation uses the predefined vendor pair and outstanding
attempt correlation. REGISTER targets the broker identity from the validated offer. Replies bind the
observed GUIDs to the challenge/protected admission exchange before trusting them.
Bootstrap uses bounded best-effort DATA and application retries, no DATA_FRAG, and no
pre-admission reliable writer/reader state. This fixed pair serves bootstrap only.

For established traffic, both peers allocate unique local vendor endpoint GUIDs and
exchange them explicitly: REGISTER.control_endpoints supplies the client's endpoints;
ACCEPT.control_endpoints supplies the broker's. Each list has exactly one CONTROL and one STATE pair, in that order. writer_guid sends from the owner of the list;
reader_guid receives at that owner. Connect client writer to broker reader and broker
writer to client reader for each class. Broker STATE writer sends downstream records;
client STATE writer sends origin records. Control carries results and independent requests.
Inventory/snapshot boundaries, records, VIEW_SYNC and freshness markers use STATE;
COMMIT/REJECT, query/lease requests and other independent control use CONTROL.
Both classes use reliable RTPS streams, bounded histories and application recovery;
transport delivery/RTPS ACK is never application COMMIT or APPLIED.

Require GUID prefixes to match their authenticated/validated owning participant,
correct vendor kind octets, and distinct endpoint identities across both pairs.
Reserve the bootstrap key; other entity keys are allocated, not globally assigned.
REGISTER retries reuse the same proposed endpoints and admission attempt. A new attempt
allocates fresh identities (or an explicitly proven quiescent reuse); changing endpoints
changes the protected transcript. ACCEPT duplicates return the recorded assignments.
Fresh RTPS identities prevent an old stream's sequence/ACK state from contaminating a
new session. Delayed application messages still require normal epoch/session fencing.
Resource exhaustion must fail/retry boundedly, never recycle an active identity.

PEER_METATRAFFIC and operation IDs 23/24 are reserved, unsupported in v1. Native WLP
uses direct participant metatraffic locators and retains its normal endpoint identities.
No TypeLookup/Security routing capability is implied. See [relay direction](../concurrency-broker-status.md).

<a id="broker-wire-details--validation-and-remaining-gates"></a>
### Validation and remaining gates

Independent golden fixtures cover a MetadataList with key-only, disposed status and
little-endian inline QoS, plus a big-endian inline QoS variant and bootstrap endpoint
bytes. Generated-code tests check byte agreement; they do not implement the semantic
validation above. Full admission validation, protected transcript/authentication,
participant authentication integration, reliable endpoint lifecycle and bounded native representations
remain implementation/freeze gates. In particular, explicit endpoint offers must be
included in the protected transcript and may not become an arbitrary-address reflector.

Protected admission, exact transcript correlation and recovery after lost ACCEPT are
reviewed in the [admission protection proposal](protocol.md#broker-admission-protection). Its
GUID-based unsecured identity and authenticated live-replacement rules supersede the
earlier stable ownership-secret proposal.

<a id="broker-wire-compatibility-review"></a>
## Broker wire assignment and compatibility review

<a id="broker-wire-compatibility-review--version-boundaries"></a>
### Version boundaries

There are separate version domains: RTPS protocol, service descriptor, bootstrap Frame,
established broker protocol, zzdds release and generated ABI. One cannot stand in for another.

* Service descriptor/context grammar remains descriptor_version=1. Unknown versions must
  not be parsed by guessing the v1 layout. Unsupported service introductions create no
  admission state; normal discovery follows its independent rules.
* All five bootstrap opcodes (ACCEPT, ADMISSION_REJECT, PATH_CHALLENGE, PATH_RESPONSE,
  REGISTER) always use Frame version 1.0 and encoding 1, including result retries after
  admission. REGISTER/ACCEPT body selections describe the established protocol.
* Established Envelopes use exactly the selected version/encoding for that session.
  No per-message renegotiation or optimistic acceptance of a higher minor. Initial
  implementations advertise only 1.0; future versions require actually implemented support.
* Selection must agree with both immutable introductions and policy. Unsupported required
  behavior fails; it never silently downgrades. Reconnect negotiates afresh.
* An incompatible bootstrap grammar needs its own explicitly distinguishable bootstrap
  revision. Changing an established major alone cannot change the fixed bootstrap parser.

<a id="broker-wire-compatibility-review--extension-rules"></a>
### Extension rules

The existing minor-extension rule applies to **mutable** structures, not arbitrary IDL
structures. A new optional mutable member must have safe absence semantics and a new ID;
it cannot smuggle in unnegotiated behavior. Existing IDs keep their types and meanings.
An unknown member with the on-wire must-understand bit set rejects the containing message.
Unknown optional members may be skipped semantically, but retain exact bytes wherever
hashing, duplicate comparison or immutable record forwarding requires them.

Final structures have positional layouts. Do not append fields to Frame, ReceiveLimits,
ScopeValue, ResumeCursor, OriginRecord or other final types and call that a compatible
minor addition. A future feature needing a different shape uses a separately identified
versioned type/body/member under an explicit compatibility rule, or an incompatible major.
Changing descriptor_version likewise needs a defined introduction compatibility path.

Must-understand and required presence are different checks. In this broker profile every
non-optional mutable field must occur exactly once, even if a generated decoder would
supply a zero/default value. Known optional fields occur at most once. Reject duplicate
member IDs, including unknown IDs, within each mutable object; skipping an unknown field
does not permit ambiguous duplicate representations. Validate nested objects as well as
Envelope and Frame. A sender clearing a must-understand bit cannot make a required known
field optional or bypass its semantic validation.

Known-but-reserved values are not ordinary unknown optional extensions. For example,
ACCEPT continuity_credential remains absent in v1 and cannot establish ownership; reserved
features cannot be selected. Unknown offered features may be omitted, but unknown required
features fail. Unknown operations are never acknowledged as applied state or successful
work. Use the operation table's authorized bounded error/recovery rules; do not manufacture
an established ERROR for bootstrap or reply to an unvalidated source.

Native discovery ParameterLists, service CDR1 values, broker XCDR2 mutable members and
opaque metadata tags each retain their own extension/framing rules. Their numeric tags
and must-understand mechanisms are not interchangeable. Bytes retained from native
announcements are not rewritten into the broker's little-endian encoding.

<a id="broker-storage-contract"></a>
## Broker bounded decoding and retained-byte ownership

<a id="broker-storage-contract--representation-decision"></a>
### Representation decision

Use bounded borrowed views to inspect received bytes, then retain only the immutable
bytes and compact validated descriptors required by protocol obligations. The current
generated owning draft types are codec-test artifacts, not the production receive model.
Their inline BoundedArray mapping reserves schema maxima: Frame is at least 1 MiB and
OriginRecord at least 512 KiB, regardless of actual encoded length or negotiated limits.
Moving those types to the heap alone does not solve per-message footprint or copy costs.

Keep the IDL bounds as wire ceilings. Production descriptors contain scalars, bounded
small metadata and slices/offsets backed by explicitly owned storage. Neither stack size
nor one queue slot may scale with the schema's largest octet sequence. Platform limits
may be lower; support for the full schema maximum is not an embedded build requirement.

Prefer generic zidl support for checked borrowed decoding and bounded allocator-backed
owning mappings, preserving schema bounds, over broker-specific copies of the generated
schema. The concrete generator API is an implementation choice, not a new wire feature
or binding ABI requirement. Do not silently change existing zidl mappings for all users.
Small current generated types remain usable where their measured storage and validation
properties fit. A broker validation layer still enforces phase, scope and state semantics.

<a id="broker-storage-contract--receive-stages"></a>
### Receive stages

1. Enforce transport frame/datagram and outstanding-input limits before allocation. TCP
   length prefixes cannot authorize arbitrary buffering; reserve bounded space before
   accumulating an incomplete message and impose its deadline. Established RTPS fragment
   reassembly has separate byte/count/deadline accounting. Bootstrap never reassembles.
2. Validate RTPS framing and effective source/destination/path context. Locate a complete
   serialized sample under existing input ownership; broker Frame preflight checks its
   exact length, encapsulation, padding, version, opcode and encoding without decoding
   a maximum-sized owning Frame.
3. Decode through bounded sub-readers: Frame body, final positional Envelope, operation body and
   record bytes each respect their declared extent and alignment origin. Typed nested
   fields retain their specified containing-stream alignment. Checked subtraction and
   conversion precede slicing, allocation and multiplication by element sizes.
4. Validate mutable bootstrap member presence/uniqueness and unknown-required members;
   validate exact positional extent for established bodies. Validate all nested bounds, discriminators
   and exact consumption. Bound both memory and work: maximum encoded input plus finite
   nesting/element/member counts must bound parsing. Unknown optional members are skipped
   without allocating their declared lengths, while their raw bytes remain available where
   required. A fixed member table overflowing is a failure, not permission to stop checking.
5. Apply the operation table's scope/session/generation/feature and semantic checks. Reserve
   descriptors, retained bytes, indexing and mandatory outcome/cleanup capacity before
   accepting effects. Parsing success alone does not install a participant or acknowledge
   application completion. Recheck ownership at the ordered commit point.
6. If work must outlive the receive call, acquire durable ownership or copy the required
   immutable range into a reserved buffer before enqueueing. Allocation/validation failure
   releases provisional reservations and follows the specified bounded failure/recovery
   path. No partially installed record or borrowed stack view escapes.

A complete protected/reassembled sample may require a contiguous provider buffer. This
contract permits that bounded allocation; it does not require zero-copy across encryption,
fragmentation or network APIs. It forbids uncontrolled duplication through nested codecs.

<a id="broker-storage-contract--ownership-and-retention"></a>
### Ownership and retention

| Data | Retention rule |
| --- | --- |
| Receive view | Valid only while its input buffer and parameter scratch are owned; contains no promise of transport-buffer lifetime |
| Pending UDP challenge | Retain the client introduction evidence required by the path-provider contract before challenge issue; a digest alone cannot recover it |
| Validated introduction/REGISTER result | Retain immutable samples/context or allowed descriptors plus exact evidence, and exact retry-comparison material through their separate deadlines |
| Origin/view record | Retain exact record_bytes and the native payload/metadata ranges within them; never hash a regenerated projection |
| Installed discovery indexes | Compact validated descriptors referencing immutable backing or independent bounded copies; unknown optional source content stays available when forwarding requires it |
| Queued/reliable output | Own referenced bytes until encoding/send completion and applicable reliability/retry obligations finish; a local send completion is not application COMMIT/APPLIED |
| Callback/status delivery | Follow the existing listener/output ownership contract; do not expose internal receive views as new public loans |

A retained buffer owner is distinct from a participant/session's authority token. Holding
bytes alive cannot keep a retired registration authorized. Every queued effect carries the
session/generation fence; retirement removes authority first and frees storage only after
its last reference and protocol obligation end. Reference handling must work in both
manual and hosted runtimes and must not invoke application callbacks from reclamation.

Pinning a receive buffer is allowed only if the transport explicitly supports it and its
pool occupancy is charged. Charge the full backing allocation, not merely the retained
slice length; otherwise a tiny retained field could pin a large frame outside the budget.
Prefer a compact copy for long-lived small records when pinning would exhaust ingress.
If one frame backs several records, charge that backing once and separately charge each
index/reference. Releasing one slice cannot release storage still used by another.

A send builder may borrow payload slices synchronously; asynchronous transport use needs
an owner lasting through completion. Shared bytes may be referenced by installed state,
retry history and output simultaneously. Logical obligations each count against their
own limits even when physical byte storage is shared. Sharing is an optimization, not
an excuse to omit worst-case capacity planning or required independent lifetime fencing.

<a id="broker-storage-contract--resource-accounting-and-progress"></a>
### Resource accounting and progress

Wire ReceiveLimits count serialized protocol quantities; local capacity counts actual
backing allocations, allocator/pool overhead, descriptors, indexes, queues, fragment state
and control/retirement reserves. Advertising a frame maximum does not promise that every
maximum can be received concurrently. Derive limits from a feasible plan and enforce both
per-item and aggregate budgets; peer proposals can only reduce local allowances.

The implementation must account for overlap: installed view plus staged replacement,
retained retry results plus in-flight output, pending/consumed cookies, and decoding scratch
plus durable copies during promotion. Reserve the overlap before copying or publishing.
A copy-and-release optimization temporarily costs both buffers. Credits transfer explicitly
between owners and are released once; accounting cannot disappear merely because a
reference crosses a runtime queue or protocol phase.

Preserve bounded control/retirement capacity when record budgets are full. Reliable RTPS
receipt must not become ACK-and-forget of an application-required record: if durable
retention fails after transport delivery, take the defined explicit rejection or session/
view recovery path. Do not advance COMMIT/APPLIED/readiness past missing state. Old valid
installed state remains intact until its replacement commits or its own validity ends.
These rules require no new resource-plan getter, six-knob API or per-message allocation
callback; those proposals remain deferred.

<a id="broker-encoding-and-digests"></a>
## Established encoding and transaction digest disposition

<a id="broker-encoding-and-digests--decision-and-compatibility-cost"></a>
### Decision and compatibility cost

Draft 3 uses final positional encoding for established Envelope and operation bodies. Those peers already negotiate the exact established version/encoding;
freeze each final layout within that mapping. No opportunistic trailing fields and no
silent reinterpretation of later versions. New fields require a separately negotiated
mapping/version or an explicit bounded extension container with its own defined semantics.
Do not claim final types provide transparent minor-version field evolution.

Retain mutable bootstrap bodies for REGISTER/ACCEPT/PATH/rejection: introduction grammar
and optional negotiated offers have a separate evolution boundary. Keep its strict
required/unique member validation and unknown-required handling. The reduction in mutable
established types does not eliminate that generator/validator requirement. Native discovery
ParameterLists and opaque record metadata retain their original extensibility rules.

Appendable saves most mutable overhead but introduces another trailing-extension policy
and DHEADER without solving arbitrary semantic compatibility. With exact established
negotiation, final is the smaller/simpler initial contract. We can add an explicitly
negotiated appendable mapping later if a concrete evolution need justifies it.

Retain one outer checked Frame wrapper, including magic, for bootstrap and established
traffic. Removing it is a separate parser distinction with small relative savings; no need
to couple that change to this revision. Signal the incompatible draft clearly. Bind
scope/epoch/session/generation from the validated transport/endpoint association to every
internal descriptor before dispatch, as in draft 2.

<a id="broker-encoding-and-digests--resume-identity-safety"></a>
### Resume identity safety

Resolve a cursor only against an existing retained baseline identified by previous broker
epoch, session, owner generation, view generation and snapshot cut. Validate original scope,
filter/policy compatibility and the actual contiguous delivery history. Unknown/retired
identity falls back to a fresh snapshot; neither a guessed cut nor a client assertion
creates a baseline. Two views at one global cut are not interchangeable. A new session's
view generation is distinct from the old cursor generation. Apply acknowledgements only
to their currently bound session/view. Removal of digests must not relax any of these rules.

<a id="broker-encoding-and-digests--hashes-and-bytes-that-remain"></a>
### Hashes and bytes that remain

Keep client/server SPDP, path-request and REGISTER/rejection correlation hashes. Their
fixed-size correlation purpose and raw-byte binding are separate from full inventory
assembly. They remain hashes, not authentication. SHA-256 code does not disappear from a
broker build merely because transaction hashing is removed; the expected saving is repeated
snapshot/inventory byte processing and message fields, not the entire crypto footprint.

Keep original raw record bytes and unknown optional native metadata. Exact duplicate
comparison must not become a comparison of reserialized projections or just record counts.
Origin revision conflict detection is independent of transaction digests and remains intact.
