# Changelog

Notable changes to Zenzen DDS, newest first. For current capability and known limitations
see [`docs/implementation_status.md`](docs/implementation_status.md); for planned work see
[`docs/roadmap.md`](docs/roadmap.md); for stable design decisions see
[`docs/decisions.md`](docs/decisions.md).

Dated entries (no release tags past `v0.2.1-zig.0.16.0`; `build.zig.zon` is
`0.2.1-zig.0.16.0-dev`).

## 2026-11-01

- CI runs the examples and every integration-test scenario on a `-Dshared-runtime` build
  too, on Linux and Windows.
- The wait-for-historical-data subscribers confirm the historical batch by taking it from
  the reader once `wait_for_historical_data()` returns, attaching their listener only
  afterwards. The call promises the samples are in the reader, not that
  `on_data_available` has run, which on the shared runtime happens later.

## 2026-10-31

- A local DataWriter's or DataReader's SEDP announcement and disposal can no longer fail
  once it exists. Discovery reserves what both need when the endpoint is created (and
  again at `enable()`, should its Publisher's or Subscriber's partitions or presentation
  have changed): creation returns nil, and `enable()` RETCODE_OUT_OF_RESOURCES, when it
  cannot. A failed announcement used to be only logged, and the endpoint never announced;
  a disposal that could not be encoded was dropped.
- An endpoint deleted while its announcement is being written is disposed of once, after
  the announcement. Peers used to be able to see it announced again after its disposal,
  then disposed a second time.
- A matched remote endpoint announced again with QoS or partitions that no longer match a
  local endpoint is unmatched from it (`on_*_matched`, with REQUESTED/OFFERED
  _INCOMPATIBLE_QOS for a QoS mismatch). It used to stay matched.
- The discovery plugin interface's `announce_writer`/`announce_reader` are split into a
  fallible `prepare_*` and an infallible `announce_*(guid)`.
- The shared runtime's readiness backend, and UDP and TCP on it, now run on Windows
  (`-Dshared-runtime`): the backend polls with `WSAPoll` and wakes through a loopback
  socket, sockets on it are nonblocking, and sends take the builder's gather list
  (`WSASendTo`, `WSASend`) instead of UDP flattening it into one buffer.
- The C and C++ enable-defer peers time their premature-match window by a monotonic
  clock rather than by counting sleeps, which on Windows overran it into the enable.

## 2026-10-30

- Build the prebuilt C/C++ library bundles `-Doptimize=ReleaseSafe` on all platforms
  instead of Zig's default Debug, and run the test suite in ReleaseSafe in the release
  workflow. A Debug `zzdds.dll` overflowed the 1 MiB default main-thread stack of an
  MSVC-built consumer inside `zzdds_create_factory()`.
- The bundle's `zzdds-config.cmake` names `bin/zidl.exe` on Windows, so
  `find_package(ZZDDS)` configures there. The release workflow now runs the full
  bundle consume check on Windows: CMake consumer and C/C++ hello_world built with MSVC
  against the relocated bundle, and the hello_world pairs run.
- Run the integration-test scenarios on Windows as well as Linux in CI. Their Zig ports
  (and the stress tests) read arguments through the portable
  `std.process.Args.Iterator.initAllocator`, their C/C++ ports build with MSVC, and the
  runners find `.exe` binaries and CMake's `Debug/` outputs.
- Windows GUID prefixes now come from the system RNG (`ProcessPrng`) instead of a
  fallback PRNG seeded only from the performance counter, and `host_based` GUIDs carry
  the real process ID on Windows instead of 0.

## 2026-10-28

- Add optional resource provider bindings: explicit per-participant selections,
  pinned preparation, exact Minimal identifiers/capabilities, compiled adapters and
  checked provider writes. Add multi-library startup with artifact hashes and an
  offline validate/plan versus native inspect example. Keep the zidl pin unchanged.

- Pin zidl v0.3.23-zig.0.17.0 and enable the shared runtime configuration reader
  by default, preserving resolver compatibility and allocator contracts. Keep
  `-Dconfig-authoring=false` as an explicit legacy fallback.
- Run resource authoring and configuration qualification against the released
  dependency in the native Debug/ReleaseSafe matrix and Linux ThreadSanitizer job.
  Include the optional frontend in LLVM coverage and Valgrind artifacts.
- A factory whose participant was deleted creates a working participant again
  with the same RTPS discovery plugin. The plugin gave the new participant the
  deleted one's SPDP and SEDP state instead of fresh state: the earlier
  announcement, built-in writers and readers were leaked and its peers kept.
- A discovery plugin serves one participant at a time: creating a second
  participant while another uses the factory's plugin now fails, instead of
  taking over the running participant's discovery, and deleting a participant
  whose discovery never started no longer stops another's.
- A participant whose `enable()` fails after its discovery started now stops
  what started, so `enable()` can be called again.

## 2026-10-27

- Add a development-only runtime configuration adapter (`-Dconfig-authoring=true`)
  preserving existing resolver policies, with strict diagnostic companions and
  conditional `_setting` support. Keep the released zidl pin and default path.

- Extend the existing TOML parser with located records/arrays, quoted names, strict
  duplicates and owned failure cleanup. Preserve its legacy accessor API.
- Add experimental resource authoring with generated presence-aware records,
  single-base writer/reader QoS profiles and provenance into concrete builder plans.
  Development requires the coordinated zidl changes via an explicit local-source
  override; the released dependency pin remains unchanged.

## 2026-10-26

- Recover endpoint discovery after a participant is lost and rediscovered. A
  lost participant's SEDP and WLP built-in proxies are now dropped with it, so
  its endpoint announcements are delivered again when it returns; before, they
  counted as already received and its endpoints stayed unmatched.
- A liveness probe that times out no longer drops the peer's SEDP built-in
  proxy itself: SPDP decides whether the participant is lost. A peer that
  re-announced meanwhile kept its participant but lost that proxy, so endpoints
  created later on this side never reached it.
- Report each participant's discovery and loss to DCPS and SEDP in the order
  they happened, so a loss reported late cannot undo the rediscovery after it.
- A reader's ACKNACK count no longer restarts when a writer is matched again.
  A writer ignores counts no higher than the last one it acted on, so after a
  rematch that only this side saw, the writer ignored the reader until its
  count climbed back past the old one, which could take hours.
- Add opt-in experimental programmatic resource plans and whole-graph construction
  with static type bindings, bounded validation, reentrant cancellation and retryable
  cleanup. Includes generated-type writer/reader acceptance fixtures and native CI;
  configuration frontends, provider libraries and XRCE integration remain follow-ons.

## 2026-10-24

- Run TCP user data on the shared runtime (`-Dshared-runtime`, POSIX). A participant
  with TCP enabled no longer fails creation there: its listen socket and connections
  are sources of the runtime's readiness backend, so `drive()` alone runs a reliable
  pair over TCP with no thread started by zzdds, and hosted workers service the
  connections in place of an accept thread and a thread per connection. Dials and sends
  never block there, and a writer whose connection fills resumes once it drains. TCP
  sends now take the message builder's gather list without flattening it, in every
  build.

## 2026-10-23

- Free a UDP socket or TCP connection that closes once nothing uses it, rather than
  keeping it until its transport closes, so a long-running process no longer grows with
  interface changes or reconnecting TCP peers. A channel naming a freed socket or
  connection still fails with `ChannelClosed`, also after its slot is reused.

## 2026-10-22

- Keep a writer operation reference across typesupport validation and hashing;
  concurrent deletion now leaves the in-flight write safe to return AlreadyDeleted.
- Preserve legacy RTPS endpoint kinds for registrations that omit keyedness,
  including the pinned dds-rtps adapter. Use explicit generated keyedness in the
  handwritten Zig examples, and retain descriptor-based kinds for loaded providers.
- Quiesce allocator-injection test fixtures before replacing their allocator and
  distinguish generation retirement from OS image residency in the macOS checks.

- Pin zidl v0.3.22-zig.0.17.0 and use its released generator and ABI helpers with
  `-Dtypesupport-library=true`. Native qualification no longer needs a separate
  zidl checkout; explicit local overrides remain available for development.
- Collect coverage from the LLVM test builds using stock elfutils, and fail CI
  on collector errors or empty reports instead of uploading partial results.
- **History a lost writer never delivered is now reported in SAMPLE_LOST.** When a
  TRANSIENT_LOCAL writer (or its participant) went away before a late-joining reader
  had all of its history, `wait_for_historical_data` returned OK, since that history can
  no longer arrive, but nothing recorded the shortfall. The samples its first HEARTBEAT
  announced and the reader never received, including any held back behind a missing
  one, are now added to the reader's SAMPLE_LOST status, as they already are when a
  writer reports history it no longer has. A writer lost before its first HEARTBEAT
  reaches the reader still reports nothing, since the reader never learned how much
  history it had.

## 2026-10-20

- Add opt-in experimental typesupport library loading, explicit export selection,
  immutable participant registration and reference-counted generation retirement.
  Existing readers retain their provider through deferred teardown; candidate
  replacement affects future selections. Include checked sample/key processing for
  complete DATA, reassembly and prematch input, and validated registered writes.
  See `docs/typesupport-libraries.md` for opt-in usage and limits.
- Add a runnable two-library inspection/pub/sub example with separate-process UDP
  checks and an optional independent Fast DDS subscriber. Derive registered
  writer/reader RTPS entity kinds from type keyedness, so keyless topics match
  peers that enforce the endpoint kind.
