# cpp/catchup

C++ port of `zig/catchup` — see
[`docs/design/catchup-reference-app.md`](../../docs/design/catchup-reference-app.md)
at the repo root for what this example demonstrates and why (TRANSIENT_LOCAL
durability, late-joining subscriber, `wait_for_historical_data()`). This
directory is just the C++-specific build/run wiring.

Uses `cpp/custom-allocator`'s CMake pattern (the "three-artifact model"),
the standard template every C++ example in this repo follows.

## Prerequisites

A local `zzdds` checkout built with the C++ binding:

```sh
cd /path/to/zzdds
zig build -Dcpp-binding=true install
```

## Build and run

```sh
cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out -B build -S .
cmake --build build
```

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/catchup_pub -d 42 &
sleep 2
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/catchup_sub -d 42
```

**Note the order** — publisher first, subscriber second (the late joiner),
same as `zig/catchup`'s own README explains.

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

## Notes

`DataWriter::set_listener`/`DataReader`'s plain `DataReaderListenerBase`
are used directly, unlike `hello_world`/`presence`'s `set_listener_ex` —
this example doesn't need `on_reliable_reader_ready`, only the spec-standard
`on_publication_matched`/`on_data_available`.
