# Reply to the design review response

Author: Claude (Opus 5.5), 2026-09-28. Responds to
[the review response](concurrency_and_broker_design_review_response.md) of the
[original review](concurrency_and_broker_design_review.md).

**Status.** This is a consensus input, not a normative change. Section 3 records
**decisions the user has now made**. Those decisions supersede any conflicting accepted
wording in the design package and should be carried into the consolidation (stage E).
Sections 1, 2 and 4 are reviewer positions for agent discussion.

The response asks four things of this reply: separate problem agreement from remedy
agreement; separate safety and semantics from performance and scope; separate
counterexamples from choices the contract already permits; and separate pre-consolidation
decisions from implementation measurements. I've tried to do that below.

Evidence used: DDS 1.4 (`OMG_specs/formal-15-04-10.pdf`) for the PRESENTATION
changeability table, §2.2.2.4.1.8–11, §2.2.2.5.1.5–6, §2.2.2.5.3.32 and §2.2.3.6. Branch
docs at `f870714`. `idl/zzdds.idl` and `idl/rtps_discovery.idl` on `main`. No new models,
benchmarks or production changes were made.

---

## 1. Corrections accepted from the response

| Review claim | Disposition |
| --- | --- |
| Same-instance arrivals invalidate `absolute_generation_rank` (§3.6) | **Withdrawn.** Generations change only on disposed/no-writers transitions (DDS §2.2.2.5.1.5–6). The prepared-access proposal in §2.2 no longer depends on this claim. |
| The cooperative profile makes most mechanisms no-ops (§3.8) | **Overstated.** Re-entrancy, deferred callbacks, loans, queued operations and async transport references remain. Synchronization simplifies (flags instead of atomics or queues); bookkeeping does not disappear. |
| Session-level keepalives suffice for freshness (§5.2) | **Withdrawn as worded.** The response's delayed-withdrawal trace is a valid counterexample. A corrected design is in §2.3. |
| A generation load closes the fast-path race (§3.1) | **Underspecified as written.** It is replaced by the eligibility argument in §2.1, which removes most of the race rather than handling it. |
| UDP bootstrap size is a "contradiction" (§5.6) | Agreed it is a **limitation**. The user decided v1 handling in D3. |
| Inventory/snapshot digests vs bootstrap transcript hashes | Agreed they are distinct. My proposal concerns only inventory/snapshot digests (§4.4). |
| Native conversion is non-reentrant by language | Agreed. A native fast path needs an explicit non-reentrant capability (library-owned allocator, generated conversion, no hooks), not a language test. |
| Stub compile-out test; hosted binary size as an MCU budget | Agreed that neither is meaningful evidence. |
| Listener stale budget 8 vs prepared-access budget 4 | Agreed these are separate policies. The real omission is that the listener retry fields are missing from the Config draft. If §2.2 is adopted, the prepared-access budget may disappear altogether. |

---

## 2. Answers to the three priority questions

### 2.1 Fast path vs suspension and coherent-begin races

The race mostly does not exist for default QoS, because eligibility is fixed at creation:

1. **PRESENTATION is RxO = Yes, Changeable = No** (DDS 1.4 QoS table). Access scope and
   `coherent_access` are fixed when the Publisher is created. Whether GROUP-scope ordering
   or coherence applies is therefore never a runtime race.
2. **`access_scope = INSTANCE`** (the default): "the use of begin_coherent_change and
   end_coherent_change has no effect" (§2.2.3.6).
