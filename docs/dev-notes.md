# Developer Notes

## Zig 0.16.0 API Changes

This codebase targets Zig 0.16.0. The following stdlib APIs changed from earlier releases
and are handled throughout the source:

| Old API | Replacement used here |
|---|---|
| `std.Thread.Mutex` | `util/mutex.zig` — wrapper over `pthread_mutex_t` |
| `std.posix.socket()` / `std.posix.bind()` etc. | `std.c.socket()` / `std.os.linux` directly |
| `std.net` (IP parsing) | `extern "c" fn inet_pton` |
| `std.crypto.random` | `std.Random.DefaultCsprng` |
| `std.time.nanoTimestamp()` | `std.os.linux` clock calls directly |
| `std.once()` | Atomic flag pattern |
| `ArrayListUnmanaged{}` init | `.empty` |
| `std.fs.cwd()` | `std.Io.Dir.cwd()` |
| `pub fn main() !void` | `pub fn main(init: std.process.Init) !void` |

`link_libc = true` is required on any module that uses libc functions directly
(sockets, pthread, etc.) — set on `zzdds_mod` in `build.zig`.

## Build Dependency Layout

`build.zig.zon` uses path dependencies pointing at the sibling `zidl` repo:

```
zz-dev/
  zidl/          ← zidl compiler + packages
  zz-dds/        ← this repo
    build.zig.zon  references "../zidl" and "../zidl/packages/zidl-rt"
```

Both repos must be checked out as siblings under the same parent for local development.
CI should clone them into the same directory structure.

## Generated Code

`build.zig` runs `zidl` at build time to generate two Zig modules:

| IDL | Output module | Flags |
|---|---|---|
| `idl/dcps.idl` | `zzdds_generated` | `-b zig --generate-interfaces --split-files` |
| `idl/rtps_discovery.idl` | `zzdds_disc_generated` | `-b zig --pl-cdr --no-typesupport --no-typeobject-support --split-files` |

Output goes into the Zig build cache (not checked in). Run `zig build gen-only` to inspect
generated output without running the full compilation.
