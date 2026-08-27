# Raw / Loaned DataReader & DataWriter API Design

## Motivation

zzdds has two informal "raw" API families today, both hand-written, C/C++-only, and
outside the IDL entirely:

- `zzdds_write_raw`/`zzdds_write_raw_kind` — write pre-serialized CDR bytes, bypassing
  `TypeSupport`/generated marshaling. Used by callers with their own serialization (a
  middleware layer speaking DDS wire format directly, e.g. a ROS2 RMW implementation).
- `zzdds_take_one_raw`/`zzdds_take_n_raw`/`zzdds_take_loaned_raw`/`return_loaned_raw` and
  their `_instance`/`_w_condition` siblings — the read-side equivalents. The batch copy
  family (`zzdds_take_n_raw` etc., `src/c_abi/bootstrap.zig`) already underlies most of
  the `--generate-zzdds-wrappers` typed reader class today via `nRawImpl`.

Two problems surfaced while adding the participant-config and discovery examples, and
while investigating an external ROS2 RMW integration attempt built directly on
`zzdds_take_loaned_raw`:

1. **`zzdds_take_loaned_raw` is a copy, and the name over-promises.** It heap-copies the
   sample out of reader history and wraps that copy in a loan-shaped handle. That's fine
   for what this API family *is* — a raw-**byte** loan that saves the caller a copy at the
   marshaling boundary — but the "loaned" name invites a caller to expect zero
   serialization / a native-struct pointer, which is explicitly **out of scope** (see
   "Scope boundaries" below). The name and doc comments were tightened to say "raw-byte
   buffer," not "zero-copy."
2. **The raw family is hand-written per-binding.** Only C/C++ have it; Java and Zig
   don't. Hand-written, independently-authored per-binding signatures are exactly the
   root-cause shape of the `create_participant_ex` C-ABI struct-layout bug found via the
   participant-config/discovery examples — building more surface area that way risks
   repeating it.

This document is the design for replacing both families with real, IDL-generated
operations, consistent and testable across all four bindings (C, C++, Java, Zig).

## Scope

In scope: raw and loaned `DataReader`/`DataWriter` operations only.

Out of scope, deferred to a separate follow-up: entity creation (factories,
`DomainParticipantFactory`). Creation is a distinct problem — some bindings construct
entities via native `new`, and `DomainParticipantFactory` has special underlying
lifecycle behavior that doesn't map cleanly onto the same "IDL op, generated
uniformly" treatment used here.

## Two real, pre-existing bugs found and fixed as part of this work

Neither is specific to raw/loan — both were found while tracing the raw tier's own
history, and both are cheap to fix now versus finding them again later.

### 1. `delete_contained_entities` has no error propagation anywhere

DDS 1.4 (`OMG_specs/formal-15-04-10.pdf`) is explicit: `delete_datareader` (§2.2.2.5.2.6)
*"is not allowed if it has any outstanding loans... will return PRECONDITION_NOT_MET"*,
and `Subscriber::delete_contained_entities` (§2.2.2.5.2.14) names outstanding loans as
**the** canonical example of when it must return `PRECONDITION_NOT_MET` — the recursive
propagation contract is identical one level up at `DomainParticipant::delete_contained_entities`
(§2.2.2.2.1.18).

zzdds's current implementation at every level (`participant.zig:vtDeleteContained`,
`subscriber.zig:vtDeleteContained`, `reader.zig:vtDeleteContained`) unconditionally tears
down children and hardcodes `return DDS.RETCODE_OK` — no precondition checking or error
propagation, for any reason, not just loans. Making loan-aware teardown correct requires
retrofitting genuine result-aware cascading through this whole chain, not just adding a
check to `delete_datareader`.

**Decided:** fast-fail only. `PRECONDITION_NOT_MET` on outstanding loans (read or write),
propagated correctly through the whole `delete_contained_entities` cascade. No
blocking/wait-for-release option in this round — noted as a plausible later addition
(a per-participant or per-entity QoS-style flag with a bounded `max_blocking_time`), not
built now.

