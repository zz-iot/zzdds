# Concurrency v1 readiness review

Status: behavioral baseline ready for implementation within the scope below,
2026-09-17. The user accepted the final bootstrap refinements. This review closes the
concurrency policy investigation; it does not freeze public ABI, certify production
conformance or authorize a production refactor. Start at concurrency-contract.md.

## Gate disposition

| Gate | Defined behavior / authoritative contract | Implementation or publication gate |
| --- | --- | --- |
| Execution and admission | Take-turns participant/endpoint owners, narrow coordinators, bounded preparation, no protocol rights across foreign calls; concurrency-model.md, admission-state-machine.md, commit-preparation.md | Concrete queues/pools, memory ordering, fairness and race tests |
| Listener identity/order | Per-entity and canonical-object exclusion, independent sibling listeners, optional fixed groups, inline eligibility; listener-execution.md section 13 and listener-identity-decision.md | Binding identity, alias/reuse tests, actual status routing |
| Delegation and lifecycle | Bounded synchronous traversal, retained rights, minimum nesting limit, external retirement frontier, callback-chain non-drain, atomic subtree preflight; listener-delegation-decision.md, listener-bulk-deletion.md | Cross-owner and foreign-unwind integration |
| R1: borrowed resources | Retained owner or explicit tracked scope/fence; independent completion storage; runtime-resource-ownership.md | Allocator/environment coverage and final-hook accounting |
| R2: runtime identities | Owners versus observers, transactional acquisition, automatic final-owner retirement, per-creation default resolution; runtime-ownership.md, runtime-resource-ownership.md | Generated references, registry races and coordinated ABI rollout |
| R3: binding output failures | Prepare/validate/commit whole batches; preserve effects on postcommit delivery failure; binding-access-failures.md, prepared-read-conflicts.md | Actual C/Zig/C++/Java preparation and failure fixtures |
| Operation results | Operation-specific deadlines, ACK/history/WaitSet predicates, release-only progress; blocking-wait-matrix.md, operation-result-mapping.md | Native and generated variant coverage; no universal invented error mapping |
| Reader/writer variants | Audited lifecycle blocking, handle/key and condition/loan provenance; strict next-instance advancement accepted as zzdds interpretation; writer-lifecycle-results.md, reader-variant-results.md | Correct current implementation deficiencies; preserve the documented DDS wording discrepancy |
| Runtime shutdown | Hosted retained executor, ordinary manual teardown tail, explicit external-loop servicing obligation; runtime-retirement.md, manual-runtime-driver.md | Real cancellation/drain, final-worker reclamation, no self-join |
| Bootstrap | Accepted versioned validation, rollback, pre-admission external attachment, no live executor replacement, explicit clock compatibility; runtime-bootstrap-contract.md | Concrete descriptors, platform clock/wake adapters and ABI review |
| Transport | Borrow/retain/copy ingress, bounded backpressure and reserved completion capacity; transport-runtime-contract.md, main-refresh-review.md | Adapt merged channels; bounded identity reclamation and asynchronous send completion |
| Public extension surface | Config-taking creation, standard defaults, factory selection, participant limits/getter, groups, owner/observer/resource/driver roles; concurrency-extension-surface.md, concurrency-api-draft.md | Production zzdds.idl, generated helpers and version compatibility; no additions to dcps.idl for non-OMG controls |
| Generic binding dependency | Managed reference lifetime, aggregate ownership, mixed Config/TOML behavior; zidl construction-reference-bindings.md and reference-ownership-contract.md | Complete generic generator support and cross-language tests; experimental C/Zig descriptor is not production ABI |

No additional application-visible policy decision was identified for this baseline.
The API draft's spellings and physical layouts remain subject to implementation review;
that review must preserve the accepted behavior or explicitly reopen the affected choice.

## Scope boundaries that must survive handoff

* GROUP access uses shared brackets/consumption, independent callback guards and atomic
  coherent visibility. The architecture does not supply a complete coherent-presentation
  wire algorithm: end markers, eviction/lifespan interactions and repair still need
  profile-specific design/integration validation. Do not present those as solved by the
  writer prototype. This milestone settles concurrency responsibilities and invariants,
  not complete implementation of every optional DDS profile.
* Optional profiles must be removable together with exclusive state. Exact build flags,
  target-specific availability and size savings are implementation/release work. Ordinary
  sample, loan and lifecycle synchronization still exists without GROUP.
* Designated-worker callback placement, affinity policy extensions, live executor
  replacement and forced runtime stop are outside initial scope. They must not weaken
  exclusion or introduce hidden cleanup obligations when added later.
* Reception/admission hardening and current codec/channel adaptation remain concrete
  implementation dependencies. Full XTypes, DDS Security, MCU ports and traversal
  protocols are not implied by concurrency readiness.
* Existing standard DDS behavior remains the starting point for operations not changed
  by this contract. This is not an exhaustive OMG conformance audit. A newly discovered
  observable ambiguity during migration requires a named review, not an undocumented
  universal error rule or an automatic expansion of the prototype.

## Evidence and confidence

The design suite records source/spec audits, bounded state models with negative controls,
hand-written ownership fixtures and a narrow generated C/Zig reference experiment.
Their individual limitations remain authoritative; model counts are not cumulative
coverage of one runtime. Existing zidl tests passed on 2026-09-16: 1,115 tests plus
23 integration build steps, including Java data/CDR and generated entity/JNI paths.
Those results do not validate experimental Java managed references, which are unsupported.

This final pass changed documentation only. Check local links and whitespace; no need
to rerun unchanged executable models or claim additional runtime validation.

## Completion and handoff

Concurrency v1 is now a behavioral implementation baseline. Production readiness still
requires the stages and acceptance evidence in concurrency-migration-plan.md, including
ABI publication review, actual binding/backend tests and performance/footprint measures.
The first production slice remains one reliable reader/writer pair through the shared
engine with manual and hosted progress, listeners, timed waits and automatic retirement.

Broker reconciliation is now consolidated in the [final handoff](specification-handoff.md)
and [broker guide](broker-spec-guide.md). Both behavioral packages can guide implementation;
wire/ABI publication and production migration remain separately gated.
