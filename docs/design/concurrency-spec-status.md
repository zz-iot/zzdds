# Concurrency and discovery-broker specification status

Current handoff: [concurrency and broker design baseline](specification-handoff.md),
2026-09-24. The directional specification effort is complete within its stated scope.
The [broker guide](broker-spec-guide.md) and [closure ledger](broker-spec-closure.md)
identify controlling contracts and remaining implementation/wire-publication gates.
Older next-step/count statements below record history, not additional requirements.

Current checkpoint: **concurrency v1 behavioral baseline ready for implementation**,
2026-09-17. The [readiness review](concurrency-final-review.md) records scope, gate
closure and remaining implementation requirements. Public ABI is not frozen and the
production runtime is not claimed to implement the new contract.

## Deliverables and current position

| Deliverable | Status | Finish line |
| --- | --- | --- |
| Concurrency specification v1 | Behavioral baseline complete within the documented scope | Accepted ownership, callback, wait, failure, resource and progress rules; explicit extension API responsibilities and migration gates |
| Revised discovery-broker specification | Behavioral contracts consolidated; explicit wire/profile and generated-ABI gates remain | Independently implementable client/server protocol, recovery, lifetime, configuration and error behavior, followed by deliberate wire-schema review |
| Production implementation and release | Separate subsequent effort; some prerequisites already merged | Generated ABI, real runtime/binding/backend integration, interoperability, fault/race tests and measured performance/size |

The original objective remains a generally useful, configurable DDS discovery broker.
No ROS 2 product requirement is assumed. Single-thread-capable execution is a library
requirement; full MCU ports, XTypes, DDS Security and ICE/STUN/TURN implementations are
not prerequisites for finishing these specifications.

## Reading order and authority

1. [Consolidated contract](concurrency-contract.md): entry point for accepted behavior.
2. [Readiness review](concurrency-final-review.md): each gate, its resolution and limits.
3. [Extension inventory](concurrency-extension-surface.md),
   [API draft](concurrency-api-draft.md) and [bootstrap](runtime-bootstrap-contract.md):
   public responsibilities, draft signatures and accepted portable construction rules.
4. [Migration plan](concurrency-migration-plan.md): production stages and acceptance.
5. [Broker guide](broker-spec-guide.md) and [closure ledger](broker-spec-closure.md):
   consolidated design baseline and explicit implementation/compatibility gates.

Detailed operation contracts linked from the consolidated contract govern their named
behavior. Explicit later accepted decisions supersede historical investigation wording.
The architecture notes and experiment ledgers retain alternatives/evidence, not a second
set of unresolved requirements. A proposal for a physical representation is not accepted
merely because its required observable behavior is settled.

## What is settled

Take-turns participant/endpoint ownership, shared runtime progress, callback exclusion
and inline eligibility, fixed listener groups, delegation and replacement/deletion
frontiers, prepared effects/output handling, operation-specific waits, automatic runtime
retirement, owner/observer separation and optional resource reclamation fences are settled.

Non-OMG controls belong in zzdds.idl. Entity creation uses Config-taking extensions with
reasonable standard-API defaults. Participant limits have build-changeable defaults;
writer preparation defaults to one per instance. Manual driving has one outer driver,
with ordinary teardown tails or an explicitly registered external-loop service obligation.
The accepted bootstrap requires external attachment before participants/I/O, no live
executor replacement in v1, explicit clock compatibility and versioned resource handling.

Generic zidl reference/configuration behavior is specified. Its implementation can remain
experimental during specification completion. Completing sequences, mixed Config/TOML,
managed-language wrappers and failure-safe ABI conversion is a production integration gate.
No new general scheduler or aggregate prototype is required by the readiness review.

## Evidence and repository baseline

The [main refresh review](main-refresh-review.md) records the inspected zzdds main
c37181e and zidl main 26dc737, including generated SPDP/SEDP codec and transport Channel
work. These are recorded audit baselines, not claims about today's remote heads. Broker
revision must reuse these facilities and check any subsequent source changes.

Bounded models and generated C/Zig experiments validate named slices only. Existing zidl
validation on 2026-09-16 passed 1,115 tests and all 23 integration build steps, including
Java/JNI. Experimental managed-reference Java generation remains unsupported. Production
race, malformed-input, binding-failure, saturation and backend tests remain outstanding.

## Broker handoff

Reconcile the review against general DDS use and current source. Preserve direct user
data by default, independently configurable TCP/UDP broker channels, lossless discovery
records, original-peer built-in metatraffic where needed, and explicit future Security,
XTypes and traversal boundaries. Limited discovery/metatraffic forwarding is distinct
from optional future user-data relay service.

