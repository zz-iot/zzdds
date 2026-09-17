# raw-loan example — what it demonstrates

A pub/sub example built around the raw/loaned `DataWriter`/`DataReader`
operations added in the 2026-08-22 redesign
(`docs/design/raw-loan-api.md`) — `loan_raw`/`publish_loan_raw`/
`return_loan_raw` on the write side, `take_raw` in loan mode (`cdr_payloads`
`_maximum == 0` on entry) plus `return_loan_raw` on the read side. Per
`docs/design/dcps-api-coverage-audit.md`, this had **zero** exercise in any
`examples/` port, in any binding, as of 2026-09-17 (internal
unit/smoke-test coverage existed —
`test/dcps/writer_vtable_test.zig`/`reader_vtable_test.zig`,
`test/bindings/smoke/JavaSmoke.java`, `examples/spikes/rust` — but nothing
in `examples/` itself, and C/C++ had zero exercise even at that lower
level).

Where `hello_world` is reliability-focused and `presence` is about an
entity-status transition, this example is about a data-path *mechanism*:
bypassing `TypeSupport` marshaling entirely and hand-serializing directly
into/out of a borrowed buffer — the shape the ROS2 RMW integration
motivating this redesign actually wants (`docs/design/raw-loan-api.md`'s
"Motivation" section).

## The type

```idl
@appendable
struct LoanedPing {
    int32 seq_num;
};
```

Topic name `LoanedPing`. Deliberately keyless and minimal, like
`hello_world`/`presence` — the payload is incidental to what's being
demonstrated. Keyless is also a deliberate scope decision, not an
oversight: the raw ops require the *caller* to supply `key_hash` directly
(no `TypeSupport` in the loop to compute it automatically), and how a
caller without `TypeSupport` should compute a correct key hash for a real
keyed type is a separate, meatier question — see "Deliberately out of
scope" below.

## QoS

`RELIABLE` + `KEEP_ALL` on both sides. Unlike `presence` (where only the
*latest* value matters), this example hard-asserts exact content and
ordering end-to-end through the loan path, so nothing can be allowed to
silently drop.

## Publisher flow

1. Create participant → register `LoanedPing`'s `TypeSupport` → topic →
   publisher → `DataWriter` (RELIABLE + KEEP_ALL). `TypeSupport`
   registration is still required here even though the raw ops bypass it
   for marshaling — `create_topic` needs a registered type name regardless
   of how samples on that topic end up serialized.
2. Wait for `on_reliable_reader_ready` (same zzdds extension `hello_world`/
   `presence` use) before writing anything.
3. **Write-loan phase**: publish 5 pings (`seq_num` 0..4) via
   `loan_raw(size)` → populate the borrowed buffer → `publish_loan_raw`,
   never through the typed `write()` wrapper.
4. **Cancel phase**: loan one more buffer, serialize a sentinel value
   (`seq_num = -1`), then deliberately call `return_loan_raw` instead of
   publishing — proves the cancel path genuinely prevents the sample from
   reaching the wire. The subscriber must never see `-1`.
5. Wait for the subscriber's matched-reader count to drop back to zero
   (same shutdown-gating idiom as `hello_world`/`presence`).
6. Explicitly assert `delete_datawriter` returns `RETCODE_OK` before
   teardown — every loan above was either published or cancelled, so an
   outstanding-loan `PRECONDITION_NOT_MET` here would mean a real leak in
   this example's own bookkeeping (or a real zzdds bug), not something to
   silently swallow into `delete_participant`'s cascade.

Required stdout markers: `Create topic:`, `Create writer for topic:`,
`Publisher: published (loan) sequence=`, `Publisher: cancelling loan for
sequence=`, `Publisher: done.`

## Subscriber flow

1. Create participant → `TypeSupport` → topic → subscriber → `DataReader`
   (RELIABLE + KEEP_ALL) with a listener on `on_data_available`.
