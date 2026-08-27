# spikes/rust

Not a Rust binding, not the `zig-ffi` backend. A throwaway probe answering
one specific question before the binding design review commits to
anything: does zzdds's loan C-ABI contract (a pointer valid until an
explicit release call) map cleanly onto a real, borrow-checker-enforced
Rust lifetime — the `zig-ffi` mode's whole value proposition — or does it
need `unsafe` escape hatches that quietly defeat the point?

**Migration note**: originally probed against the old hand-written
`zzdds_take_loaned_raw`/`zzdds_return_loaned_raw` C-ABI family
(`zzdds/src/c_abi/bootstrap.zig`). That family has since been deleted,
superseded by real `dcps.idl`-generated ops
(`DDS_DataReader_take_raw`/`DDS_DataReader_return_loan_raw`,
`DDS_DataWriter_write_raw`) generated uniformly across all four zidl
backends — see `zzdds/docs/design/raw-loan-api.md`. This spike (`src/ffi.rs`,
`src/loan.rs`, `src/main.rs`) has been migrated to the new ops; the "Findings"
section below is preserved as the historical record of what the original
probe found against the old API (finding 1's convention bug in particular —
the old function-local return-code convention no longer exists, since the
whole hand-written family it applied to is gone). One real shape change
from the migration: `take_raw` is batch-oriented at the C ABI
(`cdr_payloads`/`sample_infos` are always sequences, one
independently-located descriptor per sample, never a single-sample-shaped
op — see the design doc's zero-copy rationale) where the old
`zzdds_take_loaned_raw` returned exactly one sample directly. `LoanedSample`
now deals with a length-1 batch internally (`src/loan.rs`'s own doc comment
has the detail) — the lifetime-safety question this spike exists to answer
is unchanged, only the internal FFI shape got bigger.

Deliberately tested against the loan API's current heap-allocated
implementation, not real zero-copy/SHMEM (see `zzdds/docs/roadmap.md`'s note
on this, see `zidl/docs/design/binding-c-abi-identity.md`).
That's not a limitation of this spike — the lifetime/safety question is
about the *contract shape*, which is identical regardless of what backs the
pointer. Real zero-copy is a separate, larger zzdds-core question; this
spike doesn't depend on it and isn't blocked by it.

No `bindgen`, no external crates — `src/ffi.rs` hand-declares the small
slice of the C-ABI needed (`extern "C"` + `#[repr(C)]`), same spirit as the
Python spike's `ctypes` declarations and Go's manual struct field wiring.
Reuses `spike_shim.c` from `spikes/python` (copied in, not shared by path —
each spike directory is self-contained) for the two things Rust also has no
portable way to do without it: a QoS struct's real `sizeof()`, and setting
RELIABLE+KEEP_ALL on the writer QoS.

## Setup

```sh
cd zzdds && zig build -Dc-binding=true install
cd ../zzdds-examples/spikes/rust
gcc -shared -fPIC -I../../../zzdds/zig-out/include -o libspike_shim.so spike_shim.c static_pool_allocator.c
cargo run                                  # real end-to-end loan, correct usage
cargo build --example escape_attempt       # MUST fail to compile -- see Findings
cargo run --example allocator_spike        # allocator-injection probe, see "Allocator injection" below
```

## What's here

- **`src/loan.rs`** — the thing under test: `LoanedSample<'a>`, a
  `MutexGuard`/`Ref`-shaped RAII guard around `DDS_DataReader_take_raw`
  (loan mode)/`DDS_DataReader_return_loan_raw`. Two deliberate design
  choices, not incidental:
  `return_loan` happens in `Drop`, not a method the caller has to remember
  to call (stronger than C/C++/Java's manual contract — `Drop` still runs
  on an early return or unwind, where a forgotten call would leak); and
  `data()` returns `&'b [u8]` borrowed from `&'b self` — the **guard's own**
  borrow scope, not `&'a [u8]` tied to the outer `DataReader`. That second
  choice is the easy-to-get-wrong part and the actual point of this spike;
  see the module's own doc comment.
- **`src/main.rs`** — real end-to-end usage against the live C-ABI: creates
  a participant/topic/writer/reader in one process, writes one sample
  (a hand-built 12-byte CDR payload — 4-byte XCDR1-LE encapsulation header
  + an 8-byte magic value, no zidl codegen needed since nothing here
  filters or keys on the payload), takes a real loan, verifies the payload
  byte-for-byte, and lets the guard drop at the end of a block.
- **`examples/escape_attempt.rs`** — expected to **fail to compile**. Tries
  to smuggle a loaned sample's data slice past the point its guard is
  dropped. Never run; only ever built, and only ever expected to fail —
  see the file's own doc comment before assuming this is a mistake if
  revisited later.
- **`examples/allocator_spike.rs`** — the allocator-injection probe (added
  later, see "Allocator injection" below): creates a factory, `WaitSet`, and
  `GuardCondition` all under the same caller-supplied `ZidlAllocator`
  (`static_pool_allocator.c`, copied in from `zzdds-examples/c/custom-
  allocator/`, same self-contained-copy convention as `spike_shim.c`),
  attaches/triggers/waits for the condition, and confirms it fired.

## Findings

(Findings 1-2 below describe the original probe against the now-deleted
`zzdds_take_loaned_raw`/`zzdds_return_loaned_raw` hand-written family --
preserved as historical record per the migration note above. Finding 2's
core result -- the loan contract maps cleanly onto Rust's borrow checker --
was re-confirmed after the migration to the real generated `take_raw`/
`return_loan_raw` ops: `cargo run` and `cargo build --example
escape_attempt` both still behave exactly as described below.)

**1. Real, successful loan cycle works end-to-end against the live C-ABI,
first correction found by actually running it rather than reasoning about
the header alone: `zzdds_take_loaned_raw`'s return convention used to NOT be
the standard `DDS_ReturnCode_t` (0 = OK) — since fixed.** Confirmed by
reading `zzdds/src/c_abi/bootstrap.zig` directly after the first version of
this probe got it backwards (assumed 0 = success, silently treated every
real "no data yet" as success and every real success as an error): this
function's own convention used to be `1` = a sample was loaned, `0` = no
data available right now, negative = a real error — a different,
function-local convention undocumented in `zzdds_c.h`'s comment for this
specific function. Flagged for the C-ABI review as a real inconsistency
(every *other* zzdds function checked in this whole project used the
standard `DDS_ReturnCode_t` convention); the review agreed and normalized
`zzdds_take_loaned_raw` and its four siblings (`zzdds_take_one_raw`/
`_instance`, `zzdds_read_one_raw`/`_instance`) to the standard
`DDS_RETCODE_OK`/`DDS_RETCODE_NO_DATA`/`DDS_RETCODE_*` convention — see
zidl's `zidl/docs/design/binding-c-abi-identity.md`. This spike's
own code (`src/loan.rs`) has been updated to match.

**2. The core finding: the loan contract maps cleanly onto Rust's borrow
checker, and the escape hatch is rejected with a precise, on-point error —
confirmed by actually trying to break it, not just designing it to look
safe.** `cargo run`'s correct-usage path works cleanly: write, loan, read,
verify the payload, implicit `Drop`-triggered `return_loan` (printed, not
just assumed). `cargo build --example escape_attempt` — which tries to
assign `loaned.data()`'s result to a variable declared *outside* the
guard's own block, then use it after the block (and therefore `Drop`, and
therefore the real `zzdds_return_loaned_raw` call) has already run — fails
exactly as designed:

