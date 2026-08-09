# WaitSet example — what it demonstrates

A pub/sub example built around `WaitSet` instead of listeners, exercising
all four DDS condition types on a single `WaitSet` at once:
`GuardCondition`, `StatusCondition`, `ReadCondition`, `QueryCondition`.
Where `hello_world` shows the listener-driven style and `shape` is a
configurable diagnostic tool, this is the WaitSet-driven style — the same
kind of pub/sub flow, reached through `wait()` instead of callbacks.

This is also the first example to exercise `WaitSet`/`GuardCondition`
construction at all: before the work this example was built alongside, no
binding had a way to construct either (see zzdds's `docs/roadmap.md`).

## The type

```idl
@appendable
struct WaitsetSample {
    int32 count;
    int32 priority;
    string<256> message;
};
```

Topic name `WaitsetSample`. `priority` exists purely so `QueryCondition` has
something real to filter on: the publisher sends `priority = count` for
`count` 0..9, so a filter of `"priority > 4"` selects exactly the
high-priority half (5..9).

## QoS

`RELIABLE` + `KEEP_ALL`, same as `hello_world`, on both sides.

## Publisher flow

One `WaitSet` with two conditions attached simultaneously:

- `StatusCondition` (`PUBLICATION_MATCHED_STATUS`) — reused across two
  separate wait phases: first waiting for a reader to match, later waiting
  for it to disconnect again.
- `GuardCondition` — set by a background "watchdog" thread if the whole run
  exceeds an overall deadline. This is deliberate: it demonstrates a
  bounded-wait pattern that isn't tied to any single `wait()` call's own
  timeout, and it's genuine cross-thread concurrency on the same
  `WaitSet`/condition — the watchdog thread and the main thread's `wait()`
  loop both touch it at once.

After both phases complete, `delete_datawriter()` is called **without**
first detaching the `StatusCondition` from the `WaitSet` — deliberately, to
demonstrate that this is safe. Before the lifecycle-safety fix this example
was built alongside, that would have left the `WaitSet` holding a dangling
pointer into freed memory.

## Subscriber flow

One `WaitSet`, four conditions attached at once:

- `StatusCondition` (`SUBSCRIPTION_MATCHED_STATUS`) — logs the match.
- `QueryCondition` (`"priority > %0"`, parameter `"4"`) — the high-priority
  half. Drained via `zzdds.takeWithQueryConditionRaw`, the Zig-native raw
  path to what the OMG spec calls `take_w_condition` (`dcps.idl` had
  documented this operation as not yet implemented anywhere — this example
  is what motivated adding the first path to it).
- `ReadCondition` (any sample/view/instance state) — everything the
  `QueryCondition` pass didn't take. Draining the `QueryCondition` match
  first, then draining everything else via a plain filtered take, means
  every sample that arrives is delivered exactly once, split into exactly
  two streams (`high-priority`/`low-priority`) each cycle — a realistic
  content-based-routing pattern, not just a filtering demo.
- `GuardCondition` — same watchdog pattern as the publisher.

On the main `wait()` loop, `get_conditions()`'s result is checked against
all four to decide what to do next — `wait()` can legitimately return with
more than one condition triggered at once (e.g. a status change and new
data arriving in the same cycle), and the loop handles that rather than
assuming exactly one.

Cleanup detaches and deletes every condition explicitly before tearing the
reader down — the well-behaved counterpart to the publisher's deliberately
not doing that for its `StatusCondition`. Both are legitimate, safe
patterns; the point of having one of each in this example is to demonstrate
that the *choice* is safe either way, not that one is correct and the other
isn't.

## A known, minor gap this example works around

zidl's Zig backend generates the vtable slot for `as_{Base}` upcasts (e.g.
`StatusCondition → Condition`) but not a convenience wrapper method on the
interface struct itself, unlike every other generated operation. Both
`publisher.zig` and `subscriber.zig` have a small local
`somethingAsCondition()` helper calling through the vtable directly instead.
Worth fixing in zidl at some point — tracked as a small follow-up, not
blocking here.

See each language's own README for build and run instructions once that
port exists; today only `zig/waitset` exists.
