> Historical source snapshot, superseded by the consolidated contracts.
> Unaccepted alternatives and old completion statements below are not current policy.

# Broker control schema and wire compatibility

Current reading order and precedence: [implementer guide](broker-spec-guide.md).
Active bootstrap is SPDP introduction, optional PATH validation, REGISTER and ACCEPT;
legacy handshake types are historical only. This contract is not a wire freeze.

Status: proposed protocol contract, 2026-09-17. Complements discovery-broker.md
revision 0.2 and its accepted readiness policy. Not a wire freeze. The accompanying
[schema draft](../../schema/broker-control-draft.idl) is a generator-checked design artifact,
not a production IDL module. All 27 active operations now have draft body types;
[the registry](broker-wire-registry.md) maps them and records remaining assignments.

The [recovery review](broker-wire-review.md) R1–R5 corrections are accepted (2026-09-17):
expiry versus terminal close, idempotent admission, fresh origin inventory with independent
downstream resume, uncertain commits and bounded pre-BEGIN staging. Framing bytes, numeric
registries and codec validation still require wire-freeze review.

The [byte baseline](broker-wire-bytes.md) now supplies concrete draft Frame magic,
encapsulation, alignment/padding, encoding IDs and correlation hashes, checked against
independent golden fixtures. It supersedes the placeholder assignments below without
freezing production compatibility. The [metadata, feature and endpoint draft](broker-wire-details.md)
adds exact metadata values, version gates and bidirectional endpoint offers.

## Framing and version selection

Use RTPS DATA/DATA_FRAG for serialized control samples on explicitly assigned broker
endpoints. Preserve the existing TCP transport length prefix. There is no extra TCP
stream delimiter, native SEDP identity reuse or bootstrap dependency on TypeLookup.

Recommend a fixed Frame containing magic, protocol major/minor, operation code,
encoding identifier and bounded body bytes. The bootstrap framing/encoding is invariant
across negotiations; its proposed magic, encapsulation and numeric encoding assignments
are covered by the byte-baseline fixtures. The body contains a versioned Envelope and
operation-specific body. Both established body layers use XCDR2 little-endian final positional structs;
the fixed Frame/common final structs use the corresponding fixed encoding rules.
Generated serialize methods and the containing encapsulation must agree explicitly;
do not insert a new encapsulation at every nested struct boundary.

The sample's bounded frame can be checked before interpreting evolving fields. SPDP
service descriptors advertise supported versions; REGISTER selects from both introductions. Select the highest minor
in a mutually supported major for which all required features are available. ACCEPT
identifies the one selected version/feature set. After acceptance every message must
match it; no per-message downgrade or opportunistic encoding switch. No common version
fails admission. An incompatible fixed bootstrap is dropped/diagnosed within the
pre-admission response budget, not decoded using a guessed layout.

SPDP service descriptors offer capabilities; REGISTER binds its selections to a
validated introduction; ACCEPT confirms the exact registration digest. Bind these values to the admitted association. Return-path cookies are server-generated
opaque tokens, not authentication. V1 is insecure; future protected admission derives
from DDS Security as specified in [the security disposition](broker-security-and-filtering.md).

Bootstrap evolution may add optional members to mutable types with safe absence defaults, negotiated features
and new operations used only after negotiation. Never reuse a member/operation/feature
ID or change an existing member's type, ownership or meaning within a major. Required
new behavior needs negotiation; an incompatible baseline change needs a new major.
Final positional layouts cannot be extended by simply appending members. See the
[compatibility review](broker-wire-compatibility-review.md) for separate bootstrap,
descriptor and established-version rules. The protocol major is independent of zzdds
release number and generated C ABI version.

In mutable bootstrap bodies, unknown optional members may be skipped; unknown must-understand members or required
features reject the message. Unknown operation codes never count as an applied delta
or successful mutation. Return bounded UNSUPPORTED when authorized; invalidate a view
if its required stream cannot be interpreted. Do not silently skip holes in state.

## Envelope and decoding boundaries

