# Prepared writer commits and fair gate handoff

Status: reservation direction consolidated, 2026-09-10. Unnumbered Publisher tickets, the short group-commit gate, a per-writer configurable preparation limit (default one per instance), and an ordered preparation ledger with head-only ticket admission are selected. Exact handoff synchronization, storage structures and public configuration APIs remain unimplemented proposals. See [admission state machine](admission-state-machine.md).

## 1. Two distinct gate objects

Separate a FIFO admission record from the physical metadata gate. A request may own the next turn without holding the gate or writer execution rights. The head request's entitlement persists while it waits for its writer turn. New requests cannot bypass it.

Each retained gate request includes request identity, lifecycle/wait generation, operation kind (commit or metadata snapshot), target context reference, queue link and a pre-reserved wake/completion record. Include snapshot requests in bounded fair service; otherwise continuous commits can starve heartbeats. Actual snapshots copy bounded metadata only, with membership digests prepared separately; serialization and send happen later.

Conceptual states: QUEUED -> ENTITLED -> ACTIVE -> FINISHED, or QUEUED/ENTITLED -> CANCELLED. These are scheduling states, distinct from the request's irrevocable commit decision. Physical gate acquisition alone does not cause a write effect.

## 2. Handoff protocol

1. Under a short admission gate, append once to the FIFO. If there is no active request or entitlement, select the head and assign a unique entitlement generation. Publish its retained writer-ready notification as part of the synchronized handoff protocol.
2. Do not acquire writer execution while holding the admission/metadata gate. The notification joins the writer's ordinary ready FIFO. A direct path is permitted when both writer admission and gate entitlement are immediately eligible, respecting runtime budgets and older work.
3. When the continuation gets writer execution, validate the entitlement and prepared resources. Atomically claim ACTIVE and the physical metadata gate using a nonblocking try. If the short admission gate is occupied, register a generation-aware retry, release writer rights, and leave the entitlement in place. Registration and release notification must share synchronization; do not spin or repeatedly enqueue duplicate retries.
4. While ACTIVE, arbitrate cancellation/deadline, then either abort without sequence assignment or claim commit and perform bounded installation. Release the physical gate before output, callbacks or reclamation. Finish the gate request and transfer entitlement under the admission protocol.
5. Publish the next retained wake without allocating. Until publication is guaranteed, keep an explicit pending-publication obligation; an idle flag alone is insufficient. The concrete implementation must choose a gate ordering or embedded-record publication handshake before coding.

Cancellation of QUEUED/ENTITLED records removes or tombstones the record under admission synchronization and transfers the head entitlement once. A writer-ready event already published can still execute: its generation check turns it into a no-op, and its retained reference must be released. ACTIVE cancellation competes at the common effect boundary; cancellation loses after COMMIT_CLAIMED. No cancellation thread mutates writer-private history directly.

Entitlement can cause head-of-line delay, but it is not a mutex held across writer scheduling. Any eligible runtime executor can service the entitled continuation. Writer turns must be bounded and new writer-ready work cannot bypass it. If preparation is no longer valid and needs additional resources, release entitlement before registering the resource wait; do not retain the Publisher's next commit turn through a capacity wait. Ordinarily reservations should make this unnecessary.

## 3. Prepared change contract

Preparation runs under writer ownership as needed, outside the group metadata gate. Its result owns:

* Serialized payload or explicitly retained loan storage with the required immutability/lifetime.
* A history node/slot that can be linked without allocation or array growth.
* Reserved instance/history capacity, initialized instance metadata and stable index/link information.
* Preallocated bounded retirement bookkeeping for any replacement, plus output/completion scheduling credits.
* Retained endpoint/control-generation references and, when required, an unnumbered Publisher ticket.

Preparation must not evict publicly retained history merely to reserve a slot, consume a writer/group sequence number or report API success. Reservations remain valid while writer rights are released. Competing writes, ACK-driven cleanup and deletion must respect them.

KEEP_LAST needs particular care: preselecting a raw pointer to an eviction victim is insufficient if other operations can replace/remove that victim. Use retained identities plus a writer-private reservation protocol, or re-evaluate the bounded replacement at the final writer turn before entering the group gate. Per-instance accounting and indexed history avoid full-history scans. If revalidation discovers a new capacity wait, relinquish gate entitlement and return to resource admission. The exact reservation/index representation remains open.

Inside the gate, after all checks: claim commit, assign sequence metadata, detach any bounded prepared replacement, link the prepared change, update bounded writer/group counters and publish consistent installed progress. Record deferred cleanup; do not free payloads, scan proxies, enqueue one event per reader, or serialize packets here. Output readiness is a bounded coalesced record; fan-out occurs in later budgeted turns. A prepared commit requiring an unbounded number of removals is ineligible for this path until that operation is decomposed outside the gate.

No externally observable half-installed history is allowed. Writer ownership protects writer data; the group gate protects sequencing/progress metadata; snapshot users take compatible ownership and copy immutable results. Numeric sequence exhaustion must be checked before effect commitment, with failure behavior defined separately.

## 4. Close and resource conservation