### 2. Three of four bindings' typed reader family carries an incomplete `SampleInfo`

The entire `--generate-zzdds-wrappers` typed reader family (`take`, `read`, `take_n`,
`take_instance`, `take_w_condition`, `take_loaned`, etc.) in **C and C++** uses a reduced
3-field `zzdds_sample_info` (`valid_data`, `instance_state`, `instance_handle`) instead of
the real 12-field spec `SampleInfo` (`dcps.idl:1093`: also `sample_state`, `view_state`,
`source_timestamp`, `publication_handle`, `disposed_generation_count`,
`no_writers_generation_count`, `sample_rank`, `generation_rank`,
`absolute_generation_rank`). **Java's `Sample` class has the identical reduced field
set**, just inlined rather than a separate struct. **Only Zig's typed wrapper uses the
real, full `DDS.SampleInfo`.** This affects every existing C/C++/Java example today, not
just new raw/loan work.

**Decided:** fix bundled into this same effort (not split off as an urgent separate fix —
no real external users yet to bear the cost of the gap staying live a bit longer, and the
fix touches the same generator functions this redesign is already rewriting).

## The read side: unifying `max_len == 0`

DDS 1.4 §2.2.2.5.3.8 describes `read`'s `data_values`/`sample_infos` collections via an
abstract `len`/`max_len`/`owns` model: **`max_len == 0` on input is the spec-defined
signal to loan rather than copy**, and `return_loan` is a single universal release
operation, safe/a no-op even when there was no loan.

zidl's C backend already generates the matching `{_maximum, _length, T*_buffer,
_release}` sequence-struct shape (`c.zig:425`) — structurally the spec's collection
model. But the generated `take`/`read` wrapper never branches on `_maximum == 0` —
`take_loaned`/`return_loan` are a separate, hand-written parallel path bolted on, not
literally the `max_len == 0` branch of the same operation.

**Decided:** implement the real branch. One piece of codegen logic, applied uniformly to
every read/take-shaped operation (typed and raw alike), not a special case for the new
raw op — this also retroactively completes the existing `_w_condition`/`take_next_instance`
family's spec compliance.

**No annotation needed, on either axis:**

- Raw vs. typed is already fully expressed by parameter type (`octet_seq` vs. the
  topic's real struct type) — nothing for a marker to add.
- Loan vs. copy (`max_len == 0` branching) is structural, universal behavior, inferred
  from the parameter shape (a data collection paired with `inout SampleInfoSeq
  sample_infos`, both present) — not an opt-in flag. This matches the spec's own framing:
  it isn't optional per-op, every read/take-shaped operation is supposed to support it.

A dedicated new IDL builtin type for readability was considered and declined, in favor of
minimal frontend footprint — reuse over invention, consistent with every other choice in
this design.

## Raw ops as real `dcps.idl` operations

**Decided:** raw ops are real operations on the base `DataReader`/`DataWriter`
interfaces in `dcps.idl`, generated through zidl's already-proven op-generation path —
the same one that generates every other `DataReader`/`DataWriter` operation today. Not a
hand-written per-binding C-ABI extension (rejected — reintroduces the exact
independently-authored-signature risk category that caused the `create_participant_ex`
bug).

Illustrative shape (naming/exact IDL syntax may be refined at implementation time; the
structure below reflects the decided design):

```idl
@shared_c_abi_box interface DataReader : Entity {
    // ...existing ops...

    ReturnCode_t take_raw(
        inout sequence<octet_seq> cdr_payloads,   // batch: see "Batch reads" below
        inout octet_seq           key_hashes,     // N * 16 bytes, always copied (small, fixed-size — not worth loaning)
        inout SampleInfoSeq       sample_infos,
        in    long                max_samples);

    ReturnCode_t return_loan_raw(
        inout sequence<octet_seq> cdr_payloads,
        inout SampleInfoSeq       sample_infos);
};

@shared_c_abi_box interface DataWriter : Entity {
    // ...existing ops...

