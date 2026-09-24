# WaitSet close and runtime helping

Status: finalized behavioral/configuration contract, 2026-09-14, following user
acceptance of per-invocation resolution and authorization to finalize. Builds on
accepted WaitSet admission, level observation and temporary result ownership.
Generated IDL integration and production validation remain implementation work.

## Explicit close, separate destruction

Provide an idempotent, permanent, non-draining close operation on the zzdds WaitSet
extension interface. The standard WaitSet interface remains unchanged. A safely live
wrapper/handle can call close repeatedly and receive OK. Close is not a reset or a
one-shot interruption; a GuardCondition remains the standard reusable stop signal.

At the logical close boundary:

* Reject subsequent wait/attach/get_conditions/detach operations with ALREADY_DELETED
  on safely recognized closed lifetimes. Repeated close remains OK.
* Resolve an unresolved admitted wait as ALREADY_DELETED, subject to the accepted
  deadline arbitration. A previously committed result, including OK, is unchanged.
* Withdraw attachment eligibility and arrange notifier deregistration and ownership
  release. Closing the WaitSet does not delete its attached conditions.
* Preserve selected-result leases and retained in-flight operations until their
  conversions/cleanup finish. Logical close never waits for an application callback,
  conversion, or ownership-release hook to return.

Make logical close available without requiring destruction of the language object.
An application can close from a management thread, let its waiting thread return,
then destroy its wrapper. Destruction internally requests the same close transition
and relinquishes ownership; actual reclamation waits for outstanding internal leases.
This is not permission to destroy a C++ object concurrently with unprotected method
entry, or to invoke a freed raw handle. Valid caller ownership is required at entry.

A close ReturnCode reports logical closure, not that every release hook has run.
Final hooks run outside metadata locks and may require the configured cleanup executor
or a valid JNI environment. Mandatory cleanup capacity must be retained before close;
close cannot depend on allocating a new task after marking the object closed. The
runtime must drain accepted cleanup before destroying its backend resources. Optional
external quiescence APIs are not needed for this initial close operation.

Alternative: close waits until the active invocation and hooks finish. That makes
some external cleanup convenient, but risks self-wait during reentrant conversion or
hook execution and needs the callback-context distinctions used by entity deletion.
Use non-draining close consistently; normal wrapper/thread ownership supplies
the application's destruction ordering.

## Stable helping policy

A WaitSet needs a wake/deadline mechanism, but is not owned by a participant and need
not create a participant, socket or worker. Provide these construction policies:

| Policy | Permission granted to a waiting caller |
| --- | --- |
| Default shared runtime | Bounded internal helping on the configured default shared runtime only |
| Explicit runtime set | Bounded internal helping on the explicitly retained, finite selected runtime set |
| No helping | Observe conditions and block on notifications/deadline; runtime progress is supplied elsewhere |

Use Default shared runtime for standard construction. Resolve its runtime identity
at each successful wait admission, using a synchronized configuration snapshot, and
retain that identity until the invocation finishes output conversion or unwind.
Attachment order and configuration changes during that invocation do not retarget it.
If no default runtime exists, use no helping for that invocation, without creating
one merely for a guard-only wait. A later invocation can discover a subsequently
configured default. This per-invocation resolution is accepted and replaces the
earlier first-wait binding proposal.

The default policy is fixed on the WaitSet; its resolved runtime is fixed on the
invocation. Explicit-runtime and no-helping policies do not follow default changes.
Resolving and retaining the selected runtime must be safe against concurrent stop
or replacement; a pointer lookup followed by an unprotected retain is insufficient.
The runtime configuration specification must define the default explicitly, rather
than letting incidental factory creation or condition attachment order choose it.

Explicit configuration is construction-time, belongs in zzdds.idl, and does not
require corresponding methods on dcps.idl. Preserve ordinary factory-less language
construction through the bootstrap already used for WaitSet. A runtime reference
retains identity/storage; it does not grant ownership to shut down that runtime.
Do not select the first attached condition's runtime or enlist every runtime in the
process. No-helping remains useful for externally integrated loops and thread-affine
runtime backends. An explicit set must be validated for the selected build/backend's
helping capabilities at construction; unsupported configurations fail visibly.

Hosted default applications can rely on background progress. In a manual build,
waiting can drive permitted internal protocol/timer/condition work with bounded fair
turns, but cannot automatically dispatch nested application listeners. Callback
callers retain their accepted exclusion rights. Participants using other runtimes
still supply notifications, but require their own driver unless explicitly enlisted.

A finite set is sufficient for the initial policy; dynamic mutation during an active
wait is unnecessary. All helping shares the wait's absolute deadline and normal
runtime admission/budget rules. There is no mandatory thread hop for an already true
condition. The wait backend must remain usable for GuardCondition and timeout even
without any runtime configured.

