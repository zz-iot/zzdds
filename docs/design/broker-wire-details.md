# Broker metadata, negotiation and endpoint draft

Status: proposed v1.0 assignments, 2026-09-17; not a frozen wire protocol.
This supplements the [registry](broker-wire-registry.md) and
[byte baseline](broker-wire-bytes.md). Constants remain in the
[experimental IDL](schema/broker-control-draft.idl).

## Metadata values

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

## Version and feature selection

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
| TOPIC_CANDIDATES (1) | 1.0 | CACHED profile; optional implementation capability |
| DOWNSTREAM_RESUME (2) | 1.0 | CACHED profile, retained baseline and broker history; optional capability |
| OPAQUE_PEER (3) | Unassigned | Reserved; must not be selected in initial v1 |
| TYPE_LOOKUP_ROUTE (4) | Unassigned | Reserved pending service contract; must not be selected in initial v1 |
| SECURITY_ROUTE (5) | Unassigned | Reserved pending service/security contract; must not be selected in initial v1 |

CACHED, VIEW_ALL, fresh inventory/snapshot recovery, lease/presence proofs are baseline requirements, not opt-out feature bits. A recognized reservation
is not an implemented feature. A cached record may retain type information without
claiming the TypeLookup routing service. No feature implies successful peer reachability.

Without feature 1, request VIEW_ALL. Without feature 2, omit resume_hint, do not request
resume, and require SNAPSHOT_REQUIRED with no resumed cursor. An optional resume hint
may be declined even when feature 2 is selected. Feature selection never skips fresh
origin inventory. Per-envelope required_features must be a subset of selected features;
operation semantics must also be permitted even when that list is empty. Unnegotiated
operations/features reject without side effects; optional mutable members do not bypass
that rule. Established Envelope Frames use the selected version and encoding. Bootstrap replies
(including retained ACCEPT retries) keep bootstrap version 1.0 and encoding 1. Reconnect
renegotiates; it does not inherit the old session's capability set implicitly.

## RTPS endpoint identities and directions

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
client STATE writer sends origin records. Control carries boundaries and results.
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
No TypeLookup/Security routing capability is implied. See [relay direction](broker-relay-direction.md).

## Validation and remaining gates

Independent golden fixtures cover a MetadataList with key-only, disposed status and
little-endian inline QoS, plus a big-endian inline QoS variant and bootstrap endpoint
bytes. Generated-code tests check byte agreement; they do not implement the semantic
validation above. Full admission validation, protected transcript/authentication,
participant authentication integration, reliable endpoint lifecycle and bounded native representations
remain implementation/freeze gates. In particular, explicit endpoint offers must be
included in the protected transcript and may not become an arbitrary-address reflector.


Protected admission, exact transcript correlation and recovery after lost ACCEPT are
reviewed in the [admission protection proposal](broker-admission-protection.md). Its
GUID-based unsecured identity and authenticated live-replacement rules supersede the
earlier stable ownership-secret proposal.
