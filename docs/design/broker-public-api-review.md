# Broker public API final review

Reviewed 2026-09-23 against broker-public-api.md, broker-readiness-contract.md,
broker-resource-diagnostics.md and the accepted concurrency/listener result contracts.
This review covers application behavior, not a production ABI or a wire freeze.

## Disposition

The narrowed v1 surface is sufficient: existing Config-based creation plus readiness wait,
non-resetting status getter and optional listener setter/getter. All additions live on
zzdds extension interfaces/types. There is no resource-management API, per-record page
getter, runtime shutdown requirement, registration barrier or new DCPS StatusMask.

| Review area | Disposition |
| --- | --- |
| Default standard DDS use | Existing SPDP defaults retained; no broker enabled implicitly |
| Broker/direct/multicast coexistence | Independent overrides over compatibility presets; one authority per client |
| Scope | DomainConfig ID/tag used consistently; no realm or per-recipient participant identity |
| Disabled creation | require_ready rejected only if the participant itself would be disabled; disabled children are distinct |
| Startup and recovery deadlines | Per-attempt timeout does not reset startup/wait deadline; allow-degraded background retries do not inherit a hidden terminal startup timeout |
| Readiness vs matching | Inventory/view/freshness predicate only; neither reliable-peer callback nor data connectivity is required |
| Snapshot fields | Added previously promised view policy/completeness; phase, counts and no-session invariants specified |
| Failure observability | Getter success describes state even when FAILED; logging/listeners do not consume unresolved failures |
| Listener binding | Added @callback; reference ownership and external vs callback-chain setter quiescence made explicit |
| Resource API scope | Internal bounds required; optional tuning tree and diagnostic enumeration deferred |

These corrections reconcile existing decisions. No new feature or additional application
parameter is required. Numerical enum values and generated layouts must be fixed together
before public ABI publication; the declaration order in the current fragment is provisional.

## Return and result boundaries

| API | Normal result | Other defined outcomes |
| --- | --- | --- |
| create_participant_ex / standard creation using factory defaults | Existing DDS participant result; allow_degraded depends on local admission, require_ready also on bounded readiness | Nil under existing constructor convention for invalid/unsupported configuration, local resource failure or unsuccessful require_ready; bounded diagnostics identify cause |
| wait_discovery_ready | OK for ready at committed observation, including zero-time poll | BAD_PARAMETER invalid duration; UNSUPPORTED no configured broker service; NOT_ENABLED participant disabled; TIMEOUT unresolved at deadline; ERROR current nonrecovering blocker/proven helping dependency; OUT_OF_RESOURCES admitted-wait allocation failure or unrecoverable local capacity; ALREADY_DELETED recognized close before result commit |
| get_discovery_status | OK with copied coherent snapshot, even DISABLED/WAITING_FOR_ENABLE/FAILED | Recognized close before observation: ALREADY_DELETED; invalid output argument: BAD_PARAMETER; required output resource failure: OUT_OF_RESOURCES. Failure preserves previous output |
| set_discovery_listener | OK after publication and context-appropriate retirement boundary; nil removes | Invalid listener mapping: BAD_PARAMETER; preparation allocation: OUT_OF_RESOURCES; recognized precommit close: ALREADY_DELETED; proven precommit dependency: ERROR. Old registration unchanged on precommit failure |
| get_discovery_listener | Owned language-mapped reference or nil if absent | Safely recognized closed lifetime uses nil convention; invalid raw handles remain outside the lifetime contract |

Apply ordinary binding argument validation first, including canonical Duration validation;
never dereference a stale raw pointer to classify deletion. At admitted wait observation,
a recognized closed lifetime cannot begin work. Then distinguish unavailable broker
mechanism from disabled participant; only an eligible wait evaluates current readiness,
blocking failure and deadline. Races after admission use the concurrency contract's single
result commitment, not repeated prioritization that could overwrite a committed outcome.
Ordinary context contention is not PRECONDITION_NOT_MET or resource exhaustion.

No new timeout is imposed on listener replacement or a pure getter. External replacement
may wait for relevant old callback uses; callback/preparation-chain replacement does not.
Once replacement is published, later close cannot manufacture a failure implying it did
not occur. Failure preparing an owned getter result is handled by the established generated
binding failure convention; nil must not silently stand for allocation failure on a live
installed listener. Concrete backend error mapping remains a binding integration check.

## Snapshot and callback checks

READY is a point-in-time fact. Callback payloads are immutable copied snapshots of an
admitted revision; a subsequent getter may legitimately observe a newer revision. Callback
completion is never part of the readiness predicate. Coalescing does not promise delivery
of every transient error; the authoritative current state remains inspectable without a
listener. Installation schedules catch-up, and replacement re-evaluates unclaimed work.

Revisions are local to a participant lifetime, not comparable across participants or reused
as wire generations. The counter must not wrap silently while old observations remain valid;
implementation reserves a checked exhaustion/failure path. Current session/view fields identify
state, not authority granted to an application. Secrets and borrowed wire-buffer pointers are
absent. Direct-source matches survive broker failure according to their independent rules.

## Remaining gates, not new design projects

* Consolidate these fragments into zzdds.idl during API integration, preserving existing
  interface identity and generated inheritance mappings; regenerate supported bindings.
* Validate bounded strings/sequences, optional Config defaults, merge behavior and TOML
  representation; report unsupported mappings rather than silently dropping fields.
* Verify listener aliases, retain/release, output conversion failure, callback exceptions
  and setter retirement through the existing generic binding/concurrency test plan.
* Test disabled participant vs disabled children, empty-view readiness, record rejection/
  repair, reconnect under one wait deadline, status coalescing and close/result races.
* Publish and validate actual build/platform numeric defaults and memory accounting.

No broad prototype is needed to close this public-behavior review. The next spec task is
cross-document protocol consistency (W2–W5), especially old admission prose, per-scope
service identities, strict decoding and replay-retirement references. Native tag support
and the full integration matrix remain implementation work.
