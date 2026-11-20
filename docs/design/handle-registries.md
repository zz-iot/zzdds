# Handle registries

Step 1 of the roadmap's *Hashed handles collide* item: what makes and uses instance and
entity handles today, what the registries that replace the hashes look like, and the
order of the work. The decision is summarised in [`decisions.md`](../decisions.md)
(*Instance and entity handles are allocated, not hashed*). Study of 2026-11-18.

## Today

`InstanceHandle_t` is an `i32`; `HANDLE_NIL` is 0.

### Instance handles

`keyHashToHandle` (`src/dcps/writer.zig`) folds a 16-byte RTPS key hash into a positive
31-bit FNV-1a value. Every per-instance table in the DCPS layer is keyed by it.

| Entity | Made at | Keyed by the handle | Guard | Removed |
| --- | --- | --- | --- | --- |
| DataReader | `onDataCb`, `pushBuiltinCdr` | `seen_instances` (state, generation counts, key CDR), `tbf_map`, `owner_map`, `writer_instances` values; KEEP_LAST and RESOURCE_LIMITS scans of `pending` by `info.instance_handle` | `mu` | `seen_instances` never; `tbf_map`/`owner_map` on dispose or unregister |
| DataWriter | `writeRaw` (first alive write) | `key_registry` (key CDR for `get_key_value`) | `key_registry_mu` | never |

The writer's `register_instance` and `lookup_instance` are static functions of the key
hash (`registerInstanceRaw`, `lookupInstanceRaw`); the C ABI ignores the writer it is
given (`zzdds_register_instance_raw`, `zzdds_lookup_instance_writer`). So
`lookup_instance` never returns `HANDLE_NIL` for a key never registered or written,
although its doc comment says it does, and two writers hand out the same handle for one
key.

The RTPS history cache (`src/rtps/history.zig`) does not use these handles. Its
`InstanceHandle` is 16 bytes, so its KEEP_LAST trimming cannot collide. The study found
that the generated Zig code's write path (`raw_ops.writeRaw`, `writeRawWithTimestamp`)
gave it `INSTANCE_HANDLE_NIL` rather than the key hash, so a Zig application's keyed
KEEP_LAST writer kept `depth` samples in all, not per instance. Fixed 2026-11-19: the
DCPS writer's write functions no longer take an instance, and use the key hash.

### Entity handles

| Entity | Handle |
| --- | --- |
| Local participant | factory counter (`factory.next_handle`) |
| Local publisher, subscriber, topic | participant counter (`nextHandle`) |
| Local DataWriter, DataReader | `guidToHandle(own GUID)` |
| Discovered participant, DataWriter, DataReader | `guidToHandle(GUID)` |
| Discovered topic | `topicToHandle(name, type)`, the same fold over the names |
| Built-in topic sample | `keyHashToHandle(BuiltinTopicKey)`, equal to `guidToHandle` of the entity |

The last row is what makes the APIs agree: a handle from a built-in reader's `SampleInfo`
is the one `get_matched_*`, `get_discovered_*`, `ignore_*` and
`SampleInfo.publication_handle` use (`test/dcps/api_test.zig` checks it for
DCPSPublication). Readers compute `publication_handle` for each sample, under their own
`mu`, by folding the writer's GUID. Ignored publications and subscriptions are kept as
handles (`ignored_publication_handles`, `ignored_subscription_handles`). Two places already
detect collisions: `DataReaderImpl.publication_guids` and
`get_matched_subscription_rtps_guid`.

### Other lookups

