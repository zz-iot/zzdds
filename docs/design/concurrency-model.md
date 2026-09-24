# Concurrency model: state ownership and progress

Start with the [consolidated decision baseline](concurrency-contract.md), updated
2026-09-17, for accepted policies and implementation boundaries.

See the [specification status and finish line](concurrency-spec-status.md) for the
document map, current maturity and proposed boundary of the validation effort.

Status: architecture investigation with accepted v1 responsibilities; consolidated
2026-09-17. Later linked contracts supersede historical open/proposed language for
admission, listeners, runtime construction and retirement. Physical coordinator,
queue and backend algorithms remain implementation work. Full coherent-presentation
wire behavior is outside this concurrency milestone; see the explicit scope in the
[readiness review](concurrency-final-review.md). No production implementation is implied.

## 1. Requirements established in discussion

* The protocol core must be capable of progress on one application thread, without background OS threads. MCU/RTOS use is an active target, although a complete MCU DDS feature/resource profile is separate work.
* Hosted applications may use background execution and multiple application threads. Preserve useful concurrent API access rather than equating manual progress with a universal non-thread-safe library.
* Evented I/O, number of threads and ownership of the pump are separate choices. An event loop may run on an application thread, a dedicated thread, or several independently owned workers.
* Protocol components must not require their own receive/timer threads. Scheduling must be separable from protocol state transitions.
* Callback serialization and lifetime guarantees are independent of backend. The default permits inline callbacks when eligible and keeps distinct reader listeners under a subscriber independent.
* Additional public execution controls belong in `zzdds.idl`, not `dcps.idl`. Standard DDS applications retain a useful automatic-progress default in hosted builds.
* Build-time selection is acceptable. Exact flag spelling remains implementation work; supported manual/hosted selection and external driving follow runtime-bootstrap-contract.md.

## 2. Three independent axes

| Axis | Choices to represent |
| --- | --- |
| Progress ownership | Application-driven or library-driven |
| Protocol execution ownership | One context or several independently owned contexts |
| Platform I/O | Readiness/completion integration, blocking workers, or MCU driver polling/interrupt ingress |

Callback placement is another policy above these axes: inline when eligible, designated executor, or explicit application dispatch. Avoid one `evented` boolean that silently changes thread safety, callback placement and blocking semantics together.

Zig 0.16 introduces `std.Io` implementations, but its release notes describe `Io.Evented` as experimental and single-threaded `Io.Threaded` as lacking task-level concurrency. Those facilities do not automatically transform blocking protocol loops into a manually driven state machine. [Zig 0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html).

