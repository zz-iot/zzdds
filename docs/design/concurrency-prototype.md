# Integrated concurrency prototype: infrastructure and scope

For the overall deliverables and proposed stopping point, see the
[specification status map](concurrency-spec-status.md).

Status: synchronization, idle-wakeup, operation-expiry, metadata-snapshot and prepared-storage slices implemented, 2026-09-11. Test-only code and build targets now exist; the full acceptance scope below is not yet implemented. Selected semantics are in [concurrency-model.md](concurrency-model.md), [admission-state-machine.md](admission-state-machine.md) and [commit-preparation.md](commit-preparation.md).

The [integrated admission review](concurrency-prototype-review.md) distinguishes tested behavior, prototype shortcuts and remaining production prerequisites.

The proposed [request completion and reuse contract](request-lifetime.md) now has a
separate bounded pool experiment. Its explicit reference edges and recyclable slots
remain separate from admission storage. The engine now accounts for ready-event,
executor, gate and observer ownership explicitly, but does not yet recycle slots.

## Infrastructure inspected

| Existing facility | Use and limitation |
| --- | --- |
| `test/rtps/writer_model_test.zig`, `test/dcps/presentation_model_test.zig` | Precedent for a small independent reference model compared with executable state; current production writer/coherent behavior is not an oracle for the new contract |
| `src/util/time.zig::ManualClock` | Controllable atomic time; its sleep path uses hosted mutex/condition synchronization and timed waits. Deterministic prototype should use explicit time input/advance and ready-work steps, not clock sleeps |
| `src/util/mutex.zig`, `src/util/condvar.zig` | Hosted test adapters already offer mutex tryLock and condition wait/wake. They are not freestanding synchronization backends; condition timed waits use wall-clock machinery |
| Existing FailingAllocator tests in `test/rtps/writer_sm_test.zig` and DCPS tests | Pattern for deterministic allocation failure; add allocation counters/forbidden-allocation checks around prepared commit |
| `src/transport/mock.zig` and recording transports in model tests | Available for a later RTPS integration slice; initial scheduler/history prototype requires no transport |
| `build.zig` subsystem test lists | Normal tests and separate LLVM/TSan graphs exist. A new test family needs explicit wiring into relevant graphs; adding a normal runner alone does not guarantee sanitizer coverage |
| `scripts/check_test_sleeps.py` | Recursively scans Zig tests. New tests must use controlled scheduling rather than wall-clock sleeps |
| `scripts/run_deterministic_matrix.py`, `docs/testing.md` | Existing optimization/minimal-feature checks and optional TSan invocation; no need to invent a second full matrix |
| `test/tsan_self_check.zig` | Existing instrumentation sanity check; use the repository TSan graph rather than assume a flag on a new target instruments it correctly |

`test/support` currently contains domain allocation support, not a general deterministic scheduler. Small barrier/checkpoint support will be needed for controlled threaded races. Zig was absent from PATH but subsequently located at `/home/tsimpson/code/zig-x86_64-linux-0.16.0/zig` and verified as 0.16.0. No compiler installation was needed.

## Placement and build integration

Use a new `test/concurrency/` module root containing prototype implementation/support and two runners: deterministic stepping and hosted threaded execution. Keep it outside production exports and generated IDL. A small explicit module import for hosted utilities avoids making the experiment depend on full DCPS construction or discovery. Choose exact imports at implementation time; Zig module-root restrictions mean cross-directory helpers need proper module wiring.

Add a focused `test-concurrency` step, include appropriate runners in normal `test` and `emit-tests`, and wire the threaded runner into the instrumented `test-tsan` graph (including its LLVM selection). Check other shared test-list consumers such as LLVM emission/ReleaseSmall before declaring coverage complete. The build wiring now exists: `test-concurrency`, `test-concurrency-tsan`, normal tests/emission, LLVM emission/ReleaseSmall and TSan. A dependency-free entry point also exists: `zig build --build-file test/concurrency/build.zig test` (or `test-tsan`), exercising the same helper without fetching zidl. Root graph execution still depends on the pinned zidl package being available.

## One integrated implementation, two drivers

Implement shared request transitions, bounded prepared-node storage, per-instance ledgers and one Publisher gate. Start with two writer contexts and multiple instances, including contention on one instance. Deterministic and hosted drivers must advance the same implementation rather than maintain two copies of the algorithm.

