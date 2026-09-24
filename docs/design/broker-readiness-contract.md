# Broker readiness and registration status

Status: readiness direction accepted, 2026-09-17, including broker-independent
same-participant activity. Concrete API spelling and wire schema remain unfrozen.
Refines discovery-broker.md section 13; no production implementation is implied.

## Accepted startup default

Default broker startup to `allow_degraded`: create a locally usable participant after
local validation/resource admission, and progress discovery asynchronously. This follows
the existing distinction between local DDS construction and finding remote participants.
A temporary broker outage need not prevent local application startup or teardown.

Invalid configuration, unsupported requested transport/security capabilities and failed
local allocation still fail construction. Degraded startup is not permission to accept
an invalid configuration, weaken security or enable multicast fallback. Applications
using standard DDS interfaces get bounded transition/error logging even without a
zzdds listener. They cannot infer discovery success from a non-nil participant.

A deliberately disabled participant cannot satisfy construction-time readiness. The
accepted creation rule rejects require_ready with effective participant autoenable=false
locally, using the existing constructor failure convention. Deferred startup uses
allow_degraded, ordinary enable(), then an explicit readiness wait. An enabled broker
mechanism on a still-disabled participant reports WAITING_FOR_ENABLE; its readiness wait
returns NOT_ENABLED. This does not give standard enable() a broker-synchronization wait.

Keep `require_ready` as an explicit deployment option, using a configured finite startup
deadline. It provides fail-fast startup for services that are useless without discovery,
at the cost of making construction depend on broker availability and synchronization.
Use the same readiness predicate as the explicit wait. A nil constructor result retains
existing DDS shape; startup diagnostics must record the underlying reason. Do not add
new failure parameters to standard creation APIs.

This default is a choice, not an OMG requirement. The alternative default,
`require_ready`, catches otherwise unnoticed broker outages earlier but couples every
standard participant creation in broker mode to a network dependency. Neither default
proves peer data connectivity or application matching.

## Broker-independent local discovery

Matching between enabled readers and writers belonging to the same local participant
MUST NOT require broker admission, inventory COMMIT, downstream echo or READY. This
includes endpoints created while the broker has never been reachable, endpoints added
during recovery and removal/QoS changes during an outage. Apply ordinary DDS matching,
ignore, enablement and lifecycle rules; do not bypass compatibility or security checks.

Local entity state is authoritative for these associations. Broker view replacement,
lease expiry, registration rejection and view withdrawal cannot remove or recreate
an association justified by live local entities. If a broker view includes the client's
own records, reconcile provenance/idempotently rather than duplicate match callbacks
or let a stale self-echo overwrite newer local state. Local deletion still retracts
local matches promptly and fences delayed echoes.

Reuse normal matching/status machinery through a local discovery path. The current
SpdpSedpDiscovery.start explicitly injects self participant data into SEDP's matching
path (src/discovery/combined.zig); self endpoint discovery then uses native SEDP. Broker
mode omits cached-peer SEDP and must provide equivalent local endpoint installation
independently. Today's self-discovery bootstrap is evidence of the requirement and
integration seam, not proof that unimplemented BrokerDiscovery already meets it.

Matching does not promise an in-process data shortcut. Sample delivery, reliability
and repair use the configured data path and its reachability/resource constraints.
A functioning local path can transfer data while the broker is unavailable. Separate
participants, even in one process/host, are not automatically covered by this guarantee;
a future local rendezvous optimization must explicitly establish their discovery path.

Offline announcement bookkeeping remains bounded. Retain authoritative current local
inventory and coalesce changes not yet assigned to a delivery stream; use fenced fresh
inventory synchronization when obsolete pending history cannot be replayed. Never
silently discard a required assigned record or removal while claiming successful
registration. Local resource exhaustion can still fail new entity creation; allowing
local activity does not promise unlimited offline history or unlimited endpoints.

## What ready means

Readiness is a current synchronization condition of the local participant's broker
client. It requires:

* An admitted session in the configured authority/scope, with valid ownership and
  freshness evidence and no terminal failure preventing synchronization.
* The origin inventory for the current synchronization attempt committed by that broker.
* A complete authorized downstream view installed at its declared cut, with subsequent
  deltas applied contiguously through the advertised synchronization target. Activation
  observes the presence-proof rules; staged or stale records are not active discovery.

An empty authorized view can be ready. Presence completeness is evaluated for the fixed
synchronization target: each participant is proved, withdrawn, or explicitly evaluated
as unavailable and left inactive. A complete timely proof answer may account for an
identity without granting a lease. Missing chunks or an expired query do not establish
that completeness. Existing valid evidence is not revoked by an unavailable result.
See [presence completeness](broker-presence-completeness.md). READY does not require
all cached remote participants to be active simultaneously. The target is fixed for each synchronization
attempt, not moved forward forever by concurrent remote churn. Local changes after the
origin cut can remain pending without invalidating that completed cut. Report that
pending work separately; READY is not acknowledgment of all subsequent announcements.

A transport failure, resync requirement, detected delivery gap, expired local ownership
proof or known registration rejection that prevents faithful advertisement makes the
client not ready. Ordinary expiry/removal of a remote participant does not itself make
an otherwise synchronized client unready; it updates the view normally. Existing valid
peer state and direct data paths follow their independent lease/liveliness rules.

