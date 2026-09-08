# Centralized discovery broker for zzdds

Status: proposed design specification, revision 0.1, 2026-09-08. No implementation is included. MUST, SHOULD, and MAY express requirements of this proposed zzdds protocol, not additional OMG requirements. Wire identifiers and generated IDL require a subsequent protocol-freeze review; implementation must not invent incompatible private assignments independently.

## 1. Decision

Implement an opt-in **BrokerDiscovery** plugin and a separate **zzdds discovery broker** executable. The broker distributes participant and endpoint state; applications exchange user data directly. Both UDP and TCP client connections use zzdds transports and the same discovery semantics. Discovery transport selection is independent of user-data transport selection.

Use an explicitly versioned alternative participant/endpoint discovery protocol, with the existing SPDP/SEDP serialized discovery data as its authoritative payload. The broker owns its delivery streams; original participants own the advertised entities. Never impersonate an origin's SEDP writer to make cached discovery look like an ordinary peer transmission.

Provide a separate, destination-addressed **metatraffic route** for built-in protocols that need exchanges between actual participants: WLP now, TypeLookup and DDS Security later. This carries protocol messages, including their reliability control messages, without interpreting them as cached endpoint state. It is a small control-plane forwarding service. It does not grant permission to forward user topics.

There are two discovery profiles:

| Profile | Behavior | Initial scope |
| --- | --- | --- |
| `cached` | Broker retains origin-owned SPDP/SEDP payloads and distributes state through independent reliable streams. Clients trust broker discovery assertions. | Required in v1 |
| `opaque_peer` | Broker introduces participants and routes original native peer metatraffic; secure discovery is validated by the actual peers. No broker interpretation of encrypted endpoint discovery. | Reserved architecture; implement with DDS Security |

This distinction is essential: preserving a ParameterList is useful extensibility, but it does not make a plaintext cache a transparent DDS Security intermediary.

## 2. Standards boundary and prior art

RTPS 2.5 §8.5.6 explicitly permits alternative discovery protocols, including central lookup services, while requiring implementations to support SPDP/SEDP for interoperability. Section 9 specifies the UDP/IP mapping; this document does not claim that zzdds's TCP framing is an OMG-interoperable TCP protocol. [OMG DDSI-RTPS 2.5](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

