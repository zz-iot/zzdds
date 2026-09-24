# Concurrency API draft

Status: reconciled signature review, 2026-09-16. Single outer manual driver per runtime
is accepted. The declarations below are design fragments for eventual zzdds.idl;
they are not additions to the production IDL, parser-tested output, or an ABI freeze.
The extension-surface inventory and its ownership contracts remain authoritative.

## Configured entity creation

Retain the existing create_participant_ex signature. Extend its DomainParticipantConfig
with construction-only runtime selection and listener-group inputs, plus scalar
concurrency limits. These references must be excluded from file/wire serialization;
file configuration supplies scalar defaults only. If the generator cannot safely
separate those roles, use a versioned construction-options envelope at the bridge
rather than serialize handles or silently replace the existing ABI.

Proposed types (forward declarations and @shared_c_abi_box annotations omitted here):

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

## Runtime ownership and selection

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
    @default(4) unsigned long prepared_access_stale_validation_limit;
};
// Additional fields in zzdds::DomainParticipantConfig:
// RuntimeSelection runtime_selection;
// ListenerConfig listener;
// ParticipantConcurrencyConfig concurrency;
```

Names are draft spellings of the accepted inventory, not production declarations.
The two numeric defaults are build-changeable; the generated default-config path
must reflect the selected build defaults consistently across bindings rather than
hard-code the illustrative annotation values independently. Both limits are positive,
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

## WaitSet and resources

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

Default helping policy is DEFAULT_SHARED_RUNTIME, with an empty sequence. Sequence
inputs are borrowed for the call; construction retains deduplicated runtime identities.
Sealing is idempotent, blocks new independent resource admission and preserves existing
cleanup rights. Completion becomes ready only after sealing and all covered use ends.
Acquire its independently allocated observation token before dismantling the scope.
Resource anchors and allocator descriptors use the versioned bootstrap below.

## Simple driver signatures

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

## Versioned standalone bootstrap

The [bootstrap contract](runtime-bootstrap-contract.md) defines accepted validation,
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
see manual-runtime-driver.md. A portable timestamp cannot be finalized before choosing
the backend clock-domain bridge. Detach cannot abandon accepted cleanup.

## Generator and ABI review still required

Existing zzdds interfaces use @shared_c_abi_box to preserve entity views. zidl's Zig
C-ABI sequence-free emission explicitly treats interface elements as independently
owned boxes (src/backend/zig.zig, interface-sequence handling near line 1550). Therefore
an IDL sequence does not, by itself, implement RuntimeRefSeq's retained ownership:
constructor adapters must retain each referenced object, and output wrappers need
explicit reference-transfer conventions. New standalone reference objects must not
inherit DDS entity deletion semantics accidentally.

Validate interface-valued struct fields, empty/default interface initialization,
sequences, inout interface output and multiple base/extension views across C, Zig,
C++ and Java. Check config-file generation rejects or excludes construction-only
references. Verify library-owned default allocation and all failed-construction paths.
Changing existing struct/vtable layout needs a coordinated versioned ABI rollout and
regeneration; adding IDL fields is not automatically binary compatible.

The generator capability check and construction-config requirements are recorded below.
The fragments above intentionally do not claim to settle
platform adapter layouts, reference ownership generation or all runtime capacity knobs.

## Generator check result

The [bounded generator probe](concurrency-generator-check.md) found unsupported
TOML reference fields, unsafe Zig reference defaults, inconsistent inout-interface
emission and aggregate C-ABI conversion gaps. The declarations above remain a
semantic draft; do not apply them to production IDL until the documented generator
work or an explicitly reviewed alternative representation is ready.

The [generic binding requirements](../../../zidl/docs/design/construction-reference-bindings.md)
now define the required sequence, mixed-Config and TOML behavior: independent owned
elements, staged cloning with rollback, safe defaults, and file overlays that preserve
programmatic references and reject attempts to configure them from a file. Mixed
construction Configs are not wire types. The bounded generated C/Zig experiment
validates direct reference fields and inout ownership only; completing the remaining
binding implementations is a production integration gate, not a prerequisite for
finishing this semantic specification.
