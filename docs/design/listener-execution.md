# Listener execution contract

Status: accepted behavioral baseline, consolidated 2026-09-17. Section 13 and its
linked accepted contracts supersede historical Proposed/Open investigation wording
in earlier sections. Concrete ABI and future placement policies remain separate.
No production implementation or OMG requirement is implied by this zzdds contract.

Related: [concurrency design](concurrency-model.md), [current thread model](thread-model.md), [discovery broker proposal](discovery-broker.md).

## 1. Purpose and API boundary

**Agreed.** Provide predictable callback serialization, ordering and lifetime behavior while preserving direct, low-latency delivery. Standard DDS-only applications must get useful defaults without using extension methods. Threaded and application-driven backends must implement the same observable listener contract; their placement and timing may differ.

OMG operations belong in `dcps.idl`. New application controls for callback groups, executors, affinity, or driving progress belong on zzdds extension entity interfaces in `idl/zzdds.idl`. Generate bindings from that IDL rather than hand-editing generated surfaces. No public listener-identity accessor is currently proposed. Internal binding support for identity must not require inventing an operation on an OMG interface.

**Agreed.** Distinct reader listeners under the same Subscriber remain independent by default. A shared listener or an explicitly configured group can provide broader serialization. A Subscriber is not automatically one execution group for all its children.

## 2. OMG boundary

