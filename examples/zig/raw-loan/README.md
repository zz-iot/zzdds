# zig/raw-loan

Raw/loaned `DataWriter`/`DataReader` reference app, talking to zzdds's native
Zig API directly. See
[`docs/design/raw-loan-reference-app.md`](../../../docs/design/raw-loan-reference-app.md)
at the repo root for what this example demonstrates and why (`loan_raw`/
`publish_loan_raw`/`return_loan_raw` on the write side, `take_raw` in loan
mode + `return_loan_raw` on the read side, bypassing `TypeSupport`
marshaling entirely). The `c/`, `cpp/`, and `java/raw-loan` ports do the
same thing through their respective C-ABI/JNI bindings.

Two separate binaries (`raw_loan_pub`, `raw_loan_sub`), matching
`hello_world`'s/`presence`'s convention.

## Build and run

```sh
zig build
```

Produces `zig-out/bin/raw_loan_pub` and `zig-out/bin/raw_loan_sub`.

```sh
zig build run-sub -- -d 42 &
sleep 1
zig build run-pub -- -d 42
```

or run the binaries directly:

```sh
./zig-out/bin/raw_loan_sub -d 42 &
sleep 1
./zig-out/bin/raw_loan_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

Expected output — publisher: `Create topic:` → `Create writer for topic:` →
`on_reliable_reader_ready() is_ready=true` → 5 `Publisher: published (loan)
sequence=` lines → `Publisher: cancelling loan for sequence=-1 (never
published)` → `Publisher: done.` Subscriber: `Create topic:` → `Create
reader for topic:` → 5 `Subscriber: received (loan) sequence=` lines
(`0`..`4`, strictly in order -- the cancelled `-1` never arrives) →
`Subscriber: received all 5 samples in order.`

Any failure path on either side prints a line starting `FAIL:` and exits
nonzero.