- Separate provider ownership from OS loading, add macOS/Windows backends and a
  static-only build option. Require absolute artifact paths and restrict Windows
  DLL dependency search. Add linked-provider C ABI, allocation-failure and native
  unload checks plus a native platform qualification workflow. Non-Linux
  native qualification remains pending. Build IDL generators for the build host
  when cross-compiling DDS.
- Fix C-ABI typesupport adapter cleanup on registration allocation failure: the
  participant already consumes the adapter, so the shim must not destroy it again.
  Run legacy typesupport cleanup outside the participant lock.
- **A RELIABLE write blocked on RESOURCE_LIMITS can now succeed, and blocks for
  `max_blocking_time`.** A writer never dropped acknowledged samples from its history, so a
  RELIABLE KEEP_ALL writer that reached `max_samples` stayed full: each later write polled
  for a fixed 10 s and returned TIMEOUT however quickly its readers acknowledged. A RELIABLE
  VOLATILE writer now drops a sample once every matched reliable reader has acknowledged it
  (a TRANSIENT_LOCAL writer keeps its history for readers that match later, and a
  BEST_EFFORT writer is unchanged). A write that finds the history full waits, without
  polling, for acknowledgments to free space, for up to `reliability.max_blocking_time`,
  then returns TIMEOUT. A Publisher's default DataWriter QoS now has the DDS default
  `max_blocking_time` of 100 ms (it was 0, which the write ignored). Code that builds a
  `DataWriterQos` from scratch gets 0: such a write fails at once when the history is full.

## 2026-10-18

- **Deleting an endpoint while it is being announced no longer reads freed memory.**
  `enable` on a disabled DataWriter or DataReader captured its SEDP announcement under the
  participant's lock and wrote it after releasing it, still reading the endpoint's QoS,
  partition and topic storage. A `delete_datawriter`/`delete_datareader` in between freed
  that storage, and its disposal could reach peers before the announcement, leaving them
  with a deleted endpoint they took for alive. The announcement now has its own copy, and
  one overtaken by a deletion is followed by another disposal. An endpoint also joins its
  Publisher or Subscriber before it is announced, so a matched callback raised during
  creation gets an endpoint `lookup_datawriter`/`delete_datawriter` can find; if that
  callback deletes it, creation returns nil rather than the freed endpoint. Only the
  `enable` call that enables an endpoint announces it. In-process discovery
  (`DirectDiscovery`) now keeps its own copy of the announcements it stores rather than
  the caller's, and each announcement works from copies of the peers' endpoints, so a
  retraction meanwhile cannot free what it is reporting.
- **Fixed an intermittent "only 9/10 historical samples" failure in the catchup example.**
  Each subscriber counted the samples its listener had taken as soon as
  `wait_for_historical_data` returned, but that call waits for the samples to reach the
  reader, not for a listener to take them. The subscribers now take the historical batch
  themselves after the call returns, then attach the listener for the live batch.
- **DATA_AVAILABLE now resets as DDS specifies.** A reader's DATA_AVAILABLE status stayed
  set until a read or take left its cache empty, and `on_data_available` never reset it.
  So a StatusCondition on DATA_AVAILABLE stayed triggered while samples remained, and one
  whose application read without taking woke immediately on every wait. Every read and
  take variant now resets it, and `on_data_available` claims it before running, as the
  other statuses are claimed: a change during the callback stays pending, and a callback
  whose change a read or take already consumed doesn't run (including from
  `Subscriber::notify_datareaders`, which no longer calls readers with nothing new). An
  application that takes only part of what is available and waits on DATA_AVAILABLE again
  now waits for new data; it should wait on a ReadCondition instead
  (`docs/design/concurrency/listeners.md#reader-data-available-reset`).

## 2026-10-17

- **A remote endpoint lost while its match was being made is no longer matched.**
  Discovery decided a match under the participant's lock and added the proxy after
  releasing it, so the same remote endpoint's loss, or a newer announcement of it, could
  come first. The match then went ahead anyway: a reader kept a proxy (and per-writer
  state) for a writer already gone, or a writer for a reader already gone, and an older
  announcement could overwrite a newer one's ownership strength, lifespan or liveliness
  lease. A writer lost that way was also marked as matched for the pre-match hold, so if it
  came back, what it sent before being matched again was not held for the readers that then
  matched it. Each announcement of a remote endpoint now gets a discovery generation, and
  its matches are installed only while that generation is current; a loss withdraws it
  (`docs/design/concurrency/architecture.md#remote-endpoint-match-and-loss`). A reader's
  per-writer state, and both sides' matched status, now change in the same step as the
  proxy, so `current_count` follows the proxies exactly. `on_liveliness_changed` now fires
  when a live writer is unmatched.
- **A plain status change can no longer be lost while its listener runs.** DataReader and
  DataWriter status listeners (`on_subscription_matched`, `on_publication_matched`,
  `on_requested_incompatible_qos`, `on_offered_incompatible_qos`, `on_sample_lost`,
  `on_sample_rejected`, `on_liveliness_changed`, `on_liveliness_lost`,
  `on_requested_deadline_missed`, `on_offered_deadline_missed`, whichever level of the
  listener chain handles them) reset the status's change counts and changed flag after the
  callback returned. A change that arrived during the callback was therefore lost: no
  getter, StatusCondition or later callback ever saw it. The status is now taken and reset
  together, before the callback runs, as DDS 1.4 §2.2.4.2.1 specifies. A change during the
  callback stays pending, so the `*_change` fields are exact. A getter called inside the
  callback now sees the status already reset, and a StatusCondition is no longer briefly
  triggered by a status a listener takes.

## 2026-10-13

- **GROUP End Coherent Set markers never carry `PID_COHERENT_SET`.** Readers of one other
  implementation, which rejects a DATA with neither payload nor inline QoS, get end markers
  with `PID_COHERENT_SET = SEQUENCENUMBER_UNKNOWN` (RTPS 2.5 §9.6.4.2 Table 9.22, Example
  2). They now get it only on TOPIC/INSTANCE-scope markers: a GROUP marker always carries
  the §8.7.6 group parameters, and that reader accepts it without `PID_COHERENT_SET`.
- **CI: known interop failures don't fail the vendor-interop jobs.**
  `.github/interop-known-failures.toml` lists dds-rtps tests by vendor, direction and
  reason; `scripts/check_interop_results.py` reports a listed failure as a warning and in
  the job summary instead of failing the job, unless its output shows a sanitizer report
  or a crash, and flags a listed test that passed so the entry can be removed. The first
  entry is the four GROUP-publisher, GROUP-subscriber `CoherentSets` tests with zzdds
  publishing to one other implementation, whose subscriber delivers nothing from the
  RTPS 2.5 form (see `docs/implementation_status.md`).

## 2026-10-12

- **Data that arrives before its writer is matched is held once per participant, and
  only until discovery settles that writer.** Each reliable reader used to keep its own
  copies of data from writers it had not matched. That was up to 64 samples from each of
  32 writers, with no limit on partly reassembled samples and no expiry. Data sent to
  every reader, as multicast data is, includes writers on other topics, and stayed in
  every reader until the reader was deleted. Now the participant holds one copy for all
  its readers, and only from writers discovery has not yet announced and matched against
  them. Each reader that then matches the writer takes the data, in sequence-number
  order, ahead of anything the writer sends next; best-effort readers now get it too.
  - **When it is dropped:** once discovery has matched the writer against every local
    reader, when the writer or its participant is lost, or one lease duration of the
    writer's participant after it arrived. While that participant is undiscovered, this
    participant's lease is used. Either way it is at most 5 minutes.
  - **Bounds:** 16 MiB, 256 writers, and 64 samples plus 8 partly reassembled samples per
    writer.
  - **Built-in discovery readers no longer hold it:** a discovery announcement that
    arrives before its sender's participant is discovered is dropped, and a reliable
    discovery reader gets it by repair once matched.
- **GROUP coherent sets carry `PID_GROUP_COHERENT_SET` to every reader.** Since
  2026-10-09, readers from two other implementations got GROUP sets without it, picked by
  vendor id, because their subscribers delivered nothing from sets carrying it. RTPS 2.5
  §8.7.6 requires it on every sample and End Coherent Set marker of a group set, so zzdds
  now sends it to them too. Those subscribers deliver nothing from zzdds GROUP sets again;
  before, they took each writer's part as its own set, and a group set could be split
  across two reads.

## 2026-10-10

