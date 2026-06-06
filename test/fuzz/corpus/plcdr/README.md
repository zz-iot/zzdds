PL-CDR/PID corpus seeds.

Add minimized SPDP/SEDP ParameterList payloads here when fuzzing or code review
finds a decoder edge case that should be replayed outside the inline Zig
regression tests.

Interop-derived cases should use a descriptive filename:

```text
<vendor-or-ci-job>-<short-behavior>.plcdr
```

Also add a short note to the relevant Zig test, PR, or issue with:

```text
Source: <vendor/matrix/job/review finding>
Observed: <wrong behavior>
Minimized to: test/fuzz/corpus/plcdr/<file>
Expected: decoder returns an error or a valid/defaulted participant without panic/UB
```

If the case depends on endpoint lifecycle rather than ParameterList decoding,
prefer a discovery/mock-transport test instead of a byte corpus seed.