DDS 1.4 §§2.2.4.2–2.2.4.3 define status reset behavior, the most-specific enabled listener for plain statuses, subscriber-level precedence for data notifications, and permitted aggregation of status changes. These sections do not prescribe a general listener-object mutex or executor. This proposal adds an explicit execution contract while preserving those semantics. [DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

`Subscriber::notify_datareaders()` invokes eligible reader listeners and is expressly intended for use from `on_data_on_readers()`. Explicit delegation therefore needs distinct treatment from accidental callback re-entry. Callback count is not sample count: DDS does not require a callback for every individual change. [DDS 1.4 §§2.2.2.5.2.11, 2.2.4.3.2](https://www.omg.org/spec/DDS/1.4/PDF).

Do not describe this contract as an OMG-mandated threading model or as proof of general DDS conformance. Data access ordering and coherent presentation remain responsibilities of DDS history/presentation processing, not of the callback scheduler.

## 3. Terms

| Term | Meaning |
| --- | --- |
| Entity generation | A particular live entity lifetime; prevents pending work from targeting a reused handle |
| Listener identity | A stable identity for one application listener instance across methods and registrations |
| Registration generation | One installation of a listener and mask on an entity |
| Callback group | Explicit shared exclusion domain for listeners that access related application state |
| Dispatch eligibility | Relevant status is pending, listener selection is valid, and ordering/lifetime conditions permit invocation |
| Execution rights | Scheduler ownership of the entity, listener and optional group needed for a callback |
| Automatic invocation | Callback initiated by middleware status/data processing, including nested protocol pumping |
| Explicit delegation | Application-requested listener invocation through `notify_datareaders()` |

Serialization means no overlapping automatic invocations in a shared exclusion domain. Non-reentrancy also excludes nesting on the same thread. Neither implies fixed thread affinity. Execution rights are scheduler state, not entity/protocol mutexes held while executing user code.

## 4. Default behavior

**Agreed requirements:**

1. Automatic callbacks for one entity are serialized across methods, including callbacks resolved through parent listeners.
2. Automatic callbacks to the same identifiable listener instance are serialized across registrations and methods. Shared listener identity across bindings is a release gate, not a property supplied by today's `ListenerBox`.
3. Different listeners on different entities may execute concurrently unless explicitly grouped. Sibling readers do not inherit subscriber-wide exclusion.
4. A blocking operation inside a callback does not implicitly release its execution rights or permit automatic re-entry.
5. Eligible automatic callbacks run inline by default when execution rights are immediately available and there is no earlier pending work they must follow. No mandatory worker handoff or queue allocation is introduced on the uncontended path.
6. No stable OS-thread affinity is promised by the default. A later callback may execute on another worker after the previous one finishes.
7. Notifications reflect committed DDS state. No user callback runs while an entity, history, transport, or protocol-state mutex is held.
8. Listener and entity lifetime protections remain in force while a callback executes or explicit delegation retains them.

The blanket lock rule in item 7 is a target requirement and requires a call-chain audit. Dropping the reader lock is insufficient if the caller still holds a participant or subscriber lock.

## 5. Inline path and pending work

**Proposed mechanism, preserving the agreed fast path:**

1. Under state ownership, commit the relevant state change, update status/conditions and publish notification eligibility/order.
2. Select the applicable listener through DDS routing rules. Atomically coordinate eligibility, registration generation and execution-right acquisition.
3. If immediately eligible, consume the appropriate status at the dispatch boundary, retain required objects, release internal locks and invoke inline.
4. Otherwise retain bounded pending status work. Do not block a receive worker waiting to enter a busy listener.
5. On callback return, release execution rights and recheck pending work without a lost-wakeup window. Continue inline within a fairness budget or schedule continuation.

Multiple overlapping exclusion domains require an all-or-retry reservation protocol or equivalent scheduler coordination. Do not acquire blocking listener/group locks one at a time across user code. New arrivals cannot bypass already eligible earlier work merely because they arrived on a faster worker.

Pending work should normally identify an entity/status and relevant generations, rather than copy an unlimited event log. Allocate reusable pending storage at entity/registration creation where practical. Overload must not silently erase accumulated status counters or cause unbounded allocation. Precise limits and failure reporting require the resource-policy design.

**Agreed.** A low-latency build must not disable serialization, ordering or lifetime guarantees. Build-time specialization may eliminate synchronization only when exclusive execution is established, including interrupt/other-core boundaries. Different executor availability or default placement is acceptable; different safety semantics are not.

**Proposed extension policies:** inline-when-eligible, designated-executor dispatch, and application-controlled dispatch. Affinity can prohibit inline execution on the current worker. These are placement policies, not alternatives to serialization. Names and IDL signatures remain open.

## 6. Notification order and status consumption

The [notification boundary](listener-notification-boundary.md) refines
delegation to fixed reader membership with current-status checks per claim. It also
separates reader and Subscriber read-status reset rules. This refinement is accepted.

**Agreed.** Assign local notification ordering while committing the relevant DDS state, before worker scheduling can reorder dispatch. There is no global chronological order across unrelated entities and no promise that callback order reproduces wire arrival or sample order.

**Agreed.** Treat pending notifications as requests to observe status. At actual dispatch, atomically read the current applicable status, prepare owned callback arguments, and perform the required status reset before entering application code. Concurrent status getters and callback dispatch share the same status-consumption synchronization. A getter may consume changes before a pending callback becomes eligible; the dispatcher must reevaluate eligibility rather than play stale arguments.

Changes arriving during a callback create a new pending generation. Completion of the old callback must not clear those changes. For `DATA_AVAILABLE`, new arrival/instance-state changes during execution must not be lost; unchanged unread cache contents alone must not create a self-sustaining callback loop.

Plain status aggregation must preserve each status's counters and current-value semantics. If several events collapse into one notification, the result is an observation of current state, not a historical event replay. Coalescing across status kinds can obscure intermediate transitions; the cross-kind ordering/aggregation baseline is now **Agreed**, as detailed below.

The accepted [status-ordering policy](listener-status-ordering.md) specifies independent
per-kind coalescing, first-eligible-pending order per source entity, and current
arguments/reset at claim. It records getter, zero-net-change, registration and
explicit-delegation boundaries. A bounded plain-status fixture validates the core
ordering and counter rules; routing/registration integration remains unimplemented.

**Proposed.** Guarantee that required association/history changes are committed before notifications relying on them are eligible. Do not promise one match callback before every data callback: aggregation, listener masks and status getters complicate that statement. Specify any stronger ordering only after deriving it from concrete cases.

## 7. Listener identity across bindings

The [identity decision note](listener-identity-decision.md) now recommends a shared,
reclaimable identity domain across runtimes in one library instance and records the
updated binding evidence. Its scope and lifetime recommendations remain proposed.

**Open, high priority.** A function address is not an instance identity. A per-entity `ListenerBox` is a lifetime container and is also not sufficient: multiple boxes can refer to one application listener.

| Binding shape | Proposed approach / required verification |
| --- | --- |
| C and Zig callback structs | Investigate non-null `listener_data` as an application context identity with an appropriate lifetime token. Reused addresses must not inherit retired identity state. Null-context listeners require an explicit documented registration identity rule; identical function tables do not prove shared application state. |
| C++ listener objects | Preserve complete object identity across generated adapters and inherited interface views; test base-pointer adjustment and repeated installation. |
| Java listener objects | Canonicalize Java object identity across separately created native contexts/global references. Native wrapper address equality is insufficient. Registry ownership, synchronization and reference release need design. |
| Standard and extended listener views | The same object registered through DDS and ZZDDS views must retain one identity where their methods share state. |

The identity mechanism must work without an application using a zzdds extension. Explicit groups address relationships between *distinct* objects; they must not be the only way to make a genuinely shared listener safe. For representations with no recoverable instance identity, document the default's exact scope and the extension needed to express sharing. Do not infer aliasing from arbitrary global state used by callback code.

Identity scope across multiple factories/runtimes in one process remains **Open**. Per-runtime registries cannot provide process-wide shared-object exclusion without coordination. Choose the guarantee and ownership cost explicitly; avoid an accidental immortal process-global registry.

## 8. Explicit delegation

The accepted [delegation contract](listener-delegation-decision.md) specifies
synchronous child dispatch with bounded dependency tracking and cycle rejection.
Two bounded models now cover admission and replacement/removal. The note also
records accepted generation-aware recursion checks, a participant-configurable finite
nesting limit (default eight active delegation calls, with build-time-changeable
defaults), and ERROR with partial-completion semantics. The note is authoritative;
cross-participant limit composition remains to be specified. The accepted
[selection policy](listener-selection-audit.md) bypasses reader masks for explicit
delegation, uses no parent fallback, and preserves status when no callback exists.

**Agreed.** `notify_datareaders()` must remain usable from `on_data_on_readers()`. It is not permission for unrelated automatic callbacks to re-enter.

The [shared Subscriber GROUP access contract](concurrency-model.md#43-agreed-shared-subscriber-group-access-brackets) is selected for the initial design. Callback access guards must preserve the shared period independently of explicit application begin/end depth. Delegation admission follows the accepted cycle-aware contract; consumption remains shared. GROUP-specific access machinery must disappear when that optional profile is compiled out.

**Agreed.** Model delegation as a synchronous child dispatch under an execution token owned by the calling callback chain. It may inherit execution rights already held by that chain, including a shared group/listener, while ordinary automatic dispatch remains excluded. Retain each target reader, select eligible callbacks by DDS rules, and invoke without a subscriber lock. Delegation preserves eligible reader/status handling; it does not manufacture a sample-order guarantee.

**Accepted policy summary:**

* Busy children use all-or-retry admission with ownership and older-queue dependencies;
  a new cycle returns ERROR. Earlier child effects remain committed on failure.
* Explicit children inherit same-chain rights; automatic reentry remains excluded.
  Active-Subscriber and active-reader recursion are rejected.
* Nesting has a participant-configurable finite limit, default eight with build-time
  defaults. Creation-time mutability and cross-participant limit composition remain proposed.
* Capture reader membership once, then recheck current status and registration per
  claim. Visit each reader once; do not chase new arrivals until the Subscriber is quiet.
* Explicit selection ignores reader masks, uses only attached reader callbacks and
  preserves status for absent callbacks. Replacements withdraw unclaimed admission;
  claimed invocations retain their registration and may finish.

These rules are specification choices with bounded evidence. Production queue,
status, binding and lifecycle integration is still required.

## 9. Blocking operations and progress

**Agreed.** Starting a wait does not free the current callback's execution rights. Internal ACK processing, timers and condition updates must be able to progress independently of application listener dispatch.

**Proposed starting policy.** A nested pump advances protocol work and condition evaluation but does not automatically invoke further callbacks on that call stack. Other workers may run independent groups. This avoids cross-group stack growth while allowing many useful waits; allowing nested automatic dispatch to unrelated groups is an optional later policy, not required for the first design.

| Operation/context | Analysis needed |
| --- | --- |
| Wait for reliable ACKs | Often protocol-driven, but repair/backpressure or local delivery can depend on application work. Audit rather than whitelist by method name. |
| Reliable write with a full history | Progress can require ACKs, resource release or application consumption. Establish the specific predicate and timeout behavior. |
| WaitSet wait | Condition updates can be protocol-driven; a GuardCondition may depend on another callback. Preserve standard WaitSet rules and evaluate predicates without dispatching listeners merely to wake a waiter. |
| Delete or replace from a callback | Must not wait for that same callback to finish; see lifecycle proposals below. |
| Waiting for another callback in an occupied group | Cannot complete while exclusion is retained. No executor can guarantee progress for that dependency. |

Only implement documented, audited wait paths. Preserve standard timeout/error semantics; do not invent a universal `PRECONDITION_NOT_MET` rule without checking the operation. Detect internal self-waits where possible. Arbitrary application dependency cycles are not generally detectable. A nested wait may delay the outer pump's return; its deadline is not preemption of application code.

## 10. Replacement, deletion and ownership

The accepted [post-entry callback-failure policy](listener-callback-failure.md) requires binding-local
exception containment, continued automatic scheduling, and ERROR/partial completion
for explicit delegation. It separates post-entry exceptions from pre-entry conversion
failure; optimistic prepare/validate/commit with bounded retries and preparation-chain
lifetime handling is now accepted. Preparation recursion protection and the irrevocable dispatch-attempt boundary are
also accepted: preparation/validation failure consumes nothing; failure after commit
does not roll status back even if listener-body entry is uncertain. Retry budgets remain open. ABI outcome plumbing
and lifecycle-hook failure handling still require their detailed binding contract.

The accepted [parent/bulk deletion contract](listener-bulk-deletion.md) distinguishes
strict empty-parent deletion from recursive cleanup and requires no partial logical
deletion on ordinary preflight failure. Concrete subtree admission remains a design task.
Its accepted frontier refinement covers previously detached descendants while
waiting for application-access retirement independently of physical reference counts.
External bulk calls on a surviving root capture a finite descendant frontier; new
children after commit do not extend it. Bounded frontier validation now covers 385
states, including negative controls for lost ancestry coverage and completion holes.

The accepted [reader-deletion direction](listener-deletion-decision.md) provides
external application-access quiescence and permits callback-context logical deletion
without callback-drain waiting. Operation-race details require validation; parent/bulk
deletion and binding unwinding remain separate.

**Replacement/quiescence policy accepted for the initial design.** The
[quiescence contract](listener-quiescence-decision.md) is authoritative: ordinary
application calls drain a captured frontier of old registrations; calls from any
zzdds callback chain publish without waiting. The frontier includes older retired
registrations, and quiescence covers remaining application-context accesses and
release hooks. Single-reader deletion is accepted as described above; broader
deletion and binding details remain open.

* Listener replacement publishes a new registration generation. Already claimed callbacks may enter and finish; unclaimed work must not start on the retired registration. Pending status is reevaluated against the current listener/mask and hierarchy. Replacement itself does not erase unconsumed DDS status.
* The old listener's retained resources survive active callbacks. A callback-context asynchronous `set_listener` return does not imply quiescence;
  the accepted external-call frontier provides the standard-only management boundary. For application-owned C/C++ contexts, a precise disposal/quiescence contract is necessary; `ListenerBox` alone cannot keep application-freed memory valid.
* Entity deletion closes admission of new operations/callbacks and invalidates pending work. Single-reader deletion fails if loans or attached Read/QueryConditions exist; their publication must be coordinated with close. Callback-context deletion defers retirement of claimed uses. Logical deletion ends public API usability even while internal storage remains retained.
* A quiescence barrier or deferred-release notification, if needed, belongs in `zzdds.idl`. Standard-only applications still need a documented safe listener-lifetime pattern and the existing binding ownership rules.
* Callback exceptions/unwinds must not escape incompatible ABI boundaries, strand execution rights or skip reference release. Binding-specific exception reporting and recovery remain open.

Resolve these policies with the generated binding ownership model before promising no callbacks after a particular API returns. Listener identity lifetime, registration lifetime, entity lifetime and callback argument lifetime are distinct.

## 11. Current implementation evidence

Inspected zzdds `eaaa55a` on 2026-09-09. This is targeted source inspection, not a full concurrency audit.

* `src/util/listener_box.zig` retains a listener installation across in-flight dispatch/replacement; it contains no execution gate or cross-registration identity.
* `src/util/listener_lifecycle.zig` describes binding-owned Java contexts and application-owned C/C++/Zig contexts.
* `src/dcps/reader.zig::dispatchListener` invokes directly and follows the enclosing-listener chain.
* `notifySubscriptionMatched` snapshots counters, invokes the listener, then clears counters. The new contract requires consumption before entry and protection against clearing later changes. This path needs a focused correctness audit independently of executor work.
* `src/dcps/subscriber.zig::vtNotifyDataReaders` dispatches while holding `subscriber.mu`; it needs refactoring for the target lock contract.
* `zidl/src/backend/java.zig` emits native listener contexts and reference-release machinery. Identity across installations is not established by those allocations.

## 12. Acceptance tests and next decisions

Run the same semantic fixtures through inline, deferred and manual execution. Test shared listener methods across readers and parent fallback, independent sibling listeners, concurrent status getters, new arrivals during callbacks, registration changes and destruction. Record entry/exit traces and assert no prohibited overlaps, stale generations or lost pending work.

Explicit delegation fixtures must cover shared parent/child identity, target contention, recursive calls and deletion during traversal. Wait fixtures must distinguish pure protocol progress from dependencies on blocked callbacks. Race/TSan coverage applies to threaded builds; deterministic scheduling and fake clocks cover manual execution. MCU validation must include bounded queues, stack depth and interrupt ingress.

Benchmark receive-to-callback latency, cache-to-callback latency, allocations and cross-thread handoffs in the uncontended path; then measure tail latency and protocol progress with busy/shared listeners. The requirement is no mandatory handoff, not an unmeasured numeric latency promise.

## 13. Consolidated decision register and finish line

This register supersedes historical "next decision" language in investigation notes.
Accepted policy is not a claim that production code implements it.
For the 2026-09-15 suite-wide checkpoint and remaining policy work, see the
[consolidated contract](concurrency-contract.md).

| Area | Accepted baseline | Remaining application-visible decision | Implementation evidence still required |
| --- | --- | --- | --- |
| L1 identity | Shared identifiable listener exclusion; independent sibling listeners; standard-only defaults | Scope and binding defaults accepted; ABI representation remains an integration gate | C++ canonical views, Java wrapper aliasing, null contexts, address reuse, registry capacity and ABI plan |
| L2 status | Per-kind current aggregation; first-eligible-pending automatic order per source; claim-time reset; getter invalidation; distinct reader/Subscriber reset rules | No further core ordering choice identified; operation-specific reset edge cases and routing audit remain | Plain/read status integration, last-handle/policy arrays, registration catch-up and cross-owner publication |
| L3 delegation | Synchronous bounded traversal, explicit mask bypass, no parent fallback, absent-callback preservation, cycle rejection, recursion limits, partial errors | Creation-time limit and minimum active/destination composition accepted; generated API integration remains | Larger/deeper dependency graphs, stale wakes, routing, retention and resource exhaustion |
| L4 lifetime | External setter drains retired frontier; callback-chain setter publishes without drain wait; context-dependent deletion drain; atomic subtree preflight; contained binding failures and bounded preparation | No new core lifetime choice identified; exact binding/variant error mappings remain audit gates | Setter/binding threads, release hooks, generation reuse, subtree integration and physical reclamation |
| L5 waits | Callback rights retained; per-operation ACK/history/WaitSet scopes and result mappings consolidated; scoped helping and non-draining WaitSet close | Settled by runtime ownership, retirement and bootstrap contracts | Actual ACK/history/WaitSet/deletion traces through manual and hosted drivers, plus variant-specific error mapping |

Authoritative supporting contracts:

* [Identity contract](listener-identity-decision.md): scope/binding defaults and nesting composition accepted.
* [Status ordering](listener-status-ordering.md) and [notification boundary](listener-notification-boundary.md): accepted L2/L3 state-observation rules.
* [Delegation](listener-delegation-decision.md) and [selection](listener-selection-audit.md): accepted L3 behavior; creation-time limits and their composition are settled.
* [Replacement/quiescence](listener-quiescence-decision.md): accepted L4 setter boundary, not a deletion contract.

The five Python listener models and the Zig retirement fixture are supporting
evidence. They cover different slices; their counts must not be added and presented
as coverage of one integrated runtime. Queue/wake implementations, binding fixtures,
TSan integration and benchmarks belong to implementation validation unless a
particular uncertainty blocks a policy choice.

The policy review is complete; see [concurrency readiness](concurrency-final-review.md).
The linked identity, status, delegation, lifetime and wait contracts now have explicit
outcomes. Remaining binding/backend/race checks are implementation acceptance gates.
Designated-executor/affinity extensions are deferred; they are not required for v1.

## Creation-time explicit groups — accepted 2026-09-16

The [extension surface](concurrency-extension-surface.md) records optional fixed
entity group membership through creation Configs. Listener replacement preserves
membership; groups supplement shared-listener identity exclusion and may span
runtimes in one core. No parent-to-child inheritance or thread affinity is implied.
Existing same-chain explicit delegation remains permitted under its admission rules.
