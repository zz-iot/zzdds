# Concurrency extension surface

Status: accepted semantic inventory, 2026-09-17. The configured creation, group and
manual/bootstrap policies below are selected. Concrete spelling/layout is not frozen
ABI or compiled IDL. Production idl/dcps.idl is unchanged.

## Standard application baseline

Standard participant construction follows the factory's configured selection and
lazily creates the implicit shared runtime when needed. Participants hold operational
ownership; ordinary teardown initiates retirement automatically. No manual runtime
shutdown call is required. Hosted builds supply background progress; manual builds
still require an application driver and do not pretend blocking alone runs listeners.

Listeners serialize per entity and shared identifiable listener object, across runtimes
within one loaded core. Distinct sibling reader listeners remain independent. Eligible
callbacks can run inline. No stable thread affinity is promised. Standard WaitSets
resolve the default runtime at each admitted wait without creating it for a guard-only
wait. Default owned resources need no application reclamation fence.

## Required extension inventory

All new entity interfaces, shared public types and application configuration below
belong in zzdds.idl. Standalone construction uses a generated/versioned bootstrap;
WaitSets and runtimes need not be children of a DomainParticipant.

| Surface | Operations/configuration to express | Ownership and default |
| --- | --- | --- |
| RuntimeRef | Observe identity/state; explicitly try to acquire an owner | Observer/control-block retention only; never revives a retiring lifetime |
| RuntimeOwner | Observe its RuntimeRef; deterministically release its lease | Operational lease; aliases share release state; explicit acquisition creates a new lease |
| Runtime construction | Select a supported hosted/manual backend and resource policy | Publish only after required progress/retirement capacity exists; unsupported modes fail visibly |
| Core default selection | Follow implicit default, install explicit identity, or disable default selection | Registry is not an operational owner; changing selection never migrates existing entities |
| Factory extension | Configure default-following versus explicitly owned runtime selection | Explicit selection acquires ownership transactionally; default-following factory holds policy only |
| Participant construction extension | Optional explicit runtime override | Participant acquires a lease before publication; runtime remains fixed for its lifetime |
| Participant runtime getter | Return RuntimeRef | Does not keep workers operational merely because the runtime was inspected |
| Participant concurrency configuration | Positive finite delegation nesting limit and prepared-access stale-validation limit | Creation-time; build-changeable defaults eight and four respectively; cross-participant nesting uses the accepted minimum rule |
| Writer preparation configuration | Maximum outstanding prepared history reservations per instance | Per-writer setting, default one; not a thread count or aggregate memory budget |
| WaitSet extension | Idempotent non-draining close; construction-time helping policy and finite runtime references | Default shared-runtime policy; explicit set retains observers, not owners; no-helping is explicit |
| Tracked resource scope | Seal new independent admission; obtain independently retained completion observation | Optional for borrowed resources; seal neither deletes entities nor stops required cleanup |
| ResourceCompletion | Nonblocking readiness and timed completion wait | No operational ownership; must not pin the arena it observes; timeout is not permission to destroy resources |
| Binding access failure metadata | DDS result, bounded reason category, effect phase | Supports accepted Java convenience failure reporting; no new DDS ReturnCode values |

Default replacement must expose all three selection states explicitly; nil cannot
ambiguously mean both follow-default and disable. Runtime identity getters must never
perform lazy runtime creation. The exact default-selection controller name and bootstrap
error envelope remain integration decisions.

The participant configuration can reference the existing DomainParticipantConfig /
ParticipantConfig family. Runtime references are construction inputs, not serializable
network addresses or numeric pointer values in a config file. Keep runtime/resource
object inputs distinct from file-loadable scalar backend defaults.

## Selected creation and driver surfaces

**Configured creation pattern (selected 2026-09-16):** follow the existing
factory create_participant_ex(..., DomainParticipantConfig) pattern. Add
create_publisher_ex(..., PublisherConfig) on zzdds::DomainParticipant and
create_datawriter_ex(..., DataWriterConfig) on a new zzdds::Publisher extension.
Keep standard QoS/listener/mask arguments and append the entity's Config object;
return the standard DDS entity view, preserving identity across extension views.
These constructors/config types do not yet exist in the checked-in IDL.

DataWriterConfig carries the per-instance preparation limit, default one, fixed at
creation. Standard create_datawriter uses the documented default configuration.
Unsupported larger limits fail construction rather than silently clamp. The limit
is not DDS QoS and does not require live ledger resizing. PublisherConfig contains
publisher-specific extensions as they are selected; do not put writer-local limits
there or infer child defaults/inheritance merely from the existence of this object.
Concrete field names and any default-config getter/setter family remain part of the
IDL proposal. The configured creation pattern is selected; additional default-policy
APIs are not implicitly accepted by this choice.

