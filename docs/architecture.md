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

**Send path is zero-copy (scatter-gather).** `CacheChange.data` is read-only; headers are built
on the stack; `sendmsg()` assembles everything via iovec. See `docs/design/rtps-message-builder.md`.

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
| `-Dxtypes` | true | Suppress `PID_TYPE_INFORMATION` in SEDP; `registerTypeInfo()` is a no-op |

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
Security intercepts at the RTPS/DCPS boundary; the noop path is branch-free pass-through.
See `docs/design/security-pipeline.md` for the protection scope model.

---

## Configuration Schema (`src/config/schema.zig`)

```toml
[domain]
id = 0

[participant]
name = ""                   # empty = auto
lease_duration_ms = 10000
announcement_period_ms = 3000
guid_strategy = "random"    # "random" | "host_based"

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
kind = "spdp"           # "spdp" | "static" | "broker" | custom
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
