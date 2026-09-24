# Concurrency and discovery broker: specification handoff

Design baseline, 2026-09-24. This closes the current directional specification effort.
Both packages are ready to guide implementation and focused review within their stated
scope. Neither a frozen public ABI nor a deployed broker wire protocol is claimed.

## What is ready

| Package | Controlling entry point | Baseline result |
| --- | --- | --- |
| Concurrency | [Contract](concurrency-contract.md), [final review](concurrency-final-review.md) | Execution ownership, listener contract, waits, preparation/commit, lifetime, runtime driving and shutdown behavior settled |
| Broker | [Implementer guide](broker-spec-guide.md), [public API](broker-public-api.md), [operation table](broker-operation-validation.md) | Configuration, discovery coexistence, bootstrap/admission, origin/view synchronization, freshness, recovery and resource behavior specified |
| Broker bytes | [Registry](broker-wire-registry.md), [compatibility review](broker-wire-compatibility-review.md), [draft IDL](schema/broker-control-draft.idl) | Concrete proposed layouts/assignments and independent fixtures; explicit compatibility gates before publication |
| Production migration | [Concurrency migration](concurrency-migration-plan.md), [broker closure ledger](broker-spec-closure.md) | Named implementation stages and acceptance evidence, separated from design decisions |

Detailed contracts govern their named behavior. The broker guide identifies controlling
contracts; the concurrency final review identifies its gate documents. Chronological
investigations, abandoned alternatives and old next-step notes are evidence history,
not competing requirements. New contradictions must be resolved explicitly in the affected
contract rather than silently choosing whichever implementation is easiest.

## Preserved decisions

Concurrency uses shared manual/hosted progress with take-turns participant and endpoint
contexts. Listener exclusion and ordering permit an eligible inline fast path without
weakening the callback contract. Standard DDS applications receive useful defaults and
automatic last-owner runtime cleanup. Non-OMG controls use zzdds extension interfaces.
Optional profiles must be removable with their exclusive state; ordinary synchronization
remains necessary. Binding/reference support belongs in generic zidl where appropriate.

Broker v1 is cached discovery, with independent UDP/TCP control configuration, ordinary
multicast/directed discovery coexistence and standard domain ID/tag scope. Local matching
continues independently of broker availability. Directed SPDP carries per-transmission
inline service context while canonical participant payloads remain unchanged. Plain UDP
uses bounded pending challenges; REGISTER/ACCEPT establish fenced sessions, fresh origin
inventory and independent downstream synchronization. WLP and user data remain direct.
GUID identity does not imply authentication; service protection and future DDS Security
participant authentication remain distinct.

The latest implementation directions are bounded stateful cookies (32-byte provider value
within the existing opaque 64-byte wire bound), strict borrowed decoding with explicit
immutable-byte ownership, and no implicit wire fallback if inline introduction integration
fails. These are concrete implementation baselines, not certification of a provider or
mandated zidl API spelling. No additional product-policy question was found in this pass.

## What still has to be proved

| Gate | Required evidence before the associated claim |
| --- | --- |
| Concurrency implementation | Real manual/hosted lifecycle, scheduler/queue fairness, cancellation, callback exclusion, output failure and retirement tests; latency and memory measurements |
| Public API/ABI publication | Production zzdds.idl declarations and generic zidl mappings, defaults/ownership/error behavior across C, Zig, C++ and Java; compatibility/version rollout |
| Broker inline introduction | Unchanged canonical sample with directed context; both SPDP ingress paths preserve effective identity/path; duplicate, endian, size and channel-lifetime tests |
| Path/protection implementation | Entropy and pending/consumed challenge bounds, atomic consumption, replay/expiry/rate accounting; configured protection, revocation and migration behavior for each advertised backend |
| Broker codec/storage | Required/unique members, nested exact bounds, raw-byte retention, allocation-failure cleanup, bounded reassembly, peak native memory and independent byte agreement |
| Broker protocol integration | Loss/reorder/duplicate tests across introduction, inventory, view, freshness and close; source coexistence, enable/ignore rules, domain ID/tag and endpoint identity allocation |
| Release/compatibility publication | Explicit version/assignment review after wire-affecting findings; supported platform/profile/transport regression evidence and documented deployment limits |

No gate requires implementing every future feature. A trusted-network delivery can have
that explicit scope without claiming authenticated public deployment. Full DDS Security,
XTypes routing, ICE/STUN/TURN and allocated relays, federation, advanced management APIs,
assigned-worker policies and complete MCU ports remain separate work. GROUP concurrency
invariants do not claim to supply its complete coherent-presentation wire algorithm.

Numeric capacities/timeouts, generic generator entry-point spellings, pool layouts and
platform provider selection are implementation choices constrained by these contracts.
They are not reasons to reopen the whole architecture. If measurements reveal a conflict
with a requirement or an unavoidable wire change, reopen that named decision with evidence.

## Implementation handoff order

1. Preserve the refreshed main codec/channel integration and PR #92 discovery regressions
   when merged. The [PR review](pr-92-discovery-review.md) records the inspected head and
   local-recovery, origin-identity and cached-ignore constraints; it is not a merge review.
2. Begin the concurrency plan's first vertical slice: one reliable reader/writer pair,
   manual and hosted driving, listeners, timed waits and automatic runtime retirement.
   Bring in the generic binding lifetime support required by that slice.
3. Implement the bounded codec/storage and directed introduction seams with focused tests.
   Broker work need not wait for every endpoint/profile to complete concurrency migration,
   but must use the same ownership/progress contracts at the integration boundary.
4. Build the smallest broker end-to-end path: one scope, baseline VIEW_ALL, fresh inventory,
   readiness, disconnect/reconnect, both configured control transports and local matching
   during broker failure. Then broaden optional features, scale and backend coverage.
5. Publish wire/ABI compatibility only after the relevant gates pass. Experimental artifacts
   remain explicitly provisional until that point; no accidental production promises.

This order is a handoff recommendation, not an instruction to start a production refactor
or merge/publish the current checkout as part of this documentation task.

## Evidence inventory and limits

The 2026-09-23 refreshed generator passed 20 broker codec tests; 49 independent byte/hash
vectors cover the current draft. The registry checker covers 27 operations, 30 mutable
member-ID sets and 17 discriminator namespaces. Earlier bounded concurrency models and
binding experiments retain their individual scope/limitations; their counts do not add
up to validation of a complete runtime. PR #92 was source-reviewed at 8fc4ab1, not executed.

This handoff changes documentation only. The final checks rerun the independent vectors,
registry consistency, local links in the current handoff entry points and whitespace.
No fresh production-network, security-provider or complete binding test result is claimed.

## Definition of done for this effort

Done means a coherent implementation baseline with explicit behavior, boundaries, source
ownership, error/recovery rules, proposed wire shape and a finite acceptance checklist.
That target is reached within the scopes above. A working implementation and frozen
interoperability are the next milestones, not unfinished general design investigations.
