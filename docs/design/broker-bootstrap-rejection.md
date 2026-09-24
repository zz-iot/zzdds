# Bootstrap rejection reply

Status: current SPDP-service draft, reconciled 2026-09-18. OP_ADMISSION_REJECT = 29 carries
AdmissionReject directly in a bootstrap 1.0 Frame, without an established Envelope.
This is distinct from mutation REJECT and established-session ERROR.

## Fields and correlation

Required fields: admission_attempt, client_nonce, rejected_operation (REGISTER=32),
reason (restricted below), retry_after_ns, request_digest. Attempt/nonce come
from the REGISTER being rejected. SPDP/path failures receive bounded silence in v1. No session, owner details, endpoints, credentials, diagnostic
strings or arbitrary reflected request bytes are returned.

request_digest is SHA-256 over ASCII `zzdds-broker/rejected-request/v1` plus one NUL,
u16 little-endian rejected operation, then u64 little-endian body length and the exact
triggering Frame.body bytes. It is correlation, not authentication. Validate uniqueness,
required fields and exact body bounds before trusting extracted request identifiers.
On the client, match an outstanding request's bytes, operation, attempt and nonce,
configured service, current binding and expected response path. Protected deployments
also require the authenticated association; never accept an unprotected rejection there.
Unsecured replies provide diagnostics, not protection against network impersonation.

## Reasons and retry behavior

Use the existing numeric error registry, restricted to:

| Reason | Permitted request | Client behavior |
| --- | --- | --- |
| UNSUPPORTED | REGISTER | Stop this attempt; report incompatible version/feature/profile; no unchanged automatic retry |
| UNAUTHORIZED | REGISTER | Stop this attempt; require corrected credentials/policy before retry |
| OWNER_CONFLICT | REGISTER | Retry a fresh admission with backoff, within the caller's original deadline |
| LIMIT | REGISTER | Retry a fresh admission with backoff |
| BACKEND_FAILURE | REGISTER | Retry a fresh admission with backoff |
| TRANSACTION_EXPIRED | REGISTER | Restart admission with a fresh directed SPDP attempt and introduction |

All other codes reject the reply as invalid for this phase. retry_after_ns is zero for
UNSUPPORTED and UNAUTHORIZED. For retryable reasons, zero means no server hint, not
immediate spinning. A nonzero finite hint is a relative suggested delay; clamp it to
configured retry bounds, combine with local jitter/backoff, and never extend a caller's
absolute deadline. It does not promise when a competing participant will disappear.
No automatic retry changes the GUID or weakens security/required features.

A valid rejection ends this attempt. Duplicate rejected requests cannot later succeed
under that attempt; retain a bounded negative result or invalidate its introduction
so retry requires a fresh attempt. No rejection changes an existing participant's lease,
registration or readiness. An already accepted attempt is never turned into a rejected
operation because sending ACCEPT failed. Identical retries of a still-valid accepted
attempt replay ACCEPT. Once fenced/expired, an attempt may receive TRANSACTION_EXPIRED,
but this means its admission is no longer usable, not that it never succeeded.
An ACCEPT received before a delayed rejection makes the rejection irrelevant; no
bootstrap rejection can tear down an established session.

## Reply eligibility and resource limits

Malformed, uncorrelatable or incompatible fixed framing is silently dropped. Do not
answer a rejection with another rejection. Before disclosing OWNER_CONFLICT, validate
the source path and any configured scope authorization. Unauthorized callers must not
learn that a particular GUID is registered; use generic UNAUTHORIZED or silence.

Replies use the contacted service address and the request's channel/validated return
path, never request-supplied locators. Use non-fragmented best-effort bootstrap DATA.
No reliable endpoint/history is allocated just to reject a request. Bound output bytes,
rate, pending negative outcomes and work per path/principal and globally. Prior to path
validation, preserve the existing aggregate no-amplification budget: repeated requests
do not authorize unbounded cached reply retransmission. Include RTPS and protection
overhead in budgets. If the reply cannot fit the path/frame budget, or correlation,
authorization or rate checks fail, silence is valid. TCP uses the same bounded policy;
its existence is not scope authorization.

The baseline body is 120 bytes and its Frame is 144 bytes, excluding RTPS/transport/
security overhead; these sizes are checked by the current REGISTER rejection fixture, whose digest is
computed independently from the exact REGISTER body. The separate retired-OPEN fixture
remains historical and is not a valid current reply. Future
optional members must still fit the configured non-fragmented bootstrap budget. This
reply improves diagnosis where deliverable; it does not eliminate timeout-based failure
detection. Local activity remains available under allow-degraded startup.

## Trace checks

* Competing REGISTER on a validated authorized path receives OWNER_CONFLICT; the incumbent
  deadline stays unchanged and the contender schedules a new attempt with backoff.
* A short or spoofed prevalidation request receives no amplified reply and no ownership
  information. A valid request can still time out if replies are dropped or rate limited.
* Wrong attempt, nonce, digest, binding or phase is ignored without changing retry state.
* Lost ACCEPT is retried as ACCEPT while valid, never rewritten as an admission failure.
* A replayed negative result cannot extend startup time or invalidate an established
  session. Revocation/expiry of old admissions still obeys the admission contract.

These are specification trace checks. Codec fixtures validate serialization separately;
production needs executable rate-limit, loss, spoofing, phase and deadline tests.
