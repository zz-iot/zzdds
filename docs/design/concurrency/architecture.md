# Concurrency: architecture

Requirements use the [shared convention](../concurrency-broker-status.md#requirement-convention).
[The index](../concurrency-broker-status.md) owns scope and unresolved design items;
[the evidence inventory](../../../test/design-models/README.md) records validation.

Execution owners and fast paths define the common runtime. Admission, reservations and
retained lifetimes below constrain both manual and hosted implementations.

<a id="concurrency-model-state-ownership-and-progress"></a>
## Concurrency model: state ownership and progress

<a id="scope-and-execution-requirements"></a>
### Scope and execution requirements

* The protocol core must be capable of progress on one application thread, without background OS threads. MCU/RTOS use is an active target, although a complete MCU DDS feature/resource profile is separate work.
* Hosted applications may use background execution and multiple application threads. Preserve useful concurrent API access rather than equating manual progress with a universal non-thread-safe library.
* Evented I/O, number of threads and ownership of the pump are separate choices. An event loop may run on an application thread, a dedicated thread, or several independently owned workers.
* Protocol components must not require their own receive/timer threads. Scheduling must be separable from protocol state transitions.
* Callback serialization and lifetime guarantees are independent of backend. The default permits inline callbacks when eligible and keeps distinct reader listeners under a subscriber independent.
* Additional public execution controls belong in `zzdds.idl`, not `dcps.idl`. Standard DDS applications retain a useful automatic-progress default in hosted builds.
* Build-time selection is acceptable. Exact flag spelling remains implementation work; supported manual/hosted selection and external driving follow the [runtime contract](runtime.md).

<a id="three-independent-axes"></a>
### Three independent axes

| Axis | Choices to represent |
| --- | --- |
| Progress ownership | Application-driven or library-driven |
| Protocol execution ownership | One context or several independently owned contexts |
| Platform I/O | Readiness/completion integration, blocking workers, or MCU driver polling/interrupt ingress |

Callback placement is another policy above these axes: inline when eligible, designated executor, or explicit application dispatch. Avoid one `evented` boolean that silently changes thread safety, callback placement and blocking semantics together.

Zig 0.16 introduces `std.Io` implementations, but its release notes describe `Io.Evented` as experimental and single-threaded `Io.Threaded` as lacking task-level concurrency. Those facilities do not automatically transform blocking protocol loops into a manually driven state machine. [Zig 0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html).

Use `std.Io` where useful in hosted adapters. Do not make bare-metal support depend on a particular stackful coroutine backend. A MicroZig adapter needs the selected network driver/stack, clock, wakeup and interrupt ownership contract. No working adapter or version compatibility is asserted here. [MicroZig project](https://github.com/ZigEmbeddedGroup/microzig).

<a id="core-progress-boundary"></a>
### Core progress boundary

The engine contract: express protocol progress as bounded state-machine operations over explicit input, time and available resources. They produce outgoing work, status eligibility and a next deadline. Long I/O waits and user callbacks occur outside protocol-state ownership.

**Conforming approach — internal engine operations.** These are not public signatures:

```text
submit(command) -> admitted | retry | error
on_input(channel, bytes_or_completion, now) -> bounded work
advance_timers(now, budget) -> bounded work
drain_output(budget) -> submissions/completions
dispatch_callbacks(budget) -> eligible invocations
next_deadline() -> monotonic deadline or none
```

Output may be sent immediately when the adapter supports bounded submission; producing work does not imply allocating or enqueueing every packet. Ownership of borrowed/loaned buffers must cover partial send and asynchronous completion. An adapter must expose backpressure and completion, not block indefinitely behind a nominally non-blocking method.

No lost wakeups: checking that work is absent and arming a wait must coordinate with command/input publication. Fair budgets cover receives, commands, repairs, timers and callbacks so a flood in one class cannot prevent leases or shutdown from progressing. A callback's arbitrary duration is not bounded by a scheduler budget.

<a id="take-turns-execution"></a>
#### Take-turns execution

An execution context has at most one active protocol-state executor at a time, without permanent thread ownership. An eligible application thread, receive worker or manual driver may acquire execution rights and perform the same state transitions directly. The uncontended path must not require a command/response handoff solely to reach an assigned worker.

Context admission must be explicit and separate from the transitions it protects. A future assigned-worker policy must be able to reuse those transitions, executing directly on its worker and admitting commands from other threads. Supporting that later policy does not require implementing it now or relaxing listener guarantees.

Execution rights cover bounded state transitions. Release them before user callbacks, blocking network operations or waits whose progress requires the context. Waiting inside a callback retains the separate callback exclusion rights. A nested protocol pump reacquires context rights as needed; it does not recursively retain a context lock.

<a id="admission-policy"></a>
#### Admission policy

The [prepared-commit contract](architecture.md#prepared-writer-commits-and-fair-gate-handoff) records the selected ordered per-instance preparation ledger, configurable per writer with default limit one, and head-only Publisher ticket admission. Implementation gates are listed in the single status index.

The [admission state machine](architecture.md#admission-and-request-state-transitions) defines context lifecycle/execution, request placement, resource ownership and effect commitment. These transitions and the operation-specific effect boundaries are requirements; concrete queues and synchronization primitives are implementation choices.

Production scheduler validation and latency measurements are required before implementation claims; [the evidence inventory](../../../test/design-models/README.md) records the limited model and prototype coverage.

* Execute directly only when no older ready work exists; otherwise use FIFO ready admission within each context.
* Bound each turn. Runnable continuations and awakened requests join the tail; condition waiters remain outside the ready queue while still counting against storage limits.
* Service ready contexts round-robin. Enforce runtime-wide fairness with per-executor inline budgets and progress checkpoints
  (no shared counter on every direct call is required) so repeated direct calls cannot indefinitely bypass other ready contexts or due timers.
* Treat history-resource fairness separately: reserve available resources for the oldest eligible waiter before making it runnable. Define eligibility across instance-specific and combined resource limits in the detailed contract.
* Reserve bounded continuation/completion capacity for admitted internal work. Closing rejects applicable new submissions while preserving the progress needed to finish admitted operations.
* Any eligible executor may advance retained internal operations; waits hold no protocol execution rights. Protocol helping preserves listener exclusion and does not authorize arbitrary recursive callbacks.

Distinguish **context admission** (permission to execute) from **history admission** (acceptance of a sample). Neither queue insertion nor acquisition of execution rights alone means a DDS write succeeded.

The admission boundary must represent immediate execution, deferred/waiting admission, closure and failure. The state transitions are defined below; concrete queue representation and synchronization are implementation choices. It must support bounded pending storage, deadlines/cancellation, coordinated wakeups and generation checks. Implement the accepted fairness policy explicitly; a bare mutex does not establish it.

If an operation is queued, completion and cancellation must have a defined ordering: a request reported cancelled before history admission cannot later publish a sample. Once history admission wins, timeout handling must not report a fictitious pre-admission cancellation. Preserve each DDS operation's actual success/timeout semantics and retain payload ownership until the request has reached its terminal state.

Ownership: use participant control plus per-writer/per-reader contexts, with narrowly scoped Publisher/Subscriber coordinators, as defined by the ownership table below. This follows the user's preference for endpoint independence; concrete synchronization requires receive/write/shutdown integration validation. Context count does not imply thread count. Shared sockets route input to its owner explicitly; callback rights remain separate.

<a id="shared-subscriber-group-access-periods"></a>
#### Shared Subscriber GROUP access periods

The initial design uses one shared access period per Subscriber for GROUP presentation. This is a zzdds execution/access decision, not a claim that DDS mandates this concurrency mechanism. It supports cooperating consumers without promising a private snapshot or exclusive traversal.

* The first explicit `begin_access()` opens a period with a fixed admission boundary for eligible data. Further overlapping or nested explicit begins join it and increment Subscriber-wide depth; matching ends decrement depth. Only the final matching end closes the explicit bracket. Do not introduce implicit exclusive thread ownership or wait for another application's bracket to end.
* Individual reader operations remain synchronized, but read/take state is shared. A take by one consumer removes data another consumer might otherwise access. Applications requiring an uninterrupted ordered GROUP traversal coordinate the whole traversal, for example with one consumer task or application synchronization.
* Reception, repair and timers continue without holding protocol execution rights across application code. Newly completed groups outside the period's admission boundary await a subsequent period. Overlapping brackets can indefinitely prevent that boundary from advancing, even if each caller's bracket is short. Document this consequence and provide diagnostics for long-lived periods; do not silently advance an active view to relieve pressure.
* A fixed admission boundary does not freeze sample/view/instance state or create immutable per-caller contents. Resource accounting must cover retained and pending data. Full optional GROUP wire/history/lifespan integration remains an implementation/profile gate; no access path may expose partial coherent groups.
* Access-period references and loan ownership are separate. Closing a period must neither free outstanding loan storage nor wait for loan return. Loan return and deletion preconditions retain their own bookkeeping.
* Internal access guards for the special Subscriber callback path must preserve the active period while callbacks use it. Their accounting must be separate from explicit begin/end depth so callback exit cannot close an application's bracket. The listener contract defines explicit callback/delegation admission and recursion limits; this does not authorize automatic nested callbacks or deferred delegation semantics.

No per-thread balance checking or task ownership API is selected. A later explicit ownership extension, if justified, belongs in `zzdds.idl`. When GROUP is compiled out, omit this access-period machinery as required by [optional profile removal](#optional-profile-removal); required non-GROUP behavior remains.

Before implementation, validate overlapping/nested brackets, concurrent take versus ordered traversal, callback guard versus final explicit end, bounded storage during a prolonged period, and final end with outstanding loans. The ownership partition below fixes context granularity. The optional GROUP profile must still validate coherent visibility, retention and incomplete-set handling against these access-period rules.

<a id="execution-owners-and-coordination"></a>
#### Execution owners and coordination

The ownership partition below is required; it does not mandate one internal queue/container implementation. All execution owners use the selected take-turns policy; one application thread can advance them sequentially, while a hosted runtime can advance independent owners concurrently.

| Owner | Mutable state and responsibility |
| --- | --- |
| Participant control context | Participant lifecycle, discovery/matching decisions, endpoint registry and participant-wide policy/liveliness coordination |
| Writer context | Writer history admission, sequence state, reader proxies, repair, writer-local timers and output preparation |
| Reader context | Writer proxies, receive/reassembly state, reader history and instance state, read/take/loan bookkeeping and reader-local timers |
| Publisher coordinator | Child lifecycle and shared publication controls; optional group order, membership and coherent-boundary accounting |
| Subscriber coordinator | Child lifecycle; optional group completeness, ordering, visibility decisions and shared access-period bookkeeping |
| Transport channel owner | Socket/connection state, framing and output backpressure; dispatch of retained input to the appropriate protocol owner |

Coordinators own bounded shared transitions, not all child execution. They need admission and lifetime protection but no dedicated thread. Listener registration/exclusion remains governed by the listener contract; callbacks execute outside these owners' protocol rights. Transport-channel ownership is a required seam, not a settled I/O backend. Placement of built-in discovery endpoints within or alongside participant control is an implementation choice subject to these ownership and progress rules.

<a id="coordination-rules"></a>
##### Coordination rules

1. Ordinary endpoint work should execute with endpoint rights alone. Shared policy/matching decisions are installed as versioned updates; do not acquire participant control for every sample.
2. The baseline cross-owner mechanism is a retained command/contribution plus completion. Release one owner's execution rights before entering another. An eligible caller may immediately execute the next owner on the same thread: this boundary does not require queue allocation, a worker handoff or a context switch.
3. Do not synchronously wait for another owner while retaining execution rights. A pending operation stores its progress and resumes after a completion or readiness event. A synchronous public API waits or pumps only after releasing those rights, retaining its request/payload lifetime separately.
4. Every delayed operation identifies the target lifecycle generation. A retained reference prevents reclamation; a generation/closure check prevents stale work from modifying a replaced or closing entity. Define which admitted operations complete and which unadmitted operations cancel for each public API.
5. Notifications become eligible after the corresponding state/visibility commit. Failure to acquire listener rights must not roll back accepted protocol state or prevent repair/timer progress.

Use bounded pending storage and explicit overload handling. These rules do not authorize dropping admitted commands or treating queue admission as successful DDS history admission. The accepted short group-commit gate is a narrow exception, permitting bounded sequencing/history installation while holding writer execution rights. Its acquisition graph and preparation requirements are specified in the admission draft; it does not authorize entering general Publisher execution under writer rights. Other multi-owner operations need a separate lock-order and boundedness proof.

<a id="publisher-operations-spanning-writers"></a>
##### Publisher operations spanning writers

INSTANCE and TOPIC writes prepare payloads and reserve writer-local resources, then commit under writer rights without a Publisher ticket or group gate. TOPIC additionally obeys retained coherent-set sealing; see [fast paths](#fast-paths-and-progress-profiles).

For GROUP writes only, prepare payload and reserve writer-local resources; release writer execution rights; obtain a short-lived Publisher ticket; commit the prepared change under writer rights and the bounded group gate; then complete the ticket. A resource reservation survives release of execution rights. The accepted ticket fixes the applicable control generation but is unnumbered. Group order is assigned at actual installation under the accepted short group-commit gate; see [the commit contract](architecture.md#group-tickets-and-bounded-commit). Closing admission must not invalidate resources required by an already-admitted commit.

There must be no allocation, capacity wait, callback or network operation inside the admitted local commit. A ticket holder still needs writer execution admission: closing a coherent window must allow that commit to progress, and must not wait while owning either the coordinator or writer. In manual mode the pending commit must be runnable by the driver; it cannot depend on resuming a blocked caller's private continuation.

For GROUP, an outer coherent boundary closes the relevant ticket generation, drains admitted commits without retaining coordinator rights, and seals completion metadata before permitting subsequent publication to overtake it. It does not wait for remote acknowledgments. Ordinary capacity waiters have not joined the old generation. Sequence installation and close follow the admission/commit rules below; completion-marker retention, repair and suspension interactions require validation against the optional GROUP wire profile. TOPIC uses the retained seal protocol in the TOPIC completion section below, with no GROUP ticket; compiling out GROUP removes group-specific ordering/state, not all Publisher controls.

<a id="subscriber-operations-spanning-readers"></a>
##### Subscriber operations spanning readers

Readers submit retained prepared contributions to the Subscriber coordinator. Group records identify the remote publishing group and coherent set; readiness is not a scan asking whether every local reader has some completed data. Unrelated remote groups must not be coupled by an all-readers barrier.

Before a group becomes visible, all affected reader contributions and necessary storage must be prepared. A shared committed record or equivalent visibility mechanism allows a single decision to expose the prepared group without holding every reader context simultaneously. All access paths must respect that decision; a reader-local allocation failure must not leave other readers exposing a partial group. Concrete representation, memory ordering and optional-profile retention/history interactions require integration validation.

The agreed access brackets in the shared-access section above reference the eligible view; they hold no coordinator or reader execution rights across application code. Closing an access period releases its own retention independently of outstanding loans and callback guards. Distinct reader listeners remain independent under the listener contract, with shared consumption rather than private callback views.

<a id="lifecycle-and-validation"></a>
##### Lifecycle and validation

Creation reserves child identity/membership under parent control, initializes child state, then publishes a usable endpoint under a defined commit boundary. Failure before publication rolls back reservations. Deletion closes new admission, resolves retained work and detaches membership before eventual reclamation, subject to API preconditions. Do not destroy a child while a coordinator contribution, ticket, callback, loan or transport completion still references it. The local-publication/announcement/disposal ordering for concurrent entity creation and deletion is an [open design item](../concurrency-broker-status.md#open-design-items).

Validate at least: discovery removal racing with queued input; write admission racing with coherent close/deletion; a busy writer needed by a closing Publisher; a group whose last reader contribution fails preparation; final access end racing with a callback guard; and one-thread progress through each sequence. Compare uncontended inline work and contended admission, including allocation count, handoffs and fairness. These fixtures must precede treating the ownership map as an implemented guarantee.

<a id="platform-memory-and-blocking-boundaries"></a>
### Platform, memory and blocking boundaries

<a id="optional-profile-removal"></a>
#### Optional profile removal

Disabling an optional profile must remove its dedicated state and processing from ordinary endpoint paths while preserving core execution, listener exclusion and lifetime guarantees. Use compile-time component selection for both behavior and storage; runtime-disabled branches with permanently embedded maps, queues or per-sample metadata are insufficient. Small unsupported-operation stubs and necessary interoperability parsing may remain.

In particular, a build without GROUP presentation must not carry Subscriber-wide access-view/nesting machinery, cross-reader coherent assembly, group ordering or Publisher group-sequence coordination. Required non-GROUP presentation behavior remains endpoint-local; parent lifecycle management, listener dispatch, history admission, loans and ordinary ReadConditions/WaitSets remain. Optional profile selection must not silently downgrade requested QoS or disable requested filtering. Additional nonstandard public capability APIs, if needed, belong in `zzdds.idl`.

DDS 1.4 Annex A identifies Group access, Content-subscription, Persistence and Ownership profiles; omitting GROUP is not equivalent to omitting all presentation support. Profile boundaries and dependencies must be audited against that specification before defining switches. See [DDS 1.4 Annex A](https://www.omg.org/spec/DDS/1.4/PDF) and the [optional-profile roadmap task](../../roadmap.md#optional-dds-profile-builds).

Validate removal using matched builds: final application code/read-only data, static RAM, per-entity/per-sample storage and peak working memory. Include static application and exported-library configurations; do not infer savings from source lines or assume individual savings add together. No size savings have been measured yet. This requirement and the shared Subscriber access-period contract in the shared-access section above are agreed.

<a id="platform-boundaries"></a>
#### Platform boundaries

MCU interrupt handlers publish bounded events and wake the driver; they do not invoke DDS listeners or run unbounded protocol work. Single-threaded application execution does not eliminate synchronization with interrupts or a second core. Timer clocks must specify wrap, resolution and suspend behavior. Idle waiting must not lose interrupts between testing for work and sleeping.

Budget histories, command queues, callback pending state, fragments, timer entries and payload buffers. Prefer caller-supplied allocators/pools and make exhaustion explicit. Removing threads does not by itself make full DDS suitable for every device that can run an XRCE client.

Hosted TLS/DTLS, DNS and transport connection setup need bounded/cancellable integration; an adapter that blocks the sole driver can stop every lease and writer on that driver. Either use incremental/non-blocking APIs or isolate unavoidable blocking work where OS threads exist. Do not assume those hosted choices carry to an MCU.

Current `src/util/mutex.zig` uses pthread/Windows primitives, and transports use direct platform sockets. Supporting `std.Io` or a freestanding backend requires explicit adapter/synchronization changes; selecting a Zig build option is insufficient.

<a id="admission-and-request-state-transitions"></a>
## Admission and request state transitions

<a id="separate-state-dimensions"></a>
### Separate state dimensions

Do not combine execution, lifecycle, resource ownership and API outcome into one enum. A closing context can still execute; a resource-reserved request can still be queued.

| Object | State dimension | Values |
| --- | --- | --- |
| Context | Lifecycle | OPEN, DRAINING, CLOSED |
| Context | Execution | IDLE, SCHEDULED, RUNNING |
| Request | Placement | NEW, READY, RUNNING, WAITING, RETIRING, DONE |
| Request | Effect | UNCOMMITTED, COMMIT_CLAIMED, COMMITTED, ABORT_CLAIMED |
| Request | Owned resources | Explicit payload/reference, reservation, ticket and completion-credit records |

SCHEDULED means one service obligation exists for a nonexecuting context. It need not mean a particular queue implementation. RUNNING can have a nonempty FIFO behind its executor. CLOSED means no remaining protocol work, not that all externally retained storage has been reclaimed.

<a id="context-admission-and-turn-completion"></a>
### Context admission and turn completion

All transitions below require a common admission synchronization protocol. A short gate is the baseline conceptual model; an atomic optimization must preserve the same ordering. Never invoke application code or block while holding the gate.

| Event | Preconditions | Transition |
| --- | --- | --- |
| Direct submission | OPEN, IDLE, no older ready work, runtime inline budget permits | Retain request; claim RUNNING and execute its first turn |
| Queued submission | Lifecycle permits operation, pending-storage credit available | Append READY at tail; if IDLE, make SCHEDULED and publish service obligation |
| Driver claim | SCHEDULED | Atomically claim RUNNING and remove oldest READY request |
| Turn yields runnable work | RUNNING | Append continuation at tail; relinquish owner and schedule remaining work |
| Turn waits | Predicate registered; RUNNING | Request becomes WAITING; relinquish owner and schedule other ready work |
| Turn finishes | Result/cleanup progress recorded; RUNNING | Release turn; SCHEDULED if FIFO nonempty, otherwise IDLE |
| Internal continuation during drain | DRAINING and continuation belongs to retained admitted operation | Admit using reserved internal credit; normal FIFO service |

A small batch may retain the executor between turns within a finite budget, always serving the oldest ready request. It must eventually return service to the runtime. Idle-check plus direct claim, enqueue plus scheduling, and owner-release plus ready detection must not have separate unsynchronized gaps. Newcomers cannot steal a scheduled context's turn by observing that no executor currently holds it.

Runtime queue publication must itself be allocation-free after admission. A design may use an embedded ready node or an explicit publication handshake; context-gate/runtime-gate ordering and the precise handshake must be specified before implementation. Do not assume two independent queue/flag stores establish the invariant.

<a id="resource-waits-and-reservations"></a>
### Resource waits and reservations

Under the resource owner's rights, check eligibility and either reserve resources or register a waiter before releasing ownership. Wait records retain request identity and a wait-generation number. Resource release services the oldest eligible waiter, reserves its required resources, then makes its continuation READY. Wakeups for an obsolete wait generation are ignored without releasing a newer reservation.

A reservation has one owner and is consumed by commit or released by cleanup exactly once. New callers cannot use reserved capacity. Waiters stay within the configured pending-request budget even though absent from the ready FIFO. Multi-owner resource acquisition must release partial reservations or follow an audited acquisition protocol; fairness alone does not prevent a cycle of mutually held reservations. Choose a bounded waiter scan and operation-specific eligibility rules during implementation.

For cross-context notifications, the producer retains a preallocated completion record and publishes evidence; the destination applies it under its own rights. It does not mutate the destination's private protocol state directly. An operation can have several internal steps, but at most one executor advances its mutable continuation state at once.

<a id="commit-cancellation-and-result-delivery"></a>
### Commit, cancellation and result delivery

Preparation, ready admission and resource reservation do not mean API success. Each operation defines an effect boundary. For a write, the boundary is the irrevocable acceptance of its prepared change into history, with installation guaranteed by the reserved resources.

Before that boundary, cancellation and commit compete through one synchronized decision:

```text
UNCOMMITTED -> ABORT_CLAIMED  -> cleanup -> DONE(error/cancel/timeout)
UNCOMMITTED -> COMMIT_CLAIMED -> install -> COMMITTED -> completion -> DONE(result)
```

COMMIT_CLAIMED is an internal irrevocable commitment, not yet permission to advertise a sample on the wire or expose it through another owner's state. All validation, fallible allocation and necessary reservations precede this transition. Installation after it must be finite local work, without waits, callbacks or further fallible resource acquisition. The completion result is published only after installation and required bookkeeping. Operation-specific postcommit waits, such as acknowledgment waits, retain their own result semantics; a generic cancellation rule cannot erase an already committed effect.

Cancellation after COMMIT_CLAIMED loses the precommit race. A caller may not return a preadmission timeout and later discover that its sample was published. Before claiming commit, check the operation deadline at the same protected decision boundary. Scheduling delay can delay reporting a timeout; this policy promises no hard wall-clock return bound.

After ABORT_CLAIMED no executor may commit the request. It enters RETIRING while owners release reservations, tickets and references. A waiting caller can be notified only when returning cannot invalidate retained memory or leave untracked cleanup. The initial safe baseline completes cleanup before returning; separately retained asynchronous cleanup is a possible later optimization. Terminal result publication occurs once, with result writes visible before the waiter observes completion.

GROUP tickets are unnumbered. Assign group sequence order only at writer installation under the short group gate; issuing a ticket is not successful DDS history admission. This avoids reserving sequence numbers for work that can still be cancelled before installation.

<a id="group-tickets-and-bounded-commit"></a>
#### GROUP tickets and bounded commit

This section is GROUP-specific. INSTANCE and TOPIC use the specialization in
[fast paths](architecture.md#fast-paths-and-progress-profiles); neither acquires this gate for ordinary writes.

A ticket records control generation, permitted coherent membership and one outstanding completion obligation. It does not allocate a writer sequence number or group sequence number. All storage and continuation credits are reserved before the ticket is issued. Cancellation before commit retires the ticket and releases storage without creating a sequence hole. Final coherent close counts actual committed changes, not tickets issued.

The candidate final write transition holds writer execution rights and briefly claims a Publisher group-commit gate. Under that gate it validates ticket/deadline/cancellation state, claims commit, assigns writer/group sequence numbers and installs the prepared cache entry. Only then does it publish group progress and release the gate. The first committed member establishes the group's first sequence identifier. Empty/cancelled-only sets and end-marker sequencing need explicit treatment in the wire algorithm. GROUP sequence numbering also applies outside coherent brackets where required by the configured presentation scope.

The group-commit gate owns only shared sequencing/commit metadata, not general Publisher execution. This is an explicit exception to the baseline one-owner-at-a-time rule: writer-local installation overlaps ownership of a narrow shared gate. It requires an audited acquisition graph. No path holding this gate may enter or wait for a writer/participant/coordinator context. Network work, allocation, history scans/eviction cleanup and callbacks are excluded. Preallocate a directly installable history node/slot and defer reclamation work. Gate contention must release writer rights and register a retry without lost wakeups or busy spinning; queued gate claimants need fair service consistent with the accepted admission policy. The FIFO entitlement contract is described in [commit preparation](architecture.md#prepared-writer-commits-and-fair-gate-handoff); its test-only implementation does not establish production contention behavior.

Coherent close stops new tickets for G, then waits without coordinator execution rights for every G ticket to commit or abort and retire. Existing G tickets remain valid during the drain; tickets for subsequent publication cannot overtake the sealed boundary. A committed ticket reports its installed result through retained completion storage. Delayed retirement can delay close but cannot make uninstalled data appear committed.

The narrow gate prevents a dangerous schedule: writer A reserves GSN 10 and stalls before installation, while writer B installs GSN 11 and publishes group progress that could let receivers infer 10 is absent. Group progress snapshots must be taken consistently with installed writer ranges; stale precommit heartbeat construction must not be combined with a newer group watermark. This requirement applies to initial sends, repair and heartbeat construction, not just the counter increment.

GROUP gate/state must compile out when GROUP support is absent. Non-GROUP Publisher
controls retain their own required coordination. Production gate synchronization and
coherent wire behavior require the implementation evidence in the index.

<a id="waiter-sleep-and-shared-runtime-progress"></a>
### Waiter sleep and shared runtime progress

An ordinary hosted caller observes its retained request while runtime workers progress it.
Manual/callback-chain waiters help the shared runtime within accepted budgets. It never needs to resume a private stack frame inside an unfinished protocol transition. Supported callback waits help protocol work while retaining callback exclusion.

Sleeping needs a predicate/wakeup handshake: register wake interest, recheck completion/ready work/due timers, and atomically arm the wait relative to producers, or use an equivalent monotonic wake sequence protocol. Completion before registration must be found by the recheck; completion afterwards must wake the waiter. Spurious wakes recheck predicates. Select the earliest relevant operation or runtime timer deadline.

The shared runtime is the progress domain, not one global executor. Multiworker ready-queue ownership and per-context admission still guarantee a single executor per context. [Operations](operations.md), [runtime](runtime.md) and [listeners](listeners.md) specify cross-runtime WaitSets, runtime construction and callback delegation.

<a id="closing"></a>
### Closing

OPEN -> DRAINING closes applicable new external admission at one defined point. New external requests ordered after that point are rejected according to the API; earlier queued but uncommitted requests follow that operation's cancel-or-drain policy. Accepted commits and mandatory internal completions remain serviceable using retained credits. Lifecycle close and commit claim must be ordered so neither invalidates resources promised to the other.

DRAINING -> CLOSED requires no ready/running protocol work, no registered protocol waits, and no outstanding internal publication/ticket obligations. External loans or callback references can delay reclamation independently. Destruction cannot wait for its own callback. Runtime shutdown must keep servicing drain work rather than stopping workers first. Public deletion preconditions and exact cancel-or-drain choices remain operation-specific.

<a id="prepared-writer-commits-and-fair-gate-handoff"></a>
## Prepared writer commits and fair gate handoff

<a id="two-distinct-gate-objects"></a>
### Two distinct gate objects

Separate a FIFO admission record from the physical metadata gate. A request may own the next turn without holding the gate or writer execution rights. The head request's entitlement persists while it waits for its writer turn. New requests cannot bypass it.

Each retained gate request includes request identity, lifecycle/wait generation, operation kind (commit or metadata snapshot), target context reference, queue link and a pre-reserved wake/completion record. Include snapshot requests in bounded fair service; otherwise continuous commits can starve heartbeats. Actual snapshots copy bounded metadata only, with membership digests prepared separately; serialization and send happen later.

Conceptual states: QUEUED -> ENTITLED -> ACTIVE -> FINISHED, or QUEUED/ENTITLED -> CANCELLED. These are scheduling states, distinct from the request's irrevocable commit decision. Physical gate acquisition alone does not cause a write effect.

<a id="handoff-protocol"></a>
### Handoff protocol

1. Under a short admission gate, append once to the FIFO. If there is no active request or entitlement, select the head and assign a unique entitlement generation. Publish its retained writer-ready notification as part of the synchronized handoff protocol.
2. Do not acquire writer execution while holding the admission/metadata gate. The notification joins the writer's ordinary ready FIFO. A direct path is permitted when both writer admission and gate entitlement are immediately eligible, respecting runtime budgets and older work.
3. When the continuation gets writer execution, validate the entitlement and prepared resources. Atomically claim ACTIVE and the physical metadata gate using a nonblocking try. If the short admission gate is occupied, register a generation-aware retry, release writer rights, and leave the entitlement in place. Registration and release notification must share synchronization; do not spin or repeatedly enqueue duplicate retries.
4. While ACTIVE, arbitrate cancellation/deadline, then either abort without sequence assignment or claim commit and perform bounded installation. Release the physical gate before output, callbacks or reclamation. Finish the gate request and transfer entitlement under the admission protocol.
5. Publish the next retained wake without allocating. Until publication is guaranteed, keep an explicit pending-publication obligation; an idle flag alone is insufficient. The concrete implementation must choose a gate ordering or embedded-record publication handshake before coding.

Cancellation of QUEUED/ENTITLED records removes or tombstones the record under admission synchronization and transfers the head entitlement once. A writer-ready event already published can still execute: its generation check turns it into a no-op, and its retained reference must be released. ACTIVE cancellation competes at the common effect boundary; cancellation loses after COMMIT_CLAIMED. No cancellation thread mutates writer-private history directly.

Entitlement can cause head-of-line delay, but it is not a mutex held across writer scheduling. Any eligible runtime executor can service the entitled continuation. Writer turns must be bounded and new writer-ready work cannot bypass it. If preparation is no longer valid and needs additional resources, release entitlement before registering the resource wait; do not retain the Publisher's next commit turn through a capacity wait. Ordinarily reservations should make this unnecessary.

<a id="prepared-change-contract"></a>
### Prepared change contract

Foreign serialization, allocator hooks and fallible payload preparation run outside writer
rights. Bounded internal reservation bookkeeping may use writer ownership, outside the
group metadata gate. Its result owns:

* Serialized payload or explicitly retained loan storage with the required immutability/lifetime.
* A history node/slot that can be linked without allocation or array growth.
* Reserved instance/history capacity, initialized instance metadata and stable index/link information.
* Preallocated bounded retirement bookkeeping for any replacement, plus output/completion scheduling credits.
* Retained endpoint/control-generation references and, when required, an unnumbered Publisher ticket.

Preparation must not evict publicly retained history merely to reserve a slot, consume a writer/group sequence number or report API success. Reservations remain valid while writer rights are released. Competing writes, ACK-driven cleanup and deletion must respect them.

KEEP_LAST needs particular care: preselecting a raw pointer to an eviction victim is insufficient if other operations can replace/remove that victim. Use retained identities plus a writer-private reservation protocol, or re-evaluate the bounded replacement at the final writer turn before entering the group gate. Per-instance accounting and indexed history avoid full-history scans. If revalidation discovers a new capacity wait, relinquish gate entitlement and return to resource admission. The concrete reservation/index container is an implementation choice.

Inside the gate, after all checks: claim commit, assign sequence metadata, detach any bounded prepared replacement, link the prepared change, update bounded writer/group counters and publish consistent installed progress. Record deferred cleanup; do not free payloads, scan proxies, enqueue one event per reader, or serialize packets here. Output readiness is a bounded coalesced record; fan-out occurs in later budgeted turns. A prepared commit requiring an unbounded number of removals is ineligible for this path until that operation is decomposed outside the gate.

No externally observable half-installed history is allowed. Writer ownership protects writer data; the group gate protects sequencing/progress metadata; snapshot users take compatible ownership and copy immutable results. Numeric sequence exhaustion must be checked before effect commitment, with failure behavior defined separately.

<a id="close-and-resource-conservation"></a>
### Close and resource conservation

<a id="keep_last-reservations"></a>
#### KEEP_LAST reservations

Reserve a logical history admission credit separately from physical storage. A replacement reservation claims the right to replace one retained change; it does not overwrite that change or lend its buffer to preparation. The new payload/node and deferred-retirement capacity have their own bounded memory budget. Logical depth one can temporarily require storage for old data, prepared new data and externally pinned retired data.

Require a per-writer limit on outstanding prepared history reservations per instance, default one. This is a ceiling for each instance of that writer, not a count of application threads or a writer-wide aggregate budget. Standard DDS-only applications receive the default. Any public setting belongs on the writer extension interface in `zzdds.idl`; the creation-time DataWriterConfig.preparation_limit_per_instance field is defined in the extension API. Acquire reservation rights after fallible payload preparation and before a Publisher ticket. Requests exceeding the limit remain resource waiters; other instances and writers can continue. This is not an instance mutex held by an application thread and does not block ACK/repair/timer processing.

The one-reservation path remains the initial simple baseline. Supporting values above one requires a bounded per-instance reservation ledger; merely raising a counter is incorrect. In particular, multiple reservations for depth one cannot each independently claim replacement of the same old entry. Use ordered reservation positions, whose replacement entitlement advances through actual commit/abort decisions: aborting a predecessor must not invalidate a successor's guaranteed storage or require work inside the commit gate. The implementation must validate the ledger, GROUP gate composition and cancellation before advertising higher values. A request whose commit still depends on predecessor resolution must not hold Publisher gate entitlement. Head-only ticket admission is selected below; exact scheduling and synchronization remain to be implemented.

The selected refinement uses head-only logical history admission: later ledger entries own prepared physical storage and their ordered place, not independent claims on the same history slot. Only the head may secure actual replacement/free credit, obtain a Publisher ticket and join the gate queue. Removing a cancelled predecessor advances the ledger without renumbering or transferring ownership of a successor's prepared buffer. The successor chooses the current eligible history entry when promoted, rather than storing a pointer to a predecessor's future sample. If policy/resources prevent promotion, it waits without a Publisher ticket or gate entitlement. Thus prepared successors may cross a coherent boundary if their eventual ticket admission occurs after close; preparation alone does not establish coherent membership.

The ledger must preserve exclusive buffer ownership, cancellation without resident-data removal, per-instance commit order and coherent-generation commit order. Completion requires eventual service and policy-permitted reclamation. Admitting a successor to the gate before its unresolved predecessor can prevent either from committing; head-only admission prohibits that cycle.

Higher configured limits permit preparation to overlap; they do not permit concurrent mutation of one writer history or bypass FIFO/resource fairness. They consume bounded prepared-payload/node/notification storage independently of DDS HISTORY depth and RESOURCE_LIMITS. Keep aggregate writer/runtime memory limits as separate admission constraints, including payloads prepared before a reservation is obtained. Do not promise improved throughput without measurement. Prefer bounded preallocated bookkeeping for configured capacity and define configuration-time failure when it cannot be provided; live resizing semantics are not selected. Until the ledger is implemented, reject unsupported values rather than silently clamp them or advertise support. A model of one capacity does not validate arbitrary configured capacities.

Under writer ownership, select either a free logical credit or a policy-permitted replacement identified by a stable node identity/generation. A retained entry claimed for replacement remains visible to repair until commit or independent policy removal. If independent removal becomes appropriate, detach that entry and atomically convert the reservation to a free-but-reserved credit. Never return that credit to the general pool while its request still owns it. Thus ACK/expiry cleanup can proceed without invalidating guaranteed admission or allowing a newcomer to steal the slot. ACK arrival alone is not permission to remove data needed for durability or another policy.

At commit, a replacement reservation detaches its still-live victim and installs the prepared entry; a converted/free reservation installs without a victim. Cancellation releases only the reservation: it leaves a still-live victim intact, or returns a converted free credit to the pool. It does not resurrect a change independently removed by policy. Per-instance reservation ownership ends after commit/abort updates are installed; payload reclamation can happen later through separate references.

Example, depth one: old A is retained; W reserves replacement of A; policy cleanup removes A and converts W's claim to a free reserved slot; newcomer N cannot take the slot; W either installs B or cancels and frees the slot. A saved raw pointer without this conversion protocol would be unsafe.

Track writer-total sample credit, per-instance credit, instance identity retention and physical-memory credit separately. Do not issue a Publisher ticket while waiting to assemble these reservations. Initially, if same-instance replacement/free admission cannot meet a writer-wide limit, leave the request waiting under the configured API resource policy; optional cross-instance eviction needs a separate audited policy and must not be improvised inside the commit gate. Coherent-set and durability retention restrictions are policy inputs to victim eligibility, not bypassed by this algorithm.

An indexed per-instance order and stable global sequence index are required for bounded detach/install. A monolithic ArrayList with scans and orderedRemove does not meet that requirement. Candidate structures include stable pool nodes with intrusive instance/global ordering plus a separately prepared sequence lookup index. No concrete container has been selected. Tests must include removal of a claimed victim, cancel before/after that removal, competing same-instance writes and physical-memory exhaustion with logical space available.

Coherent close stops new generation tickets but retains service for existing commit/cancellation records. Ticket retirement follows installation or completed abort bookkeeping. Gate-turn retirement and Publisher-ticket retirement are separate: handing off the gate does not by itself tell coherent close that all accounting is complete.

Every request owns a ledger of reservation, history/payload references, ticket and scheduling credits. Commit transfers payload/history ownership to the cache; abort releases preparation ownership. Cleanup and stale wake consumption return remaining credits exactly once. Endpoint deletion cannot reclaim state still retained by either path.

<a id="request-completion-reference-retirement-and-storage-reuse"></a>
## Request completion, reference retirement and storage reuse

<a id="three-distinct-boundaries"></a>
### Three distinct boundaries

| Boundary | Required condition | What becomes possible |
| --- | --- | --- |
| Result completion | Effect resolved; installation or abort bookkeeping complete; reservations/tickets settled; request-owned resources released or transferred to tracked owners | A waiter can observe/copy the immutable result and return according to the operation's semantics |
| Reference retirement | No queued, executing, registered, publishing or observing owner can access the request; it is detached from all indexes and lists | Begin destruction of remaining request-local storage |
| Slot reuse | Destruction complete and generation advanced under pool synchronization | Admit a new request into that slot |

Result completion does not imply reference retirement. Protocol stop does not
imply storage reclamation. An effect of COMMITTED is not yet result completion.
Use a separate completion predicate with release/acquire publication or the same
protecting lock; do not overload the effect enum. The result is immutable and
published once. Copy it while retaining the request, then release the observer.

Initial baseline: a completed abort has disposed of or transferred all preparation
ownership and retired its ticket/reservation. A completed write has installed and
transferred its sample to history and settled its ticket/reservation. If old payload
reclamation remains, a retained history/pin/reclamation owner accounts for it;
the request must not leave an untracked cleanup obligation. Operation-specific
postcommit waits remain distinct and may delay that operation's result completion.

<a id="separate-identity-from-order-and-lifetime"></a>
### Separate identity from order and lifetime

**Conforming approach — pooled storage.** Use a stable pool control block with identities of the form `(pool, slot,
slot_generation)`. The pool component may be implicit when an enclosing retained
object unambiguously identifies it. Request and history-node pools have distinct
identities even if their storage is allocated together. Neither a naked pointer
nor a slot number is a public or durable identity.

Four counters have different purposes:

* Slot generation identifies successive occupants of one storage slot.
* Wait/continuation generation identifies successive registrations of one live request.
* Coherent control generation identifies the publication membership boundary.
* Ledger order identifies write admission order within an instance.

Reusing a slot must not change ledger ordering, coherent membership or sequence
numbers. Maintain explicit retained instance-ledger order independent of reusable
slot indices. A ledger holds references until
unlinking; slot position has no ordering meaning. History must identify a node,
not refer back to a request record merely to recover sample identity. Sequence
metadata and immutable diagnostics can be copied without retaining the request.

Generation exhaustion must never wrap to a previously valid identity. Retire the
slot or fail further admission explicitly. Apply an equivalent no-alias rule to
wait generations; do not roll them over while an old notification can survive.
Exact widths and configured pool sizes are implementation choices, not settled
by this contract.

<a id="reference-acquisition-and-transfer"></a>
### Reference acquisition and transfer

Pool metadata remains alive independently of individual entries. A lookup by a
non-owning handle first retains/accesses that stable control block, then validates
slot generation and liveness and acquires a reference under pool synchronization.
Only then may it dereference the entry. Generation validation followed by an
unprotected reference increment is forbidden: reuse could occur between them.
Initial implementation should use the admission/pool lock, not an improvised
lock-free reference acquisition algorithm.

An existing owner may transfer its reference without dropping it to zero. Creating
an additional owner requires a counted retain before publication. Destruction
cannot start while any such owner remains. Whether references are implemented as
counts, typed ownership records or embedded flags is secondary to conserving these
ownership obligations:

| Owner | Acquire/retain | Transfer or release |
| --- | --- | --- |
| Operation lifetime root | External admission succeeds | Release after immutable completion is published and all protocol obligations are settled or explicitly transferred |
| Result observer | Before returning/retaining the operation handle | Copy result or abandon observation, then release; abandonment does not imply cancellation |
| Instance ledger / resource or timer registration | Before linking/registering | Unlink under its owner's synchronization, then release or transfer to a continuation |
| Gate record / entitlement | Before joining FIFO | Transfer through queued/entitled/active states; release after unlink and gate retirement |
| Publication obligation | Before making a destination notification possible | Transfer into a queued event, or into retained retry state if publication is deferred |
| Ready event | Before publishing queue entry | Transfer to executor on dequeue; never drop and reacquire between pop and execution |
| Executor | By transfer from ready event or eligible direct admission | Publish any successor obligations first, then release its own reference |
| Detached cleanup job | Before releasing the owner that needed cleanup | Release after cleanup and its bounded completion publication |

One record may represent several states through ownership transfer; this table
does not require a separate atomic counter for every row. Independent live edges
must still be independently accounted for. An executing operation cannot advance
mutable continuation state concurrently with another executor. Reference safety
does not grant execution rights or authorize producer mutation of destination state.

Reference counters and continuation capacities are bounded. Admission reserves
needed internal completion capacity before publishing the request. Later mandatory
cleanup may not fail because external work exhausted the pool. Coalescing is valid
only with a retained producer/publication obligation and a synchronized predicate.
Queue duplication must not create uncounted references or double releases.

<a id="cancellation-obsolete-notifications-and-completion"></a>
### Cancellation, obsolete notifications and completion

Cancellation still competes with commit at the protected effect boundary. Winning
cancellation initiates retirement; it does not free request storage or revoke
references held by another executor. A gate/ready notification already published
can remain queued as a tombstone, retaining its target until consumed. Alternatively
it can be unlinked under the relevant owner's rights and have that reference
released there. Never release merely because an unlink was requested.

A dequeued event retains both the request and its destination lifetime. It checks
the request identity and applicable wait/entitlement generation under the destination
protocol. If obsolete, it performs no request-state mutation and releases only
its own ownership. It must not release a newer reservation, clear a newer scheduled
flag or retire a newer gate entitlement. Re-registering a wait publishes a new
wait generation before making new notifications eligible.

For the initial baseline, **a queued reference prevents slot reuse**. An owning
notification therefore cannot legitimately name an already-reused slot; a mismatch
in that case is an invariant failure, not routine cancellation. Obsolete wait
notifications for the same live request are expected. A late non-owning handle can
legitimately fail lookup after reuse. Keep those two cases distinct in tests.

Completion is published while the operation root or executor still owns the record.
Observer registration and completion recheck share synchronization, as do wake
publication and sleeping. Completing between observation and wait arming must not
lose the wake. An asynchronous user retaining a completed result handle can keep
a slot occupied; bounded capacity must report this rather than silently recycle it.
A synchronous wrapper can copy its result and drop the handle before returning.
Neither behavior introduces a new standard DDS API.

<a id="history-nodes-payloads-and-replacement-reservations"></a>
### History nodes, payloads and replacement reservations

Node lifecycle is independent of request lifecycle. Preparation owns the new node;
commit transfers it to history. Pins/loans and transport use, where applicable,
retain node/payload ownership directly rather than retaining the completed write
request. Detach removes the history owner; it does not invalidate existing pins.
No node slot or payload buffer can be reused while such an owner exists.

A replacement reservation is a logical slot entitlement, not ownership of the old
payload. Its victim locator includes the node generation and is examined only
under writer ownership while history retains that node. Policy removal converts
the reservation to free-but-reserved and clears its victim link in the same
protected transition, before dropping history ownership. A deferred task needing
to dereference the old node must retain it separately; the locator alone provides
no memory safety. Cancellation releases its reservation without resurrecting or
removing independently managed history.

When the final data owner releases a detached node, transfer it to reclamation
ownership before publishing any deferred destructor task. Reclamation must not
resurrect a zero-reference object by incrementing an already-dead record. Separate
"no data owners" from "safe to reuse": a queued or running destructor still owns
the node. Finish payload destruction outside protocol/admission locks, then publish
physical-capacity release and reusable-slot availability through retained bounded
completion storage. Do not let a waiter spend physical credit before reclamation
actually makes it available.

This enables moving allocation/free out of the admission mutex later, but does not
itself specify that executor or allocator adapter. Multi-stage preparation rollback
uses the same ownership ledger: every successful stage is either transferred to
the next stage or reclaimed after failure, including failure before any ticket exists.

<a id="reusable-state-decision-and-teardown"></a>
### Reusable-state decision and teardown

A request becomes eligible for reclamation only when completion is published,
all protocol ownership edges are gone, all observers have released it, and no
list/index references it. The final release records a reclaiming state under pool
synchronization. Destruction runs with retained pool/allocator lifetime; publish
FREE and advance slot generation only after it finishes. No new lookup succeeds
while reclaiming. Allocation into FREE fully initializes the new record before
publishing its handle or linking it into admission structures.

Endpoint/control/runtime lifetimes form explicit teardown obligations. A context
must remain accessible while destination events or executors retain it. Avoid
self-sustaining ownership cycles: the runtime's pool registry is not itself an
extra per-entry reference that an entry must release. An owning pool/control block
is destroyed only when its outstanding-entry/job/observer counts and external
owners permit it; exact storage layout may combine these counters.

Protocol stop drains all admitted protocol work, including stale notifications.
Outstanding loans may still retain storage afterwards. Reclamation service and the
allocator/control block must therefore outlive protocol stop. A manual driver must
still be able to service reclamation, or final-release cleanup must have a defined
safe synchronous path. Do not enqueue work onto workers that have been destroyed.
The initial contract requires explicit reclamation completion before destroying
the pool; it does not require hidden threads, waiting inside callbacks, or recursive
protocol execution. Public deletion results follow [operations](operations.md) and [listeners](listeners.md);
resource completion is the separate [runtime](runtime.md) reclamation fence.

Internal shutdown may batch cancellation or close admission before cancelling
uncommitted work, but must preserve already-claimed commit resources and retained
lifetimes. The observable close/results/retirement rules in [runtime](runtime.md) and
[operations](operations.md) apply to either implementation. No extension belongs in `dcps.idl`; any future nonstandard
runtime/result configuration belongs on `zzdds.idl` extension interfaces, with
safe default ownership for standard-only applications.

<a id="fast-paths-and-progress-profiles"></a>
## Fast paths and progress profiles

<a id="ordinary-operations"></a>
### Ordinary operations

PRESENTATION eligibility is fixed at creation. INSTANCE writes do not acquire GROUP
Publisher tickets or the group ordering gate. Prepare payload and bounded capacity before
commit; foreign conversion/allocation hooks execute outside protocol rights. Commit under
writer rights, then permit initial output on the same executor after releasing rights.
No mandatory worker handoff or batching delay is introduced. Capacity waits, competing
preparations, lifecycle fences and operation-specific limits still apply. Bypassing a
GROUP gate does not bypass writer ordering or make arbitrary hooks safe under ownership.

A receive may proceed to an eligible listener on the current executor after releasing
protocol ownership and acquiring the normal callback guards. Otherwise coalesce retained
notification work. Shared identity exclusion applies equally to fast and queued paths.

For a named preallocated bounded-payload configuration, target no steady-state heap
allocation, one uncontended writer commit admission, no mandatory cross-thread handoff
and no ready-queue publication when work completes inline. These are implementation
acceptance targets, not measured facts or requirements for arbitrary serializers. Count
reservations, atomic accesses, admissions and output records separately in benchmarks.

Combine already-committed ready output within byte/count/time budgets. Reuse immutable
serialization across destinations where representation/security permits; independently
reserve per-destination submission/completion state. Coalesce supersedable protocol
control work without dropping required changes. No new application flush API is required.
Suspension is an output hint, not a reason for every ordinary write to enter GROUP admission;
resume must signal pending output even if no further writes occur.

<a id="topic-coherent-completion"></a>
### TOPIC coherent completion

For coherent TOPIC Publishers, publish depth and generation consistently. Only outermost
begin/end open/close a generation. Each writer maintains its own local set under writer
rights. A closing generation schedules retained seal work for participating writers or a
bounded scan of the Publisher's writers. It must not depend on a later write.

A seal executes under writer rights: after any earlier admitted commit, close that local
set and retain an ordered repairable completion marker. No foreign calls or network sends
occur under rights. A write encountering a newer/closed Publisher generation seals its
old local set before opening another, using the same reserved machinery. Old queued seal
work must not seal a newer generation. Publisher close never waits while holding rights
needed by the writer; deletion fences work and follows incomplete-set semantics.

RTPS 2.5 §8.7.6 defines completion using DATA without PID_COHERENT_SET or with that
parameter set to SEQUENCENUMBER_UNKNOWN. DATA may omit serializedPayload, allowing
completion without a subsequent application write. Retain and repair the marker in writer
sequence order; this specifies the native mechanism, not an already-implemented codec.
[OMG RTPS 2.5](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

One reusable seal command is sufficient only with explicit monotonic pending-generation
coalescing and guaranteed rescheduling. One marker history slot is NOT enough to promise
unlimited closes without failure: earlier markers can remain unacknowledged. Reserve each
set's completion capacity before admitting its first effect. Reclaim marker storage only
when repair/retention obligations allow. Exhaustion backpressures admission of another set
under existing bounded operation rules, not the completion of an already admitted one.
Sequence capacity must also be checked before effects; never preassign a marker sequence
that later data would need to precede.

Direct retained per-writer scheduling is also permitted if it meets the same ordering,
lifetime, completion-capacity and bounded-progress requirements. **Conforming approach — retained close scan.** One implementation uses a retained Publisher close-scan obligation with a
fixed membership frontier and
closed-generation high-water. Child publication/removal and frontier capture share a
short metadata synchronization boundary. Each writer has a pre-reserved seal command;
coalesce its pending generation by maximum. Scan in bounded batches without holding
Publisher rights while acquiring writer rights. Keep the current pass's frontier/cursor
stable while new closes accumulate a dirty rescan obligation; complete the pass before
restarting so churn cannot starve writers near its end. Retain membership nodes or stable
generation-checked handles until the scan releases them. Never retain an unprotected pointer.

In this scan implementation, a writer published during an open generation joins at its first committed effect, which
reserves completion capacity. If published after a captured close frontier it cannot
commit into that closed generation: its acquire observation sees the closed/new state.
A writer already executing a commit against the old open generation is covered by the
captured membership and seals after its turn. Deletion fences both scan and seal work,
retains required cleanup references and does not fabricate completion for an incomplete
set. Publisher deletion follows the same rule for its subtree. End closes metadata and
publishes/reserves the scan obligation, then returns without waiting for writer turns.

<a id="helping-and-fairness"></a>
### Helping and fairness

Hosted ordinary application callers do not help by default. Background workers guarantee
protocol recovery, retirement and broker reconnect independently of waiters. Callback-chain
waits help bounded internal work because they occupy executors; they do not recursively
dispatch arbitrary callbacks. Manual mode retains shared-runtime helping and one outer
driver. Owner-only helping is not assumed sufficient for cross-context dependencies.

Runtime-wide fairness is an observable progress requirement, not a shared counter updated
by every inline call. Per-executor budgets and readiness/deadline signals may implement it.
No ready work or due timer may be indefinitely bypassed by repeated direct calls. Preserve
a scheduler-policy seam; v1 need not implement priority classes. Document FIFO entitlement
inversion for GROUP and bound turn/critical-section work rather than promise real-time
priority inheritance. Stage remote view reconciliation in budgeted turns with fair local
progress and a short validated visibility commit; avoid absolute local priority starvation.

<a id="cooperative-measurement-profile"></a>
### Cooperative measurement profile

Initial target: one participant/manual runtime, one bounded reliable writer/reader with
small KEEP_LAST histories, one WaitSet/ReadCondition, UDP, C/Zig, no GROUP/content filters
or advanced runtime/resource/listener-group extension use. Use fixed capacity pools or a
fixed-buffer allocator; no dynamic allocation after initialization in this profile.
ManualDriver and existing Config creation remain available.

Single-thread specialization may replace atomics/locks with flags when exclusivity is
established. Retain generation fencing, loans, reentrancy guards, queued work, pins and
async completion ownership. Produce flash/static/peak RAM measurements on a named Cortex-M
configuration, including history replacement overlap, marker reserves and pinned retired
samples. No MCU size claim follows from a compressed hosted binary or test-only struct.

<a id="required-footprint-worksheet"></a>
#### Required footprint worksheet

Measure one concrete target/build with explicit endpoint/history/payload capacities.
Report independently, rather than rolling pins and prepared buffers into HISTORY depth:

| Component | Required accounting |
| --- | --- |
| Runtime/participant | Static engine, driver/wake/timer, entity/control tables, stack high-water |
| Endpoint/instance | Index and lifecycle state, pending operations, listeners/condition registrations |
| History payload | Retained depth times bounded payload/metadata; reliability repair references |
| Replacement overlap | Old resident plus prepared replacement plus externally pinned retired data |
| Access output | Loan descriptors, claim/pin ledgers, nested output storage and conversion temporaries |
| Optional coherent support | Completion reservations/retained markers for TOPIC; GROUP-only ordering/access state separately |
| Transport | Receive buffers/reassembly, queued sends and independent completion/cancellation storage |

A single-thread build may remove mutex/atomic synchronization under exclusive ownership;
it retains state transitions, generations, pins and asynchronous completion bookkeeping.
GROUP/content-query-exclusive state must compile out when disabled. Report flash, static
RAM and peak RAM, not compressed hosted executable size or only `sizeof` of one struct.

## Required integration paths

Consolidate periodic tasks into runtime timer work; writers must not require individual
heartbeat threads. Manual and hosted drivers advance the same state machines. Compile a
minimal freestanding core without thread, sleep or socket dependencies; platform adapters
supply those services. That compile establishes isolation, not a complete MCU DDS profile.

Validate these paths with both drivers and bounded resources:

| Path | Required ordering and observations |
| --- | --- |
| Receive to callback | Transport completion → owner admission → parse/history/status commit → notification eligibility → release protocol ownership → callback claim and inline entry or retained pending work. Deferral must not delay ACK solely for a callback; history policy still governs acknowledgment. Count allocations and handoffs. |
| Reliable write under backpressure | Prepare/retain → attempt history admission → publish if admitted, otherwise register predicate/deadline → release rights → background/internal manual progress → retry or operation-specific timeout/closure. No check/insertion gap, deadline restart or mutex retained across waiting. |
| Shutdown | Close admission → invalidate new work for closing lifetimes → wake/cancel and quiesce affected ingress → finish retained effects/application uses → reclaim when references/loans permit. Never join the executing callback or break shared channels used by other contexts. |

Exercise loss, saturation, continuous ingress, stale completion and callback-initiated
closure, with equivalent observable results under manual and hosted progress. Report
uncontended and overloaded p50/p95/p99 latency, handoffs, queue depth, CPU and memory.
Hosted validation includes races; manual validation includes bounded work/stack use and
reproducible scheduling. No fixed latency target is inferred from a scalar model.
