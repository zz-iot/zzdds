# Broker admission trace review

Status: manual trace review, reconciled to REGISTER 2026-09-23. Each first
REGISTER presupposes a valid same-scope SPDP introduction; duplicate-result replay follows
the independent outcome deadline, not the original introduction expiry. These are manual state-transition
checks, not executed network tests. Uses the [reconciled admission policy](broker-admission-protection.md).
A registration token means epoch/session/generation together; GUID alone is not a token.

| Trace | Required state/result | Review |
| --- | --- | --- |
| REGISTER A accepted; ACCEPT lost; identical REGISTER A arrives on same binding | Same recorded result, same generation, unchanged deadline | Retry cannot renew presence or allocate a second registration |
| ACCEPT lost; TCP closes; new binding submits REGISTER B | Withdraw A, admit B, fresh inventory/proof | Client needs no credential from the lost reply |
| ACCEPT lost; UDP peer silently disappears; REGISTER B arrives before A's deadline | Conflict; no replacement or deadline extension | B retries after A's finite establishment timeout; cannot silently take over |
| Two initial REGISTER requests with same GUID and different incarnations race | One succeeds; other conflicts | Store serialization key is scope/GUID, so incarnation cannot bypass exclusion |
| Valid authenticated continuity permits B to replace live A | Reserve resources, fence A, install B atomically | Only B can commit afterward; allocation failure leaves A intact |
| B has same broker login or copied certificate but no validated participant continuity | Conflict while A lives | Transport access is not participant replacement authority |
| A closes; B registers same GUID; delayed A close/timeout callback runs | B survives unchanged | Callback compares registration token before withdrawal |
| A's queued mutation reaches store after B replaces A | Reject A's stale token | No old-owner upsert into B's inventory |
| A expires; its delayed REGISTER arrives after cached result was reclaimed | Reject expired attempt/challenge or retired binding | Eviction cannot recreate a registration; fresh attempt required |
| A expires; fresh attempt B uses same unsecured GUID/incarnation | Admit B under current deployment policy | No historical ownership reservation; require fresh inventory/proof |
| Participant CLOSE commits; old session retries | Reject stale work or return retained close result | No resurrection through old messages |
| Closed registration fully reclaimed; fresh admission uses same identity | Admit under current policy with fresh session/inventory/proof | No epoch-long identity ban |
| Cached ACCEPT exists; authorization revoked or A superseded | No live success replay | Cached response does not bypass current validity |
| Rejected competing requests continue arriving | A's deadline unchanged | Rejection cannot keep a phantom owner alive |
| A legitimately remains live while B competes | A remains; B's caller deadline may expire | Bounded failure detection is not a promise to evict a healthy participant |
| A's registration withdrawn while observer disconnected | Queue bounded withdrawal or invalidate observer view; freshness still expires | Reconnect cannot reactivate old records merely from its saved cursor |
| New registration succeeds before inventory commit | Not advertised as a complete participant graph | Admission is not READY or presence proof |

## Results

The revised policy has no lost-credential dependency and keeps one active registration
per scope/GUID. Correctness depends on compare-before-remove cleanup, atomic fencing,
finite unconfirmed-admission deadlines and non-reexecutable expired attempts. These must
be asserted in later executable broker tests, including callback/commit interleavings.

The [bootstrap rejection addition](broker-bootstrap-rejection.md) now gives a bounded
phase-specific OWNER_CONFLICT response, without promising delivery or extending deadlines.
DDS Security live replacement still requires explicit participant-continuity integration;
until available, waiting for disconnect/expiry remains correct even on TLS.
