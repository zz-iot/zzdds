# Concurrency: runtime

This is a current contract. Scope, decisions and implementation gates are in
[the single status index](../concurrency-broker-status.md). Validation results are maintained
only in [the evidence inventory](../../../test/design-models/README.md).
<a id="runtime-ownership"></a>
## Shared runtime ownership and construction

<a id="runtime-ownership--separate-dds-containment-from-execution-resources"></a>
### Separate DDS containment from execution resources

A runtime owns execution/progress infrastructure: ready work, timer/wakeup integration,
backend driver state, and the lifetime accounting needed by retained I/O and cleanup.
It does not become the DDS parent of a participant, publisher, subscriber or endpoint.
Factories retain their participant-management and configuration role. A shared runtime
does not imply shared discovery sessions, transport channels, sockets or security
credentials: those have their own sharing/ownership contracts.

Current `src/dcps/factory.zig` explicitly supports multiple factories, with transport,
discovery/security values and a participant list per factory. Its current deinit
iterates participants. The shared-runtime design must not infer runtime ownership
from that existing containment or silently make one factory a process singleton.

<a id="runtime-ownership--selected-selection-hierarchy"></a>
### Selected selection hierarchy

| Construction | Runtime choice |
| --- | --- |
| Standard participant creation | Resolve the factory's default selection at participant creation |
| Participant creation with explicit runtime | Use that runtime, overriding the factory default |
| Factory default selection | Initially the configured core default; alternatively an explicit retained runtime |
| Standard WaitSet wait | Resolve the current configured core default for each invocation, as already accepted |

A factory's default *selection policy* is distinct from a resolved runtime reference.
An ambient/default selection resolves at each participant creation, not when the
factory object was allocated. Each participant retains its selected runtime for its
whole lifetime; replacing the default does not migrate existing entities. Explicit
factory selections remain fixed until an explicit default-setting operation changes
future creation; participant overrides never change sibling/default selections.

Runtime references must be typed runtime identities with safe lifetime retention,
not transport pointers or participant handles. Explicit configuration and runtime
operations belong in zzdds.idl. Standard DDS APIs remain usable with the default.
Cross-runtime listener identity exclusion stays core-wide and is unaffected by which
runtime a participant selects.

<a id="runtime-ownership--default-registry-and-implicit-construction"></a>
### Default registry and implicit construction

Recommend one designated default-runtime slot per loaded core registry instance,
not one runtime per factory and not a promise spanning independently loaded copies.
An application can install an explicitly created runtime as the default. Otherwise,
standard participant creation lazily establishes a default using configured runtime
options: hosted progress in an ordinary hosted build, manual progress in a manual
build. Unsupported configured modes fail construction, rather than silently choosing
another mode. Creating a guard-only WaitSet or querying the default never creates one.

Implicit creation uses dedicated runtime configuration/allocator ownership, not the
first factory's participant settings or borrowed allocator. Concurrent first creation
must publish one initialized default or fail cleanly; no participant becomes usable
before its required runtime driver is ready. Failure leaves no half-published runtime.
Manual mode remains manual: API helping advances permitted work, but applications
must drive progress between calls when required.

Lookup/retain, install/replace and stopped-state validation need one synchronized
registry protocol. Replacing a default changes selection for future operations only;
it neither stops nor migrates the previous runtime. Retain the new runtime before
publication and release the old registry retention afterwards. Distinguish an initially
unconfigured slot from one explicitly cleared/disabled or pointing to a stopped
runtime; do not resurrect a stopped runtime or undo an intentional disable through
an incidental participant creation. Explicitly disabled/default-stopped creation
fails visibly until reconfigured. WaitSets can still wait on guards/notifications.

The default registry is not an operational owner. It uses a safe weak/control-block
reference or equivalent registry-owned identity metadata, not an unprotected pointer.
Dropping the last operational owner can retire an implicit default automatically;
a later standard participant creation may establish a fresh runtime generation.
An explicitly installed runtime must remain operationally owned by the application,
participants or an explicitly configured factory. If that selection expires or is
explicitly stopped, creation fails until reconfigured; it does not silently fall back
to an unrelated implicit runtime. Explicit disable remains distinct from automatic
retirement of an implicit default. Core unload still requires all retained core work
and foreign binding callbacks to retire.

<a id="runtime-ownership--operational-ownership-versus-storage-retention"></a>
### Operational ownership versus storage retention

Use two distinct lifetime roles, regardless of their concrete reference-count layout:

| Holder | Role |
| --- | --- |
| Participant | Operational owner of its selected runtime |
| Factory following the default | Selection policy only; does not keep an idle runtime running |
| Factory explicitly selecting a runtime | Operational owner until selection is replaced or factory released |
| Application's explicit owning runtime handle | Operational owner, allowing deliberate resource reuse between participants |
| Default registry | Safe identity lookup, not operational ownership |
| WaitSet selection/invocation | Identity/storage retention and helping permission, not operational ownership |
| Queued work, I/O, timers, callbacks and cleanup | Storage/work retention through completion; cannot indefinitely keep the runtime operational |

