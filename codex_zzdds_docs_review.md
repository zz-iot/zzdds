# zzdds Documentation Review

Date: 2026-05-20

Scope: `zzdds` repository documentation and source, excluding `zig-pkg/` as requested. I also looked at the sibling `zidl` repository documentation and recent documentation commits as a cleanup example.

Verification performed:
- `zig build test` with `/storage/tsimpson/code/zig/build/stage3/bin/zig`: passed.
- `zig build --summary all`: passed; default build currently installs `zzdds_interop_pub`, `zzdds_interop_sub`, and `zzdds_interop_pub_frag`.
- Source/docs scans used `rg`, `find`, and direct reads of `README.md`, `docs/**`, `build.zig`, `build.zig.zon`, `src/**`, `test/**`, `.github/workflows/ci.yml`, and selected sibling `../zidl/docs/**`.

## Executive Summary

The documentation is useful as a development log, but it is not yet a clean end-user documentation set. The main problem is not lack of information; it is that accurate current facts, old phase history, future design, and stale claims are intermixed. `docs/dev-plan.md` is especially overloaded: it contains real current status, resolved history, planned work, open questions that have already been resolved, and status claims that contradict the implementation.

The highest-priority fixes are:

1. Rewrite the top-level `README.md` status, build/dependency, and feature claims. It is materially stale.
2. Split `docs/dev-plan.md` into current status, roadmap, and historical changelog/decision log. Keep only current facts in the status document.
3. Correct architecture/design documents that describe future or old designs as implemented behavior, especially security, zero-copy send, config, testing, and thread model.
4. Add a real documentation index like `zidl/docs/overview.md`, with clear audience labels: user guide, implementer reference, roadmap, internal notes.
5. Keep a single source of truth for implemented feature status and make README point to it.

## Current Implementation Snapshot

This is the implementation baseline I used for the review.

- Build system uses Zig 0.16.0 and fetches `zidl` from a URL in `build.zig.zon`, with the package unpacked under `zig-pkg/` locally. It is not currently a sibling path dependency, and `.gitmodules` is empty.
- `zig build` runs zidl code generation and installs the three interop executables. It does not expose a standalone installed library artifact in the way the README implies.
- `zig build test` passed. There are 412 explicit Zig `test` blocks in `src/` and `test/`, not counting generated-code internals.
- Implemented transports include UDP, mock, lossy wrapper, and memory/in-process transport. TCP and SHMEM are not implemented.
- Implemented discovery includes SPDP, SEDP, combined SPDP/SEDP, and direct in-process discovery. Static and broker discovery are config enum values/future directions, not implementations.
- RTPS includes message parse/build, history cache, writer/reader state machines, reliable recovery, DATA_FRAG writer fragmentation and reader reassembly, HEARTBEAT_FRAG/NACK_FRAG, sequence-number helpers, received-set tracking, and protocol adapters.
- Message building still exposes iovec-style slices, but the current send path flattens those iovecs into a stack buffer before calling `Transport.send`. It is not currently a POSIX `sendmsg()` zero-copy path.
- DCPS includes factory, participant, publisher/subscriber, topic, ContentFilteredTopic lifecycle, writer/reader, waitsets/conditions, QoS matching, QoS runtime behavior tests, sample lifecycle, read/take state masks, sample rejected status, ignore participant, matched status callbacks, and an in-process delivery harness.
- ContentFilteredTopic parser/evaluator exists, but actual DataReader delivery does not automatically deserialize arbitrary CDR payloads and filter at receive/read time. Tests currently apply the CFT filter manually with a mock/simple accessor in the integration path.
- Security is a skeleton interface plus noop plugin. The `SecurityPlugins` value is stored in participant/factory state, but source search shows no actual `validateLocalIdentity`, access-control, encode/decode, or crypto enforcement call sites. The docs should not present DDS-Security support as implemented.
- XTypes support is partial. The build can include `DataRepresentationQosPolicy`, SEDP `PID_DATA_REPRESENTATION`, `registerTypeInfo`, and optional writer-side `PID_TYPE_INFORMATION`. There is no TypeLookup service, and source comments explicitly avoid TypeLookup interactions with OpenDDS.
- Config schema is ahead of parser/resolver coverage. Fields such as `participant.timer_clock_name`, `rtps.fragment_size`, `udp.meta_unicast_port`, `udp.data_unicast_port`, and `udp.data_port_separate` exist in `src/config/schema.zig`, but are not parsed from TOML or applied through env/override resolution.

