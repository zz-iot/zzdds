# Experimental programmatic resource construction

Enable `-Dresource-construction=true` to use `zzdds.resources`. The default build
keeps the API disabled. This first slice supplies owned concrete application plans,
static type registration and whole-graph construction through public DDS interfaces.
It is an experimental Zig API, not a profile parser or a stable serialization format.

## Define and resolve

```zig
const R = zzdds.resources;
var plan = try R.Plan.resolve(allocator, .{
    .name = "WriterApp",
    .participants = &.{.{
        .name = "main",
        .domain_id = 42,
        .types = &.{.{ .name = "Probe" }},
        .topics = &.{.{
            .name = "announcement",
            .topic_name = "Announcement",
            .type_ref = "Probe",
        }},
        .publishers = &.{.{ .name = "pub" }},
        .writers = &.{.{
            .name = "endpoint",
            .container_ref = "pub",
            .topic_ref = "announcement",
        }},
    }},
}, .{});
defer plan.deinit();
```

Names are exact byte strings scoped to their collection. Participant names are
application-scoped; type/topic/container/endpoint names are participant-scoped,
separately for each kind. A topic definition name is distinct from its DDS topic
name. Type names are the actual registered DDS names; aliases are not implemented.
All references resolve within the owning participant. References point downward;
inheritance and recursive references are not representable, so no cycle detector
is needed for this subset.

Resolution validates unique names, nonempty bounded names without embedded NUL,
unique DDS topic names per participant, references, domains and QoS before copying
any authored records. The plan owns all strings and collections, including private
string terminators required by the generated DDS API. Authored storage may be freed
or changed after resolution. Treat the resolved plan as immutable; do not copy its
owner or modify its fields. No native callbacks or handles are stored in the plan.

Defaults limit a plan to 1,024 resources (including its application, participants,
types, topics, containers and endpoints) and each name to 128 bytes. Limits can be
supplied to resolution. Domains are deliberately limited to 0–232 for the first
hosted/RTPS subset; this is not a claim that DDS generally limits domain identifiers
to that range. There is no implicit domain allocation or environment substitution.

## Bind and construct

A `StaticBinding` maps each required type name to a fallible registration callback.
The callback receives the new participant and the exact required name. It must
install independently owned participant support, report registration errors, and
not transfer the same owned context repeatedly. Its input context is borrowed for
`build` only; any context installed into DDS must have its own sufficient lifetime.
For generated `computeKeyHashFromCdr` callbacks the context is an allocator pointer:
that allocator object and its backing allocator must outlive the participant and
its deferred work. See the compiled acceptance fixture for a complete example.

```zig
var instance = try R.Instance.init(allocator, &plan, factory.toDDSFactory());
// This example terminates if cleanup fails. A service would retain/retry ownership.
defer instance.deinit() catch @panic("resource cleanup failed");
try instance.build(&bindings);
const writer = try instance.writer("main", "endpoint");
// Use generated typed wrappers or the existing DDS/raw APIs with this handle.
// ...
try instance.destroy();
```

The fragment shows the successful path; callers must also call `deinit` after a
failed `build` to release bookkeeping. Build automatically attempts rollback and
returns its primary construction error. If rollback also fails, `cleanup_error`
records that second error and partial ownership remains intact for diagnosis/retry. Do not use an error path that drops the instance. A process may choose to
terminate on unrecoverable cleanup failure; a long-running service must retain and
retry cleanup rather than ignoring the error.

Instance initialization allocates all graph bookkeeping before any DDS calls.
Build preflights missing/duplicate bindings, then creates participants, registers
types, and creates topics, publishers/subscribers, writers/readers. Every build is
single-use. A missing binding can be corrected and retried before construction
begins; once construction starts, failure requires cleanup and a new instance.
Multiple instances may borrow the same plan; they own separate DDS graphs.

The instance borrows the plan and caller-owned factory through successful cleanup.
The factory's runtime/transport/discovery setup is explicit caller policy; this API
performs no ambient configuration file lookup. Ordinary DDS factory enablement rules
still apply. `ready` means all local constructors succeeded, not that entities are
announced, matched, enabled by the caller's factory policy, or remotely reachable.
No runtime is created or selected by this layer.

Calls to an instance are serialized by its owner. The builder holds no mutex
across DDS calls or the registration hooks it runs. A hook may request `cancel`,
or call `destroy`, which requests cancellation and returns
`ConstructionInProgress`. It never waits for its own constructor. Cancellation is
checked after DDS calls; it does not interrupt one in progress.
Listener callbacks run as turns of the shared runtime, not inside DDS creation.
A callback on another worker must send lifecycle requests to the instance's
owner rather than calling this owner-serialized API concurrently. General
external lifecycle mutation, including deleting already-created endpoints behind
the builder, is unsupported. Prefer cancellation of the enclosing construction
instead.

A failed build exposes no endpoints through the accessors and attempts immediate
rollback. If cleanup fails, it retains the partial graph and `cleanup_error`. `destroy` visits participants in reverse order, drains and deletes their recorded
subscribers and publishers, deletes their topics, then deletes each participant
through its factory. It uses the public container-level `delete_contained_entities`
operations rather than the participant-wide cascade, which has a threaded lock-order
inversion against endpoint deletion. Successful deletions are cleared from bookkeeping. Failure preserves the remaining
owner for retry. Destruction rejects recursive cleanup with `CleanupInProgress`.
`destroy` is idempotent; `deinit` releases bookkeeping after successful destruction
and must be called once. Neither operation destroys the caller's factory.

