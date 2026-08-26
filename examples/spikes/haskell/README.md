# spikes/haskell

Not a Haskell binding. zidl's own roadmap only ever covered Haskell's
CDR/type-mapping layer ("Haskell backend — future consideration, not
scheduled") — nothing about how Haskell would reach the DCPS core
(participant/topic/reader/writer/listener) at all. This spike exists to
answer that gap directly, before the binding design review, using the same
throwaway-probe economy as the Python/Go/Rust spikes: hand-declared FFI
(`foreign import ccall`) against zzdds's existing C-ABI, no `.cabal` file,
no external packages, only `base`.

Two GHC-specific questions, neither covered by any other spike:

1. Does a zzdds-internal thread the RTS has never seen correctly deliver a
   callback into Haskell via `foreign import ccall "wrapper"`, and is the
   **threaded RTS** (`-threaded`) actually a hard requirement, as GHC's own
   documentation and long-standing convention say — checked directly rather
   than assumed?
2. Is `Foreign.StablePtr` — GHC's purpose-built "keep this value's identity
   reachable against GC" primitive — actually sufficient as the `ctx`
   keep-alive mechanism, verified under the same adversarial GC-pressure
   technique every other spike used?

## Setup

```sh
cd zzdds && zig build -Dc-binding=true install
cd ../zzdds-examples/spikes/haskell
gcc -shared -fPIC -I../../../zzdds/zig-out/include -o libspike_shim.so spike_shim.c

# Probe A: threaded RTS
ghc -threaded -O0 -o ProbeAttach_threaded ProbeAttach.hs \
  -L../../../zzdds/zig-out/lib -L. -lzzdds -lspike_shim \
  -optl-Wl,-rpath,$(realpath ../../../zzdds/zig-out/lib) -optl-Wl,-rpath,$(realpath .)
./ProbeAttach_threaded

# Probe B: same source, non-threaded RTS -- see Findings before assuming
# this is expected to fail the way the threaded build succeeds
ghc -O0 -o ProbeAttach_unthreaded ProbeAttach.hs \
  -L../../../zzdds/zig-out/lib -L. -lzzdds -lspike_shim \
  -optl-Wl,-rpath,$(realpath ../../../zzdds/zig-out/lib) -optl-Wl,-rpath,$(realpath .)
./ProbeAttach_unthreaded

# Probe C: StablePtr keep-alive under GC pressure
ghc -threaded -O0 -o ProbeStablePtr ProbeStablePtr.hs \
  -L../../../zzdds/zig-out/lib -L. -lzzdds -lspike_shim \
  -optl-Wl,-rpath,$(realpath ../../../zzdds/zig-out/lib) -optl-Wl,-rpath,$(realpath .)
./ProbeStablePtr
```

## Findings

**1. A real, live FFI ABI bug found by actually running this, not by
reading the header — `bool`-returning C functions must be declared
`CBool`, not `CInt`.** The very first run failed at the earliest possible
point: `zzdds_create_factory()` returned a legitimate, non-null pointer
(confirmed by printing it), but `zzdds_factory_is_nil()` — declared
`Ptr () -> IO CInt` — read back `871572480` for what was actually a valid,
non-nil handle. Root cause: the C function's real return type is `bool` (1
byte, per the SysV ABI, value in the low byte of the return register), and
declaring it as `CInt` (4 bytes) reads the *entire* register, capturing
whatever garbage happens to sit in the upper 3 bytes along with the real
1-byte result. Fixed by declaring it `IO CBool` instead. Worth flagging for
the review independent of Haskell: this is a real, easy, silent way to get
any C-ABI binding wrong in *any* FFI language with byte-width-sensitive
marshaling, not a Haskell-specific gotcha — it happened to surface here
first only because GHC's FFI requires hand-matching each C return type to
an exact `Foreign.C.Types` alias, with no header to check against.

**2. Threaded RTS: works cleanly, exactly as documented — 39 callbacks
in 8s, correct, in order, every one on a distinct fresh `ThreadId`.** A
third distinct pattern across all three runtime spikes so far, worth
naming precisely: Python's `PyGILState_Ensure` created a fresh
`_DummyThread` *object* per call but reused the *same underlying OS
thread* identity throughout; Go's runtime created *one* goroutine and
reused it across every call from that same foreign OS thread; GHC's
threaded RTS creates a **new `ThreadId` on every single call**, even
though it's presumably still the same underlying OS thread each time
(zzdds's timer thread is a single persistent thread, not respawned per
tick) — three different runtimes, three different bookkeeping choices for
the exact same underlying situation.