Dropping one participant/factory releases only its own ownership. When the final
operational owner is released, atomically enter retirement, reject new operational
attachments to that generation, and initiate orderly shutdown automatically. The
application using standard DDS APIs needs no runtime-stop call or unused-runtime
probe. Recurring timers and worker self-references must not prevent this transition.

Participant logical deletion and release of its operational ownership must be ordered
with publication of all required teardown obligations. Existing callbacks, transport
completions and cleanup retain the runtime until safely retired. No cleanup may first
try to acquire a reference after the final protected owner has disappeared.

Concurrent participant creation and final-owner release share synchronization: either
creation secures operational ownership before retirement, or it cannot attach to that
generation. An implicit-default creation can select/create a fresh generation instead;
it must not revive the retiring one. Old and new storage may briefly coexist while
old cleanup drains. Configuration and transport binding still determine whether new
participant construction can actually succeed; this is not a guarantee that sockets
held by the retiring generation are immediately reusable.

<a id="runtime-ownership--automatic-shutdown-and-optional-lifecycle-controls"></a>
### Automatic shutdown and optional lifecycle controls

Automatic shutdown means initiating a retained shutdown protocol, not unconditionally
joining workers inside the last participant's destructor. It finishes or cancels work
according to existing operation contracts, stops recurrent scheduling, and drains
mandatory cleanup before reclaiming backend resources. A final release from a callback
or worker must not join itself or dispatch arbitrary nested application callbacks.

Hosted backends must provide progress for retirement after operational ownership ends.
Manual backends must complete retirement on an eligible outer driver/unwind path or
synchronously where safe; they cannot require the application to discover and invoke
a hidden runtime-shutdown API after ordinary DDS teardown. The exact final servicing
and foreign-hook integration is a required shutdown-interface decision, not proven
by reference counting. Allocators and foreign binding infrastructure must remain valid
through outstanding cleanup; object ownership cannot extend externally borrowed
resources by itself.

WaitSet wake/deadline/close remains independently usable even if its selected runtime
retires. Its retained identity is not permission to restart that runtime or switch to
a new default during an active invocation. A later default-policy wait resolves anew.

Explicit stop/completion controls, if provided, belong exclusively to zzdds interfaces
and are optional for standard applications. Their authority/preconditions remain a
separate API decision; the previously proposed mandatory manual-stop sequence is
withdrawn. Forced stop with live participants is not implicitly authorized by releasing
an ordinary handle. Unexpected backend failure still uses the accepted operation
failure mappings and cannot abandon already committed effects or retained cleanup.

<a id="runtime-resource-ownership"></a>
## Runtime handles and resource reclamation

<a id="runtime-resource-ownership--public-ownership-roles"></a>
### Public ownership roles

Expose operational ownership separately from observation, with these semantic roles
(names are provisional until IDL integration):

| Role | Keeps runtime operational? | Storage/lifetime contract |
| --- | --- | --- |
| RuntimeOwner | Yes | Explicit creation or successful ownership acquisition supplies one operational lease; releasing it can initiate retirement |
| RuntimeRef | No | Stable identity/state observation and eligible helping; safe control-block retention, never automatic revival |
| ResourceCompletion | No | Observes a sealed resource scope's final reclamation; must not itself pin that scope's allocator or runtime backend |

Default/participant runtime getters return RuntimeRef. WaitSet configuration retains
RuntimeRef even when the application supplies an owner: it does not copy operational
ownership. Explicit factory runtime selection acquires operational ownership as part
of successful configuration; failure leaves the prior selection unchanged. Participant
creation similarly acquires its operational lease atomically before publication.

Provide explicit try-acquire-owner from RuntimeRef, with failure once retirement has
begun. Acquisition and final-owner retirement share synchronization. A fresh implicit
default is a new identity, not resurrection through an old reference. A ref to a
stopped runtime remains safe to inspect until released. ReturnCode-style acquisition
uses ALREADY_DELETED for a safely recognized retiring/stopped lifetime; a constructor
uses its declared nil/failure convention. Invalid inputs retain normal validation.

Each explicit acquisition creates an owning lease. Binding aliases of that same lease
share its release state; copying a C++ shared_ptr or Java reference does not require a
new operational count on every language reference copy. Explicit additional acquisition
creates another lease. Releasing a lease is idempotent at the binding-owned lease
object, not permission to call an already-freed raw handle. C/Zig need explicit
release operations; managed bindings provide their deterministic cleanup conventions
with safe finalization fallback. Holding an owner while waiting for automatic runtime
retirement is a self-created dependency; release it and observe via RuntimeRef instead.

<a id="runtime-resource-ownership--three-resource-modes"></a>
### Three resource modes

1. **Library-owned default:** allocation/backend owners are retained internally;
   ordinary DDS teardown automatically releases them after work retirement.
2. **Retained custom owner:** construction accepts a versioned ownership anchor that
   keeps the allocator descriptor, allocator state and other required resources valid.
   Accepted runtime/entity/output users retain that anchor until their last use.
3. **Raw borrowed resource:** existing allocator pointer APIs remain borrowed. Their
   resources must outlive all associated reclamation, including deferred work. A new
   explicit tracked resource scope can provide a completion fence for safe local teardown.

