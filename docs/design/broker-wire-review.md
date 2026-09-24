# Broker wire review: recovery and commit boundaries

Status: R1–R5 recovery corrections accepted, 2026-09-17, with the later identity
correction below superseding persistent ownership/credential recommendations in R1/R2.

Current policy: unsecured participants use GUID identity without historical ownership
proof. Confirmed disconnect withdraws registration; a new competing binding waits for
old-session closure/expiry unless authenticated participant continuity permits replacement.
No mandatory continuity token is issued in ACCEPT. Lost ACCEPT recovery may wait for the
finite establishment deadline. See [current admission policy](broker-admission-protection.md).
The later retention decision also supersedes epoch-long CLOSE terminality: after the
closed registration and all obligations retire, fresh admission may reuse its identity.
The original review reasoning is retained below as history. Recommendation language
below records the reasoning; broker-wire-contract.md incorporates the selected rules.
Complete control IDL and wire identifiers remain unfrozen. Reviews broker-wire-contract.md
against discovery-broker.md; no implementation, network experiment or conformance claim.

## Findings and recommendations

### R1 — distinguish expired registration from a closed incarnation

The original spec both preserves participant GUID/incarnation across reconnect and says
expired sessions cannot revive participants. The latter is correct for replay but too
broad for a live participant deliberately registering again after a long outage.

Separate transport session closure, registration expiry and terminal participant CLOSE.
Expiry withdraws broker-backed presence/endpoints and fences old sessions; it does not
assert that the application deleted its local participant. Recommend allowing the same
live incarnation to register anew under fresh admission, new ownership fencing, fresh
inventory and fresh proof. An expired session's packets alone cannot do that. Explicit
participant CLOSE remains terminal for that incarnation within the authoritative epoch.
Application restart still uses a new GUID prefix/incarnation.

Admission must establish continuity through the supported ownership credential/principal
policy, not merely possession of a shared tenant credential or the same source IP.
Without sufficient continuity proof, reject automatic takeover of a protected claim;
do not silently invent a new participant identity for the application. Recovery after
credential expiry/revocation may therefore need administrative correction. Epoch restart
already requires fresh authorized admission; v1 has no durable global closed-identity ledger.

### R2 — make OPEN retries idempotent across lost ACCEPT

Fresh session/owner generation on reconnect is insufficient unless a retried admission
is distinguishable from another takeover. If ACCEPT is lost, blindly retrying OPEN could
fence the very session the client is trying to learn about.

Recommend a client admission-attempt ID and server-retained bounded admission outcome.
Bind it to principal/continuity proof, participant incarnation, negotiation and transport
binding. Repeated identical OPEN on the same protected binding returns the same ACCEPT,
without a new generation or renewed presence lease. Conflicting reuse fails. A new
transport binding uses a new attempt and the supported continuity procedure; do not
replay an old ACCEPT onto an unrelated channel. For validated UDP path migration within
a surviving session, keep the session identity and update only validated path state.

Reserve outcome and rollback capacity before ownership handoff. Unconfirmed admission
has a finite establishment deadline; accepting OPEN is not an origin lease renewal.
After the retry window ends, require explicit new admission and fence any prior outcome;
never silently treat the same request as a new successful takeover. Credential handoff
must tolerate lost ACCEPT: retain a bounded predecessor credential recovery path tied
to the same ownership claim, or an equivalent authenticated continuity mechanism.
Complete that mechanism in the admission schema/security integration before freeze.

### R3 — resume origin and downstream state independently

ACCEPT's single fresh/resumed outcome conflates the publisher's inventory with the
observer's received graph. They can have different recovery outcomes.

Recommend fresh origin inventory for every newly admitted session in initial v1.
Use the normal atomic inventory replacement: retain still-valid old committed inventory
while staging, validate entity high-water marks, and apply post-cut mutations after
commit. An already expired inventory is withdrawn; fresh proof is required before
replacement activation. Local matching continues independently throughout.

