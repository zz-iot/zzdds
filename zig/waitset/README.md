# zig/waitset

`WaitSet` + all four DDS condition types (`GuardCondition`,
`StatusCondition`, `ReadCondition`, `QueryCondition`), talking to zzdds's
native Zig API directly — no C ABI. See
[`docs/design/waitset-reference-app.md`](../../docs/design/waitset-reference-app.md)
at the repo root for what this example demonstrates and why (WaitSet-driven
flow instead of listeners, a background watchdog thread for a real
concurrency exercise, and the publisher deliberately deleting its writer
without detaching an attached condition first, to demonstrate that's safe).

Two separate binaries (`waitset_pub`, `waitset_sub`), matching
`hello_world`'s convention.

## Build and run

```sh
zig build
```

Produces `zig-out/bin/waitset_pub` and `zig-out/bin/waitset_sub`.

```sh
zig build run-sub -- -d 42 &
sleep 1
zig build run-pub -- -d 42
```

or run the binaries directly:

```sh
./zig-out/bin/waitset_sub -d 42 &
sleep 1
./zig-out/bin/waitset_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

Expected output — publisher: `Create topic:` → `Create writer for topic:` →
`Publisher: reader matched` → ten `Publisher: wrote count=` lines →
`Publisher: reader disconnected` → `Publisher: StatusCondition remained
attached through delete_datawriter (safe).` → `Publisher: done.` Subscriber:
`Create topic:` → `Create reader for topic:` → `Subscriber: writer matched`
→ a mix of `Subscriber: high-priority count=` (5 lines, `count` 5–9) and
`Subscriber: low-priority count=` (5 lines, `count` 0–4) → `Subscriber:
received all 10 samples.` → `Subscriber: done.` Both exit 0.

## Prerequisites

Build zzdds first (no bindings needed — this example is pure Zig):

```sh
cd /path/to/zzdds
zig build install
```
