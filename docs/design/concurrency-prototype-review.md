# Integrated admission prototype review

Reviewed 2026-09-11 against `admission-state-machine.md`, the accepted policy in
`concurrency-model.md` section 4.2, and `commit-preparation.md`. This is a source
and targeted-test review, not an independent audit, exhaustive model check or
production-readiness approval. No production implementation or public IDL changed.

## Assessment

The implemented subset supports the selected take-turns, head-only reservation,
unnumbered-ticket and FIFO commit/snapshot direction. This review found no new
safety defect in the exercised subset requiring a change to those decisions.
It did find significant boundaries that must remain visible: retained IDs hide
reference-lifetime work, scheduler-lock allocation weakens the bounded-admission
claim, and test-only history access does not obey the intended FIFO contract.
Passing the current tests is not validation of the complete admission contract.

## Findings, in recommended work order

### 1. Completion is not permission to recycle request storage

[`finish`](../../test/concurrency/prototype.zig) retires the reservation and ticket
and marks a request finished, but other queued events or cancelled gate links may
still name that request. The engine retains every record until joined teardown,
so this is safe within the current scope. An application waiter must use finished
under the mutex, not the earlier atomic committed/cancelled effect, as its cleanup
completion predicate. Neither observation alone authorizes freeing the record.

A targeted audit test cancels an entitled request, executes its stale commit event,
and observes finished with zero tickets/physical credits while a cleanup event
remains queued. This is intentional evidence of separate lifetimes, not a failing
invariant. Request reuse must account for ready events, popped/running events,
gate links, completion observers and retained payload/node references. Generation
checks reject obsolete notifications but do not make a freed pointer safe to read.

**Next prerequisite:** specify result completion, reference retirement and reusable
storage as distinct transitions, then test delayed events against reused slots.
Do not replace retained arrays with recyclable pools before this is explicit.

### 2. The admission mutex is no longer uniformly short or nonblocking

`prepareWaiters` allocates and `reclaim` frees under `Engine.mu`. Writer execution
also reacquires that mutex while retaining its writer execution right. Thus an
allocator stall can delay all admission and hold up other writers, timers or
shutdown. This is acknowledged prototype scaffolding, but it does not implement
the contract's nonblocking contended-admission/retry path or establish low latency.

Actual commit installation remains outside the mutex, without allocator calls;
this review does not identify an allocator call inside that installation path.
The problem is shared admission service, not the fixed scalar install itself.
The injected allocator must not reenter the engine.

**Before production:** give fallible preparation and reclamation their own retained
work, publish bounded completion evidence, and leave bounded metadata updates under
admission synchronization. Coordinate this with finding 1 rather than simply moving
allocator calls outside the mutex and introducing ownership races.

### 3. History/pin test adapters can bypass older ready work

`removeHistory` and `pinHistory` check `running[writer]` but not its ready FIFO.
They can therefore execute while an older commit continuation is queued. This is
useful for constructing the victim-removal test schedule, and mutex plus writer
exclusion prevents simultaneous history mutation. It is **not** the accepted
"no older ready work" direct-execution rule. No starvation or direct-path fairness
claim should be based on these helpers.

**Before production:** admit policy cleanup/pin operations as normal context work
with applicable lifecycle rules. Reconstruct the victim-removal test by placing an
older cleanup operation in the writer queue before the entitled commit arrives.
Keep the current helpers explicitly identified as test adapters until then.

### 4. Shutdown's cancellation point needs an explicit operation policy

`startShutdown` sets shutdown under the mutex, releases it, then calls cancel for
each retained request. New writes/snapshots are rejected after the first transition.
An earlier pending write can still claim commit before its individual cancellation
runs; once claimed, it completes. This implements close admission followed by
best-effort abort, not atomic cancellation of every uncommitted request at the
instant shutdown starts. The general admission contract permits operation-specific
cancel-or-drain choices, so this is not by itself a contract violation.

**Before exposing the runtime API:** either adopt and document this ordering, or
make the selected abort boundary part of protected commit validation. Do not infer
atomic cancel-all semantics from the name `startShutdown`. Also distinguish
coherent generation close from context shutdown: the former intentionally reopens
new-generation ticket admission.

The new audit test confirms protocol stop may precede external-pin reclamation.
The engine and allocator still have to outlive those pins; `stoppedLocked` is not
permission to destroy them. Full entity deletion, callbacks and transport references
are not represented.

### 5. Fairness and capacity evidence is bounded and narrower than DDS history admission

The fixed round-robin selector and per-writer FIFO prevent ready-event overtaking.
The shared gate FIFO includes snapshots, and cancellation preserves handoff.
Physical preparation scans retained writes in arrival order, skipping ineligible
ones. The new audit test checks that released physical capacity goes to the older
eligible waiter before a younger independent write.

This does not implement combined writer/instance DDS resource limits, conditional
replacement eligibility, deadline-driven timed sleeping, class budgets or inline
runtime budgets. Logical reservation eligibility currently assumes depth-one
replacement is permitted. No test proves fairness under unbounded replenishment.

Internal queue headroom is explainable for this fixed model: each retained request
can contribute at most one queued promotion, commit and cleanup event at a time.
With twenty total records, that gives a conservative sixty-event bound even if
all target one writer, below its sixty-four slots. Snapshot requests need no
promotion, so the actual bound is tighter. This is a source argument, not measured
high-water evidence or a reusable capacity formula for new event kinds. Request
reuse, new continuation types and separate publication stages require a new bound.

### 6. Full conformance and some validation obligations remain absent

The prototype has one integrated transition implementation and deterministic plus
hosted threaded drivers. It has no automated equivalence check against the Python
models, exhaustive scheduler exploration, recyclable wait-generation mechanism,
application callback dispatch, participant/reader contexts, transport service,
real protocol timers or complete RTPS progress metadata. GROUP-disabled state
removal and minimal embedded builds have not been validated by this experiment.
Only a single fallible scalar allocation is exercised, not production payload/index
rollback. These remain explicit gaps, not failures concealed by TSan.

Several earlier design paragraphs still described all executable checks as absent.
Those status statements are corrected to point to the implemented subset; the
normative requirements and earlier finite-model limitations remain unchanged.

## Evidence and disposition

The baseline storage slice passed nineteen deterministic and eleven threaded tests
under LLVM TSan, as recorded in [prototype scope](concurrency-prototype.md).
This review adds three deterministic audit cases: finished versus stale references,
protocol stop versus pinned storage, and oldest-eligible physical admission.
All twenty-two deterministic cases passed under LLVM TSan, with no race or
allocator leak reports. The unchanged eleven threaded cases retain their prior
passing result; they were not rerun for this documentation/test-only review. TSan is race evidence, not proof of fairness or an independent
functional oracle. The full repository build and production runtime are not tested
by this review.

Recommendation: retain the selected architecture. Next work should be the lifetime
and reuse contract in finding 1, followed by moving preparation/reclamation behind
bounded completion publication and bringing helper operations through real FIFO
admission. No new broker or listener policy decision is required to begin that work.
