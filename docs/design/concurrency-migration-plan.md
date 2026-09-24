# Concurrency migration and acceptance plan

Status: implementation plan following behavioral v1 readiness review, 2026-09-17.
This does not authorize an immediate production refactor or claim production readiness. Start with the [consolidated contract](concurrency-contract.md).

## Migration strategy

Implement one vertical slice through runtime, transport, protocol owner and application
notification before broad endpoint migration. Preserve the existing transport/channel
work and generated discovery codecs; adapt their seams rather than building parallel
implementations. Changes to generated ABI require coordinated zidl/zzdds rollout.

| Stage | Concrete deliverable | Acceptance evidence |
| --- | --- | --- |
| 0: final contract review | Resolve/bound observable API gaps; map accepted decisions to extension APIs and supported build profiles | No contradictory lifecycle/default rules; named error and ownership results; explicit compatibility plan |
| 1: runtime substrate | Context admission, retained requests, wake/timer registration, operational ownership and retirement | Same internal core driven manually and hosted; no lost/stale wake reuse; final-owner retirement from callback; no timer rearm or completion abandonment |
| 2: transport-to-reader slice | One transport/channel dispatch into one reader with retained input, bounded queues and listener scheduling | Buffer lifetime through delivery; output completion under saturation; callback inline eligibility and exclusion; unregister/close with in-flight I/O |
| 3: binding/listener integration | Canonical identities, replacement frontier, delegation, preparation/unwind and WaitSet result lease | C/Zig/C++/Java identity/lifetime fixtures, multiple-inheritance views, Java object aliases, reentrant release and conversion failure; ABI compatibility checks |
| 4: writer and lifecycle migration | Prepared writer commits, history capacity, control-change publication, loans and subtree close | Commit versus timeout/close, configured preparation limits, atomic loan publication/preflight, release-only progress, no false rollback after commit |
| 5: waits and presentation integration | ACK/history/WaitSet predicates, shared deadlines, GROUP access/coherent coordination where enabled | Real protocol/cache completion, empty-source history behavior, best-effort timeout, default lookup/stop races, coherent visibility and minimal non-GROUP build |
| 6: broader release gates | Supported transports/backends and profiles; compatibility and resource budgets | Interoperability/regressions, malformed-input and allocation failures, shutdown under saturation, latency/throughput/size measurements |

Stages are dependency guides, not a rule forbidding useful parallel work. Stage 2
needs enough binding-safe lifetime infrastructure for the chosen slice; stage 3 broadens
coverage rather than allowing unsafe temporary callback pointers. Stage 5 can start
incrementally once the corresponding endpoint paths are migrated.

## First vertical slice

Recommend one reliable reader/writer pair with ordinary listeners, one explicit or
implicit shared runtime and one existing transport. Exercise create -> receive/write
-> notify -> timed wait -> delete -> automatic retirement. Run the same scenario with
manual and hosted drivers. Include one shared listener, one separate listener, one
blocked output and a final-participant deletion from a callback. Do not require GROUP,
XTypes, Security, broker protocol or a full MCU port for this slice.

Keep production opt-in migration boundaries explicit until equivalent behavior is
validated. Do not mix legacy callbacks and new scheduling on one entity without a
single authoritative dispatch/lifetime owner. A build option may select the migration
path, but must not silently remove the promised listener safety contract.

## Specification gate disposition and production acceptance

The [final review](concurrency-final-review.md) records closure or explicit scope for
these behavioral gates. The requirements remain binding on implementation; they are
not all new investigations or completed production checks.

| Gate | Requirement to preserve and validate |
| --- | --- |
| Variant-specific errors | Check register/dispose/unregister, copy/loan read/take, setters and deletion against their operation contracts; no invented universal TIMEOUT or PRECONDITION_NOT_MET mapping |
| Binding delivery failure | Specify recoverable allocation/JNI/C++ outcomes after observation or mutation; preserve committed effects, define output state and clean leases |
| Runtime/extension surface | Typed runtime identity, explicit/default selection, factory/participant configuration, WaitSet construction/close and ownership transfer; zzdds.idl only for non-OMG controls |
| Default lifecycle | Reconcile implicit automatic recreation with explicit stop/disable; lookup/retain and creation/retirement races; allocator ownership independent of first factory |
| Shutdown progress | Specify actual backend cancellation/quiescence and external-loop obligations; no hidden shutdown call for standard DDS use; no cleanup stranded after final executor exit |
| Transport integration | Reconcile existing channel work, shared-socket ownership and async failure reporting; no implicit transport/security sharing merely because runtime is shared |

Review gates can be closed by a concrete supported-scope restriction or a specified
contract, not only by new prototypes. Backend implementation choices, queue layout,
optimization and measured default capacities need not be frozen in the behavioral
specification. User-visible lifetime, progress and failure rules do.

## Evidence discipline

The design suite's bounded Python models and older Zig prototype fixtures are separate
experiments. Their state/test counts are not summed as integrated runtime coverage.
They identify invariants and useful negative controls; implementation acceptance
requires actual backend and binding fixtures. Rerun affected models when their
assumptions change, not merely because another document was edited.

Targeted production checks include race/fault injection around check-register-sleep,
partial TCP sends, UDP drops, fragment limits, queue exhaustion, cancellation completion,
listener replacement, loan return and retained cleanup. Tests must cover supported
manual and hosted execution and optional-profile removal. Measure uncontended listener
latency and allocation/handoff counts before and after migration; measure code size
for actual build profiles rather than estimating savings from source structure.

The reception/admission strengthening roadmap task supplies explicit protocol/DDS
outcomes used by historical waiting. It is a release dependency of claims that rely on
those outcomes, not a prerequisite for writing the broker specification.

## Broker handoff

The broker revision can now reference the accepted context, lifetime, wait and channel
ownership directions. Reconcile generated discovery codec and transport-channel work
with the local checkouts before changing implementation assumptions. Focus revision
on discovery snapshots/deltas, sessions, reconnection, peer metatraffic and configured
TCP/UDP transport. Keep XTypes/Security and traversal requirements explicit without
promising that unimplemented features already work.

The concurrency behavioral milestone is complete within the final review scope; the
broker milestone remains an independently implementable protocol/design. Production
concurrency and broker delivery are subsequent milestones, with the acceptance gates
above. This plan does not add a requirement to finish every DDS feature first.

## Upstream regression baseline — 2026-09-23

Target main f14dd08 with zidl 0.3.18 or later compatible generation. Preserve the new
reader reliable-writer-ready extension through the same listener admission/identity rules
as writer-side readiness. Neither callback is a broker-ready or history-completion barrier.
Retain EntityFactory autoenable defaults, disabled child construction and deferred discovery,
NOT_ENABLED return behavior, CFT bulk-deletion cleanup and readiness for successive queued
coherent sets. Add the four integration-tests scenarios to migration regression coverage.
Raw/loan identity representations from zidl #53 must survive generator changes. See
[refresh review](main-refresh-review.md#refresh--2026-09-23) for exact baseline and limits.

## Pending PR #92 discovery migration notes

The [focused PR review](pr-92-discovery-review.md) finds no architecture change. Preserve
self-match loss recovery while DATA still traverses a transport; `is_local` is not a
lossless-delivery guarantee. A future direct internal path uses normal context admission,
bounded ownership and callback exclusion, with equivalent ordering/replay and enable/ignore
rules. Keep local matching independent of broker availability. Reapply ignore policy when
new endpoints scan retained discovery, including at the eventual matching commit boundary.
These are migration requirements, not a request to implement direct delivery before the
specification handoff. The PR's added regressions should join migration coverage after merge.
