# zig/catchup

Durability + `wait_for_historical_data()` reference app, talking to zzdds's
native Zig API directly. See [`docs/design/catchup-reference-app.md`](../../docs/design/catchup-reference-app.md)
at the repo root for what this example demonstrates and why
(TRANSIENT_LOCAL durability, late-joining subscriber, historical vs. live
batch). The `c/`, `cpp/`, and `java/catchup` ports do the same thing
through their respective C-ABI/JNI bindings.

Two separate binaries (`catchup_pub`, `catchup_sub`), matching
`hello_world`'s convention.

## Build and run

```sh
zig build
```

Produces `zig-out/bin/catchup_pub` and `zig-out/bin/catchup_sub`.

```sh
./zig-out/bin/catchup_pub -d 42 &
sleep 2
./zig-out/bin/catchup_sub -d 42
```

**Note the order** — publisher first, subscriber second, unlike every other
example in this repo (which start the subscriber first). That's
deliberate: the whole point is a subscriber that joins *after* the
publisher has already written its historical batch. The publisher itself
doesn't need a matched reader to write that batch — it writes immediately,
then blocks waiting for a reader to match before writing the live batch.

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

Expected output — publisher: `Create topic:` → `Create writer for topic:`
→ ten `Publisher: wrote historical seq_num=` lines → (waits for a reader)
→ `Publisher: reader matched, writing live batch` → five `Publisher: wrote
live seq_num=` lines → `Publisher: done.` Subscriber: `Create topic:` →
`Create reader for topic:` → `Subscriber: wait_for_historical_data()
returned` → `HISTORICAL BATCH COMPLETE (10 samples)` → five `LIVE SAMPLE
seq_num=` lines → `Subscriber: observed historical batch then live batch
correctly.` Both exit 0.

## Prerequisites

Same as `zig/hello_world`: Zig 0.16.0, a local `zzdds` checkout built (any
binding flags are fine — this example only needs the native Zig API) as a
sibling of `zzdds-examples` (`../../../zzdds`).