**3. Surprising result, reported with an explicit caveat about what it
does and doesn't prove: the non-threaded RTS did NOT hang, crash, or
visibly corrupt state for this specific test.** `ProbeAttach_unthreaded`
(identical source, built without `-threaded`) produced the same clean
39-callback run as the threaded build. This is genuinely surprising against
GHC's own long-standing documentation and community convention, which say
the threaded RTS is required for a foreign OS thread to safely call into
Haskell — worth reporting honestly rather than either quietly matching
expectations or overclaiming safety from one clean run. **The important
limitation**: this test only ever has *one* recurring foreign OS thread
(zzdds's single per-participant timer thread) calling in, never two
*different* foreign threads entering Haskell concurrently. A real DDS
application has several independent internal threads that can each fire
listener callbacks — the timer thread, transport receive threads, the
per-writer heartbeat thread, the SPDP announce thread — and the specific,
well-documented danger of the non-threaded RTS is state corruption from
*concurrent* entry from multiple OS threads, which this probe never
actually constructed. A clean run here is evidence against a narrower claim
than "the threaded RTS doesn't matter" — it does not license dropping
`-threaded` as a requirement, and the review should treat that
requirement as still standing unless a genuinely concurrent multi-thread
version of this test is built and also passes repeatedly. Recorded as a
finding precisely *because* it complicates the simple story, not despite
that.

**4. `StablePtr` works exactly as expected — 14/14 checks correct under
aggressive GC+heap-churn pressure between every tick, no exceptions.**
Confirms `Foreign.StablePtr` is a sufficient, correct keep-alive mechanism
for `ctx`-style opaque data crossing into zzdds's C-ABI. Unlike Python and
Go, no adversarial "wrong way" contrast probe was built here — see
Non-findings for why.

## Implication for the review

None of the four findings is a blocker. Finding 1 is a real, generalizable
ABI-marshaling pitfall worth documenting for *any* future binding (not
Haskell-specific despite being found here first). Finding 4 confirms GHC
already has the right primitive for the `ctx`/keep-alive problem, same
conclusion as Go's `cgo.Handle` and Python's registry pattern, just with a
purpose-built language feature instead of a bolted-on library convention.
Findings 2 and 3 are the ones with real weight for a future Haskell
backend's design: `-threaded` should be documented as a hard, enforced
build requirement for any application using it (finding 2's clean behavior
depends on it being present; finding 3's clean behavior without it should
not be read as permission to make it optional) — this needs to live in
user-facing documentation, not just be assumed knowledge, since getting it
wrong wouldn't necessarily fail loudly for a simple application the way
`ProbeAttach_unthreaded` didn't fail here.

## Non-findings / not attempted

- **A genuinely concurrent, multi-foreign-thread version of finding 3.**
  The single most valuable follow-up this spike didn't do: drive two
  independent zzdds-internal threads (e.g., the DEADLINE timer thread
  *and* a second participant's transport receive thread delivering
  `on_data_available` from a real write) concurrently under the
  non-threaded RTS, to actually test the scenario GHC's documentation
  warns about rather than the narrower single-recurring-thread case this
  spike built.
- **`safe` vs `unsafe` foreign call classification.** Not demonstrated
  live — this spike's own C-ABI calls are all plain (`safe`-by-default)
  `foreign import ccall` declarations, and none of them block long enough
  to make the difference observable. The risk is real and well-documented
  (an `unsafe` call blocks the entire RTS capability for its duration,
  wrong for anything that might block or re-enter Haskell, like
  `WaitSet::wait()` with a real timeout) but wasn't verified against
  zzdds specifically here.
- **A deliberately "wrong" `ctx` contrast probe**, mirroring Python's
  `probe3 --unsafe` / Go's `--raw` mode. Not built: ordinary `Foreign.*`
  code has no direct equivalent of Go's `unsafe.Pointer(&x)` or a ctypes
  `py_object` escape — there's no built-in way to obtain a raw address into
  an arbitrary, still-live Haskell heap value without deliberately reaching
  for internals GHC doesn't expose through normal FFI code. That absence is
  itself worth recording as a point of relative confidence (the naive
  mistake isn't just discouraged in Haskell, it's considerably harder to
  even attempt by accident), but it's reasoned from the shape of the API
  surface, not independently constructed and confirmed the way Python's and
  Go's contrast probes were.