The GUID- and prefix-keyed maps (`writer_liveliness`, `discovery_gens`, SPDP's `known`,
SEDP's `participant_locs`, …) are `std.AutoHashMap`s and need no change. The participant's
`discovered_participants`, `discovered_writers`, `discovered_readers` and
`discovered_topics` are lists searched linearly by GUID or name, in 16 loops in
`participant.zig`; they are a follow-on, not part of this work.

## Measurements

`docs/design/probes/handle_registry_bench.zig` (`zig run -OReleaseFast …`), Windows 11,
x86_64, Zig 0.17.0, two runs within a few percent of each other. Nanoseconds per lookup of
a random existing key, 2,000,000 lookups:

| Instances | Collisions (int / MD5 keys) | Today, 1 map | Today, 3 maps | Registry | Registry, by handle | `ArrayHashMap` |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0 / 0 | 20 | 29 | 20 | 0.6 | 19 |
| 10,000 | 0 / 0 | 26 | 39 | 30 | 2.2 | 27 |
| 100,000 | 0 / 6 | 37 | 87 | 70 | 4 | 60 |
| 1,000,000 | 0 / 227 | 99 | 177 | 138 | 11 | 180 |

- *3 maps* is a reader with TIME_BASED_FILTER and EXCLUSIVE ownership, which reads
  `seen_instances`, `tbf_map` and `owner_map` for each sample. The registry holds all three
  in one slot, so it is cheaper than that and costs 0–40 ns more than a single map: its
  keys are 16 bytes rather than 4, and its slots are larger. Either is small beside a
  sample's copy and allocation.
- Lookups by handle (`read_instance`, `get_key_value`, `lookup_instance`'s result) become
  array indexing.
- MD5 key hashes collide as the birthday bound predicts (about 233 expected at 1,000,000).
  Sequential integer keys, whose key hash is the zero-padded big-endian key, did not
  collide up to 1,000,000; other structured keys were not tried. The roadmap's 2% / 90%
  figures hold for keys longer than 16 bytes.
- `ArrayHashMap` is slower from 100,000 instances. Its entry index cannot be a handle once
  an entry is removed (`swapRemove` moves the last entry; `orderedRemove` is O(n)).

## Design

### The registry

One generic type, `HandleRegistry(Key, Value)`, in `src/dcps/`:

- `index: std.AutoHashMapUnmanaged(Key, u32)` from key to slot, and
  `slots: std.ArrayListUnmanaged(Slot)`, each slot holding the key, a generation and the
  `Value`. The registry owns both directions, so they cannot drift. Keys are stored twice
  (16 bytes per entry); an adapted `index` over slot numbers would store them once, if
  memory per instance turns out to matter.
- A handle names a slot: `(generation << 22) | (slot + 1)`. It is positive and never
  `HANDLE_NIL`, and allows 4,194,303 live entries and 512 generations per slot. Resolving a
  handle checks the slot's range and generation, so a stale handle resolves to nothing
  rather than to the slot's next occupant. This is the concurrency architecture's pooled
  identity, `(pool, slot, slot_generation)`, with the registry's entity as the pool
  ([separate identity from order and lifetime](concurrency/architecture.md#separate-identity-from-order-and-lifetime)).
- Freed slots are reused first in, first out, which spreads reuse over every free slot. A
  slot's generation wraps after 512 reuses, after which a stale handle can alias again; the
  DDS spec does not require stale handles to be detected, and never reusing a slot would
  cap an entity at 2^31 instances over its lifetime.
- No custom hash contexts. `std.AutoHashMap` hashes a `Guid` or `[16]u8` with Wyhash over
  its bytes, which handles both key-hash shapes (the measurements above). A key hash must
  not be used as its own hash: for a short key it is mostly zero padding.
- Capacity is bounded by RESOURCE_LIMITS `max_instances` where it applies
  (`design/allocator-strategy.md`). A reader that cannot allocate a new instance rejects
  the sample (`REJECTED_BY_INSTANCE_LIMIT` at the limit, as now); a writer returns
  `OUT_OF_RESOURCES`.
- Each registry is guarded by the lock that guards the tables it replaces.

### Instance registries

One per DataReader and one per DataWriter: the DDS spec scopes an instance handle to the
entity that hands it out. Handles never go on the wire, so there is no interop or IDL
change.

- **DataReader**, under `mu`, keyed by key hash. The slot holds what `seen_instances`,
  `tbf_map` and `owner_map` held, so a sample costs one lookup. A sample registers its
  instance before the filters, as ownership and the writer-instance tracking need it, so
  an instance can have no accepted sample yet (its instance state is then unset).
- **Built-in DataReaders** keep their instances' state in the same kind of registry, keyed
  by the entity's GUID or topic key, but the handle each instance shows is the entity's,
  which the participant passes with the sample (`pushBuiltinCdr`); resolving one scans
  the reader's few instances. Participant and topic samples carried an all-zero key, so
  every participant (or topic) was one instance; they now carry their own. `writer_instances`
  keeps its shape with unique handles. KEEP_LAST and RESOURCE_LIMITS still scan `pending`
  by handle; the registry's live count can replace the O(n²) distinct-instance count.
- **DataWriter**, under `key_registry_mu` (renamed), keyed by key hash. `register_instance`
  allocates; `lookup_instance` returns `HANDLE_NIL` for a key never registered or written;
  the first alive write allocates if needed; `get_key_value` reads the slot. The C ABI
  passes the writer through.
- Neither forgets an instance yet, as today. Reclaiming them (a reader's instance once it
  is not alive, has no samples and is not loaned; a writer's on `unregister_instance`) is
  the follow-on that bounds memory, and the generations make it safe for handles already
  handed out.

### The participant's entity registry

One per participant, under its `mu`. It allocates the handles of everything the
participant names: itself, its publishers, subscribers, topics, DataWriters and
DataReaders, and the participants, endpoints and topics it discovers. An entity with a
GUID is keyed by it; one without (a publisher, subscriber, topic or built-in DataReader) by
a number the participant gives it (`EntityKey`). The participant's own handle is its
registry's first, so the factory's and participant's counters go. Handles are scoped to the
participant: every participant's own handle is the same, and a participant names another
by a handle of its own.

- Built-in readers show its handles on their samples (they are given them with each
  sample), so the built-in topics, `get_matched_*`, `get_discovered_*`,
  `ignore_*` and `SampleInfo.publication_handle` agree.
- A topic's handle is its `discovered_topics` entry's, for its name and type: a Topic
  created here takes that entry's handle, whether the topic was discovered first or not.
  Like the entries, topic handles are not freed.
- A matched endpoint's handle travels with the match (`MatchedWriterInfo.handle`,
  `MatchedReaderInfo.handle`). The reader records it in its match callback, which the
  protocol reader runs before it delivers what the writer sent before the match, and keeps
  it with its other per-writer state (`publication_handles`), so a sample's
  `publication_handle` is found under the reader's own `mu`, with no participant lock on
  that path. The writer does the same for its readers (`subscription_handles`). Both keep
  an endpoint's handle after it is unmatched, as a queued sample or a ready event can
  still name it; a rematch replaces it.
- A GUID's entry is freed once nothing the participant holds names it: it is not a local
  DataWriter or DataReader, nor a discovered participant or endpoint
  (`releaseGuidHandleIfGoneLocked`), so a local endpoint's deletion and its loss can come
  in either order. A handle still held by an application or a queued `SampleInfo` is then
  stale, and `get_matched_publication_data` and the like return `BAD_PARAMETER` for it, as
  for any unmatched writer. An endpoint discovered again gets a new handle.
- `ignore_publication` and `ignore_subscription` record the GUID the handle names, not the
  handle, so an ignore outlives the entry. A handle that names no DataWriter (or
  DataReader) is `BAD_PARAMETER`, as `ignore_participant` and `ignore_topic` already did
  for theirs.
- The two collision workarounds go: `get_matched_subscription_rtps_guid` and
  `get_matched_publication_rtps_guid` no longer return `PRECONDITION_NOT_MET`.
- The participant's matched notification to a reader or writer loses its handle and
  direction arguments, which neither read: the matched status changes in the match
  callbacks above.

## Order of work

1. **This study.**
2. **Instance registries** for DataReader and DataWriter, with `lookup_instance`
   returning `HANDLE_NIL` for unknown keys. Done 2026-11-19; the writer's needs zidl's
   generated Zig code to pass the writer (`registerInstanceRaw(dw, key_hash)`).
3. **The participant's entity registry**, then removing `guidToHandle`, `topicToHandle` and
   their re-export from `dcps/root.zig` (`keyHashToHandle` went in step 2). Done
   2026-11-19.
4. **Follow-ons**, each its own roadmap item: instance reclamation bounded by
   `max_instances`; the linear `discovered_*` lists.

Tests that computed a handle with `guidToHandle` (`api_test.zig`, `ignore_test.zig`,
`matched_status_test.zig`) read it back from a built-in topic sample, or give it with the
match.