`include/zzdds_c.h` currently documents borrowed allocator lifetime for factory,
WaitSet and GuardCondition construction. This proposal does not append fields to
ZidlAllocator, reinterpret those pointers as owned, or claim existing destroy functions
already provide an allocator fence. Migration must document/validate the existing
path and provide a versioned opt-in path before recommending stack/arena teardown
under deferred execution. Defaults must not require applications to use the extension.

Prefer a retained owner when practical. A foreign release hook or reference-counted
anchor cannot keep a stack arena alive unless the application actually supplies a
lifetime owner with that capability. No API can infer or extend arbitrary borrowed
memory lifetime. Anchor release is exactly once after its accepted users retire,
outside metadata locks, with the required binding environment.

<a id="runtime-resource-ownership--tracked-resource-scope-and-fence"></a>
### Tracked resource scope and fence

A resource scope accounts for every accepted user of the covered allocator/environment,
including entity storage, pending I/O, foreign hooks, returned allocations and shutdown
work. Its coverage must be explicit; a runtime-only fence is not a fence for all
factory/WaitSet allocations in the process. A user must not assume generated C output
buffers allocated from a separate allocator are covered by that scope.

Closing/sealing the scope prevents new independent resource users. Existing accepted
operations can finish required cleanup within their accounted lifetime; sealing does
not delete their DDS objects or abandon them. The ResourceCompletion becomes complete
only after all covered users and final hooks retire and no later callback can use the
resource. Returning a loan, destroying returned owned buffers, releasing operational
owners and deleting covered entities may be prerequisites; merely stopping workers
is insufficient. A copied raw pointer is not an accounted owner.

Keep completion observation metadata in separately owned storage (or caller storage
with a separately documented lifetime), so retaining the completion token cannot
prevent completion of the allocator it observes. Runtime identity/control-block
storage must likewise either be outside the resource being fenced or be included in
its remaining user count. Do not hide that choice behind the word observer.

Offer nonblocking readiness and a timed completion wait on the extension surface.
The latter uses a single deadline and permitted cleanup helping; TIMEOUT means the
resource is still in use, not permission to destroy it. Never recursively drain a
callback's own resource scope. Reject a proven self-dependency with ERROR; explicitly
integrated nonblocking loops continue servicing their registered retirement path.
A stalled foreign callback can delay completion indefinitely. This fence is optional
custom-resource management, not a mandatory runtime shutdown call for standard DDS.

Example borrowed-arena sequence: construct tracked scope and DDS objects; use them;
delete objects and release returned resources/owners; seal scope; observe/drive until
ResourceCompletion succeeds; destroy arena. The token remains independently valid.
Default library-owned resources and properly retained custom owners need no such
application wait merely to preserve memory safety.

<a id="runtime-bootstrap-contract"></a>
## Standalone runtime bootstrap contract

<a id="runtime-bootstrap-contract--configuration-and-build-capabilities"></a>
### Configuration and build capabilities

RuntimeConfig describes execution infrastructure, not participant discovery, transports,
QoS or security. Its minimum semantic settings are execution mode (build default,
hosted or manual), hosted worker policy, bounded runtime resource limits and scheduling
clock selection. Resource owners and external-loop hooks are construction inputs and
cannot be supplied as pointers in TOML. Exact field spellings and capacity defaults
remain implementation/configuration work.

Resolve build-default mode once at runtime creation. A hosted build normally selects
hosted progress; a manual-only build selects manual progress. Builds may support one
or both modes. Explicitly requesting an unavailable mode fails UNSUPPORTED; never
silently substitute one. A manual mode cannot accept a request to create hosted workers.
The runtime's effective mode, clock and limits stay fixed for its generation. Worker
placement and additional executor policies do not alter listener exclusion guarantees.

The implicit runtime uses dedicated core runtime defaults, independent of the first
factory's allocator and participant Config. Initially configure those defaults through
the core's startup configuration; live mutation of that settings object is not required.
The existing ability to select a different explicitly created runtime remains separate.
Backend/provider capability discovery must not instantiate an implicit runtime.

File-configurable settings describe supported behavior; selecting a backend does not
load arbitrary plugin code. Missing required capabilities, including timer, cancellation
and retirement progress, fail before the runtime becomes usable. Builds may remove
unused backends and optional DDS profiles; unsupported choices remain visible failures.

<a id="runtime-bootstrap-contract--bootstrap-validation-and-publication"></a>
### Bootstrap validation and publication

The bootstrap is scoped to one loaded core identity domain. A versioned entry-point
table/descriptor supplies size, supported ABI version and required capabilities.
Validate the known prefix before reading optional fields or invoking hooks. Reject
unknown required capabilities and incompatible versions. Only a version-defined
optional tail may be ignored; an arbitrary larger structure is not automatically
compatible. Reserved fields follow that version's documented initialization rules.

Standalone constructors borrow input descriptors during the call and retain/copy
everything needed beyond it. Copying a descriptor does not retain the allocator state,
provider code, JNI environment owner or event loop to which it points. Versioned
resource hooks establish those lifetimes explicitly. New descriptors do not extend
the existing ZidlAllocator or entity-box layout in place.

