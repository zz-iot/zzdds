# Blocking waits and closure: L5 decision matrix

Status: operation-policy consolidation, 2026-09-15. Existing callback, writer commit
and deletion decisions remain authoritative. Linked wait contracts and result-mapping
direction are accepted; concrete variant/runtime integration remains an audit gate.
See the [consolidated contract](concurrency-contract.md) for remaining policy work.

## Common boundary

Callback and foreign-preparation chains retain their exclusion/lifetime obligations
while waiting. Release endpoint turns and short metadata locks before waiting.
Internal protocol, timer, lifecycle and condition progress can run without dispatching
automatic listeners on that nested stack. Explicit delegation is its own accepted
exception. The waiter may help only runtimes covered by the configured progress
contract; attaching a condition does not implicitly authorize arbitrary foreign
runtime execution.

Each operation needs one retained request identity, one absolute deadline if applicable,
and one terminal result. Retry, thread migration and spurious wakes do not restart
the deadline. Resource and callback-preparation retries use the accepted budgets
(two preparations per turn, eight stale validations per explicit candidate, automatic
resource backoff from 1 ms to 1 s). They do not introduce timeouts into DDS operations
that have none.

## Operation matrix

| Operation | Completion predicate and progress | Retention while waiting | Remaining decision |
| --- | --- | --- | --- |
| DataWriter.wait_for_acknowledgments | Accepted fixed committed-write/association frontier; ACK or logical unmatch retires obligations; ACK/repair processing independent of listener execution | Writer lifetime, captured frontier/association obligations, deadline and wake | Policy accepted and bounded race model checked; production capture, timer and closure integration remain |
| Publisher.wait_for_acknowledgments | Accepted fixed membership and independent per-writer captures; all child obligations complete; no implicit resume/end | Publisher plus retained writer/frontier set and uncaptured-child placeholders; one shared deadline | Policy accepted and bounded aggregation model checked; concrete capture/completion handoff remains implementation work |
| Reliable write and lifecycle variants | Commit after required history/preparation resources and coherent admission are available | Accepted head-only reservations, request identity and operation deadline; no held commit gate while waiting | Map each variant's resource/deadline/close result; distinguish remote delivery from local commit |
| DataReader.wait_for_historical_data | Accepted known-source capture and finite per-association boundary; protocol accounting plus final DDS processing outcomes; empty set OK | Reader, retained transfer evidence/local work and one deadline | Direction consolidated and bounded model checked; provider evidence, receive/admission fixes and runtime integration remain implementation work |
| WaitSet.wait | At least one attached condition observed triggered, or deadline | WaitSet and safe condition registrations; callback rights remain held | Cross-runtime helping, condition detachment/deletion, shutdown, and exact concurrent-wait rule |
| read/take and loan publication | Local access/loan commit, with applicable presentation and lifecycle admission | Reader/access period and short request ownership; release turns for any reservation wait | No invented wait-for-data behavior; precise closure and reservation results for each API |
| return_loan | Return resources to their valid owner | Retained loan/owner identity | Must remain serviceable during preflight; invalid/double return follows API rules |
| set_listener | Publication, plus external retirement frontier when required | Captured retired registration obligations | Capacity/error mapping; callback/preparation-chain calls do not drain |
| Single/parent/bulk deletion | Accepted logical close and context-dependent application-access drain | Selected lifetime/frontier and reserved cleanup capacity | Final competing-operation result mappings; no wait for outstanding-loan return to make preflight pass |
| notify_datareaders | Accepted bounded candidate traversal | Chain, candidates and current admission/preparation obligations | Existing ERROR/partial-progress rules apply; ordinary contention has no new timeout |

