# spikes/python

Not a Python binding. A throwaway probe answering two specific questions
raised in zidl's `docs/roadmap.md` ("Binding design review: interfaces vs.
impls, inheritance, and C-ABI identity" and the "Other complications" list
under it) *before* that review commits to a real Python backend design:

1. Does a zzdds-internal thread (never created by, or announced to, the
   Python interpreter) correctly deliver a listener callback into Python —
   i.e. does `ctypes.CFUNCTYPE`'s automatic `PyGILState_Ensure`/`Release`
   actually work here, the way JNI's `AttachCurrentThreadAsDaemon` already
   does for the Java binding?
2. Does the `ctx`-carrying-a-pointer pattern several C-ABI entry points use
   (`zzdds_register_type_support_ctx`, the CFT field-accessor `ctx`, and —
   the sharper version — a listener's own function pointers) have a Python
   equivalent of Go's `cgo.Handle` requirement, and if a binding gets that
   lifetime wrong, what actually happens?

A third question got added after the first round of probes, from a
follow-up conversation about whether the same "who keeps this alive" shape
recurs for `WaitSet`/`Condition` attachment, not just listeners:

3. If a `Condition` is attached to a `WaitSet` and the application's only
   reference to it then drops, is the `WaitSet` responsible for keeping it
   alive until an explicit `detach_condition()`? (Spec answer, and zzdds's
   actual behavior: no — see probe 4 and the Findings section.)

Two more follow-up confirmations, added when a "are we ready for the design
review" conversation flagged them as open rather than actually tested:

4. `WaitSet` itself has the identical no-factory, app-owned shape as
   `GuardCondition` — does destroying it while another thread is actively
   blocked inside `wait()` on it (not just idle) crash, hang, or resolve
   safely? See probe 5's `--waitset` mode.
5. `zzdds_register_type_support_ctx`'s `ctx_deinit` hook is the same
   "acquire now, release via a hook later" shape as a listener's
   `release_listener_data` — does it actually behave the same way under the
   same GC-pressure test? See probe 5's `--typesupport-ctx` mode.

No zidl Python backend, no CDR codegen, no packaging — five flat scripts
using `ctypes` directly against zzdds's existing C-ABI (`zzdds_c.h`/
`dcps.h`), the same one the C/C++/Java bindings already use. `spike_shim.c`
is a ~15-line C helper for the two things ctypes has no portable way to do
from pure Python (get a QoS struct's real `sizeof()`, poke one nested field)
without hand-replicating `DDS_DataReaderQos`'s full layout for a throwaway
script.

## Setup

```sh
cd zzdds && zig build -Dc-binding=true install
cd ../zzdds-examples/spikes/python
gcc -shared -fPIC -I../../../zzdds/zig-out/include -o libspike_shim.so spike_shim.c
python3 probe1_deadline_timer.py
python3 probe2_many_threads_stress.py
python3 probe3_dangling_trampoline.py --safe
python3 probe3_dangling_trampoline.py --unsafe   # expected to crash -- see Findings
python3 probe4_condition_ownership.py --vanish   # expected to show a silent detach -- see Findings
python3 probe4_condition_ownership.py --crash    # expected to crash -- see Findings
python3 probe5_waitset_lifetime_and_typesupport_ctx.py --waitset
python3 probe5_waitset_lifetime_and_typesupport_ctx.py --typesupport-ctx
```

Each probe finds `libzzdds.so`/`libspike_shim.so` next to itself / at the
default relative zzdds checkout path; override with `ZZDDS_LIB`/
`SPIKE_SHIM_LIB` env vars if your layout differs.

## What each probe does

- **`probe1_deadline_timer.py`** — creates one reader with a 1s DEADLINE
  period on a topic nobody writes to, and waits for zzdds's per-participant
  timer thread (spawned unconditionally, ticks every 100ms — see zzdds's
  own roadmap "DEADLINE/LIVELINESS QoS is now enforced automatically") to
  fire `on_requested_deadline_missed` into Python repeatedly, entirely on
  its own. Cheapest possible "unknown native thread calls into Python"
  check — no writer, no data flow, no second process.
- **`probe2_many_threads_stress.py`** — repeats probe 1's setup 60 times,
  fresh participant (and therefore a fresh, distinct native timer thread)
  per iteration, tracking Python thread-object count and process RSS for a
  leak. Approximates (does NOT literally reproduce — see the script's own
  docstring) the more realistic long-running-process stress case: zzdds's
  writer heartbeat thread is lazily respawned per writer over an
  application's lifetime, so many distinct never-before-seen OS threads
  each hit `PyGILState_Ensure` for the first time, not just one repeatedly.
- **`probe3_dangling_trampoline.py`** — the adversarial one. `--safe` keeps
  the callback objects alive (the correct pattern, implicit in probes 1/2).
  `--unsafe` drops every Python reference to them immediately after
  `create_datareader()` returns — a binding bug, not a zzdds bug — then
  churns the heap before waiting for a deadline tick. Each mode runs as its
  own subprocess since the finding, if real, is a segfault, not a Python
  exception.
- **`probe4_condition_ownership.py`** — creates a standalone `WaitSet` +
  `GuardCondition` (no participant/topic needed — both are
  app-instantiated with no owning factory), attaches the condition, wraps
  the native handle in a small class whose `__del__` destroys it (the
  natural, RAII-shaped thing a binding author would plausibly write, not a
  strawman). `--vanish` drops the only reference and confirms the condition
  disappears from `WaitSet.get_conditions()` with no error. `--crash` also
  captures the raw handle in a second variable before dropping the wrapper
  (a realistic pattern — cached elsewhere, logged, handed to another call)
  and tries to use it afterward.
- **`probe5_waitset_lifetime_and_typesupport_ctx.py`** — two independent
  confirmations in one file. `--waitset` spawns a background thread blocked
  inside a real `DDS_WaitSet_wait()` call (10s timeout, no conditions
  attached), then drops the only Python reference to a GC-triggered-destroy
  wrapper around that *same* `WaitSet` from the main thread while the
  background thread is still inside the blocking call — the scarier variant
  probe 4 flagged (destroy while actively in use) but didn't build.
  `--typesupport-ctx` registers a `TypeSupport` with a `ctx` pointing at a
  Python object with no other live reference, forces GC+heap-churn pressure
  (same technique as probe 3), then registers a second `TypeSupport` under
  the same `type_name` — which should supersede the first and fire its
  `ctx_deinit` exactly once, with `ctx` still intact.

## Findings

**1. GIL attach works, and is well-behaved.** `ctypes.CFUNCTYPE`'s automatic
`PyGILState_Ensure`/`Release` correctly bootstraps a `_DummyThread` Python
thread object for zzdds's internal timer thread on first call, tears it back
down cleanly after each individual invocation (confirmed via
`threading.enumerate()` staying flat across 20+ repeated calls from the
*same* OS thread — no accumulation of stale `Dummy-N` entries), and — the
main open question — this is a genuinely different mechanism from JNI's
attach-once/detach-at-thread-death model, yet needed zero special handling.
Worth recording as real evidence, not just an assumption inherited from "JNI
already proved this pattern works."

**2. No leak across many distinct short-lived native threads either.**
`probe2` forced 60 distinct native OS threads (one per participant/timer
thread) to each do a first-time GIL attach, then terminate. All 60 produced
distinct `native_id`s (confirms they really were distinct threads, not
one reused), `threading.active_count()` never grew past baseline, and
process RSS grew ~10MB on iteration 1 (one-time warmup: shared libraries,
allocator arenas, interpreter caches) then stayed flat (~4KB/iteration
average over the remaining 59 — noise, not a trend). No evidence of the
"many distinct never-before-seen OS threads" case being worse than the
"one thread, many calls" case probe 1 covered.

**3. The real finding: dropping a listener's callback objects before the
DDS entity is destroyed reliably crashes the process, and nothing currently
protects against it.** `probe3 --safe` runs clean. `probe3 --unsafe` — which
does nothing wrong from zzdds's own C-ABI contract's point of view, no
"unregister" call skipped, no misuse of any zzdds function — segfaults
every time it's been run (confirmed 3/3, with two *different* fault types
across runs: `SIGSEGV` once, `SIGTRAP` once — consistent with a genuine
jump into freed-and-since-reused memory, not a single deterministic
address). Root cause, confirmed by tracing the actual mechanics rather than
assumed: `create_datareader()` copies the `DDS_DataReaderListener` struct's
function-pointer *values* into zzdds's internal storage — the
`ctypes.Structure` instance passed in is genuinely done being needed the
moment the call returns. What has to stay alive instead is the underlying
`CFUNCTYPE` **callable objects themselves**, because ctypes owns the actual
executable trampoline memory those pointer values refer to, and frees it
once nothing references the callable. zzdds's `release_listener_data` hook
exists specifically to tell a caller when it's safe to let those go — but
that hook is *advisory*: it tells you when you're allowed to stop holding a
reference, it can't force you to keep holding one until then. This is a
structurally different failure from anything `ListenerBox`/`EntityQuiesce`
protect against: that machinery guards the DDS *entity*'s lifetime
(reader/writer), which is entirely zzdds-side state; the trampoline's
backing memory is Python/ctypes-side state zzdds's C code has no visibility
into at all. No existing mechanism generalizes to cover it.

