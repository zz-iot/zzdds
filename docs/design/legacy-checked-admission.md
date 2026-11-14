# Checked admission for native/legacy bindings

`zzdds_register_type_support_checked` and its `_ctx` variant install an ordinary
C/native registration on the existing checked sample-processing path. The
callback receives encapsulated DDS bytes and an explicit key-only flag, and
returns status plus a hash. Nonzero status aborts before sequence accounting,
protocol history and DCPS history. The same hook handles DATA, reassembled
DATA_FRAG and prematch replay. An inline key hash does not bypass processing.
Protocol end markers retain their existing handling.

This is additive and opt-in. Existing `zzdds_register_type_support(_ctx)` and
native hash-only registration stay compatible and do not become validation APIs.
Generated C/C++ values can supply `<Type>_process_sample_from_cdr` from the zidl
hardening stack. That callback uses ordinary decoding/evolution defaults, not an
all-required-field validation policy. Checked endpoint kinds use explicit keyedness metadata. Keyless ALIVE samples must still decode;
a successful all-zero hash is valid and never used as an error sentinel.

```c
int rc = zzdds_register_type_support_checked(
    participant, "Module::Topic", Module_Topic_process_sample_from_cdr,
    Module_Topic_has_key, NULL);
```

Register before creating topics. A checked entry is immutable: equivalent
callbacks and context are idempotent; conflicts, late installations and attempts
to replace checked support with unchecked support reject. This avoids modifying
callbacks on published endpoints. The native equivalent is
`DomainParticipantImpl.installCheckedTypeSupport`, which transfers ownership
only on a new successful install and supports a pure equivalence callback.

The adapter holds a base reference owned by the participant, plus independent
processor references for protocol readers and getter references for DCPS readers.
The getter pin covers query/filter operations through reader retirement, even
when the protocol reader has already retired. Context cleanup waits for the last
reference, including deferred endpoint retirement. The ctx API takes ownership
only on a new successful install. Equivalent registration with the same ctx does
not take or release it again; failure leaves ownership with the caller. Processing
callbacks must be reentrant: different readers can invoke one registration
concurrently. They run synchronously under a protocol reader lock and must not call DDS
APIs, retain payloads or block.

Lifecycle notifications with no encoded key value preserve a supplied hash for
keyed types and use zero for keyless types. Nonempty lifecycle data is checked
with key_only=1. Keyless callbacks must still check nonempty ALIVE data. Hash
recovery placeholders are not admission decisions: the checked processor supplies
the actual hash before delivery.

Tests:

- `test-c-abi-typesupport`: context/bare registration, valid zero hashes,
  rejection/retry before sequence accounting, DATA_FRAG/prematch, immutable
  registration and cleanup pins; checks automatic installation on an actual
  legacy DataReader too.
- `test-checked-admission-generated -Dzidl-source=/absolute/local/zidl`: compiles
  actual generated C callbacks and exercises keyed/keyless rejection on real
  readers, genuine key-only shapes, MU checks and ordinary evolution defaults.
- Existing experimental `test-typesupport-library` remains separate and uses its
  restricted wire-validator ABI. Its registration path is unchanged.

The local generated fixture requires a generator with checked callbacks. Normal
builds keep their published dependency pin; existing generated Java/Zig
registration glue is not automatically migrated to this C API.