Draft revision 3 established Envelopes carry request ID, required features and operation
body. Scope, epoch, session ID and owner generation are resolved from the validated
endpoint/channel association and retained in internal work descriptors. Traditional-mode
binding is not authentication; future secure mode additionally binds authenticated context. Validate all fencing values before mutation, lease
renewal or discovery-state changes. Request IDs identify logical operations; responses carry
an explicit related request. Repeated messages keep their logical request identity.

PATH_CHALLENGE/PATH_RESPONSE/REGISTER/ACCEPT/ADMISSION_REJECT use bootstrap-specific bodies before an admitted Envelope exists;
unused established-session fields are not fabricated as authority. Define phase-specific
body types rather than allowing missing session fields on arbitrary post-admission work.

The IDL bounds are provisional schema ceilings (body 1 MiB, discovery payload 512 KiB,
metadata 16 KiB, 128 features and 256 freshness exceptions), not measured defaults.
Negotiation imposes lower per-message and aggregate limits. Account for nested envelope
and encoding overhead: an inner body fitting its bound need not fit the outer frame.
Before path validation, use the separate small, non-fragmented bootstrap budget and
anti-amplification limit; never allocate a 1 MiB frame simply because IDL permits one.

Perform bounds/overflow/fragment accounting before allocation. Validate required-member
presence, uniqueness, discriminator/body agreement, exact body consumption and permitted
phase. Reject duplicate singleton members rather than let later values overwrite earlier
security/fencing fields. Generated deserialization is not this admission validator.

Local source inspection: zidl emits unknown must-understand rejection for mutable
structs, but the inspected member-switch loop does not itself track duplicate/required
member presence. The broker needs that validation or a generic generator improvement
before untrusted network use. No public DDS ReturnCode is used as the wire error enum.

## Message body inventory

The following table defines required semantic fields; numeric IDs and complete typed
bodies remain a freeze deliverable. Every count/byte limit is checked against negotiated
ceilings and every duration is finite unless its operation explicitly permits otherwise.
Names in parentheses denote correlation, not an additional network protocol.

| Message | Body fields / result boundary |
| --- | --- |
| PATH_CHALLENGE / PATH_RESPONSE | Attempt/nonce, exact request digest and bounded cookie; response echoes challenge body unchanged; omitted on an already validated path |
| REGISTER | Introduction ID, attempt/nonce, domain scope/incarnation, selected protocol/features/profile, limits/lease/view, endpoint pairs and optional resume hint |
| ACCEPT | Selected version/features/limits, epoch/session/owner generation, negotiated lease/renewal margins, control/state endpoint identities, origin-inventory-required flag, independent downstream resume result/cursor and optional bounded continuity credential |
| ADMISSION_REJECT | Attempt, nonce, rejected REGISTER operation, restricted reason, bounded retry hint and exact request digest; direct bootstrap body, no Envelope |
| ORIGIN_BEGIN | Inventory generation, local inventory cut, expected record count and total record bytes |
| ORIGIN_RECORD | Inventory generation, zero-based item index, immutable serialized OriginRecord bytes |
| ORIGIN_END | Inventory generation, final count; exact complete indexed assembly required at ordered END |
| MUTATE | Serialized OriginRecord and request identity; origin revision governs idempotence |
| COMMIT | Related request, commit kind (inventory/mutation/close), inventory generation or entity/revision, store cut and outcome; confirms store installation, not disk durability |
| REJECT | Related request, affected inventory/entity/revision, error code and recovery action; cannot contradict an already committed result |
| VIEW_REQUEST | Client-assigned session-local view generation, view mode/options, explicit fresh versus resume request, and prior epoch/view/cursor proof if resuming |
| SNAPSHOT_BEGIN | View generation, store cut, record count and total bytes |
| SNAPSHOT_RECORD | View generation/cut, item index and serialized OriginRecord bytes |
| SNAPSHOT_END | View generation/cut, count and fixed ready-through delivery sequence |
| DELTA | View generation, contiguous delivery sequence, change kind, entity key/revision, freshness generation when relevant, optional record bytes; explicit removal/withdrawal reason |
| APPLIED | View generation, installed snapshot cut and highest contiguous installed delta sequence; independent of callback completion |
| VIEW_SYNC | View generation and fixed ready-through delivery sequence for a resumed stream without a new snapshot |
| RESYNC_REQUIRED | Either direction: affected view generation, restricted reason and bounded retry hint (zero from client); invalidates old staging/cursor |
| LEASE_CHALLENGE / LEASE_PROOF | Origin nonce and correlation under epoch/session/owner generation; deadline stays on server, no foreign absolute timestamp is compared |
| FRESHNESS_QUERY | Current view generation and fresh observer nonce; one logical submission on reliable CONTROL |
| FRESHNESS_MARKER | Nonce/view, exact ordered STATE frontier, common remaining horizon and bounded incarnation-specific exceptions; zero grants no new validity |
| CLOSE / CLOSED | Participant incarnation, close request and acknowledged fencing/store outcome; local teardown never waits indefinitely for the reply |
| STATUS / ERROR | Related operation/generation, machine-readable category/recovery action; optional bounded diagnostic metadata, never an authoritative replacement for COMMIT/APPLIED |