Each constructor requires initialized empty output slots. Stage validation, storage,
reference acquisitions, binding output preparation and required progress capacity
before publication. Failure leaves outputs empty and does not replace core defaults
or acquire an application-visible operational lease. Release temporary acquisitions
exactly once outside metadata locks. Creating a runtime does not install it as default.

If failure occurs after backend work starts, rollback still owes its cancellation and
cleanup. A failed constructor cannot leave an undisclosed obligation on the caller's
loop or borrowed resources. It must finish rollback before returning, or arrange an
independently retained cleanup executor and resources that need no further caller
service. For raw borrowed inputs, covered access must end before failure returns.
Do not start an external dependency that cannot satisfy this rule.

These are operation-specific constructor guarantees; zidl must not infer transactional
behavior from arbitrary integer return values. Ordinary reference getters return owned
observation references under the generic binding contract. New bootstrap methods use
the DDS result domain without casting generator/backend error enums into it.

| Condition | Standalone bootstrap result |
| --- | --- |
| Malformed values, inconsistent mode fields, nonempty constructor output | BAD_PARAMETER |
| Well-formed unavailable mode/capability or incompatible ABI version | UNSUPPORTED |
| Wrong core identity domain or incompatible live attachment state | PRECONDITION_NOT_MET |
| Safely recognized retiring/stopped runtime for a new attachment | ALREADY_DELETED |
| Allocation/reservation or checked retain capacity exhausted | OUT_OF_RESOURCES |
| Backend initialization/registration failure not covered above | ERROR |

This table concerns new bootstrap calls; standard DDS entity constructors keep their
existing nil failure convention. It is not a universal error mapping for all DDS APIs.
Foreign invalid pointers cannot be safely validated merely by reading a version field.

<a id="runtime-bootstrap-contract--resource-selection-and-reclamation"></a>
### Resource selection and reclamation

Resource selection explicitly chooses library-owned defaults, a retained custom owner,
or a tracked borrowed scope. Omitting resource options selects library-owned defaults;
an incomplete custom descriptor must not silently select the default allocator.
Validate allocation operations, alignment/capability requirements, owner hooks and
scope identity before allocation through the descriptor. Reject independent admission
to a sealed scope. Seal and accepted-user accounting share synchronization.

Retained ownership must cover descriptor state and executable hooks through their final
use. A tracked borrowed scope covers only the resources named in its contract; using
the same allocator address elsewhere does not enroll that use automatically. Existing
legacy borrowed-allocator APIs remain borrowed, with their explicit lifetime requirement.

Scope creation returns its scope and independent completion observation together or
neither. Allocate completion storage outside the observed resource. Observers and
provider hooks either use independent storage or remain explicitly accounted users;
no observer silently keeps its own reclamation condition unsatisfiable. Releasing the
last runtime lease is not equivalent to completing a resource scope.

<a id="runtime-bootstrap-contract--manual-construction-and-external-attachment"></a>
### Manual construction and external attachment

An ordinary manual runtime initially has the simple driver's shutdown servicing
contract. It can exist with its creator's RuntimeOwner before participants attach;
releasing that owner must still retire it safely. A ManualDriver retains progress
resources, not an operational lease. Its existence does not change that contract.

Initial external-loop attachment requires a manual runtime with no
admitted participants, transport I/O, outstanding outer drive or earlier external
registration. Synchronize attachment against participant admission and driving:
exactly one wins; a losing attachment fails with PRECONDITION_NOT_MET. Unrelated
observation references do not prevent attachment. No implicit runtime/default lookup
is performed by this operation.

Prepare and retain the adapter, establish its notification path and reserve mandatory
cleanup capacity before atomically installing it as the progress owner. Once installed,
participant admission may rely on the loop's declared servicing obligation. An owner
release racing attachment either occurs first and prevents attachment, or occurs after
handoff and notifies the now-responsible loop. Failure before handoff preserves the
simple manual contract and leaves no registered foreign wake callback behind.

While attached, outer work is serviced through ExternalDriver; ordinary ManualDriver
drive calls cannot bypass its retirement budget/affinity contract. Internal helping
continues under its existing restrictions. The adapter's wake hook only signals;
it must not call drive or invoke DDS listeners synchronously.

There is no live executor replacement in v1. Successful explicit detach requires
backend stop, no active service/notification invocation, and quiesced wake registration.
Detach first prevents new hook claims and then completes their drain; it cannot report
success while foreign hook state remains in use. A call that would wait for its own
hook/service frame fails PRECONDITION_NOT_MET. Failure preserves the registration and
its servicing obligation. Repeated detach on a valid detached wrapper is harmless.

Dropping an ExternalDriver wrapper while attached does not detach the loop. The runtime
retains the registered adapter and its resource anchor until it can quiesce safely;
an application using borrowed loop state must keep that state alive and keep servicing.
This obligation is explicit only for external-loop integration. Ordinary hosted/simple
manual applications still require no extra runtime shutdown call.

<a id="runtime-bootstrap-contract--clock-and-wake-compatibility"></a>
### Clock and wake compatibility

Execution waiting needs a monotonic scheduling clock with documented units, epoch,
resolution, suspend behavior and overflow bounds. DDS source timestamps and any
participant-specific protocol clock are distinct concepts; equal integer timestamps
or matching clock names do not establish compatibility.

