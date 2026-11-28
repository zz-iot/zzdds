# Loaned builders: typed writes filled in place

Status: built. Accepted in #217; the zzdds groundwork is #219, the zidl
codegen zidl #112 (v0.3.47), and the view smoke tests write through builders
over a live writer and reader. Phase 2 of `shmem-zero-copy.md` (part B, the write side of loaned view
types). Builds on the write loans of `raw-loan-api.md` and zidl's write
reservations (zidl `docs/design/bulk-cdr-zero-copy.md`, zidl #99).

## Goal

A typed write whose large members are filled in place, in the write loan,
instead of being built in application memory and then copied into the CDR.

In C and C++, the generated `write` already serializes into a loan. It sizes
the sample with a counting writer, takes a loan of that size, serializes into
a fixed writer over it and publishes. (The Zig `write` serializes into a
buffer of its own and hands it to `writeRaw`, one copy more.) The copy left
at that end is the serializer copying every element of every large member out
of the application's struct. A builder removes it: generated code reserves
each large member in the loan, and the application writes the elements there
directly.

Read views (phase 1) remove the matching copy at the other end.

## The builder type

zidl generates, with the view types, a builder type per struct. It mirrors the
view type member for member, using the same classification
(`cdr_skip.viewKind`):

| Member, as in the view | In the builder |
|---|---|
| Primitive sequence or array (`primitives`) | A **reservation**. A sequence also has a count, set by the application; an array reserves its declared length. |
| String (`string`) | A borrowed string, copied into the loan as `write` copies it. |
| Struct (`struct_view`) | The nested struct's builder. |
| Anything else (`owned`) | The member as declared in the struct. |
| Any **key** member | The member as declared in the struct (decision 2). |

Optional members follow the view: a presence bit, and an absent reservable
member reserves nothing. Bounded sequences are checked against their bound
before any loan is taken.

## The flow

`loan_builder` is generated per type:

1. Computes the key hash from the builder's key members, which are never
   reservations, so the hash is known before anything is serialized.
2. Sizes the sample with a counting writer, in which each reservation just
   counts.
3. Takes a write loan of exactly that size (`loan_raw`).
4. Serializes into a fixed writer over the loan. Each reservation records its
   offset, and reserved elements are not written.
5. On any failure after step 3, returns the loan (`return_loan_raw`), so
   nothing is left outstanding.

The application then fills every element of every reservation and either
publishes or cancels:

- **`publish_builder`** commits each reservation, which puts the elements in
  the writer's byte order, then calls `publish_loan_raw` with the key hash from
  step 1.
- **`cancel_builder`** returns the loan unpublished (`return_loan_raw`).

A fixed writer's buffer never moves, so once `loan_builder` returns, every
reservation's address is stable until publish or cancel.

## By language

The read side's shapes carry over: a view and a loan on the way in, a builder
and a loan on the way out. The names below are illustrative; the
implementation settles them.

**C.** The builder is a plain struct; the loan is a separate handle, as on the
read side.

```c
SensorFrameBuilder b = { .stamp = now, .points_count = n };
SensorFrameWriteLoan loan;
if (SensorFrameDataWriter_loan_builder(&writer, &b, &loan) == DDS_RETCODE_OK) {
    void *pts = SensorFrameWriteLoan_data(&loan, &b.points);
    fill_points(pts, n);   /* typed stores need memory alignment: see Rules */
    rc = SensorFrameDataWriter_publish_builder(&writer, &b, &loan);
}
```

**C++.** A move-only `SensorFrameDataWriter::BuilderLoan` owns the builder and
the loan; its destructor cancels an unpublished loan. A reservation is a
`zidl::PrimitivesReservation<T>`, the write twin of `zidl::PrimitivesView<T>`:
`as_native()` gives `T*` when the address allows typed access, `copy_from`
fills it from a span, and `data()` gives the raw bytes.

```cpp
SensorFrameBuilder b;
b.stamp = now;
b.points_count = n;
SensorFrameDataWriter::BuilderLoan loan;
if (writer.loan_builder(std::move(b), loan) == DDS::RETCODE_OK) {
    auto &pts = loan.builder().points;
    if (float *p = pts.as_native()) fill_points(p, n);
    else pts.copy_from(staging);
    rc = writer.publish_builder(loan);
}
```

**Zig.** `loan_builder` returns an error union, and `deinit` cancels unless
the loan was published, so `defer loan.deinit()` is always safe.

```zig
var loan = try writer.loan_builder(.{ .stamp = now, .points = .{ .count = n } });
defer loan.deinit();
if (loan.builder.points.asNative(f32)) |pts| fillPoints(pts) else loan.builder.points.copyFrom(f32, staging);
try loan.publish();
```

Java is out, as for views: its bindings copy across JNI, so a builder would
save nothing.

## Rules

Carried over from zidl's reservations:

- **Not zeroed.** Reserved elements hold whatever the loan's memory held, and
  go onto the wire as they are. Fill every one.
- **No memory alignment promised.** Elements are aligned relative to the CDR
  stream, which starts after the 4-byte encapsulation header, not to memory.
  Typed stores need the typed accessor (`as_native`, `asNative`, or a C check
  of the address), with a byte copy as the fallback. With write loans
  allocated 8-byte aligned (decision 9), elements of up to 4 bytes are always
  aligned in memory. 8-byte elements are aligned only by chance in XCDR2
  (which aligns them to 4) and never in XCDR1 (whose 8-byte alignment lands
  them 4 bytes off), as on the read side.
- **Fill in host byte order.** Publishing commits, which swaps where the
  writer's byte order differs from the host's.

From the write loans:

- **One owner.** A loan belongs to one builder until published or cancelled.
  A writer may have several builder loans outstanding at once.
- **Publish consumes the loan, even on failure.** `publish_loan_raw` frees the
  buffer whatever it returns. A publish that fails, for example on
  `RESOURCE_LIMITS`, loses the filled sample, so it must be loaned and filled
  again.
- **Teardown.** An outstanding builder loan blocks `delete_datawriter` with
  `PRECONDITION_NOT_MET`, as any write loan does.

## Errors

| When | Result |
|---|---|
| A count above its sequence's bound | `BAD_PARAMETER`, before any loan |
| No loan available | `loan_raw`'s code (`OUT_OF_RESOURCES`) |
| A serialization failure after the loan | the codec's error; the loan is returned |
| Publish or cancel on a loan that is not outstanding | `PRECONDITION_NOT_MET` |
| Publish failing in the writer | `publish_loan_raw`'s code; the loan is consumed |

## Decisions

1. **The builder mirrors the view.** The same classification picks the
   reservations, including members of nested structs. Other members are
   serialized as `write` serializes them. One rule covers both directions.
2. **Key members are never reservations.** The key hash is computed before the
   loan, from members the application has set, and a key is small anyway. zidl
   makes key members ordinary members of the builder, so this cannot fail at
   run time.
3. **Publishing commits.** The application fills and publishes; it never calls
   commit. Commit is idempotent and cheap (a no-op unless the byte orders
   differ), and making it implicit removes the one step that is easy to forget
   and silently wrong on a byte-swapped writer. This replaces the explicit
   commit in `shmem-zero-copy.md`'s sketch.
4. **Unfilled elements go undetected.** Nothing can tell a filled element from
   a stale one without zeroing, and zeroing costs the pass reservations exist to
   avoid.
5. **Live writes only.** Builders publish `ALIVE` samples. A dispose or
   unregister carries the key alone, which has nothing to reserve, so those
   keep the ordinary calls.
6. **No timestamp variant yet.** `publish_loan_raw` has no source timestamp
   (the generated `write_w_timestamp` uses `write_raw` for that reason). A
   `publish_builder_w_timestamp` needs a timestamped publish in zzdds first,
   and waits for a user.
7. **One opt-in.** `--generate-views` generates the builders too. Views and
   builders are one zero-copy API with one lifetime rule: a pointer into a loan
   is valid until the loan ends.
8. **C, native C++ and Zig,** as for views.
9. **Write loans are allocated 8-byte aligned.** Today `loanForWrite` asks
   for plain bytes, which promises nothing, though every allocator in use
   gives more. Asking for 8 makes elements of up to 4 bytes (`float`, the
   common sensor case) reliably typed. Aligning 8-byte elements would need
   `loan_raw` to take the payload offset to align, and then only one
   reservation per sample could be aligned. That is deferred until doubles in
   place matter enough to someone.

## Work

- **zidl:**
  - the builder types, `loan_builder`, `publish_builder` and `cancel_builder`
    in the C, C++ and Zig backends, generated by `--generate-views`;
  - `zidl::PrimitivesReservation<T>` in `zidl_cdr_view.hpp`, and the
    application-facing accessors on the native Zig reservation;
  - integration tests per language over a stub writer, as for the views.
- **zzdds, first:**
  - `loanForWrite` allocates 8-byte aligned (decision 9);
  - the Zig facade (`raw_ops.zig`) gains `loanRaw`, `publishLoanRaw` and
    `returnLoanRaw` beside `writeRaw`, for the Zig builders.
- **zzdds, after the zidl release:** pin it, and smoke tests over a live
  writer and reader in C, C++ and Zig, extending the view smoke tests: a
  builder filled in place, read back with `take_view`.
