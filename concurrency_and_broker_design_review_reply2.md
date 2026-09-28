# Reply to the design review follow-up

Author: Claude (Opus 5.5), 2026-09-28. Responds to the
[follow-up](concurrency_and_broker_design_review_followup.md). Earlier documents in this
thread: [review](concurrency_and_broker_design_review.md),
[response](concurrency_and_broker_design_review_response.md) and
[reply](concurrency_and_broker_design_review_reply.md).

**Status: final consensus input before spec revision.** §5 records two new user
decisions (D7, D8). Everything else is a reviewer proposal answering the follow-up's three requests.
D1–D6 are not reopened.

Evidence used: RTPS 2.5 §8.7.6 (`OMG_specs/formal-22-04-01.pdf`), DDS 1.4
§§2.2.2.4.1.10–11, and the reasoning traces below. No models were executed and no code
or normative documents were changed.

## 1. Dispositions and qualifications

I accept the follow-up's disposition table and all of its D1–D6 qualifications, without
amendment. In particular:

- **D2:** the token is a continuity capability, not a process identity.
- **D4:** operator disclosure ceilings may intentionally hide matches, and insecure-mode
  filters prove nothing about a client's entitlement.
- **D5:** UDP/TCP parity still needs integration evidence, and path validation addresses
  only off-path amplification.
- **D6:** the claims about what the broker can and cannot do depend on the configured
  protection.

I also accept the "one writer turn" correction:

- Foreign conversion and allocator hooks run in preparation, before writer rights are
  acquired.
- Commit is the only step under writer rights.
- The initial send happens on the same executor after rights are released.

## 2. TOPIC coherent close and sealing (Traces A and B)

Agreed: a generation read on the next write does not complete a set on its own. The
follow-up's Trace A shows the gap. RTPS already provides the completion mechanism: a
writer's set ends on a DATA "that does not contain a coherent set in-line QoS parameter
or … SEQUENCENUMBER_UNKNOWN", and such a DATA "need not necessarily contain
serializedPayload", which lets a writer end the set "before the next data is written"
(RTPS 2.5 §8.7.6).

**Proposed protocol.** Applies only to Publishers created with `coherent_access = TRUE`
and `access_scope = TOPIC`. PRESENTATION is fixed at creation, so INSTANCE-scope
Publishers carry none of this.

1. **Publisher state.** A coherent depth and a generation G, protected by a short Publisher
   metadata lock. Only the outermost `begin_coherent_changes` opens a new G (with release
   ordering). Only the outermost `end_coherent_changes` marks G closed. Nested calls change
   only the depth.
2. **Per-writer resources, reserved at writer creation.**
   - One seal command record.
   - One history slot and sequence-number reservation for an end-of-set marker DATA (no
     payload, `PID_COHERENT_SET = SEQUENCENUMBER_UNKNOWN`).

   Sealing therefore cannot allocate or fail. The marker is a normal reliable change and
   is repairable.
3. **Commit under writer rights.** The writer acquire-loads the Publisher state and
   compares it with its own `local_set`:
   - Publisher open with G, and `local_set` is not G: start a set at this sample's
     sequence number.
   - Publisher open with G, and `local_set` is G: continue the set.
   - `local_set` is open but the Publisher is closed or has moved to G′ > G: first emit
     the end marker inline, then commit the new sample outside the old set (or at the
     start of G′).
4. **Outermost end.**
   - Mark G closed.
   - Post seal(G) to every writer of the Publisher, using each writer's reserved record.
     This avoids tracking which writers participated: cost is O(writers) per close, and
     closes are rare.
   - Return. `end` never waits for a writer and never holds Publisher rights while a
     writer turn runs.
5. **Seal turn (writer rights).** If `local_set` is G and still open, emit the end marker
   and close `local_set`. Otherwise do nothing. Delivery of the end marker to readers is
   ordinary reliable output. Nothing waits for acknowledgment.

**Traces.**

- **A (no subsequent write).** seal(G) runs as retained writer work and emits the end
  marker. Completion needs no further write.
- **B (late commit versus sealing).**
  1. W loads "open G".
  2. The closer marks G closed and posts seal(G).
  3. W commits its sample into G.
  4. W's seal turn is ordered after that commit turn, so the end marker follows the
     sample.

  The sample belongs to G. That is a valid linearization of a write concurrent with
  `end`. The set is never sealed and then extended, because the writer's own
  `local_set` defines the boundary and only writer turns change it.
- **Same thread, `end` then `write`.**
  - The write's acquire-load sees "closed" and ends the set inline before committing.
  - The queued seal becomes a no-op.
  - Independently, the admission rule "no direct execution ahead of older ready work"
    orders the write after the queued seal.
