> Historical source snapshot, superseded by the consolidated contracts.
> Unaccepted alternatives and old completion statements below are not current policy.

# Broker implementation acceptance checklist

Status: review-reconciled design handoff, 2026-09-28. The specification baseline is
complete within [the handoff scope](specification-handoff.md); these are implementation
and publication gates, not requests for another broad design cycle.

| Gate | Required acceptance evidence |
| --- | --- |
| Public surface | Generate zzdds.idl Config/status/listener extensions with standard-API defaults; check binding ownership, failed construction, disabled require_ready rejection and absent-listener diagnostics |
| Native discovery | Domain ID/tag matching and explicit domain ID encoding; recipient-specific inline SPDP service context; preserve original payload/endian/unknown optional PIDs |
| Bootstrap | UDP/TCP, same-source/path behavior, unfragmented whole-message preflight, local oversize diagnostic versus remote timeout, concurrent PATH consumption and exact REGISTER retry |
| Insecure admission bounds | Entropy failure/collision handling, quotas, 1:1 prevalidation response budget, cookie/introduction/result expiry, reachable-abuse CPU/storage limits |
| Fencing and lifetime | Scope/GUID serialization, no v1 live takeover, lost ACCEPT, delayed close/timeout, fresh inventory on reconnect, bounded retirement without identity blacklist |
| Codec/storage | Mutable bootstrap required/unique fields, final exact extent, malformed/oversize nested bodies, retained raw bytes, bounded reassembly, allocation failure and borrowed lifetime |
| Ordered state | BEGIN/records/END, exact counts/bytes/dependencies, inventory COMMIT barrier, snapshot atomic visibility, contiguous deltas and current-session APPLIED |
| Resume | Full retained epoch/session/owner/view/cut identity plus scope/policy/history; missing retention falls back to snapshot; old identity cannot acknowledge successor |
| Freshness | Expiry-before-capture, bounded adaptive exceptions, defined clock factor, once-only query admission, immutable repair, fixed readiness target, delayed reductions, stale nonce/view/session, STATE stalls with independent CONTROL recovery |
| Filtering/coexistence | Required topic and topic/partition modes, operator ceiling, conservative candidates and diagnostics, current-policy output checks, direct-source provenance and same-participant activity during outage |
| Concurrency | Shared manual/hosted runtime; inline eligibility; bounded reconciliation; no callbacks/I/O under protocol rights; automatic final-owner retirement |
| Scale/deployment | Measured storage/CPU/latency, view churn, renewal failures, bounded retry/repair/cadence, supported transport/platform matrix; no inferred MCU size or internet-security claim |
| Wire/ABI publication | Review assignments/version mappings after wire-affecting implementation findings; independent encode/decode compatibility and deliberate freeze |

V1 is insecure cached discovery. DDS Security-derived secure cached operation, the v1.1
continuity token, opaque discovery, ICE/STUN/TURN, relays, federation and expanded management
APIs have separate gates and do not block this initial specification. User data and WLP
remain direct. Future secure support requires vendor-endpoint protection and actual UDP/TCP
evidence; optional TLS/DTLS is not a v1 prerequisite.

Current experimental evidence and exact reproduction commands live in
[test/design-models/README.md](../../../../test/design-models/README.md). Codec/model success is
not production conformance. The [old chronological checklist](../review-baseline/broker-implementation-checklist.md)
is retained for provenance, not as another outstanding decision list.
