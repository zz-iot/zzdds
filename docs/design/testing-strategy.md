# Zenzen DDS Testing Strategy

## Guiding Principles

**Interop over conformance.** The current verified bar is working correctly with Cyclone DDS
and OpenDDS; FastDDS and RTI Connext remain planned interop targets. We aim to be
conservative in what we send and liberal in what we accept. Where Zenzen DDS goes beyond the
spec, tests exist at the RTPS layer, not the spec-assertion layer. No formal conformance
harness.

**Avoid sleeping in tests.** Every `time_mod.sleepNs(...)` in a test is CI latency and a
potential flake. Time-dependent behavior (lease expiry, heartbeat timers, deadline) is tested
by advancing a controllable clock, not by waiting for wall time to pass.

**Test at the right layer.** The loopback test exercises the full DCPS → RTPS → transport →
RTPS → DCPS stack, which is valuable as a regression baseline. But edge cases in RTPS state
machines, discovery lifecycle, and timer behavior should be tested one layer down with a mock
transport and a controllable clock — cheaper to write, faster to run, and more precise about
what broke when they fail.

---

## Test Tiers

### Tier 1 — In-process, deterministic (fast unit tests)

Run by `zig build test`. Must stay under 30 seconds. No external dependencies, no sockets,
no threads (where possible), no sleeping.

**What lives here:**
- RTPS message parser and builder: all submessage types, endianness, edge cases in length fields
- History cache: KEEP_LAST eviction policy, KEEP_ALL growth, depth=1/N/∞ boundary cases
- StatefulWriter state machine: all AckNack cases (non-final+bitmap, final+empty, unknown reader,
  multiple proxies), heartbeat emission (firstSN/lastSN, empty cache, count monotonicity)
- StatefulReader state machine: Heartbeat handling (non-final+missing SNs, final+complete,
  stale count suppression, unknown writer), out-of-order DATA buffering, GAP handling,
  duplicate SN discard
- SequenceNumber arithmetic: high/low word boundary rollover, SEQUENCENUMBER_UNKNOWN sentinel
- QoS matching: all 22 policies, compatible and incompatible combinations
- Config resolver: env var overrides, TOML file parsing, precedence order
- Time utilities: timestamp conversion, RTPS timestamp round-trip accuracy
- DCPS loopback (existing): BEST_EFFORT single, RELIABLE single, KEEP_LAST depth=1, KEEP_ALL

**What does NOT live here:**
Anything that requires real sockets, real wall-clock timing, or external processes.

---

### Tier 2 — Mock transport (in-process, controlled delivery)

Run by `zig build test`. Same binary as Tier 1; mock transport tests live alongside the
others. No external dependencies, no real sockets.

The mock transport is the primary enabler for testing discovery, lease timers, reliability
protocol edge cases, and future features (flow control, rate limiting) without the overhead
of real UDP or the imprecision of wall-clock timing.

**Mock transport interface** (`src/transport/mock.zig`):

The mock implements the same `Transport` vtable as `UdpTransport`. A `MockNetwork` owns the
shared routing fabric; individual `MockTransport` instances join that network with their
test-chosen locators. Key behaviors:
- `send(locator, data)` enqueues the packet into a per-destination queue rather than
  sending it over a socket.
- `listen(port, handler)` registers a handler; no socket is created.
- `MockNetwork.deliverAll()` drains one delivery round across all member transports.
- `MockTransport.deliver()` drains one transport's queue.
- Configuration lives on `MockNetwork.Config`: `drop_nth` drops every Nth packet, and
  `dupe_count` delivers extra copies.

Two mock transport instances in the same `MockNetwork` replace the loopback UDP pair: no
port allocation, no bind, no threads, no timing sensitivity.

**What lives here:**
- SPDP: participant announcement, discovery, lease expiry (advance clock past lease
  duration), rejoin after gap
- SEDP: endpoint announcement ordering, QoS matching, proxy add/remove lifecycle
- RTPS reliability loop: inject DATA → advance clock → deliver Heartbeat → deliver
  NACK → verify retransmit; no sleeping
- Packet loss scenarios: drop DATA, verify NACK-triggered retransmit
- Reordering: deliver DATA[3] before DATA[2], verify buffering and gap fill
- Partition/rejoin: stop delivering → lease expires → reconnect → history replay
- Config flag behavior: `-Dipv6=false`, `-Dinterface-monitor=false` —
  verify the transport path changes without needing real interfaces