### 4.1 Selected KEEP_LAST reservation direction

Reserve a logical history admission credit separately from physical storage. A replacement reservation claims the right to replace one retained change; it does not overwrite that change or lend its buffer to preparation. The new payload/node and deferred-retirement capacity have their own bounded memory budget. Logical depth one can temporarily require storage for old data, prepared new data and externally pinned retired data.

User-requested configuration direction: a per-writer limit on outstanding prepared history reservations per instance, default one. This is a ceiling for each instance of that writer, not a count of application threads or a writer-wide aggregate budget. Standard DDS-only applications receive the default. Any public setting belongs on the writer extension interface in `zzdds.idl`; the exact name, signature and configuration timing remain open. Acquire reservation rights after fallible payload preparation and before a Publisher ticket. Requests exceeding the limit remain resource waiters; other instances and writers can continue. This is not an instance mutex held by an application thread and does not block ACK/repair/timer processing.

The one-reservation path remains the initial simple baseline. Supporting values above one requires a bounded per-instance reservation ledger; merely raising a counter is incorrect. In particular, multiple reservations for depth one cannot each independently claim replacement of the same old entry. A candidate is ordered reservation positions, whose replacement entitlement advances through actual commit/abort decisions: aborting a predecessor must not invalidate a successor's guaranteed storage or require work inside the commit gate. This ledger, its interaction with Publisher gate ordering, and cancellation propagation require joint modeling before enabling higher values. A request whose commit still depends on predecessor resolution must not hold Publisher gate entitlement. Head-only ticket admission is selected below; exact scheduling and synchronization remain to be implemented.

The selected refinement uses head-only logical history admission: later ledger entries own prepared physical storage and their ordered place, not independent claims on the same history slot. Only the head may secure actual replacement/free credit, obtain a Publisher ticket and join the gate queue. Removing a cancelled predecessor advances the ledger without renumbering or transferring ownership of a successor's prepared buffer. The successor chooses the current eligible history entry when promoted, rather than storing a pointer to a predecessor's future sample. If policy/resources prevent promotion, it waits without a Publisher ticket or gate entitlement. Thus prepared successors may cross a coherent boundary if their eventual ticket admission occurs after close; preparation alone does not establish coherent membership.

On 2026-09-10, [reservation_ledger_model.py](reservation_ledger_model.py) explored two writes to one depth-one instance, one coherent close/reopen boundary, cancellation, split ticket/gate admission, installation, independent policy removal and delayed physical reclamation:

| Per-instance preparation limit | Physical node budget (including old sample) | States | Transitions |
| --- | --- | ---: | ---: |
| 1 | 2 | 1,723 | 5,006 |
| 2 | 2 | 1,759 | 5,141 |
| 2 | 3 | 2,379 | 7,772 |

All configurations preserved ledger bounds, exclusive buffer ownership, cancellation without resident-data removal, per-instance commit order and coherent-generation commit order. From every state, completion/retirement/reclamation remained reachable without cancelling any additional request. This assumes eventual service and policy-permitted removal/reclamation; it is not universal termination under arbitrary schedules. A constructed negative control admits the successor to the gate first and demonstrates that neither predecessor nor successor can commit. The head-only rule prevents that ordering.

The model combines the abstract ledger with Publisher gate order but not actual writer-context admission, atomics, stale wakeups or wire processing. It uses uniform-size nodes and fixed initial request order, and assumes replacement/removal eligibility; variable payload budgets, blocked durability/coherent retention, multiple instances and depths above one remain unvalidated. A larger three-request/sibling-instance exploration was interrupted for runtime cost, so no result is claimed for it. The prior handoff model provides separate writer-admission coverage; neither model establishes their full implementation composition. Increasing the limit permits more prepared work only when the independent physical budget allows it.

Higher configured limits permit preparation to overlap; they do not permit concurrent mutation of one writer history or bypass FIFO/resource fairness. They consume bounded prepared-payload/node/notification storage independently of DDS HISTORY depth and RESOURCE_LIMITS. Keep aggregate writer/runtime memory limits as separate admission constraints, including payloads prepared before a reservation is obtained. Do not promise improved throughput without measurement. Prefer bounded preallocated bookkeeping for configured capacity and define configuration-time failure when it cannot be provided; live resizing semantics are not selected. Until the ledger is implemented, reject unsupported values rather than silently clamp them or advertise support. The existing depth-one model validates only the default, not higher limits.

Under writer ownership, select either a free logical credit or a policy-permitted replacement identified by a stable node identity/generation. A retained entry claimed for replacement remains visible to repair until commit or independent policy removal. If independent removal becomes appropriate, detach that entry and atomically convert the reservation to a free-but-reserved credit. Never return that credit to the general pool while its request still owns it. Thus ACK/expiry cleanup can proceed without invalidating guaranteed admission or allowing a newcomer to steal the slot. ACK arrival alone is not permission to remove data needed for durability or another policy.

