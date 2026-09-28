# Design review: concurrency model and discovery broker (zzdds PR #93, zidl `concurrency-reference-support`)

Reviewer: Claude (Opus 5.5), 2026-09-27. Local review only; nothing was posted to GitHub.

## 0. Scope, method and what was executed

**Reviewed**

- zzdds `origin/concurrency-broker-specs` (PR #93, head `e8d3f79`, 3 commits over `main`):
  180 files, about 20.9k added lines. Of these, about 123 files are in `docs/design/`
  (roughly 19k lines of design prose, 17 Python models, an experimental IDL and golden
  vectors). There is also a test-only Zig prototype (`test/concurrency/`, about 2.3k
  lines), `build.zig` wiring, and a **production SPDP change** (`src/discovery/spdp.zig`,
  `idl/rtps_discovery.idl`).
- zidl `origin/concurrency-reference-support` (`6f69558`): 5 design docs, a C probe, an
  experimental managed-reference backend path, and one unrelated real generator fix.

**Method.** I read the normative entry points in full: handoff, contract, final review,
model, admission, commit-prep, request-lifetime, prototype, listener execution/identity/
callback-failure, API draft, extension surface, runtime ownership/bootstrap/retirement/
resources, manual driver, transport contract, the wait docs, prepared-read/binding
failures, the broker overview and guide, wire contract/bytes/details, operation table,
bootstrap/introduction/path-provider/inline-context, domain identity/multi-domain,
coexistence/origin-version, readiness/public API/storage, admission protection, inventory
barrier, presence completeness, protocol review, closure ledger and the earlier broker
review. I read the zidl docs and backend diff in full. The remaining listener and broker
sub-docs I skimmed or grepped for specific claims.

**Executed**

| Check | Result |
| --- | --- |
| `zig build --build-file test/concurrency/build.zig test` (Zig 0.16.0, Debug) | 56/56 pass (42 deterministic + 14 threaded) |
| `probes/broker_golden/reference.py` | 13 vectors verified |
| `probes/broker_golden/origin_version.py` | 8 vectors verified |
| `probes/broker_retry_retirement.py` | pass (176 states / 585 transitions) |
| `probes/check_broker_registry.py` | not run: needs a full checkout (`src/rtps/pid.zig`) |
| TSan runs, the other Python models, full `zig build test`, interop | not run |

Severity key: **H** = should be resolved before this is treated as an implementation
baseline. **M** = resolve before the affected implementation stage. **L** = hygiene or clarity.

---

## 1. Executive summary

The engineering instincts throughout are good. The docs consistently keep effect,
result and reclamation separate. No locks are held across callbacks or I/O. Completion
and cancellation capacity is reserved ahead of time. Deadlines never restart. ISRs never
run protocol work. Clock domains are explicit. There is no hidden shutdown call. On the
broker side, fencing by epoch, session and generation is used instead of GUID alone,
records are lossless, user data stays direct, and origin revisions resolve cross-path
ordering. Individual contracts are careful and mostly self-consistent.

The problems are at three levels above the individual contract.

1. **The package is not in a reviewable or maintainable shape as a baseline (H).**
   It is about 19k lines across more than 100 docs. Most docs are chronological logs, with
   several "Status:" lines each and superseded "open/proposed" wording left in place.
   Authority rules like "later accepted decisions supersede historical wording" push
   conflict resolution onto every future reader. I found several real contradictions
   caused by this (§4). An implementer cannot reliably extract the rules.
2. **Performance is specified only negatively (H).** The docs say "no mandatory handoff"
   and "don't invent numbers". There is no positive design for the hot paths: the
   uncontended write, send batching and coalescing, the per-call cost of runtime-wide
   budgets, and priority. Several accepted mechanisms (Publisher ticket plus group gate,
   release-and-reacquire of writer rights, the runtime-wide inline budget, cross-runtime
   helping, optimistic prepared read/take) have hot-path costs or tail behavior the docs
   never bound. For embedded use, the spec says a lot about what must compile out, but it
   never defines the cooperative single-context profile or a static-memory model that
   MicroZig needs.
3. **Broker v1 is much larger than it needs to be, and its presence mechanism does not
   scale (H).** The v1 baseline needs all of the following on every client:
   - XCDR2 *mutable* encoding for all 27 operations
   - two reliable RTPS streams per direction with cross-stream reassembly
   - SHA-256 digests
   - nonce-bound, chunked, pull-based presence proofs for every participant in view
   - UDP path cookies
   - fenced inventory transactions
   - client-assigned view generations
   - bounded orphan staging

   Pull-based presence costs O(N × view) in broker egress on a refresh cadence the spec
   never defines. That undermines the thing a broker is for. A constrained (MCU) client
   profile is not defined at all, and VIEW_ALL is mandatory while TOPIC_CANDIDATES is optional.

**Top recommendations (details in the sections below)**

| # | Recommendation | Section |
| --- | --- | --- |
| 1 | Collapse the package into about 8 normative docs plus an archive/decision log before merging. Split the SPDP production change and the zidl allocator fix into their own PRs. | §2, §3.14, §6.1 |
| 2 | Specify the uncontended write/send/receive fast paths normatively, with operation-count budgets. Define when Publisher tickets and the group gate are *not* used. | §3.1–3.3 |
| 3 | Add send batching/coalescing and a priority hook to the execution model | §3.2, §3.5 |
| 4 | Replace optimistic prepared read/take for native bindings with pessimistic (lock-held) conversion or per-sample claims, so `take()` can't return ERROR under contention | §3.6 |
| 5 | Define the cooperative/MCU profile concretely: which mechanisms collapse, comptime-sized pools, no heap after init, and a per-entity RAM worksheet | §3.8 |
| 6 | Replace pull presence proofs with session-derived freshness plus pushed expiry; specify refresh cadence if proofs stay | §5.2 |
| 7 | Use final/appendable bodies plus version negotiation instead of mutable. Drop per-message scope/session repetition. Move ordered state onto one stream. | §5.3–5.5 |
| 8 | Fix the bootstrap MTU contradictions (1200-byte budget vs 1336-byte ACCEPT and large SPDP samples) | §5.6 |
| 9 | Define a constrained broker-client profile. Make TOPIC_CANDIDATES a mandatory *broker* capability. | §5.9 |
| 10 | Revisit reconnect-after-silent-failure (30 s lockout plus lost/found storm) | §5.7 |

---

## 2. Process and document structure (H)

**2.1 Volume and log-style docs.** About 19k lines in 100+ docs, for a design that is not
yet implemented. Most docs append dated entries ("F3 investigation…", "F3 accepted and
incorporated…"). Several docs carry multiple Status lines: `listener-callback-failure.md` (4),
`listener-status-ordering.md` (4), `broker-wire-registry.md` (4), `historical-data-wait.md` (3).
`concurrency-spec-status.md` is 322 lines of chronology. The docs declare themselves
"evidence history, not competing requirements". In practice, readers can't tell which
sentence is current without reading everything in order.

*Recommendation.* Before merge, produce a small normative set, each with a single status
and no dated narrative:

1. Concurrency architecture (owners, admission, progress, profiles)
2. Listener contract
3. Operation results and waits (one table)
4. Runtime, transport and bootstrap lifecycle
5. Extension API (IDL fragments)
6. Broker protocol (behavior)
7. Broker wire spec (bytes/registry)
8. Broker API

Move everything else, including reviews, ledgers, investigations and model write-ups, to
`docs/design/archive/` or a `decisions.md`-style log with one line per decision and a link.
The 17 Python models and the probes belong under `tools/design-models/` (or
`test/design-models/`) with a runner, so they don't sit in `docs/`.

**2.2 Models and probes are not wired into anything.** The Python models, golden vectors
and the broker codec probe run by hand. Once the wire or the design moves, they will rot
silently. Either add a cheap CI job (they are all quick) or state that they are historical
and not maintained.

**2.3 "Accepted" means several different things.** "Accepted policy", "accepted direction",
"accepted as mapping direction", "selected", "recommended for acceptance" and "agreed" are
all in use. A single table of decisions (ID, statement, status, doc anchor) would remove a
whole class of ambiguity.

**2.4 Hygiene (L)**

- `concurrency-prototype.md:29` embeds a personal path (`/home/tsimpson/code/zig-x86_64-linux-0.16.0/zig`).
- `concurrency-api-draft.md` links `../../../zidl/docs/design/construction-reference-bindings.md`.
  That only resolves in a sibling checkout and is broken on GitHub.
- Several docs cite local audit commit hashes ("local zzdds `d41e540` … rebased on main
  `c37181e`"), "working tree" state (`roadmap.md` domain-tag entry) and test counts
  ("20 codec tests, 49 vectors"). All of these go stale on merge.
- `main-refresh-review.md` and `pr-92-discovery-review.md` are point-in-time review notes
  about other PRs. They belong in PR comments or the archive, not in normative design.

---

## 3. Concurrency design

### 3.1 The uncontended write path is not specified, and may carry ticket and gate costs on every write (H)

`concurrency-model.md:141` gives the write sequence:

1. Prepare and reserve under writer rights.
2. **Release writer rights.**
3. Obtain a Publisher ticket "*where shared publication controls require it*".
4. Commit under writer rights (re-acquired).
5. Complete the ticket.

`commit-preparation.md:33` repeats "when required". Nothing defines when a ticket is *not*
required. `suspend_publications` is a Publisher-wide control on every Publisher, so a
literal reading puts a ticket on every write. The prototype always uses tickets.

As written, the steady-state best-effort or reliable write for the default QoS
(PRESENTATION INSTANCE, non-coherent) could involve all of the following:

- two writer-context admissions
- a per-instance preparation ledger entry
- a ticket issue and retire
- a FIFO gate entitlement
- a group-commit gate claim
- a coalesced output record, with fan-out "in later budgeted turns"

Each of these is small, but together they are the latency-critical path. None of them is
needed when no GROUP/coherent scope is active and the Publisher is not suspended.

*Recommendation.* Add a normative **fast-path contract**:

- If the writer's Publisher has no coherent/ordered GROUP access, no open coherent set and
  no suspension, the write runs as **one writer turn**: prepare, reserve, commit, then
  initial send.
- The fast path uses no ticket, no gate, no ledger beyond a per-instance counter, and no
  queue record.
- Suspension or coherent-begin flips a Publisher generation. Writers check it with one
  acquire-load and fall back to the ticketed path only when it is set.
- Specify how the flip races with in-flight fast-path writes. The existing
  generation/close machinery is enough for this.

Give the fast path an operation-count budget that tests can check. For example: zero heap
allocations with preallocated history nodes, at most one uncontended lock or CAS pair on
the writer context, zero cross-thread handoffs, zero ready-queue records. The docs rightly
refuse to invent *latency* numbers. Operation-count budgets are different: they are
checkable design targets and stop mechanism creep.

### 3.2 No batching or coalescing design, so the throughput story is missing (H)

`batch`, `flush` and `coalesce … send` appear nowhere in the concurrency docs as a send
mechanism. RTPS throughput depends on:

- packing several DATA submessages per datagram, together with piggybacked HEARTBEATs
- coalescing HEARTBEAT/ACKNACK traffic
- reusing one serialization for many locators

Take-turns ownership is naturally a **combining** design. When a writer context is busy,
later committed changes queue behind the running executor, which can drain them in one
datagram. Nothing makes that normative, and "fan-out occurs in later budgeted turns"
(`commit-preparation.md:39`) could just as easily produce one datagram per sample, or
defer the initial send to another thread.

*Recommendation.*

- State that the committing thread performs the initial send inline when uncontended
  (latency).
- State that an executor finding several committed-unsent changes batches them up to a
  size/count bound (throughput).
- Add an explicit application flush/batching QoS hook to the zzdds extension list. Several
  vendors expose one, and this is where zzdds would compete.
- Add "sustained write throughput at 64 B / 1 KB / 64 KB, packets per sample" to the
  migration-plan acceptance measurements.

### 3.3 A runtime-wide inline budget risks global contention (M)

`admission-validation.md:55` and `concurrency-model.md:86` require a runtime-wide inline
budget and "protocol-progress checkpoints" so that direct calls can't starve other
contexts. Implemented literally, this is a shared counter touched by every inline API
call on every core, which causes cache-line bouncing on exactly the uncontended path.

*Recommendation.* Specify the budget as per-thread (or per-context) with a read-mostly
"other work is ready or timers are due" flag, which is written rarely and read on each
inline entry. Starvation then shows up as a cheap check of that flag, not a shared counter.

### 3.4 Helping on application threads causes latency jitter (M)

C4 ("shared runtime progress domain") lets synchronous waits (write capacity, ACK waits,
WaitSets through `DEFAULT_SHARED_RUNTIME`) run *other* contexts' ready protocol work. In
manual mode this is essential. In **hosted** mode it means an application thread blocked
in `write()` or `wait()` can run a repair burst for an unrelated writer. That thread then
returns later than its own predicate required, on the wrong core, with cold caches. This
matters most for latency-sensitive threads that hosted users typically pin and prioritise.

*Recommendation.* In hosted builds, default to helping only the waited-on owner, or no
helping at all, and rely on the background workers. Keep full-runtime helping as the
manual-mode default and as an explicit hosted option. `WaitSetConfig.helping_policy`
already exists; add the same choice at runtime or participant scope for API waits.

### 3.5 No priority or real-time hook (M)

Ready service is FIFO with round-robin across contexts. `admission-validation.md:67` says
"No priorities … are required". That is fine as a v1 default. However:

- There is no seam for priority-aware ready queues. LATENCY_BUDGET and
  TRANSPORT_PRIORITY QoS are not mentioned in the execution model.
- The group-commit gate and FIFO entitlement can cause priority inversion: a low-priority
  entitled writer delays a high-priority writer's commit. `admission-state-machine.md:86`
  notes the head-of-line delay but not the inversion.

Robotics and embedded users (a stated target) will want at least two service classes.

*Recommendation.* Reserve a per-context service class in the admission design now
(FIFO within a class, strict or weighted across classes). Document the inversion risk and
the mitigation boundary: bounded gate hold time, and no class mixing inside the gate.
Designated executors and affinity are already deferred. Priority classes are cheaper and
should not be deferred with them.

### 3.6 Optimistic prepared read/take can return ERROR under contention (H)

`prepared-read-conflicts.md` and `binding-access-failures.md:37` define read/take as:
select, convert outside locks, validate, and whole-batch commit. After **four** invalidated
attempts (the `prepared_access_stale_validation_limit` default) the call returns
**ERROR**, even though eligible data remains.

Problems:

- **Invalidation is broad.** Validation covers "SampleInfo, ordering and ranks".
  `absolute_generation_rank` and the instance generation counts depend on the *newest*
  sample of each returned instance. On a keyed topic with sustained ingress, any arrival
  on a returned instance invalidates the batch. A `take()` of 100 samples across hot
  instances can then fail repeatedly. The doc's "a new unrelated sample need not
  invalidate" does not cover same-instance arrivals, which are the common case.
- **Semantics.** No mainstream DDS implementation returns ERROR from `take()` because of
  ingress load. Applications will treat it as fatal.
- **Cost.** Wasted deserialization under load, which is when it hurts most.
- **Motivation doesn't apply to most bindings.** The motivation is Java/foreign conversion
  that may re-enter DDS. For Zig, C and C++ generated types, deserialization is pure,
  bounded and non-reentrant.

*Recommendation.*

- Native generated bindings deserialize under the reader's execution rights (pessimistic)
  and never retry.
- For foreign/reentrant conversion, **claim** the selected samples under reader rights
  (take-claims hide them from other takers, and read-claims pin state), convert outside,
  then commit or unclaim. The doc rejected an "exclusive access reservation" because
  others would wait behind arbitrary code. Per-sample claims don't block other takers:
  they skip claimed samples.
- Compute rank fields at commit from the committed collection, as other implementations
  do, rather than validating them.
- Keep bounded-retry ERROR only as a last resort for pathological cases, and document it
  prominently.

### 3.7 Historical-data wait on best-effort readers always times out (M)

The ACK wait makes best-effort writers **immediately OK** (`writer-ack-wait.md:31-34`,
following DDS). The historical wait does the opposite for best-effort
(`historical-data-wait.md:277-285`): without a boundary the transfer stays pending until
TIMEOUT, or forever with an infinite duration.

A reliable TRANSIENT_LOCAL writer sends no heartbeats to a best-effort reader, and a
best-effort writer sends none at all. So `wait_for_historical_data` on a best-effort
durable reader **can never succeed**. The doc records this as a user decision. It is
still inconsistent with the ACK rule and hostile to applications. rmw_zzdds does not call
it today, so this is an application-facing risk, not an rmw one.

The empty-known-sources → immediate OK rule is also a behavior change from today (nonzero
waits currently block until a first match). It needs a CHANGELOG and migration note,
because startup code that relied on the implicit wait will silently stop waiting.

*Recommendation.* Treat best-effort associations as carrying no historical obligation, in
the same way as ACK wait, or return UNSUPPORTED for best-effort readers. Do not make the
call time out by construction.

### 3.8 The embedded (MicroZig) profile is implied, not designed (H)

The spec gets the ISR boundary, clocks, wake handshakes, "no OS thread deps in a
freestanding compile" and "optional profiles compile out" right. What an MCU port
actually needs is missing.

1. **A cooperative single-context profile.** With one execution context, no
   ISR-touched DDS state and one outer driver, most of the machinery collapses.
   Execution rights are trivially held. FIFO entitlement, the group gate, the identity
   registry's cross-runtime scope, cross-runtime delegation, RuntimeOwner/Ref leasing,
   ResourceScope, helping policies and external-loop attachment all become no-ops or
   disappear. `listener-execution.md:70` allows specialization "only when exclusive
   execution is established", but no document lists what specializes to what. Without
   that list, each subsystem will carry its hosted synchronization into the MCU build.
2. **A static memory model.** Request records carry refcounts, generations, gate links
   and ownership edges (see `prototype.zig`'s `Request`/`Ownership`). There are also
   pending-notification records, ledgers, identity records, reserved completion capacity,
   retry timers and WaitSet leases. An MCU build needs:
   - every pool sized at comptime
   - no heap after init (or a single fixed-buffer allocator)
   - a published per-entity and per-sample RAM worksheet, for example "reader with depth
     8 and 2 matched writers = X bytes"
   
   The spec's "prefer caller-supplied pools" (`concurrency-model.md:236`) is a preference,
   not a requirement.
3. **KEEP_LAST reservation memory.** The selected reservation design
   (`commit-preparation.md:47`) makes a depth-1 writer need physical storage for the old
   sample, the prepared new sample and any externally pinned retired sample. That is 2–3×
   the history payload memory. This is fine on hosted systems. On an MCU it should be
   explicit in the worksheet, and there should be an in-place replace option when no
   pins or repair obligations exist.
4. **A code-size budget per profile.** The migration plan measures size afterwards.
   Setting a target first (for example "minimal best-effort pub/sub profile ≤ N KB
   ReleaseSmall") steers design choices. The current 337 KB zipped `shape_main` is a
   useful baseline.
5. **A MicroZig transport sketch.** One paragraph on how lwIP raw-API `pbuf` callbacks map
   onto the ingress contract (inline/retain/copy) and synchronous `udp_send` completion
   would show the transport contract is implementable there. I believe it maps cleanly,
   and saying so is cheap.

### 3.9 The listener machinery is heavy for its benefit (M)

Canonical cross-binding listener identity is shared across runtimes. On top of it sit
dependency-cycle rejection for `notify_datareaders`, per-participant nesting limits with
min-composition across chains, a prepare/validate/commit protocol for callback arguments
with 2/8/1 ms→1 s retry knobs, retired-registration frontier drains and preparation
recursion frames. Each is justified locally. Together they are large, and most exist to
make Java and C++ adapters safe under re-entrancy.

*Recommendation.*

- Keep the contract, but let the implementation plan stage it. Stage 1 is per-entity
  exclusion, inline dispatch and native bindings. Cross-runtime identity, cycle detection
  and the foreign-preparation retry machinery come in stage 3, where the migration plan
  already puts binding work.
- Mark which parts compile out in the cooperative profile.
- **Inconsistency.** `listener-callback-failure.md:339` says the retry knobs (2 per turn,
  8 stale, 1 ms–1 s backoff) are "configured per participant at creation".
  `concurrency-api-draft.md:113-116` `ParticipantConcurrencyConfig` exposes only
  `delegation_nesting_limit` and `prepared_access_stale_validation_limit` (default **4**,
  a different budget from the listener's **8**). Either add the listener knobs or state
  that they are build-time only.

### 3.10 Smaller concurrency points

- **(M) The preparation-failure timer path.** The 1 ms → 1 s capped backoff for automatic
  callback preparation after transient allocation failure means a listener can go silent
  for up to 1 s after memory pressure clears unless a "resource-ready" wake exists.
  Specify which allocators provide the resource-ready signal. The pool-based ones should.
- **(M) GROUP compile-out is asserted, not demonstrated.** The group gate, tickets and
  access brackets are in the default design and the prototype. Add a build-shape check
  now, even a stub ("GROUP disabled → `Publisher` has no gate field"), so it can't
  regress during migration.
- **(L) The prototype is a good synchronization testbed.** It is fast (about 80 ms), but
  it is not the production shape: fixed IDs, scans, a scheduler mutex doing allocation.
  Keep it out of the default test graphs (§3.14) and treat it as disposable.
- **(L) Terminology.** "Take-turns execution", "execution rights", "context admission",
  "history admission", "entitlement", "ticket", "turn" and "gate" all appear, sometimes
  loosely. A one-page glossary in the consolidated architecture doc would help.

### 3.11 Internal contradictions in the concurrency docs

These come from the log-style docs described in §2.1.

| Location | Says | Contradicted by |
| --- | --- | --- |
| `listener-execution.md:174` | "Retry budgets remain open" | Same doc §13, `listener-callback-failure.md:327+` (accepted numeric defaults) |
| `listener-callback-failure.md:284` | "Exact retry budgets remain open" | Same doc lines 327–343 |
| `listener-execution.md` §8 (lines 117–140) | Cross-participant limit composition "remains to be specified"; creation-time mutability "proposed" | `listener-identity-decision.md` (accepted min-composition); `concurrency-contract.md:118` |
| `listener-identity-decision.md:87` | "Identity scope and binding defaults above still await acceptance" | Its own Status line (accepted 2026-09-15) |
| `concurrency-model.md:108` | notify_datareaders/busy-listener interaction "remains open" | Delegation/notification-boundary docs (accepted) |
| `concurrency-model.md:167, 173` | Provisional defaults; "public construction/configuration APIs, default runtime ownership… remain open" | runtime-ownership / bootstrap / extension-surface (accepted) |
| `request-lifetime.md:184` | "does not select atomic cancel-all vs close-then-cancel" | `runtime-retirement.md` (selected RETIRING semantics) (arguably consistent, but a reader cannot tell) |

### 3.12 Runtime ownership and API surface (M)

The operational-owner/observer split, automatic final-owner retirement and "no hidden
shutdown call" are good decisions. The public surface is large for v1, though:

- `RuntimeRef`, `RuntimeOwner` and `RuntimeSelection` (2 kinds)
- a core default controller with 3 states
- `ResourceScope` and `ResourceCompletion`
- `ManualDriver` and `ExternalDriver`
- `WaitSetConfig` with 3 helping policies
- `ListenerGroup`
- 6 `*_ex` constructors and Config types
- `ParticipantConcurrencyConfig`

Every one of these needs zidl managed-reference support, which does not exist yet
(§6.3). *Recommendation.* Ship v1 with the standard API, a build-selected
hosted/manual default and `ManualDriver`. Add explicit runtimes, ResourceScope,
ListenerGroup and external-loop attachment when a user needs them. The contracts can stay;
the ABI commitment is what's expensive.

### 3.13 Transport contract (L/M)

Borrow/retain/copy ingress, accepted/pending/completed/rejected output, and reserved
completion capacity are the right shape. Two gaps:

- **(M) Sharing-completion writes between fan-out destinations.** "Independently accounted
  destination submissions" is required, but the cost model (one serialization, N sends,
  one refcounted buffer) is not stated. Say it explicitly so implementations don't copy
  per destination.
- **(L) Mid-frame TCP pausing.** "Pause reading at a recoverable framing boundary" with a
  bounded partial frame is right. State that the TCP receive buffer pool is per-connection,
  so one slow endpoint can't pin the shared pool.

### 3.14 Production changes inside a spec PR (H, process)

PR #93 is presented as specs, but it:

- **changes the SPDP wire and receive behavior** (`src/discovery/spdp.zig`,
  `idl/rtps_discovery.idl`). Every announcement now emits `PID_DOMAIN_ID` (0x000f), and
  explicit foreign-domain SPDP is dropped before cache/lease updates. The change is
  standard-compliant (RTPS 2.5 §8.5.5.1) and probably interoperable, but it is a wire
  change, and the handoff doc says "This handoff changes documentation only". It needs
  its own PR, a CHANGELOG entry and a dds-rtps interop run against all vendors. It also
  changes `wire_golden_test.zig`'s expected decode domain from 7 to 0, which is correct
  but deserves its own review.
- **wires the test-only prototype into the default `test`, `test-release-small`,
  `emit-tests` and `test-tsan` graphs** (`build.zig`). That puts about 2.3k lines of
  disposable experiment on every CI leg (including Windows, where threaded checkpoints are
  skipped) and makes it a merge blocker. *Recommendation:* keep only `test-concurrency` and
  `test-concurrency-tsan`, and leave the default graphs alone.

---

## 4. Cross-document consistency (concurrency ↔ broker)

- **(M) Local matching independent of the broker vs one participant control context.**
  The broker's admission, inventory/view commit, matching and teardown "serialize through
  participant control" (`discovery-broker.md:106-112`). A large broker view installation,
  such as a 10k-endpoint snapshot reconcile, then runs as participant-control turns that
  delay local endpoint creation and matching. The turns are bounded, but the total is
  O(view). State that snapshot reconcile is chunked into budgeted turns, and that local
  create/match has priority over remote view installation. This ties into §3.5.
- **(L) The broker relies on `wait_discovery_ready` helping semantics.** These are defined
  by reference to the L5 wait contract, which is fine. The readiness wait also "follows
  recovery across epochs". Make sure the recovery machinery is not also driven *by* the
  waiting thread's helping. Otherwise, with no-helping hosted policies (§3.4), recovery
  must be background-driven, and that should be said.

---

## 5. Discovery broker

### 5.1 v1 scope is heavy; propose a minimal v1 cut (H)

The earlier review (`discovery-broker-review.md` §8) asked which use case drives the full
cached design. The disposition kept cached discovery "for configurable endpoint
distribution and scaling". I agree with keeping cached discovery. The issue is how much
machinery v1 requires around it. Baseline, non-optional items (`broker-wire-details.md:73`)
include lease/presence proofs, fresh-inventory transactions, digests, mutable encoding and
the UDP cookie path.

A v1 that is still correct but about half the size:

| Keep in v1 | Defer (to v1.x, feature-negotiated) |
| --- | --- |
| TCP control (plus plain UDP only on trusted networks) | UDP PATH cookie flow → v1.1 (TCP already gives return-path validation) |
| One reliable ordered state stream per direction + control/lease stream | CONTROL/STATE split for view records (see §5.5) |
| Fresh inventory per session, COMMIT barrier | DOWNSTREAM_RESUME (already optional); pipelining (already deferred) |
| Snapshot + contiguous deltas + APPLIED | SHA-256 digest (count + index + reliable stream suffice; see §5.8) |
| Session-derived freshness + pushed expiry (see §5.2) | Nonce presence proofs, chunked full-view answers, query serials |
| Single scope per broker process (config) | Multi-scope logical participants |
| Final/appendable bodies (see §5.3) | Mutable bodies |

Everything in the right column has a clean negotiated extension path. The design already
has feature bits and version ranges.

### 5.2 Pull-based presence proofs scale as O(N × view) and have no cadence (H)

`discovery-broker.md:363-374` and `broker-presence-completeness.md` specify how presence
works:

- Observers query presence with nonces.
- The broker returns each visible participant's remaining lease, and the client sets its
  deadline to `t0 + r`.
- State snapshots don't grant presence.
- New records need an unexpired proof before activation.
- READY requires every participant in the fixed target to be proved, withdrawn or
  evaluated unavailable.

Issues:

1. **The refresh cadence is unspecified.** I found no presence query period or interval
   anywhere. To keep broker-sourced peers alive, each observer must re-query before `r`
   (≤ 30 s) runs out, so in practice about every 10–15 s.
2. **Scale.** For VIEW_ALL with N clients, broker egress per refresh period is N × N
   entries. At N = 1,000 that is 10⁶ entries per period. At 10,000 it is 10⁸ entries per
   period, around 100+ MB/s at about 40 B per entry. This is the O(N²) presence problem
   §12 mentions. The pull design adds a per-query nonce, chunking, retained immutable
   answers and query-serial retirement on top.
3. **Activation latency.** Every newly announced remote participant needs a separate
   proof round trip before it activates. That adds at least one broker RTT to every
   discovery event, and a full-view proof to every READY.
4. **Mostly redundant with fencing.** The state stream is reliable, ordered and
   session-fenced, and the broker already withdraws expired origins. The risk the proofs
   address is a replayed or delayed stale view keeping a dead participant alive. Epoch,
   session and delivery_seq fencing already prevents a stale stream from being applied.
   The remaining case is a broker that stops sending removals while the session looks
   alive (a hung broker or partition). Session-level liveness covers that.

*Recommendation (simpler design).* A client's broker-sourced records stay valid while its
**own session is fresh**. The session is fresh while broker keepalives or LEASE traffic
arrive, measured with the same `t0`-based conservative rule, applied once per session
rather than once per participant. The broker pushes REMOVE or expiry deltas when origin
leases lapse. On session loss, all broker-sourced records get a single deadline of
`last_fresh + origin_lease` and expire together unless the session recovers. This gives
bounded expiry without synchronized clocks, costs O(N) per period instead of O(N × view),
and removes PRESENCE_QUERY/PROOF, query serials and chunk assembly from v1.

If per-participant proofs are kept, the spec must at least fix the cadence, give the
broker egress formula, and make full-view queries rate-limited per session.

### 5.3 Mutable XCDR2 for every body creates problems it then has to solve (H)

The Envelope and all 27 bodies are `@mutable` (30 mutable types in
`schema/broker-control-draft.idl`). This choice is what creates:

- the duplicate-singleton-member attack surface
- the required-member presence gap (zidl doesn't track either, per
  `broker-wire-contract.md:90-93` and the zidl roadmap entry)
- EMHEADER overhead on every field
- the need for a custom validated decoder before the protocol can face untrusted input

The protocol already has an explicit major/minor, per-session feature negotiation and
opcodes. Within a negotiated version, **appendable** (DHEADER plus trailing optional
members) or **final** bodies give forward compatibility with no duplicates to reject and
far less code. That matters for MCU clients. Reserve mutable for genuinely open-ended
descriptors, if any (for example `ServiceCapabilities`, though a length-delimited TLV list
would do).

*Recommendation.* Switch bodies to final/appendable before freeze. This removes wire-freeze
gate 3's "required/duplicate member validation" as a generator prerequisite.

### 5.4 Per-message Envelope repeats session-bound state (M)

Every established message carries:

- `ScopeValue` (the `string<256>` domain tag plus id)
- `broker_epoch` (16 B)
- `session_id` (16 B)
- `owner_generation` (8 B)
- `request_id` (16 B)
- `required_features`

These are all mutable members with EMHEADERs, and sit inside a 24-byte Frame (with an
8-byte ASCII magic) inside RTPS DATA. Established endpoints are **fresh per session**
(`broker-wire-details.md:103-121`), so the (writer GUID → session) mapping already binds
scope, epoch, session and owner generation. Validating the envelope copies against that
mapping is redundant work. The domain tag string can make up a large share of a small
DELTA.

*Recommendation.* Bind scope, epoch, session and generation to the endpoint pair at
ACCEPT. The Envelope then carries only an opcode-specific request id where needed, plus
required features. Drop the Frame magic for established traffic, since the vendor
endpoint ID already identifies the protocol. Keep it for bootstrap if wanted.

### 5.5 CONTROL and STATE streams force cross-stream reassembly (M)

BEGIN and END travel on CONTROL while RECORDs travel on STATE (operation table rows 5–7,
12–14), and they are independent reliable streams. That forces:

- "END may arrive before any RECORD"
- orphan staging budgets
- "RECORD or DELTA can also precede BEGIN"
- rules against ACK-and-forget after RTPS ACK
- the special same-session-replacement drain in `broker-inventory-barrier.md`

All of this is complexity with no benefit, because END can't complete until the records
arrive anyway.

*Recommendation.* Put everything that must be ordered on the STATE stream: ORIGIN
BEGIN/RECORD/END, MUTATE, SNAPSHOT BEGIN/RECORD/END, DELTA and VIEW_SYNC. Keep CONTROL for
admission follow-up, COMMIT/REJECT, lease, errors and close. Ordering within a reliable
RTPS stream is free, and orphan staging disappears. If control priority over bulk state
is the concern, bound STATE frame and fragment sizes; that is already required for TCP.

### 5.6 Bootstrap size contradictions (H)

`broker-bootstrap-lifecycle.md:19-31` makes three statements that conflict:

- The proposed default UDP budget is 1,200 bytes (`discovery-broker.md:250`).
- A legal ACCEPT with a 256-byte domain tag and 128 features is **1,336 bytes** before
  RTPS and security overhead.
- Bootstrap may not fragment.

So a schema-legal configuration cannot bootstrap over UDP at defaults. The client's
**canonical SPDP sample** has the same limit, and it can't be trimmed ("do not strip
canonical fields"). Multi-homed hosts, Docker/k8s nodes with many interfaces and IPv6
hosts routinely advertise 10–30 locators, at 24 B each per locator kind, plus user data,
entity name and property lists. Such clients will fail UDP bootstrap with no remedy
except switching to TCP.

*Recommendation.*

- Cap schema ceilings so the worst-case ACCEPT and REGISTER fit the default budget minus
  RTPS overhead, for example `features ≤ 16` in bootstrap bodies.
- Allow DATA_FRAG for the client's directed SPDP *after* PATH validation. Before
  validation, only the broker's response is amplification-limited, and the client's
  request size is its own cost.
- Alternatively, carry a compact introduction pre-validation and upload the canonical
  sample as the first ORIGIN record.

### 5.7 Reconnect after a silent failure is locked out for about the lease (M)

`broker-admission-protection.md:45-61, 92-101` blocks a competing registration for a
still-live GUID unless authenticated continuity exists, and v1 has none
(`continuity_credential` reserved). This blocks reconnects after:

- TCP half-open connections
- NAT rebinding
- Wi-Fi roaming
- a client IP change
- a lost ACCEPT on a new binding

In each case the client can't re-register until the old registration's lease expires,
30 s by default. When it does expire, every observer sees the participant **withdrawn,
then re-added**: a lost/found storm that also churns user-data matching fleet-wide. This
will be the most visible operational wart of the broker.

*Recommendation.* For v1, implement the reserved ACCEPT `continuity_credential` as a
broker-issued, per-session random resume token. It is delivered only over the admitted
path and is never distributed to observers, unlike `incarnation_id`, which is public
through PID 0x8003. It authorizes replacement of *that* registration only. It is no
weaker than the trusted-network threat model already accepted, and it removes the lockout.
Under `authenticated` policy it rides inside TLS/DTLS.

### 5.8 SHA-256 digests are redundant (L/M)

Inventory and snapshot digests (`broker-wire-bytes.md:72-89`) detect "inconsistent
assembly". Streams are reliable and ordered, and records carry indices, counts and total
bytes. With §5.5 applied, the digest only catches implementation bugs. It costs O(B) CPU
on both sides per snapshot, plus SHA-256 code size on MCU clients.

*Recommendation.* Make it a negotiated debug/strict feature, or use CRC-32C.

### 5.9 No constrained-client profile (H for the embedded goal)

An MCU broker client must currently implement:

- directed SPDP with inline vendor QoS
- PATH cookies
- REGISTER/ACCEPT
- two reliable writer/reader pairs
- XCDR2 mutable codecs for about 20 bodies
- SHA-256
- staged snapshot install
- presence query assembly
- inventory transactions
- VIEW_ALL, a full-domain graph in RAM, because TOPIC_CANDIDATES is an optional feature
  the broker may not implement

This is the opposite of what embedded clients want from a broker, which is to offload
discovery state.

*Recommendation.* Define a **constrained client profile**:

- TCP or UDP, but no fragmentation needed with small views
- TOPIC_CANDIDATES required
- no resume, and no presence proofs (with §5.2)
- appendable codecs
- bounded view limits declared in REGISTER
- no digest

Make TOPIC_CANDIDATES a **mandatory broker capability**. The broker is the hosted party
that can afford it, and today's negotiation lets a broker force VIEW_ALL on a client that
cannot hold it.

### 5.10 Broker-side scale and restart behavior (M)

- **Restart and failover storm.** A new epoch means every client re-introduces,
  re-registers, uploads a full inventory and requests a full snapshot at once. That is
  O(N) inventories plus O(N × view) snapshot egress, compressed into the reconnect
  backoff window (250 ms–30 s full jitter). Specify broker-side admission pacing: a token
  bucket for REGISTER, and snapshot concurrency limits with queueing. Also specify
  that READY latency after a restart is bounded by that pacing, not by RTT.
- **Per-session reliable writers.** Each session gets its own independent RTPS writers and
  histories, which is the right choice for filtered views. Specify that heartbeat and
  repair scheduling is per-broker (timer wheel, batched heartbeats), never per writer.
  The review already flagged thread-per-writer. The equivalent risk here is a timer per
  writer.
- **Snapshot memory.** "Snapshot streaming avoids cloning the database" is right. State
  that snapshot cursors pin record versions (copy-on-write or immutable records with
  refcounts) and give the bound for concurrent snapshots.

### 5.11 Security practicality (M)

"Authenticated" mode requires maintained TLS **and DTLS** with parity between UDP and TCP
(`discovery-broker.md:442`). To my knowledge, Zig std ships a TLS client but no TLS server
and no DTLS. Authenticated mode therefore means integrating a C library (mbedTLS,
wolfSSL, BearSSL) on hosted and MCU targets alike. That is a large dependency decision
that the spec leaves implicit.

*Recommendation.* Name the provider strategy. Consider allowing v1 authenticated mode on
TCP+TLS only, with UDP limited to `trusted_network`, rather than blocking all
authenticated deployment on DTLS parity.

### 5.12 Broker inconsistencies and stale text

| Location | Issue |
| --- | --- |
| `discovery-broker.md:297` | Client states `DISCONNECTED → CONNECTING → ADMITTED → REGISTERING → SYNCING → READY`. Under the SPDP bootstrap, ACCEPT (admission) *follows* REGISTER. The public `DiscoveryPhase` (`broker-public-api.md:143`) uses `CONNECTING, INTRODUCING, REGISTERING, SYNCHRONIZING, READY, BACKOFF, FAILED`. Align them. |
| `discovery-broker.md:76-77` (diagram) | "UDP or TCP: state **and metatraffic**" to the broker. v1 has no metatraffic forwarding (WLP is direct). |
| `discovery-broker.md:55` (§3 scope) | V1 "includes … authenticated deployment options". §10.4/§16.2 gate public authenticated deployment on TLS/DTLS parity. Say that v1 *specifies* it and may not *ship* it. |
| `discovery-broker.md` §8 (lines 363–376) | Gives origin-lease defaults (30 s lease, 5 s challenge) but no observer presence-query cadence. None of the presence docs give one either (see §5.2). |
| `broker-route-authority.md`, `broker-wire-review.md` | Superseded but still in `docs/design/`. The guide says so, but they will be found by search. Archive them. |
| `broker-spec-guide.md:82`, `broker-wire-bytes.md:134`, `specification-handoff.md:91` | Evidence counts ("20 codec tests, 49 vectors") duplicated in several places. They will drift. |
| `broker-domain-identity.md:55-58` and `roadmap.md` | Describe the SPDP domain-ID change as "now in the working tree". It is committed on this branch, and the text will be wrong after merge. |

### 5.13 Things I'd keep exactly as designed

- Origin-owned lossless records. No impersonation of origin SEDP writers or re-sequencing
  under origin GUIDs.
- The `(epoch, session, owner_generation, origin_revision, delivery_seq)` fencing model,
  and the rule that REMOVE advances the revision and leaves a tombstone.
- Shared origin revision across direct and broker paths, with no rollback when a source
  expires (the coexistence doc is excellent).
- Standard `(domain_id, domain_tag)` scope instead of a realm, and one logical service
  participant per scope.
- `allow_degraded` default, fixed-cut READY, and local matching independent of the broker.
- Directed context in inline QoS, keeping the canonical SPDP payload recipient-invariant.

---

## 6. zidl branch (`concurrency-reference-support`)

**6.1 (M) Split out the real fix.** The `typeRefNeedsAllocator` / `sequenceElementUsesAllocator`
change in `src/backend/zig.zig` is an independent correctness fix: allocator forwarding for
bounded sequences of structs, with a regression test. It should be its own PR and release,
not tied to experimental design work.

**6.2 (L) Experimental gating is correct.** `@experimental_managed_reference` and
`@experimental_managed_config` are rejected in the C++ and Java backends, and in C/Zig
unless `--generate-interfaces --no-typesupport` with no prefix. Production output is
unaffected. Add a removal or rename plan so experimental annotation names don't become
de facto ABI.

**6.3 (H for the concurrency API) Managed references are on the critical path.** The
extension surface in §3.12 needs everything listed as missing in
`construction-reference-bindings.md`:

- managed reference ABI with an interface-identity fingerprint
- C++/Java wrappers
- inout replacement across bindings
- sequences of references
- construction-only TOML members
- mixed Config clone and rollback

This is a substantial generator project, and none of it is needed for the *standard* DDS
API. That is the strongest argument for §3.12's smaller v1 surface.

**6.4 (M) The ABI draft has per-view provider indirection** (`managed-reference-abi-draft.md:37-42`:
provider, owner_context, adjusted_target, interface_dispatch). Fine for control-plane
objects such as runtimes and groups. Ensure this model is never used for hot-path entity
handles (writers and readers), where the existing box/fat-pointer should stay. Say so
explicitly.

**6.5 (M) Borrowed and bounded decoding is an embedded prerequisite.** The zidl roadmap
entry notes that bounded sequences use **inline storage**, so a broker `Frame` value is at
least 1 MiB and an `OriginRecord` at least 512 KiB (`broker-storage-contract.md:12-14`).
The storage contract correctly moves the broker to borrowed views. The same generator
limitation affects any user IDL with large bounds on MCU. Prioritise the generic
borrowed-decode and allocator-backed bounded mapping in zidl, not only for the broker.

**6.6 (L)** `managed-reference-abi-draft.md:92-94` notes LeakSanitizer was disabled
because of ptrace restrictions. That is fine for a probe. Just don't cite it as leak
coverage.

---

## 7. Suggested actions before merging PR #93

**Must**

1. Move the SPDP domain-ID wire change (`spdp.zig`, `rtps_discovery.idl`,
   `test/discovery/*`) to its own PR with a CHANGELOG entry and a dds-rtps interop run.
2. Remove the prototype from the default `test`, `test-release-small`, `emit-tests` and
   `test-tsan` graphs. Keep the dedicated steps.
3. Consolidate the docs (§2.1): about 8 normative docs, archive the rest, and resolve the
   contradictions in §3.11 and §5.12.
4. Remove the personal path, fix the cross-repo link, and strip "working tree" and
   local-hash text.

**Should (to be a usable implementation baseline)**

5. Add the write, send and receive fast-path contract with operation-count budgets, and
   define when tickets and the gate apply (§3.1).
6. Add batching and coalescing, and a priority-class seam (§3.2, §3.5).
7. Decide prepared read/take for native bindings (§3.6) and the best-effort historical
   wait rule (§3.7).
8. Write the cooperative/MCU profile with a static-memory worksheet (§3.8).
9. Broker: presence redesign or cadence (§5.2), final/appendable bodies (§5.3), stream
   consolidation (§5.5), bootstrap size fix (§5.6), constrained-client profile (§5.9),
   reconnect token (§5.7).

**Could**

10. Shrink the v1 public extension surface (§3.12) and the broker v1 feature set (§5.1).
11. Add CI for the design models and golden vectors, or declare them historical (§2.2).
12. Split the zidl allocator-forwarding fix into its own PR (§6.1).
