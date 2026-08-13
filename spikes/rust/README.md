# spikes/rust

Not a Rust binding, not the `zig-ffi` backend. A throwaway probe answering
one specific question before the binding design review commits to
anything: does zzdds's existing `take_loaned`/`return_loan` C-ABI contract
(a pointer valid until an explicit release call) map cleanly onto a real,
borrow-checker-enforced Rust lifetime — the `zig-ffi` mode's whole value
proposition — or does it need `unsafe` escape hatches that quietly defeat
the point?

Deliberately tested against the **existing** loan API, which is a plain
heap allocation today, not real zero-copy/SHMEM (see
`zzdds/docs/roadmap.md`'s note on this, reachable via zidl's own roadmap
"Binding design review" section). That's not a limitation of this spike —
the lifetime/safety question is about the *contract shape*, which is
identical regardless of what backs the pointer. Real zero-copy is a
separate, larger zzdds-core question; this spike doesn't depend on it and
isn't blocked by it.

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
gcc -shared -fPIC -I../../../zzdds/zig-out/include -o libspike_shim.so spike_shim.c
cargo run                                  # real end-to-end loan, correct usage
cargo build --example escape_attempt       # MUST fail to compile -- see Findings
```

## What's here

- **`src/loan.rs`** — the thing under test: `LoanedSample<'a>`, a
  `MutexGuard`/`Ref`-shaped RAII guard around `zzdds_take_loaned_raw`/
  `zzdds_return_loaned_raw`. Two deliberate design choices, not incidental:
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

## Findings

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
zidl's `docs/roadmap.md` "Binding design review: decision". This spike's
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
  larger zzdds-core question (see zidl's roadmap "Binding design review"
  section) — this spike deliberately doesn't depend on it. The Rust-side
  design question this spike was built to answer is closed either way: the
  *contract* is soundly expressible in Rust today; *what backs the pointer*
  can change later without the Rust-side lifetime design needing to change
  with it.

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
- Allocator-injection interaction with Rust's own allocator story
  (`GlobalAlloc`, `no_std + alloc`) — not examined.