- **A reliable writer resends only the sequence numbers an ACKNACK requests.** A
  non-final ACKNACK used to make it resend every cached sample and end marker from the
  ACKNACK's base up, whether the reader had asked for them or not. Against a reader that
  kept asking for an SN it would never accept, that meant resending the whole history
  on every ACKNACK. An ACKNACK requests exactly the SNs in its bitmap; a non-final one
  that requests none now draws a HEARTBEAT (capped at the history floor while a
  `TRANSIENT_LOCAL` reader's live data is held back), and the reader NACKs what it lacks
  from that.
- **A `BEST_EFFORT` DataReader never delivers a sample out of order, and sends no
  ACKNACKs.** It used to drop only exact duplicates, so a sample older than one it had
  already delivered was still delivered. It now drops any sample at or below the highest
  sequence number it has received from that writer (RTPS 2.5 §8.4.12.1.4). It also used
  to send one ACKNACK on matching, which made a `TRANSIENT_LOCAL` writer replay its
  history a second time; a best-effort reader sends none (§8.4.2.3), and a writer ignores
  any that arrive. To keep that history from being dropped as out of order, a
  `TRANSIENT_LOCAL` writer now sends a newly matched best-effort reader its history in
  sequence-number order, holding live samples to that reader until the history has gone
  out. A best-effort reader that matches the writer after the writer has sent its history
  no longer gets a second chance at it, but gets what arrived before the match (see
  2026-10-12).

## 2026-10-09

- **A DataReader that matches while a coherent set is being written gets that set
  whole.** The set isn't published until `end_coherent_changes`, after the match, but a
  zzdds writer treated it as already written:
  - A `TRANSIENT_LOCAL` reader was held back as though the set were history, so the
    set's samples, end marker and HEARTBEAT skipped it, and its NACKs for the set were
    refused. The set reached it only through the periodic HEARTBEAT, two sets per burst:
    the late topic ran a set behind (the intermittent dds-rtps `Test_CoherentSets_21`
    failure with zzdds publishing). A reader is now held back only for samples already
    sent, and is sent the set-end HEARTBEAT even while held back.
  - A `VOLATILE` reader started at the writer's next sequence number, inside the set,
    and then received the set's samples below that start. It now starts at the set's
    first sample.
  - HEARTBEATs answering an ACKNACK no longer announce an open set's samples. A reader
    NACKed them, the writer refused, and each NACK drew the same HEARTBEAT until the set
    ended.

## 2026-10-07

- **Exclusive ownership no longer switches to a weaker writer right after matching.** A
  DataReader with `EXCLUSIVE` ownership recorded a writer's strength only after the
  writer's samples could already arrive, and kept the owner's strength from when it
  claimed an instance. A stronger writer whose first sample came first claimed the
  instance at strength 0, lost it to a weaker writer, then took it back, so the reader
  delivered samples from both (the intermittent dds-rtps `Test_Ownership_3` failure). The
  strength (and lifespan) is now recorded before the writer's samples can arrive, and the
  owner's current strength is used when comparing.

Coherent sets now follow RTPS 2.5 §8.7.6 end to end.

- **A HEARTBEAT no longer ends a coherent set.** With `coherent_access`, a zzdds
  subscriber committed a writer's in-progress coherent set whenever a HEARTBEAT said it
  had every sample written so far, until that writer's first end-of-set marker. Writers
  that send each sample as it is written (zzdds's own writer holds a set until it ends)
  send HEARTBEATs in the middle of a set, so the first sets from them were split across
  `begin_access`/`end_access` cycles; in GROUP scope that could also leave one reader a
  set behind the others. A set now ends only as RTPS 2.5 §9.6.4.2 defines: an end-of-set
  DATA, a sample of another set, or a sample without `PID_COHERENT_SET`. This was the
  cause of most `Test_CoherentSets_10`–`12` interop failures with zzdds as the subscriber.
- **Incomplete coherent sets are discarded.** A subscriber now checks that every sequence
  number from a set's first sample up to the change that ends it arrived, and discards the
  set otherwise, as §8.7.6 requires. That includes the partial set a reader receives when
  it matches in the middle of one, which used to be delivered. A sample the reader drops
  itself (ownership, time or content filter, resource limits) still counts as arrived.
- **End-of-set markers are kept and sent again.** When a reader NACKed a set's end
  marker, the writer GAPed it, and it announced that GAP with every set, so a reader that
  missed the marker could not tell whether the set was complete. Writers now keep each
  marker until its set's samples are gone from the writer's cache and every reliable
  reader acknowledged it, resend it on NACK, and include it in history replay. Best-effort
  history replay also left out the samples' coherent-set inline QoS, best-effort readers
  ignored end markers, and a fragmented sample lost its coherent-set inline QoS on
  reassembly; all three are fixed.
- **GROUP coherent sets use the RTPS 2.5 wire format.** `PID_GROUP_COHERENT_SET` and
  `PID_GROUP_SEQ_NUM` are sent as `0x0063` and `0x0064` again. Since 2026-06-20 they had
  been sent as `0x0039` and `0x0038`, values RTPS 2.5 does not define, so other
  implementations ignored zzdds's and zzdds ignored theirs. Every sample of a group set now
  carries the set's id (the group sequence number of its first sample, where zzdds used
  to send the last one on the last sample only) and `PID_WRITER_GROUP_INFO`. Every writer
  of the publisher, including one that wrote nothing in the set, ends it with an End
  Coherent Set marker. zzdds v0.3.6 and earlier don't read the new ids and keep pairing
  sets by position. Subscribers from two other implementations were observed to deliver
  nothing at all from GROUP sets carrying `PID_GROUP_COHERENT_SET` that end with these
  markers; readers from those vendors got the sets without it, as each writer's own
  coherent set, which is how they handled zzdds sets before (removed 2026-10-12).
- **GROUP-scope subscribers assemble group sets by id.** `begin_access` used to pair each
  reader's oldest coherent set, so a reader that matched later than its siblings stayed a
  set out of step with them. It now exposes a publisher's group set once every one of its
  writers matched to the subscriber is done with that set, and discards the whole set if
  any part is incomplete. A part still arriving holds its set back however long it
  takes. Sets from writers that send no group set id are still paired by
  position.

## 2026-10-05

- **ContentFilteredTopic filter expressions can be changed in place.** New zzdds extension
  `zzdds::ContentFilteredTopic::set_filter_expression(expression, parameters)`; DDS only
  allows changing a CFT's parameters. Readers on the topic keep their matches, history and
  reliable readiness; the new filter applies to samples received afterwards. A malformed
  expression returns BAD_PARAMETER and leaves the filter unchanged. Available in every
  binding: C via `DDS_ContentFilteredTopic_as_zzdds_ContentFilteredTopic`, C++ by
  `dynamic_pointer_cast` to `zzdds::ContentFilteredTopicImpl`, Java via
  `ZzddsRuntime.asZzddsContentFilteredTopic`, and Zig via
  `zzdds.asZzddsContentFilteredTopic`.
- **Listeners no longer run while zzdds holds one of its own locks.** A listener that
  called back into its entity, its parent or its participant could deadlock. Affected:
  - `on_data_available`, `on_sample_rejected`, `on_sample_lost` and
    `on_liveliness_changed`, raised while the participant's lock and the protocol reader's
    lock were held during message processing (DATA, DATA_FRAG, GAP, HEARTBEAT) or while a
    newly matched writer's buffered samples were delivered;
  - `on_reliable_reader_ready`, raised from ACKNACK processing under the participant's
    lock;
  - `on_requested_incompatible_qos` and `on_offered_incompatible_qos`, raised during
    discovery under the participant's lock;
  - `on_publication_matched` for a remote reader that went away, raised under the
    participant's lock;
  - `on_data_available` raised by `Subscriber::notify_datareaders`, under the
    subscriber's lock;
  - discovery and liveliness callbacks driven by the built-in SEDP and WLP readers, which
    ran under those readers' locks.

  Each is now collected under the lock and raised after it is released, in the same
  order as before. Releasing a listener's data during `delete_contained_entities` can
  still run under the parent's lock; see the roadmap.
- **Fixed a possible use-after-free when deleting a DataReader.** Deleting a reader
  could free it while the receive thread was still delivering to it (data,
  sample-lost, heartbeat or end-of-coherent-set callbacks). The protocol reader now
  keeps its DataReader alive until it is torn down itself, as it already did for the
  reliable-readiness callback.
- **Fixed memory leaks in the filter-expression parser.** A malformed expression that
  failed after a complete operand (e.g. `x = 1 AND`), or running out of memory while
  parsing, leaked the part of the expression already parsed. Affected
  `create_contentfilteredtopic` and QueryCondition creation.

## 2026-10-03

- **Fixed a writer or reader that could stay at zero matches.** `create_datawriter` and
  `create_datareader` add the new endpoint to the participant before registering its
  matched-status callback, then announce it, which is where it is matched. A remote
  endpoint discovered in that window was matched without the callback, so the
  announce's match was a repeat and the matched status (and `on_publication_matched` /
  `on_subscription_matched`) never counted it. Exposed by the 2026-10-02 change that
  reports only new matches; before it, the repeat counted. Discovery now skips an
  endpoint until its callback is registered, leaving the match to the announce. Seen as
  an intermittent `rmw_service_server_is_available` timeout in rmw_zzdds's conformance
  tests: the client's request writer never counted the service's request reader.
- **A sample's publisher GUID resolves as soon as the sample can be taken.** A RELIABLE
  reader buffers DATA that arrives before it has matched the writer, and adding the
  match delivers it before the writer-matched callback that recorded the writer's GUID,
  so `get_matched_publication_rtps_guid` for that sample's `publication_handle` could
  return NO_DATA. The reader now records the GUID when each sample arrives. Seen as an
  intermittent "failed to resolve the publisher RTPS GUID" in rmw_zzdds's
  `take_sequence` conformance test.

## 2026-10-02

- **zidl pinned to v0.3.20.** Generated C++ and Java now accept an imported file's
  subtypes wherever an operation takes a base entity type from that file, which the new
  extension operations below need: `create_datareader_ex` takes a `DDS::TopicDescription`,
  and passing a `ContentFilteredTopic` or `Topic` crashed the Java binding before this fix.
- **Extended listeners can be installed at creation.** New zzdds extension operations
  `zzdds::Publisher::create_datawriter_ex` and `zzdds::Subscriber::create_datareader_ex`
  take a `DataWriterListenerEx` / `DataReaderListenerEx` and a mask. A remote endpoint
  discovered earlier matches inside entity creation, so an extended listener installed
  afterwards with `set_listener_ex` could miss `on_publication_matched` /
  `on_subscription_matched` and the reliable-ready callbacks. Available in every binding:
  C via the new `DDS_Publisher_as_zzdds_Publisher` / `DDS_Subscriber_as_zzdds_Subscriber`
  upcasts, C++ by `dynamic_pointer_cast` to `zzdds::PublisherImpl` /
  `zzdds::SubscriberImpl`, Java via `ZzddsRuntime.asZzddsPublisher` / `asZzddsSubscriber`,
  and Zig via `zzdds.asZzddsPublisher` / `asZzddsSubscriber`.
