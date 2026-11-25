# RTPS over shared memory, with payloads by reference, and loaned view types

Status: accepted design, not built. Builds on the raw-loan API
(`raw-loan-api.md`) and zidl's zero-copy bulk CDR views and reservations
(zidl `docs/design/bulk-cdr-zero-copy.md`, zidl #98 and #99).

## Goal

Two participants on the same host should exchange a large sample without
copying its payload. The writer fills it in place and the reader uses it in
place. The bytes stay **CDR**, and the messages stay **RTPS**, so QoS,
reliability, discovery, type evolution and remote peers work as they do today.
Two parts:

- **A. An RTPS-over-shared-memory transport.** Participants on one host
  exchange RTPS messages through shared-memory inboxes instead of sockets. A
  DATA submessage to a same-host reader carries a reference to the payload,
  which lives in a stable shared region, instead of the payload itself.
- **B. Loaned view types.** zidl generates typed, opt-in loaned samples whose
  large members are views into the loaned bytes (reads) or reservations in the
  loan (writes). Part B is useful without part A, since loans already exist.

### Non-goals

- **Zero serialization.** Native-layout loans stay out of scope, as
  `decisions.md` records ("Loans are raw *bytes*, not zero serialization").
- **Discovery over shared memory.** SPDP and SEDP stay on UDP. They advertise
  each participant's shared-memory locator, and the broker work may revisit
  this.
- **Security-protected payloads.** Payload protection transforms the bytes, so
  those topics use the network transports.
- **Sharing between users.** Segments and inboxes are per user (see Cleanup).

## Where the copies are today

For a large payload between two processes on one host over UDP loopback,
traced from the code:

| # | Copy | Where |
|---|------|-------|
| 0 | Struct to CDR, into the write loan | generated `serialize` |
| 1 | Loan into the writer's history cache | `history.zig` (`HistoryCache.add`) |
| - | None into the datagram: the builder passes payload slices to `sendmsg` (scatter-gather), in DATA_FRAGs of 16 KB by default | `message/builder.zig` |
| 2-3 | Kernel send and receive | UDP |
| 4 | Datagram into the participant's ingress queue | `participant.zig` (`queueIngress`) |
| 5 | Into the RTPS reader's cache, after reassembly | `reader_sm.zig` |
| 6 | Into the DCPS reader's pending store | `reader.zig` |
| 7 | CDR into the application's struct | generated `deserialize` |

That is six copies of the payload between serialization and decode. A read
loan already pins copy 6 instead of copying it again. Part A removes copies 1
to 6 for same-host readers. Part B removes copies 0 and 7 for the members that
matter.

## Part A: RTPS over shared memory

### Inboxes

Each participant using the transport owns one **inbox**: a bounded,
multi-producer, single-consumer ring of RTPS messages in shared memory. Its
`shmem` locator (host id and channel) names the inbox, and discovery advertises
it.

- **Sending** to a same-host locator appends the RTPS message to that
  participant's inbox. Producers reserve a slot atomically, write it, then
  publish it.
- **Fan-out** is one small message per reader participant. A slow or
  disconnected reader can only fill its own inbox.
- **Wake-up:** the consumer sleeps on a per-inbox primitive and producers
  signal it. The primitive must fit the runtime's progress backends as a
  readiness source: `eventfd` on Linux, and a named event on Windows, where the
  poll backend needs a way to wait on it. On macOS it is to be decided. This
  is the main per-platform work.
- **A full inbox drops the message.** BEST_EFFORT loses it. RELIABLE repairs
  it through RTPS: the reader sees a gap, NACKs it, and the writer resends,
  still by reference, since its history holds the chunk. Writers never block
  on an inbox.

Messages are ordinary RTPS. The first version keeps today's reliability
behaviour unchanged (HEARTBEAT, ACKNACK) over the inbox. Removing that
redundancy is a separate roadmap item.

### Payloads by reference

- **Segment.** Each participant owns one **payload segment**, created at its
  first loan and **growable up to a cap**: it adds extents as needed. The
  transport configuration sets both the initial size and the cap.
- **Chunks.** A writer's loan is a chunk in its participant's segment,
  allocated from size classes. Its history cache **adopts** the chunk instead
  of copying it (copy 1). A chunk header holds:
  - the length;
  - a **generation**, bumped on every reuse;
  - **reference counts** (below).
- **A DATA submessage** to a same-host reader carries a vendor inline-QoS
  **payload reference**, giving segment, extent, offset, length and generation,
  instead of the payload. So there is no DATA_FRAG, however large the sample.
- **The reader** maps the writer's payload extents read-only the first time it
  sees them. Its RTPS and DCPS stores keep the reference rather than bytes
  (copies 4 to 6). A read loan points into the chunk. A reference whose
  generation doesn't match is refused.
- **Isolation.** A writer never writes to a published chunk. `raw-loan-api.md`
  already makes this an explicit contract.
- **Remote readers** get ordinary DATA on the network transports, built from
  the chunk exactly as from today's cache. A writer serves each reader by its
  locator.

### Chunk lifetime

A segment has two kinds of memory. **Payload extents** are mapped read-only by
readers. A small **control area**, mapped read-write by every participant that
maps the segment, holds a **reader table** and each chunk's header.

- **Reader table.** Each writer participant's control area has a table of
  same-host reader participants. Its size is configured, for example 63. An
  entry records a reader's GUID prefix, a state, and its **outstanding
  bytes** (see Byte budgets). The entry's index names its counter in every
  chunk.
  - **Claiming.** When a reader participant first matches an endpoint of a
    writer participant on the same host, it maps that participant's control
    area and claims a free entry with an atomic compare-and-swap, recording
    its GUID prefix. It maps payload extents lazily, when a reference first
    names one.
  - **Sending.** Before sending a reference, the writer looks up the reader's
    GUID prefix in its own table. While the reader has no entry, because it
    hasn't claimed one yet or the table is full, the writer sends **inline**.
    By-reference delivery therefore starts per reader once its entry exists,
    with no extra handshake.
  - **Departing.** When a reader participant no longer matches any of that
    writer participant's endpoints and has given back all its counts and
    bytes, it marks its entry *departing*. The writer sends inline to a
    departing entry, and frees the entry once its counts are all zero:
    entries are the writer's to free, like chunks.
- **Reference counts, per reader only.** Each chunk header has a
  **per-reader count** for each reader-table entry, and nothing shared
  between readers. A reader only ever changes its own counter, one atomic
  operation at a time, so a crash leaves each count either decremented or
  not, never half-updated. Every reference message carries exactly one count,
  so no send's hold can be mistaken for another's:
  - The writer **adds one** to the reader's count **for each reference it
    sends**, before pushing the message. A chunk therefore stays held while
    any of its references is in flight, even if `KEEP_LAST` evicts it from
    the writer's history meanwhile. Retransmissions are separate sends with
    separate counts.
  - If a push fails because the inbox is full, the writer takes back **that
    send's** count, and no other.
  - The reader gives back **one count per reference it received**. It keeps
    the first reference to a chunk until its last local holder releases it:
    its RTPS cache, its DCPS store and its loans, tracked locally. It gives a
    duplicate's count back at once, which leaves the kept reference's count
    in place. It gives a rejected reference's count back at once too (stale
    generation).
  - Giving back its own counts and outstanding bytes, and claiming its table
    entry, are the only writes a reader makes into another participant's
    segment.
