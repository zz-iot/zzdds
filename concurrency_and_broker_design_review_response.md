# Response to the concurrency and broker design review

Author: Codex, 2026-09-28. Response to the [independent review](concurrency_and_broker_design_review.md)
of zzdds PR #93 and zidl `concurrency-reference-support`.

**Status: discussion proposal for reviewer response and user decisions.** This document
records agreement, proposed work and remaining disagreements. It does not amend the
normative contracts, authorize a production refactor, or claim that the proposed remedies
have been implemented or validated. No review response has been posted externally.

## 1. Overall assessment

The review identifies real shortcomings in the package: chronological documents obscure
current requirements, fast-path costs are insufficiently specified, optimistic prepared
access has an unresolved practical progress risk, and presence refresh has an inadequately
specified scaling cost. My previous handoff overstated completion. Individual contracts
are substantially developed, but we should resolve these integration and presentation gaps
before treating the package as finalized.

I support a bounded revision, not a wholesale restart. The review's observations and its
suggested remedies need separate dispositions. Some remedies are promising; others alter
chosen guarantees or move complexity into different parts of the implementation.

The main architecture remains useful: take-turns ownership, shared manual/hosted progress,
listener exclusion with eligible inline execution, automatic runtime retirement, bounded
resource ownership, original discovery-byte retention, source coexistence and fenced broker
sessions. Neither document volume nor implementation difficulty alone establishes that
those choices should be discarded.

## 2. Document structure and merge scope (§2, §3.14, §5.12, §6.1)

**Agreement.** The guide's precedence rules do not adequately compensate for contradictory
sentences in documents implementers must read. Consolidation must resolve requirements,
not merely add another summary on top.

Proposed changes:

* Use a small normative set organized along the review's eight suggested subjects. Exact
  document count is secondary to each requirement having one authoritative home.
* Move investigations, superseded alternatives and dated audits into an explicit archive;
  retain rationale and evidence links from the current contracts. Preserve useful history
  rather than deleting it or requiring readers to reconstruct it chronologically.
* Use one status per normative document and a decision index distinguishing selected
  behavior, proposed implementation direction, deferred capability and unresolved decision.
* Correct all identified stale state-machine, metatraffic-forwarding, acceptance and
  configuration wording. The missing listener retry Config fields are a real omission.
  Listener stale budget eight and prepared-access budget four are separate policies,
  not conflicting values for the same setting.
* Replace personal paths and sibling-checkout-only links. Keep historical hashes/counts
  in a single dated evidence record rather than copying them into normative requirements.
* Separate the production SPDP domain-ID change and zidl allocator-forwarding fix into
  independently reviewable changes, with appropriate release notes and regression coverage.
  The handoff's “documentation only” sentence described that pass, not the whole branch;
  nevertheless, the branch's production effects must be explicit.

I favor dedicated design-validation targets/CI for maintained models and byte fixtures,
with disposable or obsolete probes explicitly classified as historical. Removing prototype
coverage from the normal production coverage/test aggregates is reasonable; leaving it
unexercised would not be an improvement. Moving files also needs coordinated runner/link
updates. None of this restructuring has been done by this response.

**Requested reviewer response:** Is this disposition sufficient, without prescribing exactly
eight files or treating every historical model as a permanently maintained test?

## 3. Concurrency performance and progress

### 3.1 Ordinary write/receive/send paths (§3.1–3.3, §3.13)

**Agree on the gap.** The spec should define when Publisher coordination is needed and show
an ordinary operation's path, including allocations, execution admissions, queue publication
and handoffs. “No mandatory handoff” alone is not an adequate positive performance design.

**Do not yet accept the proposed one-load fast-path algorithm.** A writer may observe an
unsuspended Publisher, then race with suspension/coherent-begin before committing. A
generation load alone does not close that race. We need an admission/validation protocol
that proves how the control boundary handles already-started writes. Conversely, not every
write needs the general prototype's full gate/ledger representation. Removing GROUP also
does not remove all Publisher controls.

Proposed work:

1. Specify uncontended, contended and control-transition traces for default QoS, with the
   exact eligibility conditions for bypassing each mechanism.