The deterministic runner controls time and scheduling checkpoints. The threaded runner uses real synchronization and explicit barriers to arrange races, with bounded watchdog failures rather than sleep-based orchestration. Do not put a global test mutex around all protocol transitions; that would hide cross-context synchronization failures. Checkpoints must not introduce acquisition cycles by blocking while retaining rights required by the controller.

Compare externally observable commit order, cancellation results, coherent boundaries and resource conservation with a compact reference oracle. Do not use exact equality of internal queue layouts as the oracle. Retain the Python models as design evidence; they do not substitute for tests of the Zig implementation.

## Acceptance cases and measurements

* Preparation limits one and greater than one; independent instances/writers continue while one instance waits.
* Cancellation before/after ticket issuance, entitlement publication and commit claim, including stale notifications.
* Coherent close with delayed commits/retirement, and shutdown with remaining stale references.
* Claimed replacement removed before commit; separate logical and physical exhaustion; allocation failure before commitment; no allocation in final commit.
* Enqueue versus executor release; sleep registration versus wake; busy writer with gate entitlement; bounded progress for metadata snapshot requests.
* Ownership/reference/credit conservation at every terminal path, no commit after abort wins, no sequence assignment during preparation, and no gate held while waiting for writer execution.
* Record direct-path allocations, queued handoffs, queue high-water marks and turns-to-service. Treat hosted timing as exploratory, not a DDS latency benchmark.

The prototype uses abstract commit metadata and history policy inputs. It does not establish full DDS QoS, RTPS heartbeat/repair correctness, MCU support or broker performance. Real wire integration follows only after this synchronization experiment passes. No production runtime refactor is part of this prototype.

## Implemented first slice

`test/concurrency/prototype.zig` is shared by deterministic and hosted threaded tests. It implements two writer contexts, two instances per writer, a configurable preparation ceiling, fixed request/event storage, head-only unnumbered tickets, FIFO gate entitlement, cancellation arbitration, coherent generation draining and shutdown cleanup. Scheduler metadata has a short hosted mutex; writer turns and history installation run outside it. Logical gate ownership is synchronized through that mutex, not held by the mutex across installation. Test checkpoints intentionally pause turns to exercise contention.

The tests cover successor preparation/head admission, independent-instance admission, cancellation with stale queued work, generation close, physical-credit exhaustion preserving history, saturated external request storage with cleanup capacity, overlapping actual writer executors, cancellation after irrevocable commit, and idle-worker wakeup/shutdown. Hosted checkpoint tests currently target POSIX and skip Windows. Condition timeouts are failure watchdogs, not scheduling sleeps.

This is a deliberately bounded synchronization slice: fixed retained request/node slots and separately allocated scalar payloads stand in for production payload/index machinery. It does not reuse request IDs, implement inline API execution, automatic clock/timer service, actual DDS history-removal policy decisions, variable-size buffers or actual transport. Those remain acceptance work; no memory-footprint or latency claim follows. The core drain driver returns when no work is currently runnable. The POSIX `idle_driver.zig` adapter adds persistent worker service using a condition variable and the same mutex for producer publication, predicate recheck and wait arming. Internal wake signaling is bounded and runs under the metadata mutex; it is not an application callback. Tests after joining workers inspect history without concurrent readers.

## Operation deadline slice

Requests optionally carry an absolute deadline in explicit monotonic test ticks.
These are operation admission deadlines, not DDS Deadline QoS. `advanceTime`
publishes time and signals the driver; it does not itself dispatch expiry.
`nextDeadline` exposes the earliest still-pending deadline. The idle predicate
includes due requests, so a capacity waiter can expire without receiving credit.
A bounded scan services expiry before selecting work. Writer execution rechecks
expiry under the admission mutex before claiming commit, covering time advancement
after that scan. Equality (`now >= deadline`) is expired; backward time is rejected.

Expiry and cancellation share the abort transition but preserve distinct outcomes.
The first abort claim wins; advancing time alone does not claim an abort. Once
commit is claimed, its deadline is excluded from timer eligibility and installation
completes. Aborted requests retain their records through cleanup and stale events;
retirement releases preparation credits and tickets and may seal a coherent set.
An already-due submission is recorded as timed out without preparing storage.

This seam validates arbitration with delayed timer dispatch, not real clock
sampling or automatic timed sleeping. A production adapter must sample monotonic
time at the commit boundary and integrate the earliest deadline with its wait
handshake. Timer indexing, clock conversion and wall-clock return latency remain
outside this slice.

## Metadata snapshot slice

