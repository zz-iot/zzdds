# Broker specification and implementation checklist

Final design handoff: [scope, completion and remaining gates](specification-handoff.md),
2026-09-24.

## Current entry point

Start with the [implementer guide](broker-spec-guide.md) and [closure ledger](broker-spec-closure.md).
The public-behavior and protocol consistency reviews are complete within their stated
scope. Wire compatibility remains provisional pending the named checks. The concurrency
behavioral baseline is settled; production migration and a working broker remain separate.

The detailed checklist and dated notes below preserve review history and implementation
evidence. Old "next step" statements do not reopen resolved decisions or supersede the
closure ledger. No additional diagnostic-management API or scheduler prototype is required.

## Settled direction

* Cached SPDP/SEDP discovery with original-byte retention; reuse the merged discovery
  codecs and Channel APIs. No repeat codec extraction or general scheduler investigation.
* Shared runtime, manual and hosted execution, and the accepted listener/lifetime rules.
* Independently configurable TCP/UDP broker control and user-data transport. No user-topic
  proxy in v1; preserve routes for native metatraffic and future connectivity assistance.
* Allow-degraded startup and same-participant local activity independent of broker health.
  READY requires the fixed inventory/view/freshness targets, not peer reachability.
* Fresh origin inventory on every new session; downstream resume independently validated.
  Atomic inventory/view installation, bounded staging and no stale-owner commits.
* Unsecured GUID identity without ownership secrets. DDS Security participant identity
  uses its plugins when implemented; broker transport authentication is separate.
* Detected disconnect/expiry withdraws registration. Competing live registrations wait
  unless authenticated participant continuity explicitly permits replacement.
* Bootstrap rejection supplies bounded diagnostics without extending caller deadlines.

## Existing concrete artifacts

| Artifact | What exists | What it does not establish |
| --- | --- | --- |
| [Main spec](discovery-broker.md) | Architecture, deployment scope and delivery stages | Production implementation |
| [Readiness contract](broker-readiness-contract.md) | Accepted observable behavior | Concrete public IDL/configuration mappings |
| [Wire contract](broker-wire-contract.md), [registry](broker-wire-registry.md), [IDL](schema/broker-control-draft.idl) | 27 active operation bodies and provisional numeric registries | Frozen compatibility or complete semantic validation |
| [Byte baseline](broker-wire-bytes.md), [wire details](broker-wire-details.md) | Framing, digests, metadata, features and endpoint roles | All malformed-input and cross-version behavior |
| [Admission policy](broker-admission-protection.md), [rejection](broker-bootstrap-rejection.md) | Identity/reconnect and phase-specific rejection rules | Implemented security provider or parser |
| [Trace review](broker-admission-traces.md) | 16 manually reviewed loss/race scenarios | Executed model or network tests |
| [Codec probe](probes/broker_wire_codec.zig) | 18 passing generated-code tests; 13 independent Python vectors | Security, resource bounds or full broker state-machine correctness |

The fixture deliberately characterizes missing/duplicate mutable-member acceptance as
a remaining validator defect. Bounded sequences also currently produce large inline
native objects. Passing codec tests does not remove either production blocker. The
record fixture is structurally encoded, not a complete valid SPDP announcement; rejection
uses a synthetic digest. Exact transcript extraction still needs executable evidence.
The retry-retirement schema update passed all 15 codec tests and verified 13 independent vectors.
The added test separates a new request generation from its retained resume cursor;
full asynchronous transition coverage remains open.

## Specification completion checklist

These items close the design package. Implementation may proceed against drafts, but
independent implementations must not assume compatibility before W5.