```
error[E0597]: `loaned` does not live long enough
   data_ref = loaned.data();
              ^^^^^^ borrowed value does not live long enough
   } // <- LoanedSample::drop runs here
   - `loaned` dropped here while still borrowed
   println!("{:?}", data_ref);
                     -------- borrow later used here
```

Not a generic "can't return a reference to a local" rejection (that would
prove less — most guard-style Rust APIs happen to compile-error against a
`'static` return trivially, whether or not the loan-specific lifetime
plumbing is actually correct). This is the borrow checker catching the
*exact* mistake that matters here: using the data after the point its
backing memory would actually be released, expressed at compile time with
zero runtime cost, zero `unsafe` in the caller-visible API surface, and — a
real improvement over the C/C++/Java contract — no reliance on the caller
remembering to call anything at all.

## Implication for the review

The `zig-ffi` backend's core value proposition — safe, zero-copy(-shaped)
borrowing tied to an explicit release call — is not a design risk against
zzdds's *existing* loan C-ABI shape; the guard pattern maps onto it
directly, with no C-ABI changes needed to make the safe version possible.
The two real open items are narrower than "will this work at all":

- **Convention inconsistency** (finding 1) — worth fixing or at least
  documenting explicitly in `zzdds_c.h`, independent of Rust: any binding
  hand-declaring this function's signature from the header alone, in any
  language, would make the same mistake this spike's first version did.
- **Whether real zero-copy ever lands underneath this** is a separate,
  larger zzdds-core question (see zidl/docs/design/binding-c-abi-identity.md section) — this spike deliberately doesn't depend on it. The Rust-side
  design question this spike was built to answer is closed either way: the
  *contract* is soundly expressible in Rust today; *what backs the pointer*
  can change later without the Rust-side lifetime design needing to change
  with it.

## Allocator injection

A second, independent probe (`examples/allocator_spike.rs`), added later —
does zzdds's `ZidlAllocator` C-ABI injection point (`allocator-strategy.md`,
`docs/design/generated-class-lifecycle-design.md`) work from Rust, and what's
the realistic ceiling for a real future Rust binding's create/destroy story,
given Rust's *current stable* allocator ecosystem? The question this spike
exists to answer, and the answer found:

**The question has two genuinely different halves, and they get different
answers.** "Can Rust *consume* a caller-supplied allocator across zzdds's
C-ABI" and "can Rust's own standard collections (`Box<T>`, `Vec<T>`) be
*generic* over that same allocator" sound like the same question but aren't
— zzdds's injection point is a `#[repr(C)]` vtable struct crossing an FFI
boundary; Rust's own per-object allocator support is a *language/stdlib*
generic-parameter feature. They have independent stability stories.