- **C++: extended-listener callbacks receive the application's own entity object.** The
  `DataWriterListenerEx` / `DataReaderListenerEx` bridges wrapped the writer or reader in a
  plain `DDS::DataWriterImpl` / `DDS::DataReaderImpl`, replacing the cached wrapper, so
  the callback's entity was a different object from the one the application held and did
  not upcast to `zzdds::DataWriterImpl` / `zzdds::DataReaderImpl`. All generated C++ now
  uses zzdds's wrapper classes, which publishers and subscribers also get, so they upcast
  to `zzdds::PublisherImpl` / `zzdds::SubscriberImpl`.
- **Matched statuses are no longer double-counted.** When the participant re-reported a
  writer/reader pair (direct discovery replays readers on each writer announcement; SEDP
  re-delivers on updates), `total_count` and `current_count` in
  `PublicationMatchedStatus` / `SubscriptionMatchedStatus` grew again and the matched
  callback fired again. A match is now reported only when the RTPS layer adds a new
  proxy for the remote endpoint; a repeated report just refreshes the existing proxy. A
  match whose proxy could not be added is no longer reported either; previously its count
  never came back down.
- **Fixed intermittent "never matched" failures in examples and integration tests.** The
  apps created writers and readers without a listener and installed it afterwards, losing
  the matched callback whenever discovery finished first. Every app now passes its
  listener at creation, using the new extension operations where it needs the
  reliable-ready callbacks.

## 2026-10-01

- **zidl pinned to v0.3.19: XCDR2 encoding fixes for user types.** Generated code now
  writes the XCDR2 collection DHEADER before sequences, arrays and maps of non-primitive
  elements (strings, enums, bitmasks, structs, unions), as the XTypes specification and
  other implementations require; earlier output omitted it, so such members did not
  interoperate under XCDR2. Also from this release: nested sequences and sequences of
  array typedefs generate correctly in every binding, `@appendable`/`@mutable` top-level
  types use the D_CDR2/PL_CDR2 representation identifiers, EMHEADER length codes 5-7 are
  decoded, and minimal TypeObject hashes match other implementations. XCDR1 encodings and
  types without such members are unchanged.
  **C++ API change:** generated typed-reader condition methods (`read_w_condition`,
  `take_w_condition`, `*_next_instance_w_condition`) now take
  `std::shared_ptr<DDS::ReadCondition>` instead of a raw C `DDS_ReadCondition` handle; a
  `QueryCondition` passes directly. The C++ waitset example is updated accordingly.
- **Concurrency and discovery-broker specifications.** Contracts under
  `docs/design/concurrency/` and `docs/design/broker/`, indexed by
  `docs/design/concurrency-broker-status.md`, with the draft broker schema, independent
  wire vectors and a generated-codec probe checked by `zig build test-design-models` in a
  new `design-validation` CI job. Design only; nothing is implemented yet.

## 2026-09-30

- **SPDP carries and enforces the participant's domain ID.** Every SPDP announcement
  now includes `PID_DOMAIN_ID` (0x000f). Received SPDP that names a different domain is
  dropped before its locators are learned, so it neither discovers a participant nor
  refreshes an existing participant's lease. This matters wherever
  port mapping alone doesn't keep domains apart: a shared TCP or unicast locator, or
  colliding port mappings. SPDP without the PID is treated as belonging to the
  receiver's domain, as the spec requires, so peers that omit it still interoperate.

## 2026-09-25

- **Full four-language example mesh on Windows.** All nine mesh runners support
  Windows executable names and CMake's Debug output directory. Zig examples use
  portable argument handling, and the shape example uses portable output and
  platform-specific console handling. Shape tests no longer depend on `stdbuf`
  or terminate subscribers after a fixed number of discovery polls. Windows CI
  now runs the strict examples suite, excluding only optional OpenCV explicitly.
  Native Windows validation passed all 88 mesh pairs and all four shape filters.
- **Windows socket cleanup and Java/JNI restored.** UDP and TCP now close Winsock
  sockets with `closesocket`, rather than the CRT's `close`. The latter could
  leak sockets or terminate the host through its invalid-parameter handler:
  native debugging reproduced both the custom-allocator cross-binding failure
  (`0xC0000409`, reason 5) and Java's silent exit code 9 on this path. Regression
  tests verify that closing each transport's socket releases its bound port.
  Windows Java binding smoke tests are enabled in CI and release validation.
- Java example scripts select `zidl.exe` and the JNI DLL's `bin/` directory on
  Windows, and reserve sufficient Java thread stack space for native config parsing.
  Removed temporary config/custom-allocator checkpoints and shortened repeated
  CMake stack-size investigation comments.

## 2026-09-16

- **`userDataOnReceive` also listens on the metatraffic unicast port, fixing a
  zzdds-as-publisher regression against hdds (Durability/OrderedAccess, ACKNACK-gated
  tests).** Found via the `zz-iot/dds-rtps` interop matrix (0.2.0 vs. 0.3.1 comparison,
  2026-09-15): a writer/reader with no explicit SEDP locator inherits the participant's
  `default_unicast_locator`, distinct from `metatraffic_unicast_locator` per RTPS §8.5.4 —
  zzdds correctly advertises both as separate ports (confirmed on the wire), but hdds's
  reader unconditionally routes ACKNACK/HEARTBEAT/GAP to `metatraffic_unicast_locator`
  regardless of entity kind (confirmed directly against hdds's own source,
  `hdds-team/hdds:crates/hdds/src/dds/reader/heartbeat.rs`'s `resolve_metatraffic_dest`,
  tagged `v219` — added to work around an unrelated FastDDS quirk, applied too broadly).
  `src/discovery/sedp.zig`'s `onReceive`, the sole listener on the metatraffic port, only
  recognizes builtin SPDP/SEDP/WLP entities, so the misdirected traffic was silently
  dropped — the writer's `suppress_live_data` durability-replay gate only ever clears
  inside `handleAckNack`, which was never reached, so no live data was ever sent.
  - Fix: `participant.zig`'s `start()` now also registers `userDataOnReceive` on the
    metatraffic port (when it's a genuinely different port from the dedicated data-listen
    port), as a second fan-out handler via `Transport.listen()`'s existing
    reuse-`PortEntry`-via-`addHandler` path. `sedp.zig` is untouched — SEDP still only
    knows about builtin entities, `userDataOnReceive` still only knows about
    `active_writers`/`active_readers`; the two dispatchers stay fully decoupled, they just
    both now see metatraffic-port traffic.
  - Corrected two comments asserting the wrong reason WLP shares SEDP's listener instead
    of opening its own (`src/discovery/wlp.zig`, `docs/roadmap.md`) — `vtListen`'s
    reuse-existing-`PortEntry` path has existed since the initial commit; it was never a
    transport limitation.
  - `hdds` promoted into `ci.yml`'s gated default vendor matrix so a regression on either
    side gets caught automatically going forward.
  - Verified against the actual regression set (`Test_Durability_{5,9,10,13,14,15,17}`,
    `Test_OrderedAccess_{11..17}`, all previously failing 100% reproducibly against hdds,
    now passing) plus zzdds-self, connext, and coredx sanity checks (no change in
    behavior — the new listener only ever matters for a peer that sends to the wrong
    port).
  - Longer-term direction (not this change): `docs/design/rtps-submessage-routing.md`
    proposes routing decoded submessages by entity ID instead of registering more
    listeners — would make this whole class of "peer sent to an unexpected port" issue
    structurally impossible, at the cost of a real `ReceiveHandler` contract change.
    Deliberately deferred; not scheduled.

## 2026-09-14