ORIGIN_RECORD and SNAPSHOT_RECORD are distinct operations, even if implementation
shares a RecordItem codec. Presence exchange and VIEW_SYNC make explicit operations
missing from the original high-level list. No registration-barrier operation is added.

The active IDL includes service descriptors/context, PATH validation and REGISTER/ACCEPT,
shared limits and a resume cursor. LegacyHello/LegacyChallenge/LegacyOpenRequest are
historical experiment types with reserved, inactive opcodes. Enforce introduction/sample/
selection agreement; reject duplicate ranges/features, invalid limits or outcomes, and
a resumed cursor when snapshot is required (or its absence on resume acceptance).
`origin_inventory_required` must be true for a newly admitted v1 session. `baseline_retained`
is a client obligation, not proof that the broker still has the corresponding history.
Bootstrap size/anti-amplification limits apply to the actual encoded sample even when
individual field values fit their IDL ceilings. ACCEPT uses the authenticated bootstrap
binding because the receiver does not yet know the admitted Envelope identity.

## Record bytes and transaction ordering

OriginRecord contains participant/incarnation, kind and entity GUID, origin revision,
UPSERT/REMOVE, source encoding/protocol/vendor identity, optional native writer sequence,
change metadata and untouched discovery payload. Native sequence absence is explicit;
zero is not a fabricated native sequence. Entity ownership and record-kind constraints
are validated independently of successfully decoding the payload.

Keep the final OriginRecord baseline layout stable within a major. Its bounded metadata
carries key representation, dispose/unregister/inline-QoS information and future optional
record metadata under registered length-delimited tags. Tag encoding, must-understand
rules and assignments are defined in the current metadata/registry draft; raw discovery bytes are not
rewritten into those tags. Unknown optional metadata remains retained byte-for-byte.
Never use the same tag for a broker withdrawal reason and an origin DDS dispose.

Do not compute transaction digests in draft 3. Validate indexed assembly, exact bytes,
counts and bounds; retain assigned retry bytes. APPLIED binds the currently admitted
session/view and retained snapshot cut. Resume must resolve the full previous
epoch/session/owner generation/view generation/cut against retained scope, policy and
contiguous history; an unknown identity requires snapshot fallback. Equal cuts alone do
not identify equal views. These checks intentionally do not replace a content checksum.
See [the digest disposition](broker-encoding-and-digests.md) for costs and bounded tests.

Participant records precede dependent endpoints. Within each class sort by participant
GUID, incarnation bytes, record kind and entity GUID (unsigned byte/integer order).
Reject duplicate entity keys. A downstream snapshot may be empty; an origin inventory
contains exactly one participant record and zero or more endpoint records. Item indices must cover exactly
[0, count); same-index identical retransmissions are harmless, conflicts invalidate
the transaction. Sum lengths with checked arithmetic and match the declared byte total.