At commit, a replacement reservation detaches its still-live victim and installs the prepared entry; a converted/free reservation installs without a victim. Cancellation releases only the reservation: it leaves a still-live victim intact, or returns a converted free credit to the pool. It does not resurrect a change independently removed by policy. Per-instance reservation ownership ends after commit/abort updates are installed; payload reclamation can happen later through separate references.

Example, depth one: old A is retained; W reserves replacement of A; policy cleanup removes A and converts W's claim to a free reserved slot; newcomer N cannot take the slot; W either installs B or cancels and frees the slot. A saved raw pointer without this conversion protocol would be unsafe.

Track writer-total sample credit, per-instance credit, instance identity retention and physical-memory credit separately. Do not issue a Publisher ticket while waiting to assemble these reservations. Initially, if same-instance replacement/free admission cannot meet a writer-wide limit, leave the request waiting under the configured API resource policy; optional cross-instance eviction needs a separate audited policy and must not be improvised inside the commit gate. Coherent-set and durability retention restrictions are policy inputs to victim eligibility, not bypassed by this algorithm.

An indexed per-instance order and stable global sequence index are required for bounded detach/install. A monolithic ArrayList with scans and orderedRemove does not meet that requirement. Candidate structures include stable pool nodes with intrusive instance/global ordering plus a separately prepared sequence lookup index. No concrete container has been selected. Tests must include removal of a claimed victim, cancel before/after that removal, competing same-instance writes and physical-memory exhaustion with logical space available.

The [depth-one reservation model](history_reservation_model.py) passed 24 states and 43 transitions on 2026-09-10, checking exclusive logical credit, preservation of resident data on cancellation, no resurrection after independent removal, and a completion path from every state. It assumes replacement eligibility and available prepared physical storage; it does not validate physical memory limits, actual QoS eligibility, indexes or synchronization. It is separate from the handoff model and not an integrated end-to-end commit test. KEEP_LAST/resource behavior is informed by [DDS 1.4 sections 2.2.2.4.2.11 and 2.2.3.18](https://www.omg.org/spec/DDS/1.4/PDF); the proposed reservation mechanics are implementation choices.

Coherent close stops new generation tickets but retains service for existing commit/cancellation records. Ticket retirement follows installation or completed abort bookkeeping. Gate-turn retirement and Publisher-ticket retirement are separate: handing off the gate does not by itself tell coherent close that all accounting is complete.

Every request owns a ledger of reservation, history/payload references, ticket and scheduling credits. Commit transfers payload/history ownership to the cache; abort releases preparation ownership. Cleanup and stale wake consumption return remaining credits exactly once. Endpoint deletion cannot reclaim state still retained by either path.

## 5. Executable validation and remaining coverage

The [extended finite handoff model](commit_handoff_model.py) was run on 2026-09-10 with one and two logical executors:

| Executor limit | Reachable states | Transitions |
| --- | ---: | ---: |
| One | 2,673 | 9,613 |
| Two | 3,137 | 12,545 |

Both configurations passed assertions for unique physical gate ownership, writer ownership during gate use, FIFO commit order, cancellation excluding installation, reservation transfer/release, and at most one publication/queued/running notification reference per request. Every state has a path to sealed coherent close and fully consumed wakeups. This is an existential progress check, not a fairness proof or actual threaded execution. The model begins with two preissued tickets, one per writer, and older background work in each writer queue. It splits entitlement selection, wake publication, writer execution, commit claim/installation, resource cleanup and ticket retirement into separate transitions.

A wakeup litmus checks both orderings of atomic predicate-registration versus producer release. Its negative control splits predicate checking from registration and demonstrates a stranded waiter. The main model does not implement an admission mutex, failed physical try-lock or actual memory ordering; the litmus is a separate abstraction of the required handshake.

The explored schedules permit coherent sealing before all stale cancelled wakeups are consumed. This is intentional: ticket completion accounts for the publication boundary, while queued wakeups retain their own references and scheduling obligations. Entity reclamation and runtime shutdown must wait for those separate obligations. A generation check alone prevents stale mutation but does not provide memory safety without retention.

Extend the existing [finite model](commit_gate_model.py) with separate writer FIFO, entitlement, ACTIVE gate state, stale notifications and resource ownership. Required schedules include cancellation immediately before/after entitlement publication, busy writer with an entitled commit, snapshot behind repeated commits, replacement victim removed during preparation, close during delayed ticket retirement, and abort with an already-enqueued writer wake.

The extended model covers the two-ticket handoff/cancellation portion above. Remaining coverage includes snapshot fairness under repeated submissions, obsolete generations after re-wait, concrete replacement-victim invalidation, resource re-wait after entitlement, failed try-acquisition integrated with actual wake registration, and external queue saturation. Explicitly model these before claiming the full preparation contract is validated. Then implement a small synchronization prototype with one driver and multiple executors. No wall-clock latency or production memory-ordering guarantee follows from the finite models.

The Zig [synchronization prototype](concurrency-prototype.md#metadata-snapshot-slice)
now exercises shared FIFO snapshot/commit admission with bounded write bursts and
a threaded partial-installation checkpoint. This adds concrete finite-workload
evidence; indefinite request reuse and the remaining finite-model cases above
are still open.
