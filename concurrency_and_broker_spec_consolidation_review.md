# Review of the consolidation pass (15594a3)

Reviewer: Claude (Opus 5.5), 2026-09-29. Reviews the "revision review reply" commit
against [my previous review](concurrency_and_broker_spec_revision_review.md). Per the
reply's request, this review focuses on three things:

- lost or contradictory requirements;
- obsolete decision prose;
- whether mandatory behavior is clearly distinguished from illustrative implementation.

**Executed checks:**

- `scripts/check_design_specs.py`: PASS.
- My own link/anchor check over `concurrency/`, `broker/` and the status index: 0 broken
  links or anchors.

## 1. Summary

**What the reply fixed:**

- The structure now matches what we asked for. There is one entry point with a decision
  index (`concurrency-broker-status.md`), five concurrency and six broker subject
  contracts, and no pointer stubs, meta ledgers or merge-preparation docs.
- Evidence counts live only in the evidence inventory. Historical models are archived.
  The production patches are moved out of the design tree.
- The specific fixes from my previous review are all done: `@final` annotation cleanup,
  new ErrorBody vectors, phase order, the ACCEPT preflight rule with separated
  supported/stress sizing, the RTPS §8.7.6 citation, and the scan algorithm as one
  conforming approach.
- Declining to split PRs in this pass is fine. That is your call.

**What still needs work: the subject contracts are concatenations, not rewrites.** Each new
file is the old documents stacked as H2 sections. They keep the old headings, anchors and
much of the old investigation voice. For example: "Requirements established in
discussion", "Recommended capture", "Deadline, close and completion proposal",
"initial design: option 3", "Likely follow-on", "Review checkpoint, 2026-09-15", and
"bootstrap integration — 2026-09-17". Heading prefixes such as "Agreed:" were stripped
mechanically, which left fragments like "### core boundary" and "#### take-turns
execution".

That structure causes the three problems below: a real requirement contradiction (§2),
requirements that were lost to the archive (§3), and leftover decision prose (§4).

The consolidated set is about 7,150 lines. `listeners.md` alone is 1,236 lines and
`protocol.md` 1,192. That's workable, but it is not yet an implementer-friendly contract
set.

## 2. Contradictory requirements (High)

1. **Hosted helping versus WaitSet default.** The status index and
   `architecture.md#concurrency-fast-paths--helping-and-fairness` say ordinary hosted
   callers do not help by default. `operations.md` "Stable helping policy"
   (lines 855–876) and `extension-api.md:183` make `DEFAULT_SHARED_RUNTIME` the standard
   WaitSet policy, and define it as "Bounded internal helping on the configured default
   shared runtime". Under that definition, an ordinary hosted thread in `WaitSet.wait`
   helps. Line 891 ("Hosted default applications can rely on background progress") is
   not a rule.

   **Fix:** state that in hosted runtimes, `DEFAULT_SHARED_RUNTIME` means observe-only for
   ordinary callers. Helping applies to manual runtimes and callback-chain waits.