The broker finish line requires concrete session/entity ownership, snapshot/delta recovery,
freshness versus liveliness, bounded admission, asynchronous failure handling and versioned
wire/control schema. Protocol identifiers require their own freeze review. Measurements,
provider selection and release gates must not become invented interoperability assumptions.
Production concurrency migration need not finish before that work resumes.

## Broker reconciliation — 2026-09-17

Revision 0.2 now incorporates the accepted runtime/listener/retirement contracts and
the implemented codec/channel facilities. The review disposition keeps cached endpoint
discovery primary, rejects a threaded-only requirement and removes duplicate prerequisite
work. Next settle the application readiness/status contract, then control schema and
wire compatibility. The broker is still a proposed protocol, not implementation-ready
or wire-frozen. This reconciliation changed documents only.

The [broker readiness proposal](broker-readiness-contract.md) is now ready for review:
allow-degraded default, fixed-deadline recovery-following readiness wait, independent
pending/failure status and optional coalesced extension notification. It proposes no
separate registration barrier in initial v1. These are not yet accepted decisions.

Broker readiness direction is accepted (2026-09-17), with explicit same-participant
matching/lifecycle independent of broker availability. Local transport capability still
governs data delivery. Next is control schema and wire compatibility, with concrete
readiness/status IDL following the accepted behavioral contract.

The [wire contract draft](broker-wire-contract.md) and
[IDL subset](schema/broker-control-draft.idl) now cover proposed framing/negotiation,
message fields, cross-stream transaction assembly, digest ordering and fenced resume.
The subset generated Zig successfully; runtime codec validation and complete numeric
registries remain freeze gates. Required/duplicate mutable-member validation is an
explicit admission dependency, not implied by generator acceptance.

The recovery review R1–R5 is accepted and incorporated (2026-09-17). Fresh origin
inventory is required on every new session; downstream resume is independently
validated. Admission retries, expiry versus terminal close, uncertain commits and
pre-BEGIN staging now have explicit rules. The IDL subset includes admission and
ACCEPT/cursor fields and still generates Zig successfully. Next complete the remaining
message bodies/registries and validate actual codec/version behavior before wire freeze.

All 28 broker operations now have draft body types and a
[provisional registry](broker-wire-registry.md). Six executable codec checks pass,
including synthetic optional/required field evolution and a populated bounded struct
sequence. A narrow zidl allocator-forwarding codegen defect was fixed. Missing/duplicate
member validation, large inline bounded storage and unsupported nested-sequence decoding
are explicitly tracked; no wire freeze or complete cross-version validation is claimed.

The [wire byte baseline](broker-wire-bytes.md) proposes exact Frame/alignment/padding
and digest bytes. Eight independent Python golden vectors agree with generated Zig
output; all nine codec fixture tests passed. Metadata value grammar, feature/version
policy, vendor endpoint assignments and admission/state-machine validation remain
wire-freeze gates. No production code changed in this byte-fixture pass.


The [metadata/feature/endpoint draft](broker-wire-details.md) now defines original-endian
inline QoS retention, native status/key representation, v1 feature gates and vendor
endpoint directions. HELLO explicitly offers client endpoints; ACCEPT supplies broker
endpoints. CONTROL and STATE are reliable; routed peer metatraffic preserves native
reliability through a separate best-effort pair. Eleven independent golden vectors
and all eleven generated-code fixture tests pass. These check serialization, not the
semantic admission rules. Next review protected transcript and continuity-credential
integration, especially endpoint offers, lost ACCEPT and reconnect authorization;
then consolidate the remaining wire-freeze and production-validation gates.


The [admission protection review](broker-admission-protection.md) proposes exact
transcript correlation and stable pre-OPEN ownership authority, so even the first lost
ACCEPT cannot strand a client without a credential. It identifies inactive-claim quota
costs, superseded cached outcomes, and revocation precedence. These policy choices await
review; no new authentication implementation or conformance claim is made. Next accept
or revise this bounded continuity policy, then validate admission loss/replay traces.


The user accepted the simpler identity direction: unsecured GUID identity, DDS Security
participant authentication where configured, and registration withdrawal on detected
disconnect/expiry. The admission proposal is rewritten accordingly; historical stable
claim-secret recommendations are superseded. Competing live registrations require
validated participant continuity for replacement or wait for closure/expiry. The
[manual trace review](broker-admission-traces.md) checks 16 loss/race/recovery cases;
no executable security validation is claimed. Next decide whether a typed bootstrap
rejection should make conflicts diagnosable, then consolidate the remaining wire gates.