- Future: flow control backpressure, rate limiter, send-window exhaustion

---

### Tier 3 — Live interop (cross-process, external vendor)

Run by `zig build interop-test-cyclone` or `zig build interop-test-opendds`. Requires the
corresponding vendor implementation. FastDDS and RTI Connext scenarios are planned but do
not have build steps yet. Runs in CI nightly or on-demand; not required for PR merge.

**What lives here:**
- Cyclone DDS: Zenzen DDS writer → Cyclone reader; Cyclone writer → Zenzen DDS reader
- OpenDDS: same scenarios (implemented)
- FastDDS: same scenarios (planned)
- RTI Connext: same (planned; requires license)
- Security handshake (planned, when DDS Security plugin is implemented)

**Execution model:** `test/interop/Makefile` launches peer processes, runs scenarios,
asserts outcomes. Each scenario is a self-contained process pair with a timeout. The
Makefile is the only place with real `sleep` calls (startup ordering).

---

### Tier 4 — Adversarial (fuzz and sanitizer)

Run nightly or on-demand. `zig build test-fuzz` compile-checks the fuzz entry points;
corpus regression tests run as ordinary Zig tests under `zig build test`.

**Fuzz targets** (`test/fuzz/`):

The most important property to fuzz is: *no out-of-bounds access when processing
untrusted network data.* Length fields in RTPS packets and PID parameter lists are the
primary attack surface — a single unchecked length can turn a packet into an arbitrary
memory read.

- `fuzz_rtps_parser.zig` — feed arbitrary bytes to the RTPS message parser; assert no
  crash, no UB, no buffer overrun
- `fuzz_plcdr.zig` — feed arbitrary bytes to the PL-CDR/PID deserializer used in SPDP
  and SEDP; same assertions
- `fuzz_cdr_payload.zig` (future) — lower priority; CDR payloads are currently opaque bytes, but
  once we have type-safe binding layers this becomes important

Implementation: each fuzz target exposes `pub fn fuzzOne(data: []const u8) void`.
`zig build test-fuzz` compile-checks those targets; runnable libFuzzer executables are
built manually by compiling the Zig source to an object and linking with LLVM's libFuzzer.
Corpus lives in `test/fuzz/corpus/`.

As DDS Security is implemented, add fuzz targets for the authentication and crypto layers;
a security-capable implementation must be robust against junk data from unauthenticated peers.

**Sanitizer step** (`zig build test-tsan`):

Runs the full Tier 1 + Tier 2 test suite with ThreadSanitizer enabled. In `build.zig`:

```zig
// Add to the sanitizer test step:
t.root_module.sanitize_thread = true;
```

TSan will catch data races in the transport receive threads, the SPDP/SEDP callbacks,
and any shared state accessed without the mutex. This is especially important before
adding flow control or any new concurrent path.

Debug and ReleaseSafe modes already provide bounds checking and integer overflow
detection — these are always active in `zig build test` at no additional cost.

---

## Clock Abstraction

The `Clock` vtable is implemented in `util/time.zig` (added in Phase 31):

```zig
pub const Clock = struct {
    ctx:    *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        now_ns:   *const fn (ctx: *anyopaque) i64,
        sleep_ns: *const fn (ctx: *anyopaque, ns: u64) void,
    };

    pub fn nowNs(self: Clock) i64        { return self.vtable.now_ns(self.ctx); }
    pub fn sleepNs(self: Clock, ns: u64) { self.vtable.sleep_ns(self.ctx, ns); }
};
```

Four implementations are provided:

**`RealtimeClock`** — wraps `CLOCK_REALTIME`. Available but not used for internal timers.

**`MonotonicClock`** — wraps `CLOCK_MONOTONIC`. Default for all internal timers (lease,
heartbeat, deadline) — unaffected by NTP step adjustments or `settimeofday`.

**`BoottimeClock`** — wraps `CLOCK_BOOTTIME`. Available; useful for embedded suspend/resume
scenarios.

**`ManualClock`** — test-only. Tests call `clock.advance(ns)` or `clock.set(ns)` to drive
timers forward. `sleep_ns` waits for the logical clock to advance, waking periodically so
timer threads can observe shutdown flags.

