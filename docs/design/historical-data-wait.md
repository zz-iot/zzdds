# Historical-data wait contract

Status: revised by D1, 2026-09-28. This is a behavioral specification, not a production
change. Earlier investigations and the superseded best-effort timeout policy are archived.

## Entry and completion

Perform normal argument, duration, enablement and lifetime validation first. Return OK
immediately for VOLATILE readers, BEST_EFFORT readers, or an empty captured set of known
relevant historical sources. Best-effort history may still arrive, but this API treats it
as having no historical-delivery obligation to await. OK on those paths is not proof of
receipt or discovery completeness. Warn at most once per reader lifetime on best-effort
historical wait; avoid allocation or unbounded logging on this path.

For non-VOLATILE RELIABLE readers capture source association lifetimes at one reader-owned
boundary. Later matches do not extend that invocation. Establish a finite history target
for each captured source; absence of its first target is not evidence of an empty history.
Use one absolute caller deadline. Zero duration polls; finite expiry returns TIMEOUT;
infinite duration does not disable close/interruption handling. No periodic polling thread
is required by this contract.

Completion requires protocol accounting through each captured boundary and final local
DDS receive processing of those obligations. RTPS receipt/ACK alone is insufficient:
queued decode, identity/admission checks and cache disposition must finish. Legitimate
filtering/GAP exclusions must be distinguished from lost/rejected required processing;
malformed or capacity-dropped required input cannot silently become completed history.
Retained coherent staging can finish receive processing without making a whole remote
coherent set visible. This wait does not end a remote set or promise future publications.

If a selected source unmatches before its target or protocol accounting is complete,
return ERROR unless another terminal outcome already won. If only safely retained local
processing remains, finish it using retained metadata despite unmatch. Completed sources
stay complete. Same-GUID rematch is a new association, not a substitute for interrupted
work. Reader close follows normal ALREADY_DELETED lifetime rules. Completion, timeout
and close resolve once under the shared request contract.

## Migration and evidence

The current implementation's nonzero wait for a first match is replaced by immediate
empty-source OK. Record this and best-effort immediate success in the implementation's
CHANGELOG and binding guidance: applications requiring discovery readiness must wait for
that explicit predicate, not historical data on an unmatched reader.

The historical transfer model covers abstract retained processing and terminal ordering;
its pre-D1 best-effort scenarios are historical until updated. Real target establishment,
processing-failure accounting and supported-provider signals remain integration gates.
See [archived investigation](archive/review-baseline/historical-data-wait.md) for evidence,
not controlling requirements. DDS describes historical receipt for nonvolatile readers;
D1 is the explicit zzdds no-obligation behavior, not a claim that ACK/history predicates
are interchangeable. [DDS 1.4 §2.2.2.5.3.32](https://www.omg.org/spec/DDS/1.4/PDF).
