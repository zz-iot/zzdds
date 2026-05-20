# History Cache Design

## What the cache stores

**Both writer and reader caches store serialized bytes (CDR SerializedPayload), not typed Zig structs.** This is a firm architectural decision with several interlocking reasons:

1. **RTPS reliability requires retransmit without re-serialization.** On NACK, bytes are read from cache and wrapped in a DATA submessage. If the cache held typed structs, every retransmit would need to re-serialize.
2. **Serialize once, send to N readers.** One CDR payload serves all matched readers (on the no-security path).
3. **The loan/zero-copy read API** only makes sense with stored bytes.
4. **DATA_FRAG reassembly** accumulates byte fragments; there is no typed object until reassembly is complete.
5. **XTypes type evolution**: a reader may hold a different schema version; it stores the raw bytes and deserializes with its own schema.

## CacheChange structure

```zig
pub const CacheChange = struct {
    kind: ChangeKind,               // ALIVE | NOT_ALIVE_DISPOSED | NOT_ALIVE_UNREGISTERED
    writer_guid: Guid,
    sequence_number: SequenceNumber,
    source_timestamp: RtpsTimestamp,
    instance_handle: InstanceHandle,

    // Pre-computed MD5 key hash from key fields only (RTPS §9.6.3.3).
    // Enables per-instance tracking without deserializing the full payload.
    // All zeros for keyless types.
    key_hash: [16]u8,

    // Complete serialized payload: 4-byte encap header + CDR bytes.
    // For locally-produced samples: always CDR2_LE (0x0011 encap ID, bytes {0x00, 0x11}).
    // For remotely-received samples: whatever the remote writer sent.
    // Writer cache: always plaintext. Reader cache: always plaintext.
    // Encryption/decryption happens at send/receive time, not here.
    data: []const u8,  // owned by the history cache allocator
};
```

## Encoding

- **Writer cache**: always CDR2_LE (XCDR2, little-endian). For `@final` types XCDR1 and XCDR2 produce identical bytes; XCDR2 encap ID (`0x0011`, bytes `{0x00, 0x11}`) is always used. For `@appendable`/`@mutable` types XCDR2 is the only valid choice.
- **Reader cache**: whatever encoding the remote writer sent — may be CDR_BE, CDR_LE, CDR2_BE, CDR2_LE. **The reader cache is routinely a mix of encodings** from different matched writers. The 4-byte encap header is self-describing; CdrReader (zidl-rt) handles all variants.
- The `DATA_REPRESENTATION` QoS policy (XCDR_DATA_REPRESENTATION) is used during SEDP matching to detect incompatibility. If a reader only accepts XCDR1 and a writer only produces XCDR2, they become QoS-incompatible and will not match.

## Allocator strategy

**Decided (Phase 5):** Per-change heap allocation — simple, correct, easy to audit. The cache owns each `CacheChange.data` slice via the passed-in allocator.

Future upgrade path if throughput under sustained load becomes a concern:
- Slab/pool per topic (better throughput, bounded fragmentation)
- Ring-buffer of fixed-size blocks (best for predictable KEEP_LAST memory on embedded targets)

Neither upgrade requires changes to the `CacheChange` interface — only the allocator strategy inside `HistoryCache` changes.

## Known limitations

- **KEEP_LAST history depth is global, not per-instance.** The current implementation tracks
  the depth limit across all instances of a keyed type. Per-instance tracking requires
  deserializing key fields to identify the instance, which in turn requires `deserializeKey`
  support in `zidl-rt` (not yet available). See `docs/roadmap.md`.
