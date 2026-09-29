> Historical source snapshot, superseded by the consolidated contracts.
> Unaccepted alternatives and old completion statements below are not current policy.

# Broker wire draft registry and body mapping

Domain identity revision (2026-09-18): the accepted [standard domain identity decision](broker-domain-identity.md)
replaces broker realm with RTPS domain ID/tag. The experimental schema/fixtures now use the standard string representation.
Earlier realm-specific prose remains superseded; this is not a wire freeze.

Status: experimental assignments for codec/specification review, 2026-09-17.
Not production identifiers or an OMG allocation. The IDL constants are the single
numeric source for this draft; assignments must be reviewed before wire freeze.
No RTPS entity IDs, magic bytes or public service port are allocated by this table.

## Operation registry

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
without a negotiated mapping change. [ADMISSION_REJECT](broker-bootstrap-rejection.md) supplies
bounded preadmission diagnostics; silence remains permitted when reply checks fail.
Established ERROR is never used for bootstrap. Identical REGISTER against a consumed introduction returns its recorded ACCEPT while
the result and session remain valid; first-admission expiry is a separate check. Origin/snapshot items are state traffic; admission,
results, origin leases and status are control traffic. Inventory/snapshot boundaries,
VIEW_SYNC and aggregate freshness markers share ordered STATE with records. Opcode values 23/24 are
reserved and unsupported; no peer-metatraffic forwarding service exists in v1. Priority does not establish cross-stream order.

## Other registries and shape validation

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

## Record metadata encoding proposal

OriginRecord.change_metadata contains a baseline XCDR2 little-endian MetadataList,
without a nested encapsulation header. MetadataEntry holds tag, required flag and
opaque value. Entries sort by numeric tag; baseline tags are singleton and duplicates
reject. Preserve unknown optional entries and their values; unknown required entries
prevent semantic installation. Aggregate encoded metadata must fit the 16 KiB ceiling,
not merely each individual value. The 64-entry limit is an additional bound.

KEY_REPRESENTATION describes the retained key encoding; STATUS_INFO retains original
status bytes; INLINE_QOS retains the original inline ParameterList representation.
Their exact value grammar and feature/endpoint rules are proposed in
[the detailed wire rules](broker-wire-details.md), with golden fixtures. Never reconstruct
raw discovery payloads from these fields or substitute broker expiry reasons for native
status. Empty metadata is an encoded empty list, not an ambiguous arbitrary byte sequence.

## Remaining physical assignments

Frame magic, encapsulation/body encoding IDs and correlation hashes now have concrete
proposals and golden evidence in [the byte baseline](broker-wire-bytes.md).
Metadata values, feature/version rules and vendor endpoint roles now have concrete
proposals in [the detailed wire rules](broker-wire-details.md). Protected transcript/
continuity-credential integration and semantic admission validation remain freeze work.
All 27 active operations now have body types, but a complete type inventory is not proof
that their cross-message state machine or security is implemented.

The generated Zig backend currently represents bounded sequences as inline BoundedArray
storage. Schema ceilings therefore become large native objects, including about 1 MiB
for Frame and at least 512 KiB for OriginRecord. Production must use bounded allocated
or borrowed/streamed representations, or a suitable generic generator mapping, before
claiming embedded suitability or allocating one such object per queued message. Lower
negotiated payload limits alone do not shrink these generated types. Wire limits and
native allocation strategy must remain separate. The [storage contract](broker-storage-contract.md)
now fixes the production direction and generator/integration acceptance requirements.

RESYNC_REQUIRED uses the restricted reasons and direction-specific retry rules in
[the accepted view contract](broker-view-correlation.md); invalidation never creates a
successor view without a newer client request.

ReceiveLimits replaces four presence fields with maximum_freshness_exceptions and
maximum_freshness_marker_bytes (complete serialized Frame bytes, including Envelope).
Both effective limits must fit the session's ordinary frame/resource limits; Xmax may be
zero, selecting a common minimum horizon with no exceptions. The schema ceiling is 256,
not a requirement to advertise or allocate that many entries. Orphan budgets remain only
for bounded preconfirmation/cross-stream handling, not record-before-BEGIN within STATE.

Envelope member IDs 1–4 are retired. Required member IDs 5/6/7 remain request_id,
required_features and operation_body. The validated endpoint/channel association supplies
scope/epoch/session/owner generation to every internal admitted-work descriptor. Reject
retired members in this profile, including when sent without must-understand; do not
accept a peer's copies as alternate authority. Unknown optional new IDs retain normal rules.

Feature 6 and view mode 3 denote topic-plus-partition candidates; feature 6 depends on
feature 1 and is implemented by the zzdds broker. Required filtering never falls back to
VIEW_ALL. Features 3–5 remain reserved. See broker-security-and-filtering.md for scope.

Native discovery extension: provisional PID_ZZDDS_ORIGIN_VERSION = 0x8003, a 24-byte
incarnation/revision value, scoped to the zzdds vendor/profile. See [origin-version wire](broker-origin-version-wire.md)
for full-payload versus inline key-only placement. This remains distinct from broker
operation/member IDs and is not emitted by production discovery yet.


## SPDP service revision (2026-09-18)

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

Twenty independent service fixtures now cover native CDR1 values in both byte orders,
structural payload/inline ParameterLists, and sample/path hashes. The 20-test codec
suite checks generated CDR1 values and those hashes, including padding sensitivity.
These are structural SPDP fixtures, not complete semantically valid announcements.
Eight additional independent vectors check REGISTER, ACCEPT and current rejection bytes
and their exact-request hashes, including introduction-ID and encapsulation sensitivity. No
production SPDP association, path validation or service authorization is implemented.

## Accepted domain identity wire revision

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

## Assignment review checkpoint

The [2026-09-24 compatibility review](broker-wire-compatibility-review.md) retains these
assignments and records the bootstrap/version/final-layout rules. The mechanical checker
passes; this does not freeze the wire or certify production parser/allocator behavior.
