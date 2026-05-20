# Security Transformation Pipeline

> **Status: Not yet implemented.** The current codebase has the security plugin interface
> (`src/security/interface.zig`) and a noop pass-through (`security/noop.zig`). No real
> Authentication, AccessControl, or Cryptographic enforcement is in the data path. The
> send pipeline described below is the intended design for a future implementation.

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
- **Noop path target: zero overhead.** The desired `Cryptographic.encode_payload` shape for
  the noop plugin is a borrowed slice of the original bytes — no allocation, no copy. The
  current interface has not reached that shape yet; see the limitation below.

## Known limitation: encode_payload allocates on the noop path

The current `Cryptographic.encode_payload` signature writes into an `ArrayListUnmanaged`,
which forces an allocation even on the noop path. A tagged-union return would eliminate
this:

```zig
const EncodeResult = union(enum) {
    borrowed: []const u8,   // noop: points directly into the input buffer
    owned: []u8,            // real crypto: heap-allocated ciphertext
};
```

This optimization is deferred until a real Cryptographic implementation is underway,
since it requires changing the vtable signature across the interface boundary.

## Send pipeline

```
No security (noop):
  iovec list → flatten to stack buffer → Transport.send()

Payload protection only (planned):
  encrypt(CacheChange.data) → temp crypt_buf
  iovec list [headers | crypt_buf] → flatten → Transport.send()

Submessage protection (planned):
  build DATA into temp_buf → encrypt → SEC_PREFIX + SEC_BODY + SEC_POSTFIX
  iovec list [headers | encrypted triple] → flatten → Transport.send()

Message protection (planned, outermost):
  all submessage work → encrypt entire payload → [RTPS hdr | SEC_* | MAC]
```

The `MessageBuilder` maintains a pooled scratch buffer (reused across messages) for the
security path. The noop path never touches it.
