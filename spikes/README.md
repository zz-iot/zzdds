# spikes

Throwaway investigative probes against zzdds's C-ABI, written to answer
specific open questions *before* committing to a design or a new language
binding — not supported bindings, not something to build a real application
against, and not maintained the way `c/`, `cpp/`, and `java/` (this repo's
actual, user-facing examples) are.

Each subdirectory is a self-contained probe for one language: `python/`,
`go/`, `haskell/`, `rust/`. None of these are official zzdds bindings —
zzdds ships C, C++, and Java bindings today; a directory existing here is
not a signal that a Python/Go/Haskell/Rust binding exists or is imminent.

## Why they're kept

These aren't dead code. Several real, load-bearing engineering decisions
trace directly back to a specific probe in this directory — the C-ABI
cross-view identity bug that drove zidl's whole "Binding design review"
(see `zidl/docs/roadmap.md`) was first caught here, and this session reused
the Rust spike directly to verify a retcode-convention fix rather than
trusting the original finding from memory. Findings are written up in each
spike's own `README.md`, and the decisions they fed are recorded in
`zidl/docs/roadmap.md` and `zzdds/docs/roadmap.md` — search those for
`spikes/python`, `spikes/go`, `spikes/haskell`, `spikes/rust`, or a probe's
own flag names (e.g. `--vanish`/`--crash`) to find the specific decision a
given finding informed.

Kept as real, re-runnable code (not just prose) specifically because
C-ABI-level assumptions like these have already gone stale silently once
this session — worth being able to check again against a newer zzdds, not
just trust a written conclusion indefinitely.

## Layout

- `python/` — `ctypes`-based probes: GIL handling for a zzdds-internal
  callback thread, and the `ctx`-carrying-a-pointer pattern's Python
  lifetime shape.
- `go/` — `cgo`-based probes covering the same two questions, deliberately
  re-tested (not assumed) against Go's non-refcounted, moving-adjacent heap.
- `haskell/` — hand-declared `foreign import ccall` probes: GHC RTS thread
  registration for a zzdds-internal callback thread, and `StablePtr`-based
  ctx lifetime.
- `rust/` — does zzdds's existing `take_loaned`/`return_loan` loan contract
  map onto a real borrow-checker-enforced Rust lifetime.

See each subdirectory's own `README.md` for its exact questions, findings,
and how to build/run it.