## Layout Findings

### Finding: The README overpromises and points users at stale status

`README.md` is currently a mix of product statement, goals, build notes, repo map, spec references, and status. Several claims are too broad or stale:

- It says the project has "DDS-Security 1.2 support." The source has only skeleton/noop interfaces and no active enforcement path.
- It says RTPS wire interoperability with Cyclone DDS, FastDDS, and RTI Connext. The implementation/docs/tests in this repo show Cyclone and OpenDDS interop; FastDDS/RTI are future/planned.
- It says the zidl sibling repo `../zidl` must be present and referenced as a path dependency. Current `build.zig.zon` uses a URL/hash package dependency, and `.gitmodules` is empty.
- It says `zig build test` runs "~170 tests"; there are 412 explicit test blocks now, and the suite has grown substantially.
- It says current status is "Phases 0-27 complete"; `docs/dev-plan.md`, tests, and source show Phase 28-32 work has landed and Phase 33 work is partially present in CI.
- It does not mention important current features such as `MemoryTransport`, `DirectDiscovery`, `IntraProcessDelivery`, `LossyTransport`, QoS runtime behavior, sample lifecycle/read-take work, matched status tests, or self-interop CI.

Recommended action: Make README much shorter and more conservative:

- What this is.
- Current implemented feature matrix.
- Build/test commands.
- Minimal example or pointer to examples.
- Documentation index.
- Current limitations.

Move long architecture and phase status to docs.

### Finding: `docs/dev-plan.md` has become a scratchpad/history file

At 920 lines, `docs/dev-plan.md` dominates the documentation set. It is useful internally, but not as a user-facing plan. It mixes:

- Original phases and later corrections.
- Completed implementation notes.
- Future roadmap.
- Active questions.
- Resolved decisions.
- Stale open questions.
- Pointers to source line numbers that are no longer reliable.

Concrete stale examples:

- Phase 31 says two clock slots, `wire_clock` and `timer_clock`; implementation exposes `config.participant.timer_clock_name` and a `ClockRegistry`, but no config-level `wire_clock` slot.
- The "Before Phase 31" clock open question is still listed as active even though Phase 31 is marked implemented and source now has `ManualClock`, `monotonicClock`, `boottimeClock`, and timer-clock injection.
- Phase 32 still marks `on_publication_matched` / `on_subscription_matched` unchecked, but `test/dcps/matched_status_test.zig` and `src/dcps/writer.zig`/`reader.zig` show polling and listener paths are implemented for current discovery matching. The RELIABLE readiness contract may still be open, but the doc currently makes the whole status look unimplemented.
- Phase 33 says a `zig build self-interop` step is not done. There is no build step, but `.github/workflows/ci.yml` already runs self-interop directly against `dds-rtps`. The doc should distinguish "build step missing" from "CI self-interop absent."

Recommended split:

- `docs/status.md`: current implementation status and limitations, source-backed and concise.
- `docs/roadmap.md`: future work only.
- `docs/decisions.md`: stable design decisions with dates/phase links if useful.
- `docs/history.md` or keep `dev-plan.md`: historical phase log, clearly marked as historical.

### Finding: There is no documentation index

The current layout has README plus scattered docs, but no authoritative index. `zidl` has `docs/overview.md`, which is a good model: it separates user guides, reference material, and contributor references. `zzdds` should copy that pattern.

Suggested `docs/overview.md` sections:

- User guides: build/test, quick start, configuration, interop.
- Architecture references: DCPS, RTPS, discovery, transport, config, tracing.
- Feature/status: implemented features and limitations.
- Contributor references: testing strategy, design notes, decision log, roadmap.

## Accuracy Findings By Document

### `README.md`

Stale or misleading:

- "DDS-Security 1.2 support" should be "security plugin skeleton/noop only" until real auth/access/crypto paths exist.
- "RTPS 2.5 wire interoperability with Cyclone DDS, FastDDS, RTI Connext" should be limited to verified peers. The repo has Cyclone/OpenDDS interop harnesses and self-interop CI; FastDDS/RTI are future.
- "zidl sibling repo required" is obsolete for current `build.zig.zon`.
- Test count is stale.
- Implementation status is stale by several phases.
- Build flags omit `-Dcontent-subscription-profile`, which exists in `build.zig`.
- Architecture layer stack lists "DDS-Security v1.2" beside noop default without clearly marking it future.

