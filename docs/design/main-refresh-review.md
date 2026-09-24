# Main refresh review — 2026-09-15

Updated zzdds broker_spec from main c86934e to c37181e (after v0.3.1-zig.0.16.0),
rebasing the two broker documents to d27678c/d41e540. Updated zidl main from a069f4a
to 26dc737 (after v0.3.17-zig.0.16.0). No remote branch was updated.

## Findings

* zzdds #85 completes the generated SPDP codec swap; SEDP was already on the old
  baseline. Shared discovery/wire_codec.zig helpers now serve both. This supports
  codec reuse by the broker and does not change the concurrency ownership decisions.
  The ordinary decodeSpdpParticipant path projects selected fields into ParticipantData
  and then deinitializes the generated object. It is therefore not a lossless broker
  forwarding representation: retain the generated unknown-parameter-bearing value or
  original bytes under an explicit lifetime when preserving discovery extensions.
* zzdds #84 implements Channel, sendOnChannel and optional channel-close callbacks.
  TCP replies use the received connection; UDP replies use the received socket with
  an explicit destination. Broker routing should reuse these semantics. Receive data
  remains borrowed; callbacks run on transport threads and must not block. Sends still
  expose anyerror!void rather than asynchronous ownership/completion outcomes.
* Current Channel tokens are transport-private pointers with generations. Retention
  until transport close underpins their safety; a generation alone does not protect a
  freed allocation. UDP's documented dead-socket graveyard grows with interface churn.
  The evented runtime needs bounded identity storage/retirement and safe transport
  lifetime, not indefinite tombstones. Channel-close notifications are broadcast to
  current handlers: consumers must correlate transport lifetime plus token/generation,
  tolerate unknown/duplicate notifications and reserve cleanup delivery capacity.
  No connection token is an authenticated participant identity or proof of NAT reachability.
* zzdds #86 and zidl #52 distinguish full ALIVE payload key hashing from genuine
  key-only DISPOSE/UNREGISTER hashing, and extend the TypeSupport C ABI registration.
  Regenerate bindings together with the updated runtime. This improves reception
  correctness but does not replace the broader reception/admission audit or typed
  prepared-access work. Handwritten registrations can still omit the key-only hook;
  the inspected fallback is a zero hash, not successful validation of instance identity.
* zidl #51 improves generated Zig deinit idempotence and union cleanup. It helps
  preparation cleanup, but does not establish concurrent cleanup safety or ownership
  of copied values. Exactly-once resource retirement remains required.
* The intervening diffs do not change dcps reader/writer implementations or the
  inspected typed read/take helper bodies. The CDR/DDS error-domain mismatch,
  Java ignored raw errors and output-after-access findings still apply. Source line
  numbers in earlier audits refer to their recorded baseline and may have shifted.

## Result and validation

No concurrency decision needs reversal. Reconcile broker integration with the now
implemented codec/channel facilities rather than scheduling duplicate implementations.
The accepted binding failure policy remains needed; it is not supplied by these merges.

Rebase and stash restoration completed without conflicts. range-diff reports both
broker commits unchanged. All saved local files were restored byte-for-byte except
roadmap.md, where upstream and local additions merged; both optional-profile and
reception/admission entries remain. git diff --check passes. The backup branch,
pre-rebase stash and /tmp/zzdds-pre-main-rebase-20260915-165120 archive remain available.

This was a source/diff review, not a production test run. Zig was not on PATH during
this review. No production source edits were made as part of the refresh.

## Refresh — 2026-09-23

Rebased zzdds broker_spec onto origin/main f14dd08 (post-0.3.3), preserving the two
committed broker documents as e5fedac/04deddb. range-diff reports both patches unchanged.
Updated zidl main to 53177d9 (post-0.3.18). All tracked/untracked local work was restored
without merge conflicts. No remote branch was updated. Recovery copies remain in
/tmp/zz-spec-refresh-20260923 and named pre-refresh backup branches; stashes were applied,
not dropped (zzdds 21e2d44, zidl a1e7acb).

Reviewed changes and design implications:

* #88 adds user-endpoint receive dispatch on UDP metatraffic unicast ports, and tightens
  WLP endpoint selection. This is local packet dispatch, not broker relaying. The parsed
  submessage router described in rtps-submessage-routing.md is still proposed. Runtime
  migration must preserve shared-port handler lifetime, correct endpoint dispatch and
  cleanup; it must not infer protocol authority or domain eligibility from port alone.
* #90 adds DataReaderListenerEx.on_reliable_writer_ready and set_listener_ex. Targeted
  heartbeat evidence is distinct from DDS matching, broker READY and historical completion.
  Apply the accepted canonical listener identity, exclusion, replacement and retained-call
  rules to this callback too. Not all vendors target heartbeats, so this extension is not
  a universal prerequisite for broker READY. Empty-offer HEARTBEAT fixes must remain intact.
* #91 is more than test infrastructure: enabled-state/NOT_ENABLED checks and deferred
  announcements, EntityFactoryQosPolicy's true default, CFT contained-deletion cleanup,
  status-path fixes and coherent committed-set readiness changed production behavior.
  Preserve disabled-tree construction, top-down enablement and pending coherent-set wakeups
  in admission, deletion and WaitSet migration. Existing atomics/direct callbacks are not
  proof that the proposed serialized commit/notification contract is implemented.
* Four integration scenarios now cover coherent sets, contained deletion, deferred enable,
  and sample rejected/lost across C/C++/Java/Zig. They are useful migration regression gates;
  no claim that this refresh reran the entire network/cross-binding matrix.
* #89 and zidl #53 preserve raw/loan identity across C++/Java mappings; zzdds now pins zidl
  0.3.18. Preserve those identity-bearing representations when regenerating bindings.
  Generic managed construction references remain our separate experimental work; this
  upstream fix does not solve listener identity or all mixed Config ownership mappings.

The shared-runtime/take-turns concurrency baseline, standard domain identity, per-scope
broker participants and direct-only v1 traffic remain appropriate. One newly explicit API
question is disabled participant creation combined with require_ready; see the proposal
in broker-public-api.md. No additional production implementation was added in this refresh.

Refresh validation: rebuilt local zidl (53177d9 plus restored experiments) successfully;
all 20 broker codec tests pass with that rebuilt generator and updated runtime; all 49
independent Python wire vectors verify. Both repositories pass git diff --check, have no
unmerged paths, and contain their fetched main tip. This is targeted design-artifact
validation, not a rerun of production concurrency/network or cross-binding integration tests.

## Pending PR #92 review — 2026-09-24

Fetched PR head 8fc4ab1 without rebasing the design branch. The
[discovery-focused review](pr-92-discovery-review.md) records self-match traffic suppression,
SPDP identity decoding and late-created endpoint ignore checks. No architecture/wire change
is needed. Performance observations and PR tests were inspected, not independently run.
