# PR #92: discovery implications for the design baseline

Focused source review, 2026-09-24. Reviewed fetched PR head
`8fc4ab1a87fbbe4ac5c55a3ba8ccc1f05820e383` against merge base
`f14dd08d2780da4cb6fb83494915ea8ca6145e8d`. The working branch was not rebased or
modified with PR implementation changes. This is not a full PR approval, test run or
independent reproduction of its performance measurements.

## Result

No change to the accepted runtime/context/listener architecture or broker handshake is
needed. Preserve three migration constraints: local transport recovery, source-aware
identity validation, and ignore policy on every route into matching. Future direct local
notification is compatible with the shared runtime but is not a prerequisite for freezing
the behavioral design baseline.

## Self-matched builtin endpoints

BuiltinPair.matchRemote now marks reader/writer proxies local when the remote prefix
matches their owner's prefix. This serves combined.zig's existing self_data bootstrap;
it is not a general same-host or same-process optimization for distinct participants.
Reader setup omits its initial ACKNACK, writer liveness probing excludes self proxies,
and periodic heartbeat transmission skips a self proxy only when its acknowledged
frontier has caught up. DATA still uses the normal transport and per-write heartbeat.

That conditional matters: loopback UDP can lose data. The added writer regression checks
that a self proxy with unacknowledged data still receives a periodic heartbeat. Additional
unit tests cover idle heartbeat suppression, probe suppression and local/nonlocal initial
ACKNACK behavior. These test bodies were inspected, not executed in this review.

Some comments/test introductions and roadmap prose still say local matches cannot lose
traffic or describe heartbeat suppression without its caught-up condition. The final code
and loss-regression test correctly qualify that statement. Treat `is_local` as narrow
local-ownership provenance, not proof of lossless delivery, authenticated identity, or
permission to suppress arbitrary user-writer liveliness behavior. Do not extend this flag
to all colocated endpoints without reviewing its broader state-machine consequences.

The proposed later direct notification path should use the same context admission,
retained-input and callback exclusion contract as transport reception. It may execute
inline when eligible; it must not introduce unrestricted recursive callbacks. Preserve
ordered updates/removals, enabled-state rules, ignore/QoS checks, replay/history and any
applicable coherent visibility, with bounded backpressure rather than silent local loss.
Replacing builtin discovery delivery does not require simultaneously replacing user-data
transport. Broker availability remains irrelevant to local entity matching; broker-only
configuration must not accidentally remove the internal matching bootstrap.

## SPDP identity decoding

The PR changes decodeSpdpParticipant to select its supplied source prefix even when
PID_PARTICIPANT_GUID claims a different prefix; it logs the mismatch and continues. The
new golden test fixes that behavior. This is a direct-reception consistency choice, not
an authentication guarantee: on unsecured UDP both the RTPS header and payload are
sender-controlled. The comments' term "transport-verified" should not be read as security
validation. Correct effective source identity also requires INFO_SRC handling, already a
named requirement in the inline-context feasibility review.

Broker-delivered native records have a different provenance boundary: their original
participant identity is inside the validated OriginRecord, while the enclosing RTPS
sender is the broker. Never pass that broker prefix to the direct SPDP decoder as the
origin identity. Decode the retained sample against its explicit origin context and
require agreement between record key, embedded participant identity and origin metadata
before installation. The direct path's warn-and-continue behavior must not silently
rewrite contradictory broker records or their raw bytes. A reusable codec should keep
payload decoding separate from direct-wire versus broker-origin validation policy.

Migration tests should cover direct matching identity, direct mismatch behavior, effective
INFO_SRC, broker-wrapped foreign-origin samples, and record/payload disagreement. Existing
native domain-ID edits in our branch touch nearby decoder/schema areas; eventual rebase
must preserve those checks alongside this PR's identity change, regardless of whether Git
reports a textual conflict. No change to domain ID/tag or canonical-byte/hash contracts.

## Ignore policy and discovery caching

New writer/reader creation scans now reapply ignored participant prefixes, opposite-endpoint
handles and topic names when examining previously discovered endpoints. The added tests
exercise topic ignore followed by endpoint creation in each direction. This fixes a
second admission path into matching rather than requiring cache eviction.

The same policy must hold for broker snapshots/deltas, reconnect/resume, mixed-source
updates and future direct local notification: retained discovery evidence is not permission
to rematch an ignored endpoint. Recheck current policy when committing a match. Applying
ignore need not falsify the broker's inventory or delete independently owned source records.

## Performance and adjacent changes

The PR adds roadmap work for direct internal notification and measured discovery startup
latency. Its reported approximately 1.5-second delay and missed-initial-SPDP explanation
are observations/hypotheses from that investigation, not reproduced here or elevated to
protocol requirements. Retry tuning remains separate from the broker's fixed absolute
startup deadlines and the concurrency runtime's fairness/progress requirements. Compare
same-participant, distinct local participant and cross-process cases separately.

Timestamp/duration rounding and overflow handling also changed. These reinforce the
existing hostile-input boundary requirement; they do not replace monotonic runtime
clocks or justify decoding/reserializing bytes used by broker digests. Interface-monitor
changes inspected here are explanatory comments, not new selection behavior.

## Disposition

Added narrowly scoped migration/coexistence notes. No schema, opcode, public API or
concurrency policy changes; no additional prototype is required. Carry PR regressions
into migration acceptance after merge. Full CI, network performance and remaining PR
correctness are outside this focused review.
