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

## Reads and takes running out of memory

A read or take counts the samples it selects, then makes everything it needs for them
under the reader's lock before it changes anything: its output arrays (`PrepareOutput`),
a read's copies, and in loan mode a `loan_table` slot. Only then does it take, mark READ,
pin or reset DATA_AVAILABLE. Running out of memory at any of these returns
OUT_OF_RESOURCES and leaves every sample where and as it was. A failure after the samples
are handed out, a binding that cannot decode them, is the [two-step take](#two-step-take)'s
subject.

## Two-step take

A binding may not decode every sample it takes: a type it does not fully support, or
malformed data. Taking in one step loses such a sample. The two-step take claims the
samples first and decides what becomes of each once the binding has tried them.

* **Claim.** A typed read or take is a loan-mode `take_raw`/`read_raw` (and the
  `_next_instance` forms): the samples leave the cache, or are pinned, into `loan_table`,
  and the binding decodes from the reader's own buffers.
* **Commit.** All decoded: `return_loan_raw`, as now.
* **Fail.** Some did not: `return_loan_raw_failed` returns the loan and names them, one
  octet per sample, nonzero for a failure. What becomes of them is the reader's policy:
  * By default they are dropped, as a one-step take would, with a warning logged once per
    reader.
  * A reader that opts in (`set_keep_undecodable`) keeps them, restored as described below,
    for the application to collect with `take_raw`: to log them, save them, or read the
    fields it can.

Restored samples:

* Come back READ and marked `UNDECODABLE_SAMPLE_STATE`, a zzdds extension bit of the
  sample state just above `ANY_SAMPLE_STATE`, and raise no DATA_AVAILABLE. A read, take or
  condition selects one only when its sample-state mask has that bit, so typed reads and
  takes and existing conditions pass over it: a sample its binding cannot decode does not
  come back to it, and neither a poll nor a WaitSet spins on it. A raw read or take asks
  for them with the bit: alone, for only those, or with `ANY_SAMPLE_STATE`, for every
  sample.
* Return to their place in the cache, by arrival: each sample is stamped as it arrives, and
  a restored one is inserted among the others by its stamp.
* Keep to the history and RESOURCE_LIMITS as an arrival would. Under KEEP_LAST, those an
  instance no longer has room for below the depth go, oldest first, as a replacement
  would. Under KEEP_ALL, those that no longer fit `max_samples` or
  `max_samples_per_instance` are dropped and counted SAMPLE_LOST. Those past their
  lifespan are dropped. Restoring never fails and never exceeds a limit.
* Still have their instance. A sample on loan holds its instance from being forgotten, as
  a cached one does, until the loan returns, so a loan's instance handles stay valid while
  it is out.

A read that fails marks the samples it names `UNDECODABLE_SAMPLE_STATE` under the opt-in,
and changes nothing otherwise. A reader's samples marked so count toward its limits like
any other, so under KEEP_ALL, samples the application never collects can fill the cache.

## WaitSet waits

A wait holds its WaitSet (`quiesce`) until it returns, so destroying the WaitSet
meanwhile ends the wait, ALREADY_DELETED, rather than freeing it under the waiter.
`shutdown`, which `destroy` runs first, closes the WaitSet for good under its lock:
it detaches the conditions, firing their release hooks, and wakes the wait, which
then returns ALREADY_DELETED, as do later waits, attaches, detaches and
`get_conditions`. A WaitSet admits one wait at a time: another, even with a zero
timeout, is PRECONDITION_NOT_MET. Attaching a condition wakes the wait to rescan.
Only the first look may find a condition true past the deadline; a later one past it
is a TIMEOUT. What a condition's trigger tests, and which samples an ordered access
lets a read or take see, are the next part.

## Status

| Operation | Status |
| --- | --- |
| DataWriter and Publisher `wait_for_acknowledgments` | Done |
| DataReader `wait_for_historical_data` | Done |
| Blocking write | Done |
| Take after an allocation failure | Done |
| Take when a binding fails to decode | Done: `return_loan_raw_failed`, `set_keep_undecodable`; zidl's typed reads and takes use them |
| WaitSet lifetime, admission and deadline | Done |
| WaitSet condition triggers | Next: a ReadCondition's trigger does not apply its state masks or query (it skips undecodable samples only); next-instance and copy-mode takes ignore an ordered access's window |
| WaitSet results in C++ and Java | Later: a selected result's wrappers are not leased through conversion |