Useful content to keep:

- High-level intent.
- Build/test commands, after updating.
- Repo layout, after adding newer directories/features and correcting status.
- Spec references, but keep "support" separate from "reference."

### `docs/architecture.md`

Useful, but several parts are stale:

- "Send path is zero-copy (scatter-gather)" and `sendmsg()` claims do not match the current `writer_sm.sendIovecs()` flattening path.
- Security is described as intercepting at the RTPS/DCPS boundary with branch-free noop pass-through. The current security interface is stored but not used by the data path.
- Build option table omits `-Dcontent-subscription-profile`.
- `-Dxtypes` description says only "Suppress PID_TYPE_INFORMATION in SEDP; registerTypeInfo() is a no-op" when false. The build help claims TypeLookup service, but no TypeLookup service exists. The architecture doc should say XTypes is partial and narrowly list implemented pieces.
- Config schema is missing current fields: `[rtps] fragment_size`, `participant.timer_clock_name`, UDP port overrides, and `data_port_separate`.
- It implies environment variable overrides are generic path-based. In source, env handling is handwritten and does not cover all schema fields.
- Discovery lists `"static"` and `"broker"` as if they are normal config choices. They exist in schema but do not have implementations.
- The logging section uses `log_scope_levels`; source docs also say this, but `src/root.zig` installs a library `std_options.logFn` for tests. The interaction between a library-provided `std_options` and application root `std_options` deserves a short verified note.

### `docs/dev-notes.md`

This is short and useful, but stale:

- Dependency layout says path dependencies pointing at sibling `zidl`; current `build.zig.zon` is URL/hash based and local package cache is under `zig-pkg/`.
- Directory example says `zz-dds/`, while the actual repo directory is `zzdds/`.
- Generated-code flags list `--pl-cdr`; build uses `--zig-pl-cdr`.
- It does not mention the URL package/fetch workflow or the empty `.gitmodules` state, while CI still includes submodule fetch steps.

### `docs/design/security-pipeline.md`

This reads like a design proposal, but is not labeled as future work. It describes:

- Payload/submessage/message protection scopes.
- Cache plaintext invariant.
- A needed `encode_payload` signature revision before Phase 9.
- MessageBuilder scratch-buffer behavior for security.

Current source state:

- Security interface remains a skeleton.
- No access-control/auth/crypto enforcement call sites exist.
- The noop crypto currently appends to an `ArrayListUnmanaged`, which contradicts the doc's "Noop path: zero overhead" statement.
- There is no implemented secure send pipeline.

Recommended action: Rename or retitle as a future design note, for example `docs/design/security-pipeline-future.md`, and add a status box at the top: "Not implemented; current code has interface skeleton and noop plugins only."

### `docs/design/rtps-message-builder.md`

The conceptual choice to build DATA headers at send time still matches source, and DATA_FRAG at send time matches source. The zero-copy/sendmsg language is stale.

Current implementation:

- `MessageBuilder` builds iovec-like slices.
- `writer_sm.sendIovecs()` flattens those slices into a `[65536]u8` stack buffer and calls `Transport.send(locator, data)`.
- `Transport` has no vectored-send method.

Recommended action: Document the current "iovec abstraction + flattening transport boundary" accurately. If true vectored I/O is still desired, make that a roadmap item.

### `docs/design/history-cache.md`

Mostly useful, but there are implementation mismatches:

- The `CacheChange.data` type in source is `[]const u8`; the doc shows `[]u8`.
- It describes writer cache as always CDR2_LE. The raw write APIs and tests pass arbitrary serialized payloads; the middleware currently stores whatever caller/generated layer provides.
- It says `DATA_REPRESENTATION` matching handles XCDR1/XCDR2 incompatibility. Source has partial support via QoS snapshots and SEDP PIDs, but this should be phrased as current partial behavior, not full XTypes support.
- It should mention known current limitations from Phase 33: KEEP_LAST is global, not per-instance; instance-handle computation still depends on inline key hash/raw handle paths rather than generated `deserializeKey`/`computeKeyHash` in the receive path.

### `docs/design/testing-strategy.md`

Good intent, but it has not been updated for the current test architecture:

