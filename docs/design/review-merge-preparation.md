# Review revision merge preparation

The specification changes are uncommitted for user review. No history was rewritten,
no PR was published, and no production refactor was started. Existing production fixes
from the original branch are isolated below as reviewable patches; they remain in their
original commits until commit/PR splitting. Do not apply the patches again to this branch.

| Separate change | Review artifact | Scope and proposed release note |
| --- | --- | --- |
| zzdds native SPDP domain ID | [patch](patches/spdp-domain-id.patch) | Emit explicit PID_DOMAIN_ID; decode either endian, use receiver default only when absent, and reject foreign explicit domains before install/refresh. Release note: native discovery no longer relies solely on inferred domain ports. Domain-tag implementation remains separate. |
| zidl bounded sequence allocator propagation | [patch](patches/zidl-bounded-sequence-allocator.patch) | Forward allocator through bounded sequences whose named/typedef element decoder needs it; regression covers typedef/struct elements. Release note: generated Zig bounded struct-sequence decoding now preserves required allocator parameters. |

Both patches were extracted from the local main-to-branch changes and pass reverse-apply
checks against their corresponding current checkout. This verifies isolation/applicability,
not a new run of production tests. Existing regression source accompanies each patch.
The zidl patch excludes managed-reference prototype support; keep that experimental until
its generic ownership/default/mixed-Config contracts and supported binding tests pass.

Suggested packaging: land the independently reviewed fixes with their regressions/release
notes, then rebase the spec branch to remove duplicate production hunks. A new zidl pin is
a separate integration action after publishing that dependency. These are commit/release
operations for the user, not uncompleted specification decisions.

Design validation now has a separate CI job and explicit targets. Concurrency prototypes
are removed from production test, TSan, ReleaseSmall and coverage-emission aggregates.
The maintained Python review models/independent vectors run via
`python3 scripts/check_design_specs.py`; generated codec probes remain explicit because
they require a built generator with the allocator fix. Historical models are evidence,
not automatically included as current conformance tests.

The D1 historical-wait change needs a release note when implemented: unmatched,
VOLATILE and BEST_EFFORT readers return OK after validation, without promising receipt.
BEST_EFFORT ACK/history waits warn once per entity. The D7/D8 binding limitation must ship
with the changed helpers; [binding guidance](../language-bindings.md#planned-readtake-failure-contract)
records the required user-facing wording without implying implementation today.
