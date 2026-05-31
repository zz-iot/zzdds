# Zenzen DDS Architecture

## Key Design Decisions

**RTPS framing is NOT a plugin.** It is Zenzen DDS core. Transport carries RTPS messages
(opaque byte buffers to/from locators). If a future zero-copy SHMEM path needs to bypass
RTPS framing entirely, that will be a separate "fast channel" plugin added later.

**Discovery sits above transport.** The default SPDP/SEDP implementation uses the transport
plugin directly. Alternative discovery implementations (static config, broker) may open their
own connections or read files.

**Allocator strategy.** Always accept `std.mem.Allocator` explicitly at call sites. No global
allocator. Users can bring an arena allocator for sample-heavy paths.

**DomainParticipantFactory is not a singleton.** It is an explicitly-constructed struct holding
transport(s), discovery plugin, security plugins, and config.

**History cache stores bytes, not structs.** Both writer and reader caches hold serialized CDR
payloads. See `docs/design/history-cache.md`.

**Send path uses iovec assembly.** `CacheChange.data` is read-only (`[]const u8`); headers
are built on the stack. The iovec list is flattened to a stack buffer at the transport
boundary (`Transport.send`). See `docs/design/rtps-message-builder.md`.

**Configuration precedence (highest to lowest):**
`Programmatic API → Environment variables (ZZDDS_*) → Config file (TOML) → Built-in defaults`

Config file search order: `$ZZDDS_CONFIG` → `./zzdds.toml` → `~/.config/zzdds/config.toml`

**Conditional compilation (build-time feature flags).** Dead-code elimination for constrained targets:

| Flag | Default | Effect when false |
|---|---|---|
| `-Dipv4` | true | Exclude IPv4 UDP transport |
| `-Dipv6` | true | Exclude IPv6 UDP transport |
| `-Dinterface-monitor` | true | Enumerate NICs once at startup |
| `-Dwire-trace` | false | `Tracer` is zero-size; all trace calls are dead-code eliminated |
| `-Dguid-filter` | false | No GUID-prefix filter in wire trace (only meaningful with wire-trace) |
| `-Dxtypes` | true | When false: suppress `PID_TYPE_INFORMATION` in SEDP announcements. Note: no TypeLookup service is implemented; XTypes type discovery from remote participants is not supported regardless of this flag. |
| `-Dcontent-subscription-profile` | true | When false: disable the ContentFilteredTopic/QueryCondition SQL parser and evaluator (DDS v1.4 Annex A). MultiTopic is not implemented. |

Usage in source: `const opts = @import("build_options"); if (opts.wire_trace) { ... }`

---

## Plugin Interfaces

### Transport (`src/transport/interface.zig`)

Lowest layer. Sends/receives raw byte buffers to/from locators. Zero knowledge of RTPS framing.

```zig
can_reach(locator) bool
send(locator, data) !void
listen(port, handler) !void   // logical registration; transport manages actual socket set
unlisten(port) void
unicast_locators(out) !void
set_locator_change_handler(cb) void
close() void
```

Multiple transport instances can be active; RTPS picks the transport per locator via `can_reach`.

### InterfaceMonitor (`src/transport/monitor/`)

Detects NIC changes; notifies `UdpTransport` to update its socket set. Vtable-based so
implementations can be swapped and compiled out with build flags.

```zig
pub const InterfaceMonitor = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,
    pub const Vtable = struct {
        start: *const fn (ctx: *anyopaque, cb: ChangeCallback) anyerror!void,
        stop:  *const fn (ctx: *anyopaque) void,
    };
};
pub const ChangeCallback = struct {
    ctx: *anyopaque,
    on_change: *const fn (ctx: *anyopaque) void,
};
```

Implementations (gated by build options):
- `monitor/polling.zig` — enumerate + diff every N ms (default, all platforms)
- `monitor/netlink.zig` — Linux NETLINK_ROUTE (deferred)
- `monitor/pf_route.zig` — macOS/BSD PF_ROUTE (deferred)
- `monitor/windows.zig` — NotifyIpInterfaceChange (deferred)

### Discovery (`src/discovery/interface.zig`)

Discovers participants and endpoints; delivers events to DCPS via callbacks.

```zig
start(local_participant_info, callbacks) !void
announce_writer(info) !void   retract_writer(guid) void
announce_reader(info) !void   retract_reader(guid) void
stop() void

// Callbacks delivered to DCPS:
on_participant_discovered / on_participant_lost
on_writer_discovered / on_writer_lost
on_reader_discovered / on_reader_lost
```

### Security (`src/security/interface.zig`)

Three sub-plugins: Authentication, AccessControl, Cryptographic. Default: `security/noop.zig`.
The security interface is plumbed through the RTPS/DCPS boundary but has no active
enforcement in the current data path — only the noop pass-through is implemented.
See `docs/design/security-pipeline.md` for the intended protection scope model.

