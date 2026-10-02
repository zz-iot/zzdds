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
Internal broker control endpoints must not appear as user publishers/subscribers or
pollute application DDS built-in topic views. The broker supplies WLP endpoint information;
WLP and user-topic traffic remain direct.
There is no v1 metatraffic forwarding or tunnel service.

## Safety invariants and identity

Only the admitted owner may mutate its participant and endpoint state. Transport
reachability does not confer ownership. Participant and endpoint GUIDs survive reconnect;
a restarted participant process uses a fresh GUID prefix. Endpoint deletion/recreation
uses a fresh endpoint GUID in v1, rather than reusing retired native writer state.

Broker streams must not occupy an origin's native SEDP writer sequence space. A broker
ACK does not assert delivery to all observers. User-data locators must not be inferred
or rewritten into broker control locators. Participant installation precedes dependent
endpoint installation. Removing a participant removes its endpoint/route associations
before publishing a participant-lost callback; surviving independent discovery sources
are reconciled under [coexistence](coexistence.md).

Replay must not resurrect removed entities or indefinitely renew stale presence.
Broker reachability, participant presence, writer liveliness and peer-path reachability
are distinct facts. Disclosure policy bounds candidate filtering; within that ceiling,
incomplete type/QoS knowledge must not suppress possible matches. Resource limits require
visible rejection, bounded retry or explicit resynchronization, never successful truncation.
Protected discovery must never silently fall back to plaintext.

Every ownership, cache, inventory, view and recovery identity includes the admitted
Scope = (domain_id, domain_tag) within its configured authority. Partition QoS does not
replace this scope or provide authorization. Validate origin metadata against admitted
scope and endpoint GUID prefixes against the owner participant.

| Value | Definition |
| --- | --- |
| broker_epoch | Fresh unpredictable 128-bit value for each non-resumable store lifetime; invalidates prior cursors and delivery streams |
| participant_guid | The application's native DDS participant GUID |
| incarnation_id | Random 128-bit registration incarnation fixed for that participant lifetime; additional stale-session defense, not a substitute for a new restart GUID |
| session_id | Unpredictable admitted transport-session identifier |
| owner_generation | Broker-issued fencing generation; only the current generation may publish for the incarnation |
| entity_key | Scope, participant incarnation, record kind and entity GUID |
| origin_revision | Strictly increasing unsigned 64-bit per-entity counter starting at one, including removals |
| view_generation | Client-assigned, increasing per session/request; invalidation requires a new request. A resume cursor separately retains its old baseline identity |
| delivery_seq | Contiguous per-client, per-view delivery order, distinct from native RTPS writer sequence numbers |

Counters must not wrap. Before exhaustion, establish a fresh relevant session/view or
entity identity; do not reset a counter within the old identity. Store cuts, transaction
identifiers and RTPS stream identities retain their separate wire-defined purposes.

## Runtime and application behavior

Client and broker service protocol logic must support both manual and hosted drivers.
Unsupported backend/platform combinations fail explicitly; a manual-only configuration
must not silently spawn workers. Use the common concurrency runtime and listener contracts. No private per-participant
broker thread, mandatory callback handoff or callback-dependent recovery is required.
Serialize client admission, inventory/view commits, matching and close through participant
control or a subordinate owner with explicit ordering. Service commits serialize per scope,
without requiring a global broker mutex or one thread. Reconcile views in bounded fair
turns and publish validated visibility changes. Control priority must not indefinitely
starve STATE or direct metatraffic. Never
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

Participant close fences mutations and routes, cancels retry/renewal and publishes its
cleanup obligation before releasing runtime ownership. Send CLOSE when possible, but
local deletion/retirement never waits for CLOSED, broker availability or lease expiry.
A late COMMIT cannot reopen the local participant.

## Loss of broker service

Connection failure immediately clears current readiness and reports recovery through the
API's phase/reason fields; "degraded" describes usability, not an extra DiscoveryPhase.
Do not immediately erase installed peers. Existing direct traffic may continue while
its presence and writer-liveliness evidence remains valid. Expired broker presence causes
normal association teardown unless another enabled discovery source independently sustains
it. Reconnection does not extend old leases.

Use one authoritative service per scope in v1. Multiple addresses may identify that same
authority; do not merge independent brokers or describe an arbitrary server list as HA.
A new epoch requires re-registration, fresh origin inventory and downstream resynchronization.
Stage replacement and preserve unchanged still-valid associations where possible. Within
a retained epoch, downstream resume additionally requires the retained baseline and
validated ownership, view configuration and history; a cursor alone is insufficient.

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

## Broker operations and resource reporting

