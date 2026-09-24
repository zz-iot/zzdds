# Origin inventory barrier and future pipelining

Status: accepted v1 direction, 2026-09-17: wait for inventory COMMIT before sending
post-cut mutations. Design the follow-on for explicit negotiated dependencies.
This resolves F1 in the [operation table](broker-operation-validation.md).

## V1 admission rule

Capture an immutable inventory cut and close the client's mutation-send gate before
sending ORIGIN_BEGIN. Continue local endpoint activity; retain subsequent announcement
changes in bounded local pending state. Send the inventory records and ORIGIN_END, then
wait for the matching successful inventory COMMIT. Match session/owner generation,
inventory generation and the related inventory-completion request (ORIGIN_END). Only
that result opens the gate for post-cut MUTATE messages. RTPS ACK, local send completion,
ACCEPT, presence evidence, unrelated COMMIT and downstream READY targets cannot open it.

The broker accepts MUTATE only after the current session's inventory has committed and
while no replacement inventory is staging. Premature MUTATE is a protocol failure, not
implicit dependency staging: reject with an appropriate ERROR_MALFORMED / NEW_INVENTORY
recovery result, or fail the session if a safe correlated reply cannot be delivered.
No wire field needs to be added for this v1 rule. O in the operation table means this
current-session committed baseline, not retained inventory from an old connection.

A same-session replacement inventory also needs a boundary before its cut. Stop new
mutation submissions and resolve every previously transmitted mutation before sending
ORIGIN_BEGIN. Successful or definitively rejected outcomes suffice; an unknown outcome
does not. If the client cannot resolve outstanding work within its retry budget, recover
through a fresh session/inventory instead of letting delayed old mutations overlap a
replacement cut. Duplicate requests whose results remain retained never execute twice.
This avoids relying on ordering between control BEGIN and the independent state stream.

Within one inventory generation, retry the same immutable cut/records/END and request
identities. Lost COMMIT is repaired through retained transaction results, without changing
origin revisions or recapturing that generation's cut. A rejection leaves the gate closed.
A fresh transaction or new session captures a new cut from authoritative local state.
Old-session results and delayed COMMIT from a superseded inventory cannot open the gate.
Same-session transaction failure/retirement must invalidate its staging before reuse;
new-session fencing is the fallback where the outcome cannot safely be established.

## Local buffering, visibility and failure

Coalesce only unassigned announcement changes, preserving authoritative revisions and
required removals relative to the captured cut. An endpoint present in that cut and then
deleted needs a removal after commit. An endpoint created and deleted entirely after the
cut may need no announcement. Once a logical request/stream record is assigned, retain
its exact bytes for retry rather than silently rewriting it.

Charge pending bookkeeping to configured bounds. If it cannot represent the required
changes, fail/degrade synchronization and rebuild a fresh inventory using the recovery
rules; do not claim complete advertisement after dropping changes. Local entity creation
can still fail when its own resource reservation cannot be satisfied. The barrier does
not block local matching or data delivery and does not make local API success depend on
a broker round trip. It delays remote advertisement during registration or repair.

The broker may expose the committed cut before subsequent mutations arrive. This is
ordinary discovery lag, not atomic visibility of every local change made during upload.
The accepted fixed-target READY rule is unchanged: later pending changes are reported
separately, rather than extending the synchronization target indefinitely. Steady-state
mutations do not each wait on a new inventory barrier.

## Likely follow-on: negotiated inventory-dependent mutations

Keep the gate and pending-state ownership explicit in the client so a later policy can
release dependent mutations earlier. Keep the broker's inventory commit boundary explicit
so staged dependent work can be scheduled only after that boundary. These are design
seams, not a requirement to allocate inactive staging queues in v1 or embedded builds.

The follow-on must specify all of the following together:

* A negotiated feature with a minimum protocol version, plus a required dependency field
  on pipelined MUTATE identifying the exact inventory generation in the current session.
  Do not assign a feature number or advertise support before that contract is complete.
* The Envelope required_features entry and conditional required-member validation, so
  a v1 decoder cannot skip an optional field and accidentally apply work early. A new
  operation is also possible if it yields clearer compatibility; silent reinterpretation
  of current MUTATE is forbidden.
* Negotiated dependent-work item/byte limits and per-session/service quotas, deadlines,
  backpressure and failure replies. One valid dependency does not authorize unlimited
  precommit staging. Clients still retain sufficient retry state.
* Atomic release after inventory commit, deterministic revision ordering, and rejection
  of missing, failed, replaced or retired dependencies. In-flight work belonging to a
  previous inventory must not attach to its successor.
* Lost-result handling and a precise rule for pipelining across same-session replacement,
  including any required prior-mutation frontier. An inventory dependency alone does
  not solve the opposite boundary: old mutations racing a newer inventory cut.

Feature negotiation enables capability, not mandatory pipelining. A client may always
use the v1 COMMIT barrier; a peer without the extension uses it unchanged. No fallback
may transmit dependency-free early mutations. Measure registration/repair latency under
real RTT/churn before choosing default pipeline limits. Preserve identical committed
state, freshness and READY semantics for both execution policies.

## Trace review

| Case | V1 result |
| --- | --- |
| Inventory contains B; B deleted while uploading | Commit cut, then transmit B removal |
| C created and removed after cut before request assignment | Coalesce locally; no false C announcement required |
| ORIGIN_END overtakes records | Broker waits for complete inventory; client gate remains closed |
| Inventory commits but COMMIT is lost | Retry retained completion request; no early post-cut MUTATE |
| Old mutation outcome unknown before replacement | Resolve it or use new-session fencing; do not send overlapping BEGIN |
| Old COMMIT arrives after reconnect/replacement | Ignore for current gate |
| Pending capacity exhausted | Explicit synchronization failure/fresh inventory; no silent loss of required removal |
| Future peer supports pipelining but local client does not select it | Use unchanged v1 barrier |

These are contract traces, not new executable broker tests. Required implementation tests
must exercise the same cases with independent control/state ordering and bounded queues.