Use `std.Io` where useful in hosted adapters. Do not make bare-metal support depend on a particular stackful coroutine backend. A MicroZig adapter needs the selected network driver/stack, clock, wakeup and interrupt ownership contract. No working adapter or version compatibility is asserted here. [MicroZig project](https://github.com/ZigEmbeddedGroup/microzig).

## 3. Proposed core boundary

**Proposal C1:** express protocol progress as bounded state-machine operations over explicit input, time and available resources. They produce outgoing work, status eligibility and a next deadline. Long I/O waits and user callbacks occur outside protocol-state ownership.

Conceptual operations, not proposed public signatures:

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

## 4. Execution ownership decision and remaining alternatives

| Model | Benefit | Principal cost/risk |
| --- | --- | --- |
| Fine-grained locks and direct callers | Closest to current code; can avoid command handoffs | Lock ordering, callback call-chain audits and backend-specific waits remain complex |
| Take-turns execution per context (selected initially) | One executor at a time, with direct execution by eligible callers | Fairness, cache movement between cores and contended admission need explicit handling |
| Assigned worker per context (future policy) | Stable execution placement and centralized scheduling/batching | Off-worker synchronous calls need command/result handoffs; worker availability can limit progress |
| Sharded ownership by endpoints/sessions | Can scale a broker and large participants | Cross-owner operations, lifetime and ordering become significantly harder |

### 4.1 Agreed: take-turns execution

An execution context has at most one active protocol-state executor at a time, without permanent thread ownership. An eligible application thread, receive worker or manual driver may acquire execution rights and perform the same state transitions directly. The uncontended path must not require a command/response handoff solely to reach an assigned worker.

Context admission must be explicit and separate from the transitions it protects. A future assigned-worker policy must be able to reuse those transitions, executing directly on its worker and admitting commands from other threads. Supporting that later policy does not require implementing it now or relaxing listener guarantees.

Execution rights cover bounded state transitions. Release them before user callbacks, blocking network operations or waits whose progress requires the context. Waiting inside a callback retains the separate callback exclusion rights. A nested protocol pump reacquires context rights as needed; it does not recursively retain a context lock.

### 4.2 Agreed admission policy; state transitions to develop

The [prepared-commit contract](commit-preparation.md) records the selected ordered per-instance preparation ledger, configurable per writer with default limit one, and head-only Publisher ticket admission. [Prototype infrastructure and scope](concurrency-prototype.md) records the next implementation experiment.

The [admission state-machine draft](admission-state-machine.md) now separates context lifecycle/execution, request placement, resource ownership and effect commitment. Its synchronization mechanisms and operation-specific boundaries remain proposals for review.

The refined policy is accepted following [design-level trace validation](admission-validation.md). A [test-only synchronization prototype](concurrency-prototype.md) now exercises part of this policy with deterministic and hosted threaded drivers. Production scheduler validation and latency measurements remain outstanding.

* Execute directly only when no older ready work exists; otherwise use FIFO ready admission within each context.
* Bound each turn. Runnable continuations and awakened requests join the tail; condition waiters remain outside the ready queue while still counting against storage limits.
* Service ready contexts round-robin. Apply a runtime-wide inline budget and protocol-progress checkpoints so repeated direct calls cannot indefinitely bypass other ready contexts or due timers.
* Treat history-resource fairness separately: reserve available resources for the oldest eligible waiter before making it runnable. Define eligibility across instance-specific and combined resource limits in the detailed contract.
* Reserve bounded continuation/completion capacity for admitted internal work. Closing rejects applicable new submissions while preserving the progress needed to finish admitted operations.
* Any eligible executor may advance retained internal operations; waits hold no protocol execution rights. Protocol helping preserves listener exclusion and does not authorize arbitrary recursive callbacks.

Distinguish **context admission** (permission to execute) from **history admission** (acceptance of a sample). Neither queue insertion nor acquisition of execution rights alone means a DDS write succeeded.

The admission boundary must represent immediate execution, deferred/waiting admission, closure and failure. The precise API, queue representation and synchronized state transitions remain design work. It must support bounded pending storage, deadlines/cancellation, coordinated wakeups and generation checks. Implement the accepted fairness policy explicitly; a bare mutex does not establish it.

If an operation is queued, completion and cancellation must have a defined ordering: a request reported cancelled before history admission cannot later publish a sample. Once history admission wins, timeout handling must not report a fictitious pre-admission cancellation. Preserve each DDS operation's actual success/timeout semantics and retain payload ownership until the request has reached its terminal state.

**Proposal C2:** use participant control plus per-writer/per-reader contexts, with narrowly scoped Publisher/Subscriber coordinators, as consolidated in section 4.4. This follows the user's preference for endpoint independence; the detailed coordination protocol remains proposed and requires receive/write/shutdown validation. Context count does not imply thread count. Shared sockets route input to its owner explicitly; callback rights remain separate.

### 4.3 Agreed: shared Subscriber GROUP access brackets

The initial design uses one shared access period per Subscriber for GROUP presentation. This is a zzdds execution/access decision, not a claim that DDS mandates this concurrency mechanism. It supports cooperating consumers without promising a private snapshot or exclusive traversal.

* The first explicit `begin_access()` opens a period with a fixed admission boundary for eligible data. Further overlapping or nested explicit begins join it and increment Subscriber-wide depth; matching ends decrement depth. Only the final matching end closes the explicit bracket. Do not introduce implicit exclusive thread ownership or wait for another application's bracket to end.
* Individual reader operations remain synchronized, but read/take state is shared. A take by one consumer removes data another consumer might otherwise access. Applications requiring an uninterrupted ordered GROUP traversal coordinate the whole traversal, for example with one consumer task or application synchronization.
* Reception, repair and timers continue without holding protocol execution rights across application code. Newly completed groups outside the period's admission boundary await a subsequent period. Overlapping brackets can indefinitely prevent that boundary from advancing, even if each caller's bracket is short. Document this consequence and provide diagnostics for long-lived periods; do not silently advance an active view to relieve pressure.
* A fixed admission boundary does not freeze sample/view/instance state or create immutable per-caller contents. Resource accounting must cover retained and pending data. Detailed history/lifespan eligibility rules remain to be specified without exposing partial coherent groups.
* Access-period references and loan ownership are separate. Closing a period must neither free outstanding loan storage nor wait for loan return. Loan return and deletion preconditions retain their own bookkeeping.
* Internal access guards for the special Subscriber callback path must preserve the active period while callbacks use it. Their accounting must be separate from explicit begin/end depth so callback exit cannot close an application's bracket. The exact interaction with explicit calls in callbacks and busy-listener admission during `notify_datareaders()` remains open; this decision does not authorize arbitrary recursive callbacks or deferred delegation semantics.

No per-thread balance checking or task ownership API is selected. A later explicit ownership extension, if justified, belongs in `zzdds.idl`. When GROUP is compiled out, omit this access-period machinery as required by section 7.1; required non-GROUP behavior remains.

Before implementation, validate overlapping/nested brackets, concurrent take versus ordered traversal, callback guard versus final explicit end, bounded storage during a prolonged period, and final end with outstanding loans. Context granularity and the detailed visibility/retention algorithm are not settled by this access-contract decision.

### 4.4 Proposed ownership map and coordinator interactions

This section consolidates the preferred participant-plus-endpoints direction. It does not mark the detailed algorithms as agreed. All execution owners use the selected take-turns policy; one application thread can advance them sequentially, while a hosted runtime can advance independent owners concurrently.

| Owner | Mutable state and responsibility |
| --- | --- |
| Participant control context | Participant lifecycle, discovery/matching decisions, endpoint registry and participant-wide policy/liveliness coordination |
| Writer context | Writer history admission, sequence state, reader proxies, repair, writer-local timers and output preparation |
| Reader context | Writer proxies, receive/reassembly state, reader history and instance state, read/take/loan bookkeeping and reader-local timers |
| Publisher coordinator | Child lifecycle and shared publication controls; optional group order, membership and coherent-boundary accounting |
| Subscriber coordinator | Child lifecycle; optional group completeness, ordering, visibility decisions and shared access-period bookkeeping |
| Transport channel owner | Socket/connection state, framing and output backpressure; dispatch of retained input to the appropriate protocol owner |

Coordinators own bounded shared transitions, not all child execution. They need admission and lifetime protection but no dedicated thread. Listener registration/exclusion remains governed by the listener contract; callbacks execute outside these owners' protocol rights. Transport-channel ownership is a required seam, not a settled I/O backend. Placement of built-in discovery endpoints within or alongside participant control remains open.

#### Coordination rules

1. Ordinary endpoint work should execute with endpoint rights alone. Shared policy/matching decisions are installed as versioned updates; do not acquire participant control for every sample.
2. The baseline cross-owner mechanism is a retained command/contribution plus completion. Release one owner's execution rights before entering another. An eligible caller may immediately execute the next owner on the same thread: this boundary does not require queue allocation, a worker handoff or a context switch.
3. Do not synchronously wait for another owner while retaining execution rights. A pending operation stores its progress and resumes after a completion or readiness event. A synchronous public API waits or pumps only after releasing those rights, retaining its request/payload lifetime separately.
4. Every delayed operation identifies the target lifecycle generation. A retained reference prevents reclamation; a generation/closure check prevents stale work from modifying a replaced or closing entity. Define which admitted operations complete and which unadmitted operations cancel for each public API.
5. Notifications become eligible after the corresponding state/visibility commit. Failure to acquire listener rights must not roll back accepted protocol state or prevent repair/timer progress.

Use bounded pending storage and explicit overload handling. These rules do not authorize dropping admitted commands or treating queue admission as successful DDS history admission. The accepted short group-commit gate is a narrow exception, permitting bounded sequencing/history installation while holding writer execution rights. Its acquisition graph and preparation requirements are specified in the admission draft; it does not authorize entering general Publisher execution under writer rights. Other multi-owner operations need a separate lock-order and boundedness proof.

#### Publisher operations spanning writers

Proposed write sequence: prepare payload and reserve writer-local resources; release writer execution rights; obtain a short-lived Publisher ticket where shared publication controls require it; commit the prepared change under writer rights; then complete the ticket. A resource reservation survives release of execution rights. The accepted ticket fixes the applicable control generation but is unnumbered. Group order is assigned at actual installation under the accepted short group-commit gate; see [the commit contract](admission-state-machine.md#41-agreed-unnumbered-tickets-and-bounded-group-commit). Closing admission must not invalidate resources required by an already-admitted commit.

There must be no allocation, capacity wait, callback or network operation inside the admitted local commit. A ticket holder still needs writer execution admission: closing a coherent window must allow that commit to progress, and must not wait while owning either the coordinator or writer. In manual mode the pending commit must be runnable by the driver; it cannot depend on resuming a blocked caller's private continuation.

An outer coherent boundary closes the relevant ticket generation, drains admitted commits without retaining coordinator rights, and seals completion metadata before permitting subsequent publication to overtake it. It does not wait for remote acknowledgments. Ordinary capacity waiters have not joined the old generation. Exact sequence allocation, failure/closure ordering, completion-marker retention and suspension interaction need a state-machine specification. Non-GROUP coherent boundaries still require the applicable Publisher coordination; compiling out GROUP removes group-specific ordering/state, not all Publisher controls.

#### Subscriber operations spanning readers

Readers submit retained prepared contributions to the Subscriber coordinator. Group records identify the remote publishing group and coherent set; readiness is not a scan asking whether every local reader has some completed data. Unrelated remote groups must not be coupled by an all-readers barrier.

Before a group becomes visible, all affected reader contributions and necessary storage must be prepared. A shared committed record or equivalent visibility mechanism allows a single decision to expose the prepared group without holding every reader context simultaneously. All access paths must respect that decision; a reader-local allocation failure must not leave other readers exposing a partial group. The exact representation, memory ordering, retention and history/lifespan interaction remain open.

The agreed access brackets in section 4.3 reference the eligible view; they hold no coordinator or reader execution rights across application code. Closing an access period releases its own retention independently of outstanding loans and callback guards. Distinct reader listeners remain independent under the listener contract, with shared consumption rather than private callback views.

#### Lifecycle and validation

Creation reserves child identity/membership under parent control, initializes child state, then publishes a usable endpoint under a defined commit boundary. Failure before publication rolls back reservations. Deletion closes new admission, resolves retained work and detaches membership before eventual reclamation, subject to API preconditions. Do not destroy a child while a coordinator contribution, ticket, callback, loan or transport completion still references it. Exact discovery announcement/disposal ordering remains to be specified.

Validate at least: discovery removal racing with queued input; write admission racing with coherent close/deletion; a busy writer needed by a closing Publisher; a group whose last reader contribution fails preparation; final access end racing with a callback guard; and one-thread progress through each sequence. Compare uncontended inline work and contended admission, including allocation count, handoffs and fairness. These fixtures must precede treating the proposed ownership map as an implemented guarantee.

## 5. Manual and background drivers

**Proposal C3:** both drivers advance the same core. The manual driver processes ready work up to a budget and optionally waits up to the smaller of its caller deadline and the next protocol deadline. A lower-level non-waiting drive operation plus deadline/wakeup integration supports an application that already owns an event loop.

The background driver schedules the same work automatically and competes for context admission under the selected take-turns policy. Consolidate periodic tasks rather than retaining a heartbeat thread per writer. Stable worker assignment, migration, affinity and work stealing are possible later policies, not requirements of the initial design.

Provisional hosted default: background progress with inline-when-eligible listener placement. Provisional constrained build: explicit application-driven progress with no linked OS thread dependencies. Determine whether this is selected per library, factory/runtime or participant before defining IDL or flags.

Concurrent/reentrant `drive` calls need an ownership rule. Proposed: only one driver advances a context at once, with a specially controlled protocol-only nested pump for audited waits. A general recursive driver that dispatches arbitrary listeners is not part of the proposal.

**Agreed C4 direction: shared runtime progress domain.** A runtime contains the relevant participant, endpoint, coordinator and transport work. Supported synchronous waits can advance ready protocol work across that runtime, rather than only the endpoint being waited on. This is a progress domain, not a global execution lock or a requirement for one worker; take-turns ownership remains per context.

Public construction/configuration APIs, default runtime ownership, factory relationships and mixed manual/background behavior remain open. WaitSets spanning distinct runtimes require an explicit progress/wakeup contract; selecting a shared runtime does not silently authorize pumping every runtime in the process. Cross-factory conditions, external GuardConditions and runtime shutdown also require fixtures. Additional public controls belong in `zzdds.idl`.

## 6. Three paths to validate

### 6.1 Receive and callback

```text
transport completion
  -> identify context and acquire execution rights (inline if eligible)
  -> parse/process RTPS and commit history/status
  -> make notification eligible
  -> release protocol ownership
  -> claim listener/entity/group execution rights
  -> invoke inline, or retain pending notification
```

Record handoffs and allocations at each boundary. Ensure timers and protocol input can progress during an occupied callback in the supported waiting path. Deferring a notification must not delay acknowledgment merely because application notification has not executed; history admission/resource policies still determine what can be acknowledged.

### 6.2 Reliable write under backpressure

```text
application write
  -> serialize/retain payload under explicit ownership
  -> attempt history admission
  -> submit immediately if admitted
  -> otherwise expose a wait predicate and deadline
  -> release protocol ownership before waiting
  -> background driver or controlled manual pump makes progress
  -> retry admission or return the specified timeout/error
```

Do not hold a context lock while waiting for work that context must perform. A synchronous return must preserve the operation's meaning; “queued to the runtime” cannot silently replace “accepted into writer history.” Zero-copy/loaned API ownership must be tracked across any queued command. Waiting from a callback retains callback exclusion even while protocol ownership is released. Resource release may depend on application code, so not every write wait is guaranteed to complete by protocol pumping.

Capacity evaluation and reservation must be atomic with respect to competing writes and history changes. Evaluate actual history/instance/resource policies, not cache length alone. Register a wait predicate before releasing ownership in coordination with notifications so capacity changes cannot be missed. The current `DataWriterImpl.writeRaw` checks capacity separately from protocol insertion and polls at 1 ms with a hard-coded 10-second timeout; that implementation is evidence of refactoring work, not the desired admission contract.

### 6.3 Shutdown and callback-initiated deletion

```text
close admission
  -> invalidate new callback/command work for closing generations
  -> wake/cancel waits and quiesce transport input
  -> allow retained operations/callbacks to finish
  -> reclaim state after references/loans permit
```

Separate logical close from memory reclamation. Neither manual nor background shutdown may join/wait for its own currently executing callback. Whether public delete operations wait, defer reclamation or return a particular error depends on the entity/API and remains a lifecycle decision. Shared sockets must remain usable by other contexts. A stopped runtime must leave no timer, callback or completion referencing freed storage.

## 7. Platform, memory and blocking boundaries

### 7.1 Agreed: optional profiles must compile out

Disabling an optional profile must remove its dedicated state and processing from ordinary endpoint paths while preserving core execution, listener exclusion and lifetime guarantees. Use compile-time component selection for both behavior and storage; runtime-disabled branches with permanently embedded maps, queues or per-sample metadata are insufficient. Small unsupported-operation stubs and necessary interoperability parsing may remain.

In particular, a build without GROUP presentation must not carry Subscriber-wide access-view/nesting machinery, cross-reader coherent assembly, group ordering or Publisher group-sequence coordination. Required non-GROUP presentation behavior remains endpoint-local; parent lifecycle management, listener dispatch, history admission, loans and ordinary ReadConditions/WaitSets remain. Optional profile selection must not silently downgrade requested QoS or disable requested filtering. Additional nonstandard public capability APIs, if needed, belong in `zzdds.idl`.

DDS 1.4 Annex A identifies Group access, Content-subscription, Persistence and Ownership profiles; omitting GROUP is not equivalent to omitting all presentation support. Profile boundaries and dependencies must be audited against that specification before defining switches. See [DDS 1.4 Annex A](https://www.omg.org/spec/DDS/1.4/PDF) and the [optional-profile roadmap task](../roadmap.md#optional-dds-profile-builds).

Validate removal using matched builds: final application code/read-only data, static RAM, per-entity/per-sample storage and peak working memory. Include static application and exported-library configurations; do not infer savings from source lines or assume individual savings add together. No size savings have been measured yet. This requirement and the shared Subscriber access-period contract in section 4.3 are agreed.

### 7.2 Platform boundaries

**Proposal C5:** MCU interrupt handlers publish bounded events and wake the driver; they do not invoke DDS listeners or run unbounded protocol work. Single-threaded application execution does not eliminate synchronization with interrupts or a second core. Timer clocks must specify wrap, resolution and suspend behavior. Idle waiting must not lose interrupts between testing for work and sleeping.

Budget histories, command queues, callback pending state, fragments, timer entries and payload buffers. Prefer caller-supplied allocators/pools and make exhaustion explicit. Removing threads does not by itself make full DDS suitable for every device that can run an XRCE client.

Hosted TLS/DTLS, DNS and transport connection setup need bounded/cancellable integration; an adapter that blocks the sole driver can stop every lease and writer on that driver. Either use incremental/non-blocking APIs or isolate unavoidable blocking work where OS threads exist. Do not assume those hosted choices carry to an MCU.

Current `src/util/mutex.zig` uses pthread/Windows primitives, and transports use direct platform sockets. Supporting `std.Io` or a freestanding backend requires explicit adapter/synchronization changes; selecting a Zig build option is insufficient.

## 8. Prototype and evaluation plan

Build a bounded experiment after reviewing C1–C4; this document does not request implementation yet. Reuse a small representative RTPS path, memory/lossy transport and fake clock, then a real hosted UDP channel. Exercise identical behavior with caller-driven progress and one background worker before adding multiple workers.

Acceptance evidence:

* Reliable repair, timer progress and endpoint lifecycle agree across drivers under deterministic event schedules.
* Inline receive-to-listener path has no mandatory worker handoff; count allocations and compare latency with the existing path.
* Busy shared listeners remain serialized; unrelated listeners and protocol work make progress according to available workers/budgets.
* Manual waits progress ACKs/conditions without incidental listener recursion; callback-dependent waits exhibit the documented timeout/failure behavior.
* Queue saturation, one-way loss, continuous ingress and shutdown do not leak memory, strand execution rights or starve timers.
* No thread/sleep/socket dependencies leak into a minimal freestanding core compile. This compile is necessary but not sufficient for MCU functionality.

Run performance measurements both uncontended and under overload; report p50/p95/p99, handoffs, queue depth, CPU and memory rather than assigning an unmeasured latency budget. Threaded tests require race coverage. Manual tests require explicit work/stack bounds and reproducible scheduling.

## 9. Integration and sequencing

1. Review the listener contract's L1–L5 questions alongside C2 ownership and C4 blocking progress scope. Record decisions as accepted only when actually settled.
2. Specify shared transport channel/ingress context and clock/deadline seams. Continue lossless discovery codec work independently.
3. Prototype the three paths above using take-turns execution, then settle context granularity, contended admission and supported blocking behavior.
4. Define extension IDL and build/runtime selection. Preserve the standard API surface and document hosted/manual defaults.
5. Refactor shared timers, remaining send-under-lock paths and transport dispatch as needed. Expand backend support using the same semantic tests.
6. Update broker execution requirements to use the settled runtime. Reuse RTPS reliability only with explicit scheduling/backpressure support; scale claims remain gated on implementation and measurements.

The ownership proposal is now consolidated in section 4.4. The next work is the **concrete admission state-transition contract**: context ready/executing/closing state, request waiting/reserved/committed/completed state, synchronized wakeups and cancellation winners. The refined admission policy and shared runtime progress domain are agreed alongside take-turns execution, shared GROUP access brackets and optional-profile removal. Detailed coordinator algorithms and runtime APIs remain open. Validate the transition contract with a deterministic prototype before production refactoring.