An initial external adapter either uses the runtime's scheduling clock
directly or provides an explicitly validated deadline conversion. Its prepare-to-wait
result pairs the wake generation with an optional absolute deadline in that documented
domain. No deadline is distinct from a deadline due now. Never interpret a runtime
timestamp as a host wall-clock timestamp or a platform descriptor without conversion.

Conversion must not schedule later than the runtime deadline solely due to rounding;
early wakes are allowed and recheck the predicate. Saturation/overflow must not turn
a finite deadline into infinity. A relative wait adapter recomputes the remaining
duration against the original deadline immediately before waiting, including time
spent by the external loop since prepare-to-wait. Spurious wakes never restart it.

Timer insertion, an earlier deadline and readiness after arming notify the registered
loop. Wake acknowledgment cannot consume a newer generation. Clock conversion alone
does not replace this handshake. Small wrapping hardware counters need an adapter with
a documented unambiguous deadline horizon or extended counter; do not assume MCU ticks
are already a wide absolute clock.

Existing src/util/clock_registry.zig permits realtime/custom clocks, stores borrowed
Clock values and falls back to default on unknown names. Do not reuse that fallback
for an explicitly selected runtime scheduling clock. Preserve participant clock
semantics only through a compatible timer adapter. Virtual or externally advanced
clocks additionally need advance/change notification; do not interpret their deadlines
as host sleep intervals. Supporting every existing custom clock in every backend is
not an initial requirement, but unsupported combinations must fail visibly. This is
a migration requirement, not a claim that today's registry supplies these guarantees.

<a id="runtime-bootstrap-contract--finite-completion-gates"></a>
### Finite completion gates

The attachment restriction, clock-domain compatibility and bootstrap failure/publication
rules above are accepted. Concrete
descriptor layouts, symbol names, platform timer formats and measured capacity values
are required before publishing the corresponding ABI, not before broker design work.

Implementation acceptance must cover: unsupported/malformed descriptors; failure after
each acquired resource; borrowed-input rollback; attachment versus participant admission
and final-owner release; wake versus detach; earlier timer during arm; distinct clock
epochs; conversion overflow; and custom-clock advance where supported. Run these against
real adapters and bindings. Existing scalar models are supporting evidence only; this
review introduces no new prototype requirement.

<a id="runtime-retirement"></a>
## Runtime retirement progress and backend shutdown

<a id="runtime-retirement--state-and-retained-progress-obligation"></a>
### State and retained progress obligation

Use RUNNING -> RETIRING -> BACKEND_STOPPED -> RECLAIMED. The final operational-owner
release atomically enters RETIRING and publishes a pre-reserved retirement obligation.
No new participant can attach to that generation. Retained internal references are
not operational owners and cannot prevent entry into RETIRING.

RETIRING closes ordinary work admission and disables recurrence, while preserving
completion, cancellation, output-result delivery and release-only cleanup admission.
Every accepted operation either completes its committed effect or resolves its
uncommitted state according to the accepted operation contract. Backend stop requires
all users of backend resources to retire or transfer to independently owned resources.
RECLAIMED additionally requires all residual identity/storage references to retire.
An idle WaitSet can retain a stopped runtime identity without retaining sockets or
workers indefinitely.

The retirement obligation has a concrete owner at all times: the active outer driver,
a surviving hosted shutdown executor, or an explicitly registered external-loop
completion path. Transfer ownership before the previous progress source can exit.
Do not enqueue cleanup onto an ordinary ready queue and then terminate its only driver.
Retirement publication must not allocate; duplicate final-release/cancel wakes are
idempotent and carry runtime/request generations.

<a id="runtime-retirement--final-release-inside-a-callback"></a>
### Final release inside a callback

The callback may delete the final participant. Its deletion publishes required local
teardown, releases operational ownership and returns under the accepted callback
non-draining rule. Runtime storage and callback/binding resources remain retained.
Do not recurse into a shutdown pump from inside the callback or its foreign conversion.

When that invocation and its cleanup unwind, the surrounding driver/API frame observes
the retirement obligation and enters shutdown servicing with no listener rights or
endpoint/coordinator locks held. It can service internal completions and required
release hooks under their documented contracts, but cannot start new automatic
application callbacks. Already claimed invocations on other executors must unwind;
retirement neither destroys their storage nor pretends they have finished.

If multiple runtimes are active on an explicit nested call chain, each retirement
obligation is handed to an executor authorized for that runtime. Domain-wide listener
identity does not authorize arbitrary foreign-runtime driving during unwind.

<a id="runtime-retirement--hosted-and-manual-driver-obligations"></a>
### Hosted and manual driver obligations

Hosted mode retains a shutdown executor until backend teardown completes. Workers
cannot join themselves. A backend can use a surviving coordinator, detachable worker
exit accounting or another explicit mechanism, but it must identify the last thread's
reclamation owner. No unconditional process-global reaper thread is mandated.

For the standard/manual synchronous path, propose a teardown tail at the outermost
eligible API/driver boundary. If final-owner release occurs outside an active driver,
that releasing path becomes the shutdown driver where the backend permits it. If it
occurs inside a callback, the tail runs after callback/conversion unwind. Standard DDS
applications do not have to call a new runtime-shutdown operation.

