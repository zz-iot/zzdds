# spikes/go

Not a Go binding. Same spirit and economy as `spikes/python`: throwaway
probes against zzdds's existing C-ABI (via `cgo`, `#include`-ing the real
`dcps.h`/`zzdds_c.h` directly rather than hand-declaring structs), answering
two Go-specific questions before the binding design review commits to
anything, rather than assuming the Python findings generalize.

Go was picked as the next spike (over C#) specifically because it has a
structural difference from every already-validated binding that matters:
CPython's heap is non-moving and refcounted (every finding in
`spikes/python` implicitly relies on object addresses staying stable for the
object's lifetime once referenced). Go's heap is not refcounted, and cgo's
pointer-passing rules exist because of it — worth checking directly rather
than assuming Go's version of "keep this alive" works the same way Python's
did.

## Setup

```sh
cd zzdds && zig build -Dc-binding=true install
cd ../zzdds-examples/spikes/go
go build -o /tmp/probe1_attach ./probe1_attach && /tmp/probe1_attach
go build -o /tmp/probe2_ctx_handle ./probe2_ctx_handle
SPIKE_MODE=handle /tmp/probe2_ctx_handle
SPIKE_MODE=raw    /tmp/probe2_ctx_handle   # expected to panic -- see Findings
```

Each probe's `#cgo CFLAGS`/`LDFLAGS` point at `../../../../zzdds/zig-out`
relative to its own source file (`${SRCDIR}`-based, no env vars needed) —
only requires `zig build -Dc-binding=true install` to have been run first.

## What each probe does

- **`probe1_attach`** — same cheapest-possible trigger as the Python
  spike's probe 1: a `DataReader` with a 1s DEADLINE period on a topic
  nobody writes to, waiting for zzdds's per-participant timer thread to
  fire `on_requested_deadline_missed` via a `//export`ed Go function,
  entirely unprompted. Prints the goroutine ID observed inside the
  callback each time, to get real evidence of whether — and how — Go's
  runtime handles a foreign OS thread calling into Go code.
- **`probe2_ctx_handle`** — the sharper one. Registers a `DataReaderListener`
  with `listener_data` (`ctx`) set two different ways: `--raw` (a bare
  `unsafe.Pointer` to a heap-allocated Go struct, no other Go reference kept
  after registration) vs. `--handle` (`runtime/cgo.Handle`, the standard
  safe pattern). Between every deadline tick, forces `runtime.GC()` +
  `debug.FreeOSMemory()` plus heap churn (repeatedly allocating similarly-sized
  garbage) to put real pressure on the allocator to reclaim and reuse
  whatever memory the `--raw` pointer refers to, rather than letting it
  coincidentally survive untouched — the same amplification idea as
  Python's `probe3 --unsafe`.

## Findings

**1. No attach step needed, confirmed rather than assumed — and Go's
runtime is more efficient about it than Python's.** `probe1_attach` fires
9 callbacks over 10s, every one on a foreign OS thread's goroutine
(`is_main_goroutine=false` every time), with zero explicit attach/detach
call anywhere in the code — cgo's `//export` mechanism really does just
work when a C thread it's never seen calls in. Worth noting a difference
from Python's own finding: Python's `PyGILState_Ensure` created a **new**
`_DummyThread` object on *every single call*, even from the exact same OS
thread repeatedly. Go instead created **one** goroutine for that foreign OS
thread and reused it across all 9 calls (same goroutine ID every time) —
cheaper, and arguably a cleaner mental model (the OS thread gets a stable
Go-side identity for as long as it keeps calling in, rather than a fresh
throwaway one per call).

**2. The sharper finding, and a pleasant surprise: Go's default `cgocheck`
already catches the naive mistake, loudly, before any corruption can
happen — stronger protection than ctypes gives Python for the equivalent
error.** `probe2 --handle` survives 11 consecutive GC+heap-churn cycles
with the object's contents intact every time, exactly as expected — the
real Go object stays referenced from `cgo.Handle`'s own internal table, a
real GC root, so it's never eligible for collection while the handle
exists. `probe2 --raw` does **not** produce the silent-corruption failure
mode this probe was actually built to look for. Instead, Go's runtime
panics immediately and deterministically (confirmed reproducible, 2/2 runs,
identical message both times) the moment the listener struct — which has
the raw Go pointer sitting in its `listener_data` field — is handed to
`DDS_Subscriber_create_datareader()`:

```
panic: runtime error: cgo argument has Go pointer to unpinned Go pointer
```

This is a real, useful correction to how strong `cgocheck` actually is: the
default (`cgocheck=1`, no opt-in needed) doesn't just check a call's
top-level pointer argument, it recursively scans the **fields of a struct**
being passed to a cgo call for embedded Go pointers, and refuses the call
outright if it finds one. Since zzdds's own C-ABI shape — a listener struct
with a `ctx`-carrying `listener_data` field, passed as a single argument to
`create_datareader`/`set_listener` — means the dangerous pointer and the
call that would leak it cross the boundary *together*, this specific
mistake gets caught for free by Go's own tooling, no zzdds/zidl-side
guardrail required. It's also a *recoverable* panic (an ordinary Go
`panic`/`recover` pair), not a process-ending crash the way Python's
segfault or the C/C++ crash-shaped bugs were — a real binding could wrap
its registration calls in a `recover()` and turn this into an ordinary Go
error instead of taking the whole program down.

