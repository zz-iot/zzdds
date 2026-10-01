# Broker wire-format evidence

This directory holds the executable evidence behind the broker wire contracts: the draft
schema's identifier registry, independently derived wire vectors, and a probe that checks
zidl's generated codec against those vectors. It is not a broker implementation, a
complete protocol model or interoperability certification.

```sh
zig build test-design-models              # everything below; runs in CI
python3 scripts/check_design_specs.py     # registry and vectors only; needs only Python
zig build test-design-models --fork=../zidl   # codec probe against a local zidl checkout
```

`test-design-models` generates the draft schema's codec with zzdds's pinned zidl (v0.3.19
or later writes the XCDR2 collection DHEADERs the vectors require), compiles the probe
against its zidl-rt runtime, and runs the Python checks. It is not part of `zig build test`.

| Artifact | Coverage | Limit |
| --- | --- | --- |
| `check_broker_registry.py` | 27 active operations, 8 mutable sets, 17 discriminator namespaces; established final/removed digest shape | Mechanical schema/table consistency, not semantic admission |
| Six `broker_golden/*.py` generators | 55 byte/hash vectors, derived with `struct`/`hashlib` from the specification's byte rules | Structural values, some deliberately synthetic native payloads; no peer interoperability |
| `broker_wire_codec.zig` | 24 tests: zidl's generated codec reproduces every vector, consumes exactly, rejects the old grammar | One generator (zidl); bootstrap unknown-member handling only |

The eight mutable sets comprise four active bootstrap types, three retired legacy types
and one test-only evolution type. Unknown, missing and duplicate-member tests characterize
remaining production validation requirements; passing generated decoding does not waive them.

The generators are the independent half of the comparison: each re-derives its committed
`.hex` files and fails if they differ (`--write` regenerates them). XCDR2 sequences of
non-primitive elements (`VersionRanges`, `ControlEndpointPairs`, `ServiceDescriptors`,
`FreshnessExceptions`, `MetadataEntries`, `ParticipantIdentities`) carry a DHEADER; the
service-introduction values are XCDR1 and do not.

Network behavior, concrete clocks and skew, binding exceptions, real conditions,
memory/latency and platform integration remain acceptance tests in the
[status index](../concurrency-broker-status.md#acceptance-criteria).

## Bootstrap and established-message sizing

Complete Frame bytes exclude RTPS/transport/security wrappers. The supported-feature case
uses all v1 feature IDs (1, 2, 6); it is a structural sizing fixture, not a fully validated
registration or real canonical SPDP announcement. Measured with the codec probe and zidl
v0.3.19.

| Tag bytes | Features | Resume | REGISTER | ACCEPT | PATH |
| --- | --- | --- | ---: | ---: | ---: |
| 8 | 1, 2 | No | 372 | 468 | 192 |
| 256 | 1, 2, 6 | Yes | 700 | 796 | 192 |
| 256 | 128 IDs, schema stress only | Yes | 1200 | 1296 | 192 |

The final VIEW_SYNC Frame is 64 bytes. Body lengths if the established types were declared
with each extensibility (the schema uses final):

| Body | Mutable | Appendable | Final |
| --- | ---: | ---: | ---: |
| VIEW_SYNC | 28 | 20 | 16 |
| ORIGIN_BEGIN | 52 | 36 | 32 |
| SNAPSHOT_END | 52 | 36 | 32 |
| FRESHNESS_QUERY | 40 | 28 | 24 |
| Marker, no exceptions | 80 | 52 | 48 |
| Marker, one exception | 120 | 92 | 88 |
| Envelope, empty body/features | 52 | 28 | 24 |

## Review-era evidence (not on `main`)

The specification review also used bounded models, a synchronization prototype and a
representation-size probe. They checked the design while it was changing and are not
maintained against the contracts; they remain on the `concurrency-broker-specs` branch at
commit `05e4f36`:

| Artifact | What it checked | Limit |
| --- | --- | --- |
| [`test/design-models/*.py`](https://github.com/zz-iot/zzdds/tree/05e4f3673746ef411e5d9365ca4444e2ed4e6365/test/design-models) | Claim restoration (D7/D8), seal capacity and freshness state spaces, claim/access/condition traces, broker baseline identity, each with negative controls | Python restatements of the rules over small bounded cases; no production code |
| [`test/concurrency/`](https://github.com/zz-iot/zzdds/tree/05e4f3673746ef411e5d9365ca4444e2ed4e6365/test/concurrency) | GROUP admission ordering, request/node slot reuse with generation-checked handles, listener retirement; deterministic, threaded and TSan runs | The older GROUP admission slice only; not the INSTANCE/TOPIC write path, foreign access paths or the broker |
| [`docs/design/probes/broker_encoding_sizes.zig`](https://github.com/zz-iot/zzdds/blob/05e4f3673746ef411e5d9365ca4444e2ed4e6365/docs/design/probes/broker_encoding_sizes.zig) | The per-extensibility body lengths above | Bytes only, not speed or MCU footprint |

The production implementation's own tests supersede them; their scenarios are reflected in
the status index's acceptance criteria.