**4. A related but structurally different finding: `WaitSet` attachment is
never ownership, confirmed both from the spec and from zzdds's actual
behavior — and the failure mode this creates for a binding is a silent
correctness bug, not (by itself) a crash, unless a binding's own design
choice turns it into one.** Per DDS 1.4, a `WaitSet` never owns anything
attached to it. Real ownership is: automatic and tied to the parent
`Entity` for `StatusCondition`; tied to the parent `DataReader` for
`ReadCondition`/`QueryCondition` (explicit `delete_readcondition()`, or
implicit at reader teardown); and — the sharp case — tied to the
*application itself* for `GuardCondition`, which has no owning factory at
all. zzdds's own condition/`WaitSet` lifecycle fix (see zzdds's
`docs/roadmap.md` "WaitSet / condition example") already guarantees the
*memory-safety* half of this is handled: destroy a condition's true owner
while it's still attached, with no explicit `detach_condition()` first, and
`WakeupList.invalidateAll()`/`unregisterFromCondition()` (confirmed by
reading `src/dcps/waitset.zig` directly, not assumed from the roadmap
summary) drop it from every attached `WaitSet` cleanly — no dangling
pointer, regardless of destruction order. But that machinery is purely
internal Zig-side bookkeeping with **no C-ABI-visible signal at all** —
confirmed by reading the same file — so an application (via any binding)
that relied on `attach_condition()` implicitly keeping a reference alive
gets no error, no exception, nothing: `probe4 --vanish` confirms the
condition simply stops appearing in `get_conditions()` the instant a
GC-triggered `__del__` destroys it, with the `WaitSet` itself completely
unaware anything unusual happened. `probe4 --crash` shows the sharper edge
of the same root cause: if anything *else* also captured the raw handle
before the wrapper was collected (plausible — cached elsewhere, logged,
handed to a second API) and tries to use it after the premature destroy,
that's a genuine use-after-free — confirmed via a clean, symbolized Zig
panic (not just a bare segfault): `DDS_GuardCondition_set_trigger_value` →
`zidl_rt.unboxAs` reads a freed handle's now-garbage vtable pointer
(`panic: incorrect alignment`), pinpointing the exact mechanism.

