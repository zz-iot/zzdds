# Concurrency and discovery broker specification

This is the single entry point and decision index for the concurrency/broker design.
The contracts below describe an implementation baseline. They do not claim a migrated
production runtime, a working broker, frozen ABI/wire compatibility, or measured latency
and MCU footprint. This index defines scope, requirement conventions and the remaining design/validation gates.

## Contracts and responsibility

| Subject | Authoritative home |
| --- | --- |
| Execution ownership, admission, reservations, progress and fast paths | [Concurrency architecture](concurrency/architecture.md) |
| Listener identity, ordering, preparation, delegation and quiescence | [Listeners](concurrency/listeners.md) |
| Read/take, effects/results, ACK/history/WaitSet waits and variants | [Operations](concurrency/operations.md) |
| Runtime ownership, bootstrap, resources, driving, retirement and transport | [Runtime](concurrency/runtime.md) |
| Non-OMG concurrency configuration and API declarations | [Extension API](concurrency/extension-api.md) |
| Broker purpose, deployment scope and implementation sequence | [Broker overview](broker/overview.md) |
| Bootstrap, admission, transactions, freshness, retirement and operation legality | [Broker protocol](broker/protocol.md) |
| Encoding, assignments, metadata, versioning and byte ownership | [Broker wire](broker/wire.md) and [experimental schema](schema/broker-control-draft.idl) |
| Broker Config, status, readiness, diagnostics and enablement | [Broker API](broker/api.md) |
| Insecure v1, future secure cached mode, disclosure and continuity | [Security and filtering](broker/security-and-filtering.md) |
| Native/broker coexistence, domain identity and origin revisions | [Coexistence](broker/coexistence.md) |

The subject contracts own behavior; the API documents own declaration/default spelling;
the schema owns provisional numeric assignments. Examples and implementation approaches
must preserve those rules but do not select one internal container or scheduler algorithm.
The contracts are self-contained; historical investigations and review correspondence
are not required inputs. If implementation exposes a contradiction, resolve the named
rule explicitly rather than silently choosing different behavior.

## Requirement convention

Declarative obligations and imperatives in these contracts are requirements: "must",
"never", "do not", "use" and "require" constrain conforming implementations. "May" permits
an option. Sections or paragraphs labelled **Conforming approach** describe one permitted
implementation; another may be used if it preserves the surrounding requirements.
**Rationale** and examples explain those requirements without adding API guarantees.
"Prefer" and "should" express recommendations, not additional conformance conditions.

Future/deferred features impose no v1 implementation requirement unless explicitly stated
as a reserved field or compatibility constraint. Code/IDL snippets describe the target
surface; provisional numeric assignments and ABI layouts need the publication checks below.
An implementation gate calls for evidence, not another product-policy decision. An open
design item identifies a genuinely incomplete contract and must be resolved before its
particular interface/behavior is implemented or advertised as final.

## Key behavioral decisions

| Decision | Contract |
| --- | --- |
| D1 | After ordinary validation, VOLATILE, BEST_EFFORT and empty-known-source historical waits return OK with no receipt guarantee. Warn once per entity for best-effort history/ACK waits. Record the behavior change when implemented. |
| D2 | Optional single-use registration continuity capability is v1.1. Bind it to scope/GUID/incarnation/current registration; rotate on replacement. No SPDP token, permanent ownership registry or v1 live takeover. Lost replacement outcomes need their v1.1 protocol. |
| D3 | UDP bootstrap stays unfragmented. Preflight complete messages; diagnose local oversize and offer explicit interface restriction/TCP configuration. No stripping, hidden fragmentation or transport fallback. |
| D4 | Operator disclosure ceiling comes first; clients may require conservative topic/partition candidate filtering and refuse unsupported service. No silent ALL fallback or type/QoS suppression of diagnostics. |
| D5 | V1 is insecure cached discovery. Future secure broker operation derives from participant DDS Security, including explicit vendor-endpoint protection and UDP/TCP evidence. No separate required TLS/DTLS-first credential API or plaintext fallback. |
| D6 | Cached mode first, including eventual trusted secure caching; peer identity/permissions/user-data protection remain independent. Opaque mode and relays are later work. |
| D7 | Foreign-path failed take restores eligible retained claims, allowing temporary invisibility/NO_DATA. It never resurrects expired/evicted/deleted data or an old access bracket. |
| D8 | Foreign selection-time READ/NOT_NEW effects survive failure; cleanup does not overwrite lifecycle rebirth. Binding users receive the NOT_READ/NEW limitation and ANY-state recovery guidance. |

