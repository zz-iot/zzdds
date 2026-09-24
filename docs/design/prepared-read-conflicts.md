# Prepared read/take conflicts

Status: selected initial R3 policy, bounded-model checked, 2026-09-15.
No production implementation change; binding mappings are accepted in
[binding-access-failures.md](binding-access-failures.md).

## Recommended initial approach

Use optimistic candidate retention, validation and whole-batch commit. Holding a
payload pin does not reserve the sample against another consumer, preserve its
eligibility or publish an application loan. Other read/take, receive, lifecycle and
presentation operations keep their normal admission. No reader turn, protocol lock
or shared-consumption reservation spans foreign conversion.

At selection capture sample lifetime/generation, immutable payload and dependencies
that determine membership, returned SampleInfo, ordering and access legality. At
commit validate those dependencies under their authoritative ownership. Relevant
changes include another take, sample/view/instance state change, expiry, query or
access-generation change and logical close. A new unrelated sample need not invalidate
an attempt unless it affects required ordering/rank/metadata. Do not use one blanket
reader-update version that restarts every conversion under continuous ingress.

Commit all prepared samples and their read/take/loan effects in one logical operation,
or none of that attempt. Do not silently publish only the surviving subset: its
SampleInfo/ranks, next-instance cursor and requested ordering may no longer match the
prepared batch. A validated selection must satisfy the applicable DDS operation;
this document does not declare arbitrary retained subsets valid for every variant.
Where final metadata can be filled without failure at commit, the generator can do
so; otherwise its prepared value participates in validation.

## Retry and result policy

On a conflict, release attempt-local typed output and pins outside locks, then make
a fresh selection under normal admission. Reuse immutable decoded payload only when
its exact identity, representation and ownership remain valid; never reuse stale
SampleInfo merely because payload bytes did not change.

Use a separate participant-configured stale-validation budget, positive and
fixed at participant creation, with a build-changeable initial default of four
invalidated attempts per invocation. This number is an initial policy, not
a measured optimum and not inherited from listener retry limits. The budget does
not reset on worker migration, reselection or a query-generation change. Ordinary
context contention does not consume it, and it is not a new time-based timeout.
Yield to normal scheduling between conflicted attempts; do not hold an executor in
an unbounded immediate retry loop.

On budget exhaustion, first perform normal current-state/precondition checking without
committing effects: close returns ALREADY_DELETED on a recognized retained lifetime;
invalid operation preconditions retain their existing errors; a valid fresh selection
with no eligible data returns NO_DATA. If eligible data remains but another attempt
would exceed the budget, return ERROR with a conflict-exhaustion diagnostic. Never
report NO_DATA solely because the prior prepared candidates were invalidated. No
attempt in that failed invocation has committed read/take effects, though concurrent
operations and normal protocol/lifecycle processing can have changed the reader.

Two takers selecting the same sample illustrate the rule: one commits, the other's
validation fails. The latter reselects and either takes different eligible samples,
returns NO_DATA if none remain, or reaches the documented conflict bound under further
contention. Two reads may both succeed when their state/metadata observations remain
valid; this is not an exclusive single-consumer contract.

Preparation resource/decode errors use the separate synchronous-output failure table;
only actual stale validations charge this budget. Retained candidate capacity must be
bounded independently so concurrent preparers cannot pin unbounded history. Per-reader
pin/preparation admission limits and their exact resource mapping are an integration
requirement, not implied by the per-call retry count.

## Reentrancy and alternative

Foreign conversion and cleanup can reenter DDS. An inner call can invalidate an outer
candidate, but cannot make that candidate commit stale effects. Same-target preparation
recursion needs an explicit active-operation guard before any reentrant foreign hook;
return ERROR for recursive prepared read/take on the same reader lifetime in the
same synchronous chain, independent of which interface view was used. This rule is
separate from, not a consequence of listener notify_datareaders recursion limits.
Cross-reader application recursion is not bounded by this same-reader check; supported
foreign preparation hooks need the binding's explicit recursion/resource contract.

Alternative: an exclusive access reservation held through conversion. It reduces
retry work and can provide stronger progress under contention, but another consumer
may wait behind allocation, deserialization or arbitrary reentrant code. It also needs
new reservation-versus-expiry/lifecycle and dependency rules. Prefer optimistic access
initially; do not add a hidden exclusive fallback after retry exhaustion.

The cost of the recommendation is possible ERROR under sustained contention, plus
wasted conversion work. It preserves independent consumer progress and bounds work
per call without requiring a mandatory thread handoff. Applications seeking predictable
single-consumer behavior can coordinate their access explicitly.

## Bounded validation and remaining work

Run `python3 docs/design/prepared_read_model.py` from zzdds. Two competing takers,
two samples, one relevant state update, expiry and close were explored with retry
limits 1, 2 and 4: respectively 922/1,135, 1,629/2,087 and 1,790/2,302
states/transitions (4,341 states and 5,524 transitions across scenarios).

The model checks no duplicate consumption, no stale whole-batch commitment, immutable
completed outcomes, and no access effects for failed calls. It exercises exhaustion,
true empty reselection, expiry/reselection and close before/after commitment. Negative
controls detect omitted validation, stale survivor commitment and false NO_DATA on
exhaustion. Every reachable state has a path to completion; this is not a fairness
or production progress proof.

The small retry limit exercises exhaustion; the finite environment does not establish
behavior under four successive conflicts or justify four as a measured default.
The model abstracts relevant metadata as one version and models takes only. It does
not validate read-state/rank calculations, query/GROUP dependencies, pin capacity,
recursive foreign hooks or generated conversion exception safety. Those remain
implementation validation requirements, not reasons to expand this scalar experiment.

Next settle exact binding error mappings and review the operation variants before
closing R3. No bounded model can make an arbitrary foreign callback terminate.
