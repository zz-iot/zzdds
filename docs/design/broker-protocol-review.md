# Broker protocol consistency review

Status: cross-document consolidation pass, 2026-09-23. Documentation review and opcode
inventory check, not a wire freeze, security assessment or executed protocol model.

## Findings and corrections

| Finding | Correction / governing rule |
| --- | --- |
| REGISTER table required an unexpired introduction for every message | First consumption requires a live unconsumed introduction; replay uses retained outcome/session validity even after original introduction expiry |
| Admission protection still defined retired hello/v1 and admission/v1 transcript hashes | Replaced with references to exact client/server SPDP, service-path and register/v1 inputs in current registry; no dual handshake |
| Retry-retirement text described a cookie directly authorizing OPEN | Separate UDP cookie consumption, introduction consumption, outcome replay and physical reclamation; cookie-free transports still retain introduction replay protection |
| Endpoint negotiation still referred to HELLO and an unknown-prefix vendor request | Initial contact is native directed SPDP; predefined pair serves path validation; REGISTER follows validated offer and supplies endpoint pairs |
| Retired model was described as checking all current admission traces | Scoped its evidence to its older cookie abstraction and ordered query retirement; current introduction state machine still needs implementation tests |
| Operation table split before new bootstrap rows | Rejoined it and mechanically verified all 27 active opcode/name pairs against IDL; reserved 1–3 and 23–24 stay inactive |

The main overview now names the current handshake and standard domain identity. Historical
investigation documents can retain obsolete alternatives when explicitly labeled, but they
cannot override the registry, operation table or accepted lifecycle rules.

## Cross-message invariants checked in this pass

* Same-scope logical broker participant; explicit origin domain ID and default-empty domain
  tag; no realm, domain translation or cross-scope inventory/view/resume.
* Introduction sample/capability bytes remain immutable for an attempt. REGISTER binds
  exact bytes and retained state; sample/hash agreement is correlation, not authentication.
* No reliable session allocation before admission reservation; successful admission is
  replayable within its stated window and cannot be reexecuted after result retirement.
* Introduction expiry, result expiry, UDP cookie expiry, establishment timeout and origin
  lease are separate. Duplicates extend none. Retire storage only after live references end.
* Accepted-session output waits for valid established control confirmation; state or RTPS
  ACK alone does not confirm ACCEPT. Fresh endpoint identities fence old transport state.
* Inventory COMMIT gates subsequent MUTATE. View generation/cursor and ordered presence
  query serials prevent stale retries from recreating successor state. READY uses fixed cuts,
  not global quiescence or all peers alive, and does not depend on listener execution.
* Disconnect/expiry withdraws broker evidence, not independently justified direct evidence;
  WLP and user data remain direct. No routing/proxy service was introduced by shared ingress.

These are documentary checks against the accepted contracts. They do not prove runtime
ordering, bounded-memory realization or malformed-input rejection.

## Remaining closure work

1. Reconcile the byte-baseline/registry and all main-spec framing/metadata references in
   one final pass: no retired transcript label or opaque realm encoding may remain normative.
2. Make each unsupported/unknown/malformed case point to a single phase-appropriate error
   rule; verify scope/identity agreement through inventory and downstream record admission.
3. Record wire-freeze blockers explicitly, separating chosen protocol requirements from
   unvalidated provider details (cookie integrity profile, protected size overhead and native
   SPDP inline-context integration). Do not treat generic provider choice as implemented
   authentication or DDS Security support.
4. Publish one consolidated status/disposition for W1–W5 with the implementation regression
   matrix referenced, rather than adding new feature proposals or new scheduler experiments.

No new user-level design decision was identified in this pass. The corrected REGISTER
rule follows the already accepted lifetime contract. The specification package still needs
the remaining closure checks before claiming independent implementation compatibility.

Final byte/error/scope pass: corrected direct bootstrap body classification (including
ADMISSION_REJECT) and prohibited bootstrap fragmentation explicitly. Replaced remaining
normative realm/OPEN references in the registry. Added domain identity, parent-dependency,
key-only removal and resume checks plus a phase-specific error table to the operation
contract. The [closure ledger](broker-spec-closure.md) separates settled behavior from
named wire-freeze and delivery gates. No new protocol operation or user decision added.
