# Broker operation admission and effects

Status: first complete operation-table draft, 2026-09-17. Covers all 27 active IDL
operations. F1–F4 below have dispositions; cross-message validation remains subject
to the consolidated protocol review. It is a specification audit, not an executed protocol model.

## Shared validation before dispatch

Validate Frame bounds, encapsulation/options/padding, version, opcode and body encoding
before allocating decoded state. Validate required-member presence, singleton uniqueness,
unknown required members, exact consumption, sequence/aggregate bounds and arithmetic.
A successful generated deserialize does not establish these properties.

Bootstrap uses direct bodies and fixed version 1.0. Established traffic uses Envelope
and the selected version. Check scope, association/path, endpoint direction/class,
epoch/session/owner generation and negotiated features before effects. Recheck current
ownership at commit, not just receipt. Deferred callbacks carry the same registration
token; no old cleanup may remove a successor. Unknown optional fields cannot confer
unnegotiated behavior. Unsecured GUID identity does not bypass session checks.

Allocate/reserve operation state and mandatory result capacity before a state-changing
commit. Budgets cover per-operation, per-session and service aggregates. Resource refusal
is observable failure or session invalidation, never partial success. Frame receipt,
RTPS ACK, operation commit, APPLIED and listener completion are different boundaries.

The phases below are independent predicates, not a single linear state enum:

* **B**: bootstrap, including a recorded admission awaiting confirmation. Match the exact
  outstanding attempt/binding; no established Envelope is invented.
* **S**: current admitted session known to the client. The broker does not initiate
  established output until receipt of valid established control confirms ACCEPT receipt.
* **I**: an origin inventory generation is staging; **O**: current-session origin inventory
  committed. A session can stage a replacement while retaining a still-valid prior cut.
* **V**: a selected downstream view is staging or resumed; **A**: its baseline is installed.
  View synchronization and origin inventory can progress independently.
* **D**: closing/draining. No new work accepted; only bounded teardown/result handling.

Origin freshness and observer presence validity are additional predicates. S, O or A
alone never means fresh. READY is derived from the readiness contract; it is not a
permission required for all control traffic.

Streams: **boot** is best-effort fixed bootstrap; **ctl** reliable control; **state**
reliable record traffic. C = client, Bkr = broker. Native WLP uses direct participant
transports, not a broker stream.

Failure classes used below:

* **silent**: malformed/untrusted/stale uncorrelatable traffic; bounded diagnostics only.
* **bootstrap**: eligible ADMISSION_REJECT under its reply/disclosure budgets.
* **operation**: correlated REJECT or ERROR with no partial effect, or session failure
  if a safe mandatory result cannot be delivered.
* **view**: invalidate affected staging/view and request a fresh view; never skip a hole.

## Operation table

Every row inherits the shared checks. “Same” below means identical logical request and
content within its valid retention window, not merely a repeated RTPS sequence number.

