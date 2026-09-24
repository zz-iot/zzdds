# Reconciliation of direct and broker discovery

Status: shared graph, source-specific evidence and shared origin-version extension
accepted, 2026-09-18. Exact parameter encoding and canonical-content rules remain wire
work; no production schema or implementation change yet. It replaces the old assumption that coexistence is merely a future plugin mode.

## One graph, separately retained evidence

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

## The difficult case: comparing updates across paths

Example: direct SEDP installs endpoint revision 8; a delayed broker view still contains
revision 7. After direct discovery expires, blindly preferring the surviving source would
roll the endpoint back. “Prefer direct while available” postpones rather than solves this.

Options:

1. Arrival order: easy, but delayed snapshots can overwrite newer data. Reject.
2. Fixed source preference: predictable, but can ignore newer updates or roll back during
   failover unless conflicts remain unresolved. Useful only as an explicit limited policy.
3. A shared origin version on both paths: receiver can select the newest admitted origin
   state independently of path. Adds a small zzdds discovery extension and origin bookkeeping.

Option 3 is accepted for zzdds participants using both paths. Reuse the broker's existing
per-entity origin_revision, generated once when local discovery state changes, and expose
it plus the participant incarnation through vendor parameters in direct SPDP/SEDP records.
The same revision describes the same logical state in broker inventory/mutations. Periodic
reannouncement, retransmission, lease renewal and broker reconnect do not increment it;
a real discovery-state change does. Runtime-only directed service-request metadata is not
part of this canonical state version. Counter overflow requires defined identity renewal,
not wrapping. Exact parameter IDs/encoding and generation integration need review.

Standard peers may ignore these optional vendor parameters. Do not claim the extension
itself authenticates the revision: unsecured operation remains unsecured. Secure installs
must validate the relevant origin and permissions under their configured security profile.
A trusted plaintext broker cannot override native protected discovery merely with a large
revision number. The cached and future secure-peer profiles remain distinct.

A native writer GUID/sequence can establish equality/order only when both records really
refer to the same originating writer lifetime and sample. It is useful evidence, not a
universal replacement for the shared revision: some broker records have no corresponding
native sample, and different built-in writers have independent sequence spaces.

## Selecting content and freshness

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

## Removal is not source loss

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

## Peers without the shared revision extension

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

## Trace expectations

* Same endpoint arrives directly and through broker with revision 4: one match.
* Broker loses registration, direct revision 4 remains fresh: no unmatch.
* Direct revision 8 precedes delayed broker revision 7: no rollback, including after direct
  expiry; obtain revision-8-or-newer evidence or leave inactive.
* Origin removal revision 9 arrives, then delayed upsert 8: no resurrection.
* Broker view excludes endpoint still valid directly: remove broker evidence only.
* Same revision carries conflicting QoS: explicit conflict, no arbitrary replacement.
* Local broker upload runs after learning remote endpoints: upload only locally owned state.
* Broker service announcement also arrives via multicast: service relationship policy and
  stable capabilities prevent accidental ordinary SEDP association with that service.

Accepted: shared graph/provenance plus a shared origin revision extension for zzdds
coexistence. Assign parameters and refactor the origin update boundary only after the
wire details below are resolved. This is not executed mixed-source conformance.


## Origin update boundary

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

## Wire tasks still to resolve

* Define exactly which fields belong to canonical discovery content. Native SPDP includes
  operational values such as liveliness counters; periodic announcements and directed
  service-request context must not accidentally become conflicting copies of one revision.
  Versioning canonical entity content does not permit losing native operational semantics.
* Place the incarnation/revision metadata in valid vendor extension locations for full
  announcements and key-only disposal/unregister messages. Do not simply append it to a
  key-only payload without checking the built-in-topic key representation rules. Inline
  QoS may be the appropriate place for change-level provenance; review codec retention.
* Define comparison of unknown vendor parameters, defaulted QoS, parameter ordering and
  source encapsulation. Keep semantic equivalence separate from exact original-byte
  preservation and same-request retry identity. The broker's exact-record deduplication
  rule is not automatically the cross-source equivalence rule.
* Enforce agreement between broker OriginRecord identity/revision and embedded origin
  metadata; conflicting copies cannot be accepted according to whichever layer is read
  first. Define behavior for legacy records without the extension explicitly.

The subsequent wire review provisionally assigns origin-version PID 0x8003. Existing zzdds locator PIDs 0x8001/0x8002
are already in use; a dedicated wire-registry review must avoid them. Completing these
items is the next bounded step before adding generated-code fixtures or enabling hybrid
installation in production.

The [origin-version wire proposal](broker-origin-version-wire.md) now specifies full
payload versus inline lifecycle placement, canonical content and operational-field
separation. Its placement/comparison direction is accepted; provisional PID 0x8003 and structural
endian/deletion fixtures now exist. Production codec/graph integration remains pending.

## Direct-source versus broker-origin decoding

The [PR #92 review](pr-92-discovery-review.md) highlights a required codec boundary.
For a broker-delivered OriginRecord, validate embedded participant identity against its
record origin, never the enclosing broker RTPS prefix. Do not let a direct-SPDP decoder's
source-prefix preference silently rewrite conflicting broker records. Preserve exact
source bytes and reject inconsistent origin evidence before installation. An unsecured
RTPS header is not authenticated identity; effective INFO_SRC and configured protection
remain separate checks. All installation/rematching paths honor current enable/ignore/QoS
policy, even when the underlying discovery evidence remains cached.