A teardown tail may exceed an ordinary work-turn budget: cancellation/drain is not a
claim of bounded destructor latency. It must not wait for remote ACKs, peer discovery,
a graceful TCP peer response or a remote lease to expire. Local outstanding callbacks,
foreign cleanup hooks and backend cancellation completions can still delay completion.
Do not promise both bounded synchronous teardown and complete reclamation without an
external progress source. No busy-spin is allowed while waiting for local completion.

For an explicitly integrated external-loop/nonblocking driver, preserve its budget
and transfer retirement to the already registered loop wake/completion contract.
The application must service that loop until its outstanding-work indication clears,
as part of its existing driver ownership contract; dropping the final participant
does not make outstanding I/O disappear. This requirement is explicit at runtime/driver
construction, not a hidden shutdown API discovered after teardown. Such a backend
cannot be selected as the implicit standard synchronous path unless it also supplies
a valid automatic teardown tail. Interrupt-only or thread-affine entry must defer to
its registered executor rather than running foreign cleanup on the interrupt stack.

<a id="runtime-retirement--transport-and-timer-shutdown-boundary"></a>
### Transport and timer shutdown boundary

* Disable timer rearm and recurring discovery/heartbeat generation under the same
  state transition used to admit them. Cancel registrations; retain their targets
  until cancellation completion or in-flight callback retirement. A stale fire can
  retire its own reference, never revive recurrence or act on a new generation.
* Stop admitting ordinary receive work, unregister each runtime's dispatch entries,
  and retain in-flight buffers/targets through completion. Shared resources close
  only after their actual owners release them; retiring one runtime cannot close a
  socket still used by another live owner.
* For queued output, distinguish local committed DDS state from transmission success.
  Cancel unsent work or finish locally as its operation contract requires, reporting
  asynchronous failure through the selected output interface. Never retroactively
  turn a committed write into a precommit failure. Disposal/discovery announcements
  during teardown are best-effort with respect to reaching the peer; no remote wait
  is introduced merely to reclaim local transport state.
* Keep wake/deadline and cancellation-completion service alive until no shutdown
  operation needs it. WaitSet-owned guard/deadline service has independent lifetime.
  Destroying sockets/timers is not sufficient evidence that queued completions can
  no longer run. A backend must provide a cancellation/quiescence contract.
* Mandatory foreign cleanup executes outside metadata locks, with a valid binding
  environment. Allocator/JVM/plugin ownership must outlive it. Backend failure may
  change operation outcomes but does not waive memory-safety obligations.

Concrete ingress/output queue limits, admission failure/backpressure mapping and
channel ownership follow the bootstrap and transport sections below.

<a id="manual-runtime-driver"></a>
## Manual runtime driving and external-loop integration

<a id="manual-runtime-driver--two-public-layers-one-internal-engine"></a>
### Two public layers, one internal engine

A simple driver supports an application's ordinary main-thread pump. An external-loop
adapter integrates the same engine with an existing reactor, embedded scheduler or
platform wait primitive. Neither requires Zig language async support. Backend support
and the platform's wake/timer facilities determine the available integration methods.
All new controls live in zzdds.idl or its versioned platform bootstrap, not dcps.idl.

A driver retains the runtime identity and progress resources, not an operational owner
lease. Holding the driver must not prevent final-participant retirement. RuntimeOwner
remains the explicit way to keep a runtime operational between participant lifetimes.
A driver bound to one generation never silently follows default-runtime replacement.

Initially allow one outer manual driver at a time for a runtime. Reject concurrent or
recursive outer drive entry with PRECONDITION_NOT_MET rather than blocking behind the
caller it might depend on. This does not restrict hosted worker counts or ordinary
API callers; internal helping continues under the normal context admission rules.
A thread-affine backend additionally validates its designated driving thread. Do not
silently steal a hosted backend into manual mode.

<a id="manual-runtime-driver--simple-driver-operation"></a>
### Simple driver operation

Proposed semantic operation: drive(budget, max_wait) returns a DDS status plus a
small result structure. Concrete spelling and duration representation await IDL review.

* Require a positive finite work-turn budget. A turn can include an admitted listener
  invocation; the library cannot preempt application code. The budget bounds scheduling
  turns, not callback duration, bytes processed or hard real-time latency.
* Service runnable work immediately. If none exists, the operation may wait up to
  max_wait using the backend's next timer and wake mechanism. Once work is performed,
  do not repeatedly wait to fill the budget. Zero max_wait is a nonblocking poll.
* Establish one absolute waiting deadline at entry. Spurious wakes recheck readiness
  without restarting it. Waiting-budget expiry is normal: return OK with zero work,
  not a DDS data-operation TIMEOUT. Backend failure remains ERROR.
* Report work performed, whether another immediate turn is advisable, and runtime
  retirement/backend state separately. Empty readiness is a snapshot, not a promise
  that no producer can enqueue after return. A running idle runtime is not stopped.
* An outer drive can dispatch eligible application listeners. Blocking DDS operations
  called from those listeners use internal helping only; they cannot recurse into
  outer drive to dispatch automatic callbacks. Release hooks/foreign conversion keep
  their existing reentrancy rules and are not arbitrary listener-dispatch permission.

