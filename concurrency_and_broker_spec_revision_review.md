# Review of "spec revision 1" (d65f0bb)

Reviewer: Claude (Opus 5.5), 2026-09-29. Reviews the spec changes made after the review
thread (review → response → reply → follow-up → reply2), measured against the agreed
consensus and user decisions D1–D8. Focus is the specification documents. Tests,
fixtures and production code are touched on only where they affect the specs.

**Executed.** `python3 scripts/check_design_specs.py` passes: all maintained models plus
the 53 independent vectors.

---

## 1. Verdict

**The substance is right.** Every consensus item and user decision D1–D8 is reflected
faithfully. In several places the other agent improved on what we agreed:

| Improvement | Where |
| --- | --- |
| Reserve completion capacity **per coherent set**. My one-marker-slot suggestion was wrong when several sets are unacknowledged. | `concurrency-fast-paths.md` |
| Restoration interacting with closed or successor GROUP brackets | `prepared-read-conflicts.md` |
| Lifecycle rebirth must not get NOT_NEW reapplied | `prepared-read-conflicts.md` |
| Honest statement that a delayed lease reduction cannot retroactively shorten an already-granted observer deadline | `broker-aggregate-freshness.md` |
| The freshness egress formula is separated from its CPU capture cost | `broker-aggregate-freshness.md` |
| Measured mutable/appendable/final byte comparison | `broker-encoding-and-digests.md` |
| Resume identity no longer relies on digests, with a model and unsafe-shortcut counterexamples | `broker-encoding-and-digests.md`, `broker_baseline_identity.py` |
| Cooperative-profile footprint worksheet and constrained broker-client profile | `concurrency-fast-paths.md`, `broker-security-and-filtering.md` |

Earlier review items are also closed:

- listener retry fields added to the Config draft;
- personal path and cross-repo link removed;
- production fixes extracted as patches;
- prototypes moved out of the default, TSan and ReleaseSmall aggregates into a dedicated
  CI job;
- the D8 user-facing note is added to `docs/language-bindings.md`.

**The structure is not fixed.** The consolidation we agreed on (one authoritative home per
requirement, a small normative set) did not happen. The main defects are §2 (volume and
overlapping meta documents) and §3 (contradictions that survived because untouched
documents weren't swept). Both are editorial and need no new design decisions.

---

## 2. Too many documents (High)

**Current state:**
- 91 changed or added design documents on the branch, about 12.8k lines, excluding the
  archive;
- 19 archived copies;
- 7 pointer stubs of 6–18 lines whose only job is linking to the archive;
- 20 historical Python models still in the `docs/design/` root;
- `docs/design/patches/`.

The decision index says "Normative consolidation: Complete for review-affected
contracts". That is true only in the narrow sense that the edited documents were
reconciled.

**Overlapping meta documents.** Eight documents each claim some part of "status/entry point":

- `specification-handoff.md`
- `concurrency-spec-status.md`
- `concurrency-final-review.md`
- `review-decisions.md`
- `broker-spec-closure.md`
- `broker-implementation-checklist.md`
- `broker-spec-guide.md`
- `review-merge-preparation.md`

A reader still can't find one entry point. Evidence counts (23 tests, 53 vectors, state
counts) are repeated in several of them and will drift. They already have (see §3).

**Recommendation: one purely structural pass, with no semantic changes.** For example:

```
docs/design/concurrency/
  architecture.md      (model + admission + commit preparation + request lifetime + fast paths)
  listeners.md         (execution, identity, status/notification, delegation, deletion/quiescence, callback failure)
  operations.md        (L5 wait matrix, result mapping, read/take, ACK/historical/WaitSet waits, variants)
  runtime.md           (ownership, bootstrap, retirement, resources, manual/external driver, transport contract)
  extension-api.md     (extension surface + IDL draft)
docs/design/broker/
  overview.md          (current discovery-broker.md, trimmed)
  protocol.md          (bootstrap/admission, inventory, view, freshness, retention, operation table)
  wire.md              (bytes, registry, metadata/endpoints, compatibility; links schema/)
  api.md               (public config/status/readiness/diagnostics)
  security-and-filtering.md
  coexistence.md       (coexistence, origin version, domain identity, multi-domain)
docs/design/concurrency-broker-status.md   (single status + decision index D1–D8 + gates)
```

The rules for that pass:

- Delete the pointer stubs. Git history and the archive preserve the reasoning.
- Move the historical `.py` models into the archive, next to the documents that cite them.
- Keep evidence counts only in `test/design-models/README.md`.
- Put the merge-preparation content in PR descriptions. It is process, not design.
- Remove the per-document "Status: …, 2026-09-xx" narrative from normative text. The
  status document carries status.

---

## 3. Remaining contradictions and stale text (Medium)

These documents were not swept. Several items are the same ones listed in the original
review §3.11 and §5.12.