| Code / operation | Direction; stream; phase | Additional checks and permitted effect | Duplicate / failure behavior |
| --- | --- | --- | --- |
| 4 ACCEPT | Bkr→C; boot; B | Outstanding REGISTER/introduction binding, scope, selected limits/profile/view/features, fresh session/generation, broker endpoints; inventory-required true; resume cursor/outcome agree; credential absent. Install mapping, not READY. | Same result idempotent. Conflicting result for one attempt fails admission; late results cannot replace a newer attempt/session. |
| 5 ORIGIN_BEGIN | C→Bkr; ctl; S | Current owner, increasing inventory generation, local cut, one participant plus bounded endpoint count/bytes; one active generation. Reserve complete declared staging and reconcile orphans. | Same BEGIN does not reset deadline. Conflicting generation/content aborts affected transaction; operation failure. |
| 6 ORIGIN_RECORD | C→Bkr; state; S/I | Generation/index, exact record bounds, local participant/incarnation ownership, kind/GUID and revision validity. Stage only; early items use bounded orphan budget. | Same index/bytes harmless; conflicting index invalidates inventory. No install before join with BEGIN/END. Operation failure. |
| 7 ORIGIN_END | C→Bkr; ctl; S/I | Generation/count/digest; exact indexed set and byte total, ordering/dependencies, current fence and freshness activation rules. Atomic inventory replacement after full validation. | Early END may wait within fixed deadline. Same completed transaction returns retained result; no second commit or timeout extension. |
| 8 MUTATE | C→Bkr; state; S/O | Complete owned record, revision high-water check, valid change/metadata and dependent participant. Reserve store/delta/result capacity; commit only against current owner and correct inventory baseline. | Same revision/bytes idempotent; changed bytes at same revision conflict. No early mutation staging; the accepted F1 barrier applies. |
| 9 COMMIT | Bkr→C; ctl; S | related_request and commit kind match retained inventory/mutation/close operation; applicable entity/revision/generation agree, unused fields zero. Advance only that operation's committed frontier. | Duplicate harmless; unknown/stale correlation cannot clear current pending work. A successful result never implies view synchronization. |
| 10 REJECT | Bkr→C; ctl; S | Correlated origin operation, inventory generation or entity/revision as applicable, legal error/recovery action. Fail that uncommitted attempt; preserve authoritative local state for repair. | Cannot contradict an already committed result. Conflicting outcomes require session recovery, not rollback of committed store effects. |
| 11 VIEW_REQUEST | C→Bkr; ctl; S | Negotiated view mode; resume feature, retained baseline/cursor and authorization compatibility; non-resume cursor zero. Reserve snapshot/delta retention or select valid resume. | Same request must not create another view. Client-assigned generation increases for new requests; old/failed generations cannot restart work. Operation failure or snapshot fallback where permitted. |
| 12 SNAPSHOT_BEGIN | Bkr→C; ctl; S/V | View generation/cut, count/total budgets, selected authorized mode; empty downstream snapshot allowed. Reserve staging and reconcile early items/deltas. | Same BEGIN idempotent without extending deadline; conflicting baseline invalidates view. |
| 13 SNAPSHOT_RECORD | Bkr→C; state; S/V | View/cut/index, complete record, entity dependencies and negotiated metadata semantics. Stage only; account early records as orphans. | Same index/bytes harmless; conflicting or over-budget data invalidates view. RTPS ACK cannot stand in for application retention. |
| 14 SNAPSHOT_END | Bkr→C; ctl; S/V | Matching generation/cut/count/digest, complete ordered set and fixed ready-through target. Install baseline atomically; apply buffered deltas contiguously. Activate only with fresh presence. | Early END waits boundedly. Duplicate cannot reinstall or refresh presence. Invalid assembly causes view recovery. |
| 15 DELTA | Bkr→C; state; S/V/A | Current view, positive delivery sequence, kind-specific record/reason/revision/freshness fields. Buffer before baseline; apply only next contiguous sequence with valid dependencies. | Identical retained duplicate harmless; conflicts/gaps trigger bounded repair/resync. Withdrawals do not invent native dispose or origin revision. |
| 16 APPLIED | C→Bkr; ctl; S/V | Current view and baseline cut/digest; monotonic contiguous applied sequence no greater than actually sent history. Advance retention cursor only. | Same/lower valid acknowledgment adds no effect. Cannot refresh lease, invent received state or acknowledge another view. Invalid claim is operation failure. |
| 17 VIEW_SYNC | Bkr→C; ctl; S/V/A | Accepted resume, current retained baseline/view, fixed ready-through target. Establish target for resumed synchronization. | Same target idempotent; conflicting target for one synchronization is invalid. Never substitutes for missing baseline or presence. |
| 18 RESYNC_REQUIRED | Either; ctl; S/V/A | Applicable view, recognized reason and bounded retry hint. Invalidate affected synchronization/cursor and start fresh view within existing deadlines. | Old view must not invalidate successor. Client-originated invalidation has zero retry hint; newer VIEW_REQUEST also retires predecessor. |
| 19 LEASE_CHALLENGE | Bkr→C; ctl; S | Current session, nonzero nonce, bounded outstanding-proof work. Return matching proof only while participant/registration is live. | Duplicate does not create new freshness or extend broker deadline. D phase must not renew. |
| 20 LEASE_PROOF | C→Bkr; ctl; S | Outstanding nonce, current owner, server-local send-time deadline and valid policy. Consume proof and update origin freshness according to lease contract. | Replayed/late/unsolicited proof never renews. Admission alone is not proof. |
| 21 PRESENCE_QUERY | C→Bkr; ctl; S/V/A | Increasing query serial admitted in control-stream order, outstanding view, nonce, full-view empty list or nonempty deduplicated authorized subset; bounded proof work. Snapshot current evidence into correlated chunks. | Duplicate cannot reset observer's original query deadline or authorize extra disclosure. Capacity errors must not manufacture validity. |
| 22 PRESENCE_PROOF | Bkr→C; ctl; S/V/A | Outstanding session/serial/nonce/view, bounded chunk count/index, unique entries, matching incarnation/freshness and conservative send-time-based remaining lease. | Duplicate cannot extend deadline; conflicting chunks invalidate proof assembly. Missing participants are not inferred fresh. F3 defines immutable frontier membership and explicit unavailable results. |
| 25 CLOSE | C→Bkr; ctl; S/D | Exact participant incarnation/current owner. Reserve terminal/result/withdrawal state; atomically fence and withdraw dependent records. | Duplicate retained result returns CLOSED; old-owner CLOSE cannot remove replacement. Post-close limited reply handling is not a live session. |
| 26 CLOSED | Bkr→C; ctl; D | Outstanding CLOSE identity/request and valid reply binding; release remote-wait obligation. | Late/duplicate harmless. Local destruction already has its own bounded completion path and never requires this reply. |
| 27 STATUS | Either; ctl; S/D | Related request/generations if applicable, recognized informational code. Update bounded diagnostics only. | Coalescing allowed; cannot establish COMMIT, READY, lease or authority. Inapplicable fields zero. |
| 28 ERROR | Either; ctl; S/D | Correlated operation, paired optional entity/revision, permitted recovery and bounded hint. Apply only locally legal recovery; no error loops. | Never a preadmission response or retroactive REJECT after commit. Use generation-scoped RESYNC_REQUIRED for view invalidation; ERROR correlates request failure. |
| 29 ADMISSION_REJECT | Bkr→C; boot; B | Exact REGISTER digest, nonce/attempt/binding; restricted reason, phase and retry hint. End attempt, report or back off within original deadline. | Ignore after session accepted; cannot extend deadline or disclose incumbent details before reply authorization. |
| 30 PATH_CHALLENGE | Bkr→C; boot; B | Outstanding directed SPDP attempt/nonce/path digest; bounded nonempty cookie. | Echo exact body under response budget; no admission or native identity proof. |
| 31 PATH_RESPONSE | C→Bkr; boot; B | Verify path-bound cookie/digest/expiry before reserving validated introduction state. | Same valid response repeats the same retained offer; no repeated allocation. |
| 32 REGISTER | C→Bkr; boot; B | First admission: existing unconsumed unexpired introduction/binding, matching attempt/nonce/domain scope/incarnation, same-scope broker identity, valid selections/limits and two endpoint pairs. Reserve resources before consumption. Consumed introductions use retained-result/session validity, independent of the old introduction expiry. | Same bytes repeat valid result; conflict/expired/unknown ID rejects without reconstructing state. |

