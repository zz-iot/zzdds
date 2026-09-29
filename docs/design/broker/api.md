# Broker: api

This is a current contract. Scope, decisions and implementation gates are in
[the single status index](../concurrency-broker-status.md). Validation results are maintained
only in [the evidence inventory](../../../test/design-models/README.md).
<a id="broker-public-api"></a>
## Broker public configuration and status API

<a id="broker-public-api--creation-and-compatibility"></a>
### Creation and compatibility

Keep `DomainParticipantFactory.create_participant_ex(..., DomainParticipantConfig)`.
Ordinary DDS creation uses the factory's configured defaults; unconfigured applications
retain today's SPDP behavior. Broker settings are construction-time values copied into
participant-owned state. Changing factory defaults affects subsequent participants only.
No broker API, status bit or configuration type belongs in dcps.idl.

Retain DiscoveryKind and its existing numeric values as compatibility presets. Add
optional overrides, resolved once before resource admission:

| Preset | Ordinary peer discovery | Multicast discovery | Broker service |
| --- | --- | --- | --- |
| DISCOVERY_SPDP (default) | enabled | enabled subject to configured multicast groups | disabled |
| DISCOVERY_BROKER | disabled | disabled | enabled |
| DISCOVERY_STATIC | existing static behavior | disabled | disabled |

An explicit override wins over the preset. Invalid resolved combinations fail local
configuration validation; no implicit fallback changes the resolved settings. Initial v1
rejects mixing STATIC with the dynamic controls until static-source coexistence is defined.
`multicast_enabled=true` requires `peer_discovery_enabled=true`. Peer discovery without
multicast accepts ordinary unicast introductions and sends to configured initial peers;
it does not mean that all ordinary peers must be listed in advance. Broker service
requests remain restricted to configured service associations.

A BROKER preset with explicit peer/multicast overrides enables coexistence. A SPDP preset
with broker.enabled=true does likewise. Merely filling broker addresses does not activate
it. Existing discovery.initial_peers and UDP initial_peers remain ordinary peer seeds,
not broker addresses; preserve their existing merge semantics during migration and
normalize/deduplicate them before use. Supplying active ordinary seeds while disabling
peer discovery is a configuration error, rather than silently contacting those peers.

