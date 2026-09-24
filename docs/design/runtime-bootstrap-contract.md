# Standalone runtime bootstrap contract

Status: portable bootstrap behavior accepted, 2026-09-17. No production API or ABI
changes. Initial external attachment restrictions, no live executor replacement, clock
compatibility and construction/resource failure rules are part of the v1 baseline.
Complements concurrency-api-draft.md, runtime-resource-ownership.md and
manual-runtime-driver.md; those documents retain their established lifetime rules.

## Configuration and build capabilities

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

## Bootstrap validation and publication

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

## Resource selection and reclamation

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

## Manual construction and external attachment

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

## Clock and wake compatibility

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

## Finite completion gates

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