Configure and report finite bounds for sessions, participants, endpoints per participant
and scope, raw records, views, mutations, repair history, tombstones, staging, incomplete
inventories, fragments, unauthenticated work, candidate records and per-principal egress.
Admission accounts for requested disclosure/output, not only ingress size. In insecure v1,
"principal" denotes a configured accounting identity, not authenticated DDS identity.
An observer exceeding retention limits is invalidated or disconnected with a reason;
it must not block all origins. Failed origin announcements remain observable and bounded.

Broker process readiness means it can admit and serve configured scopes, not merely listen
on a socket. Provide graceful drain, administrative scope/disclosure controls, structured
logs, authorized read-only graph inspection and protocol-version/build reporting. These
are broker-operator facilities, not additional participant Config methods. Inspection must
respect the disclosure ceiling and bounded results; expanded diagnostic enumeration and
pagination APIs are not required for initial application v1. Management access needs an
explicit deployment authorization boundary even when DDS discovery is insecure.

Graceful drain stops new admission and permits bounded completion/closure of existing
sessions; it must not keep a process alive indefinitely for an unresponsive client.
Persistence and consensus HA are later capabilities. Loaded durable records are unconfirmed
hints until ownership and freshness are re-established.

Report admission/authentication failures as applicable, active/degraded sessions,
participant/endpoint counts, commit-to-apply and readiness latency, expiry/withdrawal
reasons, queue bytes, repair traffic, snapshot retries, cursor invalidations,
duplicates/conflicts, route errors and direct-path success. Relay utilization is required
only when relays exist. Use bounded labels and redacted sampled traces, not unbounded
GUID/topic labels or credential/cookie logging.

A session must not mechanically create a receive/heartbeat thread for each logical
CONTROL/STATE endpoint. Any threaded prototype has a measured client/thread/memory bound;
large-scale claims require an evented backend or measured evidence for the claimed range.
Centralization can lose on small/local workloads; comparisons must include them.

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

### Built-in service extension boundaries

In v1, broker-installed participant metadata establishes native WLP associations from
advertised capability and metatraffic locators. Preserve native identities, dispatch and
repair; receiving WLP must not require peer SEDP discovery exchanges. The broker never
synthesizes AUTOMATIC or MANUAL_BY_PARTICIPANT assertions from session timers;
MANUAL_BY_TOPIC stays on its writer/data path. Reachability of metatraffic and user data
must be evaluated independently.

Preserve TypeInformation, TypeIdentifiers and built-in endpoint availability now.
When TypeLookup is implemented, preserve request/related identities, target service
identity, minimal/complete distinctions and dependency traversal. The broker must not
answer as an origin. A future type-cache service uses its own explicit identity, validates
TypeObject/TypeIdentifier consistency and dependencies, bounds size/depth/cycles, and
obeys scope/disclosure authorization. Hash identity is not permission to reveal a type.
Such a cache is never needed to bootstrap broker discovery.

### Deferred traversal and relay constraints

Control reachability does not imply a data mapping: a TCP connection supplies no UDP
mapping, and a UDP mapping belongs to its actual socket. Observed addresses are path
observations, not rewritten advertised locators. Routed/VPN or port-mapped deployments
can use direct paths; private peers that can reach only the broker may discover but
remain unable to exchange data. Disjoint data transports are not translated by v1.

A future ConnectivityAgent separates gather/exchange/check/nominate/invalidate/close.
Its negotiated record namespace is outside original SPDP/SEDP bytes. Candidates identify
owner incarnation, transport component/socket or connection role, generation, address
family, type, foundation/priority, related address and expiry. Credentials are disclosed
only to authorized candidates and are never logged. IPv6 interface scope and overlapping
private networks require local network context; separate sockets do not share mappings.

Use ICE/STUN/TURN with their applicable standards when implemented; ICE-TCP is a separate
capability, not implied by TCP broker control. Preserve direct-only, direct-preferred and
explicit forced-relay policy space, with direct-preferred as the intended default. Bound
candidate checks and direct-attempt time before permitted fallback. Enforce destination
policy so candidate exchange cannot trigger unrestricted network scanning. Nomination
changes local routes, not origin GUIDs or retained discovery bytes, and covers data and
native repair/control in both directions. Native duplicate handling still applies.

Signaling, STUN service and relay data-plane allocation are distinct components, which may
be colocated. Relay allocation ownership, peer permissions and active-use lifetimes are
separate; specify credentials, quotas, refresh, channel binding and expiry before shipping.
TURN access transport and relayed peer transport are separate negotiated capabilities.
No automatic allocation may incur cost outside configured policy. Entire protected
messages remain opaque to a relay; no locator substitution, re-signing or replay into a
new recipient crypto session is authorized.