The [bootstrap rejection draft](broker-bootstrap-rejection.md) adds operation 29 and
AdmissionReject, with request correlation, restricted reasons, bounded retry hints,
no-amplification and no incumbent-identity disclosure before authorization/path checks.
Twelve generated-code codec tests and thirteen independent golden vectors pass; the new
body is 120 bytes and Frame 144 bytes before RTPS/security overhead. Semantic rejection,
rate-limit and replay tests remain production gates. The next step is to consolidate
wire-readiness gaps into one implementation checklist rather than extend admission policy.


The [29-operation admission table](broker-operation-validation.md) now maps direction,
stream, phase, validation, effects and failure handling; names/codes match the IDL.
W2 remains open: inventory/mutation dependency, view correlation/recovery, presence-proof
membership and route-generation authority require decisions. No codec or runtime change
was made. Next choose F1's post-inventory mutation admission rule.


F1 is accepted: [v1 inventory COMMIT barrier](broker-inventory-barrier.md), with explicit
local buffering and same-session replacement draining. A likely follow-on negotiates
inventory-dependent mutations with bounded staging; no feature ID or v1 wire change is
introduced. Documentation-only trace review; next is F2 view request correlation/recovery.


F2 investigation: the [view correlation proposal](broker-view-correlation.md) recommends
client-assigned session-local view generations and bidirectional RESYNC_REQUIRED. It
covers early records, abandoned requests, resume rebinding and broker invalidation.
This is pending acceptance; no IDL or codec change/test run occurred. Next review that
choice, then update schema and trace/codec evidence together if accepted.


F2 accepted and incorporated (2026-09-18): ViewRequest member 4 carries the new
client-assigned generation, independently of the old resume cursor. RESYNC_REQUIRED is
bidirectional with restricted reasons and zero client retry hints. All 13 generated-code
fixture tests pass, including populated resume/new-generation roundtrip and truncation;
13 independent golden vectors still verify. This is codec evidence, not executed
view-recovery interleavings. Next investigate F3 presence-proof membership under churn.


F3 investigation (2026-09-18): [presence completeness](broker-presence-completeness.md)
proposes immutable answers tied to a view delivery frontier, explicit unavailable results,
aggregate proof limits and subset fallback. It calls out the READY interpretation for
freshly evaluated but inactive participants. No schema change or executable test was made;
next review the semantics before assigning fields and adding fixtures.


F3 accepted and incorporated (2026-09-18): immutable presence answers carry a view
frontier and explicit availability; four ReceiveLimits fields bound query/entry/chunk/byte
resources. READY can account for explicitly evaluated inactive participants. All 14 codec
tests pass (including mixed available/unavailable entries, limits and explicit empty proof);
13 independent existing golden vectors verify. Churn/timeout semantics still need state-
machine tests. Next is F4 route generation authority and reverse error correlation.


F4 investigation (2026-09-18): [route authority](broker-route-authority.md) recommends
resolving each message against current registrations, fencing queued work to captured
source/destination tokens and using a bounded expiring reverse-error map. It proposes
removing the undistributed route_generation field and clarifies queue budget versus
unproven end-to-end age bounds. Pending acceptance; no schema/code changes or test run.


Relay reconciliation accepted and incorporated (2026-09-18): no v1 WLP or user-data
forwarding. Native WLP uses direct participant paths established from broker discovery;
allocated opaque relay transports come later. ROUTE/ROUTE_ERROR bodies are removed,
opcodes 23/24 and former peer-channel/service numbers reserved; HELLO/ACCEPT offer only
CONTROL and STATE. All 27 active operation names/codes match the table and registry.
All 14 codec tests pass; 13 existing golden vectors verify. F4 is resolved by scope;
next is W3 bounded retention/reclamation. See [relay direction](broker-relay-direction.md).


W3 investigation (2026-09-18): [retention review](broker-retention-review.md) identifies
that epoch-long closed-incarnation rejection conflicts with unrestricted churn and bounded
memory. Recommendation: terminality fences the closed registration and its old work,
while fresh admission after reclamation is governed by current policy, not an eternal
identity ledger. Pending acceptance. Also identifies bootstrap consumed-cookie retention
and presence-query serial/window as follow-up compact-replay decisions. No code changes.


W3 terminality decision accepted (2026-09-18): forget a closed registration after all
session/message/replay/delivery/runtime obligations retire; fresh admission with the same
identity is then allowed. No automatic blacklist in v1; quotas/rate limits/backoff and
configured authorization remain. Next: compact bootstrap and presence-query replay rules.