After final-owner release, service the accepted standard teardown tail at the eligible
outer boundary, even if it exceeds the ordinary turn budget or max_wait. Never wait
for remote ACKs to retire the backend. Report backend-stopped normally on subsequent
safe observations; the driver reference does not revive it. ResourceCompletion remains
the separate test for reclamation of a custom resource scope.

<a id="manual-runtime-driver--external-loop-adapter"></a>
### External-loop adapter

Construction registers the loop's wake/completion path before participants or I/O can
rely on it. Reject unsupported integrations before publication. Platform handles and
wake hooks use a versioned bridge; do not put an assumed POSIX file descriptor in the
portable DDS IDL. A wake hook only signals the loop, never drives DDS inline, and its
lifetime/environment must cover all in-flight notifications.

The adapter provides bounded nonblocking service plus a prepare-to-wait handshake.
The latter atomically arms notification and snapshots immediate work, earliest timer
and a generation/sequence token. The loop then waits on its own sources together with
that notification/deadline. If work became ready before arming, report immediate work;
if it arrives after arming, retain a wake until the loop services or rechecks it.
A naked has_work followed by sleeping is not sufficient.

Consuming a wake must not clear a newer wake. Rearm/recheck under the same notification
protocol, tolerating coalescing, duplicate and stale notifications. Timer insertion,
earlier-deadline changes, cancellation completion, released callback rights, and
retirement all participate. Internal helping that creates loop work also signals this
path. Exact atomic operations are backend integration work; these are required outcomes.

A blocked listener group alone is not immediately runnable work. Its release must
signal the waiting runtime; repeatedly reporting it ready would busy-spin. Similarly,
pending local cancellation is outstanding retirement work, not necessarily runnable
until its completion arrives.

External service preserves its turn budget during retirement and returns control to
the loop. Report retirement_pending independently of immediate work and retain the
wake source until backend cleanup no longer needs the loop. The application must
continue its already-declared servicing obligation until completion; idle is not
permission to detach. Detach during live dependence fails PRECONDITION_NOT_MET unless
a replacement executor has atomically accepted the obligation. Dropping a wrapper
cannot silently unregister the only completion path. Define explicit adapter detach
and foreign-resource lifetime in the bootstrap contract.

This is the accepted external-loop ownership obligation, not a mandatory shutdown
call for ordinary DDS applications. A platform integration unable to honor it must
use the simple driver's teardown contract or a hosted backend instead.

<a id="manual-runtime-driver--result-distinctions-and-validation"></a>
### Result distinctions and validation

Keep these concepts separate in the eventual result types:

| Observation | Meaning |
| --- | --- |
| Work performed | This invocation executed one or more permitted turns |
| Immediate work | Another turn may make progress without awaiting an external event |
| Next deadline | Loop must arrange a wake no later than this backend timer deadline |
| Retirement pending | Loop still owes cancellation/completion/cleanup service |
| Backend stopped | This runtime generation no longer needs backend progress |
| Resource scope complete | Separately fenced allocator/environment has no covered users |

A backend error does not clear outstanding cleanup obligations. Do not infer that an
ERROR result permits adapter or allocator destruction. Avoid a single enum that loses
simultaneous work-performed and retirement-pending information.

Required integration fixtures: enqueue between arm and sleep; earlier timer insertion;
wake during acknowledgment; final participant deleted inside a listener; callback
blocked on protocol progress; cross-runtime group release; late cancellation after an
idle result; attempted recursive/concurrent driving; detach before retirement finishes.
Existing scalar retirement/wakeup models support portions of this contract but do not
validate a real platform adapter. No new model is required before reviewing this API.

<a id="manual-runtime-driver--accepted-bootstrap-integration--2026-09-17"></a>
### bootstrap integration — 2026-09-17