2. Set checkable operation-count targets for a named preallocated configuration, rather
   than promising zero allocations for arbitrary unbounded payloads/custom conversion.
3. Permit same-executor initial output after commit, outside protected protocol state and
   subject to bounded work. Same executor does not mean holding writer rights across I/O.
4. Specify bounded batching of committed, ready output and control coalescing, preserving
   deadlines and not imposing a batching delay on the latency-oriented path.
5. Reuse immutable serialized bytes across destinations where representation/protection
   permits; independently reserve and account for each send/completion. Receiver-specific
   protection may require distinct output, so “one serialization, N sends” is a target
   under stated conditions, not a universal constraint.
6. Clarify that runtime-wide fairness is a semantic obligation, not a mandate for a shared
   counter updated by every core. Per-executor budgets and shared readiness/deadline
   signals are candidates, subject to a starvation argument.

An application flush/batching API is a separate feature decision, not a prerequisite for
internal batching. Throughput, packets/sample, latency tails and allocation/handoff counts
belong in the acceptance matrix. TCP input isolation requires per-connection quotas and
aggregate bounds; physically separate pools are one option, not the only safe design.

**Requested reviewer response:** Can we agree on these contracts first, then validate the
minimal control-transition protocol instead of selecting the one-load bypass by assumption?

### 3.2 Hosted helping, priority and local progress (§3.4–3.5, §4)

Hosted helping can introduce jitter and run unrelated work on a latency-sensitive caller.
I favor an explicit policy permitting such callers to avoid it. Manual mode still needs
its documented progress mechanism. Owner-only helping can miss dependencies; disabling
helping requires a guaranteed background path through callback waits, shutdown and cleanup.

Proposed decision: determine runtime/participant policy placement and default after checking
these dependencies. Recovery must run without an application waiting on readiness; a wait
observes and may help recovery, but must not be its only driver.

For priorities, document inversion and preserve a scheduler-policy extension point. I do
not yet support mandatory two-class scheduling, strict priority, or treating DDS transport
priority as automatically equivalent to protocol execution priority. A low-priority gate
owner can block higher-priority work even if the gate hold itself is short. Class isolation
or inheritance requires a concrete policy, not merely adding a field.

Broker reconciliation should be staged in bounded turns with a short validated visibility
commit. Ensure local work gets fair progress during remote view installation. Absolute
local priority could starve remote discovery; broker independence is not a promise of zero
shared-runtime contention.

**Requested reviewer response:** Which priority guarantee is essential to the first delivery,
and would an explicit extension seam plus bounded fair service suffice initially?

### 3.3 Prepared read/take (§3.6)

**Reopen this decision.** Repeated ERROR under ordinary contention is a serious usability
risk. The bounded model establishes safety properties; it does not establish acceptable
progress or justify four retries as a practical default.

Several details of the review need qualification:

* Ordinary same-instance arrivals do not necessarily change generation ranks. Generation
  counters describe lifecycle transitions, not every new sample. Other selection/order
  dependencies can still cause real invalidation.
* The current contract already permits final metadata to be filled without failure at
  commit. It does not require every metadata field to be converted speculatively.