- **Nesting.** Only outermost transitions touch G.
- **Deletion.** Deleting a writer or Publisher with an open `local_set` leaves that set
  incomplete. Readers discard it, per DDS §2.2.2.4.1.10. No end marker is fabricated.
- **Writer created while G is open.** It joins at its first commit.

**Cost.** An INSTANCE-scope write pays nothing. A TOPIC-coherent write pays one
acquire-load and a comparison. Neither path uses a ticket, gate or ledger. GROUP scope
keeps the existing ticket and group-commit design.

**For the trace set:**
- nested begin/end across threads;
- `end` racing an in-flight writer turn (both orders);
- writer deletion with a pending seal;
- Publisher deletion during a close;
- seal with the reserved marker slot while history is full. The reservation guarantees
  this case; it should be tested.

## 3. Read/take contract (Traces C and D)

Trace C is correct: rolling back read-state is unsafe, because another successful
operation may depend on it. My earlier proposal is replaced by the following.

### 3.1 Two paths, chosen by conversion capability

- **Certified native path.** Generated C, C++ or Zig conversion using a library-owned
  allocator, with no foreign hooks: a non-reentrant capability, not a test of the
  language. Conversion runs under reader rights.
  - No claims, no retry, no rollback.
  - Fully linearizable.
  - Output storage can be reserved before selection, so no failure is possible after
    selection.
- **Foreign-conversion path.** Java, or any conversion that may re-enter DDS or run user
  code. Uses the claim contract in §3.2.

### 3.2 Claim contract (foreign path)

| Effect | When applied | On conversion failure |
| --- | --- | --- |
| sample_state → READ, view_state → NOT_NEW (read and take) | Committed at selection | **Retained.** These are forward-only transitions and are never rolled back, which resolves Trace C. Other operations may rely on them. |
| Take removal | Tentative: the sample becomes **claimed** at selection | **Restored** in its original position (D7), unless the sample has since become ineligible (below) |
| SampleInfo returned (ranks, counts, states) | Captured at selection, with ranks computed over the selected collection | Discarded with the failed output |

Other rules while a sample is claimed:

- **Visibility.** Other takes and reads skip it. ReadCondition/QueryCondition evaluation
  and WaitSet triggers treat it as taken. GROUP ordered access treats it as consumed,
  which is consistent with the accepted shared-consumption brackets.
- **Retention.**
  - The payload stays pinned in place.
  - A claimed sample still counts toward history depth.
  - If KEEP_LAST replacement or lifespan expiry would remove it during the claim, it is
    removed normally; rollback then does not restore it.
  - Instance lifecycle changes during the claim are recorded on the instance as usual. A
    restored sample keeps its per-sample generation counts, so ranks are computed
    correctly at the next access. Rollback never overwrites instance-level state.
- **Restoration signals.** Restoring samples re-evaluates conditions and wakes waiters,
  exactly like a new arrival.
- **Slow successful conversion.** Hiding claimed samples in this case is not a weakening:
  that take is linearized at selection.
- **Reporting.**
  - A take that fails after selection reports the failure with effect phase
    "state effects committed, samples restored". It uses the existing ERROR or
    OUT_OF_RESOURCES mapping with that phase.
  - A read that fails after selection reports "state effects committed, output
    discarded".
  - Failures before selection keep "no effect".
- **Retry machinery.** The foreign path has no stale-validation retry, and no
  conflict-exhaustion ERROR row.

### 3.3 Explicit weakenings of failed-call isolation

1. **Take failure visibility (D7, user-approved).** A take that fails after selection can
   make its samples temporarily invisible. Concurrent takers may observe NO_DATA, and the
   samples then reappear. This is the only non-linearizable history in the contract.
   Foreign-conversion path only.
2. **Retained read-state effects (D8, user-approved).** A read or take that fails after
   selection leaves the selected samples READ and their instances NOT_NEW. No data is
   lost. An application filtering on NOT_READ or NEW may skip those samples on its next
   call. Foreign-conversion path only. The rejected alternative was deferring these
   effects to commit, which is non-linearizable for overlapping reads, as in the
   follow-up's Trace C.

### 3.4 Validation

A bounded model or trace set covering:
- two takers with one failing;
- a read concurrent with a failing read (Trace C);
- KEEP_LAST eviction during a claim;
- dispose and rebirth during a claim;
- a GROUP ordered-access consumer skipping claimed samples;
- condition and WaitSet wake on restoration.

Negative controls: rolling back read-state, and restoring an evicted sample.

## 4. Aggregate freshness marker: requirements confirmed, exception policy chosen

All seven of the follow-up's requirements are confirmed. Concrete choices:

1. **Frontier.** The marker `M(q, view_generation, delivery_seq, H, X)` covers exactly the
   records in the observer's view as applied up to `delivery_seq`, with matching
   incarnations. Later additions and replacement incarnations get nothing from it. READY
   needs one applied marker at or after the synchronization cut.
2. **Expiry at capture.** Building a marker runs expiry evaluation for that view against
   actual origin deadlines. Any origin whose deadline has passed is withdrawn before the
   marker in the STATE stream; no pending timer task can leave it inside the marker.
3. **H and exceptions.**
   - H is a common horizon for the non-exception set: every such origin has at least H
     remaining at capture.
   - Each entry in X carries its own remaining lease `r > 0`. An entry with `r = 0` means
     "no validity from this marker": existing evidence is kept, not extended.
   - Markers only extend deadlines (max-merge). Deadlines shrink only through
     authoritative withdrawal or lease-reduction deltas.
4. **Bounded exception policy: adaptive H with negotiated `Xmax`.**
   - Session limit `Xmax`, with a default on the order of 64, to be tuned by measurement.
   - The broker lowers H until `|X| ≤ Xmax`.
   - No chunking. Failure never extends validity.
   - Under correlated renewal failure, H collapses toward the smallest remaining lease.
     Observers then expire those participants conservatively, which is correct because
     they are missing renewals, or re-query sooner: the client schedules its next query
     at roughly `t0 + H/2`, bounded by a minimum interval.
   - Worst-case egress is O(clients × Xmax) per refresh period.
   - Activation latency for new records is at most one query period, or immediate if the
     observer re-queries when new records arrive.
5. **Correlation and replay.**
   - One outstanding nonce per observer session and view.
   - Retries keep the original `t0`.
   - A nonce is consumed on first application. Duplicate markers, markers for abandoned
     or superseded nonces, and markers from a previous session or view generation are
     ignored.
   - RTPS still retains the marker's bytes until they are acknowledged. The marker is
     small and O(Xmax).
6. **Clock and reductions.**
   - Assumption: relative monotonic clock-rate error between observer and broker is at
     most ε, configured conservatively. Observer deadlines are `t0 + H·(1−ε)` and
     `t0 + r·(1−ε)`.
   - A lease reduction or authorization change decided before a marker is built is
     reflected in that marker. One decided after it is ordered after the marker in the
     STATE stream, and caps the deadline when applied.
   - A stale marker therefore cannot outlive a reduction.
7. **Resume and backpressure.**
   - A new session requires a new nonce. Old markers cannot apply.
   - A stalled STATE stream stops markers from applying, so deadlines lapse
     conservatively.
   - Control-stream progress and resynchronization remain available.
   - Traces: healthy renewal, a single failing origin, widespread renewal failure,
     reduction racing marker construction, and reconnect with resume.

Replacing the per-origin query/chunk/serial machinery should wait until this trace set
supports the safety claim and the worst-case numbers above.

## 5. User decision

**D7 (2026-09-28). A take that fails after selection restores its claimed samples.**
This applies to the foreign-conversion path. The observable consequence (§3.3 item 1) is
accepted. The alternatives are rejected:

- keeping the samples removed (linearizable, but data is lost);
- keeping optimistic validation (ERROR under contention).

**D8 (2026-09-28). Read-state effects survive a failed read or take.** On the
foreign-conversion path, READ and NOT_NEW transitions committed at selection are
retained if conversion then fails (§3.3 item 2).

**Required documentation.** The normative read/take contract and the binding user docs
must include a known-limitation note covering four points:

- **Condition:** with bindings that use the foreign-conversion path (e.g. Java), a read
  or take that fails after selection (for example OOM, or an exception from conversion
  code) still marks the selected samples READ and their instances NOT_NEW.
- **Consequence:** a later read/take filtered on NOT_READ or NEW (sample-state or
  view-state masks, or equivalent ReadCondition/QueryCondition masks) may skip those
  samples, even though the application never received them.
- **Workaround:** after such a failure, retry with ANY sample and view state masks,
  i.e. no state filter. More generally, applications that cannot tolerate this should
  avoid state filters on these bindings.
- **Scope:** the certified native path (generated C, C++ or Zig conversion) cannot fail
  after selection and is unaffected.

## 6. Next step

With §2–§4 answered and D7–D8 recorded, the follow-up's §5 revision sequence can start.
Record D1–D8 and these dispositions in the decision index. Carry D8's known-limitation
note into the normative read/take contract and the binding documentation. Then revise the
access/progress contracts, broker STATE/freshness/framing, API/security/filtering scope,
and finally consolidation. Each of the three trace sets above is a single bounded
experiment with a clear stopping condition.
