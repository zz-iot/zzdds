# zzdds stress tests

Concurrency- and lifecycle-under-load tests, `OpenDDS EntityLifecycleStress`-shaped.
Deliberately **not** part of `zig build test`: these are wall-clock, real-concurrency,
real-UDP, non-deterministic by nature — the opposite of the deterministic
`ManualClock` / mock-transport gate (`docs/design/testing-strategy.md`). They live here,
build against the zzdds repo root as an out-of-tree package (like `examples/`), and run
from their own Python harness.

Layout mirrors `examples/`:

```
stress-tests/
  run_all.py                       orchestrator — builds + runs everything (--strict for CI)
  zig/
    entity_lifecycle_stress/       multi-process port of OpenDDS EntityLifecycleStress
    lifecycle_churn/               in-process, N-thread entity/listener/waitset churn
```

Run everything:

```
cd zzdds && zig build -Dc-binding=false install     # native Zig API only; no bindings needed
ZZDDS_ZIG_OUT="$PWD/zig-out" stress-tests/run_all.py           # dev: skips what isn't built
ZZDDS_ZIG_OUT="$PWD/zig-out" stress-tests/run_all.py --strict  # CI: any skip is a failure
```

Each `zig/<app>/` also has a standalone `run.py` and its own `zig build` (pinning
`../../..`), so a single scenario can be iterated in isolation.

---

## Survey: OpenDDS `EntityLifecycleStress`

`OpenDDS/tests/DCPS/EntityLifecycleStress/` — `run_test.pl` + `publisher.cpp` +
`subscriber.cpp`.

**Harness.** `run_test.pl` spawns **10 publisher + 10 subscriber processes** by default
(`publishers N` / `subscribers M` override), *interleaved* — even loop index → pub, odd →
sub, wrapping — then starts them in that same interleaved order. All on **domain 31**.
`-DCPSPendingTimeout 3` caps how long a writer's teardown waits for unacknowledged
samples. 600 s overall timeout.

**Publisher process.** `create_participant` → `register_type` →
`create_topic("Movie Discussion List")` → `create_publisher` → `create_datawriter` →
`register_instance` → write **750** small samples 10 ms apart (or **4** samples of 4000
bytes, 2 s apart, with `-l`) → cleanup.

**Subscriber process.** `create_participant` → `register_type` → `create_topic` →
`create_subscriber` → `create_datareader` (+ listener) → block on a condvar until *any*
`valid_data` sample is seen, ≤ 7.5 s → cleanup, with a **monitor thread** that prints
"taking a long time to clean up" if teardown exceeds 3 s.

**The cleanup split** (both). `if (getpid() % 3) { delete_datawriter/reader;
delete_publisher/subscriber; }` — then **always** `delete_contained_entities()` +
`delete_participant()` + `TheServiceParticipant->shutdown()`. So ~⅓ of processes lean
entirely on the `delete_contained_entities` cascade; ~⅔ tear children down explicitly
first.

**What it stresses.** N-participant concurrent SPDP/SEDP fan-in / fan-out on one domain;
overlapping create + teardown (interleaved start, staggered finish); both teardown code
paths; teardown while peers are still matching; slow / hung teardown detection.

**What it doesn't.** Pass/fail is "every process exited 0 within 600 s" plus stdout
markers. It catches hangs and crashes; leaks / UAF / races only surface if you separately
run it under Valgrind / ASan. The cleanup path is chosen by `pid % 3` — non-deterministic
and not guaranteed to cover both. No structured metrics.

---

## The zzdds port

Two apps under `zig/`, both talking to the **native Zig API** (`zzdds.createFactory()`,
`dp.create_publisher(...)`, the generated typed `…DataWriter` / `…DataReader`) — no C-ABI,
no binding marshaling. Binding-marshaling stress is a separate concern (the Integration
tier in `docs/design/dcps-api-coverage-audit.md`).

### `zig/entity_lifecycle_stress` — the faithful multi-process port

One binary, `elc_stress`, with `--role pub|sub`. `run.py` spawns N pubs + M subs as
separate processes, interleaved, on a per-run-unique domain, bounded by
`_common.LiveProcess` (SIGINT → grace → SIGKILL; every wait has a ceiling). Entity graph,
keyed `Messenger` type, 750-small / 4-large sample profiles, subscriber-waits-for-first-
valid-sample, and teardown-duration monitoring are all faithful to OpenDDS.

Where it improves on the original:

| | OpenDDS | here |
|---|---|---|
| leak / double-free / UAF in teardown-under-churn | Valgrind, out of band | `-Ddebug-allocator=true` on the shared lib + `DebugAllocator` in the app → hard, attributable failure at exit |
| data races in the churn | — | `-Dsanitize-thread=true` build variant → gating |
| cleanup-path coverage | `pid % 3`, non-deterministic | `--cleanup {explicit,cascade}` flag; `run.py` always runs both |
| failure reproduction | — | `--seed`; every process prints a structured `SUMMARY: OK\|FAIL teardown_ms=<n> entities_created=<n>` line the harness asserts on |
| extra churn | — | `--churn` — create/delete a DataWriter/DataReader repeatedly on the live participant during active SEDP matching |