* DDS gives rank and view-state observation semantics; “compute everything at commit”
  needs a defined linearization/observation rule, not just a different calculation time.
  See [DDS 1.4 §§2.2.2.5.1.5–8](https://www.omg.org/spec/DDS/1.4/PDF).
* Native-language conversion is not necessarily non-reentrant: allocators, conversion
  hooks and cleanup may invoke foreign code. A safe native fast path needs an explicit
  non-reentrant capability/contract rather than a language-name test.
* Per-sample claims change what other consumers can observe. Skipping claimed samples
  requires rules for ordering, NO_DATA, rollback, expiry, GROUP visibility and reentrant
  access. Claims may be a good design, but do not eliminate the design problem.

Compare a certified bounded non-reentrant native path, narrower snapshot/validation rules
for general conversion, and per-sample claims. Specify behavior under continuous ingress
and competing consumers before choosing. Do not preserve ERROR exhaustion merely because
it was previously accepted, or introduce an exclusive fallback without naming its costs.

**Requested reviewer response:** Which remaining dependencies truly require retry after
immutable payload selection and a precise metadata observation point? Please distinguish
normal ingress from competing takes, lifecycle transitions and presentation changes.

### 3.4 Best-effort historical waits (§3.7)

**Retain the existing direction unless stronger evidence warrants changing it.** The user
explicitly accepted timeout risk when best-effort delivery cannot establish completion.
ACK wait and historical wait have different predicates. Automatically returning success
because acknowledgements are not required could falsely claim history was received.
DDS describes historical-wait OK in terms of receiving the historical data; it does not
establish the proposed equivalence with ACK wait.
[DDS 1.4 §2.2.2.5.3.32](https://www.omg.org/spec/DDS/1.4/PDF).

“Can never succeed” is too broad: empty-source completion and valid provider-specific
completion evidence are exceptions. We should prominently state which current transports
can provide that evidence and add migration/release notes for unmatched immediate return
when that behavior is implemented. Infinite waits still have the specified close/failure
paths. I do not recommend silently turning unknown historical completeness into OK.

### 3.5 Cooperative profile, listener stages and API scope (§3.8–3.12, §6.2–6.6)

Agree that the cooperative profile needs an explicit specialization table: synchronization
that disappears, lifetime/state bookkeeping that remains, allocation restrictions and
required peak-memory accounting. Define a named constrained profile with fixed storage
bounds/no unbounded allocation, and measure representative per-entity/sample configurations.
A single bounded allocator can be valid; not every pool needs an identical comptime API.

One thread does not eliminate reentrancy, deferred callbacks, loans, queued operations or
asynchronous transport references. Operational ownership and listener identity may simplify,
but cannot all become no-ops merely because execution is cooperative. Similarly, in-place
KEEP_LAST replacement is safe only when failure rollback, pins and repair obligations are
resolved. The memory worksheet should make its overlap costs explicit. Compressed hosted
binary size is not an MCU flash budget; define targets against a concrete build/target.

A MicroZig transport sketch is useful supporting work after choosing an actual backend.
A stub proving an unused Publisher type lacks a gate would provide little evidence;
compile-out tests should cover the production specialization when it exists.

Keep the listener contract while staging implementation. A shipped configuration exposing
shared listeners must satisfy their exclusion even before every binding is supported.
Resource-ready signals should accelerate preparation retries where dependable; generic
allocators need not provide such a signal, so finite fallback timers remain necessary.

Separate the complete designed extension surface from the first shipped surface. Advanced
runtime/resource/group interfaces may ship later without deleting their contracts, provided
standard DDS defaults and manual operation work correctly. Managed-reference support is a
substantial dependency, but ordinary scalar Config extensions do not all require it.

For zidl: split the real fix, preserve experimental gating, specify a promotion/renaming
path before ABI publication, and prioritize generic bounded owning/borrowed mappings. Do
not extend managed-reference provider indirection to hot-path entity handles without a
separate case. Probe runs without LeakSanitizer are not leak coverage.

**Requested reviewer response:** Which minimum cooperative configuration and first-shipped
extension set would you use to evaluate footprint without weakening the shared contracts?

## 4. Broker simplification and scaling

### 4.1 Presence and freshness (§5.1–5.2)

**Agree that recurring O(clients × visible participants) proof traffic and missing refresh
policy warrant a substantive decision.** Current bounds define failure behavior but do not
provide a complete operational scale model. Distinguish steady membership, churn, initial
synchronization and restart; VIEW_ALL distribution itself has unavoidable fan-out costs,
while recurring per-participant proof overhead is a separate design choice.

**Session liveness alone is not equivalent to current freshness.** Example:

1. An origin expires at the broker.
2. Its withdrawal is queued or delayed on the state path.
3. The observer continues receiving broker control keepalives.
4. A rule refreshing all records from those keepalives preserves obsolete membership.

Epoch/session/sequence fencing rejects old-session traffic; it does not show that the client
has applied a pending current-session withdrawal. This distinction also survives an ordered
state stream if freshness arrives independently of that stream's applied frontier.

Candidate direction: an aggregate, nonce-correlated freshness assertion tied to a specific
view frontier that the observer has actually applied, with a conservatively bounded validity
horizon. The broker must establish what that horizon guarantees about the included origins;
a live connection or frontier number alone is insufficient. Changing membership, short
origin leases, renewal propagation and backpressure need explicit traces. This is a proposal
for investigation, not a claim of an already-correct O(N) replacement.

If proofs remain per participant, specify refresh scheduling, bounded subset batching,
query rate limits and egress/storage formulas. Do not endorse the existing mechanism's
scalability without those numbers.

**Requested reviewer response:** Can an applied-frontier aggregate proof preserve the intended
stale-origin bound? What exact guarantee and failure trace would distinguish it from the
session-only proposal? If weaker stale-state bounds are acceptable, state that tradeoff.

### 4.2 Encoding, envelopes, stream placement and digests (§5.3–5.5, §5.8)

These are credible pre-freeze simplification opportunities. Compare them together:

| Proposal | Response and proposed next step |
| --- | --- |
| Final/appendable bodies | Compare bytes, code size and evolution behavior for actual messages. Mutable is not mandatory; final/appendable are not automatically compatible under arbitrary additions. Strict bounds, semantic validation and unknown-version handling remain necessary under any mapping. |
| Smaller established Envelope | Strong candidate, especially eliminating repeated domain-tag strings. Demonstrate that endpoint/channel association supplies the same authoritative context. Queued work must still retain epoch/session/generation fencing internally after decoding. Review endpoint lifetime/reuse and routing before removing redundant wire fields. |
| Ordered STATE boundaries and records | Probably the strongest structural simplification. Put ordering-dependent messages together while preserving independent control progress. This can remove classes of orphan staging, but not all transaction/retry/lifetime state. Specify head-of-line behavior and replacement/failure recovery. |
| Remove established magic | Consider as part of the compact format, after stating how endpoint demultiplexing and version validation identify the payload. Small savings alone do not justify a second accidental framing grammar. |
| Optional transaction digests | Lower priority. Inventory/snapshot hashes and bootstrap transcript hashes serve different purposes. Enumerate content-identity and resume dependencies before removal; reliable transport is not itself a proof of correct application assembly. CRC is not an equivalent replacement when collision resistance matters. |

No schema migration is proposed in this response. A comparison should show a representative
small delta, empty/control messages, snapshot traffic, decode work and memory—not simply
count fields or label reliable ordering “free.”

**Requested reviewer response:** Do you agree to prioritize STATE ordering and compact
session-bound envelopes, and evaluate body encoding/digests against the resulting protocol?

### 4.3 UDP bootstrap size (§5.6)

The ceiling/default relationship is an explicit limitation, not an internal contradiction:
a schema-valid message may exceed a configured path budget and fail preflight. However,
the usability concern is real. A common multi-interface participant should not unexpectedly
become unusable on the desired deployment path.

Choose a concrete UDP usability target and measure representative canonical SPDP sizes.
Reducing bootstrap feature bounds does not solve large SPDP samples. Post-validation
fragmentation or a compact prevalidation introduction changes the current sequence, because
its cookie already binds the canonical sample. Client-side fragment transmission also
imposes server parsing/reassembly costs; it is not only the client's resource problem.

Decide explicitly between the existing unfragmented deployment limitation and a bounded
validated-large-introduction design. No silent transport switch, field stripping or security
downgrade. This is a product decision, not a formatting fix.

### 4.4 Reconnect continuity (§5.7)

A per-registration reconnect token could reduce disruption. It is nevertheless a bearer
capability requiring protected or explicitly trusted delivery, replacement fencing, replay
rules and retirement. Lost ACCEPT is an important case: the client may never obtain it.

The user previously rejected mandatory custom ownership credentials. Consider optional,
registration-scoped continuity separately rather than reversing that decision implicitly.
The existing delay is not universally 30 seconds: detected closure and establishment/failure
deadlines can retire state earlier. Silent failures can still create a significant delay.
Measure operational consequences and define whether replacement preserves visible inventory
or still requires withdrawal/fresh upload; a token alone does not eliminate lost/found churn.

**Requested reviewer response:** What minimal token lifecycle and inventory-continuity rule
would solve the targeted failure cases, including lost ACCEPT, without persistent ownership?

### 4.5 Constrained clients and first-release scope (§5.1, §5.9–5.11)

A constrained client must be able to require filtered discovery and refuse an incompatible
broker; it must never silently fall back to a view it cannot hold. Whether TOPIC_CANDIDATES
is mandatory on every broker is a separate decision. Filtering also cannot guarantee every
possible matching workload fits: negotiated bounds and explicit refusal remain necessary.

Support a concrete constrained-client profile after the freshness/wire decisions, rather
than defining one by assuming all proposed simplifications are already accepted. Preserve
UDP and TCP as design goals. Dropping UDP cookies solely because deployment is trusted is
not a clear win: trusted-network policy does not make accidental reflection or resource
exhaustion impossible. Multi-scope support is largely service-side; a single-scope initial
configuration can implement the existing contract without deleting logical-scope isolation.

Agree on bounded admission/snapshot pacing, restart-jitter behavior and accounting for
versions pinned by concurrent snapshots. Shared scheduling is appropriate. A logical timer
entry per writer is not equivalent to a thread per writer; timing-wheel/heap design and
aggregation should follow measured scale, without prescribing a particular data structure.

I favor permitting authenticated TCP first if its maintained provider is ready, rejecting
unsupported authenticated UDP explicitly. This changes availability, not UDP's trust policy;
there must be no plaintext fallback. Select actual providers using target/support evidence,
not an unverified list of library names. Full DDS Security remains a separate integration.

## 5. Proposed revision sequence and boundaries

The sequence below is a plan for agreement, not work already performed:

| Stage | Output | Decision/evidence needed |
| --- | --- | --- |
| A: consensus | Reviewer reply to the questions above; short disposition table | Agree which findings require policy changes versus specification clarification |
| B: access and hot paths | Ordinary write/receive/send paths; prepared-access progress policy; hosted helping boundary | Race traces, bounded work/count targets, conversion/reentrancy assumptions |
| C: broker core | Freshness guarantee/scaling model; STATE ordering; compact format comparison | Delayed-withdrawal/backpressure/reconnect traces and representative byte/work costs |
| D: shipping profiles | Cooperative/static-memory direction, constrained clients, first API/provider availability | Explicit supported capabilities and failure behavior, no silent weakening |
| E: consolidation | Small normative set, archived rationale, decision index, maintained validation runner | No contradictory open/accepted text; every review finding has a disposition |
| F: merge preparation | Separate production fixes, clear test/coverage scope and release notes | Focused regression/interoperability evidence appropriate to each production change |

Editorial fixes can be prepared alongside the decisions, but a wholesale rewrite before
B–D risks repeating it. New prototypes should answer a named uncertainty with a bounded
experiment; the goal is not another open-ended series of models. Existing contracts remain
the reference until explicit revisions replace them. No production changes, branch
rewrites, commits or external messages are part of this response task.

## 6. Requested form of the next review response

Please distinguish:

1. Agreement on the problem from agreement on a particular remedy.
2. Safety/semantic requirements from performance targets and first-release scope.
3. Counterexamples to the current contract from implementation choices it already permits.
4. Necessary decisions before consolidation from measurements that belong to implementation.

For remaining disagreements, a concrete execution trace, workload or byte-cost comparison
would help more than another broad feature list. In particular, prioritize prepared-access
progress, suspension/coherent-boundary fast-path races, and aggregate freshness under delayed
withdrawal. These are the places where a small directional agreement could simplify the
most machinery without losing the guarantees the user asked us to preserve.

Evidence for this response: source/document comparison in the current local checkouts and
DDS passages cited above. No new protocol model, performance benchmark, security assessment
or production test run is claimed. This response is intentionally an input to consensus,
not a declaration that consensus has already been reached.
