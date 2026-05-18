# RTPS Message Builder Design

## Do NOT pre-generate DATA headers

DATA headers are ~24 bytes and trivial to generate. The expensive thing is the payload,
which is already in the history cache. Build headers on the fly at send time.

## Zero-copy via scatter-gather I/O

The send path assembles an RTPS message as a list of `iovec` entries and calls `sendmsg()`.
On the no-security path, the payload is **never copied**:

```
iov[0] → stack buffer: RTPS Header (20 bytes)
iov[1] → stack buffer: INFO_TS submessage (12 bytes)
iov[2] → stack buffer: DATA header + inline QoS (~60–80 bytes)
iov[3] → CacheChange.data  ← direct pointer into history cache, zero copy
```

**Invariant: `CacheChange.data` is read-only and never modified by the message builder.**
The cache entry can be simultaneously pointed to by multiple in-flight iovecs (retransmit
to multiple readers at once).

## Fragmentation (DATA_FRAG)

Fragmentation happens at send time, not write time. The cache stores the complete payload.
Each DATA_FRAG submessage is built with a header on the stack and an iovec slice into
`CacheChange.data[offset..offset+frag_size]`. Still zero-copy.

The reader's `StatefulReader` accumulates DATA_FRAG payloads into a reassembly buffer
(indexed by writerSN + received-fragment bitmap). Only when all fragments arrive is a
complete `CacheChange` stored in the reader history cache.

## Security scratch buffer

When security is enabled, `MessageBuilder` maintains a pooled scratch buffer (reused across
messages) for intermediate encryption results. The noop path never touches it.

See `docs/design/security-pipeline.md` for the full send pipeline with security enabled.