Broker-introduced peers never automatically become ordinary SPDP/SEDP seed destinations.
Multicast controls discovery traffic only, not multicast user-data transport. Stable
participant-wide capability advertisement and per-association endpoint eligibility follow
[service introduction](protocol.md#broker-service-introduction). All-disabled remote discovery is
valid; same-participant matching still works through the local path.

<a id="broker-public-api--proposed-config-fields"></a>
### Config fields

Within module zzdds (existing types omitted):

```idl
enum BrokerStartupPolicy { BROKER_ALLOW_DEGRADED, BROKER_REQUIRE_READY };
enum BrokerViewPolicy { BROKER_VIEW_ALL, BROKER_VIEW_TOPIC_CANDIDATES,
                        BROKER_VIEW_TOPIC_PARTITION_CANDIDATES };
typedef sequence<string<1024>, 16> BrokerAddresses;
struct BrokerBootstrapConfig {
    @optional unsigned long udp_payload_limit_bytes;
    @optional unsigned long tcp_sample_limit_bytes;
    @optional unsigned long attempt_timeout_ms;
    @optional unsigned long startup_timeout_ms;
    @optional unsigned long retry_min_delay_ms;
    @optional unsigned long retry_max_delay_ms;
};
struct BrokerDiscoveryConfig {
    @optional boolean enabled;
    BrokerAddresses addresses;
    @default(BROKER_VIEW_ALL) BrokerViewPolicy view;
    @default(BROKER_ALLOW_DEGRADED) BrokerStartupPolicy startup;
    // No independent broker security/credential selector: use participant DDS Security.
    BrokerBootstrapConfig bootstrap;
};
// Add to the existing DiscoveryConfig, preserving its existing fields:
// @optional boolean peer_discovery_enabled;
// @optional boolean multicast_enabled;
// BrokerDiscoveryConfig broker;
```

Address bounds above are proposed public limits. Standard domain identity is
configured once on DomainConfig: existing id plus `@default("") string<256> tag`.
There is no broker realm. See the accepted [domain identity decision](coexistence.md#broker-domain-identity)
for standard encoding, defaults and required native support. The participant's resolved
domain identity is used by ordinary discovery and broker admission alike.

One enabled broker configuration identifies one authority/scope in v1. Addresses are
ordered alternative transport addresses for that authority, not a federation or multiple
independent stores. At most one admitted session is active. Reconnect through another
address follows epoch/ownership and fresh-inventory rules. Retire/fence old candidate work
before replacement; late replies cannot select another authority or revive a session.
Do not imply replicated-server continuity merely because two addresses share a list.
Future DDS Security configuration must validate the intended broker participant and its
permissions. A configured address or domain/tag alone is not authenticated identity.

Each address explicitly selects UDP or TCP; endpoint grammar and transport provider
validation must reuse zzdds transport channels. Broker control transport is independent
of user-data transport enable flags. Enabling broker TCP does not require enabling TCP
user data, nor does disabling UDP user data disable an explicitly selected UDP broker
channel. Unsupported requested transports fail construction. V1 is traditional, insecure
cached discovery; it provides no cryptographic authentication, confidentiality or access
control. Secure broker operation follows participant DDS Security configuration and must
fail explicitly until the required integration exists. No fallback from requested security
to plaintext. BrokerSecurityPolicy and credential_ref from the old proposal are removed.

A candidate-view policy is a required capability, not permission to fall back to VIEW_ALL.
The operator's disclosure ceiling applies first; client topic/partition candidate selection
can only narrow it. The zzdds broker implements topic and partition candidate filtering.
If a configured client cannot use the offered filtering or bounded view, fail admission/
synchronization explicitly. Partition changes trigger re-evaluation; no QoS/type filtering
may silently suppress incompatible-QoS reporting. The registry assigns feature 1 to topic candidates and feature 6 (requiring 1) to
topic/partition candidates. Server administration syntax is an implementation surface;
this fragment introduces no arbitrary client filter-expression API.

Initial v1 has fixed cached discovery and direct-only user/WLP traffic: omit configurable
relay/ICE/profile selectors until supported. Existing illustrative future settings do not
promise implemented relay, TypeLookup or DDS Security behavior.

Unspecified bootstrap values resolve to finite build/platform defaults. Zero is not an
alias for infinity or default; reject it for these fields. Require retry_min <= retry_max,
checked duration conversion, sufficient transport/provider minima and bounded buffers.
Publish exact resolved defaults with the implementation; this draft does not claim an
untested timeout or safe MTU. The [lifecycle contract](protocol.md#broker-bootstrap-lifecycle)
defines whole-message preflight, result retention and deadlines. Use the runtime's common resource configuration and finite defaults for the initial
resource plan; detailed wire limits are derived internally. The accepted
[resource scope](api.md#broker-resource-diagnostics) defers additional broker-specific tuning
knobs and the resolved-plan getter.

Local detectable errors fail construction even under allow-degraded. Remote oversize
introductions, dropped replies and transient outages leave an allow-degraded participant
locally usable with observable failure/retry state. require_ready uses a finite configured
startup deadline and rolls back an unsuccessful construction. An explicit later readiness
wait may be infinite; recovery does not extend its original deadline.

<a id="broker-public-api--readiness-and-status-signatures"></a>
### Readiness and status signatures

Proposed operations on zzdds::DomainParticipant:

```idl
DDS::ReturnCode_t wait_discovery_ready(in DDS::Duration_t max_wait);
DDS::ReturnCode_t get_discovery_status(inout DiscoveryStatus result);
DDS::ReturnCode_t set_discovery_listener(in DiscoveryStatusListener a_listener);
DiscoveryStatusListener get_discovery_listener();
```

`wait_discovery_ready` refers to this participant's enabled broker authority even in mixed
mode. With broker service disabled it returns UNSUPPORTED; ordinary SPDP has no global
completion predicate. Existing readiness return-code, deadline, cancellation and callback
helping rules are unchanged. The getter is supported even with broker disabled, reporting
DISABLED/ready=false. Invalid configuration is not represented as a live participant.

Proposed bounded snapshot, with numeric enum assignments deferred to the IDL review:

```idl
enum DiscoveryPhase { DISCOVERY_DISABLED, DISCOVERY_WAITING_FOR_ENABLE, DISCOVERY_CONNECTING,
    DISCOVERY_INTRODUCING, DISCOVERY_REGISTERING, DISCOVERY_SYNCHRONIZING,
    DISCOVERY_READY, DISCOVERY_BACKOFF, DISCOVERY_FAILED };
enum DiscoveryFailure { DISCOVERY_NO_FAILURE, DISCOVERY_TRANSPORT_FAILURE,
    DISCOVERY_TIMEOUT, DISCOVERY_INCOMPATIBLE, DISCOVERY_UNAUTHORIZED,
    DISCOVERY_OWNER_CONFLICT, DISCOVERY_LIMIT, DISCOVERY_MESSAGE_TOO_LARGE,
    DISCOVERY_LOCAL_RESOURCE_FAILURE, DISCOVERY_PROTOCOL_FAILURE,
    DISCOVERY_BACKEND_FAILURE, DISCOVERY_REGISTRATION_REJECTED };
struct DiscoveryStatus {
    unsigned long long revision;
    DiscoveryPhase phase;
    boolean ready;
    BrokerViewPolicy view;
    boolean view_complete;
    boolean retry_pending;
    DiscoveryFailure current_failure;
    boolean has_session;
    octet broker_epoch[16];
    octet session_id[16];
    unsigned long long owner_generation;
    unsigned long long view_generation;
    unsigned long long pending_local_records;
    unsigned long long rejected_local_records;
};
@callback interface DiscoveryStatusListener {
    void on_discovery_status(in DDS::DomainParticipant participant,
                             in DiscoveryStatus status);
};
```

The getter copies an atomic snapshot and never clears status or consumes a notification.
No borrowed arrays, strings or wire-buffer views escape. Failure leaves the caller's
inout result unchanged under the shared result-publication contract. When has_session
is false, session fields are zero and cannot be interpreted as a previous live session.
A current session may be synchronizing with view_generation=0 before a view is assigned.
Counts are bounded outstanding current work, not lifetime totals. READY and pending local
records may coexist after the fixed synchronization cut. The snapshot is deliberately not
per-endpoint rejection detail, a diagnostic log or a proof of peer data connectivity.
Retain unresolved failures until repair; rate-limited logs provide detail without secret
material. Affected GUID/revision and reason are available through bounded diagnostics/logging
when known. Programmatic per-entity enumeration is deferred; current unresolved failure
remains visible in this summary regardless of logging or listener delivery.

The optional listener receives an immutable snapshot valid for the callback duration.
Applications may copy it. Install retains the listener on success; nil removes it;
getter returns an owned language-mapped reference. Canonical listener identity, exclusion,
replacement/quiescence and deletion follow the accepted binding/listener contract.
It uses the participant listener group and entity admission, with no new DCPS StatusMask.
Installation schedules catch-up, including DISABLED; changes may coalesce. A status revision
is monotonic within participant lifetime; updates during a callback leave newer work pending.
No callback is needed to make READY true or complete a wait. No private callback thread or
recursive automatic dispatch is introduced.

<a id="broker-public-api--enablement-interaction"></a>
### Enablement interaction

The broker Config enabled switch selects a mechanism; DDS Entity enablement is separate.
For a deliberately disabled participant, validate/reserve local configuration but do not
start broker introduction or advertise disabled endpoints. Status inspection and listener
installation remain available. DISCOVERY_WAITING_FOR_ENABLE makes this
state distinguishable from broker service disabled, network backoff or failure.

Wait rule: an existing participant with broker service configured but Entity
still disabled returns NOT_ENABLED, rather than helping an impossible readiness wait.
If broker service is absent, UNSUPPORTED applies as before. Recognized deletion retains
its existing result arbitration. Calling standard enable starts normal asynchronous
broker progress; it must not acquire a new proprietary network-wait meaning.

Accepted creation rule: require_ready plus effective autoenable=false is an incompatible
configuration, diagnosed locally through the existing nil-constructor/error-reporting
convention. Do not silently enable the participant or wait for a timeout while no caller
can yet enable it. Applications needing staged creation use allow_degraded, enable the
participant when ready, then call wait_discovery_ready explicitly. This is an accepted specification requirement, not an existing implementation behavior.

<a id="broker-public-api--final-review-clarifications"></a>
### Final review clarifications

Enabled broker configuration requires at least one nonempty, supported service address.
Validate address syntax/provider support locally; DNS resolution and connection failure
are remote-progress outcomes, not necessarily invalid construction. Omitted addresses
never mean discover any broker on multicast. Known local configuration failures are
reported before network attempts. Unused broker configuration does not activate a service;
provider availability and address-presence requirements apply when that service is enabled.

Only the factory's effective autoenable policy for this participant controls the
require_ready/disabled-construction rejection. A participant configured not to autoenable
its future children can still itself be enabled and satisfy broker readiness with an empty
endpoint inventory. Disabled children must not be exported as active endpoints or hold
initial READY hostage. Ordinary local enablement/resource preconditions still apply.

Each attempt_timeout bounds one admission attempt; retry creates a fresh attempt without
extending require_ready's startup deadline or any explicit wait deadline. Under
allow_degraded, startup_timeout does not become a hidden deadline that permanently stops
background reconnect. Finite attempt deadlines/backoff and local lifetime/resource policy
continue to bound each attempt. No configured retry-count API is implied by this contract.

`view` reports the configured/accepted view policy; negotiation cannot silently change it.
`view_complete` means the current installed view and required presence evaluation satisfy
the fixed synchronization target; it is false when no usable current view exists. An
empty authorized view can be complete; it does not mean every cached peer is alive.
`ready` additionally requires committed origin inventory and valid session/freshness with
no blocking registration failure. A complete view alone is not readiness. No session means
zero epoch/session/generation fields and view_complete=false. The configured view policy
is still reportable while disconnected. DISCOVERY_READY and ready=true are equivalent.

`pending_local_records` counts distinct retained origin records with outstanding broker
work, including unresolved rejected work; `rejected_local_records` is its failed subset.
Count a record once despite retransmissions; pending removal obligations count after entity
deletion. These are not user samples, DDS queue depth or an exact revision-commit barrier.
When broker service is disabled both counts are zero; disabled entities not yet eligible
for advertisement are not pending records. Aggregate inventory failure remains a summary
failure unless a particular affected record is identified; do not fabricate per-record blame.

current_failure is a current summary, not the last historical error. When several failures
coexist, prefer a service-wide blocker; otherwise report registration rejection while
rejected work remains. Exact GUID/revision/reason stays in bounded diagnostics. Never
clear a record failure merely because a connection attempt succeeded. BACKOFF means an
automatic retry is scheduled; FAILED means progress needs external correction or cannot
continue under current conditions. FAILED need not mean the DDS participant or its direct
matches are deleted. SYNCHRONIZING can retain a failure while repair is in progress.
retry_pending reports scheduled/in-flight corrective work, not a promise that it will succeed.

Readiness waits follow transient failures/recovery until their original deadline. They
return ERROR for a current blocking failure with no eligible autonomous recovery (or
OUT_OF_RESOURCES for the specified unrecoverable local capacity case). A rejection followed
by admitted repair is not automatically terminal. A later independent application correction
can restore progress after an earlier wait has returned ERROR. There is no hidden retry or
reconfiguration method added by this rule. Successful status reads return OK even when the
snapshot reports FAILED; observation failure is distinct from the observed state.

Getter and setter remain supported with broker disabled or Entity not enabled. Nil removes
the listener successfully. External set_discovery_listener obeys captured-frontier quiescence;
from a zzdds callback/preparation chain it publishes without waiting for retired invocations.
Preparation failure leaves the old registration unchanged. No setter TIMEOUT is invented.
A getter takes an owned reference at its observation boundary; concurrent replacement does
not invalidate that result. Nil means no installed listener; safely recognized close also
uses the binding's nil getter convention, not a fabricated handle. Callback participant
handles are borrowed for the callback and may be retained only using normal binding rules.
No participant/listener reference is serialized in Config or wire data.

See [public API review](../concurrency-broker-status.md) for return mapping, audit disposition
and remaining implementation gates. These fragments still require generated ABI review.

<a id="broker-public-api--udp-oversize-diagnostics"></a>
### UDP oversize diagnostics

For locally detected bootstrap oversize, report the encoded size and configured budget,
and name existing UdpConfig.interfaces restriction and an explicitly configured TCP broker
address as remedies. Do not silently strip canonical announcements or switch transport.
A remote offer that cannot fit may yield only a bounded timeout; do not invent its cause.

<a id="broker-readiness-contract"></a>
## Broker readiness and registration status

<a id="broker-readiness-contract--accepted-startup-default"></a>
### startup default

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

<a id="broker-readiness-contract--broker-independent-local-discovery"></a>
### Broker-independent local discovery

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

<a id="broker-readiness-contract--what-ready-means"></a>
### What ready means

Readiness is a current synchronization condition of the local participant's broker
client. It requires:

* An admitted session in the configured authority/scope, with valid ownership and
  freshness evidence and no terminal failure preventing synchronization.
* The origin inventory for the current synchronization attempt committed by that broker.
* A complete authorized downstream view installed at its declared cut, with subsequent
  deltas applied contiguously through the advertised synchronization target. Activation
  observes the presence-proof rules; staged or stale records are not active discovery.

An empty authorized view can be ready. Apply a timely nonce-correlated aggregate marker
at or after the fixed synchronization frontier. It accounts for that membership; zero or
already-elapsed evidence leaves affected origins inactive without revoking independent
valid evidence. Missing or timed-out markers do not establish freshness evaluation.
See [aggregate freshness](protocol.md#broker-aggregate-freshness). READY does not require
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

<a id="broker-readiness-contract--readiness-wait"></a>
### Readiness wait

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
Ordinary hosted waiters do not help by default; manual/callback-chain waits help only
permitted internal progress. The wait retains callback rights if entered from a
callback and does not dispatch nested automatic listeners. Reject a proven self-dependency
with ERROR. It does not create an extra operational runtime lease. An infinite wait is
allowed by the explicit wait API, with the ordinary possibility of never becoming ready;
that does not make infinite startup waiting the default.

<a id="broker-readiness-contract--status-and-asynchronous-failures"></a>
### Status and asynchronous failures

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

<a id="broker-readiness-contract--registration-barrier-scope"></a>
### Registration barrier scope

Do not add a separate per-endpoint registration barrier in initial v1. It is useful but
is not required to state readiness correctly. Pending/error status and initial origin
commit remain observable. A later barrier must capture a local mutation frontier and
specify superseded revisions, deletion, reconnect and epoch replacement; neither READY
nor a matched-reader status may be documented as that barrier today.

<a id="broker-resource-diagnostics"></a>
## Initial broker resource and diagnostic surface

Use the runtime's common finite resource plan and negotiated broker ReceiveLimits.
Initial v1 does not add a resolved-plan getter, diagnostic pagination or a new family
of per-broker resource knobs. It must still bound global/session storage, pending
challenges, staging, overlap, repair, freshness capture/output and deferred references.
The [storage contract](wire.md#broker-storage-contract) defines ownership/accounting.

Use the existing configuration path for finite build/platform defaults; explicit limits
must be validated before work is promised. Rate-limited logs plus the participant's
non-resetting current status expose failure without a listener. Credentials, cookies and
unbounded entity/topic labels are not diagnostics. Per-record detail can be logged
boundedly; no unbounded status payload is permitted.

The [public API](api.md#broker-public-api) controls the v1 Config/status fields. Expanded
resource controls and programmatic diagnostic enumeration remain later extensions.
The [archived proposal](../archive/review-baseline/broker-resource-diagnostics.md) is not a
second public API or a requirement to ship those deferred controls.