This differs from finding 3 in an important way: it is **not** a hazard
`release_listener_data`-style plumbing would fix, because there's nothing
analogous to fix it *with* today — no native signal fires when a condition
gets silently detached this way, for any binding, in any language, not just
Python. The real lever is a binding-side design choice: does a condition
wrapper's `__del__`/finalizer auto-destroy the native object at all? For
`ReadCondition`/`QueryCondition`/`StatusCondition`, a binding can sidestep
the whole issue by *never* auto-destroying on wrapper GC — their real DDS
owner (the reader/entity) reclaims them eventually regardless, so the
wrapper's Python-level lifetime doesn't need to be tied to the native
object's at all. `GuardCondition` is the one type this doesn't work for: it
has no fallback owner, so a binding is forced to choose between
premature-destruction risk (auto-destroy on GC, as tested here) and a
permanent per-participant-lifetime leak risk (never auto-destroy, and the
application forgets to call an explicit destroy). The standard mitigation
for the first option is the same acquire/release keepalive shape as finding
3 — but self-imposed and self-triggered (on the binding's own
`attach_condition`/`detach_condition` call sites, which it always initiates
itself), not hung off any zzdds-provided hook, because no equivalent to
`release_listener_data` exists for conditions.

**5. `ctx_deinit` behaves exactly like `release_listener_data` — confirmed,
not just assumed by analogy.** `probe5 --typesupport-ctx`: registering a
second `TypeSupport` under the same `type_name` correctly supersedes the
first and fires its `ctx_deinit` exactly once — not early (checked
immediately after the first registration, before it fires), not late
(checked before the second registration's own call returns), and not on
the wrong object (`ctx_deinit`'s callback dereferences `ctx` and confirms
the magic value matches, surviving real GC+heap-churn pressure applied
between the two registrations). Confirms the `zzdds_register_type_support_ctx`/
`ctx_deinit` pattern — noted as structurally identical to listeners'
acquire/release shape back when this was reasoned about, not tested — holds
up under the same adversarial pressure finding 3 used to break the naive
listener case.

**6. `WaitSet` survives being destroyed while another thread is actively
blocked inside `wait()` on it — the scarier variant of finding 4, tested
directly rather than left as a hypothesis.** `probe5 --waitset`: a
background thread enters `DDS_WaitSet_wait()` with a real 10s timeout and
no conditions attached; ~0.5s in, the main thread drops the only Python
reference to a GC-triggered-destroy wrapper around that same `WaitSet` and
forces `gc.collect()`, synchronously running `zzdds_destroy_waitset()`
*while the background thread is still inside the blocking call*. Result:
no crash, no hang forever — the background thread's call simply rides out
its own 10-second timeout and returns `DDS_RETCODE_TIMEOUT` (10) cleanly,
exactly as if nothing unusual had happened. Genuinely reassuring, and
recorded with the same care given to every "did not crash" result in this
project: this confirms one specific interleaving (destroy ~0.5s into a 10s
wait, one destroying thread, one waiting thread) behaves safely, not that
every possible interleaving does — no TSAN run, no stress-loop across many
random timings, no concurrent attach/detach mixed in with the destroy. A
positive data point for the review, not an exhaustive proof.

## Design refinements from follow-up questions

Two points worth recording precisely, since they change how finding 3's
fix should actually be built, confirmed by reading the relevant code rather
than assumed:

- **The keepalive registry for finding 3 must be keyed per-registration,
  not per-listener-identity.** A naive `dict` keyed by
  `id(python_listener_object)` breaks the ordinary case of one listener
  object registered on multiple `DataReader`s: releasing the *first*
  reader's registration (its `release_listener_data` firing) would pop the
  *only* registry entry, dropping the keepalive for a listener the
  *second* reader still needs — a self-inflicted version of finding 3's own
  bug. Fix: generate a fresh trampoline set and a fresh registry slot per
  `create_datareader`/`set_listener` call, even when the same Python object
  is passed twice; ordinary Python refcounting then handles "the same
  underlying object needed by two independent slots" for free. This isn't
  just a defensive choice — it matches zzdds's own contract: confirmed in
  `src/dcps/writer.zig`, every entity's listener is copied **by value**
  into its own `listener_ex_box`, with no notion of shared listener
  identity across entities at the C-ABI level either.
- **`zzdds::DataWriterListenerEx` extending `DDS::DataWriterListener` does
  not introduce a second "per-view" keepalive to track.** Traced in
  `writer.zig`: there is exactly one storage slot per writer
  (`listener_ex_box`), always holding the *wider* `Ex` shape internally.
  Setting the base listener via `set_listener` widens it
  (`listenerExFromBase`) into the same slot rather than creating a second
  one; `get_listener()` narrows back down for reads. Widening/narrowing are
  pure struct-reshapes of pointer values the caller already supplied — not
  a second box, not a second release hook. So there's exactly one acquire
  and one `release_listener_data` firing per registration regardless of
  which interface width the app used — the earlier "one C-ABI box per
  interface view" pattern (`CachedCAbiHandle`/`_getOrCreate`) doesn't apply
  here at all: that machinery is for **outbound** entity handles zzdds
  hands back to the app; listeners are the opposite direction (the app
  hands function pointers to zzdds), never boxed or cached by identity in
  the first place.

## Implication for the review

This isn't a zzdds or zidl bug today — no current binding (C, C++, Java) has
this shape of hazard, because none of them hand zzdds a native function
pointer whose backing memory is owned by a separate, independently-GC'd
runtime the way a ctypes trampoline is. It's a **binding-author
responsibility that has no guardrail**, and it's easy to get wrong exactly
the way `probe3 --unsafe` does — a Python binding that reference-counts
listener wrapper objects "normally" (drop the last ref, let `__del__`/GC
reclaim it) needs to specifically know to keep the raw `CFUNCTYPE` object
alive independent of whatever wrapper object the application holds, until
`release_listener_data` fires. Worth the review deciding whether this stays
a documented binding-author contract (the C-ABI already exposes the release
hook — the gap is purely "nothing forces a binding to honor it") or whether
it's worth zidl generating a small keep-alive registry for exactly this
pattern (conceptually the same shape as the `cgo.Handle`-style table this
spike used informally for `ctx`, just applied to callback objects instead
of arbitrary data) so a future Python (and, by the same argument, C#/Go)
backend doesn't have to reimplement this correctly by hand every time. Keep
the registry keyed per-registration, not per-listener-identity (see "Design
refinements" above) — whichever shape the review lands on.

Finding 4 is a narrower, separate ask: since there's no `release_listener_data`
equivalent for conditions today, a future binding's `WaitSet`/`GuardCondition`
wrapper layer has to implement its own acquire-on-attach/release-on-detach
bookkeeping unassisted, self-triggered off its own `attach_condition`/
`detach_condition` call sites — not something zidl can generate a shared hook
for the way it can for listeners, unless a future round adds one.

## Non-findings / not attempted

- Zero-copy/borrowed-data across the C-ABI (the Rust `zig-ffi` question) —
  out of scope for this spike; nothing here touches it.
- Real heartbeat-thread respawn via actual matched pub/sub (probe 2
  approximates the same OS-thread-churn shape via repeated participant
  create/destroy instead — see that script's docstring for why, and what a
  literal version would additionally need).
- Async-runtime-friendly event delivery (asyncio-idiomatic queuing instead
  of synchronous upcall) — not exercised; all five probes use plain
  synchronous listener callbacks.
- Exhaustive `WaitSet`-destroy-while-waiting interleaving stress (many
  random timings, TSAN, concurrent attach/detach mixed in) — finding 6
  confirms one specific interleaving is safe, not every possible one.
- `ReadCondition`/`QueryCondition`/`StatusCondition` ownership specifically
  — probe 4 only exercises `GuardCondition`, the sharpest case (no fallback
  owner at all). The claim that a binding can sidestep the issue for the
  other three by never auto-destroying on wrapper GC is reasoned from their
  spec ownership model and zzdds's lifecycle fix, not independently probed.