- **Only the writer frees.** The writer knows locally when its history drops
  a change. It then puts the chunk on a **retired list**. When it allocates,
  and periodically, it returns retired chunks whose per-reader counts are all
  zero to their size class, bumping their generation. Readers never free a
  writer's chunk.
- **Small payloads go inline.** The counts cost a few bytes per reader per
  chunk, so payloads below a configured threshold travel inline in the DATA
  message, as on any transport, and only larger ones by reference.
- **Byte budgets, not chunk counts.** Sample sizes vary, `KEEP_LAST` depth
  applies per instance, readers match after the segment exists, and
  unpublished write loans hold memory too. So the bounds are in bytes:
  - The **segment cap**, from the transport configuration, bounds everything
    a participant's writers hold: history, loans, and chunks lent to readers.
    Each writer's history stays governed by its HISTORY and RESOURCE_LIMITS as
    today, and its outstanding write loans count against the segment too.
  - Each same-host reader has a **byte quota** per writer participant,
    enforced by the **sender**, so that references queued but not yet
    received count too. Before sending a reference, the writer adds the
    chunk's size to the reader's outstanding bytes in its table entry. A
    failed push takes that send's bytes back, and the reader gives the bytes
    back with each count.
  - **The quota decides how a sample is delivered, never whether.** When a
    reference would exceed the quota, the writer sends that sample **inline**
    instead: the payload is copied into the reader's inbox, in DATA_FRAGs as
    on any transport. Inline delivery pins nothing in the writer's segment,
    so a reader at its quota still makes progress, including repairs of an
    earlier gap while it holds later samples waiting for it. Such samples
    just cost a copy. A chunk larger than the reader's quota always goes
    inline.
  - The quota bounds what a slow or suspended reader can pin, and the inbox's
    capacity bounds its inline traffic, which a full inbox drops as usual. So
    one reader cannot consume the cap. This follows `raw-loan-api.md`'s rule
    that a writer never waits on a reader's application code.
  - A sample larger than the largest size class gets an extent of its own,
    within the cap.

  Nothing derives the cap from QoS. It is configured; quotas share it fairly.
