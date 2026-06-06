# Interop Regression Intake

The live vendor matrix in CI is the interoperability gate. This directory is the
triage map for turning CI/vendor/code-review findings into fast, deterministic
regressions that run without vendor binaries.

## Where a Minimized Case Goes

Use the smallest layer that still represents the bug:

- RTPS wire bytes that crashed, misparsed, or exposed a malformed-length path:
  add a minimized file to `test/fuzz/corpus/rtps_parser/`.
- SPDP/SEDP ParameterList or PL-CDR bytes:
  add a minimized file to `test/fuzz/corpus/plcdr/`.
- ACKNACK, HEARTBEAT, GAP, retransmit, or receive-window sequencing:
  add a scripted/model case to `test/rtps/reader_model_test.zig` or
  `test/rtps/writer_model_test.zig`.
- DCPS presentation, coherent access, ordered access, waitsets, or QoS runtime:
  add a model/mock/intraprocess case under `test/dcps/`.
- End-to-end behavior that cannot yet be minimized:
  keep it in the CI shape-main matrix and file a follow-up to reduce it.

## Regression Notes Template

When adding a case, include a short note in the test or corpus README:

```text
Source: <vendor/matrix/job/review finding>
Observed: <wrong behavior>
Minimized to: <file/test name>
Expected: <invariant the test asserts>
```

The goal is not to mirror a vendor implementation. The goal is to preserve the
smallest protocol or DCPS behavior that made interop fail.