| ID | Remaining deliverable | Completion criterion |
| --- | --- | --- |
| W1 | Public configuration, readiness/status/error IDL ([proposal](broker-public-api.md)) | Review concrete zzdds.idl extension signatures and Config fields, defaults, supported discovery modes, timeout/error mapping and generated binding ownership. Standard DCPS APIs retain sensible defaults. No non-OMG API added to dcps.idl. |
| W2 | Complete semantic admission table ([27-row draft](broker-operation-validation.md); F1–F3 accepted; F4 removed from v1) | For all 27 active operations specify permitted phase/direction/stream, required fields and cross-field constraints, accepted identity/generation, duplicate handling, resource reservation, state effects and failure response. Include malformed metadata, transcript comparison and unauthenticated reply restrictions. |
| W3 | Bounded retention and retirement rules ([review](broker-retention-review.md); registration-scoped retirement accepted; compact replay direction accepted; lifecycle horizons remain) | Specify reclamation conditions for admission outcomes/challenges, closed registrations, revisions, withdrawn records and cursors. Show that forgetting old state cannot reexecute old work; capacity pressure has a defined failure path. Distinguish replay protection from the rejected permanent ownership registry. |
| W4 | Bootstrap and endpoint lifecycle completeness ([sizing/lifecycle review](broker-bootstrap-lifecycle.md)) | Confirm SPDP/context, PATH and REGISTER/ACCEPT fit configured non-fragmented budgets, including security overhead; define oversize failure rather than hidden fragmentation. Specify endpoint establishment/confirmation, timeout, resource rollback and late ACK/close handling for both established endpoint pairs. Resolve retained raw nested transcript representation. |
| W5 | Wire review and compatibility baseline | Review all provisional assignments, exact bytes and feature/version rules together. Define strict decoding behavior, add representative old/new-version fixtures and negative cases, and identify any remaining wire-affecting implementation findings before declaring the baseline frozen. |

W3 now scopes terminal CLOSE to its registration and derived work. After full retirement,
fresh admission may reuse the identity. No v1 blacklist is required. Consumed-attempt guards through challenge expiry and ordered presence-query serials
now have accepted bounded rules. Concrete lifecycle horizons/resource accounting remain
to be checked with W4.

## Implementation and evidence checklist

These are delivery gates, not reasons to reopen the settled general architecture.

| ID | Work | Required evidence |
| --- | --- | --- |
| I1 | Strict codec/admission boundary | Required/duplicate member checks, exact consumption, arithmetic/aggregate bounds, safe encapsulation finalization, unknown-field handling and raw-record/transcript retention. Negative fixtures and fuzzing. Generic zidl improvements are in scope. |
| I2 | Bounded native storage and runtime integration | Allocated/borrowed wire mappings, resource reservations, completion/cancellation ownership, shared timers and manual/hosted behavior. No per-session thread or oversized inline queue-object assumption. |
| I3 | Store, admission and synchronization | Executable fake-clock/loss/reordering tests for all W2 transitions, atomic inventory/view updates, fixed READY targets, stale commit/cleanup, resume, orphan staging and retention exhaustion. |
| I4 | Channel and metatraffic integration | Real UDP/TCP return-path tests, source-address preservation, endpoint reliability, direct WLP and native repair with peer SEDP disabled, independent data transports, close/migration behavior. No user-data relay. |
| I5 | Public API/configuration bindings | Generate W1 surfaces, validate Config/default behavior and error/status observations across supported bindings; preserve original local matching and native discovery behavior. |
| I6 | Protected deployment | Select maintained TLS/DTLS provider and authorization integration; test replay, revocation, downgrade, amplification, disclosure and quotas. DDS Security live replacement remains unavailable until participant-continuity evidence exists. |
| I7 | Operational and performance envelope | Measured memory/default limits, backoff/pacing, fairness under slow observers and reconnect storms, metrics and documented scale/latency results. Native discovery regression coverage. |