2. `on_data_available`: loop calling `take_raw` with `cdr_payloads`
   zero-initialized (loan mode) and `max_samples = 1`, until it returns zero
   samples. For each: deserialize directly out of the borrowed bytes (no
   copy on the read side — `zidl_rt.CdrReader.init` just takes a `[]const
   u8` view), assert `seq_num` matches the next expected value in strict
   order, then `return_loan_raw` immediately.
3. The strict-ordering check doubles as the cancel-path assertion: if the
   cancelled `-1` ever leaked through, it would fail the ordering check
   immediately (it can never equal the next expected value in 0..4) — no
   separate "and also assert -1 never arrives" check needed.
4. Exit once all 5 expected samples have arrived in order — the one thing
   this example asserts programmatically, matching `hello_world`'s
   known-count pattern rather than `presence`'s status-transition pattern
   (this example is data/reliability-focused, not status-focused).

Required stdout markers: `Create topic:`, `Create reader for topic:`,
`Subscriber: received (loan) sequence=`, `Subscriber: received all 5
samples in order.`

## A real gap found building the Zig port

`zidl-rt`'s `CdrWriter` (`zidl/packages/zidl-rt/src/cdr.zig`) is always
`std.ArrayList(u8)`-backed (dynamic growth) — there is no fixed-capacity /
counting-mode writer the way C's `zidl_cdr.c` has
(`zidl_cdr_writer_init_fixed`/`zidl_cdr_writer_init_counting`, built
specifically for this loan use case per `docs/design/raw-loan-api.md`'s
"Sizing" section). That means the Zig publisher genuinely cannot serialize
*directly* into the buffer `loan_raw` hands back the way a C caller can:
it serializes into a normal dynamic buffer first (to learn the real size),
then `loan_raw(size)`, then `@memcpy`s the already-serialized bytes into
the loaned buffer, then `publish_loan_raw`. The example still exercises
the real `loan_raw`/`publish_loan_raw` ops correctly and the narrative
still holds, but it's not a true zero-copy write path in Zig today the way
the API is designed to support — a real, previously-undocumented gap in
`zidl-rt`, not a workaround invented for this example. Worth its own
follow-up (a fixed/counting `CdrWriter` mode in `zidl-rt`, mirroring the C
backend) if a genuinely zero-copy Zig write-loan ever matters; not fixed
here, out of scope for "build the example."

The read side has no equivalent gap — `CdrReader.init` takes a `[]const
u8` view of whatever `take_raw` returns, loaned or not, so deserializing
directly out of the borrowed bytes was already a real zero-copy read from
the start.

## Status per binding

- **zig**: done, verified cross-process (`zig build`, then publisher +
  subscriber over real UDP on a shared domain) — both exit 0, all 5
  samples received in order, cancelled sample never arrives. See "A real
  gap found" above for the one caveat.
- **c**: done, verified cross-process, both directions of zig↔c interop
  also verified. True zero-copy write-loan (`zidl_cdr_writer_init_counting`
  then `_init_fixed` straight into the loaned buffer) — no gap here, unlike
  Zig.
- **cpp**: **fixed and verified.** See "A real bug found building the C++
  port" below for the root cause and the fix. Verified: real cross-process
  run (both exit 0, all 5 samples in order, cancelled sample never
  arrives, true zero-copy write-loan via `zidl_cdr_writer_init_counting`/
  `_init_fixed`, `delete_datawriter`/`delete_datareader` both return
  `RETCODE_OK`), zig↔cpp and c↔cpp interop both directions, zidl's own
  test suite (`zig build test` in `zidl`), and two pre-existing C++
  examples (`presence`, `waitset` — the latter exercises
  `ReadCondition`/`QueryCondition` heavily, good regression coverage for
  the shared adaptation logic this fix refactored) rebuilt against the
  fixed backend and re-run clean.