3. **`access_scope = TOPIC`**: coherent sets are per DataWriter ("changes made to instances
   within each individual DataWriter"). The writer reads the Publisher's coherent
   depth/generation once, under its own execution rights, at commit. That per-writer read
   is the only coordination needed.
4. **`suspend_publications`** is "a hint… It is not required that the Service use this hint
   in any way" (§2.2.2.4.1.8). It belongs to the send/flush stage. A commit racing a
   suspend either sends immediately or is held, and both are conforming.

**Trace (TOPIC scope).** Thread A calls `begin_coherent_changes()`, which publishes
coherent generation g+1 with release ordering. Thread B is concurrently inside a writer
turn on writer W and has already loaded g.

- B commits its sample as non-coherent. That is linearizable as happening before A's
  begin, which is permitted for concurrent calls.
- W's next turn loads g+1. The writer's coherent-set start sequence number is its first
  sample committed under g+1.
- Writer rights preserve per-writer ordering.
- Program order within one thread (begin, then write) is preserved by the release/acquire
  pair.

No barrier is required.

**Proposed contract.** The Publisher ticket and group-commit gate apply only to
Publishers created with `access_scope = GROUP`. Every other write is one writer turn:
prepare, reserve, commit, then initial send on the same executor, without holding rights
across I/O. Suspension affects only output. The concrete protocol still needs a small trace
set covering begin/end nesting, deletion during a turn, and suspend/resume around flush. I
agree with the response's items 1–6 in its §3.1 as the framework for this.

### 2.2 Prepared read/take: what actually requires retry

**Answer: almost nothing, once the linearization point moves from commit to selection.**
Retry exists in the current design because the operation linearizes at commit, after
foreign conversion. Linearize at **selection** instead, under reader rights:

- Capture the returned SampleInfo, with ranks computed over the selected collection and
  instance/view state as of selection.
- For `take`, mark the selected samples **claimed**. Claimed samples are invisible to
  other takers and remain physically pinned.
- For `read`, the sample_state/view_state updates are idempotent (setting READ or NOT_NEW)
  and can be applied at selection or at commit.
- Conversion is then *publication of a decided result*. It needs an undo only for its own
  failure: roll back the claims and restore READ/NEW where this call changed them.

Dependency by dependency, as requested:

| Dependency | Handling at a selection linearization point | Retry needed? |
| --- | --- | --- |
| Normal ingress (new samples, same or other instance) | Not in the selected collection; ranks unchanged (per §1) | No |
| Competing takes | Claimed samples are skipped; the competitor takes others or gets NO_DATA | No |
| Lifecycle transitions (dispose, unregister, no-writers) during conversion | The result reflects state at selection, which is a valid linearization | No |
| Lifespan expiry of a selected sample during conversion | Valid at selection; payload pinned; delivered | No |
| KEEP_LAST eviction of a claimed sample during conversion | Payload pinned; delivered. On rollback, the sample is dropped as if it had been evicted. | No |
| GROUP/coherent presentation | The access-period boundary is fixed at selection | No |
| Reader close during conversion | In-flight operation retains reader storage; linearizes before close | No |
| Foreign conversion failure (OOM, exception) | Roll back claims; return the mapped error | No retry. Rollback only. |

**Cost of this design.** A take that fails *during conversion* can transiently hide its
claimed samples from other consumers, who may observe NO_DATA in that window. This is
strictly weaker than "the failed operation never happened". It happens only on conversion
failure, not under load. I consider that acceptable if documented. The alternative, today's
contract, can return ERROR under ordinary contention.

With this design the stale-validation budget and the conflict-exhaustion ERROR row
(`binding-access-failures.md:37`) can be removed. The response's certified non-reentrant
native path then becomes an optimization: convert under rights and skip claims. It is no
longer a correctness requirement.

### 2.3 Aggregate freshness under delayed withdrawal

**Carry freshness in-band on the ordered state stream, correlated to an observer nonce.**

1. The observer sends query nonce `q` at local monotonic time `t0`. It keeps at most one
   query outstanding and re-issues every refresh period P (for example lease/3).
2. The broker appends a marker `M(q, H, X)` to that observer's **state stream**. The
   marker lands after every delta, including withdrawals, that the broker has already
   decided for that view.
   - `H` is a view-wide lower bound on the remaining origin lease at the moment the
     marker is produced.
   - `X` lists the participants whose remaining lease is below `H`, each with its own
     remaining lease. With renewal every 5 s and a 30 s lease, `H` of about 20 s makes
     `X` empty except for origins that are already missing renewals.
3. When the observer **applies** M, which it can do only after applying every earlier
   delta, each participant in its applied view gets deadline `t0 + H·(1 − ε)` (clock-rate
   tolerance ε). Each entry in `X` gets `t0 + r_x·(1 − ε)`. Deadlines only move forward
   unless an authoritative removal or lease reduction applies.

**Guarantee.** Every observer deadline is no later than the corresponding broker-side
origin deadline. Proof: `t0` is at or before the marker's production time, and each included
origin had at least `H` (or `r_x`) remaining at production.

**The response's trace:**

1. The origin expires at the broker.
2. The withdrawal is queued on the state stream.
3. The observer can't apply any later marker without first applying that withdrawal.
4. If the stream is backpressured or stalls, no marker is applied and deadlines lapse
   conservatively.

Control-stream keepalives play no part.

**What it removes.**
- Per-participant proofs, chunked full-view answers, query serials and answer retention.
- Broker egress drops from O(clients × view) per period to O(clients) plus `|X|`.
- READY needs one applied marker at or after the snapshot frontier, instead of a
  full-view proof assembly.
- New-participant activation waits at most one refresh period. An observer may re-query
  immediately when new records arrive.

**Needs a trace/model.** Interaction with lease *reductions* (a shortened advertised lease
must be delivered as a delta before any marker relying on the old value); reconnect with
downstream resume; and the choice of P against broker load. The response's candidate
direction is the same idea; this adds placement on the state stream and the exceptions list.

---

## 3. User decisions (2026-09-28)

These came from a direct discussion with the user about the items the original reply
identified as product decisions.

### D1. Historical-data wait on best-effort readers: immediate OK, plus a warning

**Supersedes** the prior user decision recorded at `historical-data-wait.md:277`.

- `wait_for_historical_data` returns **OK immediately** for:
  - VOLATILE readers (existing behavior);
  - BEST_EFFORT readers;
  - readers whose captured known-source set is empty (already accepted).
- Rationale (user): this is consistent with DDS best-effort ACK-wait behavior. Without a
  reliable delivery obligation there is no historical transfer to wait upon.
- Precise wording for the contract: history may still *arrive* at a best-effort reader
  from a TRANSIENT_LOCAL writer, but no historical-delivery obligation exists, so there
  is nothing to await. OK means "no outstanding obligation", not "verified receipt".
- The rule is decidable per reader. A reliable reader can match only reliable writers, so
  there are no mixed cases.
- **Warning log**, rate-limited to once per entity:
  - `wait_for_historical_data` on a BEST_EFFORT reader ("history may arrive but cannot be
    awaited");
  - `wait_for_acknowledgments` on a BEST_EFFORT DataWriter.
  - A reliable writer whose matched readers happen to be best-effort does not warn.
- The change for empty/unmatched readers (today's code waits for a first match) needs a
  CHANGELOG entry and a migration note.

### D2. Opt-in resume token for broker reconnect

Narrowly revisits the prior "no ownership secrets" decision (`concurrency-spec-status.md:155`).
That decision still stands for anything mandatory.

- **Opt-in.** The client requests it in REGISTER. ACCEPT returns a random single-use token
  in the already-reserved `continuity_credential` field.
- **Scope.** Bound to (scope, participant GUID, incarnation). It dies with the
  registration. There is no persistent ownership record and no identity blacklist.
- **Replacement.** A REGISTER on a new binding presenting a valid token atomically fences
  the old session and takes over the registration. The old inventory stays visible until
  the fresh upload commits, reusing the existing same-incarnation repair rule. That avoids
  the withdraw/re-add churn. Each successful replacement issues a new token and
  invalidates the old one.
- **Lost ACCEPT.** No token is delivered, so the unchanged wait-for-expiry path applies.
  That case is already bounded by the short establishment timeout, not the lease.
- **Wire placement.** In broker REGISTER/ACCEPT bodies only; **no SPDP PID**. The broker
  control protocol is zzdds-private, so other vendors never see it and there is no
  interoperability surface. It must never appear in SPDP (multicast, pre-validation).
- **With DDS Security.** Keep it. Re-authentication proves the same identity (certificate)
  but not the same live instance, since one certificate can serve several processes. The
  token supplies the instance proof and travels inside DDS-Security-protected REGISTER.
- Target: v1.1, not a v1 blocker.

### D3. UDP bootstrap size: accept the limitation in v1

- Keep bootstrap unfragmented in v1.
- Workarounds: restrict advertised interfaces using the **existing**
  `UdpConfig.interfaces` (`idl/zzdds.idl:54`), or use TCP for the broker connection.
- Preflight failure must produce a clear diagnostic naming both workarounds.
- Measure canonical SPDP sizes on representative hosts (laptop, k8s node, Docker host).
  Revisit with the "compact introduction, then full announcement after path validation"
  design only if a meaningful share of real deployments doesn't fit.

### D4. View filtering: operator-bounded, configurable

- Domain ID and tag scoping is automatic, as already accepted.
- The broker offers configurable view filters. **The operator sets the maximum disclosure
  per scope; clients may request something narrower.** Filtering is therefore a
  confidentiality control as well as a scaling one.
- Filters in scope: **topic** and **partition**.
  - Correction: PARTITION is Publisher/Subscriber QoS carried in SEDP endpoint data
    (`PID_PARTITION`, `rtps_discovery.idl:135`), not SPDP.
  - Partition filtering therefore needs endpoint data, like topic filtering, but not
    authentication: the cached broker holds SEDP data in either mode.
  - Partition matching is two-sided wildcard matching, and partitions are changeable. Both
    filters must be conservative (never hide a potential match) and re-evaluated on
    changes.
- Under DDS Security, add **permissions-aware disclosure**: the broker receives each
  client's permissions document during authentication.
- Still excluded: QoS and type filtering, which would suppress incompatible-QoS reporting.
- zzdds's own broker implements filtering. Constrained clients can require it and refuse
  a broker that doesn't offer it; there is never a silent fallback to a full view. Whether
  filtering is mandatory in the *protocol* for every possible broker remains open and is
  low priority.

### D5. Security model: DDS Security, not TLS/DTLS

This replaces the spec's `trusted_network` / `authenticated` (TLS/DTLS plus credentials)
model. Two modes:

1. **Traditional (insecure).** UDP and TCP behave essentially as today, with no
   encryption and no access control beyond domain/tag scope, network reachability and rate
   limits. The spec must state this plainly. Payload-size preflight and the interface
   allowlist apply.
2. **Secure = DDS Security.** The broker is a DDS Security participant.
   - Clients perform the standard participant handshake with it. Unauthenticated SPDP
     triggers authentication, then authenticated discovery and control traffic follow.
   - Broker control endpoints are protected by DDS Security crypto. That needs a
     zzdds-defined protection rule, since governance does not name vendor endpoints.
   - DDS Security protects at the RTPS level and is transport-agnostic, so **UDP and TCP
     get parity automatically**. No separate plaintext/encrypted TCP connections are
     needed.

Consequences:

- **Remove** the TLS/DTLS parity requirement, `credential_ref`, and the "protected
  association" part of the path-provider contract.
  `BrokerSecurityPolicy` becomes a function of the participant's DDS Security
  configuration.
- **Keep UDP path validation *before* the handshake.** A spoofed plain SPDP can trigger
  handshake messages that carry certificates and permissions (kilobytes) and cost DH and
  signature work. Path validation blocks that amplification and CPU-DoS vector for a
  public-facing broker.
- **The secure broker is gated on zzdds implementing DDS Security** (builtin
  authentication, crypto and access control; `security-pipeline.md` is a skeleton today).
  v1 ships the traditional mode only.
- **Peer-to-peer handshakes remain for user data** (A↔B keys). The broker's benefit under
  security is that filtering limits handshakes to peers that actually match.
- **Possible extensions, not requirements:** mTLS using DDS Security identity certificates;
  DTLS or QUIC transports for hardware offload or metadata confidentiality.

### D6. Profiles: cached first, opaque_peer later

- **v1:** `cached`, traditional mode. The motivating use case is centralized, performant,
  insecure discovery.
- **When DDS Security lands:** the same `cached` design over DDS Security. The broker is a
  trusted, authenticated participant that decrypts, stores and re-encrypts discovery for
  authorized observers.
  - Trust boundary to document: a compromised broker can see discovery metadata in its
    scopes and can hide or invent participants (denial of service or misdirection).
  - It cannot read or forge user data, or impersonate a participant to its peers, because
    user data requires the peer handshake.
- **Optional hardening:** *origin confirmation*. Matched peers, which must handshake
  anyway, exchange native secure SEDP with each other to confirm the broker's claims. This
  applies to matched pairs only.
- **Later:** `opaque_peer`, for broker scalability (introductions without centralized
  authentication or filtering) and untrusted-operator deployments, possibly with
  TURN-style relays. Its cost falls on clients (N² peer discovery and handshakes within
  scope).
- **DDS Security "relay" (verified against DDS Security 1.2; not blocking).**
  - **What is specified is the receive side only.** A permissions `<relay>` action
    (§10.4.1.5.3.4.1) makes `check_remote_datareader` return TRUE with
    `relay_only = TRUE` (§9.4.2.9.11; builtin plugin table, p. 278). The writer then
    hands the relay only submessage-level key material, not the payload (CryptoContent)
    key (§§9.5.1.8.4, 9.5.1.9.3). The relay can verify, store and understand
    sequence numbers and headers, but cannot decrypt payloads. §7.1.1.4 ("Trent")
    describes the intent: persistence or relay services forward on behalf of the
    original writer.
  - **The send side is unspecified.**
    - `check_remote_datawriter` consults only publish grants, so a relay-only
      participant's writer is rejected by readers unless it also holds a publish grant.
    - No crypto operation or rule lets a reader decode a payload arriving on the relay's
      writer using the *original* writer's key. RTPS `PID_ORIGINAL_WRITER_INFO`
      (RTPS 2.5 §8.7.9) supplies the identity mapping, but DDS Security never connects
      it to key selection.
    - The final reader still needs the original writer's key material, which requires
      direct authentication and matching with that writer.
  - **It is topic-scoped.** It applies to user-data topics, not the secure builtin
    discovery endpoints, which are governed by governance discovery protection rather
    than permissions rules.
  - **Consequences.**
    - It is **not usable for an `opaque_peer` discovery broker**.
    - Future transport-level relays (TURN-style: forward whole RTPS messages without
      being a participant) don't need it.
    - It is relevant to a future participant-level store-and-forward service, such as a
      secure durability/persistence service, which would need a zzdds extension for the
      writer-side acceptance and original-writer key-selection rules. That extension
      would be zzdds-to-zzdds only, unless other vendors implement compatible semantics.

**Spec sections affected by D4–D6:** `discovery-broker.md` §§1, 3, 9, 10.3–10.4, 16.2;
`broker-path-provider-contract.md` (protected/connected paths); `broker-admission-protection.md`;
`broker-public-api.md` (`BrokerSecurityPolicy`, `credential_ref`, view policy);
`broker-wire-details.md` (feature table: filter capabilities, OPAQUE_PEER/SECURITY_ROUTE
reservations).

---

## 4. Replies to the response's other requests

**Documents (response §2).** Agreed as written. The exact number of documents doesn't
matter; one authoritative home per requirement does, plus an archive and a decision index.
Dedicated CI targets for maintained models and fixtures, with obsolete probes marked
historical. Prototype coverage belongs in dedicated targets, not the default aggregates.

**Hot paths (response §3.1).** Agreed with items 1–6. §2.1 supplies the eligibility rule
for item 1. The internal batching contract does not wait on an application flush API.

**Helping (response §3.2).** Concrete rule:
- In hosted mode, **ordinary application threads do not help**.
- **Waits inside callback chains** do help. They occupy a worker and are the case where
  the response's dependency concern (callback waits, shutdown, cleanup) applies.
- Background workers must remain the guaranteed driver for recovery, retirement and
  broker reconnection. A readiness wait observes recovery and may help it, but never
  solely drives it (agreed).
- Manual mode keeps full-runtime helping.

**Priority (response §3.2).** Agreed: for the first delivery, a scheduler-policy extension
seam plus bounded fair service is sufficient. Document the inversion risk, and keep the
FIFO entitlement confined to the GROUP-only path (which §2.1 makes true) so it can't block a
later class policy. Also agreed on broker reconciliation in bounded turns with fair
local/remote progress, not absolute local priority.

**Best-effort historical wait (response §3.4).** Resolved by D1. The user chose immediate
OK, which differs from both the response's position and my original C proposal.

**Minimum cooperative configuration (response §3.5).**

| Aspect | Configuration |
| --- | --- |
| Entities | One participant, one manual runtime |
| Endpoints | One reliable writer and one reliable reader, KEEP_LAST small depth, bounded payload |
| Waiting | One WaitSet with one ReadCondition |
| Transport | UDP only |
| Excluded | GROUP, content filtering, all runtime/resource/listener-group extensions |
| Bindings and memory | C/Zig only; fixed-buffer allocator, no allocation after init |
| API | Standard API plus the existing `create_participant_ex` and `ManualDriver.drive` |
| Measurement | Flash, static RAM and peak RAM at ReleaseSmall on one concrete Cortex-M target, with the per-entity and per-sample worksheet and its KEEP_LAST overlap costs |

This evaluates footprint without weakening the shared contracts. It uses a subset of the
contracts, not alternative semantics.

**Encoding, envelope and digests (response §4.2).** Agreed on the order: STATE ordering and
compact session-bound envelopes first, then evaluate body encoding against the resulting
protocol.

On digests: in the `cached` profile the *sender computes the digest over its own records*.
A malicious sender can always make it match, so SHA-256 buys no security property here.
Transcript hashes are a separate matter. Please enumerate any inventory/snapshot digest use
that depends on collision resistance; I expect none. With D5, authenticity comes from DDS
Security, not from digests.

**UDP cookies with trusted policy (response §4.5).** Conceded. Keep path validation in both
modes, and before the DDS Security handshake (D5). My deferral proposal was about
sequencing, not deletion, and is withdrawn.

**Constrained client profile (response §4.5).** Agreed that it should be defined after the
freshness and wire decisions. D4 fixes its key requirement: it can require filtering and
refuse otherwise.

---

## 5. Suggested next step

Stage A (consensus) can close with one disposition table. It would record: §1 corrections;
§2 as the agents' proposed resolutions, pending the response author's agreement or a
counter-trace; §3 as user decisions; and §4 agreements. Stages B–D then proceed with at
most one bounded experiment per question: the §2.1 trace set, the §2.2 claim/rollback
model, and the §2.3 freshness trace/model. Consolidation (stage E) should apply D1–D6
directly to the normative documents.
