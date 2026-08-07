# zig/hello_world

Minimal reliable pub/sub example, talking to zzdds's native Zig API
directly — no C ABI, no code generation shim in between. See
[`docs/design/hello-world-reference-app.md`](../../docs/design/hello-world-reference-app.md)
at the repo root for what this example demonstrates and why (keyless
topic, fixed RELIABLE/KEEP_ALL QoS, reader-ready-gated write loop). The
`c/`, `cpp/`, and `java/hello_world` ports do the same thing through their
respective C-ABI/JNI bindings; this one shows what it looks like with
nothing in between.

Two separate binaries (`hello_world_pub`, `hello_world_sub`), matching the
`custom-allocator`/`listener-pubsub` convention rather than `shape_main`'s
single `-P/-S` flag — one small, readable file per role.

## Build and run

```sh
zig build
```

Produces `zig-out/bin/hello_world_pub` and `zig-out/bin/hello_world_sub`.

```sh
zig build run-sub -- -d 42 &
sleep 1
zig build run-pub -- -d 42
```

or run the binaries directly:

```sh
./zig-out/bin/hello_world_sub -d 42 &
sleep 1
./zig-out/bin/hello_world_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

Expected output — publisher: `Create topic:` → `Create writer for topic:` →
`on_reliable_reader_ready() is_ready=true` → ten `Publisher: wrote count=`
lines → `on_publication_matched() current_count=0` → `Publisher: done.`
Subscriber: `Create topic:` → `Create reader for topic:` → ten `Subscriber:
received count=` lines → `Subscriber: received all 10 samples in order.`
Both exit 0.

## Notes

- `zzdds.registerTypeSupport(participant, type_name, ts)`
  (`zzdds/src/raw_ops.zig`) registers `HelloWorld`'s TypeSupport directly
  against the native Zig API — no C-ABI shim involved, unlike the other
  three bindings.
- `HelloWorld.computeKeyHashFromCdr`, generated per topic struct by zidl's
  Zig backend (`--generate-zzdds-wrappers`), matches zzdds's
  `TypeSupport.compute_key_hash` callback shape. Its `ctx` parameter is a
  `*const std.mem.Allocator` — Zig's explicit-allocator idiom, unlike C's
  global allocator override.

## Prerequisites

Same as `zig/shape`: Zig 0.16.0, a local `zzdds` checkout built (any
binding flags are fine — this example only needs the native Zig API) as a
sibling of `zzdds-examples` (`../../../zzdds`).