- **java**: **fixed and verified.** The write-loan path (`loan_raw`/
  `publish_loan_raw`/`return_loan_raw` on `DataWriter`) already worked —
  `docs/design/raw-loan-api.md`'s "Java-specific implementation note"
  documents zidl finding and fixing that exact identity-loss failure class
  before this session. But investigating it surfaced a **second, wider bug
  on the read side**: see "A real bug found building the Java port" below —
  fixed the same day, same session, same failure class. Verified: real
  cross-process run (both exit 0, all 5 samples in order, cancelled sample
  never arrives, `delete_datawriter`/`delete_datareader` both return
  `RETCODE_OK`), java↔zig interop both directions, `zig build test` in
  zidl (full suite, after updating two regression tests that asserted the
  old, buggy generated shape), and the pre-existing `presence` Java example
  rebuilt against the fixed backend and re-run clean. Like Zig (and unlike
  C), the write side isn't true zero-copy — no CDR counting-mode writer in
  this backend either, same documented gap, same reason.
- **All four bindings now have a working, cross-verified raw-loan example**
  (zig↔c, zig↔cpp, c↔cpp, java↔zig all spot-checked both directions).
- Cross-binding interop smoke test (`interop/raw_loan_cross_binding_smoke_test.py`):
  not yet built as a formal script — every pair has been spot-checked ad
  hoc above, but there's no permanent, repeatable harness yet (the pattern
  `presence_cross_binding_smoke_test.py` established: build all 4 ports,
  run a representative subset of same/cross-binding pairs, assert on real
  completion markers).

**zidl pin note:** the fix is verified against a local zidl checkout, not
yet a tagged release. `zzdds/build.zig.zon`'s `.zidl` dependency is
currently pointed at `.path = "../zidl"` (a local, uncommitted edit) for
this verification — reverting to a real tagged/hashed pin (and un-reverting
zig-out to match) needs a real zidl release first, same as every other
zidl-pin-bump entry in `zzdds/CHANGELOG.md`.

## A real bug found building the C++ port

**`::DDS::DataWriter::loan_raw`/`publish_loan_raw`/`return_loan_raw` and
`::DDS::DataReader::take_raw`+`return_loan_raw` are broken for every C++
caller today** — confirmed by both reading the generated bridge
(`zig-out/src/dcps_impl.cpp`) and a real run: `raw_loan_pub` fails
deterministically on its first `publish_loan_raw` call with
`RETCODE_BAD_PARAMETER` (`FAIL: publish_loaned() failed at sequence=0`,
2026-09-17).