Other settled directions: take-turns participant/endpoint contexts; shared manual/hosted
runtime; callback exclusion without mandatory worker hops; ordinary hosted callers do not
help; GROUP-only Publisher tickets; retained TOPIC seal work with per-set completion
capacity; optional profiles remove exclusive machinery; standard DDS APIs keep useful
defaults and automatic last-owner runtime cleanup. Non-OMG public controls belong in
zzdds.idl. Broker WLP and user traffic remain direct in v1.

Draft 3 uses ordered STATE transactions/aggregate freshness, final established bodies,
mutable bootstrap and retained-baseline identity without transaction digests. Original
SPDP/SEDP bytes and bootstrap correlation hashes remain. Delayed reductions cannot
retroactively revoke observer grants before delivery. Fairness, storage and output remain
bounded independently of these wire simplifications.

## Open design items

| Item | Required resolution | Boundary already fixed |
| --- | --- | --- |
| Local entity publication versus discovery announcement/disposal | Specify ordering when creation, asynchronous announcement and deletion race, including retained disposal work and failure reporting; place the result in architecture/operations | No usable entity before local publication, no stale generation mutation, no callback before corresponding state commit; broker announcement failure never retroactively undoes local creation |
| Listener bridge ABI and resource-failure results | Select/version the generated identity/ownership/invocation-outcome descriptor and document permitted set_listener resource-exhaustion results and per-binding mappings | Preserve original dispatch pointer, canonicalize identity at registration, retain old registration on preparation failure, no exception crosses core frames, no new standard setter timeout |
| External-loop platform ABI | Define clock-domain conversion, wake representation and platform-specific adapter descriptor/version validation | One outer driver, atomic arm/recheck, attach before participants/I/O, no live executor replacement or premature detach in v1 |

Concrete queue/pool/container selection, internal cancellation batching and scheduling of
built-in endpoints are implementation choices constrained by the contracts, not open public
semantics. GROUP wire/history/lifespan validation is a required optional-profile gate;
the endpoint ownership partition and shared access-period behavior are settled. DDS Security,
relays, opaque mode and v1.1 continuity recovery belong to their expressly deferred scopes.

## Implementation and publication gates

