# Concurrency: extension api

Requirements use the [shared convention](../concurrency-broker-status.md#requirement-convention).
[The index](../concurrency-broker-status.md) owns scope and unresolved design items;
[the evidence inventory](../../../test/design-models/README.md) records validation.
<a id="concurrency-api"></a>
## Concurrency API

<a id="configured-entity-creation"></a>
### Configured entity creation

Retain the existing create_participant_ex signature. Extend its DomainParticipantConfig
with construction-only runtime selection and listener-group inputs, plus scalar
concurrency limits. These references must be excluded from file/wire serialization;
file configuration supplies scalar defaults only. If the generator cannot safely
separate those roles, use a versioned construction-options envelope at the bridge
rather than serialize handles or silently replace the existing ABI.

Target types (forward declarations and @shared_c_abi_box annotations omitted here):

```idl
interface ListenerGroup {};

struct ListenerConfig {
    ListenerGroup group; // nil: no explicit group; borrowed input, retained on success
};
struct PublisherConfig { ListenerConfig listener; };
struct SubscriberConfig { ListenerConfig listener; };
struct TopicConfig { ListenerConfig listener; };
struct DataReaderConfig { ListenerConfig listener; };
struct DataWriterConfig {
    ListenerConfig listener;
    @default(1) unsigned long preparation_limit_per_instance;
};
```

Add these methods to zzdds::DomainParticipant:

```idl
DDS::Publisher create_publisher_ex(
    in DDS::PublisherQos qos, in DDS::PublisherListener a_listener,
    in DDS::StatusMask mask, in PublisherConfig config);
DDS::Subscriber create_subscriber_ex(
    in DDS::SubscriberQos qos, in DDS::SubscriberListener a_listener,
    in DDS::StatusMask mask, in SubscriberConfig config);
DDS::Topic create_topic_ex(
    in string topic_name, in string type_name, in DDS::TopicQos qos,
    in DDS::TopicListener a_listener, in DDS::StatusMask mask,
    in TopicConfig config);
```

New extensions preserve the ordinary factory relationship:

```idl
interface Publisher : DDS::Publisher {
    DDS::DataWriter create_datawriter_ex(
        in DDS::Topic a_topic, in DDS::DataWriterQos qos,
        in DDS::DataWriterListener a_listener, in DDS::StatusMask mask,
        in DataWriterConfig config);
};
interface Subscriber : DDS::Subscriber {
    DDS::DataReader create_datareader_ex(
        in DDS::TopicDescription a_topic, in DDS::DataReaderQos qos,
        in DDS::DataReaderListener a_listener, in DDS::StatusMask mask,
        in DataReaderConfig config);
};
```

Standard constructors use default Config values. Nil group does not inherit the
parent's group. Creation retains supplied references before entity publication and
rolls back on failure, returning a nil entity by the existing constructor convention.
A shared ListenerGroup does not contain entities or own their runtimes. Releasing the
application handle leaves entity-held and in-flight group references intact.

<a id="runtime-ownership-and-selection"></a>
### Runtime ownership and selection

```idl
enum RuntimeState { RUNNING, RETIRING, BACKEND_STOPPED };
interface RuntimeRef;
interface RuntimeOwner;
interface RuntimeRef {
    RuntimeState get_state();
    DDS::ReturnCode_t try_acquire_owner(inout RuntimeOwner owner);
};
interface RuntimeOwner {
    RuntimeRef get_runtime();
    DDS::ReturnCode_t release();
};
enum RuntimeSelectionKind { FOLLOW_DEFAULT, EXPLICIT_RUNTIME };
struct RuntimeSelection {
    RuntimeSelectionKind kind;
    RuntimeRef runtime;
};
```

FOLLOW_DEFAULT requires nil runtime; EXPLICIT_RUNTIME requires a valid reference.
In participant configuration, FOLLOW_DEFAULT resolves the factory's runtime selection.
In factory selection, FOLLOW_DEFAULT resolves the core default at each creation.
Neither means eagerly resolve and retain today's implicit default.
Participant and explicit factory selection acquire operational leases transactionally.
The Config itself owns no operational lease. Returned RuntimeRef objects retain
observation storage; wrapper destruction/release is distinct from RuntimeOwner.release,
which relinquishes the operational lease idempotently on a still-valid lease object.
Failure of try_acquire_owner produces nil output; callers supply an empty output slot.

Complete the factory and participant extension fragments with:

```idl
// On zzdds::DomainParticipantFactory:
DDS::ReturnCode_t set_runtime_selection(in RuntimeSelection selection);
DDS::ReturnCode_t get_runtime_selection(inout RuntimeSelection selection);
// On zzdds::DomainParticipant:
RuntimeRef get_runtime();

struct ParticipantConcurrencyConfig {
    @default(8) unsigned long delegation_nesting_limit;
    @default(2) unsigned long listener_preparation_attempts_per_turn;
    @default(8) unsigned long listener_stale_validation_limit;
    @default(1) unsigned long listener_retry_initial_ms;
    @default(1000) unsigned long listener_retry_max_ms;
};
// Additional fields in zzdds::DomainParticipantConfig:
// RuntimeSelection runtime_selection;
// ListenerConfig listener;
// ParticipantConcurrencyConfig concurrency;
```

Names are draft spellings of the accepted inventory, not production declarations.
These numeric defaults are build-changeable; the generated default-config path
must reflect the selected build defaults consistently across bindings rather than
hard-code the illustrative annotation values independently. Counts and delays are positive; initial retry delay must not exceed its cap. They are
finite and fixed at participant creation. Cross-participant delegation uses the
accepted minimum limit along the chain. Standard creation receives these same defaults.

Factory selection replacement first validates and acquires any new operational lease,
then publishes the policy, then releases the old lease outside metadata locks. Failure
leaves the previous selection unchanged. Existing participants never migrate. Its
getter returns the configured policy and retained observation references, without
resolving an implicit default or acquiring operational ownership. The participant
getter returns its fixed runtime identity, also without an operational acquisition.
Getter output replacement must stage fallible cloning before replacing caller storage.

Keep factory runtime selection distinct from the existing default participant Config:
storing a Config retains reference storage only. An explicit participant override is
promoted when creating that participant and can fail if its runtime has retired.
An explicitly selected factory runtime instead holds a lease until selection replacement
or factory destruction. Existing set/get_default_participant_config must obey the
mixed-Config clone/failure rules; a shallow copy of new reference fields is insufficient.

The core default controller additionally needs IMPLICIT_DEFAULT, EXPLICIT_DEFAULT and
DISABLED states, plus an observing lookup that does not instantiate a runtime. Its
bootstrap is scoped to one loaded core. Explicit installation retains identity, not
operational ownership; an application must retain an owner elsewhere. Do not conflate
this controller with factory-local FOLLOW_DEFAULT selection.

Do not expose RECLAIMED through a retained RuntimeRef: its own observation storage
has not been reclaimed. BACKEND_STOPPED is distinct from a ResourceCompletion fence.
No force-stop operation is required in this initial signature set; adding one requires
an explicit authority/error contract rather than an alias for owner release.

<a id="waitset-and-resources"></a>
### WaitSet and resources

```idl
typedef sequence<RuntimeRef> RuntimeRefSeq;
enum HelpingPolicy { DEFAULT_SHARED_RUNTIME, EXPLICIT_RUNTIMES, NO_HELPING };
struct WaitSetConfig {
    HelpingPolicy helping_policy;
    RuntimeRefSeq runtimes;
};
interface WaitSet : DDS::WaitSet { DDS::ReturnCode_t close(); };
interface ResourceCompletion {
    boolean is_ready();
    DDS::ReturnCode_t wait(in DDS::Duration_t max_wait);
};
interface ResourceScope {
    ResourceCompletion get_completion();
    DDS::ReturnCode_t seal();
};
```

Default helping policy is DEFAULT_SHARED_RUNTIME, with an empty sequence.
For ordinary hosted callers this is observe-only; manual-runtime and callback-chain
waits may help permitted internal work on the resolved runtime. Explicit-runtime
selection permits helping only within the selected backend's capabilities and the
callback exclusion rules; NO_HELPING never pumps runtime work. Sequence
inputs are borrowed for the call; construction retains deduplicated runtime identities.
Sealing is idempotent, blocks new independent resource admission and preserves existing
cleanup rights. Completion becomes ready only after sealing and all covered use ends.
Acquire its independently allocated observation token before dismantling the scope.
Resource anchors and allocator descriptors use the versioned bootstrap below.

<a id="simple-driver-signatures"></a>
### Simple driver signatures

```idl
struct DriveBudget { unsigned long max_turns; };
struct DriveResult {
    unsigned long turns_performed;
    boolean immediate_work;
    RuntimeState state;
    boolean retirement_pending;
};
interface ManualDriver {
    DDS::ReturnCode_t drive(in DriveBudget budget,
        in DDS::Duration_t max_wait, inout DriveResult result);
    RuntimeRef get_runtime();
};
```

Budget must be positive. Waiting expiry is OK with zero turns. Recursive/concurrent
outer driving returns PRECONDITION_NOT_MET without starting work. Backend failure
returns ERROR while preserving an initialized result describing any work already done
and remaining retirement obligation. An error does not authorize destroying resources.
Driver creation validates manual backend compatibility and any thread affinity.
The driver retains progress resources, not operational ownership. Accepted standard
teardown tails may exceed the normal turn/wait budget.

<a id="versioned-standalone-bootstrap"></a>
### Versioned standalone bootstrap

The [bootstrap contract](runtime.md#standalone-runtime-bootstrap-contract) defines accepted validation,
failure/publication, resource retention and clock compatibility rules for this table.
Its initial external attachment restriction is accepted. Concrete signatures/layouts
still require coordinated generation and ABI review before publication.

These are semantic signatures, not literal C declarations. Each operation returns a
DDS result and an initially empty output handle; failure publishes no partial object.
A bridge descriptor includes size/version and explicit retain/release hooks where
needed. Generated language wrappers provide the established standalone constructor form.

| Operation | Inputs | Output |
| --- | --- | --- |
| create_runtime | Backend/scalar RuntimeConfig, retained resource anchor or tracked borrowed scope | RuntimeOwner |
| create_listener_group | Core context, allocation/resource selection | ListenerGroup |
| create_waitset_ex | WaitSetConfig, allocation/resource selection | zzdds WaitSet |
| create_resource_scope | Explicit coverage and borrowed-resource descriptor | ResourceScope plus independent completion observation |
| create_manual_driver | RuntimeRef, supported simple-driver policy | ManualDriver |
| attach_external_loop | RuntimeRef, versioned platform wake/completion adapter | ExternalDriver registration |
| configure_core_default | Explicit default-selection kind and optional RuntimeRef | Result only |
| observe_core_default | Core context | Selection state and optional RuntimeRef; no lazy creation |

ExternalDriver must expose bounded nonblocking service, atomic prepare-to-wait,
wake acknowledgment/recheck and explicit detach. Platform wait handles and clock
representations belong in the platform adapter. The portable contract returns an
opaque wake generation, immediate readiness, next deadline and retirement obligation;
see [external-loop driving](runtime.md#manual-runtime-driving-and-external-loop-integration). A portable timestamp cannot be finalized before choosing
the backend clock-domain bridge. Detach cannot abandon accepted cleanup.

<a id="concurrency-extension-surface"></a>
## Concurrency extension surface

<a id="standard-application-baseline"></a>
### Standard application baseline

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

<a id="required-extension-inventory"></a>
### Required extension inventory

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
| Participant concurrency configuration | Positive finite delegation nesting limit; distinct listener preparation budgets | Creation-time; nesting build default eight and cross-participant minimum rule; no read/take stale-validation budget (D7/D8) |
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

<a id="first-shipped-subset-versus-complete-design"></a>
### First shipped subset versus complete design

A first vertical slice may ship scalar Config creation defaults, ordinary DDS entity APIs,
one manual driver and hosted runtime, while deferring explicit runtime-owner/resource/group
objects. Standard creation still enforces canonical listener exclusion and automatic runtime
cleanup. An unsupported extension must fail explicitly, never weaken shared semantics.
The cooperative measurement profile uses one participant, bounded reliable writer/reader,
ReadCondition/WaitSet and UDP with fixed storage; no advanced extension is needed merely
to exercise its standard operations. The full reference ownership and construction-only
Config contract remains the integration target for later surfaces.

<a id="listener-group-reference-lifecycle"></a>
## Listener-group reference lifecycle

<a id="what-the-application-does"></a>
### What the application does

Create a group, place it in a reader Config, and pass that Config to
create_datareader_ex(topic, qos, listener, mask, config). The call does not consume the
Config or the application's group reference. After successful creation, either can
be discarded without removing the reader's group membership. Another entity may use
the same group. Standard creation without a group keeps existing default behavior.

No per-call retain/release function arguments are added. The group implementation
and generated managed-reference bridge supply those functions once. Group membership
controls callback exclusion; it does not retain an operational runtime lease or extend
the lifetime of application-owned listener contexts.

<a id="ownership-trace"></a>
### Ownership trace

The counts below represent logical ownership obligations, not a requirement for one
atomic increment per wrapper alias or language reference.

| Step | Live ownership | Required action |
| --- | --- | --- |
| Create group | Application group handle | Constructor transfers one owned reference |
| Put group in owning Config | Application handle + Config field | Retain/copy managed reference; replacing an old field releases its old ownership |
| Enter configured reader creation | Same owners; call borrows Config | Caller keeps Config stable/alive for the synchronous call |
| Prepare reader | Previous owners + provisional entity membership | Retain group before publication; validate same core domain |
| Creation fails | Application handle + Config field | Release provisional membership and other construction resources |
| Creation succeeds | Application handle + Config field + reader membership | Transfer provisional membership into published reader; no extra retain required |
| Destroy Config and application group handle | Reader membership | Drop only their reference obligations |
| Replace listener | Reader membership remains | Retire old listener registration under existing setter rules; group is unchanged |
| Logically delete reader | Retained entity/callback work still protects membership | Stop new eligibility; do not release storage needed by a claimed invocation |
| Last relevant work retires | No reader membership needed | Release membership after group rights/wake obligations are safely relinquished |
| Last group reference retires | None | Reclaim group storage and any independently owned bridge identity |

If another entity/config owns the group, it survives the final step for this reader.
A group does not own its member entities permanently. Dispatch may retain an entity
(which protects its group transitively) or retain the group directly; either is valid
provided the obligation is explicit and not duplicated or lost.

<a id="callback-and-replacement-cases"></a>
### Callback and replacement cases

An eligible invocation holds entity, listener-identity and optional group execution
rights. Ownership of storage and possession of execution rights are different: merely
retaining a group never blocks another callback. Acquiring group rights does not by
itself keep a freed group object safe.

An active callback may delete its reader. Logical deletion returns according to the
accepted callback rule; the invocation keeps membership storage valid until it unwinds.
It then releases group rights and publishes any wake for another runtime before its
last storage protection disappears. Mandatory wake bookkeeping must not allocate after
logical deletion. An external delete's application-quiescence guarantee need not wait
for every internal storage reference to disappear.

Listener replacement never moves the reader between groups. If no listener is installed,
the entity still retains its creation-time group for a later registration. Parent fallback
uses the selected registration entity's group, not every group traversed during lookup.
Same-chain explicit delegation retains its accepted inherited-rights exception.

Pending records must retire or relinquish ownership when invalidated. A group queue
must not permanently own an entity that owns the group: cancellation/claim retirement
must break any temporary cycle, and dormant membership must not create one.

<a id="binding-consequences"></a>
### Binding consequences

**C++:** an owning group wrapper can use shared ownership; copying it into a Config
keeps the reference target alive. Copies may share one native ownership anchor. Reader
creation establishes independent core membership before returning. Destroying the
Config cannot invalidate that membership. No DDS entity deletion is inferred from
last-wrapper release.

**Java:** a Config field keeps its group wrapper reachable. The native reader must
retain its own group reference at creation; it cannot depend on future Java reachability.
Deterministic wrapper close and fallback cleanup must release their native ownership
once. A closed wrapper still referenced by a Config must be detected at conversion,
not dereferenced as a stale handle. Document whether close invalidates aliases of that
same wrapper; it must not close the shared exclusion domain for other retained members.

**C/Zig:** raw field assignment is not an implicit retain. Provide generated owning
field assignment/clone/move/destroy helpers or an equally explicit scoped API. For
example, a conceptual set_group_retained helper retains the new value before releasing
the old one, including self-assignment. A borrowed Config view may be passed synchronously
only while its owner protects every reference; it must never be destroyed as though
it owned those borrowed fields. The eventual representation must distinguish these
conventions clearly. This helper requirement is generic, not listener-group-specific.

**C-ABI conversion:** use a borrowed argument view or a temporary owning conversion,
with explicit cleanup. Both must convert interface views correctly and propagate failure.
Neither may accidentally add an operational lease, drop a group, or substitute nil.
A borrowed conversion does not permit the callee to save pointers into the Config.

## Generated reference and construction-Config requirements

These are generic zidl capabilities used by zzdds, not generator special cases keyed to
RuntimeOwner or other DDS names. Opted-in managed references retain storage/identity;
consumer objects define operational ownership, close and retirement. Existing shared C-ABI
boxing preserves interface views but does not itself imply managed-reference lifetime.
Plugin extraction is separate future work and is not a prerequisite.

Inputs borrow for the call; retaining/queueing stores its own reference. Owned return/out
values transfer one reference to the result; failed boxing releases it. Owning Config
fields and sequence elements each retain an independent non-nil reference. Clone stages
all fallible work and rolls back partial acquisition; destruction releases exactly those
references. Nil defaults must be initialized and safely destructible in every binding.
C/Zig shallow assignment is not implicit retain. Ref copies never acquire an operational
RuntimeOwner lease implicitly. Raw lookup followed by unprotected retain is insufficient.

Use correct declared-interface conversion for base/extension views, including adjusted
pointers; do not reinterpret vtables or copy native fat references into opaque C handle
fields. Preserve layout/alignment and identity. Inout needs an actual replaceable slot
or language holder; a Java reference passed by value is not output replacement. Stage
replacement and cleanup explicitly, retaining the old owned slot on failed publication.
Operation-specific success/effect conventions remain explicit; the generic generator must
not interpret integer zero or DDS return codes as universal transaction success.

Construction Configs combine scalar settings with process-local references, but are not
wire types. File overlays apply supported scalars while preserving programmatic references
and rejecting attempts to set those references from a file. A nested struct is not an
exclusion mechanism by itself. Require generic construction-only metadata/conversion;
do not silently ignore unsupported fields, manufacture nil, or turn failed sequence
conversion into an empty successful runtime selection. Keep the chosen _ex(..., Config)
public pattern; private bridge envelopes may implement it without adding user parameters.

Before publication, compile and execute scalar/reference/sequence and mixed-Config cases
across C, Zig, C++ and Java. Cover nil defaults, inout replacement, allocation failure,
partial clone rollback, base/extension aliases, release hooks and scalar TOML overlays.
Generation alone or the bounded direct-reference probe does not establish support.
Standalone managed references do not inherit DDS entity deletion conventions.