## Findings exposed by the table

**F1 — resolved: inventory COMMIT barrier.** The client waits for matching inventory
COMMIT before transmitting post-cut mutations. Before same-session replacement it also
resolves previously transmitted mutations; uncertainty requires new-session recovery.
Local activity and bounded coalescing continue. The [barrier contract](broker-inventory-barrier.md)
records failure/overflow rules and the likely follow-on negotiated dependency mechanism.
No wire field or dormant broker staging is required in v1.

**F2 — resolved: client-assigned view generations.** Required ViewRequest member 4
identifies the new exchange; all view-bearing output echoes it. The old resume cursor
remains distinct. RESYNC_REQUIRED is bidirectional with restricted reasons, zero client
retry hints and no response loop. The [accepted view contract](broker-view-correlation.md)
defines high-water retirement, failed-request behavior and authorization invalidation.

**F3 — resolved: fixed presence answers.** The [accepted presence contract](broker-presence-completeness.md)
adds a view delivery frontier, explicit available/unavailable entries and four aggregate
limits. Complete timely answers account for the fixed READY target; unavailable entries
remain inactive and cannot revoke existing evidence. Full-view overflow uses bounded
subset queries, not truncated success. Replay retention remains W3 implementation work.

**F4 — resolved by scope correction.** No broker forwarding in v1. Remove ROUTE and
ROUTE_ERROR bodies, reserve their IDs and peer-channel/service numbers, and preserve
direct native WLP integration. [Allocated opaque relays](broker-relay-direction.md) are
later transport work; the per-message route-authority proposal is superseded.

