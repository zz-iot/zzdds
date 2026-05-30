# Zenzen DDS — Running the Test Suite

## Quick start

```sh
zig build test           # all tests (600+); < 30s on a modern machine
zig build test-tsan      # same tests under ThreadSanitizer
zig build test-fuzz      # compile-check fuzz targets; corpus regression runs in zig build test
```

## What `zig build test` covers

**Tier 1 — unit tests:**
- RTPS message parser + builder (all submessage types, endianness, edge cases)
- History cache (KEEP_LAST eviction, KEEP_ALL growth, depth boundary cases)
- `StatefulWriter` state machine (AckNack cases, Heartbeat emission)
- `StatefulReader` state machine (Heartbeat handling, out-of-order DATA, GAP, duplicate SN)
- DATA_FRAG fragmentation + reassembly
- SequenceNumber arithmetic (high/low word boundary rollover)
- QoS matching (all 22 policies, compatible + incompatible combinations)
- Config resolver (env var overrides, TOML file parsing, precedence order)
- Time utilities

**Tier 2 — in-process DCPS tests (IntraProcessDelivery):**
- DCPS loopback: BEST_EFFORT and RELIABLE, KEEP_LAST/KEEP_ALL
- Instance lifecycle: ALIVE → DISPOSED → resurrected → UNREGISTERED
- `read()` / `take()` with all state filter combinations
- `WaitSet` + `ReadCondition` + `StatusCondition` + `GuardCondition` + `QueryCondition` lifecycle/state-mask triggering
- `on_publication_matched` / `on_subscription_matched` callbacks
- `ContentFilteredTopic` delivery-time filtering and `QueryCondition` read/take filtering
- RESOURCE_LIMITS enforcement
- QoS runtime enforcement (OWNERSHIP, DEADLINE, LATENCY_BUDGET, PARTITION, DURABILITY, TIME_BASED_FILTER, LIFESPAN, LIVELINESS)
- `LivelinessChangedStatus` / `on_liveliness_changed` (reader-side per-writer lease expiry via ManualClock)
- `SampleLostStatus` / `on_sample_lost`; `SampleRejectedStatus` / `on_sample_rejected`
- Fuzz corpus regression (RTPS parser, PL-CDR deserializer)

**Mock transport tests (in Tier 2 binary):**
- SPDP: announcement, discovery, lease expiry, rejoin
- SEDP: endpoint announcement, QoS matching, proxy lifecycle
- RTPS reliability: inject DATA → advance clock → Heartbeat → NACK → verify retransmit
- Packet loss, reorder, partition/rejoin scenarios

## ThreadSanitizer

```sh
zig build test-tsan
```

Runs the full Tier 1 + Tier 2 suite with TSan enabled. Catches data races in receive
threads, SPDP/SEDP callbacks, and any shared state accessed without the mutex.

## Fuzz harnesses

```sh
zig build test-fuzz      # compile-check fuzz targets (fast; no installed fuzz binary)
```

Fuzz targets are in `test/fuzz/`:
- `fuzz_rtps_parser.zig` — arbitrary bytes to RTPS message parser; assert no crash/UB/overrun
- `fuzz_plcdr.zig` — arbitrary bytes to PL-CDR/PID deserializer (SPDP/SEDP)

To run the fuzzer directly (requires LLVM's libFuzzer), build the fuzz source as an object
and link it with `clang -fsanitize=fuzzer,address`. The exact commands are documented in
the comments at the top of each fuzz source file.

There is intentionally no `zig build test-fuzz-bin` step today; `zig build test-fuzz`
compile-checks the fuzz targets but does not install runnable fuzz executables.

## Live interop tests

The local developer targets require an installed peer implementation and are not part of
`zig build test`.

```sh
zig build interop-test-cyclone   # requires Cyclone DDS; set CYCLONE_ROOT or see test/interop/Makefile
zig build interop-test-opendds   # requires OpenDDS at OPENDDS_ROOT
```

Each scenario is a self-contained process pair run by `test/interop/Makefile`:
- Basic pub/sub (Zenzen writer → peer reader; peer writer → Zenzen reader)
- Fragmented data (DATA_FRAG, large payload exceeding `fragment_size`)

CI also gates the dds-rtps `shape_main` matrix against the pinned release binaries for
Cyclone DDS, FastDDS, OpenDDS, and RTI Connext in both publish and subscribe directions,
including ThreadSanitizer runs for the Zenzen DDS side.

## Test design philosophy

See `docs/design/testing-strategy.md` for the tier model, clock abstraction rationale,
and notes on what we are *not* building (spec conformance harness, network simulation,
formal verification).