Single outer driving and the two progress contracts are accepted. The
[runtime bootstrap contract](runtime.md#runtime-bootstrap-contract) fixes initial external
attachment before participants/I/O, atomic progress handoff, clock compatibility and
no live executor replacement in v1. Its narrower detach rule supersedes the possible
replacement-executor exception above. Concrete platform ABI and backend fixtures remain
implementation gates. Owner release and automatic retirement suffice for ordinary use.

<a id="transport-runtime-contract"></a>
## Transport/runtime ownership and backpressure

<a id="transport-runtime-contract--ingress"></a>
### Ingress

A channel owns socket/connection state, framing and I/O buffers. Delivery to an endpoint
is an explicit ownership decision: process inline under eligible bounded admission,
retain a buffer lease, or copy into bounded owned storage before returning. A borrowed
receive slice must never escape its callback lifetime. Retain the dispatch registration
and destination lifetime before enqueueing; a raw context pointer is not that retention.

Account both bytes and records, including partial frames/fragments and destination
fanout references. A retained multicast buffer may be shared immutably; each recipient
still needs bounded dispatch bookkeeping. Apply configured frame/fragment size limits
before allocating from untrusted lengths. Transport acceptance is not validated RTPS
receipt or DDS admission; follow the separate reception/admission roadmap contract.

On exhaustion:

* UDP may drop an unadmitted datagram and record an internal drop reason. Do not
  update sequence/ACK or historical-completion state for work never accepted by the
  protocol. Reliable recovery may occur through its normal protocol; best-effort
  delivery has no added guarantee. This is not automatically a DDS SAMPLE_LOST event.
* TCP normally pauses reading at a recoverable framing boundary, retaining bounded
  partial-frame state. Never discard arbitrary bytes and continue parsing as though
  framing were intact. An oversized/invalid frame or inability to preserve framing
  follows the channel's explicit failure/close policy. Shared-stream head-of-line
  blocking remains real; control queue reservations cannot bypass bytes on the wire.
* Saturation does not block an interrupt or I/O callback waiting for endpoint rights.
  It must not wait for application callbacks to release space on that same stack.

One slow peer/endpoint must not consume every configured ingress resource: expose
per-channel/peer limits plus aggregate bounds. Exact defaults are measurement and
configuration work, not selected numbers in this specification.

<a id="transport-runtime-contract--output-submission-and-completion"></a>
### Output submission and completion

Use these conceptual outcomes, with an explicit request/buffer lifetime:

| Outcome | Ownership and meaning |
| --- | --- |
| Completed locally | Adapter has finished accessing the submitted bytes; not proof of peer receipt |
| Accepted pending | Ownership/lease transferred until exactly one terminal completion |
| Would block / not accepted | No ownership transfer; producer retains data and may register a retry |
| Rejected / terminal failure | No transfer, or a terminal completion for previously accepted work; the distinction is explicit |

The producer registers readiness and releases its context instead of retaining
execution rights through output congestion. Check/register shares synchronization
with capacity release, and retries keep the original applicable deadline. A completed
send, failure or cancellation releases its lease exactly once. Cancellation request
alone does not authorize buffer reuse. An inline completion is permitted if its
ownership handoff is unambiguous and does not invoke application code under locks.

For TCP partial output, preserve the frame prefix/payload cursor and immutable backing
storage until completion or connection failure. Do not interleave frames on a stream,
report an unaccepted request after sending a prefix, or transparently replay a partially
sent frame on a fresh connection without an explicit higher-level retry contract.
UDP submission preserves datagram boundaries. Shared buffers require independently
accounted destination submissions; partial fanout is not all-destinations success.

Output queue acceptance, local transmission completion, DDS write commitment and
remote ACK are separate events. A committed reliable change stays repairable according
to its history/QoS policy even when a send attempt fails; the output lease must protect
its bytes against history reclamation. Best-effort postcommit output failure has no
invented retransmission guarantee. Async failures feed the owning protocol/channel
state and diagnostics; they do not retroactively change a returned write result.

<a id="transport-runtime-contract--capacity-needed-for-progress"></a>
### Capacity needed for progress

Recommend bounded ordinary ingress/output capacity, plus separately reserved internal
completion/cancellation/retirement records. Reserve each accepted operation's terminal
record before acceptance; rejected submissions need no later completion record.
A full data queue must not prevent returning buffers, publishing an accepted send's
completion, cancelling a timer or handing off retirement. These are logical capacity
classes, not a mandate for one physical queue or worker per class.

Coalescible protocol-ready hints use pre-reserved per-owner state: repeated ACK/repair
or discovery readiness need not allocate a new task each time. Raw control packets
are still untrusted input requiring bounded parsing and admission; they do not receive
unlimited exemption from capacity limits. Validated control work can receive reserved
capacity/bounded priority, with fairness so continuous control traffic cannot starve
ordinary work. Mandatory release work must not depend on allocating another data item.

This prevents local capacity cycles, not arbitrary network or application deadlock.
TCP data can hide a needed control frame behind it, and a full reader history can
require application consumption. Protocol/channel topology and supported runtime
helping must account for those limits. Do not promise that QoS or priority eliminates
all head-of-line blocking.

<a id="transport-runtime-contract--close-and-retirement"></a>
### Close and retirement

Unregister logically prevents new dispatch claims. Already claimed dispatch and I/O
completion retains registration/channel/target lifetimes until it retires. Separate
logical unregister from an optional external drain; the current blocking unlisten
must not be called in a context where it waits for its own callback. Exact generation
checks cover stale dispatch, ready notifications and queued completions.

Channel close rejects new submissions, resolves accepted work and drains backend
users before resource destruction. Runtime retirement preserves completion/cancel
service even when ordinary queues are full; it must not wait for remote peers solely
to reclaim local state. Shared transport resources close only when their actual owners
release them. A retained stopped runtime identity is not a live channel owner.

<a id="transport-runtime-contract--channel-integration-after-main-refresh"></a>
### Channel integration after main refresh

Preserve received-channel routing from the implemented Channel/sendOnChannel API.
Retained queued work must also retain or safely resolve the owning transport lifetime;
a copied pointer token plus generation is not a resource lease. Replace unbounded
dead-channel retention with bounded safe identity reclamation for the evented backend.
Correlate broadcast close notifications against known channel generations and retain
reserved completion/cleanup capacity; never treat every notification as session loss.
The existing API does not yet supply asynchronous send ownership or completion.