- It says Tier 1 must have no sockets, no threads, no sleeping. Current tests include UDP tests, SPDP timer threads, loopback polling sleeps, and background threads under `zig build test`.
- It describes mock transport config as `drop_rate`, reorder delay, and `deliverPort()`/`dropAll()` APIs. Source has `MockNetwork.Config{ drop_nth, dupe_count }` and `deliverAll()`/`deliver()`, while more general drop policy lives in `LossyTransport`.
- It says live interop is `zig build interop-test`; actual build steps are `interop-test-cyclone` and `interop-test-opendds`.
- It lists fragmentation as future, but DATA_FRAG is implemented and tested.
- It omits `IntraProcessDelivery`, `MemoryTransport`, `DirectDiscovery`, and `LossyTransport`, which are now central to deterministic DCPS and RTPS testing.
- It says TSan is a future merge requirement once Tier 2 exists, but CI currently runs `zig build test-tsan` on Linux x86_64.

Recommended action: Rewrite this around current test tools:

- Unit and source tests.
- In-process DCPS tests with `IntraProcessDelivery`.
- RTPS protocol tests with `MockTransport`/`LossyTransport`.
- UDP transport tests.
- External interop tests.
- Self-interop CI.
- Fuzz/TSan.

### `docs/design/thread-model.md`

This document is too short for the current implementation and partly stale:

- It says "one timer thread for lease monitoring and deadline tracking." Current SPDP has a timer thread, StatefulWriter has heartbeat thread behavior, UDP listeners spawn receive threads, polling interface monitor can spawn a thread, trace async sink can spawn a flush thread, and DCPS deadline/liveliness are driven by explicit `participant.checkTimers()` rather than a participant-owned timer thread.
- It mentions `DomainParticipant.drive(timeout)` as a desired embedded/single-threaded path; no such API exists.
- It says SEDP includes TypeObjects in `DiscoveredWriterData` for remote type matching. Current source has optional TypeInformation emission for writers, omits reader TypeInformation to avoid TypeLookup stalls, and no TypeLookup service.

Recommended action: Replace this with a real current concurrency model document, with a "future single-threaded drive API" subsection.

### `docs/rtps-reference.md`

This document is useful as a reference, but it appears to contain stale/wrong PID mappings relative to the source and `idl/rtps_discovery.idl`.

Examples:

- It says `p2p_builtin_participant_message_writer/reader` are not yet in `src/rtps/guid.zig`; they are present.
- PID table values conflict with `src/rtps/pid.zig` and `idl/rtps_discovery.idl`. For example source uses `TOPIC_NAME = 0x0005`, `TYPE_NAME = 0x0007`, `PARTICIPANT_GUID = 0x0050`, `DATA_REPRESENTATION = 0x0073`, while the doc table lists different values for several of these.
- Builtin endpoint bitmask "Typical bitmask" text appears inconsistent with the listed bits and current source constants.

Recommended action: Treat this as a generated or checked reference. At minimum, annotate it as "spec notes, not source of implementation constants" and add a small validation task to keep `docs/rtps-reference.md`, `src/rtps/pid.zig`, and `idl/rtps_discovery.idl` aligned.

## Cross-Document Consistency Issues

### Security

Documents conflict on whether DDS Security is implemented:

- README says support exists.
- Architecture describes a runtime security interception path.
- Security design says a send pipeline exists conceptually.
- Dev plan later lists DDS Security as planned future work.
- Source shows skeleton/noop only and no enforcement call sites.

Recommended source of truth: Status should say "Security: interface skeleton + noop plugins; real DDS-Security not implemented."

### XTypes

Documents imply broader XTypes support than the code has:

- README lists DDS-XTypes TypeObject/TypeIdentifier as a supporting spec.
- Build help says `-Dxtypes` includes TypeLookup service.
- Architecture says `-Dxtypes=false` suppresses TypeInformation and makes `registerTypeInfo()` a no-op.
- Source implements partial DataRepresentation/TypeInformation emission and explicitly avoids TypeLookup behavior.

Recommended wording: "Partial XTypes plumbing: DataRepresentation QoS, optional local TypeInformation registration/emission; no TypeLookup service or dynamic type discovery."

### Interop

Interop claims vary:

- README says Cyclone/OpenDDS confirmed and goals include FastDDS/RTI.
- Testing strategy says `interop-test` and FastDDS future.
- Build has `interop-test-cyclone` and `interop-test-opendds`.
- CI has self-interop with `dds-rtps`, but no `zig build self-interop` step.

Recommended wording: Split "verified today" from "planned peers."