    ReturnCode_t write_raw(
        in octet_seq       key_hash,
        in InstanceHandle_t handle,
        in octet_seq       cdr_payload,
        in WriteKind        kind);        // alive | dispose | unregister

    ReturnCode_t loan_raw(
        in    unsigned long size,
        inout octet_seq     cdr_payload);

    ReturnCode_t publish_loan_raw(
        inout octet_seq        cdr_payload,
        in    octet_seq        key_hash,
        in    InstanceHandle_t handle,
        in    WriteKind        kind);

    ReturnCode_t return_loan_raw(          // cancel, no publish — write-side, not the read-side op above
        inout octet_seq cdr_payload);
};
```

**What actually shipped is broader than this sketch**, per its own "may be refined at
implementation time" caveat — see `idl/dcps.idl` for the real, final signatures. Real
`take_raw` also takes `instance_handle`/`a_condition`/`sample_states`/`view_states`/
`instance_states`, has a non-destructive `read_raw` sibling, and both have
`take_next_instance_raw`/`read_next_instance_raw` counterparts — added mid-implementation
for full parity with the old hand-written raw family's instance/condition-filtered
variants (`_w_condition`, `_instance`), which this sketch didn't originally cover. Real
`write_raw` also takes `source_timestamp` (`{TIME_INVALID_SEC, TIME_INVALID_NSEC}` =
"now"), covering the `_w_timestamp` family the old raw family had and this sketch didn't.
`publish_loan_raw` deliberately has **no** `source_timestamp` parameter, unlike
`write_raw` — only the "use now" write path can go through a loan; the `_w_timestamp`
family stays on `write_raw` in every binding's generated typed wrapper.

**Full replacement, not additive.** Every hand-written export in `bootstrap.zig`'s raw
family (`write_raw`, `write_raw_kind`, `take_one_raw`, `take_n_raw`, `read_n_raw`,
`take_n_instance_raw`, `read_n_instance_raw`, `take_next_instance_w_condition_raw`,
`read_next_instance_w_condition_raw`, `take_loaned_raw`, `return_loaned_raw`) is
superseded — no back-compat shim kept alongside (that would perpetuate the exact
two-implementations-drift risk that caused the `SampleInfo` bug). Core
`DataReaderImpl`/`DataWriterImpl` logic underneath (`takeRaw`, `readRaw`, `takeFiltered`)
is reused and extended, not discarded — only the hand-written export wrappers go away.
The entire typed-wrapper codegen (all 4 backends) gets rewritten in the same pass to
target the new raw ops instead of the old hand-written ones. Known migration-required
consumers of the *old* raw functions directly: the `zzdds-examples/spikes/rust` spike and
the external RMW attempt (not `c/shape/shape_main.c` — it only uses the typed wrapper and
just needs a rebuild).

## Batch reads

Batch copy-mode already exists and already underlies most of the typed API today
(`zzdds_take_n_raw`/`zzdds_read_n_raw`/`zzdds_take_n_instance_raw`/`zzdds_read_n_instance_raw`,
`bootstrap.zig:547`, `CRawSampleArray` shape via `nRawImpl`) — low risk to carry forward.

**Decided: full batch support, including loan-mode.** No `_n_loaned_raw` exists today;
this is the genuinely new piece.

**Pin granularity: one shared pin per batch call, but never one contiguous data region.**
A first design pass proposed a single contiguous `octet_seq` holding all N samples' CDR
bytes back-to-back — a real flaw: producing that layout requires copying each
independently-located sample into one consolidated buffer at take-time, which would
permanently defeat zero-copy for batches even after a real SHMEM backend exists (samples
naturally live in independently-allocated chunks, never contiguous by construction).

Corrected shape: `sequence<octet_seq> cdr_payloads` — N independent `octet_seq` views,
each pointing wherever that sample's storage actually lives, no consolidation ever. Only
the small array of N descriptor structs itself is a single contiguous allocation
(headers only, proportional to N, not to payload size) — the shared batch pin is keyed
off *that* array's pointer identity (see "Owner handles" below), one level up from the
single-sample case. One `return_loan_raw` call on the outer sequence releases the whole
batch at once. This isn't new invention — it's exactly the shape `zzdds_take_n_raw`'s
existing `CRawSampleArray` already uses today (an array of independently-allocated
per-sample entries) — the redesign formalizes it under IDL and adds the batch-level
pin/release on top.

**Partial batches on pool pressure**: if the pool has room for fewer than `max_samples`
requested, return what's available rather than fail the whole call — matches
`max_samples`'s existing "up to N, whatever's available" spec semantics, not a new
failure mode.

Batching applies to the read/take side only. Write-loans stay single-buffer, non-batched
by design (see below) — batch write-loans were never proposed and aren't needed for the
single-owner write-loan lifecycle.

## Owner handles: opaque, never a bare pointer

Every loan operation (read or write, single or batch) hands back an opaque owner/loan
handle alongside pointer + capacity — never a bare pointer alone. All subsequent
operations (publish-with-loan, cancel, return) key off the handle, re-validated
internally the same way `isNullHandle`/`unboxAsView` already validate every other handle
in `bootstrap.zig` today.

Concretely: since the caller always hands back the *same* `octet_seq`/`sequence<octet_seq>`
value it received, zzdds's C-ABI layer keys its internal outstanding-loans table off the
buffer's (or, for batches, the outer descriptor array's) pointer identity — no new struct
field needed, generated shape stays uniform between read-loans and write-loans, single and
batch.

## Write-side loan: `loan_raw` / `publish_loan_raw` / `return_loan_raw`

Not spec-standardized (same territory as ROS2 RMW's `rmw_publisher_loan`) — a zzdds
extension. Borrow → populate → publish-or-cancel, mirroring `rmw_publisher_loan()`/
iceoryx's shape.

**Single-owner, not multi-holder.** Read-loans and write-loans need different underlying
mechanisms, not one shared refcount primitive. A read-loan is multi-holder — many
independently-taken samples can be pinned concurrently by app code, which is why
retirement-vs-free decoupling and a refcount make sense there (see "Lifetime and
isolation" below). A write-loan is single-owner: one buffer, borrowed by exactly one
caller, until published or cancelled — a much simpler allocate/return lifecycle.

**Resource-limit timing: deferred admission (matches plain `write()` exactly).**
`loan_raw` does not check or reserve against `RESOURCE_LIMITS` — it only needs memory
from the backing pool (the same allocator seam built for read-loans, reused, no new
mechanism). The existing resource-limits check runs unchanged at `publish_loan_raw` time,
exactly mirroring today's `write()` failure mode. A fail-fast-at-loan-time alternative was
considered and rejected: `max_samples_per_instance` can't be enforced at loan time anyway
(`key_hash`/instance identity isn't known until `publish_loan_raw`), so it could only ever
partially front-load the check, at the cost of a genuinely new two-phase reservation
concept for a partial benefit.

**Teardown**: `delete_datawriter`/`delete_contained_entities` refuse with
`PRECONDITION_NOT_MET` on unpublished/uncancelled write-loans, symmetric with the
read-loan policy above.

## Sizing (client-side, not a core concern)

`loan_raw` just takes a byte count — where that count comes from is entirely the
caller's problem. For the generated typed `write()` wrapper: run a "counting" pass
locally, in-process, before ever calling `loan_raw`. Concretely, `ZidlCdrWriter`
(`zidl/packages/zidl-cdr/`) already has a fixed-capacity mode
(`zidl_cdr_writer_init_fixed`, `grow_fn == NULL`, returns `ZIDL_CDR_OVERFLOW` on
overrun — the generated `{Type}_serialize(ZidlCdrWriter*, const {Type}*)` functions are
already writer-abstracted, not buffer-management-aware, so they work unchanged against
it) — add a third "counting" mode (`buf == NULL`, writes just advance `len`/`pos`) so the
same unmodified `_serialize()` can run once to size, once to write. Zero new per-type
codegen. This is client-side/generated-wrapper-side plumbing, not threaded through the
loan operation's own semantics at all.

## Alignment

No contract needed. `zidl_cdr.c`'s primitive-write implementation goes through `memcpy`
exclusively — never a raw pointer-cast typed store — so CDR's relative-to-offset-0
alignment scheme is safe regardless of the loaned buffer's absolute base address. Will
still document a courtesy minimum (e.g. 8-byte) since every real allocator already
provides it for free, closing the door on ever needing this for a future raw-native-struct
loan variant (see "Deferred" below).

## Lifetime, isolation, and pool pressure (read-loan side)

**Decided: build the real mechanism now, heap-backed, not just an API shape.** This is
correctness-critical concurrency logic — pin/retire-vs-free ordering, isolation, teardown
refusal — that should be proven out against a boring, well-tooled backend (heap allocator
+ TSan + the existing DebugAllocator-reroute setup) before it also has to cope with real
SHMEM's much harder debugging story (cross-process, no TSan visibility). Building it twice
(fake now, real later) costs more than building it once correctly behind a seam.

**The core model**: decouple logical retirement (leaving the reader's `KEEP_LAST`/
`RESOURCE_LIMITS`-visible history, on schedule, unaffected by outstanding loans) from
physical free (deferred until a pin/refcount hits zero). One rule gives two properties for
free:

- **Pool exhaustion is bounded without blocking**: logical retirement never stalls — no
  cross-process writer ever waits on a reader's application code to release a loan. When
  real exhaustion happens (loans held well past headroom), refuse/drop new incoming data
  and report via `RETCODE_OUT_OF_RESOURCES`/`SAMPLE_LOST` — vocabulary zzdds already has
  (`zzdds_take_loaned_raw` already returns `RETCODE_OUT_OF_RESOURCES` on OOM today), not a
  new concept. Never force-invalidate an active loan.
- **Isolation is guaranteed by construction**: a writer never mutates published storage in
  place — a new sample always means a new allocation. Anything a pin is still holding is
  therefore permanently immutable until release. (True today by accident, since each loan
  is already a private copy — this design makes it an explicit, load-bearing contract so a
  future real zero-copy backend inherits the guarantee instead of retrofitting it, closing
  a gap the real ecosystem — rmw_fastrtps — has shipped without an answer to.)

**Scoped to the DCPS layer only, not `HistoryCache`.** The pin attaches to the
already-existing per-reader heap-allocated retained-sample store (the `PendingChange`/
reader-queue level in `reader.zig`), not the RTPS `HistoryCache`'s own `CacheChange.data`.
Eliminating that *first* copy (DCPS borrowing directly from the RTPS cache instead of
duping) stays out of scope — that's protocol-layer, reliability-sensitive code this
project has already found subtle concurrency bugs in before (see
`docs/design/rtps-proto-quiesce` decision), and refactoring it as a side effect of the
loan work would be an unwarranted risk increase.

**No config flag yet for backend selection.** Only one backing-store implementation
exists this round (heap) — nothing to select between. Build a clean pool/allocator-shaped
seam the refcount/retirement logic depends on abstractly (modeled on `dds-rtps`'s existing
`createFactoryWithAllocator` precedent), with the heap-backed implementation wired in as
the only concrete one today. The config flag(s) become real work for the later
SHMEM-backend effort, when there's an actual second implementation to gate between.

**Refcount mechanism**: a sibling of `EntityQuiesce`, not a new concurrency primitive —
same underlying problem ("don't free while someone might still be touching it, teardown
must observe this safely"), same proven CAS-acquire/tearing-down-flag pattern, already
TSan-verified in this codebase.

## Scope boundaries

**What this API is.** A *raw-byte* loan: the application serializes directly into, or reads
directly out of, an internal CDR buffer, avoiding one copy. The bytes are still CDR; QoS,
security, and RTPS wire behaviour are unchanged.

### Out of scope — not a fit for a DDS implementation (decided 2026-08-27)

- **True zero-copy meaning zero serialization** and a **raw native-representation (POD)
  loan variant** (a fixed-layout native struct pointer, as ROS2 RMW's POD-only loan
  contract wants). This is fundamentally at odds with IDL as a platform-agnostic data
  representation and with the QoS / security / wire assumptions the rest of the stack
  relies on — close to an anti-feature here. Applications needing that class of
  performance should use a mechanism that doesn't carry representation-independence, QoS,
  or security. The alignment courtesy-minimum above is just that — a courtesy, not a
  foothold for this.

### Deferred — possible future work, not committed

- **Entity creation** (factories, `DomainParticipantFactory`) — separate follow-up.
- **SHMEM for the RTPS `HistoryCache`** — using shared memory for cache *storage* (with
  RTPS/UDP scaffolding, as Connext does) is still on the table; it does not imply zero
  serialization. This design's storage seam is built so a SHMEM pool can slot in
  underneath without an API break.
- **A SHMEM transport** alongside UDP/TCP — not in v1; possible later. See the roadmap's
  "Deferred / Out of Scope for v1" section for the scope boundary.
- **Blocking teardown option** (wait-for-release instead of fail-fast) — plausible later
  addition (a bounded `max_blocking_time`-style config), not built now.

## Java-specific implementation note

**Status: implemented, but not the way this section originally predicted** — recorded here
for anyone relying on this doc to find the code. The write-loan buffer reaches Java as a
`java.nio.ByteBuffer` backed by native memory (`JNI NewDirectByteBuffer`), as planned. What
changed: this section originally assumed the work would land as a new hand-written native
method in `java_runtime/zzdds_java_runtime.c` (following that file's existing
`jbyteArray`-based conventions), reasoning that `zzdds_java_runtime.c` was the only place
Java's JNI bridge lived. That assumption stopped holding once `write_raw`/`take_raw` and
friends became real generic `dcps.idl` operations generated for every binding, including
Java: the generated `--generate-zzdds-wrappers` typed reader/writer classes call straight
through to the *generated* base-interface JNI bridge (`java.zig`'s own `emitJniBridgeOp`
codegen) rather than through `zzdds_java_runtime.c` at all — that hand-written file is no
longer a dependency of the raw/loan read/write path in any binding.

Given that, the write-loan buffer exposure landed as a `java.zig` codegen special case
(`isWriteLoanBufferOp`, matching `DataWriter`'s `loan_raw`/`publish_loan_raw`/
`return_loan_raw` by name) instead: these three ops get a hand-written emission at every
generation layer (interface method, impl class + native decl, JNI bridge) using
`java.nio.ByteBuffer` for `cdr_payload` in place of the generic `List<Byte>` every other
`OctetSeq` param gets. `loan_raw` became `ByteBuffer loan_raw(int size)` — a return value,
not an `inout` param, since Java has no way to grow/replace a `List` into a *fresh* direct
buffer the way it can keep mutating the same `List` object in place for a real `inout`.
`zzdds_java_runtime.c` needed zero changes.

This turned out to be load-bearing, not just a cleaner architecture: a first attempt at
generating `loan_raw`/`publish_loan_raw` through the *generic* per-op JNI path (the same
one `write_raw`/`take_raw` use, before this special case existed) compiled and looked
correct, but silently lost the loaned buffer's identity — Java's generic `inout OctetSeq`
marshaling copies through a *fresh* native buffer on every JNI call boundary, so
`publish_loan_raw` never actually saw the buffer `loan_raw` returned. Confirmed via a real
build-and-inspect of the generated bridge, then via a deliberate re-break: this doesn't
just leak (as the "Owner handles" section above assumes for every binding — "the caller
always hands back the *same* value it received" turned out to be Java-JNI-boundary-false
without this fix), it publishes the fresh buffer's *uninitialized* contents as the sample,
a real data-corruption bug, not a resource leak. `NewDirectByteBuffer`'s
`GetDirectBufferAddress` reliably returns the same native address back for the same Java
object (not a `.slice()`/`.duplicate()` of it), which is what makes the `ByteBuffer`-based
special case actually preserve identity across the call pair.