The baseline references are [DDS 1.4](https://www.omg.org/spec/DDS/1.4), [RTPS 2.5](https://www.omg.org/spec/DDSI-RTPS/2.5), [XTypes 1.3](https://www.omg.org/spec/DDS-XTypes/1.3), and [DDS Security 1.2](https://www.omg.org/spec/DDS-SECURITY/1.2). Preserve DDS entity identity, QoS interpretation, matching, and status behavior in the clients. Broker protocol extensions, routing metadata, tenant isolation, and session leases are zzdds-specific.

Relevant comparisons, consulted after examining zzdds:

| System | Useful evidence | Consequence for this proposal |
| --- | --- | --- |
| OpenDDS RtpsRelay | Forwards RTPS across NAT, distinguishes SPDP/SEDP/data traffic, and uses STUN and ICE. Its documented ICE implementation does not use TURN. | Separate traffic classes and candidate gathering by actual socket; do not make data relaying the default. [OpenDDS documentation](https://opendds.readthedocs.io/en/master/devguide/internet_enabled_rtps.html) |
| Fast DDS Discovery Server | Reuses discovery structures, supports TCP and redundant servers, and keeps user data direct. The current 3.x documentation distinguishes Pro filtering from unfiltered open-source distribution; older v2 descriptions should not be assumed to describe current editions. | Independent transport configuration and explicit disclosure modes are useful; benchmark rather than assume filtering guarantees. [Current documentation](https://fast-dds.docs.eprosima.com/en/3.x/fastdds/discovery/discovery_server.html) |
| RTI Cloud Discovery Service | Centrally forwards participant announcements and preserves domain isolation; documents additional domain tags. | Participant rendezvous is a viable simpler alternative, but by itself does not meet the endpoint-discovery scaling objective. Preserve numeric domain isolation explicitly. [Core concepts](https://community.rti.com/static/documentation/connext-dds/current/doc/manuals/addon_products/cloud_discovery_service/core_concepts.html) |

No wire compatibility with these services is promised. Unmodified third-party DDS participants use the existing SPDP/SEDP path. A broker merely configured as an ordinary initial peer is not sufficient to speak this protocol.

### Alternatives rejected for the primary profile

* **SPDP introductions only:** attractive for maximum native reuse, but SEDP remains peer-to-peer, including its reachability and scaling costs. Retain as a possible compatibility mode.
* **Blind RTPS forwarding only:** valuable for protected peer exchanges, but retains peer reliability state and potentially quadratic traffic. This is the future opaque profile, not the optimized cache.
* **Republish cached SEDP with origin GUIDs and new sequence numbers:** creates ambiguous writer ownership, ACK routing, replay and security behavior. Reject.
* **A fresh topic-name/QoS JSON directory:** loses protocol information and becomes a second implementation of DDS semantics. Reject.
* **A DDS data router:** changes the user-data topology and trust model. Outside the discovery service's initial purpose.

## 3. Scope and invariants

V1 includes a single authoritative broker, UDP and TCP sessions, bounded reliable state distribution, complete late-join synchronization, endpoint disposal, participant expiry, all-domain and conservative topic-based disclosure, WLP forwarding, authenticated deployment options, metrics, and reconnect recovery. It supports routed networks, VPNs, public addresses, and operator-configured port mappings. Automatic NAT traversal is not a v1 claim.

Required invariants:

1. An application participant's GUID and endpoint GUIDs survive broker reconnects. A new participant process/incarnation uses a new GUID prefix; reconnect is not participant reincarnation.
2. Only the admitted owner may mutate its participant and endpoint state. Broker transport identity and entity ownership are different concepts.
3. Broker streams never inhabit an origin's native SEDP sequence space. A broker acknowledgment does not assert receipt by every remote participant.
4. User-data locators never become broker control locators by inference or rewriting.
5. Participant state is installed before dependent endpoints. Removing a participant removes all its endpoints and associated routes before the participant-lost callback.
6. Delivery replay cannot resurrect a removed entity or refresh a dead participant indefinitely.
7. Broker reachability, participant presence, DDS writer liveliness, and peer-path reachability are separate states.
8. Broker filtering may over-disclose within authorized scope; it MUST NOT suppress a potentially matching endpoint because of incomplete type/QoS knowledge.
9. Limits produce visible errors, bounded retries, or explicit resynchronization. Never silently truncate the discovery graph and report success.
10. Security policy never silently falls back from protected discovery to plaintext cached discovery.

## 4. Logical architecture

```mermaid
flowchart LR
    A[Application A] --- DA[BrokerDiscovery A]
    B[Application B] --- DB[BrokerDiscovery B]
    DA <-->|UDP or TCP: state and metatraffic| BR[Discovery broker]
    DB <-->|UDP or TCP: state and metatraffic| BR
    A <-->|Direct RTPS user traffic and repair| B
    DA -.-> CA[Local connectivity agent]
    DB -.-> CB[Local connectivity agent]
    CA -.-> NT[Future STUN / TURN services]
    CB -.-> NT
```

The broker has four components with separate resource budgets:

* **Session/admission layer:** binds an authenticated client to a scope and participant; validates return paths and owns connection lifecycle.
* **Discovery store:** immutable origin payloads plus parsed indexes, ownership, entity revisions and tombstones.
* **View distributor:** constructs each client's authorized graph, snapshots and deltas; owns downstream reliability.
* **Metatraffic router:** forwards bounded original protocol messages using explicit source/destination participant identities and traffic classes.

A participant has a discovery-state adapter, shared discovery codecs, normal local DDS matching, and a route resolver. The route resolver separates an advertised peer locator from the currently usable direct or broker-assisted path. Network changes update routes without changing GUIDs or rewriting signed discovery.

The broker's protocol endpoints are internal control entities. They MUST NOT appear as user publishers/subscribers or pollute the application's DDS built-in topic view.

## 5. Scope, ownership and data model

Every lookup, subscription, route and cache key includes `Scope = (realm_id, domain_id)`. `realm_id` is an immutable, administratively assigned opaque identifier authorized at admission. It is not a DDS partition, topic prefix, or replacement for `domain_id`. Domain translation and cross-realm forwarding are not supported.

The broker MUST verify any domain value in origin metadata against the admitted domain. A matching DDS domain number alone grants no access. DDS partition QoS remains an endpoint matching input, not an access-control boundary.

| Value | Meaning |
| --- | --- |
| `broker_epoch` | Fresh unpredictable 128-bit value at each non-resumable store lifetime; invalidates prior cursors and delivery streams |
| `participant_guid` | Actual application's DDS participant GUID |
| `incarnation_id` | Random 128-bit registration incarnation, fixed for that participant lifetime; additional stale-session defense, not a substitute for a new GUID after process restart |
| `session_id` | Unpredictable admitted transport-session identifier |
| `owner_generation` | Broker-issued fencing generation; only one generation may publish for an incarnation |
| `entity_key` | Scope, participant incarnation, record kind, entity GUID |
| `origin_revision` | Strictly increasing unsigned 64-bit counter per entity, starting at 1; includes removals |
| `view_generation` | Changes when a client view is replaced or its filter/security scope changes |
| `delivery_seq` | Contiguous per-client, per-view delivery order; distinct from RTPS writer sequence numbers |

Counters MUST NOT wrap. Exhaustion requires a fresh relevant session/view or entity identity before further writes.

An origin record contains the key, revision, operation (`UPSERT` or `REMOVE`), serialization/profile identifier, original protocol/vendor metadata, raw serialized discovery payload, and needed change metadata (key representation, status information and inline QoS). Preserve an original built-in writer GUID/sequence number when one exists for diagnostics or hybrid deduplication; these are not the broker delivery ordering mechanism.

Use SPDP participant data and SEDP publication/subscription data encoded by shared codecs. Retain the complete owned byte representation, including encapsulation, unknown optional parameters, repeated parameters and padding. Parsed indexes are disposable derivatives. Do not decode into today's `QosSnapshot` and then reconstruct the authoritative payload. Preserve unknown locator kinds even if this broker cannot use them.

RTPS ParameterLists allow repeated parameters and distinguish ignorable from must-understand unknown parameters. Enforce that distinction when semantically accepting data; preserving bytes does not permit a client to accept semantics it does not understand. [RTPS 2.5 §9.4.2.11](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

The store may retain structurally valid opaque payloads without claiming semantic support, provided clients receive the original bytes and the index fails open within the authorized scope. Unsupported required semantics MUST prevent successful installation at a client and produce a diagnostic. Malformed lengths, ambiguous singleton keys, ownership mismatches and contradictory scope data are rejected before commit. Repeated list PIDs are not mistaken for duplicate singleton keys.

Endpoint GUID prefixes MUST belong to the admitted participant. A removal includes an explicit entity key; parsing a disposal payload is not the only way to identify the object. The original dispose/unregister status is retained separately from broker reasons such as lease expiry or loss of view interest.

## 6. Protocol and transport contract

### 6.1 Bootstrap and channels

Clients receive a list of broker service addresses out of band. No multicast, SEDP, TypeLookup, or application endpoint match is needed to bootstrap. DNS names resolve to service addresses; the authenticated service identity is independent of the resolved IP.

Use RTPS DATA/DATA_FRAG and the existing reliability machinery for explicitly configured zzdds control endpoint pairs. Their identities are assigned in a documented zzdds vendor extension namespace at wire freeze, never by reusing standardized SPDP, SEDP, WLP, TypeLookup or Security entity IDs. A minimal bounded bootstrap endpoint pair is known in advance; admission returns fresh per-session endpoint identities and capabilities. Automatic discovery of these endpoints is unnecessary.

Generate the control payload types with zidl. The envelope has an explicit protocol major/minor, operation kind, required-feature flags, scope, broker epoch, session/owner generation, request identity and bounded body. Its extensibility rules MUST allow unknown optional members while rejecting unknown required features. V1 uses one fixed baseline encoding independent of runtime TypeLookup; propose XCDR2 mutable types subject to zidl round-trip fixtures before wire freeze.

There are three logical channel classes:

| Channel | Delivery | Contents |
| --- | --- | --- |
| Control | Reliable, bounded, highest scheduling priority | Admission, commit results, view boundaries, errors and shutdown |
| State | Reliable, bounded, application snapshot/delta cursors | Origin registrations and downstream views |
| Peer metatraffic | Native end-to-end reliability; outer forwarding does not acknowledge native writers | WLP, future TypeLookup/security, complete original RTPS messages |

Lease challenges use a small expiring control exchange; stale retransmitted responses are never treated as fresh. Peer metatraffic is volatile and MUST NOT be placed in a late-join state snapshot. Underlying TCP is reliable, but that does not change a forwarded protocol's DDS durability or reliability semantics.

The same semantic messages operate over UDP and TCP. TCP preserves zzdds's existing four-byte big-endian length framing around transport messages. Do not add a competing stream delimiter. The sender's successful write is not a broker commit. Retain RTPS reliability behavior initially on both transports; optimize redundant TCP repair only after proving equivalent reconnect and history behavior.

### 6.2 Required operations

| Operation | Required semantics |
| --- | --- |
| `HELLO / CHALLENGE / OPEN / ACCEPT` | Negotiate version, required capabilities, scope, profile, limits, lease and authenticated return path; establish fencing generation |
| `ORIGIN_BEGIN / RECORD / ORIGIN_END` | Atomically publish a complete participant inventory at a local inventory cut; buffer subsequent mutations |
| `MUTATE / COMMIT / REJECT` | Idempotent single-entity change under active ownership; explicit acceptance or typed rejection |
| `VIEW_REQUEST / SNAPSHOT_BEGIN / RECORD / SNAPSHOT_END` | Complete authorized view at a specified cut, with count and digest |
| `DELTA / APPLIED` | Contiguous changes after the cut and an acknowledgment of successful view installation |
| `RESYNC_REQUIRED` | Invalidate cursor and staged changes; obtain a fresh snapshot |
| `LEASE_CHALLENGE / LEASE_PROOF` | Correlate fresh evidence to an outstanding nonce and local deadline |
| `ROUTE / ROUTE_ERROR` | Send original bounded metatraffic to an admitted destination incarnation |
| `CLOSE / CLOSED` | Retract participant inventory and invalidate its routes/session |
| `STATUS / ERROR` | Expose lifecycle, authorization, capacity and unsupported-feature failures |

Request IDs are 128-bit and scoped to session. A repeated accepted mutation with the same entity revision and identical bytes is idempotent. Same revision with different bytes is a protocol conflict: reject and require inventory repair. Lower revisions never overwrite higher revisions. A transport ACK only releases transport history; `COMMIT` means validated and installed in the current broker epoch's store. V1 commit is not disk durability or quorum replication.

Assign independent RTPS sequence spaces to each session's control/state writers. Do not use one global reliable writer whose sequence gaps every filtered client must repair. Coalesce state only before assigning a delivery sequence; after assignment, retain the change until acknowledged or invalidate the view explicitly. Native RTPS GAP cannot stand in for an omitted required view delta. Control framing, RTPS sequence ordering, entity revisions and view cursors each solve a different problem and must not be conflated.

### 6.3 UDP obligations

The client binds a specific local channel before sending HELLO. Replies MUST return through the same socket/path, and the broker MUST use the service address contacted by the client as the reply source. Existing address-family support checks are not path validation.

Before address validation, the server stays stateless or strictly bounded and MUST NOT send more bytes than received. Use an expiring integrity-protected return-routability cookie; cookies are not client authentication. Allocate reliable history only after validation/admission. An authenticated packet from a new tuple initiates path validation; it does not immediately redirect queued traffic. Retain the old validated path for a bounded overlap.

Fragment control samples at RTPS level. Start with a configurable conservative maximum UDP payload (proposed 1,200 bytes including protocol/security overhead budgeting); support smaller operator limits and path-MTU adaptation. Avoid reliance on IP fragmentation. Enforce aggregate and per-session reassembly bytes, fragment counts, timeouts, duplicate limits and fair repair scheduling before allocation.

Reliability MUST include paced transmission, RTT-sensitive repair, bounded in-flight bytes, backoff, and an aggregate congestion budget covering all streams to a client. An unlimited HEARTBEAT/NACK retransmission loop is not an acceptable WAN congestion policy. Loss, blocked ICMP and delayed acknowledgments must not trigger unbounded traffic.

### 6.4 TCP obligations

The client initiates the connection; the broker replies over that accepted connection, even when the client's listening locator is unreachable from the broker. Add a connection/channel handle to the transport abstraction rather than pretending a NAT-translated source tuple is a universally dialable listener.

Disable `reuse_connection_by_host` for broker channels. Participants behind one NAT must not share a route simply because their source IP is equal. Demultiplex by authenticated session and ownership, not host alone.

Enforce frame limits before allocation, incomplete-frame deadlines, bounded send queues, connect/write deadlines, and cancellation. A slow receiver MUST NOT block the discovery store or other sessions. Cap state frame sizes so that control work gets scheduling opportunities; TCP byte-stream head-of-line blocking remains a limitation. Separate physical priority connections are an optional later negotiated capability.

On any reconnect, establish or explicitly resume a session before sending mutations. A new TCP connection generation does not establish discovery state consistency by itself.

## 7. Lifecycle and synchronization

Client states are `DISCONNECTED → CONNECTING → ADMITTED → REGISTERING → SYNCING → READY`; failures lead to `DEGRADED` and bounded retry. `STOPPING → CLOSED` is terminal. Report transport-connected, inventory-committed, view-ready and degraded separately. An empty authorized view can be READY.

### 7.1 Registration

1. Authenticate the session, authorize scope and select the discovery profile.
2. Claim participant GUID/incarnation. Reject a concurrent different owner. A valid resumption credential may replace a prior connection with a higher fencing generation; old connections immediately lose mutation rights.
3. Publish participant metadata and a complete endpoint inventory. `ORIGIN_BEGIN/END` identify a consistent cut, item count and digest. Local endpoint mutations after that cut are queued as subsequent ordered operations.
4. Validate and atomically commit the inventory. Do not advertise half of an initial participant inventory as complete. Existing committed inventory remains visible during a valid same-incarnation repair until replacement is complete.
5. Install the requested downstream view and then report READY.

Allow only one inventory transaction per owner generation. Give each transaction a monotonically increasing inventory generation, and include it on every fragment/end marker. A replacement inventory is authoritative for membership: previously committed endpoints absent at its cut are removed. Retain their revision high-water marks, reject fragments from prior transactions, and apply post-cut mutations only after the replacement commits. Inventory completion cannot restore an already closed participant. An interrupted transaction expires without altering the last committed inventory.

For v1, deleting and recreating an endpoint MUST allocate a fresh endpoint GUID. Existing endpoints may change supported mutable attributes using increasing revisions. Local revisions are retained through reconnect. Process restart creates a new participant prefix, so old RTPS writer state cannot be confused with a fresh process.

### 7.2 Snapshot plus deltas

The broker serializes accepted mutations within each scope. A view snapshot is taken at store cut `C`; dependent participant records precede endpoint records. Buffer subsequent applicable changes while streaming the snapshot. `SNAPSHOT_END` includes the cut, record count and SHA-256 digest over the ordered, length-delimited serialized records, independent of packetization.

The client stages the snapshot, validates dependencies and limits, and installs it only when the end marker and digest agree. It reconciles the old and new view in one serialized discovery update, then invokes ordered callbacks. Retained identical GUID/revision records must not cause a lost/found storm. Deltas after `C` use contiguous per-view `delivery_seq`; a gap blocks installation until repaired or a new snapshot is requested.

Client `APPLIED` acknowledges an installed prefix, not a received fragment or incomplete staging buffer. No exactly-once network delivery is promised; logical application is idempotent. There is no global simultaneity guarantee between clients.

Snapshot/delta buffering has byte/time limits. If churn outruns a snapshot, send `RESYNC_REQUIRED`, cancel the attempt and retry with backoff. After a configured retry budget, report capacity failure instead of retrying forever. Readiness MUST NOT be reported for a partial view. Admission may reject a view too large for negotiated client limits.

### 7.3 Deletes and tombstones

An accepted REMOVE advances the entity revision and leaves a tombstone. A participant close atomically closes its ownership and removes dependent state. Delayed upserts, delayed inventory fragments, and expired sessions cannot revive it.

Keep a per-incarnation high-water record even after an endpoint's payload is reclaimed. Delivery tombstones can be collected after every resumable view has acknowledged beyond the removal or has been invalidated. Bound resumption retention; a cursor older than retention MUST receive a full snapshot. Reclaim incarnation fencing records only once all associated sessions, cursors and accepted replay windows have been invalidated. Do not rely on a guessed network packet lifetime to make GUID reuse safe.

Withdrawal from a filtered view is `VIEW_WITHDRAW`, not an origin DDS dispose. It removes a discovery association when appropriate, but must not fabricate a user-topic dispose/unregister sample.

### 7.4 Broker failure

Connection failure marks discovery DEGRADED immediately but does not immediately erase installed peers. Existing direct data paths can operate while peer presence and writer liveliness remain valid. They are not guaranteed to survive indefinitely: when broker-backed presence expires, normal endpoint teardown applies unless a separately enabled direct presence authority exists.

V1 uses one authoritative service per scope and no merging of independent brokers. Multiple addresses may reach that same authority. An operator-switched replacement has a new epoch; all clients re-register and resynchronize. Resume only when epoch, session ownership, view generation and retained cursor all match. On epoch change, stage replacement state and preserve unchanged valid associations where possible; never extend old leases merely because the new broker connected.

Automatic multi-broker availability is a later feature requiring explicit ownership/fencing and partition semantics. An arbitrary ordered list of independent servers is not a correct HA implementation: clients may split into disjoint discovery graphs.

## 8. Presence, liveliness and freshness

Keep these timers distinct:

| Timer | Establishes | Cannot establish |
| --- | --- | --- |
| Transport/session health | Client can communicate with broker | Peer data reachability, writer liveliness |
| Origin registration lease | Broker has recent evidence from the participant's discovery agent | Application writer made progress |
| Observer presence lease | Client has bounded fresh evidence about a remote participant | Unbounded validity of cached state |
| DDS writer/WLP lease | Native liveliness policy is being asserted | Discovery graph completeness |
| Future ICE consent/path timer | Permission and viability of a nominated transport path | DDS ownership or QoS compatibility |

Origin registration renewals must come from the participant discovery agent, not an independent socket reader that can stay responsive while the participant is stalled. Use a server challenge with a nonce and a server-monotonic deadline; a timely valid response establishes an origin deadline no later than challenge-send-time plus the negotiated origin lease. Duplicates do not extend that deadline. Negotiate a renewal period with margin for RTT and scheduling. TCP ACKs, old SPDP bytes and arbitrary endpoint replay do not renew registration.

For cached discovery, the negotiated origin lease MUST NOT exceed a finite participant lease advertised in the preserved SPDP payload. A shortened advertised lease takes effect on the next committed participant update and caps the existing deadline immediately. This keeps the broker's additional freshness mechanism from silently lengthening the participant's declared presence policy. `opaque_peer` also preserves native peer lease processing; broker registration freshness never authorizes bypassing native expiry or security validation.

Observer presence must account for delayed replay without requiring synchronized clocks. V1's reference algorithm is a batched client challenge:

* Client sends nonce `q` at local monotonic time `t0` for its current view generation.
* Broker returns `q`, entity incarnation/freshness generation, and each visible participant's remaining registration lease `r`, evaluated when producing the proof. This may be chunked but every chunk is tied to `q` and the view generation.
* Client sets that participant's broker-backed deadline to `t0 + r`, never `receive_time + r`. If already elapsed, ignore the proof. A duplicate `q` is not a new challenge. An old generation cannot override a newer removal.
* Proposals for compressed/batched equivalents must preserve this conservative bound. Account for configured monotonic clock-rate tolerance; clocks need no common epoch. Suspend/resume invalidates outstanding proofs unless the clock reliably includes suspend time.

Freshness generations are broker-owned monotonic values within an epoch, advanced on accepted renewals, lease reductions and terminal removal. Include the generation on removal/lease-reduction events; invalidate earlier proofs when either event is installed. Accept a proof only for its requested scope/view/epoch and a currently outstanding nonce. Never reduce an already valid deadline merely because an older proof arrives out of order; take the maximum of valid conservative deadlines unless an authoritative removal or lease reduction imposes an earlier bound. Initial inventory commit requires a fresh origin proof and must leave enough lease margin to complete downstream activation.

State snapshots do not grant fresh presence. New records require an unexpired corresponding proof before activation; proofs cannot activate records absent from the installed authorized view. Broker expiry removes the participant at the broker; observer timers ensure bounded expiry when removals cannot be delivered. A slow client may expire a healthy participant conservatively, which is preferable to reviving a dead one indefinitely.

Proposed defaults are a requested 30-second origin lease (negotiated down to the advertised finite participant lease when smaller), 5-second challenge period, full-jitter reconnect backoff from 250 ms to 30 s, and 60-second bounded cursor retention. These are tunable starting points, not performance evidence. Infinite broker registration leases are rejected in v1 even if a different discovery mode accepts infinite participant leases. Reject timer combinations that cannot accommodate configured RTT/deadline margins.

WLP assertions are forwarded only from actual origin WLP processing. The broker never synthesizes AUTOMATIC or MANUAL_BY_PARTICIPANT assertions from its session timer. MANUAL_BY_TOPIC remains governed by the native writer/data path. Forwarding preserves WLP writer sequence identity, suppresses duplicate application, and has a finite queue lifetime; reconnect does not replay a stored assertion as new liveliness.

## 9. Disclosure and matching

V1 supports:

* `all`: all admitted participants, including zero-endpoint participants, and all their endpoints in the authorized scope. This is the correctness/reference mode and supports discovery inspection tools.
* `topic_candidates`: reveal remote opposite-direction endpoints sharing a local topic name, together with the participant metadata and built-in routes needed to evaluate/use them. Do not filter by type name, type identifier, QoS compatibility, partitions, or transport compatibility in v1.

Default to `all` in v1. Applications explicitly choose `topic_candidates` when partial discovery visibility is acceptable; the configuration example below demonstrates that opt-in.

Topic-only candidate selection intentionally includes incompatible QoS/type candidates so that clients retain matching decisions and incompatible-QoS reporting. Type assignability need not imply identical type names. All local endpoints are uploaded even when no current peer is interested; otherwise two mutually unknown endpoints could wait forever for an interest signal.

When interest expands, deliver retained current records immediately; do not wait for origin reannouncement. When it contracts, issue ordered view withdrawals and maintain participant reference counts until all endpoint, diagnostic and in-flight built-in-service dependencies are released. Pending services have bounded pin durations and are cancelled on participant removal or authorization revocation.

Filtering changes DDS built-in topic visibility: `topic_candidates` is a partial discovery view, explicitly advertised in diagnostics and API documentation. Applications requiring complete participant inventories select `all`. Neither mode claims full visibility across other realms, domains or unavailable brokers.

More aggressive filters require a proof that they introduce no false negatives for the supported DDS/XTypes semantics, including partition expressions, mutable QoS, content-filtered topics and group presentation. Unknown semantics fall back to a broader authorized view. A content-filter expression on user samples is not by itself a safe endpoint discovery filter.

## 10. Built-in services and security evolution

### 10.1 General metatraffic routing

`ROUTE` includes scope, admitted source incarnation, destination participant incarnation, service class, route generation, bounded lifetime and complete original RTPS message bytes. Reject absent destinations and cross-scope routes. The trusted local dispatcher chooses the service class; the broker checks visible native identifiers where possible. Mixed user/control messages must be separated before encapsulation. Unrecognized service classes require explicit capability negotiation and policy permission.

The receiver gets both original RTPS bytes and route context. Original source identity is never inferred from the broker's network address. Keep RTPS header, INFO_SRC/INFO_DST context, sequence numbers, timestamps, fragments and crypto bytes intact. Replies resolve the remote participant to the reverse metatraffic route. Do not inject broker addresses into original advertised locators.

Native DATA, HEARTBEAT, GAP, ACKNACK, DATA_FRAG, HEARTBEAT_FRAG and NACK_FRAG must all follow the same appropriate participant route. Outer receipt never manufactures native ACKNACKs. Normal originating state machines retain retransmission responsibility. Bounded router drops are observable; reliable native services repair, best-effort services retain their own retry/loss behavior.

Route registration is independent of user endpoint matching. WLP routes follow participant dependencies; TypeLookup routes exist while type matching is pending; authentication routes must exist before protected discovery can match endpoints. This avoids a discovery/authentication circular dependency.

### 10.2 XTypes

XTypes TypeLookup is a request/reply built-in service with four endpoints and reliable, volatile service traffic; carrying `PID_TYPE_INFORMATION` alone does not implement it. [XTypes 1.3 §7.6.3.3](https://www.omg.org/spec/DDS-XTypes/1.3/PDF).

Preserve TypeInformation, TypeIdentifiers and endpoint availability metadata in cached discovery now. Once TypeLookup is implemented, actual participant service endpoints communicate directly or through the metatraffic route. Preserve request identities, related identities, target service identity, minimal/complete distinctions and dependency traversal. The broker does not answer as the origin.

An optional future broker type service must be an explicit service under its own identity. Validate TypeObject/TypeIdentifier consistency and dependencies before caching. Bound object size, dependency depth and cycles; isolate authorization and disclosure by scope. Public hash identity is not permission to reveal a protected type. This service is an optimization, never required to bootstrap the broker protocol.

### 10.3 DDS Security

DDS Security defines stateless authentication endpoints, volatile secure token exchange, and protected discovery endpoints. Its `relay_only` facility has specific cryptographic/access-control semantics; it is not blanket authorization to republish protected discovery. [DDS Security 1.2 §§7.5, 9.4–9.5](https://www.omg.org/spec/DDS-SECURITY/1.2/PDF).

For v1 `cached`, transport/session authentication protects registration and access to the broker, but the broker is trusted to report discovery state. This is not end-to-end DDS discovery authentication. Expose this trust model explicitly.

Future `opaque_peer` requirements:

1. Introduce authorized candidate participants with bootstrap metadata sufficient to run native DDS authentication. Such introductions are untrusted hints until peer validation succeeds.
2. Run authentication, permissions checks, secure participant/endpoint discovery and key exchange between actual participants. Install protected state only after native validation; the plaintext cached-state adapter is bypassed for that peer relationship.
3. Forward entire protected messages without locator substitution, re-signing, impersonation or replay into a new recipient's crypto session. Late join invokes the origin's native discovery history and per-peer security processing.
4. With hidden endpoint metadata, use the whole authorized participant scope as the default candidate set. Do not promise topic-based filtering or its scaling benefit. Optional disclosure hints need a separately agreed confidentiality policy.
5. Keep origin/receiver security identities and receiver-specific protection intact across broker failover. A broker restart may interrupt routing; it cannot generate fresh peer tokens or secure history.
6. Negotiation binds the chosen profile to authenticated configuration. If no supported secure profile exists, fail explicitly. Never strip protection to make discovery succeed.

An opaque router may be unable to verify that encrypted bytes contain only metatraffic. Enforce authenticated class declarations, recipient-side dispatch checks and separate quotas; document that broker-side payload classification is limited under whole-message encryption. Do not advertise cryptographically enforced topic classification without evidence.

This profile preserves a path for future DDS Security reuse but does not establish conformance in advance. Protected discovery, origin authentication, access revocation, native lease behavior and each crypto protection scope require integration tests with the eventual implementation. Optimized secure caching is a separate later design problem, not a v1 promise.

### 10.4 Admission security before DDS Security exists

Support `trusted_network` and `authenticated` deployment policies. The former requires explicit configuration and is suitable for a separately protected network; it cannot be described as safe public-internet discovery.

An authenticated public deployment requires authenticated encryption for broker control sessions over both transports, server identity verification, client credentials and per-scope authorization. Use a maintained TLS implementation for TCP and a maintained DTLS implementation for UDP, integrated as transport/channel protection. Do not design custom cryptography. If these wrappers are deferred, public deployment support is deferred with them; UDP support must not quietly have a weaker trust model than TCP.

Bind the envelope's scope, session, epoch, ownership and negotiation transcript to the protected session. Enforce replay windows, credential rotation, revocation, per-principal quotas and authenticated administrative operations. A return-path cookie alone does not satisfy these requirements. DDS Security remains responsible for eventual end-to-end participant/endpoint permissions.

## 11. Connectivity and NAT traversal

Broker connectivity establishes a control path only. A TCP control connection conveys no UDP data mapping; a UDP control mapping conveys no mapping for another socket. Observed source addresses are path-scoped observations, not replacements for advertised locators.

| Deployment | V1 expected outcome |
| --- | --- |
| Same LAN without multicast | Broker discovery; direct unicast user data |
| Routed subnets / VPN with permitted peer ports | Broker discovery; direct data using routable advertised locators |
| Public or explicitly port-mapped peer listeners | Works when both data and native reply/repair paths are configured correctly |
| Private peers can reach broker but not each other | Discovery succeeds; report direct connectivity unavailable |
| TCP control allowed, UDP data blocked | TCP broker connection does not solve UDP data; use mutually supported reachable data transport |
| Both peers behind restrictive NAT/firewalls | No v1 connectivity guarantee; future ICE may find a path, future TURN may supply fallback |
| Peers support disjoint data transports | No matchable transport path; broker does not translate UDP to TCP user data |

Add a local ConnectivityAgent interface with `gather`, `exchange`, `check`, `nominate`, `invalidate` and `close` operations. Reserve a capability-negotiated connectivity record namespace outside original SPDP/SEDP bytes. A candidate set includes owner incarnation, transport instance/component ID, generation, address family, candidate type, foundation/priority, related address, expiry, and (for TCP) connection role. Credentials are exchanged only with authorized peer candidates and never logged.

A component identifies the actual bound socket or connection role, such as a metatraffic socket or user-data socket. Endpoints sharing a socket may share candidate work; endpoints with different sockets must not inherit its mapping. IPv6 interface scope and overlapping private address spaces require local network context; a raw address string is insufficient.

Use standard [ICE RFC 8445](https://www.rfc-editor.org/info/rfc8445/) with its applicable updates, [STUN RFC 8489](https://www.rfc-editor.org/info/rfc8489/), and [TURN RFC 8656](https://www.rfc-editor.org/rfc/rfc8656.html) when implementing traversal. ICE-TCP is a separate capability described by [RFC 6544](https://www.rfc-editor.org/rfc/rfc6544); it is not implied by a TCP connection to the discovery broker.

Future connectivity policy defaults to `direct_preferred`: authenticated checks and nomination choose working direct paths first. `direct_only` forbids relayed user data; `relay_allowed` authorizes bounded fallback. Do not exhaust an unbounded list of direct candidates before offering fallback: candidate priorities and a configured direct-attempt deadline govern escalation.

The broker is the candidate signaling rendezvous; STUN/TURN may be separate services or optional colocated components. TURN allocations, credentials, permissions, channel bindings, quotas, refresh and expiry are a separate data-plane service. UDP versus TCP/TLS access to TURN and relayed peer transport are separate negotiated facts. No automatic allocation charged to a user without the configured policy allowing it.

Route nomination updates the local route table, leaving original GUIDs and discovery data intact. Path changes cover both data and RTPS repair/control in both directions. In-flight duplicates remain subject to native RTPS sequence handling. Bound concurrent checks and apply destination policy so a malicious participant cannot use candidate exchange to trigger unrestricted scans of another client's network.

## 12. Performance, limits and operations

Let `N` be participants, `E` total endpoints, `R` delivered endpoint-to-observer relationships and `B` retained raw payload bytes. A single cached broker has approximately `O(B + E + N + R)` state before bounded queues; client-to-broker reliability associations are `O(N)`. Full disclosure still has `O(N·E)` endpoint delivery and potentially `O(N²)` participant presence distribution. Sparse topic interest reduces `R`; all-to-all applications cannot escape their information volume. Opaque peer security can reintroduce `O(N²)` native associations.

Therefore centralization is not an unconditional performance improvement. It trades multicast/peer work for server indexing, fanout, queues and a failure dependency. Include single-host and small-LAN workloads in benchmarks where the broker may lose.

Store raw payloads once with immutable reference-counted ownership. Index by scope and topic/direction; maintain per-view membership and dependency counts. Snapshot streaming avoids cloning the entire database for each joining client. Batch small records within MTU/frame limits. Use per-client round-robin or deficit scheduling with reserved control capacity and finite repair budgets. No global store lock may be held across network writes or application callbacks.

V1 MUST configure and report bounds for: sessions, participants, endpoints per participant/scope, raw record bytes, view bytes, outstanding mutations, repair history, tombstones, snapshot staging, incomplete inventories, reassembly, route queues, accepted unauthenticated work, candidate records, and per-principal egress. Admission accounts for the requested view, not just its ingress record size.

Do not solve a slow observer by blocking all origins. Disconnect or invalidate that observer's cursor with an explicit reason when its retention budget is exhausted. An origin whose mutation cannot be committed retains/retries it or reports discovery failure to its application. Endpoint creation semantics must expose asynchronous announcement failure; local creation success alone cannot promise remote discovery.

The existing TCP implementation uses a receive thread per connection. Reusing it is suitable for a bounded prototype; large-scale support requires an event-driven backend or measured evidence that the thread/memory budget meets the claimed envelope. Preserve the transport interface while changing the backend. Do not market 100,000-client scalability based solely on asymptotic analysis.

Required metrics include admission/authentication failures, active and degraded sessions, participant/endpoint counts, committed-to-applied latency, ready latency, expiry/withdrawal reasons, queue bytes, repair traffic, snapshot retries, cursor invalidations, duplicates/conflicts, route errors, direct-path success, and future relay utilization. Avoid GUID/topic labels in unbounded metric dimensions; use sampled traces with redacted credentials.

Readiness means the broker can admit and serve its configured scopes, not merely that its process listens. Provide graceful drain, administrative scope/credential controls, structured logs, a read-only graph inspection API with authorization, and protocol-version/build reporting. Persistence, federation and consensus HA are later phases; durable files loaded after restart are unconfirmed hints until origin ownership/freshness is re-established.

## 13. Configuration and API contract

Illustrative TOML below is proposed syntax, not accepted by the current parser:

```toml
[discovery]
kind = "broker"

[discovery.broker]
realm = "production-eu"
addresses = ["tcp://discovery.example.net:7443"]
profile = "cached"
view = "topic_candidates"
session_security = "authenticated"
credential_ref = "workload-identity"
origin_lease_ms = 30000
renewal_period_ms = 5000
startup = "require_ready"
startup_timeout_ms = 15000

[discovery.broker.connectivity]
policy = "direct_only"
# Future: stun_servers, turn_servers, candidate policy and check budgets.

[transport.tcp]
enabled = false # Existing user-data selection: UDP user data in this example.
```

For UDP control, configure `udp://...` service addresses and the authenticated datagram channel. A broker may listen on both UDP and TCP for the same authoritative scope; UDP-connected and TCP-connected clients discover each other. Mixed addresses in one service configuration select a reachable transport to that same authority, not independent graph authorities.

`startup = require_ready` fails participant startup on timeout; `allow_degraded` permits local operation and exposes asynchronous discovery status. Neither silently enables multicast fallback. Expose `wait_discovery_ready`, broker status, view completeness, registration failure and peer connectivity diagnostics through Zig and the C ABI, then existing language bindings. Preserve existing `spdp` defaults and transport behavior for applications that do not opt in.

Broker-only mode emits no SPDP multicast and does not create peer SEDP associations for cached peers. A future explicit hybrid mode may run native discovery concurrently, but needs shared per-origin provenance, source-specific leases, idempotent lifecycle callbacks and loop prevention. Do not implement hybrid by simply running two plugins against the same callbacks; one source disappearing must not delete an entity still valid through another source. Automatic LAN import/export and cross-vendor broker gateways are outside v1.

## 14. Integration with the current repositories

Inspection baseline: zzdds `f083f95`, zidl `35d7735`. This was an architecture/source inspection, not a claim that the existing test suite was executed.

| Existing area | Evidence / required work |
| --- | --- |
| `src/discovery/interface.zig` | Already anticipates broker plugins; add raw record ownership/provenance and update/batch semantics without making reduced `QosSnapshot` the authoritative wire model. Maintain callback lifetime and stop guarantees. |
| `src/discovery/combined.zig`, `builtin_endpoint.zig`, `wlp.zig` | Reuse built-in state machine and dispatch concepts. Separate native peer matching from broker-record installation and route WLP explicitly. |
| `src/discovery/spdp.zig`, `sedp.zig` | Extract shared codecs; current parsed structures discard unknown data and are insufficient for lossless broker storage. Add strict structural validation before public network use. |
| `src/transport/interface.zig` | `send(locator)` plus `on_receive(data, src)` does not express a validated reply channel, local socket component or peer route. Add optional channel/session and ingress-context capabilities. `canReach` is capability filtering, not connectivity proof. |
| `src/transport/udp.zig` | Send path selects cached source sockets. Establish explicit same-socket send/receive semantics for broker sessions and future candidate components; test instead of assuming current behavior suffices. |
| `src/transport/tcp.zig` | Existing bounded length framing and connection generations are reusable. Add accepted-channel replies, bounded asynchronous sends, session-aware routing and eventual scalable I/O. Disable host-only reuse. |
| `src/dcps/participant.zig` | Currently assumes UDP discovery and constructs TCP as a separate optional data transport. Refactor stack ownership so broker control does not accidentally become the data transport or data locator source. |
| `src/c_abi/extensions.zig` | `ParticipantStack` currently constructs concrete UDP + `SpdpSedpDiscovery`. Introduce tagged/owned stack construction selected by configuration. |
| `src/config/schema.zig`, generated config and TOML | `DiscoveryKind.broker` exists as a future enum value; add real configuration and dispatch, with unsupported settings rejected explicitly. Update the generating schema/source, not only generated output. |
| `idl/rtps_discovery.idl`, zidl codecs | Reuse encoding capabilities, but preserve raw discovery bytes independently of generated known fields. Add broker control IDL and deterministic fixtures; no new IDL language feature should be needed unless implementation proves otherwise. |
| `src/security/*`, `docs/design/security-pipeline.md` | Real DDS Security enforcement is not implemented. Treat the proposed pipeline as a future integration dependency, not evidence of working protected discovery. |

Recommended new modules: `discovery/broker_client.zig`, shared `discovery/codec/`, `discovery/state_store.zig`, `discovery/metatraffic_router.zig`, `connectivity/interface.zig`, and a broker executable backed by a reusable service library. Exact file organization is an implementation choice. Keep protocol/state logic testable without real sockets.

## 15. Verification and release gates

Tests must establish observable behavior, particularly where broker semantics differ from native discovery.

| Area | Required evidence |
| --- | --- |
| Codec fidelity | Little/big-endian input, repeated and unknown optional PIDs, required unknown PIDs, malformed lengths, key-only disposal, nondefault QoS and TypeInformation. Byte-exact raw preservation through broker storage and replay. |
| State ordering | Endpoint before participant, update/delete reordering, duplicate revision conflicts, inventory replacement during mutation, GUID collision, and old-generation traffic. No stale resurrection. |
| Synchronization | Join during continuous churn; drop snapshot end, disconnect mid-snapshot, lose a delta, exhaust cursor retention. READY only for a verified complete view. |
| Failure detection | Process crash, discovery-agent stall, broker crash, one-way loss, delayed lease proofs, duplicate challenges, suspend/resume and clock changes. Bounded expiry; no broker-manufactured writer liveliness. |
| Transport matrix | UDP↔UDP, TCP↔TCP and UDP↔TCP control clients with independent UDP/TCP data choices; IPv4/IPv6; same NAT source IP; return over accepted TCP connection; UDP rebinding. |
| Reliability/resource limits | Loss, duplication, reorder, MTU reduction, fragment floods, slow TCP reader, oversized frame and reconnect storm. Bounded memory and fair progress for healthy sessions. |
| Filtering | Full-view versus candidate-view differential matching; late interest, zero endpoints, partition/QoS mismatch reporting, distinct assignable type names, mutable updates and pending service pins. |
| Routing | Native ACKNACK/GAP/fragment repair follows reverse routes; no user-topic forwarding in v1; no WLP replay on reconnect. |
| Security | Cross-domain/realm denial, spoofed owner, expired/revoked credentials, downgrade attempts, unauthenticated amplification, replay and candidate destination abuse. |
| Future XTypes/Security | TypeLookup before endpoint match; protected authentication before secure discovery; each crypto protection scope; secure late join and broker restart. Required before advertising those capabilities. |
| Existing interoperability | Native SPDP/SEDP and supported data interoperability remain unchanged when broker mode is disabled. Cross-vendor broker compatibility remains explicitly unsupported. |

Use deterministic fake clocks, memory/lossy transports and model-based event sequences for ownership, snapshots and lease invariants. Fuzz bootstrap, envelope, raw ParameterList, inventory and fragment parsers. Real socket/network-namespace tests are required for NAT/source-port and TCP return-path claims; in-memory tests cannot establish them.

Benchmark native SPDP/SEDP and both broker transports at proposed tiers of 2, 100, 1,000 and 10,000 participants, subject to available hardware. Vary endpoints per participant, interest density, churn, WAN RTT/loss and payload size. Record p50/p95/p99 time from origin commit to installed peer state, startup-ready time, bytes, CPU, peak memory, thread count and recovery convergence. Include full disclosure, candidate filtering and slow observers. Publish hardware/configuration and supported limits; do not impose an unsupported latency number as a design claim.

### Delivery sequence

1. **Protocol foundations:** finalize IDL/identifiers, raw codec fidelity, ownership/inventory/view model, fake-clock tests and channel contract. Prototype full-view cached mode in memory.
2. **Functional broker:** single broker, UDP/TCP channels, full lifecycle, WLP routes, configuration/bindings and routed-network integration tests. Candidate filtering follows full-view differential tests.
3. **Production hardening:** authenticated TCP/UDP deployment, quotas, pacing, backpressure, restart recovery, observability and published scale envelope. These are public-deployment release gates, not optional cleanup.
4. **Direct connectivity assistance:** candidate signaling, socket-specific STUN/ICE, nomination and path migration; implement ICE-TCP separately if needed.
5. **Fallback and availability:** explicit TURN service integration; consensus/fenced HA specification and implementation. Either may be prioritized independently.
6. **OMG extensions:** integrate native TypeLookup and `opaque_peer` DDS Security as those features arrive. They may proceed before traversal/HA; the route architecture exists from phase 1.

## 16. Decisions still requiring implementation evidence

This proposal makes the architecture, trust boundary, default scope, consistency and failure semantics concrete. Before wire freeze, settle these bounded engineering items:

* Exact vendor endpoint/parameter assignments and versioned control IDL, with cross-version fixtures. No numeric assignment in this proposal is an OMG allocation.
* TLS/DTLS provider and Zig/platform integration; maintain authenticated UDP/TCP parity.
* Channel API shape and the smallest reusable change to current transport ownership/source-socket behavior.
* Default memory/record/view limits and timers from measured workloads, plus the supported scale of the existing TCP backend.
* Application-facing asynchronous announcement failure/status API consistent across bindings.

The most consequential future policy decision is whether a deployment trusts the broker with discovery plaintext. `cached` chooses that trust for scaling; `opaque_peer` preserves peer-owned security processing at a potentially substantial discovery cost. Both belong in the architecture, and neither should be presented as providing the other's properties automatically.
