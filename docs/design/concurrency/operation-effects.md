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

Two records serve an acknowledgment wait:

* **`Waiter`** (`src/protocol/waiter.zig`): one per call. It keeps the call's first
  outcome, and its caller sleeps on it.
* **`Capture`** (`src/protocol/ack_wait.zig`): one writer's part of the call. It records the last committed sequence
  number, and the reliable readers that owed an acknowledgment of it when the wait
  began, each by GUID and match.

The `StatefulWriter` settles a capture at each acknowledgment, reader unmatch, or refresh
of a reader to best effort. A reader matched later never joins. A reader that unmatches
owes nothing more, and matching again is a new match.

Deleting a writer runs in this order:

1. `DataWriterImpl.closeProto` stops new calls from pinning the protocol writer.
2. The protocol writer's `deinit` settles every capture `part_failed`. Its readers are
   removed only after that, so their removal cannot look like acknowledgment.
3. A DataWriter's wait returns ALREADY_DELETED. A Publisher's wait returns ERROR, unless
   the Publisher's own close came first and settled it ALREADY_DELETED.

The Publisher's wait counts every reliable writer's capture before beginning any, so a
writer acknowledged at once cannot settle the whole wait early.

## Historical-data waits

`src/protocol/history_wait.zig`'s `Capture` is the reader's part of the call. It records
the matched writers that owed the reader history when the wait began, by GUID and match:
those whose first HEARTBEAT has not yet said how much, and those that have not delivered
it all in order. The `StatefulReader` settles it under its lock, after delivering to the
DataReader's cache, so the history is there to take when the wait returns. A writer that
has delivered stays done. One that unmatches before then fails the wait (ERROR), even if
it matches again. So does history the DataReader received but dropped: its data callback
says what it did with each sample, and one RESOURCE_LIMITS rejected or there was no memory
to keep cannot count as delivered. A filtered one (content, time, ownership) can. A wait
begun once such a loss has happened fails at once. A failure at the deadline or later is
a timeout. The reader's close settles the wait first (ALREADY_DELETED), as a writer's
does.

## Blocking writes

A write first asks its `StatefulWriter` for room (`admitWrite`), without holding the
DataWriter's `publish_mu`. The writer keeps its admissions in one list, oldest first:
each waits for room or holds it. Room counts the history and the held admissions against
`max_samples` and the instance's `max_samples_per_instance`. Under KEEP_LAST, a change
that replaces its instance's oldest takes none, held or new: an instance grows by no more
than its room below the depth. With neither limit set there is nothing to count. A waiter
takes room only when no waiter ahead of it also has room and is still within its
deadline, so a newcomer cannot take what an older write is owed, and an older write past
its deadline holds nobody up. Close and the deadline are checked under the same lock, at
that decision: a write that has waited to its deadline times out, even if room is freed
then. A zero timeout only checks.

Admitted, the write registers its instance under `publish_mu` and commits
(`writeAdmitted`), which uses the held room. A writer closed in between refuses the
commit, and a registration the write made is undone. Deletion closes writes as it
settles acknowledgment waits, so a write blocked or admitted then returns
ALREADY_DELETED, and none commits after the delete returns. A BEST_EFFORT writer never
waits: no room is OUT_OF_RESOURCES.

## Status

| Operation | Status |
| --- | --- |
| DataWriter and Publisher `wait_for_acknowledgments` | Done |
| DataReader `wait_for_historical_data` | Done |
| Blocking write | Done |
| Take after an allocation failure | Next: no sample lost when building the output fails |
| Take when a binding fails to decode | Planned: two-step take, so a binding can fail a decode and the samples return |
| WaitSet waits | To audit |