The complete integration matrix remains in [main spec §15](discovery-broker.md#15-verification-and-release-gates).
An in-memory test cannot certify NAT/source-address behavior. An authenticated transport
cannot certify DDS Security protected discovery. Target-specific skips must be reported.

## What counts as done

**Concurrency design:** the accepted behavioral baseline and migration plan already
exist. Production migration remains separate work, with the documented optional-profile
and binding limitations. Broker design does not require repeating all those experiments.

**Broker specification:** W1–W5 are resolved or explicitly excluded from the initial
feature set, contradictions are removed, and a reviewer can implement client/server
behavior without guessing wire or application semantics. Wire-affecting issues cannot
be deferred behind a claim of frozen compatibility. This is the current design target.

**Functional broker:** I1–I5 support the declared initial feature set and pass its tests.
A deliberately restricted trusted-network release may precede authenticated deployment,
but must say so. Public authenticated deployment additionally requires I6 and the relevant
I7 hardening; scale claims require measured evidence.

ICE/STUN/TURN, consensus HA, native TypeLookup and DDS Security protected-discovery
integration remain separate feature milestones. Their extension boundaries stay in view;
their complete implementation is not required to finish this broker specification.

## Next bounded step

The W2 table covers all 27 active operations. F1–F3 are accepted; F4 is resolved by
removing broker forwarding from v1. Native direct WLP remains required and allocated
relays are later work. Next examine W3 retention/reclamation, then W4 bootstrap/endpoint
lifecycle, W1 public APIs and final W5 review. Experiments should resolve named gaps,
not introduce another forwarding protocol or repeat general concurrency investigations.

The [coexistence investigation](broker-discovery-coexistence.md) recommends one graph with
source-specific evidence and shared origin revisions in zzdds SPDP/SEDP extensions.
Shared origin-version ordering is accepted; vendor metadata placement and canonical
content comparison remain explicit wire tasks, not solved by receipt order.

Origin-version placement/comparison is accepted, with provisional PID 0x8003 and eight
additional structural LE/BE vectors. The 17-test codec suite still includes old-bootstrap
fixtures; it does not validate the proposed SPDP introduction or production coexistence.

The [service introduction field proposal](broker-service-introduction.md) is the current
W4 handshake candidate; old bootstrap fixture sizes do not measure its messages.

SPDP service sequence/introduction records are now accepted with experimental schema
and registry assignments. 18 codec tests pass; retired HELLO/OPEN tests are historical.
Next add native service ParameterList/hash fixtures and consolidate superseded bootstrap
prose, then finish size/deadline checks and public API work.

Service fixture follow-up (2026-09-18): 19 codec tests and 20 independent service
vectors pass. Native CDR1 values and sample/path hashes cover both byte orders; hash
input includes inline parameter terminal padding. Rejection prose now uses REGISTER;
older sizing is explicitly historical. Remaining bounded wire work: REGISTER/ACCEPT
and rejection hash vectors, current-handshake size/deadline checks, and consolidation
of the remaining historical admission/lifecycle sections before the W1 API pass.

Current handshake closure pass (2026-09-18): 21 codec tests / 49 independent vectors
pass, including REGISTER/ACCEPT/rejection hashes and current size profiles. The revised
[lifecycle contract](broker-bootstrap-lifecycle.md) separates introduction admission
expiry from retained-result expiry, and cookie replay guards from both. Large ACCEPT is
1204 bytes before RTPS/security; whole-exchange preflight is required. Production deadline,
size-failure and endpoint tests remain gates. Next reconcile W1 public configuration with
independent direct/multicast/broker settings and these bounded bootstrap failures; do not
reopen concurrency or imply that production bootstrap is implemented.

W1 configuration pass (2026-09-18): [public API proposal](broker-public-api.md) preserves
create_participant_ex, resolves DiscoveryKind as a preset with explicit overrides, and
defines one-authority status/wait/listener semantics even in mixed discovery. Remaining
W1 review: resolved defaults/resource-budget mapping, per-entity diagnostics and generated
IDL/TOML/binding validation. No production API is changed by this draft.

Accepted domain identity revision (2026-09-18): [domainTag replaces realm](broker-domain-identity.md).
Native support is absent and is now an explicit roadmap prerequisite. W1 uses DomainConfig.tag;
W2 admission and W5 wire/schema/fixture review must use standard domain identity. Next migrate
scope encoding/request-context fixtures together, and implement native domain admission before
claiming broker or mixed-discovery domain-tag support. Previous size/hash results apply only
to their recorded pre-migration layouts.

Native domain-ID increment: SPDP now always encodes PID_DOMAIN_ID, retains explicitly
received IDs and rejects foreign IDs before native SPDP cache/locator updates. Missing
IDs retain receiver-domain fallback for interoperability. DomainTag/config propagation,
early SEDP eligibility review and broker scope fixture migration remain pending; this
increment is not full domain-tag compliance.

Next domain-identity decision: [multi-domain service identities](broker-multidomain-service.md)
recommends one logical broker participant per configured domain ID/tag, sharing listeners
and runtime. No application configuration change or new round trip is required. This is
a review proposal; native implementation and wire-fixture migration are not expanded here.

Accepted multi-domain/wire reconciliation: one logical broker participant per configured
scope; ordinary domain eligibility unchanged. Experimental ScopeValue uses standard-bounded
CDR string domain_tag and explicit domain_id, and directed request omits realm. Twenty
codec tests and 49 independently verified vectors pass; the retired-handshake sizing test
was removed. Current maximum profile REGISTER/ACCEPT sizes are 1240/1336 bytes before
RTPS/security. Next spec work: W1 resource budget/default mapping and per-entity failure
diagnostics. Native tag implementation remains deferred to delivery work.

W1 next recommendation: [resource configuration and diagnostics](broker-resource-diagnostics.md).
Review a small public resource group with derived wire limits, a resolved-plan getter and
restartable bounded current-failure pages. Numeric platform tuning remains an implementation
gate; deterministic resolution, units and failure semantics are specification requirements.
No new production code or experiment was added for this decision.

Resource/API scope narrowed by user acceptance: see [v1 disposition](broker-resource-diagnostics.md).
The previously proposed six resource fields, resolved-plan getter and failure pagination are
all deferred. Keep internal bounds, reservation/failure semantics, participant observability
and bounded diagnostic logs. Public status includes a registration-rejection category;
individual errors do not require a new collection API. No production code was changed.

2026-09-23 refresh: rebased onto zzdds f14dd08 and updated zidl to 53177d9; see
[review](main-refresh-review.md#refresh--2026-09-23). Concurrency architecture stands;
new reader readiness callback, enablement/deletion/coherent-readiness fixes and raw-loan
identity mappings become migration regression requirements. Twenty codec tests and 49
vectors pass with rebuilt zidl. Wire-contract OPEN prose and retention open-question text
were reconciled. The public API now records one pending recommendation: disabled Entity
creation combined with require_ready fails local configuration validation; staged enabling
uses allow_degraded plus an explicit readiness wait. Resolve this before final W1 IDL.

2026-09-23 enablement decision accepted: reject require_ready combined with disabled
participant creation locally. Staged enabling uses allow_degraded, standard enable and
explicit wait. The public phase draft now includes WAITING_FOR_ENABLE. Next deliverable
is the consolidated public IDL/API review (return-code table, status invariants and listener
ownership), followed by one cross-document W2–W5 consistency pass. No new feature design
or production implementation is required to proceed.

2026-09-23 final public-behavior review: [disposition and return table](broker-public-api-review.md).
The narrowed surface is sufficient. Corrected callback annotation and missing view status,
disabled-child vs disabled-participant distinction, timeout scope, summary failures/counts
and listener ownership/quiescence. No new API feature or user decision identified. W1
behavior review is complete; generated declaration/layout and binding checks remain explicit
gates before API publication. Proceed with cross-document W2–W5 protocol consistency;
this is not a claim that the entire broker spec or wire ABI is frozen.

2026-09-23 protocol consolidation: [review and disposition](broker-protocol-review.md).
Corrected REGISTER first-admission versus replay expiry, replaced retired transcript rules,
reconciled endpoint negotiation and scoped historical model evidence. Mechanically verified
all 27 active opcode/name pairs against the schema. No wire bytes, production code or new
feature decisions changed. Remaining work is the final byte/error/scope consistency pass
and an explicit W1–W5 closure/blocker ledger, not additional concurrency prototypes.

Current closure disposition is consolidated in [broker-spec-closure.md](broker-spec-closure.md).
Use that ledger rather than treating older chronological "next" paragraphs as open tasks.
Public behavior and the reviewed protocol invariants are settled; wire compatibility is
still provisional pending the named integration/assignment checks. Final scope/error/byte
reconciliation added no production changes or new API features.