### IntraProcessDelivery (`src/delivery/intraprocess.zig`)

A bundle that wires `MemoryTransport` and `DirectDiscovery` together for deterministic
in-process testing. Used by all DCPS-level tests added in Phase 29 and later.

```zig
var delivery = try IntraProcessDelivery.init(alloc);
defer delivery.deinit();

const t_w = try delivery.newTransport();
const d_w = try delivery.newDiscovery();
var factory_w = try DomainParticipantFactoryImpl.init(
    alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .random, .{});
```

Each participant gets its own `MemoryTransport` and `DirectDiscovery` instance from the
shared `MemoryBus` / `DiscoveryBus`. Endpoint matching and data delivery are synchronous
with no timer threads. BEST_EFFORT QoS is fully supported; use `MockTransport` for
RELIABLE protocol-level tests (see `docs/design/testing-strategy.md`).

### MemoryTransport (`src/transport/memory.zig`)

Synchronous in-process transport. `send()` delivers immediately via a shared `MemoryBus`
port→handler map — no queue, no `deliverAll()` pump. Assigns each participant a fake
IPv4 address derived from its participant ID for locator routing.

### DirectDiscovery (`src/discovery/direct.zig`)

In-process discovery without SPDP/SEDP. When a writer or reader is announced, all
participants sharing the `DiscoveryBus` are notified synchronously, triggering immediate
QoS matching. No UDP packets, no timer threads, no leases.

### LossyTransport (`src/transport/lossy.zig`)

A transport shim that wraps any `Transport` and applies a `PacketPolicy` to each outgoing
`send()`. Built-in policies:

- `DropEveryNth` — drop every Nth packet (deterministic, 1-indexed)
- `DropRate` — drop each packet with probability p (0.0–1.0)
- `DropFirst` — drop the first N packets then pass all remaining

```zig
var policy = LossyTransport.DropEveryNth.init(3);
var lossy = try LossyTransport.init(alloc, inner_transport, policy.packetPolicy());
defer lossy.deinit(alloc);
```

Used in RELIABLE retransmit and NACK-triggered resend tests.

### ClockRegistry (`src/util/clock_registry.zig`)

Maps string names to `Clock` instances. Pre-populated with `"default"` / `"monotonic"` /
`"realtime"` / `"boottime"`. The `timer_clock_name` config field selects which clock
`DomainParticipantFactoryImpl` uses for all internal timers. Custom clocks can be registered
before creating a factory.

### ContentFilteredTopic and QueryCondition evaluator (`src/dcps/filter.zig`)

SQL-subset parser and evaluator for `ContentFilteredTopic.filter_expression`. Gated by the
`-Dcontent-subscription-profile` build option. When false, parsed expressions are disabled
and the evaluator returns "match".

Supported grammar: comparison (`=`, `<>`, `<`, `<=`, `>`, `>=`, `LIKE`), `BETWEEN`,
`AND`, `OR`, `NOT`, parameter references (`%0`–`%99`), and dot-path field names.

The `FieldAccessor` vtable lets a typed wrapper or generated deserializer supply field
values without the filter module depending on generated code. Readers get that accessor
from `TypeSupport.get_field`. `ContentFilteredTopic` readers apply the expression before
enqueueing samples; `QueryCondition` applies its expression during `read()` / `take()`.
If a type has no registered field accessor, expressions are treated as unevaluable and
samples pass through.

---

## Configuration Schema (`src/config/schema.zig`)

The table below mirrors the full in-memory schema. Programmatic configuration can set all
fields. TOML/env coverage currently lags the schema: `file.zig` / `resolve.zig` do not yet
parse or override `participant.timer_clock_name`, the `[rtps]` section, or the UDP
`meta_unicast_port` / `data_unicast_port` fields.