**Root cause.** `::DDS::OctetSeq` is `std::vector<uint8_t>` in the C++
backend. The generated bridge for `loan_raw` calls the real C-ABI
`DDS_DataWriter_loan_raw`, gets back a real loaned `DDS_OctetSeq` (a
pointer + length keyed into the writer's outstanding-loan table by pointer
identity — see `docs/design/raw-loan-api.md`'s "Owner handles" section),
**copies its bytes into the `std::vector` output parameter, then discards
the original C-level struct** (`DDS_OctetSeq_free`, a no-op here since
`vtLoanRaw` deliberately sets `_release = false` on a loan — see
`src/dcps/writer.zig:1159` — so this doesn't crash, it just silently drops
the only reference to the real loaned pointer). The `std::vector` the app
receives and populates has **no relationship** to the original loaned
buffer at all. When the app then calls `publish_loan_raw(cdr_payload, ...)`,
the bridge constructs a **fresh, empty** `DDS_OctetSeq{}` — never populated
from the `cdr_payload` vector parameter — and passes that to
`DDS_DataWriter_publish_loan_raw`, which immediately rejects it
(`vtPublishLoanRaw`'s `seq._buffer orelse return DDS.RETCODE_BAD_PARAMETER`,
`src/dcps/writer.zig:1186`). `return_loan_raw` has the identical flaw.
Beyond just failing every call, this also permanently leaks the writer's
quiesce refs and outstanding-loan accounting that `loan_raw` acquired
(`vtLoanRaw`'s `self.acquireQuiesce()`/`proto_writer.quiesceAcquire()`
only ever get released inside `vtPublishLoanRaw`/`vtReturnLoanRaw`, which
this bridge can never actually reach with a valid buffer) — so even
catching the `RETCODE_BAD_PARAMETER` and retrying leaves the writer
permanently stuck, eventually blocking `delete_datawriter` with
`PRECONDITION_NOT_MET` forever.

The read side (`DataReaderImpl::take_raw`) has the mirror-image bug: the
*first* `take_raw` call itself still succeeds and returns real, correct
data (the vector-copy happens after a successful loan, so the app does get
real bytes) — but `return_loan_raw` afterward hits the identical
empty-struct problem, so the reader's per-sample loan pin/refcount is
never released either, a slow-motion version of the same permanent-leak
failure mode (eventually `RETCODE_OUT_OF_RESOURCES` / stuck
`delete_datareader`, not an immediate visible error like the write side).

**This is the same failure class Java already found and fixed** for its
own write-loan path (`docs/design/raw-loan-api.md`'s "Java-specific
implementation note": "a first attempt at generating `loan_raw`/
`publish_loan_raw` through the *generic* per-op JNI path... silently lost
the loaned buffer's identity" — Java's fix was a hand-written codegen
special case, `isWriteLoanBufferOp` in `java.zig`, using a
`java.nio.ByteBuffer` instead of the generic `List<Byte>` specifically to
preserve pointer identity across the call pair). C++'s backend never got
an equivalent special case — and, notably,
`PresenceBeaconDataReader::Loan` (the *typed* generated read-loan
convenience wrapper, `--generate-zzdds-wrappers`) already keeps the raw
`DDS_OctetSeqSeq`/`DDS_SampleInfoSeq` C structs directly rather than
copying through `std::vector`, so it does **not** have this bug — only
the untyped `::DDS::DataWriter`/`::DDS::DataReader` interface-level raw
ops (`--generate-interfaces`) do.

**Fixed (2026-09-17), in `zidl`, not worked around here.** A new
`isRawLoanOp` special case (`src/backend/cpp.zig`, mirroring Java's
`isWriteLoanBufferOp`) covers all 8 affected ops (`DataWriter::loan_raw`/
`publish_loan_raw`/`return_loan_raw`; `DataReader::take_raw`/`read_raw`/
`take_next_instance_raw`/`read_next_instance_raw`/`return_loan_raw`).
For these ops' identity-bearing `inout` params only (`cdr_payload(s)`,
`key_hashes`, `sample_infos`), the generated C++ signature now uses the
raw C ABI struct type (`DDS_OctetSeq&`/`DDS_OctetSeqSeq&`/
`DDS_SampleInfoSeq&`) directly instead of the `std::vector`-based
`::DDS::OctetSeq&` etc. — exactly the shape
`PresenceBeaconDataReader::Loan` already used successfully. No copy, no
lost identity: the app's reference to the loaned buffer *is* the C ABI
call's own struct, passed straight through. Every other param on these
ops (size, key_hash as an `in` value, handle, kind,
instance_handle/previous_handle, a_condition, the state masks,
max_samples) is untouched, reusing the exact same adaptation logic every
other op already gets (the `a_condition`/`ReadCondition` dynamic_cast
adaptation was extracted into a shared `emitEntityInParamAdapt` helper so
the new special-cased emitters could reuse it rather than re-deriving it
by hand). Three generator sites needed the fix, all in `src/backend/cpp.zig`:
the interface declaration (`emitInterface`/new `emitRawLoanInterfaceOp`),
the impl class's header declaration (`emitEntityImplDecl`/new
`emitRawLoanImplDecl` — missed on a first pass, caught by a real "invalid
new-expression of abstract class type" build failure since the override
no longer matched the now-differently-typed pure virtual), and the impl
body (`emitEntityImplMethods`/new `emitRawLoanImplOp`). zzdds's own
hand-written `include/zzdds_cpp.hpp` (`DataWriterSupport`/
`DataReaderSupport`, which forward to the generated impl) needed a
matching signature update, not a zidl change.