### `zig/lifecycle_churn` — in-process, N-thread churn

One binary, `churn_stress`, `DebugAllocator` as *the* allocator so any leak / double-free
/ UAF in churned teardown hard-fails at process exit. Generalizes the single hand-built
scenario in `test/dcps/participant_vtable_test.zig` ("reentrant delete_participant from a
timer-driven listener"). `--scenario`:

- **`entities`** — many threads create → use → delete `DataWriter` / `DataReader` /
  `Topic` / `Publisher` / `Subscriber` on shared participant(s) while SEDP matching is
  active. (audit: *"rapid DataWriter/DataReader create/delete during active SEDP
  matching"*)
- **`reentrant`** — the seed pattern run N-wide: a DEADLINE listener, fired from the
  participant's own timer thread, reentrantly deletes its whole entity graph including
  the participant. (audit: *"generalized reentrant-listener / entity-lifecycle churn"*)

Planned follow-on scenarios (frame is built for them; not in this first pass):
`waitset` (threads attach/detach conditions on a shared WaitSet while another blocks in
`wait()`), `listener` (concurrent `set_listener()` replacement racing entity deletion and
event delivery), `instance` (`register_instance` / `unregister_instance` / `dispose` /
`get_key_value` / `lookup_instance` churn), `cft` (ContentFilteredTopic / QueryCondition /
`set_expression_parameters` churn).

---

## CI

`ci.yml` job `stress` (`needs: test-linux`), modeled on the `examples` job: builds zzdds
native + `-Ddebug-allocator`, then `stress-tests/run_all.py --strict` with **CI-sized**
parameters (small N, short durations) and a hard `timeout-minutes`. The weekly `schedule`
trigger runs a heavier matrix (larger N, longer runs, `--large`). Following
`examples-tsan`, a ThreadSanitizer variant of `lifecycle_churn` runs in that lane.

## Findings

### `lifecycle_churn --scenario entities` — UAF in the discovery-driven listener dispatch (found + fixed 2026-08-29)

Found on the first run of the scenario. Originally ~40–60% repro with 4–6 churn threads
on one shared participant; 0% at 1–2 threads. Now 0 crashes in >100 runs at 8 threads;
the scenario is gating (not xfail).

The churn threads do spec-legal work: concurrent `create`/`delete` of Publisher +
DataWriter (and Subscriber + DataReader). The participant's UDP receive thread, running
SEDP `onReaderDiscovered`, releases `participant.mu` and then fires a matched writer's
`on_publication_matched` — which walks the DDS 1.4 §2.2.4.1.5 listener-fallback chain
(writer → Publisher → Participant). A racing `delete_datawriter` + `delete_publisher`
freed the `DataWriterImpl` and then the `PublisherImpl` in that window, so
`notifyPublicationMatched` → `dispatchWriterFallback` → `box.releaseRef` ran on freed
memory. `entity_quiesce.zig`'s own doc spells out why: it "can't protect a `ctx` pointer
that was already dangling before `acquire()`" — that has to come from whatever hands the
callback its `ctx`, and the discovery path handed it a raw pointer with `mu` released.

The `entities` scenario itself is the regression — it is gating in the `stress` CI job
(built with `-Ddebug-allocator`), and reproduces in ~10 s locally. It stays out of
`zig build test`: reproducing this race needs real UDP, a real receive thread, and two
racing teardown threads — inherently non-deterministic, the opposite of that suite's
`ManualClock` / mock-transport contract.

**Fix, two parts** (`src/dcps/{participant,writer,reader,publisher,subscriber}.zig`):

1. `MatchedNotify` gained `is_reader` + `quiesceAcquire`/`quiesceRelease`. The four
   discovery-notify sites (`onReaderDiscovered`, `onWriterDiscovered`, the two
   `announceMatched*`) now take the *target* `DataWriterImpl` / `DataReaderImpl`'s
   `EntityQuiesce` reference **while `participant.mu` is held** and hold it across the
   `notify` call — pinning the entity the raw `ctx` points at.
2. `PublisherImpl` / `SubscriberImpl` gained an `EntityQuiesce` (deferred teardown, like
   the writer/reader already had). Each `DataWriterImpl` / `DataReaderImpl` holds a
   lifetime reference on its parent for its whole (possibly-deferred) life, so
   `dispatchWriterFallback` / `dispatchReaderFallback` can never read a freed parent even
   if `delete_publisher` / `delete_subscriber` races. To avoid a ref cycle, the parent's
   owned-children teardown moved from `reallyDeinit` into `deinit` (synchronous, before
   `beginTeardown`).

Participant-level fallback has the same shape but the `entities` scenario keeps the
participant stable, so it is untested here — a `--scenario` that also churns
participants would be the way to exercise it.

## Non-goals

Not a Bench-style configurable framework. Not a perf / throughput / latency benchmark.
Not cross-vendor (that is the dds-rtps matrix). Not part of `zig build test`.

Any bug a stress test finds should be distilled into a **deterministic** Tier-1 / Tier-2
regression under `zzdds/test/` — stress tests find, unit tests pin
(`docs/design/testing-strategy.md`).
