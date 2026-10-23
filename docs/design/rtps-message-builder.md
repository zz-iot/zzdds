# RTPS Message Builder Design

## Do NOT pre-generate DATA headers

DATA headers are ~24 bytes and trivial to generate. The expensive thing is the payload,
which is already in the history cache. Build headers on the fly at send time.

## Iovec assembly and gather-list sends

The send path assembles an RTPS message as a list of `iovec` entries pointing into static
buffers and the history cache:

```
iov[0] → stack buffer: RTPS Header (20 bytes)
iov[1] → stack buffer: INFO_TS submessage (12 bytes)
iov[2] → stack buffer: DATA header + inline QoS (~60–80 bytes)
iov[3] → CacheChange.data  ← direct pointer into history cache
```

**Invariant: `CacheChange.data` is read-only (`[]const u8`) and never modified by the
message builder.** The cache entry can be referenced by multiple in-flight iovec lists
(retransmit to multiple readers at once).

`sendIovecs()` hands the list to `Transport.sendGather(locator, iovecs)`. A transport
with `send_gather` takes the list as is: UDP on POSIX passes it to `sendmsg()`, so the
payload is not copied before the kernel. For a transport without it (TCP, the in-process
transports) and for UDP on Windows, the list is copied into a `[65536]u8` stack buffer and
sent flat. Either way a message over 65536 bytes is refused with `MessageTooLarge`. The
outcomes are in
[output submission](concurrency/transport-adapters.md#output-submission).

## Fragmentation (DATA_FRAG)

Fragmentation happens at send time, not write time. The cache stores the complete payload.
Each DATA_FRAG submessage is built with a header on the stack and an iovec slice into
`CacheChange.data[offset..offset+frag_size]`. The iovec list is still assembled without
copying, and is sent as described above.

The reader's `StatefulReader` accumulates DATA_FRAG payloads into a reassembly buffer
(indexed by writerSN + received-fragment bitmap). Only when all fragments arrive is a
complete `CacheChange` stored in the reader history cache.

## Security scratch buffer

In the planned security path, `MessageBuilder` will maintain a pooled scratch buffer
(reused across messages) for intermediate encryption results. The current implementation
has only the noop security plugin and no active cryptographic data path.

See `docs/design/security-pipeline.md` for the full send pipeline with security enabled.