**Listener groups (accepted 2026-09-16):** each entity creation Config may supply
one optional retained listener-group reference. Membership is fixed for the entity's
lifetime, including creation with no listener; set_listener replacement preserves it.
No group selects the standard per-entity/shared-listener defaults. Distinct sibling
reader listeners remain independent, and parent membership is not implicitly inherited.
The group may span participants/runtimes within one loaded core identity domain.
It provides exclusion, not a worker, thread affinity or operational runtime ownership.

Group rights supplement entity and canonical listener rights; they never replace them.
The group applies when a registration on that entity is selected, including selection
as a parent fallback. Do not acquire the groups of every entity traversed while finding
the selected listener. Explicit notify_datareaders delegation keeps its accepted
same-chain inherited-rights exception; automatic callbacks cannot overlap or reenter
the occupied group. Group membership does not impose a global ordering of incoming
samples or turn related readers into a coherent presentation group.

Configured construction retains group identity before publishing the entity; failure
releases temporary references. Entities and outstanding callback work keep group
storage alive after the application's group handle is released. Reject references
from an incompatible core domain rather than silently creating independent exclusion.
There is no live reassignment or independent group-close operation in this initial
surface. Existing retired-frontier rules still govern listener replacement/deletion.

Add the corresponding configured subscriber/reader creation paths and entity Config
fields when assembling IDL, following the same _ex pattern. Topic/participant listener
configuration must expose the same option. Exact standalone group constructor and
reference-release ABI remain integration work. Shared listener identity still needs
no application API; designated-executor dispatch and affinity remain separate future
placement policies.

**Manual driver (two-layer direction accepted 2026-09-16):** the
[simple driver and external-loop contract](manual-runtime-driver.md) supplies a
concrete semantic proposal. A bounded drive operation must state whether it permits application
callbacks, what constitutes budget exhaustion/idle, and how the caller waits for the
next wake/deadline. Internal helping has narrower rights than an outer application
driver. Ordinary teardown must hand retirement work to a valid outer driver; explicit
external-loop integration must establish continued servicing before accepting work.
Specify wake registration/acknowledgment and retirement completion together rather than
publishing a standalone poll function with a hidden shutdown requirement.

Explicit runtime stop, if exposed, is a zzdds control distinct from releasing an owner.
It is never required of standard applications. Final stop/drive signatures must use the
accepted retirement and callback-dependency rules; do not promise synchronous joining
from a callback or let a stopped runtime abandon cleanup.

## Internal mechanisms and binding facilities

Admission tickets, request generations, sample pins, callback invocation claims,
prepared-access handles, canonical listener identity keys, and I/O completion records
are internal. Do not add getters for them to DDS entities. Cross-language bridges may
need versioned private envelopes without creating application-facing DDS operations.

C/C++ precise result-and-count helpers are additive typed binding conveniences.
Java AccessFailure is a proposed spelling for the accepted unchecked failure mechanism.
Public shared metadata belongs in zzdds.idl; language exception causes and RAII wrappers
remain binding facilities. Existing CDR result codes stay in their own domain.

Allocator ownership anchors need a versioned bridge. Do not append unversioned fields
to existing allocator descriptors or reinterpret borrowed pointers as retained owners.
C/Zig releases must be explicit; managed references alone do not establish deterministic
resource release. RuntimeRef and ResourceCompletion aliases retain observation storage,
not operational leases or the resources they are waiting to reclaim.

## Rollout and specification completion

Before generating public code, review the resulting zzdds.idl additions and bootstrap
ABI together for nil/error conventions, reference transfer, partial-construction cleanup,
base/extension identity and version compatibility. Validate actual zidl support for the
chosen interface-valued configuration and exception representation. Do not assume a
semantic table alone guarantees generator support.

The creation, driver, reference/configuration and portable bootstrap reviews are complete.
The [readiness review](concurrency-final-review.md) records the behavioral v1 milestone.
Concrete ABI generation/publication and actual backend validation remain release gates.
The next specification work is broker reconciliation, not another general prototype.

Production race tests, backend performance and embedded footprint measurements remain
implementation acceptance work. They do not require extending this specification phase
with another general scheduler prototype.

## Signature draft — 2026-09-16

The [API draft](concurrency-api-draft.md) translates the selected creation, ownership,
group and single-outer-driver policies into IDL fragments and bootstrap signatures.
The next integration gate is interface-reference ownership and construction-only
config fields; production IDL remains unchanged.
