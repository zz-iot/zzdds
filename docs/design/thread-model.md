# Thread Model and Type Information

## Current Thread Ownership

The default UDP/SPDP path is multi-threaded:

- `UdpTransport` owns one receive thread per active socket/port.
- `SpdpSedpDiscovery` owns an SPDP timer thread for periodic participant
  announcements and lease checks.
- `StatefulWriter` starts a heartbeat thread when the first matched reader is added.
- The polling `InterfaceMonitor` owns a polling thread when interface monitoring is enabled.
- `trace.AsyncRingSink` owns an optional flush thread when the application starts it.

DCPS deadline and liveliness checks are not driven by a participant-owned timer thread in
the current implementation. `DomainParticipantImpl.checkTimers()` walks active writers and
readers and fires deadline/liveliness status updates. Tests call it directly with a
`ManualClock`; production code that needs these status callbacks must arrange to call it
from its own timer loop until a participant timer driver is added.

Listener callbacks may run on transport receive threads in the live UDP path. With
`MemoryTransport` + `DirectDiscovery`, callbacks happen synchronously on the caller's
thread. Application listeners should avoid blocking and should not call back into APIs that
would invert locks held by the receive path.

`WaitSet.wait()` blocks only the calling thread.

## Single-Threaded Direction

An embedded/single-threaded API such as `DomainParticipant.drive(timeout)` is not
implemented. The design should keep this possible by preserving non-blocking seams for
transport polling and by keeping timer checks explicit through `checkTimers()`.

## Type Information Registration

Current XTypes support is limited to optional TypeInformation advertisement:

- `DomainParticipantImpl.registerTypeInfo(type_name, cdr)` stores a CDR-encoded
  TypeInformation blob by type name.
- SEDP writer announcements can include `PID_TYPE_INFORMATION` when `-Dxtypes=true` and a
  blob has been registered for the type.
- SEDP reader announcements deliberately omit `PID_TYPE_INFORMATION` because peers such as
  OpenDDS may initiate TypeLookup when they see it.
- No TypeLookup service, TypeObject exchange, or remote schema-evolution matching is
  implemented.

Zig-native `TypeSupport` registration is separate from TypeInformation advertisement:
`participant.registerTypeSupport()` can provide `compute_key_hash` for keyed-instance
handling and optional `get_field` access for ContentFilteredTopic/QueryCondition
expressions. Remaining TypeSupport work is the C ABI/non-Zig binding bridge and eventual
TypeLookup integration.