## Runtime stop is not WaitSet close

Stopping one selected runtime removes its ability to make protocol progress; it does
not automatically close the WaitSet or make the whole wait fail. Another condition,
a GuardCondition, or the deadline can still resolve it. Do not implicitly substitute
a replacement runtime with the same configuration or address: retained identities
must distinguish lifetimes. A stopped selection remains inert for the rest of its
invocation. The next default-policy invocation resolves the then-current default
again. An explicitly selected stopped runtime is not automatically replaced; changing
that construction-time selection requires another WaitSet.

Only an irrecoverable failure of the WaitSet's own wake/deadline mechanism warrants
ERROR for its unresolved wait. Normal manual idleness, absence of a configured runtime
and runtime stop are not that failure. Close must have a retained path to wake a
waiter independently of the stopped runtime's ordinary work queue.

## Existing infrastructure and remaining validation

`src/c_abi/extensions.zig:542` currently constructs a standalone WaitSet with an
optional allocator; `src/dcps/waitset.zig` owns its condition variable and teardown.
`src/config/process.zig` installs configuration lazily for the first factory, not a
WaitSet runtime selection. Neither the runtime policies above nor an explicit public
close operation are claimed implemented. Do not equate process configuration with an
existing runtime registry or change its freeze boundary as an incidental side effect.

Close and helping policy decisions are settled. Validate progress after a selected
runtime stops and safe default lookup/retention during replacement, keeping backend
wake lifetime separate from runtime lifetime. Existing wakeup/ownership models cover
abstract close versus result conversion; they do not establish concrete backend
shutdown or the full composed implementation. Runtime construction/IDL integration
must reconcile this contract with the shared runtime specification; this document
does not invent a production runtime singleton.

## Configuration and extension surface

The implementation-facing surface is a zzdds WaitSet extension derived from
DDS::WaitSet with `DDS::ReturnCode_t close()`, and a construction configuration with
these fields:

| Field | Contract |
| --- | --- |
| helping_policy | DEFAULT_SHARED_RUNTIME (default), EXPLICIT_RUNTIMES, or NO_HELPING |
| runtimes | A finite sequence of retained runtime references; used only by EXPLICIT_RUNTIMES |

No mutable setter is provided. Existing standard construction uses the default
configuration; configured construction is an additional standalone bootstrap, not
a DomainParticipant factory method. Standard and extension views must preserve the
same WaitSet identity. The exact runtime-reference IDL type and generated bootstrap
spelling are tied to the forthcoming runtime interface; do not introduce a second
runtime handle system just for WaitSet. No additions go in dcps.idl.

Validate configuration before publishing a WaitSet:

* Reject unknown policy values, nil runtime entries, an empty explicit set, or a
  nonempty runtimes field with a non-explicit policy as BAD_PARAMETER in the
  construction diagnostic. Deduplicate valid explicit entries by runtime lifetime
  identity; retain each once. NO_HELPING is the unambiguous way to select no runtimes.
* Reject a policy the selected build/backend cannot support as UNSUPPORTED; never
  silently replace explicit helping with no helping. Resource exhaustion is
  OUT_OF_RESOURCES. Construction failure publishes no partially initialized object
  and releases any acquired references. Pointer-returning bootstrap APIs use their
  defined nil/failure convention; do not pretend they return a DDS ReturnCode_t.
* A safely retained stopped runtime is a valid inert selection. It cannot be
  restarted or replaced implicitly through this reference. Actual eligibility to
  execute work also obeys runtime caller-affinity and admission rules; explicit
  selection does not authorize bypassing those rules.

Each admitted wait snapshots and retains its permitted runtime set as part of
request setup. Setup time is included in its one absolute deadline. A rejected
second waiter does not change configuration or acquire an active helping scope.
WaitSet close during setup competes through the same lifecycle request protocol;
there must be no retained-runtime leak or late admission after close.

Only the configured default identity is resolved for DEFAULT_SHARED_RUNTIME; it
does not enumerate active runtimes. The runtime configuration layer must provide a
synchronized identity lookup/retain operation and a defined absence result. Default
replacement may affect a later wait, never a currently admitted one. A guard-only
wait must work even if no process/factory runtime configuration has been initialized.

Close cleanup must remain serviceable after every selected runtime stops. A
standalone WaitSet needs its own retained cleanup/wakeup service, or an equivalent
backend guarantee, rather than depending on a selected runtime queue that can reject
work. In manual builds, physical cleanup can require subsequent backend servicing;
close still completes logically. Allocators and foreign binding infrastructure must
outlive their outstanding cleanup obligations, not merely the call to close.
