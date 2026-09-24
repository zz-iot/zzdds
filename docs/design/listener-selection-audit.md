# Explicit delegation listener-selection audit

Status: accepted initial selection policy, 2026-09-11. Production code is
unchanged. Existing membership, admission and retirement decisions remain applicable.

## Accepted selection and standards qualification

For explicit `notify_datareaders`, select the current attached reader's
`on_data_available` callback regardless of that registration's DATA_AVAILABLE mask.
Do not fall back to Subscriber or Participant listeners. Automatic notification
continues to honor its listener masks and routing rules.

DDS 1.4 section 2.2.2.5.2.11 specifies attached reader listeners and changed
DATA_AVAILABLE status without a mask test. Section 2.2.2.1.1.3 gives the general
mask restriction. Reading explicit delegation as a specific application-directed
operation is a supported interpretation, not an explicit mask-override sentence
in the OMG text. [DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

Two primary implementation sources support that interpretation:

* OpenSplice v7's Subscriber API expressly documents mask bypass and no parent
  propagation for explicit delegation. It also documents consumption for NULL
  listeners, which is a separate policy from mask bypass.
  [OpenSplice Subscriber API](https://download.zettascale.online/www/docs/OpenSplice/v7/apis/ospl/isocpp2/html/a02180.html).
* OpenDDS's inspected master `SubscriberImpl::notify_datareaders` copies reader
  membership, then the ordinary-reader path calls `get_listener()` and invokes it
  directly with no mask test or parent fallback. Its unread-sample predicate,
  null-listener status reset, and queued built-in-reader path differ from parts of
  our accepted contract; this is corroboration for selection, not wholesale adoption
  of that implementation. This moving source was inspected on 2026-09-11 and is
  not a pinned interoperability test.
  [OpenDDS SubscriberImpl.cpp](https://github.com/OpenDDS/OpenDDS/blob/master/dds/DCPS/SubscriberImpl.cpp).

The practical benefit is permitting a reader listener to be installed for explicit
application-directed delivery while suppressing automatic DATA_AVAILABLE callbacks.
A zero mask therefore does not prevent explicit delegation. Removing the attached
listener prevents its unclaimed invocation; a mask change alone does not.

## Local source findings

* `src/dcps/subscriber.zig:532`, `vtNotifyDataReaders`, iterates all readers while
  holding `subscriber.mu`. It neither tests changed DATA_AVAILABLE nor establishes
  its required reset boundary before calling the generic dispatcher.
* `src/dcps/reader.zig:3050`, `dispatchListener`, acquires the reader ListenerBox,
  checks the separately loaded mask, and falls back through the Subscriber.
* `src/dcps/subscriber.zig:605`, `dispatchReaderFallback`, can continue to the
  Participant. This is unsuitable for explicit attached-reader-only selection.
* `src/util/listener_fallback.zig`, `tryDispatch`, combines mask selection and
  immediate invocation. It cannot by itself supply retained selection, admission
  or the release-all-protocol-locks boundary.
* Reader `vtSetListener` publishes the box and mask separately. The future
  registration abstraction must publish listener/mask/generation consistently for
  automatic selection and retain the claimed registration for explicit selection.

These are source findings, not newly executed behavior tests. Fixing only the mask
check would leave the status, locking, lifetime and fallback problems unresolved.
Implement a dedicated explicit-selection operation feeding the common callback
admission machinery; do not globally change the generic helper's masking behavior.

## Accepted selection table for zzdds

Assume a live retained reader, current changed DATA_AVAILABLE, and successful admission.

| Attached reader callback | DATA_AVAILABLE mask | Explicit action |
| --- | --- | --- |
| Present | Enabled | Invoke attached callback |
| Present | Disabled | Invoke attached callback |
| Absent/null | Either | Skip without consuming status; no parent fallback |

If status is no longer changed, skip regardless of mask. StatusCondition enabled
statuses are a separate setting and do not select listener callbacks. A non-null
application listener whose method intentionally does nothing is still an invocation
and consumes status at the normal claim boundary.

A mask-only replacement still creates a new registration under the accepted
replacement contract. Pending admission withdraws and retries against that generation;
being masked out no longer makes the explicit callback ineligible. This does not
relax recursion, rights, depth or quiescence rules.

## Accepted nil-listener distinction

Skip an absent/null callback without consuming its pending status. The skip itself
resets neither reader DATA_AVAILABLE nor Subscriber DATA_ON_READERS; another real
callback or read/take can still legitimately reset status. A real attached callback
that intentionally does nothing is invoked and consumes status at the normal claim
boundary. Generated bindings must preserve this distinction between absence and an
application no-op method.

This deliberately differs from the documented OpenSplice behavior and the inspected
OpenDDS ordinary-reader path described above. A Subscriber can legitimately combine
listener-driven readers with readers handled through polling or WaitSets. Explicit
notification traversal should not consume status merely because no callback is
attached to one of those readers. Missing callbacks therefore produce no warning by
default. This preserves notification state, not a private sample or history snapshot.

## Implementation acceptance cases

Test enabled/disabled masks with a pending status, zero mask with explicit delegation,
no pending status, a parent-only listener, absent reader callback, mask-only replacement
while waiting, and actual claim versus replacement. Assert the attached reader is the
only selected target, no application callback runs under subscriber/protocol locks,
and status consumption occurs only at the selected dispatch boundary. The existing
status/admission models do not implement listener selection; these remain production
acceptance cases. No new public extension API or additional build flag is needed.