- **Allocation failure.** If no chunk fits and the segment is at its cap,
  `loan_raw` fails with `OUT_OF_RESOURCES`, as today's heap-backed `loan_raw`
  does on exhaustion.

### Liveness and cleanup

Three rules decide who cleans up after whom, without races:

1. **Owners clean their own structures.** Only a participant reclaims inside
   its own segment and inbox:
   - a writer resets a dead reader's accounting as a whole: its per-reader
     count in every chunk and its outstanding bytes go to zero, and its
     reader-table entry is freed. Nothing shared between readers needs
     repairing, so a release the reader left half-done cannot corrupt it;
   - an inbox owner skips slots a dead producer reserved but never published.

   No participant reclaims inside another live participant's structures. A
   reader giving back its own counts is a release, not a reclamation.
2. **The OS decides who is dead.** Each participant holds an exclusive lock on
   a per-participant **lock file** for its whole life: `flock` on POSIX, and
   `LockFileEx` on Windows. Both are held by the process's open file, not by a
   thread, so a thread exiting changes nothing. The kernel releases the lock
   only when the process exits, crash included, and there is no process-id
   reuse to get wrong. (A Windows named mutex would not do: it belongs to a
   thread, and is abandoned when that thread exits.) The file is opened
   close-on-exec, so a child process cannot inherit it. If one did, it would
   only keep the participant looking stalled, never dead.
   - **Lease expired, lock held: stalled** (suspended, debugged). Every other
     participant independently stops delivering to it, which changes nothing
     shared. Its pinned chunks stay, bounded by its quota, since it may resume
     and read them.
   - **Lock acquirable: dead.** Writers reset its accounting in their own
     segments.
3. **Taking a dead participant's lock is the claim to reap it.** The one
   participant that acquires it unlinks the dead participant's segment,
   inbox and lock file. Others fail to take the lock and move on. Mappings
   already open keep the memory alive until they close.

Every participant using the transport **sweeps the per-user directory of lock
files at startup, and periodically**, reaping any it can lock. A participant
that crashed during shutdown, with nobody left to notice, is cleaned up by the
next run rather than leaking.

The directory is per user, for example `$XDG_RUNTIME_DIR/zzdds`,
`/tmp/zzdds-<uid>` or `%LOCALAPPDATA%\zzdds`. Segment and inbox names derive
from domain and GUID prefix.

## Part B: loaned view types

zidl generates, opt-in, a **view type** per topic type, alongside the ordinary
struct:

- Primitive sequences and arrays become `ZidlCdrPrimitivesView` in C, a native
  view type in C++, and `PrimitivesView` in Zig.
