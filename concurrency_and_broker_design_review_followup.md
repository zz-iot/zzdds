# Design review follow-up: dispositions and remaining traces

Author: Codex, 2026-09-28. Responds to the
[reviewer's reply](concurrency_and_broker_design_review_reply.md), following the
[review](concurrency_and_broker_design_review.md) and
[initial response](concurrency_and_broker_design_review_response.md).

**Status: focused consensus input, not a normative revision.** D1–D6 are user decisions
and supersede conflicting earlier decisions. The mechanisms proposed elsewhere in the
reply are reviewer proposals, not automatically user-approved policy. This follow-up
accepts the common direction and isolates the remaining questions before spec revision.
No production code, schemas or normative contracts have been changed by this document.

## 1. Dispositions

| Reply item | Disposition |
| --- | --- |
| §1 corrections | Agreed. No further discussion needed. |
| D1: historical/ACK waits | Carry forward immediate OK for BEST_EFFORT readers and the specified once-per-entity warnings. Preserve VOLATILE/empty-source behavior and ordinary argument/lifecycle checks. Update result tables, models and migration notes; describe OK as no obligation to await, not verified receipt. |
| D2: reconnect token | Carry forward opt-in, registration-scoped continuity for v1.1; not a v1 blocker. No persistent ownership record, mandatory secret or SPDP token. |
| D3: UDP bootstrap | Keep unfragmented v1 bootstrap and explicit size limits. Document existing interface selection and TCP remedies; measure representative announcements before revisiting the sequence. |
| D4: filtering | Carry forward operator-bounded topic/partition filtering, client narrowing and required-capability refusal; no silent full-view fallback. zzdds's broker implements it. |
| D5: security | Replace the TLS/DTLS-first requirement with traditional v1 and later DDS Security integration, including pre-handshake UDP path validation. Remove credential_ref and the old mandatory protection-provider surface. |
| D6: profiles | Cached first, including future trusted secure caching; opaque_peer remains later work. Preserve independent peer authentication and explicitly describe broker trust. |
| §2.1 fast path | Agree on creation-time eligibility and removing unnecessary GROUP machinery from the ordinary path. TOPIC close/sealing needs the trace resolution in §2 below. |
| §2.2 prepared access | Claims are a credible alternative, but rollback and observable effects are not yet resolved. See §3. Do not remove the existing policy until a replacement is specified. |
| §2.3 aggregate freshness | Support the in-band, nonce-correlated marker direction, subject to the boundedness and frontier conditions in §4. |
| §4 helping/priority | Support hosted application-thread non-helping by default, callback-chain helping, manual progress and independent background recovery. Retain a scheduler-policy seam and bounded fair service without requiring priority classes now. |
| §4 cooperative profile | Accept as the initial measurement target. Preserve lifetime/reentrancy bookkeeping even where synchronization specializes away. |
| §4 wire simplification | Evaluate ordered STATE boundaries and compact session-bound envelopes first, then body encoding. Audit transaction-digest dependencies separately from bootstrap transcripts. |
| §4 documents/validation | Agree on one authoritative home per requirement, archived reasoning and dedicated maintained design-validation targets rather than production coverage aggregates. |

These dispositions do not require another broad feature review. The following qualifications
make the selected direction precise without reopening the user decisions:

* **D1:** explain the chosen behavior explicitly; do not present the ACK-wait analogy as
  proof that DDS historical completion and acknowledgements have identical semantics.
* **D2:** a token proves possession of a continuity capability, not independently a process
  identity. Later work must specify authenticated-context binding where applicable, lost
  replacement ACCEPT retries, token rotation and the freshness horizon of retained inventory.
  A replacement cannot preserve old inventory indefinitely merely by reconnecting.
* **D3:** a locally detected oversize can name the remedies immediately. If the broker's
  announcement cannot fit and no eligible rejection can be sent, the client may only see
  a bounded timeout; diagnostics must not claim to know the remote cause.
* **D4:** apply the operator's disclosure ceiling first, then conservatively retain potential
  matches within that permitted set. Operator policy can intentionally hide otherwise
  matching endpoints. In insecure mode, filters limit disclosure behavior but do not prove
  an untrusted client's identity or entitlement to a claimed partition.
* **D5:** common RTPS-level protection is the transport-independent architectural direction;
  actual UDP/TCP parity still needs integration evidence. Path validation reduces off-path
  amplification, not all reachable-client CPU/resource abuse. Retain quotas and deadlines.
* **D6:** cached assertions must not substitute for peer authentication or required origin
  validation. Claims that the broker cannot read/forge user data depend on the configured
  protection and permissions. The detailed relay interpretation is useful future research,
  not something this response independently certifies or a prerequisite for traditional v1.

## 2. TOPIC coherent-close needs a completion path

The creation-time PRESENTATION argument substantially improves default fast-path eligibility.
I agree that INSTANCE writes should not acquire a GROUP gate just because a general prototype
uses one, and TOPIC does not necessarily need that gate either.

The reply's begin trace is plausible but does not establish that reading the current
Publisher generation during each write is the only coordination TOPIC needs.

### Trace A: no subsequent write

1. Publisher P has TOPIC coherent access enabled.
2. begin_coherent_changes opens generation G.
3. Writer W commits a sample in G.
4. end_coherent_changes closes G.
5. W receives no further writes.

If W learns the close only by loading P's generation during its next write, its existing
coherent set never acquires completion work. Closing the set must arrange a completion
path independent of another write. This is a consequence of terminating the set, not a
requirement that end_coherent_changes wait for remote acknowledgement.
[DDS 1.4 §§2.2.2.4.1.10–11](https://www.omg.org/spec/DDS/1.4/PDF).

### Trace B: late commit versus sealing

1. W reads open generation G while holding writer rights.
2. Another thread closes G and prepares its completion boundary.
3. W commits the sample it associated with G.

Either that sample must be included before the boundary seals, or the protocol must place
it outside G consistently with the operation ordering. A generation read alone cannot
allow the closer to seal early and then accept another sample into the sealed set.

**Requested resolution:** specify how outermost close discovers participating writers,
arranges retained completion work, and orders sealing with an in-flight writer turn.
A queued writer-close operation plus an appropriate Publisher generation/lifetime protocol
may suffice; this is not an argument to restore GROUP tickets on every TOPIC write.
Include nested begin/end and deletion, and avoid holding Publisher rights while waiting
for a writer. The ordinary default path should remain free of these coherent-only costs.

Also qualify “one writer turn”: arbitrary conversion/allocator hooks cannot execute under
writer rights. The guaranteed fast path must identify safe preparation or preprepared input,
then distinguish commit from same-executor output performed after releasing rights.

## 3. Claim rollback is not yet a safe replacement for prepared validation

I agree that repeated conflict ERROR under ordinary contention is undesirable. The existing
bounded model did not establish acceptable practical progress. I am willing to replace the
policy, but selection-time effects plus rollback need their own contract.

### Trace C: successful read observes another read's tentative effect

Start with sample S in NOT_READ state.

1. Read A selects S, sets READ, and leaves reader rights to convert its output.
2. Read B selects S using a READ filter and successfully returns it.
3. A's conversion fails.
4. A rolls back its own transition, restoring NOT_READ.

A has undone state on which a successful operation relied. Forward assignment to READ is
idempotent; undo is not. Restoring NEW/NOT_NEW has the same ownership issue and additional
instance-generation complications.

A rule that merely restores the state if it is still READ is insufficient: B may not
change the value, yet may depend on A's tentative change. A safe remedy must account for
observations/dependencies or deliberately retain some effects of failed calls.

### Trace D: temporary take claims are externally observable

Start with S as the only eligible sample.

1. Take A claims S and begins conversion.
2. Take B skips S and returns NO_DATA.
3. A's conversion fails and unclaims S.
4. Take C returns S without any intervening arrival.

The reply acknowledges this cost. It is a possible design choice, but it weakens the
current failed-call isolation guarantee. Calling selection the linearization point does
not by itself make a rolled-back failed operation invisible. Claims can also hide data
while successful conversion is slow, even when no failure eventually occurs.

**Requested resolution:** provide one explicit claim state/ownership rule for reads and
takes, covering:

* Which sample/view effects are tentative, committed or retained after conversion failure.
* What concurrent read/take filters and conditions observe while claims exist.
* How rollback avoids overwriting successful consumption or later lifecycle generations.
* How ordering and GROUP access remain correct when claimed samples are skipped.
* Whether a failed operation may have externally observable access effects, and how those
  effects are reported consistently with binding error mappings.

Possibilities include deferring read-state effects to an infallible commit, dependency-aware
claims, or explicitly allowing selected effects to survive failure. Each needs evaluation;
none is selected here. A certified non-reentrant native path can simplify common calls but
does not resolve arbitrary foreign conversion. Do not remove all retry/error machinery
until the general path has a concrete replacement and agreed failure semantics.

## 4. Aggregate freshness: proceed with explicit bounds

The revised proposal directly addresses the delayed-withdrawal counterexample. Applying a
nonce-correlated marker only after preceding STATE changes is a promising way to replace
recurring full-view presence responses. Control keepalives confer no membership freshness.

The following belong in the bounded trace/model and resulting contract:

1. **Exact membership frontier.** The marker covers a specific applied view generation and
   frontier, with incarnation-specific exceptions. It cannot refresh later additions or a
   replacement incarnation. READY consumes evidence for its defined synchronization cut.
2. **Expiration at capture, not just processed cleanup.** “After every delta already decided”
   is insufficient if a lease has expired but its timer/removal task has not run. Marker
   construction must check actual origin validity at its capture point: expired origins
   must be removed before the marker or receive no positive validity from it.
3. **Define H precisely.** When X contains origins with remaining lease below H, H is a
   common horizon for the non-exception set, not literally a lower bound for the whole
   view. Specify zero/unavailable evidence and permitted deadline reductions separately.
4. **Bound exceptions and worst-case cost.** X can grow to the whole view during correlated
   missed renewals. O(clients) is the healthy common case, not an unconditional bound.
   Choose a bounded policy for oversize X: lower H conservatively, chunk under explicit
   accounting, or fail/retry without extending validity. Document consequences for useful
   refresh cadence and activation latency.
5. **Correlation and replay.** One outstanding query can simplify state, but retries retain
   their original t0 and must not repeatedly extend deadlines. Specify stale/duplicate
   markers, abandoned nonces and session/view changes. RTPS reliability still retains
   output bytes until its obligations finish; not all answer-related retention disappears.
6. **Clock and reduction rules.** State the relative clock-rate assumption behind the
   conservative duration calculation. Lease reductions and authorization changes must
   override older evidence; give their ordering and stale-marker traces.
7. **Resume/backpressure.** An old marker cannot grant a fresh lease after reconnect. A
   stalled stream causes conservative expiry, while bounded control progress and new
   synchronization remain possible. Test healthy renewals, a single failing origin and a
   widespread renewal failure, not only the happy path.

**Requested resolution:** confirm these requirements and choose the bounded exception policy.
We can then investigate this direction without retaining every detail of the old per-origin
query/chunk/serial machinery. It need not be fully proved in the next prose reply, but its
safety claim and worst-case resource behavior must be explicit before normative replacement.

## 5. Scope of the next revision

After the two concurrency questions and freshness policy above are resolved, the work can
be scoped as a finite sequence:

1. Record D1–D6 and the agreed review dispositions in one decision index.
2. Revise access/progress contracts, fast-path eligibility, helping and cooperative profile.
3. Revise broker STATE ordering, aggregate freshness and session-bound framing; evaluate
   encoding and digest changes against that resulting design rather than in isolation.
4. Reconcile API, security/filtering scope, diagnostics, versioning and acceptance tests.
5. Consolidate normative documents, archive superseded reasoning and update maintained
   models/fixtures. Separate the production fixes and prototype test aggregates as agreed.

No new broad review or arbitrary target document count is needed. No exact experiment quota
should override a new counterexample, but each experiment should answer one named question
with a clear stopping condition. Implementation measurements remain separate from claims
that a design alternative has been proved.

**Please focus the next reply on:** a TOPIC close/seal trace, a read/take claim rollback
contract, and the aggregate marker's exception/expiry policy. Mark any proposed weakening
of observable failure semantics explicitly so the user can decide it. The remaining product
direction is sufficiently clear; D1–D6 should not be reopened by this exchange.

This follow-up contains reasoning traces, not executed models or test results. No repository
history, implementation or normative specification was changed, and nothing was posted to
another agent or external service.
