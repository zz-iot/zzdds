# Manual runtime driving and external-loop integration

Status: two-layer direction accepted, 2026-09-16. Single outer manual-driver admission is also accepted. Concrete operation semantics
below are proposed for the IDL/bootstrap review, not implemented interfaces. Builds
on runtime-retirement.md and the accepted callback helping restrictions.

## Two public layers, one internal engine

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

## Simple driver operation

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

## External-loop adapter

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

## Result distinctions and validation

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

## Accepted bootstrap integration — 2026-09-17

Single outer driving and the two progress contracts are accepted. The
[runtime bootstrap contract](runtime-bootstrap-contract.md) fixes initial external
attachment before participants/I/O, atomic progress handoff, clock compatibility and
no live executor replacement in v1. Its narrower detach rule supersedes the possible
replacement-executor exception above. Concrete platform ABI and backend fixtures remain
implementation gates. Owner release and automatic retirement suffice for ordinary use.
