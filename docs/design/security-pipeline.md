# Security Transformation Pipeline

DDS Security v1.2 (formal/25-03-06) defines **three independent protection scopes**, any
combination of which can be enabled simultaneously.

## Protection scopes

### 1. Payload protection (per topic/endpoint)

Encrypts/signs just the `serializedPayload` field (the CDR bytes). Metadata (sequence
numbers, entity IDs, inline QoS) remains in the clear. Useful when you want data
confidentiality but are OK with traffic analysis.

```
Before: DATA { ... | serializedPayload: [encap | cdr_bytes] }
After:  DATA { ... | SecureBody: [session_id | iv | ciphertext | MAC] }
```

Governed by `TOPIC_PROTECTION_KIND` in the security governance document.

### 2. Submessage protection (per DataWriter/DataReader)

Encrypts/signs the entire DATA/HEARTBEAT/ACKNACK/etc. submessage — including sequence
numbers and entity IDs. Replaces the submessage with a `SEC_PREFIX + SEC_BODY + SEC_POSTFIX`
triple.

```
Before: [DATA submessage]
After:  [SEC_PREFIX (0x31)] [SEC_BODY (0x30): encrypted DATA] [SEC_POSTFIX (0x32): MAC]
```

Governed by `ENDPOINT_PROTECTION_KIND`.

### 3. RTPS message protection (per DomainParticipant)

Wraps the entire RTPS message payload (all submessages) in one transformation. Hides even
participant-level metadata from observers.

Governed by `RTPS_PROTECTION_KIND`.

## Key invariants

- **Cache always stores plaintext.** Encryption happens at send time; decryption at receive
  time, before storing in the reader cache.
- **"Serialize once, N readers" breaks with payload/submessage protection.** Each matched
  reader has its own session key (negotiated during Authentication). Same plaintext →
  different ciphertexts per reader. Mitigation: readers sharing a governance/multicast group
  can share a key; hardware AES-GCM is fast (~1 ns/byte on modern CPUs).
- **Noop path: zero overhead.** The `Cryptographic.encode_payload` vtable for the noop
  plugin returns a pointer to the original bytes — no allocation, no copy.

## Encode_payload signature (needs revision before Phase 9)

The current `Cryptographic.encode_payload` signature writes into an `ArrayListUnmanaged`,
which forces an allocation even on the noop path. Before Phase 9, replace with a
tagged-union return:

```zig
const EncodeResult = union(enum) {
    borrowed: []const u8,   // noop: points directly into the input buffer
    owned: []u8,            // real crypto: heap-allocated ciphertext
};
```

This eliminates the allocation hot path when security is disabled.

## Send pipeline

```
No security (noop):
  scatter-gather iovecs → sendmsg()   [zero payload copies]

Payload protection only:
  encrypt(CacheChange.data) → temp crypt_buf
  scatter-gather [headers | crypt_buf] → sendmsg()

Submessage protection:
  build DATA into temp_buf → encrypt → SEC_PREFIX + SEC_BODY + SEC_POSTFIX
  scatter-gather [headers | encrypted triple] → sendmsg()

Message protection (outermost):
  all submessage work → encrypt entire payload → [RTPS hdr | SEC_* | MAC]
```

The `MessageBuilder` maintains a pooled scratch buffer (reused across messages) for the
security path. The noop path never touches it.