**1. Confirmed, real, end-to-end: Rust can consume `ZidlAllocator` today, on
stable, with zero unstable features.** `ffi::ZidlAllocator` is a plain
`#[repr(C)]` struct with `extern "C" fn` pointer fields — ordinary,
always-been-stable Rust, ABI-identical to the C struct in `zidl_allocator.h`.
`examples/allocator_spike.rs` reuses the existing `static_pool_allocator.c`
(copied into this directory, not reimplemented in Rust — the question here
is whether Rust can consume a `ZidlAllocator`, not whether it can author
one), passes `&static_pool_allocator` to `zzdds_create_factory_with_allocator`
/`zzdds_create_waitset_with_allocator`/`zzdds_create_guardcondition_with_allocator`,
attaches the `GuardCondition` to the `WaitSet`, triggers it, and confirms a
real `DDS_WaitSet_wait()` reports it fired — `cargo run --example
allocator_spike` passes cleanly (`PASS`). **Proven, not just "ran without
crashing"**: deliberately skipping `static_pool_allocator_reset()` (leaving
the pool's free list genuinely empty) makes the very same run fail for real
— `zzdds_create_factory_with_allocator: error.OutOfMemory`, factory returns
nil — confirming the allocator is actually being consulted by zzdds's core,
not silently bypassed to a process default. Reverting the skip restores the
clean pass. Since `WaitSet`/`GuardCondition` specifically exercise this
session's `get_allocator` vtable-accessor fix (`WaitSet::wait()`'s native
temporary buffer, freed via the *entity's own* allocator rather than a
process-wide guess), this run is also a second, independent, cross-language
confirmation that fix holds — already verified in C/C++ via the
`noalloc_guard` examples; this is the same claim from a third language.

**2. Confirmed via a direct compiler check, not assumed: Rust's own
*per-object* allocator generics (`Box<T, A>`/`Vec<T, A>`, `std::alloc::
Allocator`) remain nightly-only.** This environment has stable Rust 1.85.0
only (no `rustup`, no nightly toolchain available). A minimal snippet
(`use std::alloc::Allocator; struct MyBox<T, A: Allocator> { .. }`) fails
to compile on this stable toolchain with:
  ```
  error[E0658]: use of unstable library feature `allocator_api`
   --> use std::alloc::Allocator;
      = note: see issue #32838 <https://github.com/rust-lang/rust/issues/32838>
  ```
  Issue #32838 has been open since 2016 and is still unresolved as of this
  toolchain. For contrast, confirmed separately that Rust's *other*,
  *process-wide* allocator override — `#[global_allocator]`/`GlobalAlloc`
  (what the old "Non-findings" bullet below used to name) — compiles and
  runs fine on the same stable toolchain; it's simply a different mechanism
  (one allocator for the whole process's `Vec`/`Box`/`String` ecosystem, not
  a per-factory injection point), and not what zzdds's `ZidlAllocator`
  contract needs or provides.

**Bottom line, confirming the design doc's expected ceiling, not refuting
it**: a real future Rust binding's standalone-entity create/destroy story
(`WaitSet`/`GuardCondition`, and any future `@standalone`-annotated type)
has a clean, idiomatic shape available *today*, on stable: an explicit
`create_with_allocator(allocator: &ZidlAllocator) -> Self`-shaped
constructor (exactly what this spike calls), paired with ordinary `Drop` for
cleanup — the same "explicit factory function + caller-owned `Box`/`Drop`"
shape `allocator-strategy.md`/the design doc's Decisions log already
expected. What that ceiling rules out: Rust *binding-side* wrapper objects
(an RAII guard analogous to `LoanedSample<'a>` above, or a hypothetical
`WaitSet` wrapper struct) being *themselves* allocated through the injected
`ZidlAllocator` via `Box<T, A>`-style generics — those stay on Rust's
ordinary default allocator (or whatever `#[global_allocator]` is registered
process-wide) until `allocator_api` stabilizes, which is a real, current,
external constraint on the Rust ecosystem, not a zzdds/zidl design gap.

## Non-findings / not attempted

- The contrasting "wrong lifetime, compiles anyway" version (`data()`
  returning `&'a [u8]` tied to the reader instead of `&'b [u8]` tied to the
  guard) was not built as a second, parallel example — the escape-attempt
  result against the *correct* design was decisive enough on its own to
  not need the negative contrast case to make the point. Worth building if
  the review wants to see the wrong version fail at runtime the way C/C++
  would, for a side-by-side writeup.
- `pure` Rust mode (the non-`zig-ffi`, no-zzdds-dependency backend) is out
  of scope for this review entirely — it doesn't touch the C-ABI/interface
  questions this review is about.
- ~~Allocator-injection interaction with Rust's own allocator story
  (`GlobalAlloc`, `no_std + alloc`) — not examined.~~ **Examined — see
  "Allocator injection" above.** `GlobalAlloc`/`#[global_allocator]`
  specifically wasn't needed or used: this probe's whole point is
  *per-object* injection (a `ZidlAllocator*` passed to one factory), which
  is a different mechanism than Rust's process-wide global allocator
  override — see that section for why the two shouldn't be conflated.
