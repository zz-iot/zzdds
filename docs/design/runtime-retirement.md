# Runtime retirement progress and backend shutdown

Status: selected retirement direction, bounded handoff model checked, 2026-09-15.
Automatic final-operational-owner retirement and the teardown-tail/external-loop
direction are the design baseline; concrete backend integration remains unimplemented.

## State and retained progress obligation

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

## Final release inside a callback

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

## Hosted and manual driver obligations

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

## Transport and timer shutdown boundary

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
channel ownership are the next interface section, not frozen by these shutdown rules.

## Decision and validation boundary

Recommend the teardown-tail default plus explicit external-loop progress contract.
The main tradeoff is that ordinary synchronous final teardown can take longer than a
normal pump budget, while explicitly nonblocking integration preserves its budget by
retaining an externally serviced completion obligation. Both keep standard DDS usage
free of a mandatory runtime-stop call.

Validate final release during callback/conversion, timer rearm versus retirement,
late transport completion, final worker exit, default replacement, cancellation
failure and stalled foreign hooks. A bounded model should check ownership handoff
and no rearm after retirement; production fixtures must verify actual backend cancel,
thread exit and binding release. No unconditional progress is promised if an application
callback never returns or an explicitly owned external event loop is abandoned.

## Bounded handoff validation

Run `python3 docs/design/runtime_retirement_model.py`. The outer-driver scenario
passes 106 states/266 transitions; the registered external-executor scenario passes
130 states/330 transitions. Total: 236 scenario-states and 596 transitions. Six
outcome witnesses are reachable, and every state has a path to storage reclamation.
This is existential reachability under eventual event servicing, not a fairness or
bounded-shutdown-latency guarantee.

The model starts with a callback, one operational owner, one timer, one pending I/O
and an independent identity observer. It separates final-owner release, callback
unwind, progress handoff, timer cancellation/fire, I/O cancellation/completion,
backend stop, final executor exit and storage reclamation. Five negative controls
expose lost handoff, rearm after retirement, prematurely releasing I/O completion
retention on cancellation request, early backend stop and early executor exit.
Cancellation-reference loss is checked directly as a lifetime invariant; the model
does not execute an actual late operating-system callback through reclaimed memory.

No policy change was needed. A stopped identity observer can keep runtime storage
alive without keeping the backend operational. Pending cancellation remains distinct
from cancellation completion. The external mode assumes its registered executor is
serviced; abandoning that loop is outside its progress guarantee.

This one-owner/one-timer/one-I/O abstraction does not validate concrete atomics,
multiple workers or self-join handling, finite queues, binding hooks, default-runtime
replacement, participant creation races, shared sockets, backend failures, or actual
manual/hosted driver implementations. In particular, an atomic callback-unwind handoff
is a required implementation property, not established by the model itself. Backend
fixtures and integration tests must establish those contracts.

Next specify ingress/output ownership and backpressure, using this retirement
obligation to keep cancellation and release paths serviceable under saturation.