No callback must execute for the readiness predicate to become true. An application
reading READY observes a fact at one point in time, not a promise it remains true.

## Readiness wait

Proposed semantic operation on zzdds::DomainParticipant:
`wait_discovery_ready(max_wait) -> DDS::ReturnCode_t`.

For v1 this operation is supported when a broker service is enabled, including mixed
direct/multicast/broker configurations. Without a broker it returns UNSUPPORTED until
another discovery mechanism has its own readiness meaning specified. It does not silently
wait for endpoint matches or pretend SPDP converges to a complete graph.

* If ready at admitted observation, return OK immediately. Zero duration is a poll:
  not-ready returns TIMEOUT unless a terminal failure already applies.
* Otherwise follow this participant's recovery across reconnects, session/view changes
  and broker epochs, retaining one absolute deadline. Do not follow another participant
  lifetime, scope or configured independent broker authority.
* Commit OK when a current valid generation meets the predicate. Old-session messages
  cannot complete the wait. Once committed, later disconnect does not rewrite OK.
* Timeout commits TIMEOUT if still unresolved at the original deadline. A recognized
  participant close resolves ALREADY_DELETED. A terminal synchronization failure returns
  ERROR, or OUT_OF_RESOURCES for a proven unrecoverable local capacity refusal.
* Invalid duration returns BAD_PARAMETER. Resource failure registering the wait returns
  OUT_OF_RESOURCES. Ordinary scheduling contention is not a failed precondition.
* A recoverable disconnect/backoff does not return ERROR immediately. Authentication,
  authorization, protocol incompatibility and exhausted recovery budget are terminal
  for that attempt and remain observable until corrected/recovery is explicitly possible.

Use the concurrency contract's deadline/result arbitration and retained-lifetime rules.
The wait helps permitted internal progress, retains callback rights if entered from a
callback and does not dispatch nested automatic listeners. Reject a proven self-dependency
with ERROR. It does not create an extra operational runtime lease. An infinite wait is
allowed by the explicit wait API, with the ordinary possibility of never becoming ready;
that does not make infinite startup waiting the default.

## Status and asynchronous failures

Expose a non-resetting coherent status getter on the zzdds participant extension. Its
bounded result describes client phase, ready flag, monotonic status revision, broker
and synchronization generations, view mode/completeness, pending announcement count,
current failure category. Affected entity/revision details, when known, are supplied
through bounded diagnostics/logging in v1; programmatic per-record enumeration is deferred. Counters describe
current unresolved work; keep historical diagnostic counts separately. Credentials and
unbounded payload/error strings are not status fields.

Use explicit reason categories for connection/recovery, authentication/authorization,
protocol incompatibility/conflict, local/broker capacity and registration rejection.
A getter read does not consume an error and the last diagnostic is not necessarily a
current failure. Scope terminal errors and their clearing to the relevant generation;
a stale completion cannot clear a newer failure.

Local entity creation succeeds or fails at local admission. A later rejection keeps
that entity locally valid, marks its discovery registration failed and makes broker
readiness false while the failure prevents accurate advertisement. Ordinary pending
updates are not terminal errors. An idempotent retry keeps the same origin revision;
a corrected new value uses a newer revision. Deleting an endpoint does not erase an
unconfirmed removal obligation: retain bounded tombstone/inventory repair state until
remote absence is established or the old ownership expires/is fenced.

Reserve failure bookkeeping with admitted announcement work so a full queue cannot
silently lose the only error report. Logs can be rate-limited; current status cannot
silently forget unresolved failure. A later successful repair clears the applicable
current failure without erasing diagnostic history.

Provide an optional zzdds discovery-status listener with coalesced latest-state
notification and an immutable status snapshot/revision. It uses the participant's
existing entity, canonical listener and configured group exclusion; no private callback
thread or new DDS StatusMask bits. Replacement/claim and absent-callback preservation
follow the listener contract. Intermediate transitions may coalesce, so it is not an
exact event log. Installing a listener provides catch-up to current status. Getter/wait
behavior does not depend on a listener being installed. Exact IDL spelling and bounded
reason types follow acceptance; no production listener interface is added here.

## Registration barrier scope

Do not add a separate per-endpoint registration barrier in initial v1. It is useful but
is not required to state readiness correctly. Pending/error status and initial origin
commit remain observable. A later barrier must capture a local mutation frontier and
specify superseded revisions, deletion, reconnect and epoch replacement; neither READY
nor a matched-reader status may be documented as that barrier today.

## Required validation and next step

Before implementation publication, cover: broker unavailable at construction; wrong
credentials versus transient disconnect; empty-view readiness; continuous churn after
fixed cuts; reconnect/epoch change during a wait; timeout versus READY and delete;
late old-session completion; endpoint rejection followed by repair/removal; and status
coalescing/absent listener under manual and hosted progress. These are concrete integration
checks, not a request for another scheduler prototype.

Startup default, recovery-following wait and optional status listener/no separate
registration-barrier initial scope are accepted. Validate same-participant endpoint
creation/matching/deletion before first broker contact and through outage/recovery,
including stale self-echo and local data transfer over supported configured paths.
Next draft the control-message schema and wire compatibility rules, preserving these
application-visible distinctions. Concrete generated API signatures remain part of
that integration review.

The [public API proposal](broker-public-api.md) now supplies concrete draft Config and
status/listener signatures. These remain subject to generated-binding review.
