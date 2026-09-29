# Reply to the concurrency and broker specification revision review

The revision review is right that the previous pass settled the substantive decisions
more successfully than it consolidated their presentation. Calling consolidation complete
was premature. This pass accepts that criticism and replaces the overlapping active notes
with subject contracts, rather than adding another completion ledger.

## Consolidation and navigation

[The specification index](docs/design/concurrency-broker-status.md) is now the single
entry point, accepted-decision summary and implementation/publication gate list. Five
concurrency contracts cover architecture, listeners, operations, runtime and extension API.
Six broker contracts cover overview, protocol, wire, API, security/filtering and coexistence.
The index assigns responsibility to each. API declarations/default spellings and provisional
schema assignments have explicit homes; behavioral explanations refer to those homes.

The old active documents and pointer stubs are removed. Selected accepted requirements
have been edited into the subject contracts; discarded alternatives, source investigations
and historical models are retained in the dated consolidation archive. Existing links
were redirected to the current requirement when retained, or to the historical source
when the linked material is historical. Review-chain text remains historical, even where
its links now reach the consolidated contracts. The archive is not another normative layer.

Per-document status/date blocks, repeated execution ledgers and obsolete “next decision”
prose have been removed from the active contracts. The evidence inventory is
[test/design-models/README.md](test/design-models/README.md); counts and measured fixture
sizes belong there. No aggregate model count is presented as full-system correctness.
The accepted strict next-instance interpretation and WaitSet runtime selection replace
older unresolved recommendations. Lease renewal and typed reader/writer preconditions
remain explicit requirements after consolidation.

## Specific review dispositions

* **Stale listener decisions:** accepted. Concrete listener identity, grouping, preparation,
  retry and lifetime rules now live in the listener contract, with application declarations
  and defaults in the extension API. Designated-worker scheduling remains a future policy,
  not an unresolved requirement for the initial take-turns design.
* **Discovery phase order and bootstrap sizes:** corrected. REGISTER precedes ACCEPT and
  synchronization. Exact generated sizes are recorded only in the evidence inventory.
  The supported-feature fixture is distinguished from the maximum-schema stress fixture.
* **Final encoding annotations:** accepted. Removed member IDs and must-understand
  annotations from final structs; retained the mutable bootstrap annotations. Existing
  golden bytes did not change. Optional ErrorBody members retain actual presence flags;
  independent absent/present fixtures and generated-codec checks now exercise both forms.
* **Broker ACCEPT sizing:** accepted with a qualification. The very large selected-feature
  fixture is schema stress, not a legal v1 feature selection. That does not excuse missing
  broker checks. Locally predictable broker introduction/ACCEPT combinations must be
  preflighted when enabling configuration, and the exact request-dependent ACCEPT must fit
  before admission commits. This is a contract clarification, not merely a document move.
  Oversize UDP still has no hidden fragmentation, stripping or TCP fallback.
* **Native coherent completion:** accepted. The architecture identifies the RTPS 2.5 §8.7.6
  DATA completion mechanism: absent PID_COHERENT_SET or SEQUENCENUMBER_UNKNOWN, with payload
  permitted to be absent. Completion does not require a subsequent application write.
  Retention, repair and ordering obligations remain part of the implementation gate.
* **Scan and cadence examples:** accepted. The participant scan is a conforming implementation
  approach, not a required container/dispatch algorithm. Suggested refresh cadence is a
  starting default, not a protocol timing mandate. Bounded completion, fairness and freshness
  deadlines remain requirements regardless of implementation.
* **PR packaging:** agreed as a useful review preference. The small extracted implementation
  patches now live under review-artifacts/patches, outside the normative design tree.
  This pass does not rewrite commits or manufacture five PRs. Splitting publication is
  workflow work; it is not a prerequisite for the semantic contract to be coherent.

## What remains unchanged

D1–D8 remain accepted. In particular, foreign conversion preserves committed READ/NOT_NEW
and restores only eligible retained take claims on failure; it cannot reopen closed GROUP
access or overwrite a rebirth. Insecure cached discovery is v1, continuity is v1.1, and
secure cached discovery requires DDS Security integration evidence. WLP and user traffic
remain direct in v1. Relays and opaque forwarding remain later work. Final established
bodies and retained-baseline recovery do not restore transaction digests.

The consolidation is an implementation baseline, not a claim that the runtime migration,
broker, optional coherent wire profile or generated ABI has been implemented. The index
keeps those evidence gates visible without maintaining competing completion checklists.

## Validation and next review

The maintained specification checks, independent wire vectors, generated broker codec
checks and encoding comparison pass. The evidence inventory contains the exact counts,
sizing observations and limitations. Annotation cleanup preserves the existing fixture
bytes; new fixtures cover optional ErrorBody presence. Documentation path/anchor checks
and whitespace checks accompany the reorganization.

For the next review, please focus on lost or contradictory requirements in the subject
contracts, any remaining obsolete decision prose, and whether the distinction between
mandatory behavior and illustrative implementation is clear. Another agreement round is
not needed merely to restate the accepted product decisions. Any newly discovered wire or
public API conflict should be resolved explicitly before compatibility claims are frozen.
