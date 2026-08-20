# discovery example — what it demonstrates

A pub/sub example built around zzdds's DDS-standard *discovery
introspection* operations: `DomainParticipant.get_discovered_topics`/
`get_discovered_topic_data`, `DataWriter.get_matched_subscriptions`/
`get_matched_subscription_data`, and `DataReader.get_matched_publications`/
`get_matched_publication_data`. These let an application inspect what the
discovery protocol has learned — which topics exist, which readers a writer
has matched and their QoS, which writers a reader has matched — a common
building block for monitoring/tooling code, not just internal bookkeeping.

This is `participant-config`'s direct sibling: that example found (and,
as of 2026-08-20, zidl now fixes) a C-ABI struct-layout mismatch affecting
`create_participant_ex`/`set_default_participant_config`/
`get_default_participant_config`, and confirmed via a standalone C probe
that the same *string-layout* half of the bug (independent of
`--zig-generate-toml-config`) also affects `TopicBuiltinTopicData`/
`PublicationBuiltinTopicData`/`SubscriptionBuiltinTopicData` — the three
struct types these operations return. `participant-config`'s own scope
stopped at the `zzdds.idl` operations it happened to be exercising when it
found the bug; this example exists to give the `dcps.idl` half — the three
operations above — the same real, cross-language regression coverage,
closing out the full affected-operation list from
`zzdds/docs/roadmap.md`.

## The type

```idl
@appendable
struct DiscoveryPing {
    int32 count;
};
```

Topic name `DiscoveryPing`. Deliberately minimal, like `participant-config`
— this example is about the discovery operations, not the data type, so
the type stays out of the way.

## Publisher / subscriber flow

Both processes create a plain participant (no config-file/programmatic
config split here — that's `participant-config`'s job), register
`DiscoveryPing`'s TypeSupport, and create their topic.

**Publisher:**

