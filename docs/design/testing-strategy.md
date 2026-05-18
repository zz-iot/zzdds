# Zenzen DDS Testing Strategy

## Guiding Principles

**Interop over conformance.** The real bar is working correctly with Cyclone DDS, FastDDS, and
RTI Connext — not passing a spec-derived test suite. We aim to be conservative in what we send
and liberal in what we accept. Where Zenzen DDS goes beyond the spec (flow control, rate
limiting, embedded-specific extensions), tests exist at the RTPS layer, not the spec-assertion
layer. No formal conformance harness.

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

The mock implements the same `Transport` vtable as `UdpTransport`. Key behaviors:
- `send(locator, data)` enqueues the packet into a per-destination queue rather than
  sending it over a socket.
- `listen(port, handler)` registers a handler; no socket is created.
- `deliver()` drains the send queue and calls registered handlers directly — the test
  controls exactly when packets arrive.
- Configuration: per-sender drop rate, fixed reorder delay, duplication count. Composable
  with a `ManualClock` to produce deterministic timer-driven scenarios.

Two mock transport instances wired together replace the loopback UDP pair: no port
allocation, no bind, no threads, no timing sensitivity.

**What lives here:**
- SPDP: participant announcement, discovery, lease expiry (advance clock past lease
  duration), rejoin after gap
- SEDP: endpoint announcement ordering, QoS matching, proxy add/remove lifecycle
- RTPS reliability loop: inject DATA → advance clock → deliver Heartbeat → deliver
  NACK → verify retransmit; no sleeping
- Packet loss scenarios: drop DATA, verify NACK-triggered retransmit
- Reordering: deliver DATA[3] before DATA[2], verify buffering and gap fill
- Partition/rejoin: stop delivering → lease expires → reconnect → history replay
- Config flag behavior: `enable_ipv6 = false`, `enable_interface_monitor = false` —
  verify the transport path changes without needing real interfaces
- Future: flow control backpressure, rate limiter, send-window exhaustion

---

### Tier 3 — Live interop (cross-process, external vendor)

Run by `zig build interop-test`. Requires vendor implementations (Cyclone DDS, FastDDS).
Runs in CI nightly or on-demand; not required for PR merge.

**What lives here:**
- Cyclone DDS: Zenzen DDS writer → Cyclone reader; Cyclone writer → Zenzen DDS reader
- FastDDS: same scenarios (future)
- RTI Connext: same (future; requires license)
- Security handshake (future, when DDS Security plugin is implemented)
- Fragmentation: large payloads exceeding RTPS max message size (future)

**Execution model:** `test/interop/Makefile` launches peer processes, runs scenarios,
asserts outcomes. Each scenario is a self-contained process pair with a timeout. The
Makefile is the only place with real `sleep` calls (startup ordering).

---

### Tier 4 — Adversarial (fuzz and sanitizer)

Run nightly or on-demand. Separate `zig build test-fuzz` and `zig build test-tsan` steps.

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

Implementation: each fuzz target is a standalone Zig executable with a `pub fn
fuzzOne(data: []const u8) void` entry point wired to libFuzzer via a thin C shim.
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

### Why

Every time-dependent behavior in Zenzen DDS — lease expiry, heartbeat period, NACK
suppression delay, deadline QoS, lifespan QoS — currently calls `time_mod.nanoTimestamp()`
or `time_mod.sleepNs()`, which are hardcoded to `CLOCK_REALTIME` on Linux. This makes
timer-driven tests slow (real wall-clock sleeping) and non-deterministic (subject to
scheduler jitter), and it makes the code unportable to RTOSes that expose a different
clock API.

### Design

Add a `Clock` vtable to `util/time.zig`, following the same vtable pattern as `Transport`
and `Discovery`:

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

### Implementations

**`RealtimeClock`** — current behavior; wraps `CLOCK_REALTIME` via `std.os.linux.clock_gettime`.
Default for production use.

**`MonotonicClock`** — wraps `CLOCK_MONOTONIC`. Preferred for all internal timers (lease,
heartbeat, deadline) because it is not affected by NTP step adjustments or `settimeofday`.
On RTOSes this maps to the monotonic system tick counter. Should become the default for
all timer paths.

**`ManualClock`** — test-only. Wraps an `std.atomic.Value(i64)` initialized to an arbitrary
epoch. `sleep_ns` is a no-op (or optionally advances the clock by the requested amount,
for scenarios where "sleeping" should advance simulated time). Tests call `clock.advance(ns)`
to drive timers forward without any real elapsed time.

**RTOS / custom hardware** — an integrator provides their own `Clock` implementation
wrapping whatever API their platform exposes. The vtable is the only contract.

### Migration

`DomainParticipantFactoryImpl`, `SpdpEndpoints`, `SedpEndpoints`, and the RTPS state
machines all acquire a `Clock` from the factory at construction. The existing free functions
`nanoTimestamp()` and `sleepNs()` in `util/time.zig` remain as shims backed by
`RealtimeClock` for call sites that don't yet need configurability.

---

## Mock Transport Design

### Interface (`src/transport/mock.zig`)

```zig
pub const MockTransport = struct {
    alloc:   std.mem.Allocator,
    mu:      mutex_mod.Mutex,
    queue:   std.ArrayListUnmanaged(Packet),
    handlers: std.AutoHashMapUnmanaged(u32, ReceiveHandler),

    pub const Packet = struct {
        dest_port: u32,
        data:      []u8,        // owned by MockTransport
        src_loc:   Locator,
    };

    pub const Config = struct {
        drop_rate:    f32 = 0.0,   // 0.0 = no drops, 1.0 = drop all
        dupe_count:   u32 = 0,     // extra copies delivered per packet
        // Future: reorder_window: u32
    };

    config: Config,

    /// Deliver all queued packets to their registered handlers.
    /// Call from the test to advance the protocol state.
    pub fn deliver(self: *MockTransport) void { ... }

    /// Deliver only packets destined for `port`.
    pub fn deliverPort(self: *MockTransport, port: u32) void { ... }

    /// Drop all queued packets without delivering them (simulate partition).
    pub fn dropAll(self: *MockTransport) void { ... }

    pub fn transport(self: *MockTransport) Transport { ... }
};
```

Tests construct two `MockTransport` instances — one for each participant — and wire them
so that each instance's `send` enqueues into the other's queue. `deliver()` calls then
simulate network delivery with precise test control.

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
| libFuzzer | Standalone fuzz executables in `test/fuzz/` | Nightly; manual on parser changes |
| Live interop | `zig build interop-test`; external vendor binaries | Nightly or on-demand |

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
real implementations actually do. Real-world interop with Cyclone, FastDDS, and RTI
is a stronger signal than passing a conformance suite that no peer implementation was
tested against.

**Network simulation** (ns-3, CORE, etc.). The mock transport covers the protocol-level
conditions that matter (loss, reorder, duplication) without requiring a network simulator.
Physical-layer behavior (MTU, congestion, asymmetric latency) is out of scope.

**Formal verification.** Desirable eventually for safety-critical deployments; premature now.

---

## CI Structure (Target)

```
zig build test          ← Tier 1 + Tier 2; always runs; < 30s
zig build test-tsan     ← Tier 1 + Tier 2 under TSan; PRs and nightly
zig build interop-test  ← Tier 3; nightly or on-demand; requires vendor installs
zig build test-fuzz     ← Tier 4 fuzz harness launch; nightly; no timeout
```

Coverage reports and fuzz corpus updates are artifacts, not gates. TSan clean is a
merge requirement once the Tier 2 mock transport suite exists.