## A real bug found building the Java port

**`DataReader.take()`/`read()`/`take_n()`/`take_instance()`/
`take_w_condition()`/etc. — the generated *typed* reader wrapper every
existing Java example already uses — call `take_raw`/`read_raw` in loan
mode but never called `return_loan_raw`.** Found while checking how the
Java write-loan path works (confirming it before designing this example's
publisher), by reading the generated `FooDataReader.java`: every one of
these 12 methods builds empty `List`s (the loan-mode signal), calls the
raw op, reads the sample out, and returns — the lists just go out of
scope. This isn't specific to a not-yet-built example; it's in code every
Java example in this repo already ships, and it's a bigger, more
far-reaching finding than the C++ bug above (which blocked one
not-yet-built example) precisely because it was already silently present
everywhere.

**Why it hadn't been visibly broken.** The leak (the reader's quiesce refs
and per-loan outstanding-loan bookkeeping never resolve) has no immediate
symptom in a short example run — the process exits before it matters, and
nothing checks `delete_datareader`'s return code strictly enough to catch
an eventual `PRECONDITION_NOT_MET`.

**Why the obvious fix (just add the missing call) is unsafe, not just
incomplete.** `return_loan_raw`'s generic JNI bridge reconstructs a
*fresh* native `DDS_OctetSeqSeq`/`DDS_OctetSeq`/`DDS_SampleInfoSeq` from
the Java `List`s' *current* (post-take, copied) contents via
`DDS_OctetSeqSeq_from_java` — which `malloc()`s new memory, not the same
pointer `take_raw` produced. Calling the real `return_loan_raw` with that
reconstructed struct doesn't find a match in the reader's `loan_table`
(pointer-keyed), so it falls into the "not found" branch and calls
zzdds's own **Zig allocator's `free()`** on memory `malloc()` allocated —
a cross-allocator free, undefined behavior, not just a leak. (Confirmed
by tracing `src/dcps/reader.zig`'s `vtReturnLoanRaw` and the JNI glue's
`_from_java`/`malloc` codegen — not empirically crashed, since the unsafe
version was never actually shipped; caught and redesigned before landing.)

**The real fix, mirroring the C++ fix's shape but adapted to JNI's
constraints.** A new `isReadLoanBufferOp` special case (`src/backend/
java.zig`, alongside the pre-existing `isWriteLoanBufferOp` this whole
investigation started from) covers `DataReader::take_raw`/`read_raw`/
`take_next_instance_raw`/`read_next_instance_raw`/`return_loan_raw`.
Content params (`cdr_payloads`/`key_hashes`/`sample_infos`) keep their
existing `List`-based Java types and `_fill_java` population, completely
unchanged — reading a sample's bytes was never the bug. A new trailing
`java.nio.ByteBuffer[3] loanHandles` out-parameter carries the three real
native pointers as opaque direct `ByteBuffer`s (`NewDirectByteBuffer`/
`GetDirectBufferAddress`, the exact mechanism already proven correct for
the single-buffer write-loan case) — the caller passes the same array
back to `return_loan_raw` unchanged, and its JNI bridge reconstructs the
exact original three C structs (same pointer, same `_maximum` recovered
from `GetDirectBufferCapacity`) and calls the real C ABI function
directly, no Java round-trip for the structs themselves. One batch call's
whole `cdr_payloads` array shares one `loan_table` entry regardless of
sample count, so `loanHandles` doesn't need to be per-sample.

