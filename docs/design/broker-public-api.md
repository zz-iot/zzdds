# Broker public configuration and status API

Status: W1 consolidated public API review, 2026-09-23. Reconciles accepted independent
discovery, readiness and runtime contracts. These are design fragments for zzdds.idl,
not production IDL changes, generated ABI guarantees or accepted TOML syntax.

## Creation and compatibility

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
[service introduction](broker-service-introduction.md). All-disabled remote discovery is
valid; same-participant matching still works through the local path.

## Proposed Config fields

Within module zzdds (existing types omitted):

```idl
enum BrokerStartupPolicy { BROKER_ALLOW_DEGRADED, BROKER_REQUIRE_READY };
enum BrokerViewPolicy { BROKER_VIEW_ALL, BROKER_VIEW_TOPIC_CANDIDATES };
enum BrokerSecurityPolicy { BROKER_SECURITY_UNSPECIFIED,
                            BROKER_TRUSTED_NETWORK, BROKER_AUTHENTICATED };
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
    @default(BROKER_SECURITY_UNSPECIFIED) BrokerSecurityPolicy security;
    string<256> credential_ref;
    BrokerBootstrapConfig bootstrap;
};
// Add to the existing DiscoveryConfig, preserving its existing fields:
// @optional boolean peer_discovery_enabled;
// @optional boolean multicast_enabled;
// BrokerDiscoveryConfig broker;
```

Address/reference bounds above are proposed public limits. Standard domain identity is
configured once on DomainConfig: existing id plus `@default("") string<256> tag`.
There is no broker realm. See the accepted [domain identity decision](broker-domain-identity.md)
for standard encoding, defaults and required native support. The participant's resolved
domain identity is used by ordinary discovery and broker admission alike.

One enabled broker configuration identifies one authority/scope in v1. Addresses are
ordered alternative transport addresses for that authority, not a federation or multiple
independent stores. At most one admitted session is active. Reconnect through another
address follows epoch/ownership and fresh-inventory rules. Retire/fence old candidate work
before replacement; late replies cannot select another authority or revive a session.
Do not imply replicated-server continuity merely because two addresses share a list.
Authenticated provider configuration must bind expected service identity, not just trust
any certificate accepted by a broad trust store.

Each address explicitly selects UDP or TCP; endpoint grammar and transport provider
validation must reuse zzdds transport channels. Broker control transport is independent
of user-data transport enable flags. Enabling broker TCP does not require enabling TCP
user data, nor does disabling UDP user data disable an explicitly selected UDP broker
channel. Unsupported requested providers fail construction, including authenticated
profiles unavailable in the build. No fallback to plaintext. Security UNSPECIFIED is
valid only while broker service is disabled; enabling it requires an explicit trusted
network or authenticated policy. credential_ref names provider configuration, never an
inline secret. Transport authentication is not DDS Security participant authentication.

Initial v1 has fixed cached discovery and direct-only user/WLP traffic: omit configurable
relay/ICE/profile selectors until supported. Existing illustrative future settings do not
promise implemented relay, TypeLookup or DDS Security behavior.

Unspecified bootstrap values resolve to finite build/platform defaults. Zero is not an
alias for infinity or default; reject it for these fields. Require retry_min <= retry_max,
checked duration conversion, sufficient transport/provider minima and bounded buffers.
Publish exact resolved defaults with the implementation; this draft does not claim an
untested timeout or safe MTU. The [lifecycle contract](broker-bootstrap-lifecycle.md)
defines whole-message preflight, result retention and deadlines. Use the runtime's common resource configuration and finite defaults for the initial
resource plan; detailed wire limits are derived internally. The accepted
[resource scope](broker-resource-diagnostics.md) defers additional broker-specific tuning
knobs and the resolved-plan getter.

Local detectable errors fail construction even under allow-degraded. Remote oversize
introductions, dropped replies and transient outages leave an allow-degraded participant
locally usable with observable failure/retry state. require_ready uses a finite configured
startup deadline and rolls back an unsuccessful construction. An explicit later readiness
wait may be infinite; recovery does not extend its original deadline.

## Readiness and status signatures

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

## Review and integration gates

The v1 resource/diagnostic scope is settled. Remaining W1 specification work is the
consolidated IDL fragment and consistency review of return codes, bounded values and
listener ownership. Generation, sequence/string defaults, TOML roundtrip and binding
validation remain explicit integration gates; they must not expand the accepted API scope. Generator improvements belong in zidl and remain in scope. No hand-written
binding shortcut or production IDL mutation is justified by this design fragment alone.

Required compatibility cases: untouched standard DDS app; broker-only preset; mixed
multicast/direct/broker configuration; unicast-only ordinary peers; all-remote-discovery-off;
unsupported security/provider; local message preflight failure versus remote timeout;
allow-degraded local matching; require_ready rollback; listener-free status/wait; and status
coalescing across session replacement under manual and hosted runtime progress.

The accepted [resource and diagnostic scope](broker-resource-diagnostics.md) requires
internal bounds and visible current failure, while deferring extra tuning knobs, a
resolved-plan getter and failure enumeration. No pagination contract is needed in v1.

## Enablement interaction — accepted 2026-09-23

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

## Final review clarifications

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

See [public API review](broker-public-api-review.md) for return mapping, audit disposition
and remaining implementation gates. These fragments still require generated ABI review.