W3 retry investigation (2026-09-18): [retry retirement](broker-retry-retirement.md)
proposes consumed-admission guards lasting through cookie expiry, and monotonically
ordered presence-query serials with bounded result slots. It avoids an unbounded random-
nonce tombstone set and uses ordered control admission, while allowing out-of-order answer
completion. Pending acceptance; no schema changes or executable tests in this pass.


W3 retry-retirement direction accepted and incorporated (2026-09-18). PresenceQuery/Proof
now carry query_serial; admission guards last through challenge expiry. The bounded
abstract model explored 176 query states/585 transitions, checked admission expiry and
both completion orders, and detected both intentionally unsafe replay variants. All 15
codec tests pass; 13 independent vectors verify. No production replay/security claim.
Next reconcile W4 bootstrap sizing, endpoint establishment and lifecycle deadline horizons.


W4 investigation (2026-09-18): [bootstrap lifecycle](broker-bootstrap-lifecycle.md)
records measured HELLO/CHALLENGE/OPEN/ACCEPT sizes. OPEN is 852 bytes with 128-byte realm,
resume and 64-byte cookie, but 1300 with a 512-byte cookie, before RTPS/security overhead.
Recommendation: exact nonfragmented preflight, explicit failure when required fields do
not fit, existing first-control confirmation and separate fixed deadline horizons.
All 16 codec tests pass; policy details await review. No real network/provider validation.


SPDP-based service connection sequence drafted (2026-09-18): plain UDP gets bounded
path validation before a full broker reply; TCP/validated protected associations omit
that duplicate check. Proposes compact REGISTER/ACCEPT after SPDP introduction, preserving
inventory/view/presence contracts. No IDL replacement yet: transcript and cookie-free
attempt retirement must be redesigned with the sequence. Next review sequence and source
reconciliation for coexisting direct/broker discovery. See broker-spdp-bootstrap.md.


Coexistence investigation (2026-09-18): [direct/broker reconciliation](broker-discovery-coexistence.md)
proposes one installed graph, source-specific freshness, and shared origin revisions in
zzdds vendor discovery parameters. Source expiry is not origin deletion; stale surviving
sources cannot roll state backward. Conflicts lacking comparable versions are not silently
merged. Policy awaits acceptance; no IDL/production code or tests changed.


Coexistence direction accepted (2026-09-18): one installed graph, separately tracked
source evidence, and shared origin versions. The origin update boundary now explicitly
allocates a version once for both paths; removal is distinct from source expiry. Next
resolve canonical-content equivalence and vendor metadata placement, especially key-only
native disposal and operational SPDP fields, before assigning PIDs. No production/IDL
changes or executable tests in this documentation pass.


Origin-version wire investigation (2026-09-18): proposes a 24-byte incarnation/revision
vendor parameter in full discovery payloads, inline QoS for key-only lifecycle messages,
and typed canonical comparison separate from native operational counters and exact broker
retry bytes. Unknown optional fields compare conservatively. No PID or production IDL
assigned yet; next accept/refine placement and comparison, then add endian/deletion fixtures.
See [wire proposal](broker-origin-version-wire.md).


Origin-version placement/comparison accepted (2026-09-18). Design-schema PID 0x8003 and
OriginVersion added; production discovery IDL/emission unchanged. Eight new independent
structural LE/BE value/full/key-only/inline vectors agree with focused Zig decoding/LE
encoding checks. All 17 codec tests pass; previous 13 broker vectors also verify. No
semantic coexistence or full-announcement conformance claim. Next reconcile directed
service metadata and compact registration fields in the SPDP bootstrap proposal.


Service introduction fields drafted (2026-09-18): persistent capabilities in canonical
SPDP, directed request/offer in inline QoS, compact REGISTER bound to a validated ephemeral
introduction ID. The proposal explicitly trades bounded post-validation state for avoiding
full sample repetition and cookie-free TCP replay ambiguity. Pending acceptance; no new
PIDs/opcodes/codec claim. Next confirm that tradeoff, then revise schema/fixtures together.


SPDP introduction direction accepted and experimental schema updated (2026-09-18):
PIDs 0x8004–0x8006, ops 30–32, bounded PathCookie and compact RegisterRequest. Old opcodes
1–3 reserved; Legacy types remain fixture-only. ACCEPT echoes introduction ID. All 18
codec tests pass; compact REGISTER example is 468 Frame bytes (empty realm, resume, two
pairs), before transport/security overhead. Existing 21 vectors retain their stated scope,
including historical OPEN rejection. Next native ParameterList/hash fixtures and editorial
consolidation; no production handshake/security implementation claimed.
