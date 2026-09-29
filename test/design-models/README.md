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
| Six broker_golden Python scripts | 53 independent byte/hash vectors | Structural values, some deliberately synthetic native payloads; no peer interoperability |

The eight mutable sets comprise four active bootstrap types, three retired legacy types,
and one test-only evolution type. Unknown/missing/duplicate-member tests characterize
remaining production validation requirements; passing generated decoding does not waive them.

Generated codec evidence (23 tests) and current representation comparison require built
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

`docs/design/prepared_read_model.py`, `historical_transfer_model.py` and
`probes/broker_retry_retirement.py` are historical abstractions of superseded policies.
They are intentionally excluded from this runner. Other existing operation/listener
models retain their documented narrow evidence; their counts are not summed into one
runtime-conformance claim. Network, concrete clock/skew, binding exceptions, real condition
predicates, memory/latency and platform integration remain implementation acceptance tests.

Final local validation, 2026-09-29: the standalone Python runner and root
`test-design-models` target pass; generated codec tests (23) and all three representation
probes pass; isolated concurrency `test` and `test-tsan` targets pass. Local Markdown path
and active-contract anchor checks and `git diff --check` pass. No new production-network,
MCU, DDS Security or full generated-binding regression run is claimed.