Snapshot requests use the same FIFO gate links and entitlement handoff as commits.
Their continuation joins the target writer's normal ready queue and obtains that
writer's execution rights before activating the gate. Four separately budgeted
snapshot records remain available even when all sixteen write records are occupied.
Records are retained without reuse in this experiment; capacity exhaustion is
explicit. Snapshots need neither history credit nor a coherent-set ticket, and do
not change sequence numbers. Cancellation and shutdown use the existing abort and
stale-notification cleanup paths. The shared internal `committed` effect denotes
successful snapshot completion as well as successful write installation.

While active, a snapshot copies two bounded progress fields: installed count and
last installed sample metadata. It never reads another writer's mutable history.
The commit gate protects both fields, including the interval between their updates;
the completed result is release-published. Packet serialization, full writer/group
metadata and membership digests are not implemented here.

FIFO admission prevents later gate arrivals from overtaking a snapshot. This
requires eventual executor service and completion of older active turns; it is not
a wall-clock bound. Tests cover a snapshot ahead of younger saturated bursts, a
snapshot behind four older commits with twelve younger writes, reserved capacity,
cancellation and a checkpoint inside partial progress installation. Turn bounds
apply to these finite workloads, not arbitrary production context queues. Request
reuse and indefinite replenishment remain untested.

## Prepared-storage slice

Each prepared write owns an allocator-backed scalar payload and a stable node
record keyed by its unrecycled request ID. Node ownership distinguishes preparation,
resident history and external pins. Physical credit is returned only after all
three are gone. The default test allocator detects leaks; an injected failing
allocator exercises allocation failure before logical reservation/ticket admission.
An explicit out-of-memory outcome is internal to this test model, not a selected
public DDS error mapping. Preparation still has only one fallible allocation; this
does not validate partial rollback across production payload/index construction.

Only an instance head acquires the explicit depth-one logical reservation. It
records either the current victim's stable identity or a free reserved slot.
Authorized policy removal converts a victim reservation to a free reservation,
without transferring ownership to a successor. Commit checks that history still
matches that reservation, installs from the prepared payload, and transfers node
ownership after releasing the gate. Abort releases its reservation and preparation
storage without removing a live victim or resurrecting an independently removed
one. Retired payloads remain readable through existing pins; the final pin release
reclaims storage and retries physical-capacity waiters.

`removeHistory` and `pinHistory` are test adapters using nonblocking writer
admission under the metadata mutex. They return Busy if a writer turn is running;
a production continuation/retry queue and policy eligibility are not implemented.
Pin handles require balanced ownership by the test caller; IDs are not recycled.
Allocation and reclamation currently run under the short scheduler metadata mutex,
**outside the final installation gate**. This is a synchronization experiment,
not the proposed production allocation path or a performance result. Final commit
performs no allocation/deallocation; teardown frees remaining resident payloads
after all workers and pins have been released.

The new tests cover victim removal with a waiting successor, cancellation with a
live or removed victim, multiple pins retaining physical credit despite free
logical capacity, real allocation failure, successful commit with further
allocations disabled, last-pin release during partial installation, and idle-worker
wakeup after reclamation. Variable-size budgets, multiple fallible preparation
stages, node reuse/generation validation, production indexes and actual DDS
retention eligibility remain open.

## Integrated ready/gate ownership slice

The admission engine now retains requests for operation roots, result observers,
queued events, executing events and gate membership. Ready publication retains
before enqueue; dequeue transfers ownership to the executor without a reference
count gap. The executor releases after all transition accesses and successor
publication. Gate ownership transfers from queue to entitlement/active state, and
is released only after actual unlink or gate retirement. Cancelling a queued gate
record leaves its reference alive while the tombstone remains linked.

Completion releases the operation root after bookkeeping. Independent event and
gate references may remain. Tests can explicitly release the initial observer;
the legacy fixture otherwise releases that single observation at joined teardown.
Additional observations are bounded and must be released explicitly. A protected
retain rejects a request whose accounted references have reached zero.

`auditOwnership` independently walks real ready queues, current executor IDs and
the gate chain, compares those edges with the ownership ledger, and checks the
root/completion relationship. Every engine teardown runs this audit. New tests
also run it at intermediate states, including a saturated shutdown and threaded
pauses where cancellation has completed but either a gate tombstone or popped
executor still owns the request.

This integrates the ownership transfers, not recyclable storage. The engine still
uses retained numeric IDs for ordering and node identity. Its operation root covers
its synchronous reservation/ticket/wait bookkeeping; separate asynchronous timer,
ledger and context/control-block ownership is not yet modeled. Zero accounted
request references is therefore **not** permission to recycle the present engine's
request storage. The following identity slice removes node/order coupling; complete
request-slot reuse and conversion of remaining internal references still remain. The small pool experiment remains
the only executable slot-reuse fixture. No public API or production code changed.

