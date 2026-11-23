# Concurrency: operation effects under endpoint locks

[Operations](operations.md) and the
[architecture's request states](architecture.md#admission-and-request-state-transitions)
define when an operation's effect commits, how a wait is settled and what a close does to
an operation still in progress. They describe queued requests. zzdds runs operations
inline instead: endpoints keep their mutexes, and the runtime supplies progress
([first slice](../concurrency-broker-status.md#implementation-and-publication-gates)).
This note says how the contracts map onto that model, and tracks what is still to be done.

## Approach

* **One decision point per effect.** Where the contracts have a request move from
  uncommitted to committed or aborted, zzdds makes that decision under the lock of the
  entity that owns the effect. Commit, timeout and close are then decided in one order
  there, and the first one decided stands.
* **Waits are records their producers settle.** A blocking call registers what it waits
  for with the entity whose changes settle it, and each change settles it under that
  entity's lock, at the moment the change happens. The caller only sleeps (hosted) or
  helps the manual runtime until settled or its deadline passes. A result settled before
  the deadline stays settled, however late the caller runs.
* **A wait keeps what it waits on.** A call that waits holds the entity, and any protocol
  object it waits on, until it returns. Deletion settles the wait first, then destroys.

## Acknowledgment waits

`src/protocol/ack_wait.zig` holds the two records.

* **`Waiter`:** one per call. It keeps the call's first outcome, and its caller sleeps
  on it.
* **`Capture`:** one writer's part of the call. It records the last committed sequence
  number, and the reliable readers that owed an acknowledgment of it when the wait
  began, each by GUID and match.

The `StatefulWriter` settles a capture at each acknowledgment, reader unmatch, or refresh
of a reader to best effort. A reader matched later never joins. A reader that unmatches
owes nothing more, and matching again is a new match.

Deleting a writer runs in this order:

1. `DataWriterImpl.closeProto` stops new calls from pinning the protocol writer.
2. The protocol writer's `deinit` settles every capture `writer_closed`. Its readers are
   removed only after that, so their removal cannot look like acknowledgment.
3. A DataWriter's wait returns ALREADY_DELETED. A Publisher's wait returns ERROR, unless
   the Publisher's own close came first and settled it ALREADY_DELETED.

The Publisher's wait counts every reliable writer's capture before beginning any, so a
writer acknowledged at once cannot settle the whole wait early.

## Status

| Operation | Status |
| --- | --- |
| DataWriter and Publisher `wait_for_acknowledgments` | Done |
| DataReader `wait_for_historical_data` | Next: lifetime pin, close result, captured sources, no polling |
| Blocking write | Planned: reserved capacity served oldest first, close before commit, per-instance limits, failed implicit registration undone, handle error codes |
| Take after an allocation failure | Planned: no sample lost when building the output fails |
| Take when a binding fails to decode | Planned: two-step take, so a binding can fail a decode and the samples return |
| WaitSet waits | To audit |