| Gate | Evidence required before the associated claim |
| --- | --- |
| Concurrency | Real queue/publication/memory-order correctness, cancellation, callback exclusion, claim restoration, conditions, manual/hosted retirement and bounded fairness |
| Optional presentation | Actual TOPIC markers and repair; GROUP coherent visibility, history/lifespan interactions and incomplete-set handling. Concurrency invariants do not supply the entire optional wire profile. |
| Bindings and ABI | Generated zzdds.idl extensions, generic zidl reference/Config ownership (specified in the zidl repository's `docs/design/managed-references.md`; required only for the advanced extension objects, not the first shipped subset), nil/default/error behavior, mixed file configuration and language exception/cleanup tests |
| Broker introduction | Recipient-specific inline SPDP context with unchanged canonical payload; both transport ingress paths, domain ID/tag, bounded whole-message sizing and same-source replies |
| Parsing/storage | Required/unique mutable members, exact final extent, malformed/oversize nested bodies, retained bytes, allocation failure, bounded reassembly and native peak-memory accounting |
| Broker state machine | Loss/reorder/duplicate/expiry tests across PATH/REGISTER/inventory/view/freshness/close, retained resume identity, local activity during outage and direct-source coexistence; every [admission test scenario](broker/protocol.md#admission-test-scenarios) |
| Deployment | Rate/CPU/storage abuse bounds, entropy/path-provider behavior, filter correctness, platform coverage and measured latency/footprint/scale |
| Publication | Explicit assignment/version review after wire-affecting findings; independent peer compatibility before frozen wire/ABI promises |

The first implementation slice is a bounded reliable reader/writer pair with manual and
hosted progress, listeners, waits and automatic retirement. Broker integration can proceed
against the same ownership interfaces without waiting for every optional profile. Start
with one scope, fresh inventory, view/readiness, reconnect and local matching during outage;
then implement required candidate filtering and both advertised control transports.
No automatic authorization to refactor production or publish releases follows from this index.

## Acceptance criteria

The implementation must cover the matrix below before claiming its associated capability.
Run the same core traces under manual and hosted drivers; exact bounded model results alone
do not establish native memory ordering, generated-binding correctness or interoperability.

| Area | Required evidence |
| --- | --- |
| Codec fidelity | Little/big-endian native payloads, repeated/unknown optional and required PIDs, malformed lengths, key-only disposal, nondefault QoS and TypeInformation; byte-exact retained storage/replay |
| State ordering | Endpoint-before-participant input, update/delete reorder, revision conflicts, replacement inventory during mutation, GUID collision and stale-generation work; no resurrection |
| Synchronization | Continuous churn, missing END/delta, mid-snapshot disconnect, exhausted retention, bounded retries and complete-view readiness; unchanged records produce no lost/found storm |
| Failure detection | Origin/discovery-agent/broker stall or crash, one-way loss, delayed/replayed proofs, suspend/resume and clock changes; bounded expiry with no fabricated writer liveliness |
| Transport | UDP↔UDP, TCP↔TCP and UDP↔TCP control clients with independent UDP/TCP data choices; IPv4/IPv6, same-NAT source IP, accepted TCP return path and UDP rebinding |
| Resource/congestion | Loss, duplicate/reorder, reduced MTU, fragments, slow TCP reader, oversized frames and reconnect storms; bounded memory/repair traffic and healthy-client fairness |
| Filtering | Full versus candidate differential matching; late/zero interest, partitions, incompatible-QoS diagnostics, distinct assignable type names, mutable updates and future service pins when supported |
| Direct metatraffic | WLP peers installed through broker with peer SPDP/SEDP disabled; reachable native reply/repair paths; blocked WLP is not rescued by broker freshness |
| Security boundary | Domain ID/tag isolation, spoofed ownership attempts, amplification/replay and destination abuse in v1; expired/revoked credentials, downgrade and native protection scopes before secure-profile claims |
| Runtime and bindings | Receive-to-callback, reliable backpressure and shutdown paths; final deletion inside callback, cancellation, stale closes/wakes, foreign preparation/entry failure, claim restoration and external-loop retirement |
| Constrained builds | No thread/sleep/socket dependency in freestanding core; optional-profile state removal measured in matched builds; actual adapter, work/stack and memory bounds before MCU claims |
| Existing interoperability | Native SPDP/SEDP and supported data interoperability unchanged with broker disabled; cross-vendor broker compatibility is not promised |
| Future services | TypeLookup before matching, secure late join/restart and authentication before secure discovery, tested before advertising the respective capability |

Use fake clocks, bounded/lossy transports and model event schedules for deterministic
invariants. Fuzz bootstrap, envelope, ParameterList, inventory and fragment parsing.
Real sockets and network namespaces are required for NAT/source-port and TCP return-path
claims. Report privileged test requirements and environment skips; a skipped path is not
passing coverage. A general network simulator is not required.

Benchmark native discovery against both broker control transports, targeting 2, 100,
1,000 and 10,000 participants as hardware permits. Report achieved coverage and capacity;
these tiers are evaluation targets, not minimum advertised capacity. Vary endpoints,
interest density, churn, RTT/loss, payload size, full/candidate views and slow clients.
Include single-host/small-LAN cases. Report p50/p95/p99 origin-commit-to-peer-install,
startup readiness and recovery convergence, alongside bytes, CPU, peak memory, thread
count and configuration/hardware. For concurrency, report uncontended and overloaded
latency, handoffs and queue depth. Do not replace measurements with asymptotic claims.

## Evidence

[The evidence inventory](probes/README.md) records executed checks, counts, fixture sizes
and limitations. The maintained wire checks run separately from production tests. No
historical review or archive is required to interpret the contracts. Review-era models and
prototypes are listed there for reference; their bounded results must not be aggregated
into a full-system correctness claim.
