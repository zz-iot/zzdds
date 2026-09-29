# Centralized discovery broker

The broker distributes participant and endpoint discovery information so applications
can discover across network boundaries or reduce distributed discovery overhead. It does
not make an unreachable peer transport reachable by itself. This specification targets
general DDS use, not a ROS 2-specific topology. Start at the
[single contract index](../concurrency-broker-status.md).

## V1 scope

V1 is cached, traditional insecure discovery over configurable zzdds UDP or TCP channels.
Control transport is independent of user-data transport. Multicast, ordinary directed
SPDP and broker discovery are independent configuration choices; broker-only is a preset.
One client has one admitted authority/session, with alternative configured addresses for
that authority. Address lists do not imply federation or replicated-store continuity.

Scope is standard domain ID and domain tag. A broker serving several scopes presents one
logical service participant per scope; implementations may share sockets and workers.
Canonical participant SPDP payloads remain recipient-independent. Directed inline vendor
context identifies broker intent and capability without making the broker a normal SEDP
peer. Introduction, transport eligibility and native service endpoint roles are specified
in [protocol](protocol.md) and [coexistence](coexistence.md).

Store original SPDP/SEDP payload bytes and unknown optional metadata alongside parsed
indexes. Validate scope, ownership, revisions and dependencies before installation. Broker
expiry and filtered-view withdrawal are source changes, not invented DDS dispose events.
Matching, enablement, ignore, security and direct-source evidence retain their own rules.
The broker supplies WLP endpoint information; WLP and user-topic traffic remain direct.
There is no v1 metatraffic forwarding or tunnel service.

## Runtime and application behavior

Use the common concurrency runtime and listener contracts. No private per-participant
broker thread, mandatory callback handoff or callback-dependent recovery is required.
Reconcile views in bounded fair turns and publish validated visibility changes. Never
hold a global store lock across network output, foreign code or application callbacks.

Same-participant local endpoint matching must work before first broker contact and through
outages. Default `allow_degraded` construction returns a locally usable participant while
recovery proceeds. `require_ready` is an explicit finite startup wait and rejects disabled
construction. API phases are CONNECTING, INTRODUCING, REGISTERING, SYNCHRONIZING and READY,
with BACKOFF/FAILED recovery outcomes; DISABLED and WAITING_FOR_ENABLE cover configuration
and enablement. ACCEPT completes registration and starts synchronization. No separate
public ADMITTED/SYNCING/DEGRADED enum is implied. Teardown is terminal lifecycle behavior,
not an additional DiscoveryPhase value. [API](api.md) owns exact enum spelling and results.

READY means the fixed origin/view/freshness synchronization target was met. It does not
prove all peers are active, compatible, reachable or caught up with every later change.
Reconnect requires fresh origin inventory; optional downstream resume independently
resolves retained identity/history. Listeners do not gate protocol completion.

## Scaling and bounded failure

For N participants, E endpoints, retained raw bytes B and R endpoint-to-observer
relationships, cached state is approximately O(B+E+N+R), excluding explicitly bounded
queues. Client-to-broker reliability associations are O(N). ALL disclosure still costs
O(N*E); all-to-all information cannot be removed by centralization. Candidate views reduce
R within the operator ceiling, without filtering away incompatible-QoS diagnostics.

Retain raw bytes once where possible, with per-view dependency accounting. Bound snapshot
staging, replacement overlap, repairs, origin tombstones, deferred references, output and
freshness captures. Coalesce only before assigning required delivery sequences. Capacity
failure must reject, backpressure or invalidate/resynchronize explicitly; it cannot become
partial successful discovery. Reserve CONTROL/recovery capacity independently of STATE.

Aggregate freshness reduces recurring output but does not by itself reduce capture CPU.
The [protocol](protocol.md) defines actual frontier/expiry checks, bounded exceptions,
clock assumptions and rate-limited cadence. Measure steady state, startup, churn, failing
origins, correlated renewal failure and slow clients separately. Use bounded metric labels
and avoid logging cookies, credentials or unbounded topic/GUID sets.

## Later capabilities

TypeLookup should reuse retained native identities, metadata and direct built-in routes
when implemented; cached type information does not imply a working lookup service.
DDS Security-derived trusted cached discovery comes before opaque-peer mode. Those modes
have different trust costs, detailed in [security and filtering](security-and-filtering.md).
No TLS/DTLS-first requirement or secure-to-plaintext fallback is introduced.

Traversal is a separate transport capability. A future connectivity agent can gather and
exchange ICE candidates, check/nominate paths and invalidate generations. Prefer direct
peer paths. A participant may later request a leased broker-owned relay allocation and
advertise its custom locator in its own announcements. Allocation renewal, peer permission,
quotas, expiry, transport support and opaque encrypted traffic need a separate protocol;
this is not permission to resurrect the retired per-message broker ROUTE service.
Relay lease identity must remain distinct from participant discovery freshness and WLP.
Federation, persistence/HA, management pagination and registration continuity tokens are
separately scoped follow-ons. D2 reserves the optional continuity capability for v1.1.
