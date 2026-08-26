# zig/registry

Keyed instance lifecycle reference app, talking to zzdds's native Zig API
directly. See [`docs/design/registry-reference-app.md`](../../docs/design/registry-reference-app.md)
at the repo root for what this example demonstrates and why (explicit
`register_instance`/`write_w_timestamp`/`dispose`/
`unregister_instance_w_timestamp`, `get_key_value`, `lookup_instance`). The
`c/`, `cpp/`, and `java/registry` ports do the same thing through their
respective C-ABI/JNI bindings.

Two separate binaries (`registry_pub`, `registry_sub`), matching
`hello_world`'s convention.

## Build and run

```sh
zig build
```

Produces `zig-out/bin/registry_pub` and `zig-out/bin/registry_sub`.

```sh
zig build run-sub -- -d 42 &
sleep 1
zig build run-pub -- -d 42
```

or run the binaries directly:

```sh
./zig-out/bin/registry_sub -d 42 &
sleep 1
./zig-out/bin/registry_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.
Fully deterministic — no timing dependency, runs in well under a second
once matched.

Expected output — publisher walks three instances (`sensor_id` 1, 2, 3)
through three different lifecycles (disposed, unregistered, left alive),
then confirms `get_key_value()` round-trips instance 1's handle back to its
key. Subscriber observes each instance's `SampleInfo.instance_state`
sequence and confirms `lookup_instance()` round-trips instance 3's key back
to the same handle its own samples carried. Both exit 0.

## Notes

- Only one `_w_timestamp` variant is exercised per operation family
  (`write_w_timestamp` on instance B, `unregister_instance_w_timestamp` on
  instance B) — see the reference doc's "deliberately out of scope" section
  for why a fourth/fifth variant for symmetry wasn't added.
- `dispose`/`unregister_instance` serialize only the key fields on the wire
  (`serializeKey`, not `serialize`) — the non-key `value` field passed to
  those calls is never actually sent, only `sensor_id` matters.

## Prerequisites

Same as `zig/hello_world`: Zig 0.16.0, a local `zzdds` checkout built (any
binding flags are fine — this example only needs the native Zig API) as a
sibling of `zzdds-examples` (`../../../zzdds`).