V1 clients wait for the matching inventory COMMIT before sending post-cut MUTATE.
Same-session replacement first resolves outstanding transmitted mutations; otherwise use
new-session recovery. The [inventory barrier](broker-inventory-barrier.md) defines local
buffering and the future negotiated pipelining extension.

Origin mutation retries preserve the same stored record bytes and revision. A changed
record at the same revision is a conflict. A control-envelope minor change does not
change the major's OriginRecord baseline serialization; do not create artificial revision
conflicts by re-encoding retries differently after negotiation.

Control and STATE writers retain independent sequence spaces, but transaction boundaries
and records share STATE. Reject RECORD before its BEGIN or END with an incomplete indexed
set; there is no intra-STATE orphan assembly or cross-stream excuse for those sequences.
Only preconfirmation CONTROL-versus-STATE staging remains bounded as specified by bootstrap
lifecycle. On deadline/capacity failure, abort the transaction and require explicit recovery.
Do not ACK-and-discard application staging expecting transport repair; reserve failure
notification capacity independently, or fail the session when safe recovery cannot be kept.
Likewise COMMIT must not advance local pending state for a different inventory request.
Per-stream RTPS ACK does not join these application-level dependencies.

View generation is assigned by the client in VIEW_REQUEST, echoed by all view-bearing
responses, and monotonically increases for new requests within a session. ACCEPT does
not start view output before VIEW_REQUEST. Resume preserves its prior baseline/sequence
position but rebinds output to the new request generation. Bidirectional RESYNC_REQUIRED
invalidates only its named generation; see [view correlation](broker-view-correlation.md).

A fresh snapshot view starts delta sequence at 1; snapshot baseline is sequence 0. Buffer deltas
while staging. SNAPSHOT_END captures a finite ready-through sequence when formed; READY
requires installation through it, not a moving target. A resume uses VIEW_SYNC's target.
APPLIED cannot acknowledge uninstalled records or exceed sent history. Retain unacknowledged
required deltas or invalidate the view; never replace them with an RTPS GAP alone.
VIEW_WITHDRAW changes view membership without inventing a newer origin revision.

## Recovery and bounded idempotence

Every newly admitted transport session obtains fresh session identity and owner fencing.
Unsecured identity is the participant GUID; no persistent ownership secret is required.
DDS Security authentication, where configured, supplies participant authentication through
its plugins. V1 has no broker authentication provider; future secure admission follows the DDS Security
contract, with optional transport security as a separate later choice.

Confirmed disconnect withdraws registration and endpoints promptly; silent failure/UDP
absence uses finite detection or lease deadlines. Expiry/disconnect is not terminal
participant CLOSE. A still-live participant may register again with fresh inventory and
proof. Explicit CLOSE fences the registration and its derived work. After all retained
obligations retire, the registration can be forgotten and a fresh admission may use the
same identity. This is not an epoch-long identity ban.

Admission serializes by scope/GUID. A new binding competing with a still-live registration
must wait for closure/expiry unless authenticated continuity explicitly permits replacement.
Different incarnation IDs do not bypass a duplicate-GUID conflict. Shared credentials,
source addresses and a certificate alone are insufficient for secure live replacement.

Identical REGISTER against the same live consumed introduction on the same binding returns its retained ACCEPT without new generations
or lease renewal. New bindings use new attempts. Lost ACCEPT may therefore delay unsecured
reconnect until the old registration closes or its finite establishment deadline expires.
Do not reexecute expired attempts or replay successful outcomes after fencing/revocation.
Retain bounded replay protection; delayed old-session cleanup must not delete a successor.
See the [admission policy](broker-admission-protection.md) for exact boundaries.

Every new session uploads a fresh origin inventory in v1, even if its downstream view
resumes. Preserve still-valid old inventory while atomically staging replacement; expired
inventory stays withdrawn until fresh activation. Preserve entity revision high-water
marks and buffer post-cut mutations. Do not bump revisions merely because a COMMIT reply
was lost. Fencing and store commit serialize: old commits before handoff can be included
in repair; old attempts after handoff cannot commit.