DDS 1.4 describes writer ACK waiting in section 2.2.2.4.2.15, historical waiting in
2.2.2.5.3.32 and WaitSet waiting in 2.2.2.1.6.3. Their timed completion predicates
are different; satisfying one is not evidence that application listener processing
has completed. WaitSets can span participants and are not participant-created entities.
[OMG DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

## Proposed closure/result principles

* A terminal success or committed mutation is not retroactively changed to deletion
  failure because close happens before the caller wakes. Mutation commit and wait
  completion are distinct boundaries; a successful write is not proof of delivery.
* If logical entity close wins before an uncommitted operation can complete, recommend
  ALREADY_DELETED for ReturnCode_t operations where the closed lifetime is safely
  recognized. Entity-creating APIs use their defined failure representation. Do not
  dereference arbitrary stale handles merely to manufacture this result.
* A stopped runtime with a still-live entity is not automatically a deleted entity.
  Recommend ERROR if it irreversibly removes the operation's required progress,
  unless the particular API defines another result. A merely idle/manual runtime
  has not failed; its configured driver/helping contract determines progress.
* Do not let deleting an attached condition masquerade as deleting the WaitSet.
  Update attachment eligibility and wake/recheck using its own rules; choose the
  WaitSet shutdown result separately from entity deletion.
* Resolve success, deadline expiry and close under one request completion protocol.
  Specify the deadline boundary for each predicate; do not use wake-delivery order
  as evidence of which event happened first. A delayed caller can observe a success
  already committed before its deadline. Tie rules remain to be fixed with the
  operation-specific frontier.
* Only reject a known dependency if the middleware can establish that retained
  rights prevent its completion. Arbitrary application locks, GuardCondition setters
  or peer application behavior are not inferable from an operation name. A finite
  deadline remains useful even when the library cannot detect the dependency.

These principles do not yet constitute a blanket whitelist of blocking calls from
callbacks. For example, ACK receipt may be protocol-driven, but a full remote history
can depend on application consumption; a local GuardCondition can depend on the same
callback that is waiting. The library must not promise eventual success for either.

## Bounded next sequence

1. Define DataWriter ACK-wait write/association frontiers and match/unmatch/close races.
   Use that as the first concrete completion-versus-timeout case. The proposed
   [writer ACK-wait contract](writer-ack-wait.md) records the source audit, accepted
   boundaries and bounded race validation. This decision is complete; production
   validation remains an implementation task.
2. Lift the contract to Publisher scope, preserving one deadline and the accepted
   coherent admission model. The [Publisher ACK contract](publisher-ack-wait.md)
   records accepted fixed membership with per-writer captures, child-close ERROR,
   no implicit resume/end and bounded aggregation validation. This decision is
   complete; concrete runtime integration remains an implementation task.
3. Resolve WaitSet and historical waits, including manual/cross-runtime progress.
   The [historical-data investigation](historical-data-wait.md) now records current
   first-heartbeat/ever-matched behavior and accepted fixed known-source scope,
   including immediate OK for an empty captured set. Receive-versus-protocol
   completion uses the accepted receive-processing direction. Reliable-transfer
   boundaries/departure direction and best-effort timeout risk are selected in that
   document; bounded transfer validation passes 59,320 scenario-states and 182,540
   transitions. Best-effort alone does not
   make the wait unsupported or complete without evidence.
   The [WaitSet proposal](waitset-wait.md) separates standard single-waiter/live
   attachment rules from proposed observation, lifetime and helping boundaries.
   Temporary result ownership across concurrent detach/delete is accepted and
   bounded-model checked (316 scenario-states, 878 transitions). Concrete binding
   integration remains a follow-up. The request/wakeup model now passes 3,724
   scenario-states and 11,054 transitions. Explicit non-draining close and factory-less
   helping configuration are finalized in the [close/progress contract](waitset-close-progress.md).
   Concrete runtime wiring and generated binding integration remain untested.
4. Complete operation-specific lifecycle/read/write mappings and integrate the runtime
   wake/timer/closure interface. Binding retry timers are one client of that interface.
   The [remaining result mappings](operation-result-mapping.md) consolidate effect,
   deadline, loan and deletion rules, now accepted as the mapping direction, and
   identify concrete audit gates. Next follow the consolidated contract's remaining
   identity/nesting and runtime/transport decisions.

Do not create another full runtime prototype just to fill the table. Add bounded
traces only for uncertain frontier, completion or progress interactions. This is the
remaining listener/runtime contract work before the concurrency specification can
be consolidated for implementation; broker revision need not await production refactoring.