Why `--handle` mode doesn't trip the same check, verified rather than
assumed: `cgo.Handle` is an integer under the hood, and the pointer is
converted to `uintptr` *before* being wrapped back in `unsafe.Pointer` —
`cgocheck`'s scanner only follows things it can still identify as Go
pointers at the point of the call, and a `uintptr` genuinely isn't one to
Go's type system anymore. This isn't just documented convention holding up
by luck; it's specifically why the pattern works, confirmed by seeing the
check fire for the raw case and stay silent for the handle case using the
exact same call site and the exact same underlying object.

## Implication for the review

Weaker of a gap than the Python listener finding, and in the *opposite*
direction: rather than "nothing currently protects against this," Go's own
tooling already provides a strong, load-bearing guardrail for the most
direct way to get this wrong (embedding a raw Go pointer directly in a
struct field passed to a cgo call). The residual risk is narrower than it
first looked — worth the review noting that `cgocheck`'s protection is a
boundary-crossing check, not an ongoing invariant: it can only catch a
violation at the moment a Go pointer crosses into a specific cgo call's
arguments, not "C copied this pointer somewhere else and used it later,
long after the check already passed" — a scenario this probe didn't
specifically construct (it wasn't necessary to, since the direct case
already failed as cleanly as it did) but which remains theoretically
possible via a path that doesn't put the raw pointer inside a single
struct argument at the point of the call. Recording as an open edge rather
than a confirmed gap, since deliberately constructing that scenario would
need reaching into a path cgocheck's scan doesn't cover, not just repeating
this probe's setup.

## Non-findings / not attempted

- Many-distinct-native-threads leak stress (Python's `probe2` equivalent) —
  not built. Lower priority here since `probe1` already showed Go reuses
  one goroutine per foreign OS thread rather than Python's per-call churn,
  which is the more leak-prone shape to begin with; revisit if the review
  wants this confirmed directly rather than reasoned from probe 1's result.
- `WaitSet`/`Condition` ownership (the Python `probe4` question) — not
  re-tested for Go. The finding there was about DDS spec ownership
  semantics and the absence of any C-ABI-level notification hook, both of
  which are language-independent facts already established; nothing about
  Go's runtime model would change either conclusion.
- Constructing a genuine "pointer copied elsewhere, used later" cgocheck
  bypass — see "Implication for the review" above.