Permit downstream resume separately when epoch, view configuration/authorization,
retained client baseline, applied cursor and broker delta retention all agree. A lost
APPLIED response may lead the client to repeat installation acknowledgments; the broker
may accept a higher claimed cursor only within its retained, actually sent stream and
must not manufacture missing history. Conservative replay of retained deltas is safe.

Client eligibility requires the actual installed graph or sufficient retained baseline
state to reconstruct it, not just a numeric cursor. If peer expiry or memory reclamation
has discarded that baseline, request a snapshot. Retained inactive records may be
reactivated only by fresh proof after checking current view membership; successful
resume alone never refreshes presence. Authorization changes invalidate the old view.

ACCEPT should therefore report origin-inventory-required separately from the downstream
resume decision/next step. Readiness requires both sides' synchronization targets, not
one Boolean 'resumed'. This costs an origin re-upload on reconnect but substantially
simplifies uncertain mutations and inventory-cut recovery. A later origin-resume
optimization can add explicit proof of retained inventory state.

### R4 — uncertain commit is not a new mutation

A MUTATE may commit before its COMMIT reply is lost. Request IDs are session-scoped,
while origin revisions survive sessions. Distinguish their deduplication roles.

Within a surviving session, retry the same request/record. On a new session, rebuild
inventory from authoritative current local state and preserved revision high-water marks;
do not increment an entity revision merely to find out whether the old operation worked.
A newer real local change may legitimately supersede it. Snapshot/inventory replacement
must not interpret a removed endpoint's delayed upsert as a fresh create.

Commit, fencing and new inventory-cut admission serialize at the store boundary. Old
work committed before fencing may remain visible until replacement; old work reaching
commit after fencing is rejected. A postcommit transport failure is not REJECT for the
committed operation. If a retained result cannot establish an answer, require inventory
repair rather than guessing success or replaying an arbitrary side effect.

### R5 — cross-stream ordering includes RECORD-before-BEGIN

The draft handles END before RECORD but not RECORD/DELTA before BEGIN. Independent
control/state streams permit both. Recommend bounded orphan staging keyed by transaction
or view generation, including an early end marker. BEGIN validates and charges the final
announced limits before assembly continues. Timeout or capacity refusal aborts the
transaction and explicitly requests retry/resync; no partial installation.

An RTPS-acknowledged item discarded by application staging cannot simply be expected to
reappear through RTPS repair. Application-level transaction failure must invalidate that
attempt and cause a fresh one. Mandatory failure notification has reserved capacity;
if it cannot be delivered, terminate/degrade the session so the sender cannot infer commit.
Fresh origin inventories contain exactly one participant record plus zero or more
endpoints. Only a downstream view may have zero total records. Correct the draft's
unqualified 'count zero is valid' accordingly.

## Choices that look sound

* Keep fixed bootstrap framing and negotiated mutable bodies; complete exact bytes and
  admission validation before freeze. Version selection considers only supported majors
  and feature-compatible minors. No silent fallback from required features/security.
* Hash exact retained record bytes in deterministic order, with a domain-separated digest.
  This avoids re-encoding unknown discovery parameters; exact encodings/tags remain gates.
* Keep RTPS acknowledgment, broker COMMIT, view APPLIED and application callback completion
  separate. Fixed synchronization targets permit readiness under continuous churn.
* Reject unknown required semantics and duplicate singleton fields before committing.
  Existing generator acceptance does not satisfy that validation requirement.

## Accepted review decision

Adopt R1–R5, particularly **fresh origin inventory on every new session, independent
optional downstream resume**. Retain same-participant local operation during all recovery.
Then revise the wire/schema drafts together and complete admission/ACCEPT/body types.
No new scheduler prototype is needed to decide this policy; later protocol fixtures
must exercise lost ACCEPT/COMMIT/APPLIED, expired registration, discarded client baseline,
late old-owner commit and cross-stream staging exhaustion.
