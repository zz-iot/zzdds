# Maintained review validation

These bounded checks support the 2026-09-28 specification revisions. They are not a
production DDS implementation, complete model proof or interoperability certification.
Run independently of production aggregates:

```sh
python3 scripts/check_design_specs.py
# Equivalent root target, when its package dependencies are available:
zig build test-design-models
```

| Artifact | Coverage / current result | Limit |
| --- | --- | --- |
| review_revision_traces.py | 24 claim permutations, 144 freshness cases, 3 capacity cases; 4 negative controls | Abstract single sample, equal-rate clocks; no actual binding/transport |
| protocol_revision_model.py | Seal capacities 1/2: 81/69 states, 117/106 transitions; freshness: 2,340 states, 5,116 transitions; 3 negative controls | One writer/two sets, bounded clock/state; no universal fairness or wire decoder |
| review_contract_traces.py | 363 claim/access/condition traces, 7 nested/multiwriter seal traces, 256 horizon/clock cases | Conditions are abstract predicates; finite schedules, not complete GROUP/RTPS or synchronization implementation |
| broker_baseline_identity.py | 22 checks and 2 unsafe-shortcut counterexamples | Retention/history/compatibility are model inputs; no filter or replay engine |
| check_broker_registry.py | 27 active operations, 8 mutable sets, 17 discriminator namespaces; established final/removed digest shape | Mechanical schema/table consistency, not semantic admission |
| Six broker_golden Python scripts | 55 independent byte/hash vectors | Structural values, some deliberately synthetic native payloads; no peer interoperability |

The eight mutable sets comprise four active bootstrap types, three retired legacy types,
and one test-only evolution type. Unknown/missing/duplicate-member tests characterize
remaining production validation requirements; passing generated decoding does not waive them.

Generated codec evidence (24 tests) and current representation comparison require built
Zig/zidl executables, provided explicitly:

```sh
ZIDL_EXE=/path/to/zidl ZIG_EXE=/path/to/zig bash docs/design/probes/run_broker_wire_codec.sh
ZIDL_EXE=/path/to/zidl ZIG_EXE=/path/to/zig bash docs/design/probes/run_broker_encoding_sizes.sh
zig build --build-file test/concurrency/build.zig test
zig build --build-file test/concurrency/build.zig test-tsan
```

The codec tests cover positional exact consumption and old-grammar rejection, bootstrap
unknown-member behavior and independent bytes. The comparison changes only the measured
body types in temporary schemas; nested fixed types remain fixed. It measures bytes,
not speed or MCU footprint. The isolated Zig prototype tests exercise the older GROUP
admission/lifetime synchronization slice; they do not implement the new native/foreign
access paths, aggregate broker, or INSTANCE/TOPIC specialization.

Only the maintained artifacts listed above contribute to current validation claims.
Older experiments are excluded. Network, concrete clock/skew, binding exceptions,
real conditions, memory/latency and platform integration remain acceptance tests.

Final local validation, 2026-09-29: the standalone Python runner and root
`test-design-models` target pass; generated codec tests (24) and all three representation
probes pass; isolated concurrency `test` and `test-tsan` targets pass. Local Markdown path
and active-contract anchor checks and `git diff --check` pass. No new production-network,
MCU, DDS Security or full generated-binding regression run is claimed.

## Consolidation validation and bootstrap sizing

The annotation cleanup preserves all existing golden bytes. The added ErrorBody
present/absent vectors bring the independent inventory to 55 and the codec suite to 24.
Final members have no mutable member annotations; ErrorBody's optional flags remain.

Complete Frame bytes below exclude RTPS/transport/security wrappers. The supported-feature
case uses all v1 feature IDs (1, 2, 6); it is still a structural sizing fixture, not a
fully validated registration or real canonical SPDP announcement.

| Tag bytes | Features | Resume | REGISTER | ACCEPT | PATH |
| --- | --- | --- | ---: | ---: | ---: |
| 8 | 1, 2 | No | 368 | 464 | 192 |
| 256 | 1, 2, 6 | Yes | 696 | 792 | 192 |
| 256 | 128 IDs, schema stress only | Yes | 1196 | 1292 | 192 |

The final VIEW_SYNC Frame is 64 bytes. Representation comparison body lengths:

| Body | Mutable | Appendable | Final |
| --- | ---: | ---: | ---: |
| VIEW_SYNC | 28 | 20 | 16 |
| ORIGIN_BEGIN | 52 | 36 | 32 |
| SNAPSHOT_END | 52 | 36 | 32 |
| FRESHNESS_QUERY | 40 | 28 | 24 |
| Marker, no exceptions | 76 | 48 | 44 |
| Marker, one exception | 116 | 88 | 84 |
| Envelope, empty body/features | 52 | 28 | 24 |
