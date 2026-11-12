# Thread Model and Type Information

This document describes current behavior. Proposed future behavior is tracked in the
[listener execution contract](concurrency/listeners.md#listener-execution-contract) and
[concurrency design](concurrency/architecture.md#concurrency-model-state-ownership-and-progress); those drafts do not describe implemented guarantees.
Every participant runs on the shared runtime (docs/design/concurrency/runtime.md). The
runtime's [thread mapping](concurrency/runtime.md#thread-mapping) says where each thread
of the earlier threaded implementation went.

## Current Thread Ownership

zzdds starts no thread of its own for participants, transports, discovery or writers: they
run as turns and timers on the participant's runtime, whose hosted workers (or the
application, through `drive()`) make progress. The one remaining thread is optional:

- `trace.AsyncRingSink` owns an optional flush thread when the application starts it;
  without one, the application drains it with `flush()`.

`DomainParticipantImpl.checkTimers()` walks active writers and readers and fires
deadline/liveliness status updates. It runs as a timer on the participant's runtime, armed
for the earliest time anything is due; a manual runtime runs it from `drive()`.

`UdpTransport` and `TcpTransport` start no thread: their sockets are sources on their
runtime's backend, which they must be attached to before they listen (or, for TCP, send).

Listener callbacks run as turns of their participant's listener group, on a runtime worker
(or inside the application's `drive()`), not on the stack of the call or receive that
raised their status. The exception is an explicit traversal: `Subscriber.notify_datareaders()`
invokes its readers' `on_data_available` on the calling thread before it returns. Either
way one listener object runs one callback at a time
(docs/design/concurrency/listeners.md). Application listeners should still avoid blocking:
a blocked callback holds a worker.

`WaitSet.wait()` blocks only the calling thread.

Concurrent `DataWriter.write()` (and the `dispose`/`unregister_instance`/`write_raw`
family) from multiple application threads on a *single* writer is safe: the RTPS
`StatefulWriter`/`StatelessWriter` layer is internally locked, and `DataWriterImpl`'s own
per-write state (`last_sn`, the `get_key_value` key registry) is guarded
(`src/dcps/writer.zig` — atomic `last_sn`, `key_registry_mu`). Ordering between concurrent
writes is not defined — they interleave — but no write is lost or corrupted.

## Single-Threaded Use

A manual runtime runs everything a participant does from the application's
`drive(budget, max_wait)`, with no thread started by zzdds
(docs/design/concurrency/runtime.md#manual-runtime-driving-and-external-loop-integration).
Integrating with an external event loop is specified there but not implemented.

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
