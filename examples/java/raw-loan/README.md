# java/raw-loan

Java port of `zig/raw-loan` — see
[`docs/design/raw-loan-reference-app.md`](../../../docs/design/raw-loan-reference-app.md)
at the repo root for what this example demonstrates and why
(`loan_raw`/`publish_loan_raw`/`return_loan_raw` on the write side,
`take_raw` in loan mode + `return_loan_raw` on the read side, bypassing
`TypeSupport` marshaling entirely). This directory is just the
Java/JNI-specific build/run wiring.

Uses `java/hello_world`'s JNI build pattern (`build.py`/`run.py`,
`ZzddsRuntime`).

## Prerequisites

- A zzdds checkout built with `zig build -Djava-binding=true install`.
  Needs the read-loan JNI fix (see the reference doc's "A real bug found
  building the Java port" section) — a zzdds built before that lands will
  build this example, but `Subscriber` will either hang (no data ever
  released back to it) or, in the worst case, crash with a native heap
  corruption error depending on allocator behavior.
- `JAVA_HOME` set to a full JDK.
- Python 3.10+.

## Build and run

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build.py
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run.py -d 42
```

or run `Subscriber`/`Publisher` as two separate JVM processes directly
(see `run.py` for the exact `java` invocation). `-d`/`--domain <id>`
(default 0) is the only flag either class takes.

`build.py` accepts a `ZIDL_EXECUTABLE` override, same as `java/hello_world`.

## Notes

Same `Loaned_ping.LoanedPing` (not `LoanedPing.LoanedPing`)
outer-wrapper-class naming quirk as `java/hello_world`'s own note — zidl's
Java backend names the generated file's outer class from the IDL file's
stem (`loaned_ping` → `Loaned_ping`), separately from the struct's own
name.

Unlike every other example in this repo, the publisher/subscriber never
touch the generated typed `LoanedPingDataWriter`/`LoanedPingDataReader`
wrapper classes at all — this example's whole point is exercising the
*raw* `loan_raw`/`publish_loan_raw`/`return_loan_raw`/`take_raw` ops on
`Dcps.DDS.DataWriter`/`DataReader` directly, serializing/deserializing by
hand via the generated `LoanedPing.serialize`/`deserializeFrom`.

The read-loan API's `loanHandles` out-parameter (`java.nio.ByteBuffer[3]`,
passed to `take_raw` and back to `return_loan_raw` unchanged) is
JNI-internal plumbing, not something this example's app logic needs to
understand — treat it as an opaque receipt.