Four generator sites needed the fix (interface declaration, impl
forwarding method, native declaration, JNI bridge), plus the typed
wrapper generator (`emitZzddsDataReaderFile`) itself needed updating to
actually call `return_loan_raw(_loan)` in all 12 read methods — the
original bug's actual location. One more wrinkle, also caught by a real
build failure rather than assumed: the JNI bridge's `a_condition`
unboxing can't hardcode `zidl_java_unbox_as_DDS_ReadCondition` (that
dispatcher has `static`/internal linkage, and is only emitted into a
generated file whose *own* entity graph derives from `DDS::ReadCondition`
— not necessarily true for a file that merely inherits the op, e.g.
zzdds's own extension module). Fixed by calling the existing
`entityUnboxFnName` helper to resolve the correct name per generated
file, same as the generic path already does.

## Two findings from zidl PR #53's Greptile review, both fixed

Both real, both fixed before merge, neither changes this example's own
code (both were in the zidl backend generators, not the example ports).

**Exception safety in the generated typed reader.** The 12 methods
`emitZzddsDataReaderFile` generates (`take`/`read`/`take_n`/`take_instance`/
`take_w_condition`/etc. — the fix to the Java read-loan-leak bug described
above) originally converted the loaned payload into a `Sample`/`Sample[]`
*before* calling `return_loan_raw`. If that conversion throws — unsupported
CDR encapsulation, malformed/truncated buffer, invalid enum value, OOM —
`return_loan_raw` is skipped and the loan stays outstanding, same failure
mode as the original bug, just reachable through a different path (a
decode error instead of a missing call). This example's own hand-written
publisher/subscriber never hit it (control over the wire format means no
malformed input), but the generated *typed* wrapper has to be safe against
one regardless. Fixed by wrapping each method's conversion in
`try { return ...; } finally { reader.return_loan_raw(_loan); }` — the
loan is now released on every path, not just the success one.

**Interface identity was matched by bare name, not qualified name.**
`isRawLoanOp` (C++) and `isReadLoanBufferOp` (Java) originally checked only
the unqualified `"DataWriter"`/`"DataReader"` leaf name — so an unrelated
user interface named `DataWriter` in some other module would also match,
routing it through this DDS-specific codegen (hardcoded `DDS_*` C struct
types in the C++ case) even though it has nothing to do with `dcps.idl`.
Doesn't affect zzdds's own generation today (nothing in this project
declares a colliding name), but a real correctness hole for zidl as a
general-purpose tool. Fixed by checking the *declaring* interface's
qualified name (`"DDS::DataWriter"`/`"DDS::DataReader"` exactly) instead:
call sites iterating an interface's own operations pass that interface's
own `qualified_name` directly; call sites walking a possibly-derived
interface's full member list (e.g. `zzdds::DataWriter : DDS::DataWriter`,
which inherits these ops without redeclaring them) resolve the real
declaring interface first (C++: `OwnedOperation.owner`, already available;
Java: the pre-existing `findDeclaringInterface` helper).

## Deliberately out of scope

- **Keyed types / computing `key_hash` without `TypeSupport`** — a real,
  separate, meatier feature; only makes sense to tackle once the keyless
  path is proven across all 4 bindings.
- **Batch loan mode** (`max_samples > 1` in one `take_raw` call, returning
  multiple independently-located loaned buffers in one call) —
  `docs/design/raw-loan-api.md` calls this "the genuinely new piece" of
  the whole redesign; deserves its own follow-up rather than diluting this
  example. This example always requests `max_samples = 1`.
- `_w_timestamp` / condition-filtered (`a_condition`) / instance-filtered
  (`instance_handle`) raw op variants — plain masks only here.
- A C/C++ "escape attempt" negative test proving use-after-`return_loan_raw`
  is unsafe, mirroring `examples/spikes/rust/examples/escape_attempt.rs`'s
  compiler-enforced one — real value, but as a `test/` addition after this
  example lands across all 4 bindings, not part of it.
