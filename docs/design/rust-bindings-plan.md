# Rust bindings after CDR consolidation

Date: 2026-11-12. Status: design proposal; implementation is not started.

## Starting point

Native CDR consolidation, `zidl-rt` retirement and shared Java runtime delivery
are complete. [PR #150](https://github.com/zz-iot/zzdds/pull/150) pins zidl
0.3.30 and delivers its Java JAR. The
[Release dry run](https://github.com/zz-iot/zzdds/actions/runs/43303145293)
passed all platform tests, self-interop and relocated bundle checks.

The earlier Rust pure/zig-ffi proposal is superseded. Recommend one first codec
path: generated owned Rust values with traversal over the shared `zidl-cdr`
C ABI. Keep the standalone codec independent of DDS. A separate pure Rust codec
needs an identified deployment requirement or measured benefit; it is not an
initial default. Crate names and supported Rust/toolchain versions are open.

## Evidence and its limits

The [existing spike](../../examples/spikes/rust/README.md) records a real raw
loan exchange, a compiler rejection when a borrowed payload escapes its guard,
and allocator injection through the C ABI. These are historical experimental
results, not a supported Rust binding or current-main validation. The spike's
hand-declared ABI and allocator/destruction behavior need fresh review.

In particular, a borrow tied to a loan guard proves only one lifetime relation.
It does not prove that another handle cannot delete the reader/participant,
that a callback cannot race deletion, or that thread access is safe. The spike
also folds native errors into `Option`; a supported API must preserve error
codes separately from an empty read.

## Proposed ownership boundary

Owned generated samples use ordinary Rust collections. Encoding borrows them;
owned decoding allocates Rust values after validating native lengths and status.
No ordinary application value must be `repr(C)` just to use the codec. The native
archive is an implementation dependency, not an object representation policy.

DDS raw loans expose serialized byte slices and sample metadata through a guard.
The guard holds the resources needed to keep its native reader and participant
alive. Views borrow `&self` on the guard, not just the reader lifetime. Returning
or dropping the guard invalidates its views. Construct Rust slices only after
checking pointer, length and null/empty cases; never cast CDR bytes directly to
arbitrary generated Rust values.

Native deletion through aliases, parent `delete_contained_entities`, callback
teardown and shutdown must be blocked or deferred while loans are outstanding.
A forgotten guard may leak/pin resources but must not allow use-after-free;
safety cannot depend on Drop always running. Specify ownership of the independent
key-hash sequence as well as the payload/sample-info loan. Offer an explicit
return operation that can report errors; Drop remains a non-panicking fallback
with a defined failure policy. Do not describe raw loan access as an end-to-end
zero-copy guarantee or a typed borrowed deserializer.

Keep reader/loan handles non-Send and non-Sync initially. Add thread traits only
after documenting native synchronization, deletion and callback invariants.
Listeners need a separate design for callback retention, replacement and panic
containment; Rust panics must not unwind across the C callback boundary. See
Rust's [FFI guidance](https://doc.rust-lang.org/nomicon/ffi.html) and
[Send/Sync guidance](https://doc.rust-lang.org/nomicon/send-and-sync.html).

The native codec allocator is process-wide. Do not expose an unrestricted safe
setter or assume Rust collections use it. Prefer fixed/counting output and
Rust-owned allocations in the first codec wrapper. If native-owned output is
added, pair its allocation/deallocation on the native side and preserve allocator
lifetimes. DDS allocator injection remains a separate resource-lifetime issue.

## Proposed PR sequence

1. **Standalone codec/ABI experiment in zidl.** Wrap a small CDR subset; check C
   layouts and link requirements, fixed/counting writers, both byte orders,
   malformed inputs and compile-fail buffer lifetimes. Prove consumption with a
   prebuilt archive and no Zig/C compiler in the application build.
2. **Minimal generated Rust codecs in zidl.** Final fixed-shape declarations and
   traversal first, then an explicit feature matrix for owned strings/sequences,
   unknown enum values, keys, optionals and extensibility. Check independent
   wire vectors before treating adapter roundtrips as conformance evidence.
3. **Minimal owned DDS client in zzdds.** Generate the required DDS API subset,
   implement resource ownership and error mapping, register a type and exchange
   owned samples through real UDP discovery. Include deletion and failed-create
   cleanup tests. Do not imply TypeObject support from successful serialization.
4. **Safe raw loan API.** Revalidate the old spike against current headers; test
   escape/double-return rejection, parent deletion, early-return/unwind cleanup,
   forgotten guards and independent hash ownership. Integrate listener and
   thread access only after their contracts are explicit.
5. **Distribution and broader coverage.** Relocated Rust consumer checks for
   Linux/macOS/Windows, shared allocator/symbol ownership with the DDS library,
   version coupling, examples and a documented supported API/encoding table.

The next concrete task is step 1, not the whole backend. Review and measure that
experiment before committing to a public crate API. `no_std`, custom collection
allocators, typed zero-copy views, a pure Rust codec and a broad DDS surface are
separate later decisions.
