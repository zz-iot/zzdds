# Admission policy: design validation

Status: refined policy accepted, 2026-09-10. This is a transition/dependency analysis of the scheduling proposal in [concurrency-model.md](concurrency-model.md), not executable testing, a liveness proof or a performance measurement. The user accepted the refined scheduling policy and shared runtime progress domain after reviewing these findings.

## Candidate policy and assumptions

Direct execution is allowed only when the context has no older ready work. Otherwise ready operations enter FIFO order. Turns are bounded; runnable continuations go to the tail and condition waiters leave the ready queue. A runtime services ready contexts round-robin. Any eligible executor can advance retained internal operations. Protocol-only pumping does not recursively dispatch arbitrary listeners.

The reasoning below assumes a finite configured number of admitted records, eventual driver/executor service, finite protocol turns and correctly synchronized publication/wakeup. It does not guarantee progress through arbitrary user callbacks, a stalled OS thread holding execution rights, missing network traffic or resources deliberately retained by the application.

## 1. Coherent close with an outstanding writer ticket

Trace:

1. Write W reserves resources and receives ticket for Publisher generation G. Its local writer commit is ready but has not executed.
2. End E executes under Publisher admission, closes new tickets for G and observes W outstanding.
3. E registers its drain dependency and releases Publisher rights. It is no longer a ready operation.
4. The driver runs W's writer commit using reserved resources, then publishes its retained completion to the Publisher.
5. Completion retires the ticket and makes E's continuation ready. E seals completion metadata and advances the control generation.

Conditional result: no scheduler dependency cycle if W and its completion remain executable during close. It fails if closing disables all ingress, if E retains Publisher rights while waiting, if an intermediate continuation exists only on the blocked caller's stack, or if publication of W's completion needs an allocation from a full submission queue.

Required refinements: distinguish new external admission from admitted internal progress; reserve the complete bounded continuation/completion path before issuing the ticket; retain target lifetime through completion. Registration of E's predicate and the zero-ticket transition must use a common synchronization protocol to prevent a lost wakeup.

Sequence reservations also need separate scrutiny: assigning a group number is not proof that its cache change is installed. Heartbeat/order metadata must not advertise an uncommitted reservation as safely passed or absent. This is a Publisher protocol invariant, not something FIFO scheduling establishes.

## 2. Reliable write waiting for capacity

Trace:

1. Writer history is full. W checks admission, registers a capacity predicate under writer ownership, and leaves the ready queue before waiting.
2. Protocol input A processes the acknowledgment or other event that actually makes a slot reusable under the configured history policy.
3. W becomes runnable and later commits, or its deadline/cancellation wins before history admission.

Conditional result: blocked W does not prevent A executing. However, FIFO execution alone does not guarantee W capacity: a fresh write N already queued before W's wakeup can claim the freed slot. Repeating this schedule can starve W even while W receives regular execution turns.

Required refinement: history admission needs an independent resource-waiter policy. Initial candidate: service the oldest eligible waiter when resources become available and reserve those resources before publishing its runnable continuation. New writes cannot steal a resource reserved for W. Requests blocked on a different instance-specific limit should not stop unrelated eligible requests; define eligibility, multi-resource reservation and cancellation cleanup explicitly. Do not claim unconditional fairness for requests whose required resources never become available.

Register the wait predicate atomically with the admission check. Capacity release before registration must be observed by the check; release after registration must schedule a retry. Deadline/cancellation and history admission have one winner, with reservations released exactly once. Queue insertion and ticket allocation are not successful history admission.

Remaining application limitation: an application can fill a buffered coherent set and wait for more capacity before calling end. Scheduling cannot manufacture space or close the application bracket. Storage policy and operation deadlines must handle this case.

## 3. Sustained receive load

Trace:

1. A channel is continuously readable. One retained ingress-ready record represents bounded pending input work.
2. It processes a finite packet/byte/work budget, then yields. Remaining input makes it ready again at the tail.
3. Endpoint work, timers, completions and other ready contexts receive turns before the next ingress slice monopolizes execution.

Conditional result: FIFO plus round-robin prevents ready-work starvation only if intake, decoding/fan-out and output preparation all have bounded turns, and the runtime checks timers/completions even when input is continuously ready. Coalescing readiness alone does not bound packet buffers or a large dispatch fan-out.

Required refinements: bounded ingress buffers and fan-out continuations; one coordinated ready-membership state per context; timer checks at bounded scheduling intervals; explicit packet-overload handling; and reserved/coalesced internal wakeups. UDP loss under overload may require repair and is not equivalent to losing an admitted API request. TCP backpressure must not block the sole executor. No guarantee of successful data delivery under unlimited offered load follows.

Inline execution requires an additional runtime budget: an application or receive worker may otherwise execute endless uncontended operations in one context while a different context waits. On a manual driver, synchronous API entry/exit needs a defined protocol-help checkpoint or equivalent runtime service mechanism. Cross-context inline continuations consume the same finite budget and become queued work when it expires. An arbitrary application that never calls the driver or a progress-capable API cannot be guaranteed background progress.

## 4. Cross-cutting admission races

Checking for older work and claiming execution must be one synchronized transition. A new caller must not observe idle before an older enqueue becomes visible and then bypass it. Releasing execution, publishing runnable continuations and setting/clearing runtime-ready membership likewise need one no-lost-wakeup protocol. A context can be executing or queued for service without admitting two executors.

Submission limits must cover waiting requests as well as ready requests. Moving to a condition wait cannot evade the memory budget. Internal reserved capacity must be sized from maximum outstanding operations and their fan-out, rather than a guessed spare slot count. If a required reservation cannot be obtained, do not admit the operation yet.

An executor may advance another caller's internal request, but automatic callback placement must still obey the listener contract. Arbitrary callback duration prevents a wall-clock fairness bound on a sole executor. Protocol helping during supported callback waits mitigates only dependencies that protocol work can satisfy.

## Outcome and next verification

The candidate is viable under the stated assumptions but incomplete without separate resource fairness, close-safe internal admission and a runtime-wide inline budget. The user has accepted these refinements; the concrete synchronized transitions remain to be specified and tested. No priorities or permanent assigned workers are required by these traces.

Before implementation claims, encode deterministic schedules for: close before/after ticket completion; cancellation before/after resource reservation and commit; repeated newcomers competing with an old capacity waiter; continuous receive readiness with due timers and another ready context; exhausted external queue with internal completion due; and enqueue racing with executor release. Run the same schedules with one driver and multiple executors. Measure latency and queue bounds separately; these traces supply no numerical performance estimate.
