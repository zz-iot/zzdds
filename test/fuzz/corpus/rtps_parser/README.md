RTPS parser corpus seeds.

Add minimized packets here when fuzzing or code review finds a parser edge case
that should be replayed outside the inline Zig regression tests.

Interop-derived cases should use a descriptive filename:

```text
<vendor-or-ci-job>-<short-behavior>.rtps
```

Also add a short note to the relevant Zig test, PR, or issue with:

```text
Source: <vendor/matrix/job/review finding>
Observed: <wrong behavior>
Minimized to: test/fuzz/corpus/rtps_parser/<file>
Expected: parser returns an error or parsed submessages without panic/UB
```

If the case is better expressed as a semantic state-machine sequence than raw
bytes, prefer `test/rtps/reader_model_test.zig` or
`test/rtps/writer_model_test.zig`.
