# Ordered aggregate freshness revision

Status: accepted draft-3 behavioral contract, 2026-09-28. Replaces per-origin chunked
proof assembly. Revised schema/vectors encode this direction; codec agreement alone does
not establish semantic admission or production integration. No deployed compatibility is frozen.

## STATE ordering

Place ORIGIN_BEGIN/RECORD/END, MUTATE, SNAPSHOT_BEGIN/RECORD/END, DELTA, VIEW_SYNC and
freshness markers on the relevant reliable ordered STATE direction. CONTROL carries
requests, COMMIT/REJECT, origin lease traffic, errors and close. Application effects follow
STATE order, not merely RTPS receive order. Bootstrap confirmation still requires valid
established CONTROL, normally VIEW_REQUEST; ORIGIN_BEGIN no longer serves as that control
confirmation. Client submits confirming control before state; cross-stream preconfirmation
staging remains bounded and must not become ACK-and-forget.

Keep fresh inventory and its COMMIT barrier before post-cut mutations. Same-session
replacement can exploit STATE ordering but cannot assume previously failed/unknown outcomes
succeeded; define transaction retirement before relaxing its existing drain rule. Ordering
removes record-before-BEGIN staging within STATE, not all staging between STATE and CONTROL.

## Query and marker

One outstanding nonce per observer session/view. Record local monotonic t0 at first send;
transport repairs retain it. Submit the logical query once; application timeout starts
a new nonce, as specified by [retry retirement](broker-retry-retirement.md). Broker captures membership/freshness against an exact committed view
frontier, applies expiry evaluation using actual deadlines, and orders required withdrawals
before its marker. A scheduled but unprocessed expiration cannot receive fresh validity.
Build marker M(nonce, view_generation, frontier, H, exceptions) from immutable capture data.
A client applies it only after the covered STATE prefix is installed. It grants nothing to
later members or different incarnations. Failed/abandoned/old-session queries confer nothing.

H is a common remaining-lease horizon for non-exceptions, not a lower bound over exceptions.
Each exception names an origin incarnation and its remaining duration; zero grants no new
validity. Positive evidence extends an existing compatible deadline using max-merge. Expiry,
withdrawal, lease reduction and authorization revocation can invalidate evidence; a marker
cannot reverse already-applied authoritative changes.

Bound exceptions by negotiated Xmax AND encoded byte budget. Choose the largest useful H
not exceeding the configured target whose below-H origins fit both bounds; lower H when
necessary, including to zero. Never silently omit a required exception. If identity size
or other bounds prevent representation, use a safe lower horizon or explicit query failure.
No marker chunking. Empty views have an explicit correlated marker. An applied marker
accounts for the fixed readiness cut; zero evidence leaves unproved members inactive.

Compute conservative observer durations using the documented relative clock-rate tolerance;
define epsilon >= 0 such that broker clock rate / observer clock rate <= 1+epsilon
throughout the exchange and granted interval. Use c = 1/(1+epsilon), rounding duration
down, and deadlines t0 + c*remaining. This is a deployment clock-rate assumption, not
synchronized epochs. A platform unable to uphold it must invalidate grants across the
unaccounted interval (including suspend) or provide a suitable elapsed-time clock. Do not use
arrival time or refresh immutable durations on retransmission. Validate the clock assumption
and arithmetic; comparable monotonic epochs are not required. Consume the nonce on first
application. Duplicate responses cannot extend it. Marker bytes remain owned through normal
reliability obligations; at most one logical query does not mean zero retained output.

## Reductions and failure semantics

A reduction decided before capture is reflected in ordered preceding state and evidence.
A later reduction is ordered after the marker and caps validity WHEN APPLIED. It cannot
retroactively shorten an observer's previously granted deadline before reaching that observer.
A stalled stream therefore expires under the earlier granted bound. Do not claim instant
revocation or that every observer deadline is always below a subsequently shortened broker
lease. This limitation also applies to delayed authorization notifications; prevent new
unauthorized disclosure immediately at the broker's output boundary.

Fresh sessions need fresh nonces even when resuming a view. Retained membership is not new
freshness. STATE backpressure prevents marker application and conservatively expires
records; independent CONTROL capacity must permit recovery. No control keepalive grants
freshness by itself.

## Cadence and scale

Schedule refresh before the granted horizon expires, initially targeting roughly half of
the common horizon, with finite minimum interval, bounded jitter and one outstanding query.
Account for short exception deadlines separately where useful. Rate limits take precedence
over endless immediate retry when H is tiny/zero. If the horizon is insufficient, conservative
expiry—including healthy origins sharing a reduced horizon—is an explicit consequence.
New membership may trigger an earlier rate-limited query. Neither one-period activation nor
READY latency is guaranteed without delivery/progress and capacity assumptions.

With N observers, exception cap K and actual query rates f_i, marker egress is bounded by
sum_i f_i * (fixed_marker_bytes + K*exception_bytes), plus discovery traffic and retransmits.
A shrinking horizon can increase f_i only to the configured cap. Healthy common-case cost
can approach O(N) per common refresh period; correlated failures do not justify an unbounded
exception list or query storm.

Naive capture scans cost O(sum_i f_i * view_size_i), even with compact output. Index shared
origin deadlines and view membership to reduce repeated work where worthwhile; charge
snapshots/indexing and bound reconciliation turns. Do not claim CPU scaling from egress
scaling. Benchmark steady state, one failing origin, correlated renewals, view churn and
restart separately. Exact capacities/cadence require implementation measurement.

## Wire migration checkpoint

Draft 3 implements compact final session-bound framing, exception/count/byte limits,
filter capability IDs and aggregate opcodes 33/34. The generated encoding comparison
and transaction-digest audit are recorded in [the encoding disposition](broker-encoding-and-digests.md).
Retain full session/scope/generation in internal admitted-work descriptors despite their
wire omission. Revised independent fixtures and the registry check pass; production
admission validation and the broader normative consolidation remain open.

## Bounded model checkpoint

The same protocol revision model explores 2,340 states/5,116 transitions for capture,
expiry-generated withdrawal, STATE delay, duplicate capture/reply, nonce consumption and
session replacement retaining old queued messages. Negative controls detect arrival-time
lease extension and applying a marker ahead of a queued withdrawal. Clock rates are equal
in this model; view churn, multiple origins/adaptive horizon selection, authorization and
post-capture lease reductions require separate checks. These counts are not a full broker
state-machine proof. The earlier arithmetic trace explicitly demonstrates that a reduction
can reach an observer after the new deadline but before its previously granted deadline.

The current wire uses FRESHNESS_QUERY=33 and FRESHNESS_MARKER=34; old presence
operations 21/22 are reserved. ReceiveLimits bounds exception count and the complete
marker Frame bytes. See broker-wire-bytes.md for exact overhead and remaining codec gates.

`review_contract_traces.py` adds 256 three-origin adaptive-horizon/rational-clock cases
and explicit delayed-reduction checks. It tests caps 0–3 internally (negotiated v1 limits
remain positive), expiry-before-capture and the defined rate factor. It does not model
network scheduling, filter churn, actual clock drift or rate-limit enforcement. Those are
implementation acceptance tests, not additional unresolved protocol choices.