Returned reader/writer handles are borrowed. Use them only while the instance is
ready and its entities remain alive. Coordinate outstanding application operations,
loans and callbacks before destruction; do not delete or replace owned entities
through those handles. The backing DDS allocators must outlive deferred retirement.
Local rollback cannot retract remote discovery observations or guarantee disposal
transmission under memory exhaustion on the current threaded implementation.

## QoS and scope

The concrete endpoint QoS subset has a reliability choice, positive finite history
and resource limits, VOLATILE durability, KEEP_LAST history and an explicit
`data_representation` choice (`.XCDR1` by default, or `.XCDR2`). Each endpoint
selects one representation; this does not convert serialized samples. This experimental module requires the default `-Dxtypes=true` build:
existing core representation storage does not compile with XTypes disabled, and
this slice does not repair that separate configuration. Default history
depth is 1; limits are 32 samples, one instance and 32 samples per instance.
Resolution rejects inconsistent limits/depth. Container and topic QoS use generated
DDS defaults. No arbitrary QoS object/pointer is borrowed from authoring storage.

The separate experimental [authoring frontend](resource-authoring.md) now adds
TOML records, single-base profiles and source provenance into these same plans.
Partitions, additional representations/policies, provider libraries, persistent
portable plan encoding, incremental XRCE construction and standard XML/JSON
frontends follow separately. These concrete records
are intentionally smaller than the eventual catalog; they do not freeze TOML names
or claim DDS-XML/DDS-JSON support. Future runtime migration must reuse its supported
public APIs and capability checks, not bypass creation failures or select a fallback.

## Verification

```sh
zig build test-resource-construction -Dresource-construction=true
zig build test-resource-construction -Dresource-construction=true -Doptimize=ReleaseSafe
zig build test-resource-construction -Dresource-construction=true -Dsanitize-thread=true
zig build test -Dresource-construction=true
```

The focused target fails explicitly if its opt-in is omitted. The enabled tests
also join the ordinary test step and emitted native test artifacts. TSan uses LLVM.
CI's `resources-typesupport` job runs them on every PR: native Linux in Debug and ReleaseSafe,
macOS and Windows in ReleaseSafe, plus Linux ThreadSanitizer and authoring checks.
Remote execution is separate evidence from local Linux checks.

The [acceptance fixture](../test/dcps/resource_construction_test.zig) builds a static
[zidl-generated Probe](../test/resources/resource_probe.idl), instantiates separate
writer and reader applications with real in-process DDS transport/discovery,
exchanges generated typed samples, and destroys one writer while another remains
usable. It tests invalid references/QoS/budgets, owned plan copies, plan/bookkeeping
allocation failures, missing bindings, registration failure, late failure after an
earlier graph was built, retryable deletion, cancellation, and writer/reader deletion
from a synchronous match callback. In-process delivery establishes local graph reuse;
it is not evidence of UDP interoperability, broker readiness or manual runtime support.


For explicit multi-library sources, generation-pinned preparation and participant-
scoped bindings, see [resource provider bindings](resource-providers.md). Ordinary
compiled registrations can continue using this API without the loadable library ABI.

## Incremental construction

`resources.Incremental` constructs one requested object at a time from an owned
Plan. It shares binding validation, registration, topic construction and endpoint
QoS translation with whole-graph Instances. Initialize it with a borrowed factory,
bindings and an explicit live-object capacity (1–65,536 slots). Initialization
allocates bookkeeping but creates no DDS entities.

```zig
var graph = try R.Incremental.init(allocator, &plan, factory, bindings, 32);
// Call try graph.deinit() before releasing the plan/factory/binding contexts.
const participant = try graph.createParticipant("main");
const topic = try graph.createTopic(participant, "reading");
const publisher = try graph.createPublisher(participant, "pub");
const writer = try graph.createWriter(publisher, topic, "reading");
const borrowed_writer = try graph.writer(writer);
_ = borrowed_writer;
try graph.delete(writer);
```

A participant installs its selected type registrations, but creates no topics or
endpoints. Publisher/subscriber creation requires an existing participant. Writer/
reader creation requires an existing container and topic matching the definition,
in the same participant instance. Missing dependencies are rejected; the builder
does not create them implicitly. Each participant creation yields a distinct
instance, even when it uses the same definition. Duplicate topic creation within
one participant is rejected to avoid two deletion owners for one DDS Topic.

Handles belong to the graph's address and a slot generation. Cross-owner, wrong-kind
and deleted/reused handles are rejected. The owner can move before first use but
must remain at a stable address afterward. Do not copy it, mutate its bookkeeping,
delete borrowed DDS handles externally, or use handles after successful deinit.
The Plan, factory, binding array and registration contexts must outlive the graph.
Operations are serialized by the caller; this API adds no concurrent mutation or
XRCE object-ID/session policy. DDS callbacks may request cancel/destroy reentrantly
on that same owner thread, but must not free the owner or mutate its entities.

Deletion is leaf-only and checks both parent ownership and endpoint-to-topic
references. Destroy follows resource dependencies rather than slot order, which
may change after reuse. A failed create rolls back only its own candidate, leaving
unrelated resources intact. If rollback fails, `cleanup_error` retains the secondary
error and all remaining handles stay owned; new operations are blocked. Retry
`destroy`/`deinit`, keeping the allocator and dependencies alive until success.
Explicit failed deletion similarly retains the object for whole-owner cleanup.
Reentrant destroy during construction requests cancellation and returns
`ConstructionInProgress`; actual cleanup follows after the callback returns.

Construction uses the factory's existing enable behavior. Disabled DDS parents
currently reject some child deletion operations; using disabled construction does
not establish atomic staging, automatic enablement or announcement rollback.
These backend limitations also apply to incremental ownership. Successful logical
cleanup is subject to the existing deferred-retirement allocator lifetime rules.