```toml
[domain]
id = 0

[participant]
name = ""                   # empty = auto
lease_duration_ms = 10000
announcement_period_ms = 3000
guid_strategy = "random"    # "random" | "host_based"
timer_clock_name = "default" # clock used for all timers: "default" | "monotonic" | "realtime" | "boottime"

[rtps]
fragment_size = 16384       # max RTPS message size before DATA_FRAG splitting (bytes)

[transport.udp]
enabled = true
ipv4_enabled = true         # hard override; auto-detected per-interface otherwise
ipv6_enabled = true

# RTPS port formula (§9.6.1.1): PB + DG×domain_id + PG×participant_id + offset
port_base = 7400            # PB
domain_gain = 250           # DG
participant_gain = 2        # PG
meta_multicast_offset = 0   # D0
meta_unicast_offset = 10    # D1
data_multicast_offset = 1   # D2
data_unicast_offset = 11    # D3

# null = auto-assign (try min_valid..max_valid until bind succeeds)
participant_id = null

# Override computed port numbers (null = use RTPS formula)
meta_unicast_port = null
data_unicast_port = null

# Interface names ("eth0") or IPs ("192.168.1.5"). Empty = all interfaces.
interfaces = []

multicast_group_v4 = "239.255.0.1"
multicast_group_v6 = "ff02::1"
multicast_ttl = 1

# false = bind to interface IP (Cyclone style); true = bind to 0.0.0.0 / ::
bind_wildcard = false

recv_buffer_size = 0          # 0 = OS default
interface_poll_interval_ms = 5000

[discovery]
kind = "spdp"           # "spdp" (implemented) | "static" | "broker" (planned) | custom
initial_peers = []      # e.g. ["192.168.1.100:7400"]
static_config_file = ""

[qos.defaults]
reliability = "best_effort"
durability  = "volatile"
history_kind = "keep_last"
history_depth = 1
```

Environment variable overrides use `ZZDDS_` prefix + path in uppercase:

```
ZZDDS_DOMAIN_ID=5
ZZDDS_TRANSPORT_UDP_MULTICAST_GROUP_V4=239.255.0.2
ZZDDS_DISCOVERY_KIND=static
ZZDDS_DISCOVERY_STATIC_CONFIG_FILE=/etc/zzdds/peers.toml
```

---

## Logging (`src/log.zig`)

All diagnostic log output uses scoped loggers defined in `src/log.zig`.
Do not call `std.log.*` directly — use the appropriate scope:

| Scope | Constant | Used in |
|---|---|---|
| `zzdds_rtps` | `log.rtps` | `src/rtps/` |
| `zzdds_spdp` | `log.spdp` | `src/discovery/spdp.zig` |
| `zzdds_sedp` | `log.sedp` | `src/discovery/sedp.zig` |
| `zzdds_transport` | `log.transport` | `src/transport/` |
| `zzdds_dcps` | `log.dcps` | `src/dcps/` |

Applications control verbosity at compile time in their root module:

```zig
pub const std_options = std.Options{
    .log_scope_levels = &.{
        .{ .scope = .zzdds_rtps,      .level = .debug },
        .{ .scope = .zzdds_spdp,      .level = .err   },
        .{ .scope = .zzdds_sedp,      .level = .warn  },
        .{ .scope = .zzdds_transport, .level = .warn  },
        .{ .scope = .zzdds_dcps,      .level = .warn  },
    },
};
```

Scopes not listed default to the process-wide `std.options.log_level`.
For runtime filtering, override `std_options.logFn`.

---

## Wire Trace (`src/trace.zig`)

A second, independent observability system for structured RTPS wire events. Zero overhead when
disabled — `Tracer` is a zero-size struct and every `tracer.submit(...)` call is dead-code
eliminated at compile time (requires `-Dwire-trace=false`, the default).

Enable at build time:

```sh
zig build -Dwire-trace=true
zig build -Dwire-trace=true -Dguid-filter=true   # + GUID-prefix filter
```

**Synchronous output (stderr):**

```zig
var buf: [256]u8 = undefined;
var stderr_writer = std.Io.File.stderr().writer(io, &buf);
var sink = trace.SyncSink{ .writer = &stderr_writer, .format = .text };
factory.setTraceConfig(.{ .sink = sink.sink() });
```

**Async ring buffer to file:**

```zig
var file  = try std.Io.Dir.cwd().createFile(io, "trace.ndjson", .{});
// set up a file writer (see std.Io.File.Writer) and pass its *std.Io.Writer to AsyncRingSink
var asink = try trace.AsyncRingSink.init(alloc, 4096, file_writer_ptr, .ndjson);
try asink.startFlushThread();
factory.setTraceConfig(.{ .sink = asink.sink() });
// ... use factory ...
asink.deinit();  // flushes remaining events before returning
```

**Output formats:** `.ndjson` (one JSON object per line) or `.text` (short human-readable lines).

`TraceConfig` is stored on `DomainParticipantFactoryImpl` and applied to every participant and
state machine it creates. For discovery state machines (SPDP/SEDP), wire the tracer before
passing to the factory:

```zig
const tc = trace.TraceConfig{ .sink = my_sink.sink() };
disc_impl.setTracer(tc.tracer());   // wires SPDP + SEDP tracers
factory.setTraceConfig(tc);         // wires user DataWriter/DataReader tracers
```

**Key types:** `TraceEvent` (tagged union covering all RTPS submessages + `skipped`),
`GuidFilter` (empty slice = accept all), `Sink` vtable, `SyncSink`, `AsyncRingSink`,
`NoopSink`, `Tracer`.