`DomainParticipantFactoryImpl` selects the clock by name via `ClockRegistry`
(`timer_clock_name` config field; default: `"monotonic"`). See `src/util/clock_registry.zig`
and `docs/architecture.md`.

---

## Mock Transport Design

### Interface (`src/transport/mock.zig`)

```zig
pub const MockNetwork = struct {
    pub const Config = struct {
        drop_nth: u32 = 0,     // 0 = never drop; N = drop every Nth packet
        dupe_count: u32 = 0,   // extra copies delivered per packet
    };

    pub fn setConfig(self: *MockNetwork, cfg: Config) void { ... }

    /// Deliver one round across all member transports.
    /// Packets enqueued during this call arrive on the next deliverAll().
    pub fn deliverAll(self: *MockNetwork) void { ... }
};

pub const MockTransport = struct {
    /// Deliver all packets currently queued for this transport.
    pub fn deliver(self: *MockTransport) void { ... }

    pub fn queueLen(self: *MockTransport) usize { ... }
    pub fn transport(self: *MockTransport) Transport { ... }
};
```

Tests construct one `MockNetwork`, then create one `MockTransport` per participant with
distinct locators. `deliverAll()` calls simulate network delivery with precise test
control.

### Integration point

The mock transport plugs in at exactly the same seam as `UdpTransport`: passed to
`DomainParticipantFactoryImpl.init`. No changes to the RTPS or DCPS layers are required.
Alternatively, mock transport instances can be handed directly to RTPS state machines
for tests that don't need the full DCPS stack.

---

## Tooling Summary

| Tool | How | When |
|---|---|---|
| GPA leak/UAF detection | `std.testing.allocator` in all tests | Always (`zig build test`) |
| Bounds + overflow checks | Zig Debug mode (default for test) | Always |
| ThreadSanitizer | `root_module.sanitize_thread = true` | `zig build test-tsan` (PRs, nightly) |
| LLVM coverage | `zig test` + `-fprofile-instr-generate`; `llvm-cov report` | Nightly CI script |
| libFuzzer | Source entry points in `test/fuzz/`; runnable executables are built manually with LLVM's libFuzzer | Nightly; manual on parser changes |
| Live interop | `zig build interop-test-cyclone` / `interop-test-opendds` | Nightly or on-demand |

**On static analysis:** Zig's compiler eliminates many C-style static analysis targets
(buffer overruns caught by bounds checks, no silent integer promotions, no implicit casts
between pointer types). No mature Zig-specific linter exists yet. Comptime evaluation
reduces the runtime surface that a linter would otherwise need to cover.

**On safety certification (DO-178C, IEC 61508, ISO 26262):** Long-term concern.
Zig's design properties are favorable: no hidden control flow, no exceptions, no RAII
surprises, deterministic memory layout, comptime elimination of dead paths. Keep these
in mind when designing new APIs — prefer explicit allocation, avoid dynamic dispatch
on hot paths where determinism matters, and keep platform abstraction layers thin and
auditable. Formal verification tooling for Zig is not yet mature enough to plan around.

---

## What We Are Not Building

**Spec conformance harness.** A system that maps OMG spec section numbers to executable
assertions sounds attractive but is expensive to maintain and often diverges from what
real implementations actually do. Real-world interop with Cyclone DDS and OpenDDS is a
stronger signal than passing a conformance suite that no peer implementation was tested
against; FastDDS and RTI Connext remain planned targets.

**Network simulation** (ns-3, CORE, etc.). The mock transport covers the protocol-level
conditions that matter (loss, reorder, duplication) without requiring a network simulator.
Physical-layer behavior (MTU, congestion, asymmetric latency) is out of scope.

**Formal verification.** Desirable eventually for safety-critical deployments; premature now.

---

## CI Structure (Target)

```
zig build test                  ← Tier 1 + Tier 2; always runs; < 30s
zig build test-tsan             ← Tier 1 + Tier 2 under TSan; PRs and nightly
zig build interop-test-cyclone  ← Tier 3; requires Cyclone DDS at CYCLONE_ROOT
zig build interop-test-opendds  ← Tier 3; requires OpenDDS at OPENDDS_ROOT
zig build test-fuzz             ← Tier 4 fuzz harness compile-check
```

Coverage reports and fuzz corpus updates are artifacts, not gates. TSan clean should be a
merge requirement for changes that touch transport, discovery, WaitSet, or shared DCPS state.