2. **The universal write sequence still comes first.** `architecture.md:135`
   ("Proposed write sequence: … obtain a short-lived Publisher ticket where shared
   publication controls require it …") is the first write path a reader meets. It is
   only corrected 115 lines later by the GROUP-only note (line 251) and the fast-path
   section (line 558). `architecture.md:231` still calls the write effect boundary
   "proposed".

   **Fix:** state the INSTANCE/TOPIC single-turn write path first, and mark the
   ticket/gate sequence as GROUP-only where it is introduced.
3. **Status is contradicted within the same doc.**
   - `architecture.md:69` says "synchronization mechanisms and operation-specific
     boundaries remain proposals for review".
   - `architecture.md:83` says "The state transitions are defined below".
   - The file header says "This is a current contract".

   Pick one per section: normative, or illustrative/gated.
4. **Retry-retirement paragraph contradicts itself.** `protocol.md:1031–1034` says the
   retry-retirement proposal "now recommends … ordered presence-query serials … pending
   acceptance". The very next paragraph says that direction is accepted and presence
   serials are historical. Delete the first paragraph. The heading anchor
   `broker-retention-review--blacklists-and-next-decision` also carries the stale
   "next decision" title.

## 3. Requirements lost to the archive (High)

The broker overview shrank from 685 lines to 88. The status index declares the archive
non-normative ("explain history only"). Normative requirements that lived only in the old
`discovery-broker.md` are therefore now effectively deleted. I confirmed by grep that each
of the following survives only in `archive/consolidation-2026-09-29/discovery-broker.md`:

| Lost requirement (old section) | Why it matters |
| --- | --- |
| Core invariants (§3): only the admitted owner mutates its state; broker streams never occupy an origin's native SEDP sequence space; user-data locators never become broker control locators; a participant is installed before its endpoints, and removing a participant removes its endpoints before the participant-lost callback; limits produce visible errors, never silent truncation | These are the protocol's safety properties. Only the sequence-comparison and no-silent-truncation fragments survive elsewhere. |
| Identity/data model table (§5): `broker_epoch` (fresh unpredictable 128-bit per store lifetime, invalidates cursors), `incarnation_id`, `session_id`, `owner_generation`, `delivery_seq`, "counters MUST NOT wrap" | `delivery_seq` and the epoch semantics are used throughout `protocol.md`/`wire.md`, but never defined. |
| UDP obligations (§6.3): reply from the contacted service address on the same socket/path; pacing, RTT-sensitive repair, bounded in-flight bytes, aggregate congestion budget per client | Without these, WAN deployments can produce unbounded repair traffic. |
| TCP obligations (§6.4): disable `reuse_connection_by_host` for broker channels; slow receivers must not block the store | NAT correctness and isolation. |
| Channel lifetime (§6.5): one shared ingress dispatcher per service rather than a handler per session, given the 64-handler cap; correlate close notifications | Scale requirement tied to the current transport. |
| Snapshot install (§7.2): stage, then reconcile old and new views in one serialized update; identical GUID/revision records must not cause a lost/found storm; RESYNC_REQUIRED plus a retry budget when churn outruns the snapshot | User-visible churn behavior. |
| Broker failure (§7.4): DEGRADED keeps installed peers until their leases expire; single authority per scope; epoch change forces full re-registration and staged replacement | Operationally critical. |
| Operations (§12): graceful drain, admin controls, authorized inspection API, protocol/version reporting, the required metrics list | Needed for a deployable broker. |
| Verification (§15): transport matrix (UDP↔TCP, IPv4/IPv6, same-NAT source), network-namespace tests, fuzzing of bootstrap/envelope/ParameterList/fragment parsers, 2/100/1k/10k benchmark tiers with p50/p95/p99 | Acceptance criteria, currently absent from the status gates. |

Smaller losses on the concurrency side (old `concurrency-model.md` §5, §6 and §8):

- consolidating periodic tasks instead of one heartbeat thread per writer;
- the three validation paths (receive→callback, reliable write under backpressure,
  shutdown);
- no thread/sleep/socket dependency in a freestanding core compile;
- p50/p95/p99 reporting for uncontended and overloaded runs.

**Fix:** restore these into `broker/overview.md` (invariants, identity model, failure
behavior, operations), `broker/protocol.md` (UDP/TCP/channel obligations, snapshot
install) and an "acceptance criteria" section of the status index, plus the concurrency
items into `architecture.md`. Then diff every archived document against its new home for
MUST/SHALL/"must"/"never" sentences. The broker overview is the case I checked; the same
risk applies wherever a document was shortened rather than moved.

## 4. Obsolete decision prose and stale references (Medium)

**Examples of leftover proposal wording:**

- `listeners.md:95`: "Review checkpoint, 2026-09-15: … recommendations below remain the
  proposed final L1/nesting refinements".
- `listeners.md:152`: "Participant nesting configuration recommendation".
- `listeners.md:896`: "Subtree admission protocol: proposed initial mechanism".
- `operations.md:411/458/502/744`: "Recommended capture", "Deadline, close and
  completion proposal", "Recommended scope", "Recommended mechanism".
- `protocol.md:742`: "initial design: option 3".
- `protocol.md:706`: "Likely follow-on".
- `runtime.md:660`: "bootstrap integration — 2026-09-17".
- `architecture.md:174`: "**Proposal C5:**".
- `architecture.md:246`: "the user accepted … on 2026-09-10".

**Stale self-references:**

- `architecture.md:18` names `runtime-bootstrap-contract.md`, and `extension-api.md:244`
  names `manual-runtime-driver.md`; both files are gone.
- `architecture.md:101` refers to "section 7.1", but headings are no longer numbered.
- `architecture.md:274` says WaitSets and runtime construction "remain outside this
  draft", yet they are defined in `operations.md` and `runtime.md`.
- `architecture.md:546`, `runtime.md:198` and `broker/wire.md:350` say "This document /
  proposal / draft" about a section that is now inside a larger document.

**Orphaned evidence text:** `architecture.md:343` ("All configurations preserved ledger
bounds…") refers to a model-results table that was removed.

**Prototype-specific instructions in normative text:** `architecture.md:404`
("Replace the prototype's `req[0..id]` order scan").

**Meaningless links:** `architecture.md:71` links both "design-level trace validation"
and "test-only synchronization prototype" to the status index.

## 5. Mandatory versus illustrative (Medium)

The status index states the rule clearly: contracts own behavior, and examples don't
select algorithms. The contracts themselves mostly don't mark which sentences are
normative. Many requirements are still phrased as "Recommend …" or "Prefer …", and many
implementation sketches are phrased as "Use …".

**Suggestion:**
- Adopt an explicit convention: MUST/SHOULD/MAY, or a per-section "Requirement" versus
  "Conforming approach" label.
- Apply it during a rewrite, not a concatenation.
- Rewrite each subject document as requirements first, rationale second, with alternatives
  moved to the archive.
- Target: operations/listeners around 400–600 lines each.

**Open items need a single home.** Genuinely open items are scattered inside contracts
and absent from the status index. Examples:

- `listeners.md:773`: subtree admission algorithm is an "explicit remaining design task";
- `architecture.md:153`: discovery announcement/disposal ordering "remains to be
  specified";
- `architecture.md:103`: context granularity and the visibility/retention algorithm are
  "not settled";
- `architecture.md:546`: cancel-all vs close-then-cancel shutdown is not selected.

Add an "Open design items" table to the index, so "settled" means exactly the things not
in that table.

## 6. Recommended next pass

One more **editorial** pass, with no design changes:

1. Fix the four contradictions in §2. The WaitSet/hosted-helping one needs a one-line
   rule.
2. Restore the §3 requirements into their subject homes. Then run an automated check that
   every MUST/must/never sentence in the archive either appears in a normative document
   or is explicitly listed as superseded.
3. Strip the §4 proposal/date/self-reference prose, and apply a normative-marking
   convention (§5).
4. Add an Open design items table and an Acceptance criteria section to the status index.

After that, I'd consider the specification set ready to split into the PRs discussed
earlier. The substance (D1–D8, fast paths, claims, freshness, draft-3 wire) remains sound
and needs no further agent round.