W3/W4 accepted retention and lifecycle rules supply the cross-message constraints.
Twenty-seven rows alone do not prove full consistency or correct implementation; see
[protocol consistency review](broker-protocol-review.md).

## Audit evidence and next decision

The operation names/codes in this table were mechanically compared with OP_* constants
in the draft IDL. This checks inventory coverage only. Codec fixtures were not rerun:
this pass changes documentation, not wire types or generator code.

F1–F3 are accepted; F4 is resolved by removing v1 forwarding. Next address W3/W4. Convert these rows into executable transition/loss tests once
the corresponding decisions are settled; do not encode an accidental draft assumption
in a prototype and then treat the prototype as specification authority.

The SPDP service revision retires opcodes 1–3. Directed SPDP request/offer parameters
are preadmission metadata, not additional broker opcodes. Exact framing/hash assignments
are in the current registry; historical HELLO/OPEN rules do not apply to REGISTER.

## Domain scope checks at record boundaries

The admitted scope is immutable standard domain ID/tag within the configured authority.
Both client and selected logical broker participant must advertise that scope in their
introduction. Broker-profile client SPDP requires explicit domain ID; absent domain tag
means empty. No source-port inference, case folding or realm alias selects scope.

REGISTER and every established Envelope must equal that retained scope; equality does
not itself authorize the principal. Recheck current session/owner at commit. A syntactically
valid foreign-scope Envelope cannot select another scope's store or return its contents.
Destination endpoint/association, introduction/session and scope must agree independently.

For an origin participant record, validate payload GUID/incarnation/domain identity against
the admitted origin. Domain identity cannot change by MUTATE or replacement inventory in
one session. For an endpoint record, validate endpoint identity and parent participant using
the record/key and registered parent's scope. SEDP records need not repeat domain fields;
absence is not permission to use another domain's same-GUID participant. Key-only removals
resolve exclusively against that retained origin/scope and the specified inline metadata.
Duplicate/contradictory singleton identity metadata is invalid, not last-value-wins.

A complete inventory contains its one admitted participant and owned endpoints; stage
out-of-order data boundedly but do not commit or activate endpoints without their validated
parent. A downstream snapshot/delta likewise validates participant domain identity and
endpoint-parent membership in the selected authorized view. Unknown parents remain staged
only within the existing budget/deadline; a failed dependency invalidates the transaction
or view, never silently installs an orphan. Broker withdrawal is distinct from origin REMOVE.
Resume must validate original authority/scope/baseline retention as well as cursor numbers;
a cursor from another scope cannot be rebound by changing its Envelope.

## Phase-appropriate errors

| Input / phase | Permitted response / effect |
| --- | --- |
| Malformed fixed framing, uncorrelatable source, unknown session or wrong association | Bounded silence/diagnostic; no allocation of a replacement session and no reply to an advertised locator |
| SPDP service or PATH validation fails | Bounded silence in v1; no established ERROR and no ownership disclosure |
| Valid correlatable REGISTER cannot be admitted | ADMISSION_REJECT only under its restricted reason/path/authorization/size rules; otherwise silence |
| Valid current-session origin operation fails semantic validation before commit | Correlated REJECT/ERROR as defined by that operation; no partial store installation; retire the session if safe mandatory-result handling cannot be maintained |
| Snapshot/delta assembly or dependencies fail | Invalidate the affected view and use generation-scoped RESYNC_REQUIRED; no skipped delivery hole or fabricated APPLIED |
| Duplicate operation whose effect already committed | Retained outcome or defined expired-result recovery; never retroactive failure implying the effect did not occur |
| Invalid/unexpected rejection or error reply | No error-response loop; bounded diagnostic and locally justified recovery only |

A current-session scope/identity contradiction is not an instruction to route elsewhere.
Reject its effects and fail the affected operation/session under the existing policy; any
response must use the verified original association. Unknown/untrusted traffic cannot tear
down another session. Error-code availability in the registry does not authorize that code
in every phase. ADMISSION_REJECT and RESYNC_REQUIRED retain their explicit reason subsets.
