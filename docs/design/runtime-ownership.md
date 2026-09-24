# Shared runtime ownership and construction

Status: automatic operational ownership direction accepted, 2026-09-15.
This supersedes the initial requirement for application-requested runtime shutdown.
No runtime implementation or generated API is introduced. WaitSet helping, callback identity and operation policies remain
as accepted in the consolidated concurrency contract.

## Separate DDS containment from execution resources

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

## Selected selection hierarchy

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

## Default registry and implicit construction

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

## Operational ownership versus storage retention

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

## Automatic shutdown and optional lifecycle controls

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

## Next interface work

The [transport/runtime contract](transport-runtime-contract.md) records accepted
buffer submission/retention, bounded data capacity and reserved release paths. Its
saturation model passes 164 states/338 transitions; it is not a competing channel
implementation. Next is the staged migration/validation plan and integration review.

The [retirement progress proposal](runtime-retirement.md) specifies the proposed
outer-driver teardown tail and explicit external-loop handoff. Its bounded model
passes 236 scenario-states and 596 transitions; concrete backend integration remains.

The operational-ownership direction, retirement handoff and transport direction are
accepted. Next address the [final review](concurrency-final-review.md), especially
borrowed-resource reclamation and public owning-versus-observing runtime references.
These are API/lifetime refinements, not a request to reopen automatic shutdown or
implement another scheduler prototype.
