> Historical source snapshot, superseded by the consolidated contracts.
> Unaccepted alternatives and old completion statements below are not current policy.

# Concurrency fast paths and progress profiles

Status: revised execution direction, 2026-09-28. Controlling performance specialization
of the general admission model; implementation validation obligations are listed below.

## Ordinary operations

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

## TOPIC coherent completion

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

One reusable seal command is sufficient only with explicit monotonic pending-generation
coalescing and guaranteed rescheduling. One marker history slot is NOT enough to promise
unlimited closes without failure: earlier markers can remain unacknowledged. Reserve each
set's completion capacity before admitting its first effect. Reclaim marker storage only
when repair/retention obligations allow. Exhaustion backpressures admission of another set
under existing bounded operation rules, not the completion of an already admitted one.
Sequence capacity must also be checked before effects; never preassign a marker sequence
that later data would need to precede.

Use a retained Publisher close-scan obligation with a fixed membership frontier and
closed-generation high-water. Child publication/removal and frontier capture share a
short metadata synchronization boundary. Each writer has a pre-reserved seal command;
coalesce its pending generation by maximum. Scan in bounded batches without holding
Publisher rights while acquiring writer rights. Keep the current pass's frontier/cursor
stable while new closes accumulate a dirty rescan obligation; complete the pass before
restarting so churn cannot starve writers near its end. Retain membership nodes or stable
generation-checked handles until the scan releases them. Never retain an unprotected pointer.

A writer published during an open generation joins at its first committed effect, which
reserves completion capacity. If published after a captured close frontier it cannot
commit into that closed generation: its acquire observation sees the closed/new state.
A writer already executing a commit against the old open generation is covered by the
captured membership and seals after its turn. Deletion fences both scan and seal work,
retains required cleanup references and does not fabricate completion for an incomplete
set. Publisher deletion follows the same rule for its subtree. End closes metadata and
publishes/reserves the scan obligation, then returns without waiting for writer turns.

The finite model and seven additional traces cover close without another write, both
commit/close orders, nested begin/end, two writers, creation/deletion, coalesced generations
and full marker history. No claim of implementation fairness or concrete atomic correctness
follows. The scan's publication/retention handshake and actual RTPS completion-marker
encoding need integration tests. GROUP retains its shared-order coordination; do not copy
it into INSTANCE specialization.

## Helping and fairness

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

## Cooperative measurement profile

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

### Required footprint worksheet

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

## Bounded model checkpoint

`test/design-models/protocol_revision_model.py` explores two generations with one writer
and one/two marker slots. The retained writer turn excludes seal service; a coalesced
command carries the greatest closed generation. With capacity one/two, the model explores
81/69 states and 117/106 transitions. A negative control that permits sealing during the
writer turn loses close work and is detected. This establishes bounded safety/available
seal transitions, not scheduler fairness, multiple-writer membership, nested-depth behavior
or the RTPS completion-marker encoding. Seven additional explicit traces cover nested
and multiwriter/deletion schedules; actual synchronization and marker encoding remain
integration requirements.