Downstream resume independently requires unchanged epoch/view configuration and scope
authorization, an actually retained client baseline and adequate broker delta history.
A cursor without its baseline is insufficient. Reclaimed baseline means fresh snapshot;
retained inactive records still need fresh proof before activation. Conservatively replay
retained deltas when APPLIED was lost. Accept a higher client cursor only if bounded by
that view's actually sent history and validated recovery state, never by guessing.
ACCEPT reports origin-inventory-required separately from downstream snapshot/resume;
readiness requires both synchronization targets plus fresh evidence. Old session traffic
and old presence proofs cannot acquire the new session's authority.

A new epoch always invalidates old resume cursors. Revision high-water marks and
incarnation rules prevent resurrection within an epoch; full inventory/freshness evidence
re-establishes state after restart. Do not infer fresh presence from successful resume.
Presence proofs from old sessions/views/nonces cannot activate or renew records.

Bound request-result retention by negotiated session/retry windows. While a result is
retained, duplicate request/body returns the same result; conflicting body is rejected.
After that window, do not guess whether a mutation committed or replay side effects:
use entity revision/high-water state when it establishes the answer, otherwise require
inventory repair. CLOSE is idempotent for its fenced incarnation. Snapshot loss never
requires resurrecting deleted local entities to repair the graph.

Wire errors identify both category and allowed recovery: retry same request after a
bounded hint, re-register inventory, resync view, revalidate path, or terminal/configuration
correction. Receivers enforce the state machine instead of blindly following a peer's
retry hint. Error reports cannot extend lease deadlines or reset an application's wait
budget. Route failures and transient disconnect do not retroactively undo local DDS work.

## Freeze gates and validation

The [consolidated checklist](broker-implementation-checklist.md) separates remaining
specification work W1–W5 from implementation/release evidence I1–I7. All 27 active operation
bodies and provisional assignments now exist. Complete semantic validation, retention,
endpoint/bootstrap lifecycle and compatibility review before wire freeze; body coverage
and golden encoding agreement alone are insufficient.

The schema draft now generates and compiles with local zidl after a narrow generator
fix for allocator forwarding in bounded sequences of structs. The
[codec fixture](../../probes/broker_wire_codec.zig) initially passed six checks: ACCEPT recovery fields,
snapshot-end roundtrip/truncation, synthetic future optional/required members, missing/
duplicate member characterization, inline storage footprint and populated presence-entry
sequence decoding. Run [the script](../../probes/run_broker_wire_codec.sh) with ZIDL_EXE and
ZIG_EXE set. Generated artifacts are temporary; no production protocol is installed.

The malformed-member characterization deliberately demonstrates a remaining admission
gap, not acceptance of malformed broker messages. These tests are not a complete two-release compatibility matrix or network/state-machine
validation. Independent positional golden vectors now exist; semantic admission coverage remains incomplete. Large inline bounded storage also remains a production/embedded mapping
gate, recorded with other generator follow-ups in zidl's roadmap.

Regression validation: the full local zidl `zig build test` target passed after the
allocator-forwarding fix and its new typedef/struct-sequence regression. The broker
fixture also passed with the rebuilt generator. This run did not repeat the separate
C/C++/Java integration target; its earlier success is not new evidence for these codecs.


Protected admission, exact transcript correlation and recovery after lost ACCEPT are
reviewed in the [admission protection proposal](broker-admission-protection.md). Its
GUID-based unsecured identity and authenticated live-replacement rules supersede the
earlier stable ownership-secret proposal.

See [bootstrap rejection](broker-bootstrap-rejection.md) for preadmission error correlation,
retry behavior and response-budget rules.

Current fixture evidence: 23 generated tests and 53 independent vectors; full semantic
admission, two-release compatibility and network tests remain open. The operation table
uses ordered STATE boundaries/records and aggregate freshness. The controlling
[aggregate freshness contract](broker-aggregate-freshness.md) replaces chunked presence;
older presence-completeness reasoning is transitional, not the current wire grammar.

[Retry retirement](broker-retry-retirement.md) defines consumed-admission guards through
cookie expiry and bounded aggregate results protected by once-only reliable CONTROL admission.