| Location | Problem |
| --- | --- |
| `listener-execution.md:123` | "cross-participant limit composition remains to be specified". It was accepted (`listener-identity-decision.md`, `concurrency-contract.md`). |
| `listener-execution.md:174`, `listener-callback-failure.md:284` | "Retry budgets remain open". Accepted, and now present in the Config draft. |
| `listener-identity-decision.md:87` | "Identity scope and binding defaults above still await acceptance". Accepted. |
| `listener-bulk-deletion.md`, `listener-callback-failure.md`, `listener-identity-decision.md` | Each still has two Status lines. |
| `discovery-broker.md:302` | Client states `… CONNECTING → ADMITTED → REGISTERING …`. Admission (ACCEPT) follows REGISTER, and the public `DiscoveryPhase` uses `CONNECTING, INTRODUCING, REGISTERING, SYNCHRONIZING, READY, BACKOFF, FAILED`. Align the two. |
| `broker-bootstrap-lifecycle.md:22` vs `broker-encoding-and-digests.md:124` / `broker-wire-bytes.md:151` | Large REGISTER/ACCEPT sizes disagree: 1228/1324 vs 1196/1292. One is stale. |
| `review-merge-preparation.md:3` | "The specification changes are uncommitted". They are now committed. |

---

## 4. Wire and schema clarity (Medium)

1. **Leftover mutable annotations on `@final` types.** Established `@final` structs
   (`Delta`, `FreshnessMarker`, `ViewEnd`, …) still carry `@id(n) @must_understand` on every
   member, and `ErrorBody` mixes in `@optional`. With final positional encoding, `@id` has
   no wire meaning. As far as I know, XTypes defines `@must_understand` only for mutable
   members. Leaving them there invites readers, and possibly future generator behavior,
   to assume evolution semantics the encoding doesn't have.
   - Remove `@id`/`@must_understand` from the final types.
   - Keep `@optional` only where an XCDR2 presence flag is intended, and add an
     independent vector for both the present and absent cases.
2. **Default UDP budget vs the broker's own ACCEPT.** D3 accepted that an oversized
   *client* SPDP fails with a local diagnostic. The worst-case *ACCEPT*, though, is 1292 or
   1324 bytes, over the 1,200-byte default before RTPS overhead. That failure would surface
   at the client as an unexplained timeout. Either cap the bootstrap ceilings, or require the
   broker to reject configurations it can't honor. Most of the excess comes from 128
   feature IDs; about 16 would be plenty for v1.
3. **Coherent end-marker encoding.** Cite the concrete RTPS mechanism in
   `concurrency-fast-paths.md` instead of leaving it wholly to integration: a DATA without
   `PID_COHERENT_SET`, or with `SEQUENCENUMBER_UNKNOWN`, which may omit its payload
   (RTPS 2.5 §8.7.6).

---

## 5. Over-specification (Low/Medium)

The TOPIC-coherent section of `concurrency-fast-paths.md` now prescribes one particular
algorithm: a retained close-scan obligation with a fixed membership frontier, dirty-rescan
restarts, batch scanning and handle retention. It is a reasonable design. As normative
text, though, it constrains implementations more than the requirements do.

**Recommendation.** State the requirements normatively:

- completion needs no later write;
- a stale seal never closes a newer generation;
- a commit that raced with the close is ordered before its writer's seal;
- per-set completion capacity is reserved before the set's first effect;
- `end` never waits on writer rights while holding Publisher rights;
- deletion follows incomplete-set semantics.

Present the scan algorithm as one conforming approach. Simply posting seal work to each
writer is another. The same applies to a few other "use X" phrasings in the broker
freshness scheduling text, such as the half-horizon refresh. Keep those as defaults, not
requirements.

---

## 6. Checklist answers

| Question | Assessment |
| --- | --- |
| Too many documents? | **Yes.** See §2. Content is the right size; organization is not. |
| Clear? | The new or rewritten documents are much clearer and more direct. Untouched listener documents retain the old log style. |
| Consistent? | Mostly. Residual items are in §3 and §4.1. |
| Sufficient to describe real systems? | Yes for an implementation baseline. Gates are explicit, and unknowns are marked as measurements rather than hidden. |
| Overly constrained? | Slightly, in places where algorithms are written as requirements (§5). The final established encoding is a deliberate, documented trade: later field additions need a new negotiated mapping. |
| Embedded/general-purpose flexibility? | Good. There is a named cooperative profile with a worksheet and a constrained broker-client profile. GROUP and filters compile out, hosted and manual progress are both defined, and neither profile requires dynamic allocation. |
| Scale/throughput/latency? | Good. Fast-path targets, batching without added delay, fairness without a shared counter, hosted no-helping, the freshness egress formula with its CPU caveat, and bounded exceptions. Priority remains a seam only, which was agreed. |
| Faithful to OMG specs? | Spot checks pass: PRESENTATION immutability, INSTANCE-scope coherent no-op, suspend as a hint, generation-rank semantics, partition in SEDP, historical-wait wording, and no claim about DDS Security relay. Apply §4.3. |
| Good design principles? | Yes. Effect/result/reclamation separation, reserved completion capacity, no rights across foreign code or I/O, explicit weakenings recorded as user decisions, and no silent fallbacks. |

## 7. Suggested next steps

1. Run the structural pass (§2) together with the §3/§4.1 fixes. These are editorial, with
   no semantic or decision changes.
2. Re-run `scripts/check_design_specs.py` and the codec probe after any schema annotation
   cleanup.
3. Split the branch into:
   - the SPDP domain-ID PR (with an interop run);
   - the zidl allocator-fix PR;
   - the normative design-docs PR;
   - the design models/probes/CI PR;
   - the concurrency prototype.

   Once the patches have become real PRs, delete `docs/design/patches/`.