1. Right after `create_topic`, calls `get_discovered_topics` +
   `get_discovered_topic_data`, asserting the returned `name`/`type_name`
   match. This succeeds immediately, with no remote peer needed — a
   participant registers its own locally-created topics into its
   discovered-topics table right away (see zzdds's
   `src/dcps/participant.zig`, `vtCreateTopic`'s comment). Prints
   `Discovery OK (participant): topic.name='...' topic.type_name='...'`.
2. Creates its `DataWriter`, waits for the reliable-reader-ready handshake
   (same idiom as `hello_world`/`participant-config`), then calls
   `get_matched_subscriptions` + `get_matched_subscription_data`, asserting
   the matched subscription's `topic_name`/`type_name` match. Prints
   `Discovery OK (writer): matched_subscription.topic_name='...'
   type_name='...'`.
3. Writes 3 samples, then shutdown-gates on the matched count returning to
   zero (same idiom as `hello_world`).

**Subscriber:**

1. Creates its `DataReader`, then polls `get_matched_publications` (bounded
   timeout, same "wait for X" idiom as every other polling loop in this
   project) until a publication has matched, then calls
   `get_matched_publication_data`, asserting the matched publication's
   `topic_name`/`type_name` match. Prints `Discovery OK (reader):
   matched_publication.topic_name='...' type_name='...'`.
2. Reads 3 samples in order.

Required stdout markers: `Create topic:`, `Create writer/reader for
topic:`, `Discovery OK (participant):`, `Discovery OK (writer):`,
`Discovery OK (reader):`, 3× `Publisher: wrote count=`/`Subscriber:
received count=`, `Publisher: done.`/`Subscriber: received all 3 samples
in order.`.

## Why this needed its own example, not just more assertions in participant-config

Per this project's own example-design criteria: a common feature, a
testable outcome, and not so much machinery that the "example" part gets
hard to follow. Discovery introspection is a genuinely distinct feature
from participant/factory configuration (different interfaces —
`DomainParticipant`/`DataWriter`/`DataReader`, not
`DomainParticipantFactory` — and a different part of the DDS spec
entirely), so folding it into `participant-config`'s own pub/sub flow would
have made that example's "one clear thing" harder to follow. Splitting it
out also means each example's failure mode stays unambiguous: if
`participant-config` passes but `discovery` fails (or vice versa), that by
itself narrows down which operation family broke.

## Ownership: ports differ here, and that's expected

`topic_data`/`subscription_data`/`publication_data`'s string fields
(`name`, `topic_name`, `type_name`) are **borrowed** slices in the native
Zig call path — zzdds's own vtable implementations
(`vtGetDiscoveredTopicData`/`vtGetMatchedSubData`/`vtGetMatchedPubData`)
hand back slices into storage zzdds itself owns, valid for the matched
entity's lifetime, not a fresh caller-owned copy. `zig/discovery` never
calls `.deinit()` on these structs as a result — doing so would free memory
it doesn't own.

Crossing the C ABI changes this: the C-ABI mirror conversion
(`{Name}FromCAbi`/`{Name}ToCAbi`, see the fix writeup below) always
allocates a fresh, caller-owned copy via `std.heap.c_allocator` when
writing into the mirror struct, regardless of whether the internal value
was borrowed or owned. So `c`/`cpp`/`java`'s ports **do** need to free what
`get_discovered_topic_data`/`get_matched_subscription_data`/
`get_matched_publication_data` write back (`DDS_TopicBuiltinTopicData_free`
and friends) — see each port's own README/source for exactly where.

## The bug this closes out (see `participant-config` and `zzdds/docs/roadmap.md` for the full writeup)

`participant-config` found and zidl now fixes a C-ABI struct-layout
mismatch with two independent halves: a `_toml_applied`-bookkeeping-field
offset shift (only affects `--zig-generate-toml-config` types, i.e.
`zzdds.idl`'s `DomainParticipantConfig` family), and a plain-`string`
representation mismatch (`[]const u8` internally vs. `char *` in the public
header) that affects **any** struct with an unbounded string field,
independent of toml config entirely. `TopicBuiltinTopicData`/
`PublicationBuiltinTopicData`/`SubscriptionBuiltinTopicData` (`dcps.idl`,
never touched by `--zig-generate-toml-config`) hit only the second half —
confirmed for real via a standalone C probe against
`DDS_TopicBuiltinTopicData_free` before this example existed, but never
exercised per-operation until this example actually calls
`get_discovered_topic_data`/`get_matched_publication_data`/
`get_matched_subscription_data` for real.

The fix (zidl's C-ABI mirror-struct mechanism, `structNeedsCApiMirror` in
`src/backend/zig.zig`) generalizes over both triggers — a struct needs a
mirror if this invocation added `_toml_applied` to it *or* it has an
unbounded string anywhere in its field tree — so the same mechanism that
fixed `participant-config`'s three operations covers these three too, with
no extra per-struct handling. This example is that claim's regression test.

## A pre-existing flake, not caused by this example

While verifying `java/discovery`, `on_reliable_reader_ready` intermittently
never fired on the publisher side (~2/7 runs), even though the subscriber
had genuinely matched (`get_matched_publications` returned non-empty and
`Discovery OK (reader):` printed correctly). A/B tested against
`java/participant-config` (no discovery calls at all, already verified
working earlier the same session) with 5 back-to-back runs on fresh
domains: 3/5 failed with the identical `FAIL: no reliable reader became
ready within 10s`. Same failure, same rate, zero relation to this
example's code — this is pre-existing Java reliable-reader-ready timing
flakiness in this sandbox under repeated back-to-back JVM startups, not a
bug in `get_discovered_topics`/`get_discovered_topic_data` or this
example. Matches the already-closed "hdds/CoreDX CoherentSets flake" precedent
(write-timing variability, not a zzdds correctness issue) — noted here for
the record, not chased further. Re-running (or giving the subscriber a few
more seconds to start before launching the publisher) reliably passes.

## Deliberately out of scope

A `run.py`-style automated harness comparing pass/fail across all four
bindings — same reasoning as `participant-config`: worth adding once
everything reliably passes everywhere as a baseline to protect.
Configuration-file-driven discovery timing knobs (SPDP period, lease
duration, ...) — that's `participant-config`'s territory, not this
example's.

See each language's own README (`zig/discovery`, `cpp/discovery`,
`c/discovery`, `java/discovery`) for build and run instructions.