- **`resolveKeyHash`'s fallback now dispatches on change kind, not one shared function for
  both ALIVE and DISPOSE/UNREGISTER.** Found via the `instance` stress scenario
  (`stress-tests/README.md`): a non-zzdds peer that omits the inline `PID_KEY_HASH` sends a
  *complete* payload for an ALIVE change but a *key-only* one for DISPOSE/UNREGISTER (RTPS
  §8.7.9's K-flag convention) — calling the same reconstruction function for both misreads
  one of the two shapes. This depends on zidl splitting `computeKeyHashFromCdr` into a
  full-payload-safe default and a `computeKeyHashFromCdrKeyOnly` sibling (zidl PR, same
  date) — the unsuffixed name changing meaning is a drop-in swap for the ALIVE case (no
  zzdds source change needed there), but the DISPOSE/UNREGISTER case needs its own callback.
  - `TypeSupport` gained an optional `compute_key_hash_key_only` field alongside the
    existing `compute_key_hash` (now documented as the ALIVE/full-payload one).
    `ActiveReader` gained a matching `key_hash_only_fn`, set alongside `key_hash_fn` at
    reader-creation and TypeSupport-replacement-refresh time.
  - `resolveKeyHash` now takes the change's `kind` (already in scope at all three call
    sites) and picks `key_hash_fn` for `.alive`, `key_hash_only_fn` otherwise. When a
    registration leaves the new field unset, it falls back to `zeroes([16]u8)` rather than
    risk calling the ALIVE-shaped function on a key-only payload — a known incomplete
    instance handle for that registration instead of a confidently wrong one.
  - The C-ABI surface the C/C++/Java bindings register through
    (`zzdds_register_type_support`/`_ctx`) now also carries the key-only function pointer —
    see the entry directly below. Every one of zzdds's own `examples/`/`stress-tests/`
    registrations passes it.
  - Regression: `test/dcps/type_support_test.zig` — two new tests, one proving the kind-based
    dispatch (distinct constant-hash functions per kind, asserted via resulting instance
    handles), one proving the zero-hash fallback when `compute_key_hash_key_only` is
    unregistered. Both verified to actually fail against the pre-fix dispatch (reverted
    locally and re-run) before landing.
  - zidl pin → `v0.3.17-zig.0.16.0` (`build.zig.zon`), the tagged release containing the
    `computeKeyHashFromCdr` split (zidl PR #52). Developed and verified against a `.path`
    override of the unreleased branch; re-verified against the real tag once it landed.

- **`zzdds_register_type_support`/`_ctx` (the C-ABI TypeSupport registration surface the
  C/C++/Java bindings all funnel through) gained a `compute_key_hash_key_only_fn`
  parameter**, closing the gap the entry above left open. Both entry points now take it as
  a new argument (inserted right after `compute_key_hash_fn`) and thread it into the new
  `TypeSupport.compute_key_hash_key_only` field via `c_abi/typesupport.zig`'s two adapters
  (`CTypeSupportAdapter`/`CtxTypeSupportAdapter`), each gaining a matching
  `computeKeyHashKeyOnly` method. `include/zzdds_c.h` updated to match.
  - **zidl side**: the C and C++ backends' generated `{Type}TypeSupport_register(...)`
    wrapper now passes `{Type}_compute_key_hash_from_cdr_key_only` too — a C++ consumer
    (which always goes through that generated wrapper) needed no source change at all.
  - **Java/JNI**: `zzdds_java_runtime.c`'s `registerTypeSupport` now also resolves
    `computeKeyHashFromCdrKeyOnly` via `GetStaticMethodID` (optional — cleared like
    `getFieldFromCdr`'s lookup if the class predates this contract) and wires a new
    `zzdds_java_compute_key_hash_key_only_ctx` trampoline. Java examples needed no source
    change either (reflection-based).
  - **C examples**: unlike C++ (which always calls the generated
    `{Type}TypeSupport::register_type(dp)` wrapper), every one of these called
    `zzdds_register_type_support` directly, naming the generated key-hash/get-field
    functions explicitly — an unexplained asymmetry with no documented rationale, and
    exactly the fragility that made this a mandatory 19-file fix instead of a no-op. Fixed
    at the root instead of just patched: all 19 call sites across `examples/c/*/src/*.c`
    now call the generated `{Type}TypeSupport_register(dp, type_name)` wrapper too (which
    the C backend already generated, unused, alongside C++'s), matching C++'s pattern and
    insulating the examples from any future C-ABI signature change the way C++ already was.
  - **Native Zig registrations**: `examples/zig/*/{publisher,subscriber}.zig` (15 files) and
    `stress-tests/zig/{entity_lifecycle_stress,lifecycle_churn}/main.zig` (7 call sites)
    now all pass `.compute_key_hash_key_only = {Type}.computeKeyHashFromCdrKeyOnly` too.
  - Regression: `test/c_abi/typesupport_test.zig` — new tests for both entry points proving
    `compute_key_hash_key_only_fn` is wired to a real, independently-callable second slot
    (not aliased to `compute_key_hash_fn`) and that a `NULL` value falls back to a zero hash
    rather than leaving the field genuinely unset (it's the same "always wire the adapter
    method, let the method check its own null" pattern the pre-existing, required
    `compute_key_hash_fn` slot already used).
  - Verified end to end against the real generated+compiled artifacts, not just unit tests,
    re-run after the C-examples wrapper switch above: `examples/c/hello_world`,
    `custom-allocator`, and `discovery` all built via CMake against a real
    `zig build install` tree, `hello_world` actually run (publisher/subscriber exchanged all
    10 samples); every `examples/zig/*` and `stress-tests/zig/*` binary built standalone;
    `lifecycle_churn --scenario instance` run for real (`SUMMARY: OK`); TSan clean.

## 2026-09-13

- **SPDP discovery codec is now zidl-generated too**, completing the SEDP swap
  (2026-09-10): `SPDPdiscoveredParticipantData` goes through the same generated
  `idl/rtps_discovery.idl` codec (`--zig-pl-cdr`, `@pl_retain_unknown` — every
  unrecognised PID round-trips losslessly), closing the last gap toward lossless
  discovery retention for a future broker relay. The hand-rolled `spdp.zig`
  encoder/parser are gone.
- **New `discovery/wire_codec.zig`** — GUID <-> wire-byte conversion, PL_CDR framing, and
  `Locator_t` sequence conversion in both directions, factored out of `sedp.zig` (which
  had its own private copies) so SPDP and SEDP share one implementation.
- `SPDPdiscoveredParticipantData.participantGuid` / `.leaseDuration` are now `@optional`
  in the IDL, purely for the decode side (a peer may omit either PID); decode falls back
  to the RTPS message header's `guid_prefix` and a 10s lease default, matching the
  pre-codec parser exactly. zzdds's own encoder always fills both, so the wire is
  unaffected — verified byte-exact against the existing `EXPECTED_SPDP` golden fixture in
  `test/discovery/wire_golden_test.zig`, no wire deltas (unlike SEDP's two).
- `test/fuzz/fuzz_plcdr.zig`'s big-endian and repeated-known-PID tests now assert the
  actually-decoded values, not just that decode doesn't crash — caught by Greptile review
  on PR #85: both would have passed even if the codec swap silently mis-decoded BE fields
  or kept the *first* occurrence of a repeated PID instead of the last. The repeated-PID
  case in particular needed two *differing* values (10s then 5s) to prove "last wins" at
  all — two identical occurrences pass regardless of which one "won".
- zidl pin → `v0.3.16-zig.0.16.0` (`build.zig.zon`). That release's changes are all on the
  generated-union `deinit()`/`deserializeInto` safety path (three Greptile-review rounds on
  zidl PR #51 — discriminant-before-payload, `@mutable`-loop payload/discriminant staleness,
  and an owning-default-discriminant early-failure case); zzdds's own discovery IDL (SPDP,
  SEDP, `EndpointDisposal`) declares no unions, so no zzdds source change was needed. Full
  suite re-verified against the new pin: `zig build test` 1094/1094, `test-tsan` clean.

## 2026-09-11

- zidl pin → `v0.3.15-zig.0.16.0`. Fixes a PL_CDR decode bug the discovery codec swap
  (2026-09-10) exposed against real vendor traffic: the generated
  `deserializeFromPlCdr` switch dispatched on `pid & 0x3FFF`, but RTPS 2.5 §9.6.4.2.1
  reserves bit `0x8000` for vendor-specific PIDs whose low 15 bits are the vendor's own
  private numbering. RTI Connext's vendor PID `0x8021` (a compressed TypeObject blob)
  aliased `PID_PRESENTATION` (`0x0021`), so zzdds failed to decode any Connext (and TOC
  CoreDX) SPDP/SEDP announcement — a live-interop-only regression the golden fixtures and
  self-interop suite couldn't see, since zzdds's own encoder never emits vendor PIDs. No
  zzdds source change needed; the fix is entirely upstream (zidl PR #50).

## 2026-09-10

- **SEDP discovery codec is now zidl-generated** from `idl/rtps_discovery.idl`
  (`--zig-pl-cdr`, `@pl_retain_unknown` — every unrecognised PID round-trips losslessly,
  the groundwork for a discovery-broker relay). The hand-rolled `sedp.zig` encoders/parsers
  are gone; `discovery/qos_adapter.zig` maps the typed `DDS.DataWriterQos` /
  `DataReaderQos` (+ Publisher/Subscriber `PresentationQosPolicy`) to/from the wire structs.
- **Removed:** the flat `disc.QosSnapshot`, `participant.zig`'s `writerQosSnapshot` /
  `readerQosSnapshot` / `reprFromQos`, and `src/qos/policy.zig` + `qos_match.checkWriterReader`
  / `checkPresentation` (all orphaned). QoS matching is now `qos_match.checkDiscovered`,
  operating directly on the RTPS discovery wire structs. Discovery callbacks carry
  `qos: *const Discovered{Writer,Reader}Data` (borrowed) plus a `raw_parameter_list` for a
  future broker.
- **Wire deltas** (all spec-legal; `test/discovery/wire_golden_test.zig` is the contract,
  validated against the live interop suite): a default writer/reader now advertises
  `PID_DATA_REPRESENTATION [2]` (matching the real `reprFromQos` path, not the old golden
  capture); `PID_TYPE_INFORMATION` is replayed after `PID_PARTITION` rather than before.
- SPDP encode/decode is unchanged (hand-rolled — it carries no QoS).
- SEDP decode re-seeds `RELIABILITY` after decode when a peer omits `PID_RELIABILITY` for
  its spec default (Connext does this for a default-RELIABLE writer): the generated decoder
  leaves `kind == 0` (invalid), which QoS matching would read as weaker than BEST_EFFORT.
  Writer branch seeds `0 → RELIABLE`, reader branch `0 → BEST_EFFORT` (RTPS 2.5
  §8.5.4.2/§8.5.4.3). The old hand parser applied RTPS defaults inline.
- SEDP decode: PARTITION names are no longer capped at 32 per endpoint (the IDL type is an
  unbounded `sequence<string>`; the fixed decode buffer silently dropped the rest and broke
  matching for endpoints with many partitions) — `partitionNamesOwned` now sizes to the
  actual count. The legacy `PID_PARTITION` (`0x0035`) hand-parse reads its sequence count
  and string lengths with the payload's byte order instead of assuming little-endian, so a
  big-endian peer's legacy partitions decode correctly.
- zidl pin → `v0.3.14-zig.0.16.0` (fixes `@optional` sequence / array codegen the SEDP
  structs rely on).

## 2026-09-03

- **Release workflow — first real run shook out three `package-libs` bugs.** That job
  (`release.yml`-only, never exercised by `ci.yml`) had shipped unrun since 2026-08-28.
  1. **`Verify install tree is complete` false negative.** The dynamic-lib probe was
     `if ! ls <4 candidate paths> 2>/dev/null | grep -q .` under `set -o pipefail`; on any
     one platform 3 of the 4 paths are absent so `ls` exits non-zero, `pipefail` propagates
     that over grep's success, and `!` inverts it to a bogus "no dynamic libzzdds found" —
     with `libzzdds.{so,dylib,dll}` sitting right there. Replaced with a `test -f` loop.
     Also added `--summary all` to the install build.
  2. **macOS static archive not linkable by Apple `ld64`.** The `libzidl_cdr.a` that
     `Step.Compile`'s GNU-format archiver writes has member offsets Apple's linker rejects
     (`64-bit mach-o member 'zidl_cdr.o' not 8-byte aligned`). `zig cc` (LLD) tolerates it —
     so `test-bindings` never saw it — but the new prebuilt-bundle consume check, which
     links with Apple clang/ld, did. `build.zig` now installs the macOS `libzidl_cdr.a` by
     re-packing the object with the `zig ar` subcommand (`--format=darwin`, 8-byte
     aligned) instead of `b.installArtifact`; the internally-linked `zidl_cdr` static lib
     is unchanged. Fixes a local `zig build install` on macOS and a macOS bundle
     cross-compiled from another host, not just the release runner. (ziglang/zig#1981;
     Linux `ar` output is fine.)
  3. **macOS dylib not linkable by Apple ld-prime C++ consumers.** Zig 0.16 publishes its
     Mach-O linker-synthesized `___dso_handle` in `libzzdds.dylib`'s export trie. When a
     C++ consumer registers a destructible static with `__cxa_atexit`, Apple ld 1267 binds
     the reference to that dylib export and fails with `target '___dso_handle' does not
     have address`. `zig c++`/LLD do not, so `test-bindings` was green; the new
     prebuilt-bundle consume check building `examples/cpp/hello_world` with Apple clang++
     caught it. The macOS install step now post-processes the dylib
     (`scripts/fix_macos_dylib_exports.sh`) to filter only that private runtime symbol
     from its export trie (`strip -s` with the kept-symbol list; `strip -R` alone leaves
     `LC_DYLD_EXPORTS_TRIE` untouched); the raw compile artifact is unchanged for Zig's
     in-tree links. macOS builds also now default to Zig 0.16's supported deployment floor
     (13.0) instead of stamping the build host's current OS version (which produced an
     `LC_BUILD_VERSION` skew warning). `verify_release_bundle.py` gained a `check_structure`
     guard that fails if the dylib re-exports `___dso_handle`. (ziglang/zig#24370.)
- **Convention — dry-run `release.yml` before merging any change to it.** Documented in the
  workflow header and `docs/binding-release-plan.md`: run it from the PR branch with
  `dry_run: true` (skips `publish`) and confirm `test`, `self-interop`, and all four
  `package-libs` legs pass, since `package-libs` is release-only.

## 2026-09-02

- **Pinned `zidl` v0.3.12-zig.0.16.0** (`build.zig.zon`) — the selective-parse family
  (`deserialize_selected` / `KEY_FIELD_MASK` / `skipPrimitives`) that rewires
  `get_key_value` and `get_field_from_cdr` off the key-only deserializer. The
  `lifecycle_churn` `instance` scenario now **asserts** `get_key_value`'s returned
  `subject_id` (non-leading `@key`) on both the writer and reader sides — it was
  call-only-not-asserted while the fix was unreleased. Verified: 8 threads × 6 s, plus
  ThreadSanitizer, clean; full stress suite green.
- **Fix — keyed writers now always send inline `PID_KEY_HASH`; a present all-zero hash is
  honoured.** Two connected key-hash bugs the `instance` stress scenario exposed for a
  zero-valued key (`subject_id == 0`):
  1. `writer_sm.zig` suppressed the inline `PID_KEY_HASH` parameter whenever the computed
     hash was all-zero bytes — indistinguishable from "keyless topic" but also true for a
     legitimate zero key. A subscriber then had to reconstruct the per-instance hash from
     the payload.
  2. `resolveKeyHash` treated a *received* all-zero hash as "absent, recompute" rather
     than as the value the writer sent.
  Now: `TypeSupport` gains `has_key`; `pubCreateProtoWriter` marks the RTPS `StatefulWriter`
  keyed (via new `setKeyed` / adapter passthrough); a keyed writer emits `PID_KEY_HASH` on
  every DATA/DATA_FRAG including an all-zero key (`writer_sm.zig` `inlineKeyHash` helper).
  `decodeKeyHash` returns `?[16]u8` and `resolveKeyHash` returns a *present* hash verbatim,
  even all-zero. The C-ABI `zzdds_register_type_support{,_ctx}` infer `has_key` from a
  non-NULL `compute_key_hash_fn` (per their documented contract); Zig-native callers set it
  explicitly (stress harness updated). Regression: `test/dcps/type_support_test.zig` — a
  keyed writer's zero-key sample routes by the wire hash and bypasses `key_hash_fn`, with a
  control test showing the unchanged non-`has_key` fallback. Verified by re-breaking.
- **Known follow-up.** `TypeSupport.compute_key_hash`'s contract is "full CDR payload in,
  hash out", but zidl's generated `computeKeyHashFromCdr` runs the key-only deserializer,
  so a non-`has_key` fallback still misreads a non-leading `@key` from a non-zzdds peer that
  omits the inline hash. Completion — route the fallback through
  `deserialize_selected(KEY_FIELD_MASK)` on a full payload, K-flag-gated — needs a
  `TypeSupport.compute_key_hash` signature change (`is_key_only: bool`) rippling to the
  C ABI mirror and a further zidl release, so it is a follow-up beyond the v0.3.12 bump.
  Tracked in `docs/roadmap.md` "Selective CDR parse — deferred follow-ups".
- **Release prep — prebuilt-bundle consume check.** `release.yml`'s `package-libs` job used
  to verify only the *contents* of the install tree it built, in place. It now also extracts
  the finished per-platform tarball into an unrelated directory and drives a real downstream
  consume of it (`scripts/verify_release_bundle.py` + committed fixtures under
  `test/release-bundle/`): structural completeness, pkg-config / CMake-package
  relocatability (no baked-in absolute build path), the bundled `bin/zidl` runs, and
  `find_package(ZZDDS)` + `pkg-config` build `examples/{c,cpp}/hello_world` and a minimal
  consumer against the *relocated* prefix — on Linux the hello_world pair also exchanges its
  10 samples. This is the consumption path `rmw_zzdds` (and any C/C++ CMake consumer) takes;
  the in-tree `test-bindings` step never exercised a moved prefix. Linux: full; macOS:
  `--skip-example-run` (skips only the live-UDP pair run — `cmake_consumer` still links and
  runs against `libzzdds.dylib`). Windows keeps the structural check only: the generated
  `zzdds-config.cmake` / `zzdds.pc` are POSIX-shaped (search `lib/` for the shared lib, no
  `IMPORTED_IMPLIB`, `bin/zidl` not `bin/zidl.exe`), so `find_package(ZZDDS)` can't configure
  a bundle there yet — tracked in `docs/roadmap.md` "CI / Release Platform Coverage".
- **Release prep — musl / static Linux target lane.** `-Dtarget` was never actually
  cross-compiled anywhere in CI. New `zig build test -Dtarget=x86_64-linux-musl` step in
  `run_deterministic_matrix.py` (so `ci.yml`'s `test-linux` covers it) and `release.yml`'s
  `test` job (Linux x86_64 only). A `-linux-musl` binary is statically linked and runs
  natively on the glibc runner, so this executes the full suite (1076/1076), proving zzdds
  is musl-clean for Alpine / static-binary / container consumers. In
  `run_deterministic_matrix.py` the step is gated to x86_64-Linux hosts (elsewhere the
  cross-built binaries can't run, and Zig would silently skip them); CI's `ubuntu-latest`
  runs it unconditionally. `aarch64-linux-musl` (needs qemu) and a static-archive `libzzdds`
  bundle variant remain deferred — `docs/roadmap.md` "CI / Release Platform Coverage".
- **Release prep — GitHub-release notes now come from `CHANGELOG.md`.** `release.yml`'s
  `publish` job built its release body from raw `git log --pretty=%s` subjects. It now
  quotes the `CHANGELOG.md` sections added since the previous release tag —
  `scripts/extract_changelog.py` emits the leading run of sections whose heading is not
  present in `CHANGELOG.md` as of that tag (whole-heading, not date, comparison), falling
  back to the leading date-headed run when the tag predates the file, and to raw commit
  subjects only if that yields nothing. Always appends a `compare` link. Two releases on
  the *same calendar day* under one `## <date>` heading aren't distinguished — the second
  gets the git-log fallback (fine for a hotfix; the notes are hand-editable).
- **Decision recorded — pre-1.0 has no stability guarantee.** `docs/decisions.md` gains a
  "Versioning / Releases" section: any release may break the Zig API, the C ABI, the
  QoS/config schema, or the bundle layout, with no deprecation cycle; the C ABI stays in
  flux until zzdds and Zig mature toward a distant 1.0; `--runtime-version <N>` stays
  unimplemented until there is a tier worth pinning. Consumers pin an exact
  `vX.Y.Z-zig.A.B.C` tag / bundle; downstream middleware (e.g. `rmw_zzdds`) owns its own
  version mapping and absorbs zzdds churn behind its own boundary. `release.yml`'s release
  notes now carry a matching "Stability" section.
- **Fix — the installed `zzdds.pc` / `zzdds-config.cmake` version now tracks `build.zig.zon`.**
  `build.zig` carried a second, hand-maintained `zzdds_version` string (stuck at
  `0.1.1-zig.0.16.0-dev`) that stamped the `Version:` field of the generated pkg-config and
  CMake package files — so a consumer's `pkg-config --modversion zzdds` reported a version
  two minors behind the actual package. It now reads `@import("build.zig.zon").version`, the
  same field `release.yml` bumps at tag time.

## 2026-08-30

- **Stress tests — five new `lifecycle_churn` churn scenarios.** On top of
  `entities`/`reentrant`: `waitset` (threads attach/detach Read/QueryConditions on a
  shared WaitSet while a waiter is in `wait()` and a waker flips a GuardCondition;
  includes a deliberate delete-while-attached), `listener` (participant + publisher +
  subscriber listeners installed; per-iteration `set_listener` swaps incl. `null` racing
  entity teardown and event delivery), `cft` (a shared long-lived ContentFilteredTopic
  hammered with `set_expression_parameters` while its reader is drained, alongside
  unique-name CFT + reader lifecycle churn), `participants` (N threads each churning a
  whole participant on one shared domain, listeners at every level, writer/reader
  fan-in/fan-out — the participant level of the §2.2.4.1.5 fallback under teardown), and
  `instance` (per-thread writer; `register_instance` / `write` / `dispose` /
  `unregister_instance` / `get_key_value` / `lookup_instance` churn with a shared reader
  fan-in). All gating in the `stress` CI job; `listener` and `cft` also run under
  ThreadSanitizer. See `stress-tests/README.md`. The `instance` scenario surfaced two
  pre-existing bugs: the concurrent-`write()` race (next entry, fixed here) and
  `get_key_value` decoding the wrong key for a non-leading `@key` member — fixed in zidl
  (a *selective-parse family*: `deserialize_selected(KEY_FIELD_MASK)` decodes just the
  `@key` members and skips the rest, all four backends), landing here with the zidl
  v0.3.12 `build.zig.zon` bump; the scenario's `get_key_value` value assertion is staged
  for that PR (`zz-dev/zidl-v0.3.12-pin-bump-followups.md`).
- **Fix — concurrent `write()` on a single `DataWriter` was unsynchronised.**
  `DataWriterImpl.writeRaw` updated `last_sn` and the `get_key_value` key registry (a
  `HashMapUnmanaged`) with no lock, so two application threads calling `write()` /
  `dispose()` / `unregister_instance()` on the same writer — spec-legal — raced on the
  map's grow/insert and could abort on its `SafetyLock` (found by `instance` under
  ThreadSanitizer). The RTPS layer under `proto_writer` was already internally locked; now
  `last_sn` is a `std.atomic.Value` and the key registry is guarded by a dedicated
  `key_registry_mu`. `docs/design/thread-model.md` documents the guarantee. Regression:
  `test/dcps/writer_vtable_test.zig` — 6 threads × 40 keyed `write_raw` calls on one
  writer plus a concurrent `getKeyValueRaw` poller; also runs in the `test-tsan` lane.
- **Fix — unsynchronised `listener_mask` (data race).** `listener_mask` was a plain
  `u32` written unlocked by `set_listener` and read unlocked by the discovery/timer
  dispatch path (`listener_mu` only ever covered the `ListenerBox` swap beside it).
  Every *runtime* access in `src/dcps/{writer,reader,publisher,subscriber,participant,
  topic}.zig` is now `@atomicLoad`/`@atomicStore` `.monotonic`; struct-literal
  initialisers stay plain. Found by the `listener` scenario under TSan.
- **Fix — CFT `set_expression_parameters` use-after-free.** `ContentFilteredTopicImpl`
  had no synchronisation on `expr_params`: `set_expression_parameters` frees the old
  parameter strings + backing array and swaps in the new list while the receive thread's
  `matchSample` is mid-`filter_mod.eval` holding those strings by reference (SEGV in
  `parseFloat`). New `params_lock: Mutex` on the impl, held across `matchSample`'s eval
  and around the swap in `set_expression_parameters` / the read in
  `get_expression_parameters`. Found by the `cft` scenario (~40% repro at 12 threads).

## 2026-08-29

- **CI flake fix — unique DDS domain per test binary.** `zig build test` runs the ~29
  participant-creating test binaries as parallel Run steps; they all stood up participants
  on domain 0 and contended for the same fixed RTPS ports (SPDP multicast 7400, metatraffic
  unicast), so on slow runners (ARM64, DebugAllocator/TSan lanes) the loser hit
  `error.BindFailed`, discovery stalled, and a loopback test timed out. `build.zig` now
  gives each test binary's Run step a distinct `ZZDDS_TEST_DOMAIN_BASE` (per-lane counter,
  see `addTestRun`); the new `test/support/domain.zig` reads it, and every DCPS/C-ABI test's
  `create_participant` (plus `loopback_test` / `wlp_loopback_test`'s hand-wired
  `UdpTransport.init` / `SpdpSedpDiscovery.init`) uses `test_domain.get()`. Distinct domains
  map to disjoint port sets (250-port stride). `mock_loopback_test` is unchanged (it never
  binds a real socket).
- **CI flake fix — `tcp_transport_test` reconnect race.** "connectionGeneration increments
  on reconnect" replaced a fixed `sleepMs(100)` (a guess at how long the local TCP stack
  takes to process a peer FIN) with a poll-until-observed loop: drive the reconnecting
  `send()` until a new `TcpConnection` is seen, or a 5 s deadline. Same invariant asserted,
  no magic constant.
- **`ReleaseSmall` CI lane.** New `zig build test-release-small` runs the unit suite at
  `-OReleaseSmall`, wired into `run_deterministic_matrix.py` and `release.yml` (Linux
  x86_64). It forces the LLVM backend to work around a Zig 0.16 self-hosted-x86_64 codegen
  bug — read-only globals emitted without alignment at `-OReleaseSmall` — that is fixed on
  Zig 0.17 master; switch back to the plain self-hosted backend at the 0.17 bump. See
  `docs/design/ci-platform-coverage-expansion.md`.

## 2026-08-26

- **`zzdds-examples` folded into `examples/`.** The standalone `zz-iot/zzdds-examples` repo
  was merged into this repo at `examples/`, preserving history, so a core fix and the
  example that exercises it can land in one commit. `examples/` is absent from
  `build.zig.zon`'s `.paths` allowlist, so it stays out of the fetched tarball. CI's
  `examples`/`examples-tsan` jobs collapsed to one checkout; `ZZDDS_EXAMPLES_REF` removed.
  The standalone GitHub repo is not yet archived.

## 2026-08-22

- **Raw / loaned DataReader & DataWriter API redesigned.** The hand-written, C/C++-only
  `zzdds_*_raw` family is replaced by real `dcps.idl` operations generated across all four
  bindings (`take_raw`/`read_raw`/`take_next_instance_raw`/`read_next_instance_raw`/
  `return_loan_raw` on `DataReader`; `write_raw`/`loan_raw`/`publish_loan_raw`/
  `return_loan_raw` on `DataWriter`). `max_len == 0` signals loan-vs-copy, inferred from
  parameter shape. Loan-outstanding tracking added (CAS refcount pin table in `reader.zig`;
  single-owner counter in `writer.zig`) with `PRECONDITION_NOT_MET` fast-fail teardown.
  `take_loaned_raw` remains a raw-*byte* buffer loan (a copy out of reader history), not
  zero serialization — see `docs/design/raw-loan-api.md`.
- **`delete_contained_entities` now propagates preconditions.** Previously every level
  (`participant.zig`/`subscriber.zig`/`reader.zig`) hardcoded `RETCODE_OK` regardless of
  precondition state — a DDS 1.4 spec gap. Now a synchronous check-then-teardown pass fails
  all-or-nothing with `PRECONDITION_NOT_MET` before any child is torn down.
- Fixed the C/C++/Java typed reader family carrying a 3-field `zzdds_sample_info`/`Sample`
  instead of the 12-field spec `SampleInfo` (missing `source_timestamp` and every
  generation/rank field). Only Zig was correct before.

## 2026-08-20

- **Fixed a C-ABI struct-layout bug in `create_participant_ex` /
  `set_default_participant_config` / `get_default_participant_config`.** The exported
  wrappers declared their `config` parameter as the non-`extern` Zig type
  `zzdds.DomainParticipantConfig`, which carries a hidden `_toml_applied: bool` field, while
  the public header declared it without that field — so every C/C++/Java caller built a
  smaller struct that the wrapper then read/wrote through as the larger layout, and
  `factoryGetDefaultParticipantConfig`'s `config.deinit()` freed through garbage offsets
  (confirmed via a real JVM crash). Introduced by "Config File Improvements" (#54); never
  caught because no cross-language caller had exercised these three ops. Fixed via zidl's
  C-ABI mirror mechanism (`zidl v0.3.7`).
- **Fixed a zidl Java JNI `@optional` scalar marshaling crash** — `StructMarshalGenerator`'s
  `.scalar` case never checked `is_optional`, so it emitted `GetMethodID(cls, "get_x",
  "()I")` for a boxed `Integer` getter, got NULL, and the next call dereferenced it. Only
  reachable via `UdpConfig`'s five `@optional` port fields. Also fixed a live leak in the
  same generator (`javaFieldDescriptor` return value never freed at four sites). `zidl v0.3.7`.
- **Hardened `zzdds_java_runtime.c`'s JNI boundary** against `null`/invalid handle inputs.
  Audited all 21 `zzdds_java_unbox` and 4 `GetStringUTFChars` sites; added
  `zzdds_java_require_non_null` / `_require_utf_chars` helpers that throw a catchable
  `NullPointerException` (previously: a full JVM crash) naming the parameter. Three sites
  left unguarded where `null` has documented meaning (idempotent destroy; `cft == NULL` =
  "no filter").
- **`-Z` / `--datafrag-size` added to every `shape` port** (dds-rtps port + zzdds-examples
  `zig`/`c`/`cpp`/`java`). Found in the process that **`--periodic-announcement` had been a
  silent no-op in all five ports** — they set it via `setenv(...)` but `src/config/resolve.zig`
  stopped honouring env vars in "Config File Improvements" (#54). Rewired through the real
  config mechanism.

## 2026-08-19

- **Writer Liveliness Protocol implemented** (RTPS 2.5 §8.4.13).
  `DomainParticipant`/`DataWriter.assert_liveliness()` previously only updated local
  timestamps and never emitted wire traffic. New `src/discovery/builtin_endpoint.zig`
  (`BuiltinPair`, a shared abstraction for RTPS well-known-EntityId endpoint pairs; SEDP
  refactored onto it first) and `src/discovery/wlp.zig` (`WlpEndpoints`, the
  `BuiltinParticipantMessageWriter/Reader` pair, sharing SEDP's metatraffic listener,
  driven by `checkTimers()`). AUTOMATIC and MANUAL_BY_PARTICIPANT via `ParticipantMessageData`;
  MANUAL_BY_TOPIC via an on-demand Heartbeat with the RTPS LIVELINESS flag
  (`StatefulWriter.sendLivelinessHeartbeat`). Deliberate simplifications:
  `BuiltinParticipantMessageReader` is RELIABLE-only; AUTOMATIC send period is `lease/3`
  floored at 100ms. Real-wire regression test (`test/dcps/wlp_loopback_test.zig`, two real
  `UdpTransport` participants).

## 2026-08-16

- **CI extended to non-Linux platforms** (#65): DebugAllocator, C/C++/Java bindings, TSan,
  and ReleaseFast across the Linux ARM64 / macOS / Windows matrix, where feasible. Java/JNI
  on Windows and TSan on macOS were attempted and deferred — see the roadmap's "CI /
  Release Platform Coverage" section and the two investigation notes in `zz-dev`.

## 2026-08-13

- **Listener "nearest enclosing non-null listener" fallback (DDS 1.4 §2.2.4.1.5)
  implemented** — `src/util/listener_fallback.zig`, wired into `reader.zig`/`writer.zig`/
  `subscriber.zig` dispatch. When an entity's own listener callback is null, dispatch now
  walks up (reader → subscriber → participant) to the closest installed non-null listener,
  passing the originating entity as the callback argument.
- **C-ABI `WaitSet`-attached-condition release hook wired into the C++ and Java wrapper
  layers** — the memory-safety half was already internal; the wrappers now use the hook so
  a wrapper's own keep-alive can be released at the right time.
- **Five P1 races in `java_runtime/zzdds_java_runtime.c`** fixed (found across several
  Greptile review rounds on PR #62) — attach/detach interleavings and an OOM-but-proceed
  path in `WaitSetImpl.attach_condition`.
- **Closed a gap in `src/c_abi/extensions.zig`'s checked downcasts** (test coverage), and
  fixed a real gap the coverage pass's own `FailingAllocator` run surfaced. The OOM-path
  error branches in `factoryCreateParticipant` etc. remain untested — see roadmap.

## 2026-08-12

- **C-ABI entity/condition cross-view identity fixed at the root** (with zidl's
  `@shared_c_abi_box` / `CAbiViews` work). Phase 1: the Condition family. Phase 2: extended
  to every other entity impl. A `Condition` returned from `WaitSet.wait()` is now
  identity-comparable against a held condition's own upcast handle in C
  (`zzdds-examples/c/waitset` workaround removed) and C++ (via zidl's shared-family
  `_getOrCreate`; `cpp/waitset` workaround removed). Zig-native was never affected. See
  `zidl/docs/design/binding-c-abi-identity.md`.

## 2026-08-09 – 2026-08-10

- **`WaitSet` / condition example added** (`zzdds-examples/{zig,cpp,c,java}/waitset`),
  exercising `WaitSet` + all four condition types on one `WaitSet`. Surfaced and fixed a
  cluster of bugs unreachable before (nothing could construct a `WaitSet` through any
  binding):
  - `WaitSet` / `GuardCondition` C-ABI + Zig-native construction
    (`zzdds_create_waitset`/`_guardcondition` + `_with_allocator` + `_destroy` + `_is_nil`
    in `extensions.zig`; `zzdds.createWaitSet`/`createGuardCondition` in `raw_ops.zig`;
    `nil_waitset`/`nil_guardcondition` in `nil.zig`; `zzdds::create_waitset`/
    `create_guardcondition` in `zzdds_cpp.hpp`). Both interfaces have no factory op in
    `dcps.idl` per OMG spec.
  - Condition/entity lifecycle safety — a destroyed condition now drops cleanly from every
    attached `WaitSet`, no dangling pointer regardless of destruction order.
  - `QueryCondition` deleted via its spec-correct `ReadCondition` upcast corrupted memory
    (`deinit` reached the wrong object) — fixed with an `owner_qc` back-pointer.
  - `WaitSetImpl.vtWait`'s two-pass count-then-fill loop raced a concurrent
    attach/detach — fixed.
  - zidl C++ backend: `attach_condition`'s `dynamic_cast` cascade wrongly excluded
    `ReadCondition`; zidl Zig backend: a `sequence<EntityInterface>` out-param had
    corrupted binary layout (native fat-pointer passed where the C ABI expects one opaque
    pointer). Both fixed in zidl (`v0.3.5`).

## 2026-08-06

- **ContentFilteredTopic filtering now actually works in every binding.** No backend had
  ever emitted zzdds's `TypeSupport.get_field` hook, so CFT filtering silently never
  activated. `get_field` is now wired for every binding (needed a zidl `get_field_from_cdr`
  codegen change and a Java bare-`sequence<T>`-param JNI marshaling fix). New
  `zzdds_cft_match_sample` C-ABI export.
- **Fixed `data_representation` QoS re-matching reading a dangling pointer.**
- **Plain-struct CDR functions** (`_serialize`/`_deserialize`/`_skip`/`_default`) exposed
  across the C ABI (`zidl v0.3.4`).
- **C++ ABI: `create_datawriter` / `create_topic` can now return zzdds's own extended
  entity types** (not just the `DDS::` base) — via zidl's `--cpp-impl-override` /
  `--cpp-impl-include` (`zidl v0.3.4`).
- **`zzdds_register_type_support_c` / `_ctx_c`** renamed (dropping the `_c` suffix); added
  Zig-native `registerTypeSupport` / `setListenerEx` ergonomic wrappers in `raw_ops.zig`
  and fixed live string-cleanup leaks found while verifying them (`zidl v0.3.4`).
- **DEADLINE / LIVELINESS QoS now enforced automatically** — a per-participant timer thread
  (`DomainParticipantImpl.timer_thread` / `timerThreadFn`) periodically calls
  `checkTimers()`. Previously nothing drove it in production; callers had to pump it
  themselves. Scoped to one thread per participant.
- Fixed a standing Zig build-graph bug (unrelated to this work) found along the way.

## dds-rtps shape interop validation (Phase 33) — complete

The OMG **dds-rtps shape** interop suite (48 cases): self-interop CI job 48/48 (gates
release); zenzen↔zenzen 100%; FastDDS, OpenDDS, RTI Connext, Cyclone DDS all 48/48
bidirectional (Cyclone's two CFT cases are `SUB_UNSUPPORTED_FEATURE` in its own
`shape_main` — a test-infra gap, not a wire issue).

This does **not** cover GROUP_PRESENTATION coherent-set interop, which uses a separate,
larger suite — RTI Connext still has 5 open zzdds→Connext gaps there
(`CoherentSets_8/10/11/12`, `OrderedAccess_8`); see `docs/implementation_status.md` and the
roadmap's "DCPS / QoS" gaps.

## Earlier (through 2026-08-05)

Core RTPS 2.5 (SPDP/SEDP discovery, stateful reliable readers/writers, HEARTBEAT/ACKNACK,
fragmentation), the full DCPS entity model and all 22 QoS policies, ContentFilteredTopic /
QueryCondition SQL, pluggable UDP/TCP transport, the C / C++ / Java bindings (opaque-handle
C ABI, generated C++ impl classes, real JNI bridge), TypeSupport C-ABI shim, and the
configurable-allocation Tier 0/1 work (`zzdds_create_factory_with_allocator`, the
`get_c_abi_handle` cache). See git history for detail.
