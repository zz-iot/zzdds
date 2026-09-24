# Bounded protocol retention and reclamation

Status: registration-scoped terminality accepted, 2026-09-18. Fresh admission using
the same identity is permitted once the closed registration and all derived obligations
are fully retired. Bootstrap/query compact-replay rules are resolved by the current lifecycle and retry contracts.

## The important contradiction

The superseded contract said explicit CLOSE is terminal for that incarnation throughout
the broker epoch. It also allows an arbitrarily long epoch with bounded memory and
unsecured fresh admission identified only by GUID/incarnation. After forgetting a closed
incarnation, the broker cannot distinguish a fresh registration using that same identity
from an identity it promised never to admit again.

Invalidating old sessions prevents delayed packets from reviving a registration. It does
not prevent a fresh SPDP/REGISTER exchange from claiming the same closed identity. No guessed
packet lifetime or session replay window solves that second problem.

There are three defensible choices:

| Choice | Advantage | Cost |
| --- | --- | --- |
| Retain closed-incarnation records for the entire epoch | Enforces the current permanent rejection promise | State grows with churn; a fixed quota eventually rejects new participants or requires epoch restart |
| Retain them for a configured duration | Bounds time retention | The rejection promise expires; memory still needs quotas under high churn; duration is a policy choice, not proof that packets vanished |
| Scope broker terminality to the closed registration and all work derived from it | Old work can never revive a closed registration; records are reclaimed after real dependencies retire | Broker does not police identity reuse by a completely fresh admission once historical state is reclaimed |

The third choice is accepted. A correct client still treats deletion of its local participant as
terminal and creates a fresh GUID/incarnation for a new participant. The broker enforces
session validity and current authorization, not a permanent identity-use ledger. A fresh
admission after reclamation is a new registration requiring new inventory/proof, not a
resurrection through stale packets. This fits the accepted unsecured identity direction.
Authenticated identity/permission revocation is enforced separately by its policy provider;
reclaiming protocol records does not revoke or restore those security decisions.

## Reclamation inventory

These rules describe the accepted retirement structure; the compact-replay mechanisms
below still require concrete implementation contracts.
“Invalidate” means making all later lookups fail admission before freeing state; outstanding
local references may still require deferred memory release under the runtime contract.

| Retained state | Why retained | Safe retirement / pressure response |
| --- | --- | --- |
| Validated introduction, UDP cookie and REGISTER result | Return the same outcome; reject expired/replayed admission | Invalidate the attempt's admission capability before evicting its outcome. Expired challenges never execute; a surviving still-valid challenge needs negative/high-water state or retirement of its binding. Pressure refuses new work, never silently converts a duplicate into new admission. |
| Current registration/session | Fence mutations and cleanup to one owner | Remove from active lookup atomically, invalidate its queues/tasks and retain only necessary result/withdrawal dependencies. Unknown established sessions reject without allocating a replacement. Fresh session identity cannot reuse a still-referenced token. |
| Closed-registration result | Answer duplicate CLOSE; complete withdrawals safely | Retain within bounded result window and while dependencies require it, then reject old-session traffic through absence from active lookup. No epoch-long closed-identity reservation under the recommendation. |
| Origin revision high-water/tombstones | Reject stale same-session updates and conflicting retries | Retain while the origin session and its mutation/inventory dependencies can reference them. If capacity cannot preserve needed revision history, force fenced new-session/full-inventory recovery. Never silently forget a tombstone while accepting old-session mutations. |
| Inventory staging/result | Atomic assembly and idempotent commit outcome | Fixed transaction deadline; retire generation before releasing staging. Keep result within retry budget or make outcome unavailable and require defined recovery. One active generation plus monotonic high-water avoids retaining every aborted transaction forever. |
| View snapshot/delta history | Deliver and resume an exact installed prefix | APPLIED advances retention only for its view; remove acknowledged entries when no other retained view needs them. Pressure invalidates affected views/cursors explicitly before dropping required history. Saved client cursor does not force indefinite server retention. |
| Removal delivery records | Tell observers to withdraw stale state | Retain until relevant views acknowledge or are invalidated. Disconnected observers rely on conservative presence expiry; do not keep a global removal forever solely because an observer vanished. |
| View request outcomes | Prevent old requests creating successor snapshots | Session-local monotonic request generation/high-water plus bounded current outcome. An older generation cannot restart; an unavailable result requires a newer generation. |
| Presence proof chunks/results | Keep one immutable answer per query nonce | Finish/expire query, then reject late use. Random nonce alone does not give a compact order: see the query-retirement gap below. Pressure rejects queries before promising complete answers. |
| In-flight transport/runtime references | Prevent use-after-free and stale completion effects | Logical invalidation first; memory release only after completions and observers relinquish references. Cancellation request is not completion. Bound outstanding work at submission. |

Across sessions, preserve origin revision monotonicity in the client as already required.
A new session's authoritative inventory establishes its baseline; old-session messages
cannot enter that namespace. Retained downstream history remains generation/cursor-bound
and cannot overwrite a newly installed replacement baseline.

## Resolved compact-replay rules

REGISTER consumes a validated introduction. Unknown/retired introduction IDs never
reconstruct admission. A consumed result has its own replay deadline, separate from the
unconsumed introduction's expiry. Retain UDP consumed-cookie correlation until all
associated cookies expire; TCP/protected paths do not require that extra cookie guard.
Reserve result/guard capacity before effects. See [current lifecycle](broker-bootstrap-lifecycle.md).

Presence queries use increasing session-local serials admitted in control-stream order,
with bounded active result slots and retained admission high-water. Older/forgotten serials
cannot recreate an answer; completion order may differ from admission order. Observer
nonces still bind freshness independently. This is the accepted [retry-retirement contract](broker-retry-retirement.md),
not an open choice between arbitrary nonces and unbounded result caches.

## Required validation after decisions

Exercise long-running create/delete churn with fixed quotas; stale CLOSE/commit after
session replacement; old REGISTER after result eviction and consumed UDP path responses before cookie expiry; removal
with disconnected observers; resumption after delta eviction; and concurrent presence
queries whose replies complete out of order. Account separately for logical map entries,
retained payload bytes and deferred runtime references. An apparent empty lookup table
is not evidence all memory can be freed.

## Blacklists and next decision

No automatic misbehavior, repeated-incompatibility or reconnect blacklist is required for
v1. Such admission policy may be added later, independently of protocol-state retention.
V1 still enforces quotas, rate/response budgets, bounded retry/backoff, current configured
authorization and rejection of stale sessions. None requires a permanent participant ban.
A future blacklist needs explicit scope, expiry/recovery and administrative policy; GUID
or source IP alone is not authenticated identity and shared NATs require care.

Next specify compact bootstrap attempt and presence-query retirement and their limits.
The accepted registration rule does not permit discarding replay guards while associated
old work could still execute. Executable reclamation tests follow those concrete rules.

The [retry retirement proposal](broker-retry-retirement.md) now recommends expiring
consumed-admission guards and ordered presence-query serials with bounded active slots.
It supersedes the earlier sliding-window suggestion as the preferred design, pending
acceptance; query admission already has an ordered reliable control stream.

The retry-retirement direction is now accepted: consumed guards through challenge expiry
and ordered presence serials. Earlier sliding-window alternatives are historical. Exact
configured horizons and bootstrap fit/endpoint lifecycle remain W4 integration work.