### Config

Docs imply full config precedence and path-to-env mapping. Source has a schema, a partial TOML parser, a partial env resolver, and programmatic overrides that do not cover all schema fields.

Recommended action: Add `docs/configuration.md` with a table generated or manually checked against `schema.zig`, `file.zig`, and `resolve.zig`:

| Field | Default | TOML | Env | Override | Notes |

This would immediately expose fields like `rtps.fragment_size` and port overrides that exist in schema but cannot currently be loaded from TOML/env.

### Test Status

README and testing docs are far behind current test count and test architecture. Dev plan has newer information but buries it in phase logs. Users should not need to read a 920-line dev plan to learn what tests exist.

Recommended action: Create `docs/testing.md` as current operational documentation. Move aspirational testing philosophy to a contributor note.

## zidl Documentation Cleanup Pattern To Copy

The local `../zidl` docs are a useful cleanup model:

- README is short and user-facing.
- `docs/overview.md` is a clear documentation index with user guides, reference material, and contributor references.
- Feature coverage lives in `docs/features.md`.
- Current implementation details live in `docs/implementation_status.md`.
- Future work lives in `docs/roadmap.md`.
- Backend details are split by audience and scope.
- Recent commits such as `Documentation Updates`, `More Documentation Fixes`, and `Add deferred work / gaps to roadmap` show the cleanup direction: move gaps to roadmap, keep references focused, and avoid hiding current limitations in historical notes.

Suggested zzdds equivalent:

- `README.md`: short project summary, current status, build/test, docs index link.
- `docs/overview.md`: index.
- `docs/quickstart.md`: minimal DDS pub/sub setup, current limitations.
- `docs/configuration.md`: actual supported config inputs.
- `docs/implementation_status.md`: source-backed current status and limitations.
- `docs/testing.md`: current test commands and what each covers.
- `docs/interop.md`: Cyclone/OpenDDS/self-interop setup and status.
- `docs/architecture.md`: current architecture only.
- `docs/roadmap.md`: future work.
- `docs/decisions.md`: stable design decisions.
- `docs/history.md`: optional phase log migrated from `dev-plan.md`.

## Highest Priority Documentation Fixes

1. Update README status and dependency instructions.
2. Add `docs/overview.md`.
3. Create `docs/implementation_status.md` and make README point to it.
4. Move most of `docs/dev-plan.md` out of the main reader path.
5. Correct security claims everywhere.
6. Correct zero-copy/sendmsg claims everywhere.
7. Correct config documentation and explicitly show unsupported TOML/env fields.
8. Correct RTPS PID reference or mark it non-authoritative.
9. Rewrite testing docs around current `IntraProcessDelivery`, `MockTransport`, `LossyTransport`, UDP tests, fuzz tests, TSan, and CI self-interop.
10. Add an interop status table that distinguishes Cyclone, OpenDDS, self-interop, FastDDS, and RTI.

## Suggested Current Status Text

This is a possible source-backed status summary for README or `docs/implementation_status.md`:

```md
Current status: zzdds has a working Zig-native DDS/RTPS core with UDP, SPDP/SEDP discovery,
direct in-process discovery, RTPS reliability, DATA_FRAG fragmentation/reassembly, DCPS
entity lifecycle, WaitSet/conditions, QoS matching, several QoS runtime behaviors, sample
lifecycle/read-take support, and Cyclone/OpenDDS interop harnesses.

Major gaps: DDS-Security is skeleton/noop only; XTypes is partial and does not include
TypeLookup; ContentFilteredTopic parsing/evaluation exists but automatic typed filtering
in the DataReader path is incomplete; MultiTopic is not implemented; TCP/SHMEM transports
are not implemented; some runtime behavior remains global rather than per-instance
(ownership, time-based filter, KEEP_LAST history depth).
```

## Notes On End-User Helpfulness

The current docs are more helpful to the original implementer than to a new user. A new user likely wants:

- How to add `zzdds` to a Zig project.
- What Zig version works.
- Whether `zidl` is fetched automatically.
- Minimal publisher/subscriber example.
- What features are safe to rely on.
- What interop peers are verified.
- How to configure domain, participant ID, interfaces, multicast, port overrides, fragmentation size.
- How to run tests and interop tests.
- Known limitations.

Most of that information exists somewhere, but it is scattered or stale. The cleanup should optimize for a reader who has not followed the phase history.
