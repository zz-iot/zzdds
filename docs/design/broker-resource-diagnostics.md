# Initial broker resource and diagnostic surface

Use the runtime's common finite resource plan and negotiated broker ReceiveLimits.
Initial v1 does not add a resolved-plan getter, diagnostic pagination or a new family
of per-broker resource knobs. It must still bound global/session storage, pending
challenges, staging, overlap, repair, freshness capture/output and deferred references.
The [storage contract](broker-storage-contract.md) defines ownership/accounting.

Use the existing configuration path for finite build/platform defaults; explicit limits
must be validated before work is promised. Rate-limited logs plus the participant's
non-resetting current status expose failure without a listener. Credentials, cookies and
unbounded entity/topic labels are not diagnostics. Per-record detail can be logged
boundedly; no unbounded status payload is permitted.

The [public API](broker-public-api.md) controls the v1 Config/status fields. Expanded
resource controls and programmatic diagnostic enumeration remain later extensions.
The [archived proposal](archive/review-baseline/broker-resource-diagnostics.md) is not a
second public API or a requirement to ship those deferred controls.