- Strings are zero-copy.
- Every other member is decoded as today.

Decoding a view walks the CDR once, costing per member rather than per byte.

```c
SensorFrameView view;
SensorFrameLoan loan;
if (SensorFrameDataReader_take_view(&reader, &view, &info, &loan) == DDS_RETCODE_OK) {
    const float *pts = ZIDL_CDR_VIEW_AS(&view.points, float);
    if (pts) { /* use view.points.count floats in place */ }
    else     { /* zidl_cdr_view_copy into a buffer of your own */ }
    SensorFrameDataReader_return_view(&reader, &loan);
}
```

- A view is valid until its loan is returned. This is why view types are a
  separate, opt-in API: the ordinary typed take hands back a struct the
  application owns and may keep.
- The write side is a **loaned builder**. The application sets the scalar
  members and the lengths of its reserved members. Generated code:
  1. sizes the sample with a counting writer;
  2. takes a write loan;
  3. serializes into it, reserving the large members;
  4. returns the reservations.

  The application fills and commits each reservation, then publishes.

  ```c
  SensorFrameBuilder b = { .stamp = now, .points_count = n };
  if (SensorFrameDataWriter_loan_builder(&writer, &b) == DDS_RETCODE_OK) {
      fill_points(zidl_cdr_reservation_data(b.writer, &b.points), n);
      zidl_cdr_commit_primitives(b.writer, &b.points);
      SensorFrameDataWriter_publish_builder(&writer, &b);
  }
  ```

- **Rules carried over from zidl's design:**
  - elements are aligned relative to the payload, not memory;
  - swapped views must be copied;
  - typed access needs allocated storage: true of loans, whether heap or
    shared memory;
  - reservations are not zeroed, and every element must be filled.
- **Languages:** C, native C++ and Zig. Java's bindings copy across JNI, so
  views would gain little there.

## Phasing

1. **Read view types over today's heap loans** (zidl codegen, and the zzdds
   typed wrappers in C, C++ and Zig). This removes the decode copy.
2. **Loaned builders** for writes, with reservations.
3. **Writer history adopts loaned buffers** (heap): removes copy 1 for every
   writer. It is also the seam the shared segment slots into.
4. **The shared-memory inbox transport, with payloads inline.** RTPS over
   shared memory first, proving the inboxes, wake-ups, drops and repair,
   liveness locks and sweeps, with no shared payloads yet. This already
   removes the kernel copies.
5. **Payload segments and references:** chunks, generations, the reader
   table and per-reader counts, the retired list, sender-side byte quotas with
   inline fallback, the inline threshold, and growth with a cap.

## Decisions

1. **Transport:** RTPS over shared-memory inboxes, with no UDP for same-host
   user data. Discovery stays RTPS over UDP for now.
2. **Inboxes:** one per participant (multi-producer, single-consumer). Higher
   fan-out cost than a broadcast ring per writer, but a slow or disconnected
   reader only affects itself.
3. **Reliability:** today's RTPS behaviour, unchanged, in the first version.
   Eliding redundant HEARTBEAT and ACKNACK traffic over shared memory and TCP is
   a roadmap item. It must stay robust to deliberate drops (decision 4).
4. **A full inbox drops the message,** and RELIABLE repairs it through RTPS.
   Writers never block on an inbox.
5. **Cleanup:** owners reclaim inside their own structures. Process-held file
   locks distinguish dead from stalled. Taking a dead participant's lock elects its
   one reaper. Startup and periodic sweeps clean up after past runs. Stalled
   participants keep their quota-bounded chunks until confirmed dead.
6. **Segments:** one per participant, growable up to a cap, with the initial
   size and cap set in the transport configuration.
7. **Loan failure:** `loan_raw` fails with `OUT_OF_RESOURCES`. A blocking loan
   is deferred: with byte quotas and growth, exhaustion means the cap is too
   small, and waiting would mostly wait on a stalled reader.
8. **View types:** primitive sequences and arrays become views, and strings
   become zero-copy, in C, native C++ and Zig.
