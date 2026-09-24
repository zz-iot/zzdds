# Writer lifecycle result audit

Status: standards/source audit, 2026-09-15, against zzdds main c37181e and zidl
26dc737. Refines the accepted operation-result direction; no production changes.

## Standards findings

DDS 1.4 §§2.2.2.4.2.5–.14 gives write, dispose and unregister (including timestamped
variants) write-style capacity blocking. Reliable capacity waits use max_blocking_time;
expiry is TIMEOUT. Immediate OUT_OF_RESOURCES is permitted for resource-limit blocking
when waiting cannot free the required capacity. Dispose explicitly references write's
resource-error rules. Unregister's prose explicitly references blocking and timeout.

Registration also references blocking/resource errors, although its signature returns
InstanceHandle_t. Keep that signature: never return a numeric DDS error as a handle.
Registration is idempotent; lookup does not register. HANDLE_NIL is also permitted
when the service chooses not to allocate a handle, so it is not a precise failure code.

For write/dispose/unregister, a detectable existing-handle/key mismatch is
PRECONDITION_NOT_MET; a detectable nonexistent handle is BAD_PARAMETER. A nil handle
selects identity by key. Unregister retires registration rather than merely disposing
the value. Timestamped variants retain their corresponding handle rules.

Source: [OMG DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF), printed pages 50–54.
These findings do not establish an error-precedence order for simultaneous faults.

## Current source gaps

* writer.zig writeRaw uses a fixed ten-second polling deadline and sleeps one
  millisecond, rather than the configured reliability duration. Its capacity check
  precedes protocol insertion; the check alone is not a concurrent reservation.
* registerInstanceRaw and lookupInstanceRaw compute a handle from a key hash without
  writer registration state. The C ABI bootstrap calls the same static function.
  vtWriteRaw compares a supplied handle with that hash-derived value and returns
  BAD_PARAMETER on mismatch; it cannot implement the two membership cases above.
* writeRaw inserts key_registry data after protocol write succeeds, swallowing copy
  and map-allocation failures. Publication can therefore succeed without the key
  bookkeeping this path attempted to establish. This is a source finding, not a
  reproduced fault-injection test.
* disposeRaw/unregisterRaw directly call the protocol writer, whereas generated raw
  WriteKind operations go through writeRaw. Migration must audit both paths rather
  than assuming one helper covers every binding.
* C++ generated helpers maintain a separate instance_handles_ unordered_map. That
  cache must not become independent authority for registration across interface
  views, bindings or concurrent calls; its allocation and synchronization belong in
  the preparation/publication audit too.

## Contract implications

Use the existing writer admission ledger for lifecycle operations as well as data.
Reserve necessary instance/key metadata, control changes and output machinery before
commit. Resolve capacity waits with the applicable operation deadline; do not reset
it during retries or wait while retaining an execution turn. A capacity precheck is
insufficient when concurrent preparations can consume the same space.

Registration membership must be authoritative in the core writer lifetime, with
identity/generation validation at commit. Hash equality alone is not proof of a live
registration. Binding caches are derived conveniences. Concurrent registration of
one instance must resolve to one registration; an admitted unregister must not retire
a newer registration accidentally. Exact handle allocation/collision strategy is
implementation work, not fixed by this audit.

For the proposed implementation, failed implicit registration plus write must leave
no newly published registration or history effect. Explicit registration is its own
commit. Successful unregister retires registration atomically with required lifecycle
publication, honoring autodispose; retained key/control storage may outlive logical
retirement for protocol and cleanup obligations. Dispose alone does not retire the
registration. A later close or send failure does not undo a committed operation.

Preserve handle-returning APIs, mapping unsuccessful handle acquisition to HANDLE_NIL.
Keep detailed internal timeout/allocation diagnostics without requiring standard DDS
applications to use extensions. If precise application-facing registration results
are later exposed, place the additional interface in zzdds.idl. No new public API is
needed to adopt the concurrency rule here.

## Remaining validation and next step

Production migration needs focused tests for configured deadline versus the current
10-second constant, competing instance-capacity reservations, registration racing
unregister, wrong-existing versus unknown handles, metadata allocation failure, and
all timestamped/raw/typed paths. These are migration gates, not another scheduler model.

Next complete the reader variant/precondition audit, then consolidate the remaining
extension/API decisions. This closes the writer lifecycle *mapping investigation*,
not the production correctness gaps or the complete concurrency specification.