## Independent identity and ordering slice

History and replacement reservations now hold `NodeHandle` values containing
engine identity, node slot and node generation. Reclamation increments generation
(or exhausts the slot without wrap), and preparation can reuse that node slot for
a different request. Pins validate this identity before release; an obsolete pin
cannot release a new occupant. Immutable sample progress retains request numbers
only as diagnostic values; it no longer dereferences requests to locate payloads.
Preparation and instance-head checks use explicit admission order rather than
request slot position. Fixed-size scans remain test scaffolding, not production
indexes or a complexity/performance claim.

Checked request lookup/retain/cancel methods validate engine identity, slot
generation and reference liveness under the admission lock. Ready events capture
the generation and validate it on dequeue. Internal raw request indices and the
legacy test observation API remain, protected by retained ownership and the fact
that request slots are still not recycled. Request-generation mismatch tests
therefore exercise validation, not reuse of an integrated request slot. Actual
request reuse continues to be tested by the separate small pool experiment.

The node test exercises real slot reuse while the old request/result remains
retained, and rejects an obsolete pin after that reuse. An order-permutation fixture
checks physical admission and instance order independently of slot position.
Allocation/reclamation still use the admission mutex; public IDL and production
protocol code are unchanged. This completes the current identity checkpoint, not
the production lifetime implementation. The [status map](concurrency-spec-status.md)
recommends returning to remaining specification decisions instead of automatically
adding more runtime machinery.

## Validation record

The accepted listener-quiescence policy now has five bounded retirement-frontier
fixture cases. All 42 deterministic runner entries (40 substantive cases and two
import-only entries) passed with LLVM TSan on 2026-09-11 after the main rebase.
This does not test a production setter or actual binding release callbacks.

The identity/ordering extension passed under LLVM ThreadSanitizer on 2026-09-11:
thirty-six deterministic runner entries (thirty-five substantive cases and one
import-only entry) and fourteen threaded tests, with no race or allocator leak
reports. No ReleaseSafe or full-repository result is claimed for this extension.


The integrated ready/gate ownership extension passed under LLVM ThreadSanitizer
on 2026-09-11: thirty-three deterministic runner entries (thirty-two substantive
cases and one import-only entry) and fourteen threaded tests, with no race or
allocator leak reports. This includes structural ownership audits at teardown and
selected intermediate states. No ReleaseSafe or full-repository pass is claimed.

The separate lifetime-pool experiment passed under LLVM ThreadSanitizer on
2026-09-11: thirty-one deterministic runner entries (twenty-two existing cases,
eight pool cases and one import-only entry) and twelve threaded tests. Both
negative controls produced their expected violation witnesses. No race or test
allocator leak reports occurred. No ReleaseSafe or full-repository pass is claimed
for this extension.

The integrated review added three deterministic audit cases; all twenty-two
deterministic cases passed under LLVM ThreadSanitizer on 2026-09-11, with no race
or allocator leak reports. The engine and threaded tests were unchanged in this
review; their earlier eleven-case result remains applicable.

The prepared-storage extension passed all nineteen deterministic and eleven
threaded cases under LLVM ThreadSanitizer on 2026-09-11, with no race or test
allocator leak reports. No ReleaseSafe or full-repository result is claimed for
this extension.

The metadata-snapshot extension passed all fourteen deterministic and nine threaded
cases under LLVM ThreadSanitizer on 2026-09-11, with no race reports. Formatting,
diff whitespace and the test-sleep guard also passed. This extension was not rerun
in ReleaseSafe; the earlier optimization results below apply to their stated slices.

On 2026-09-11 the idle-wakeup slice passed six deterministic cases in ReleaseSafe
and five threaded cases with LLVM ThreadSanitizer. The subsequent operation-expiry
slice passed ten deterministic cases and eight threaded cases under LLVM
ThreadSanitizer, with no race reports. ReleaseSafe passed the first nine
deterministic cases; the final queued-gate-expiry case was added during that
compilation and is covered by the ten-case TSan run. The
boundary-race case explicitly pauses between an empty observation and wait
registration, publishes work, then requires the locked recheck to find it.

These checks use the dependency-free test roots and the local Zig 0.16.0 compiler.
The main repository build graph has been wired but not executed here against its
pinned zidl package; do not read this record as a full-suite pass. No runtime public
API or production protocol implementation has changed.
