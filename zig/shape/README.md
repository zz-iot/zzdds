# zig/shape

Native-Zig port of `dds-rtps`'s `srcZig/shape_main.zig` — the OMG
DDS-Interoperability "Shapes" demo app (`ShapeType`: a keyed `color` string
plus `x`/`y`/`shapesize`), talking to zzdds directly through its native Zig
API (no C ABI involved). One binary, `-P`/`-S` selects publisher/subscriber
mode. See `docs/design/shape-reference-app.md` at the repo root for the full
spec — this is step 1 of that plan (Zig first: the one real existing port,
lowest risk, and the CLI/behavior reference `c/shape`, `cpp/shape`, and
`java/shape` are built against once they land).

`shape_main.zig` and `dds_impl.zig` are carried over from `dds-rtps` almost
as-is — paths in `build.zig` changed, and `--config` support (see below) was
added on top, since it's a real capability dds-rtps's own `shape_main`
doesn't have; everything else, including the rest of the CLI behavior, is
unmodified so this stays the authoritative reference the other three ports
are built against. `dds_impl.zig` implements the small "dds" vendor-shim
contract `shape_main.zig` expects (participant bootstrap, QoS status/listener
glue, nil-handle checks — see the contract description in
`dds-rtps/srcZig/dds.zig` if you need the full interface), plus one addition
beyond that contract: `configureFromFile`, below. CDR serialization/key-
hashing is handled by the zidl-generated `shape_gen` module, built at
`zig build` time from `idl/shape.idl`.

## Prerequisites

- Zig 0.16.0.
- Local `zzdds` and `zidl` checkouts as siblings of `zzdds-examples` (i.e.
  `../../../zzdds` and `../../../zidl` relative to this directory) — matches
  this repo's own convention of always building against a local zzdds
  checkout (see the top-level README), and the checkout layout
  `zzdds`'s own CI uses for its `zzdds-examples` smoke-test job. No
  `zig build install` step is needed first: `build.zig.zon` depends on the
  zzdds/zidl *source trees* directly (Zig module dependencies, not the
  installed C ABI), so anything committed in those checkouts is picked up.

## Build and run

```sh
zig build                       # debug build
zig build -Doptimize=ReleaseSafe # matches zzdds's own CI (self-interop jobs)
```

Produces `zig-out/bin/shape_main`. Convenience run steps:

```sh
zig build run-pub -- -i 10 -w   # shape_main -P -i 10 -w
zig build run-sub -- -i 10      # shape_main -S -i 10
```

or run the binary directly:

```sh
./zig-out/bin/shape_main -S --read-period 200 &
sleep 1
./zig-out/bin/shape_main -P --write-period 200 -w
```

`-h`/`--help` lists the full CLI surface (QoS, topic/data, timing, and
presentation/coherent flags) — that output is the authoritative spec, not
this README; re-check it directly rather than trusting a copy here to stay
current.

Expected output: publisher prints `Create topic:` → `Create writer for
topic:` → (once a reader matches) `on_publication_matched()`, then one
`COLOR    COLOR     xxx yyy [size]` line per write when `-w` is passed;
subscriber prints `Create topic:` → `Create reader for topic:`, then one
line per received sample.

## Log level

`shape_main`'s `std.log` level defaults to matching the Zig optimize mode
(`debug` for `Debug`, `info` otherwise); override with
`zig build -Dlog-level=warn` (`err`/`warn`/`info`/`debug`) to quiet the
transport-level `debug` logging (SPDP/RTPS traces) seen in a `Debug` build.

## Config-file support (`--config <path>`)

`--config <path>` loads a `zzdds.toml`-style file and installs it as the
process-wide default participant config *before* the factory is created —
the native-Zig equivalent of `c/custom-allocator`'s
`zzdds_process_configure_from_file` (Milestone 3), calling straight through
to `zzdds`'s own `config/process.zig` (`process_config.configureFromFile`)
via `dds_impl.zig`'s `configureFromFile` wrapper. No C ABI involved. Must be
the first config-related call in the process — `main()` calls it before
`dds.createParticipant()`, which is the first point a factory gets created.

```sh
./zig-out/bin/shape_main -S --config ../../config/custom-ports.toml &
sleep 1
./zig-out/bin/shape_main -P --config ../../config/custom-ports.toml -w
```

Both sides must use the same config file for anything port/transport-related
(`custom-ports.toml`, `tcp-non-discovery.toml`, `unicast-only.toml`) — a
mismatched pair (one side configured, one on defaults) won't discover each
other, since they'd be listening/announcing on different ports.

See `zzdds-examples/config/` (repo root) for the example scenario files —
`ipv4-only.toml`, `ipv6-only.toml`, `tcp-non-discovery.toml`,
`unicast-only.toml`, `custom-ports.toml`, `short-lease.toml` — each with a
top comment on what it isolates and why. Verified two of them produce a real,
externally observable effect: `custom-ports.toml` binds port 20010 instead
of the default 7410 (checkable via `ss -uln` while a participant using it is
running), and a full pub/sub pair using it still discovers and exchanges
samples normally.

Note: `dds.configureFromFile` is called with `std.heap.c_allocator`, not
`shape_main`'s own `alloc` (a leak-checking `DebugAllocator`) — the resolved
config becomes a process-wide singleton with no matching "destroy" call, by
design (same allocator zzdds's own ambient/lazy default path already uses,
for the same reason). Routing it through `alloc` instead would report as a
leak at `gpa.deinit()`, even though nothing was actually lost.
