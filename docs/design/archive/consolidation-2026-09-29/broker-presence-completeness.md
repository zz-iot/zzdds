> Historical source snapshot, superseded by the consolidated contracts.
> Unaccepted alternatives and old completion statements below are not current policy.

# Presence completeness: current contract and historical record

The controlling v1 contract is [ordered aggregate freshness](broker-aggregate-freshness.md).
A timely nonce-correlated marker at or after the fixed synchronization frontier accounts
for that view. Positive horizons activate eligible origins; zero evidence leaves origins
inactive without revoking independent valid evidence. An empty view still receives a marker.
Later additions do not move the readiness target and require their own fresh evidence.

The former chunk/subset/availability/query-serial protocol is retired. Its opcodes 21/22
are reserved, not an alternative mode. See [the archived rationale](../review-baseline/broker-presence-completeness.md)
for history only. Current byte limits and opcodes are in [the wire baseline](broker-wire-bytes.md).
