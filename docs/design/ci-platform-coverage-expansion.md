# CI Platform Coverage Expansion — Spec

## Scope

Implements the top 4 re-ranked items from `docs/roadmap.md`'s "CI / Release Platform
Coverage" section (re-reviewed 2026-08-16). All four are chosen because none require
new external infrastructure (no vendor binaries for non-Linux, no code-signing, no release
pipeline redesign) — they extend tooling and jobs that already exist and already work on
Linux x86_64 to platforms `ci.yml`/`release.yml` already run bare `zig build test` on.

Explicitly **not** in this spec (deferred to later roadmap items, unchanged ranking 5-10):
real vendor/self RTPS interop on non-Linux, Intel macOS runners, `release.yml` binding
builds, musl targets, prebuilt release binaries, Valgrind alternatives.

## Current state (verified against `ci.yml`/`release.yml`/`build.zig` on 2026-08-16)

| Job | Platforms | What it runs |
|---|---|---|
| `test-linux` (ci.yml) | Linux x86_64 only | `run_deterministic_matrix.py --include-tsan` (Debug, feature-minimal, ReleaseSafe, TSan), `-Ddebug-allocator=true`, `test-bindings -Dc-binding -Dcpp-binding` |
| `test-other` (ci.yml) | Linux ARM64, macOS ARM64, Windows x86_64 | bare `zig build test --test-timeout 60s` — nothing else |
| `test` (release.yml) | Linux x86_64, Linux ARM64, macOS ARM64, Windows x86_64 | `zig build test` everywhere; `zig build test-tsan` gated `if: matrix.os == 'ubuntu-latest'` only |

Three facts from `build.zig` that bound what's actually achievable, confirmed by reading the
code (not assumed):

- **`test-bindings` (C/C++ smoke tests) is pure Zig-build-system.** It compiles C/C++ smoke
  test sources via Zig's own `addExecutable`/`addRunArtifact`, not by shelling out to
  `cmake`/`gcc`/`cl.exe`. This means it should build on Windows/macOS without any extra
  toolchain install — `zig cc`/`zig c++` handle it. (The separate, heavier
  zzdds-examples CMake-based C++ example apps are a different code path, not touched here.)
- **Java/JNI header discovery is already OS-aware.** `findJniIncludeDir()` (build.zig:11-28)
  already switches on `linux`/`darwin`/`win32` include-dir layout. It has never been
  *exercised* on darwin/win32 in CI, but the code path exists and isn't Linux-only by
  construction.
- **`-Dsanitize-thread=true` has no OS gating in build.zig.** The `.use_llvm = true` forcing
  (needed because Zig 0.16's default self-hosted x86_64 backend silently no-ops TSan
  instrumentation under Debug) applies unconditionally. ThreadSanitizer itself is a
  Clang/LLVM feature supported on Linux and macOS (x86_64/ARM64) — not Windows, which is why
  item 3 targets macOS only.

## Item 1 — DebugAllocator lane on `test-other`

**Change:** add a `DebugAllocator lane` step to `test-other` (ci.yml), identical in form to
`test-linux`'s existing step:

```yaml
- name: DebugAllocator lane (default allocator path only, additive to the matrix above)
  run: zig build test -Ddebug-allocator=true
```

**Platforms:** Linux ARM64, macOS ARM64, Windows x86_64 (all three — nothing in this lane is
platform-conditional).

**Risk:** low. This is `std.heap.DebugAllocator`, pure Zig, already proven on Linux. The only
plausible new finding is a genuinely platform-specific allocator interaction, which is the
point.

## Item 2 — C/C++/Java bindings on the 3-platform matrix

**Change:** extend `test-other` to also build+run the binding smoke tests, mirroring
`test-linux`'s `zig build test-bindings -Dc-binding=true -Dcpp-binding=true` step, plus wire
in Java:

```yaml
- name: C/C++ binding smoke tests
  run: zig build test-bindings -Dc-binding=true -Dcpp-binding=true

- name: C/C++/Java binding smoke tests (with Java)
  run: zig build test-bindings -Dc-binding=true -Dcpp-binding=true -Djava-binding=true
```

(exact step split TBD during implementation — may end up as one step once JDK setup is
added; sketched as two above only to separate "needs JDK" from "doesn't").

**Needs added to `test-other`:**
- `actions/setup-java@v4` (temurin, java-version 21) — mirrors the `examples` job's existing
  step, which today only runs on `ubuntu-latest`. `setup-java` itself supports Windows/macOS
  runners already; this is a new usage, not new tooling.
- Windows already has the UDP firewall rule (`netsh advfirewall ... zzdds-test-udp`) from the
  existing `Test` step — binding smoke tests that open real sockets are covered by the
  existing rule, no new firewall change expected.

**Platforms:** Linux ARM64, macOS ARM64, Windows x86_64.

**Risk:** medium, assessed pre-implementation — correctly predicted "expect this to take
iteration," undershot by how much. **Outcome (PR #65, 2026-08-17): C/C++ landed on all three
platforms. Java/JNI landed on Linux ARM64 and macOS. Java/JNI on Windows is deferred, not
achieved**, after three rounds of real bugs found and fixed/investigated:

1. **`UnsatisfiedLinkError: ... Can't find dependent libraries`** — confirmed and fixed.
   Windows PE/COFF has no `rpath` equivalent (unlike Linux/macOS, where Zig auto-adds one
   when one build-graph library links another), and `-Djava.library.path` only pointed at
   `zzdds_jni.dll`'s own build-cache directory, not wherever `zzdds.dll` (its dependency)
   actually ended up. Fixed in `build.zig`: both libraries now install to the same real
   directory (`.bin` on Windows, since `InstallArtifact` treats a `.dll` as `isDll()`), and
   that directory is added to `PATH` via `run.addPathDir(...)`.
2. **`EXCEPTION_STACK_OVERFLOW` inside `zzdds.dll`**, crashing at the first native call
   (`createFactory()`) — despite that same call succeeding natively (no JNI) moments earlier
   in the same CI job. Hypothesis: the JVM's default native thread stack (~1MB on Windows)
   is smaller than this call path needs, while Linux/macOS pthread defaults (~8MB) have
   enough headroom. "Fixed" with `-Xss8m` — this eliminated the stack-overflow signature.
3. **`java.exe` exits with code 9, zero output**, same crash site, appeared *after* fix #2 —
   a different, previously-masked failure, not caused by `-Xss8m` itself. Windows Defender
   was the leading hypothesis (freshly-built unsigned native DLL, dynamically loaded via
   JNI, on a runner with Defender active by default) — ruled out: an explicit workspace
   exclusion was confirmed applied (via Defender's own config-change log) well before the
   crash, and Defender's operational log shows no detection/block action anywhere near the
   crash time. Explicit `-XX:ErrorFile`+`-XX:+CreateMinidumpOnCrash` flags were added to
   force a crash file to a known-writable location — still produced nothing, which is
   conclusive: the JVM's own crash handler never runs at all, not just writes somewhere
   unexpected. Combined with zero Windows Error Reporting "Application" log entry, this
   points at something terminating the process in a way that bypasses SEH entirely. Leading
   (unconfirmed) hypothesis: **Control Flow Guard**. `jvm.dll` ships CFG-instrumented on
   Windows; JNI is extremely function-pointer-heavy (the `JNIEnv*` passed to every native
   method is a large vtable); `zig cc`-built DLLs are not known to be CFG-instrumented. An
   indirect call across that boundary rejected by CFG enforcement would explain the total
   silence — but this needs a live debugger (WinDbg) on real Windows hardware to confirm,
   which CI cannot provide. A self-contained investigation brief (exact repro command, full
   chronological trail, suggested next steps: check CFG status via `dumpbin`, attach a
   debugger before the crash rather than post-mortem, isolate JNI from a minimal
   non-JNI C harness) was written and handed off separately for whoever picks this up next
   — not committed to this repo.

`java-binding`'s dependency on `findJniIncludeDir` actually matching each runner's JDK layout
did turn out to be fine on Linux ARM64 and macOS — no issues there, contrary to this
section's original "treat with mild suspicion" caution.

## Item 3 — TSan extended to macOS (unit-test level only)

**Change:** run `zig build test-tsan` (and `test-tsan-self-check`, the regression guard that
proves TSan instrumentation itself hasn't silently gone inert — see
`decision-...tsan-allocator-expansion` history) on macOS ARM64, in both `ci.yml` and
`release.yml`.

- `ci.yml`: `test-other`'s macOS leg gets an additional conditional step (`if: runner.os ==
  'macOS'`), or macOS is split into its own small job — implementation-time call, see plan.
- `release.yml`: `test` job's `Test (TSan)` step condition changes from
  `matrix.os == 'ubuntu-latest'` to `matrix.os == 'ubuntu-latest' || matrix.os ==
  'macos-latest'`.

**Explicitly out of scope for item 3:** the `examples-tsan` job (C/C++ waitset/shape/
custom-allocator example binaries built+run under TSan via CMake, with the `zig c++` wrapper
and the GNU-ld/libstdc++ constructor-ordering fix, and the ASLR `sysctl` workaround). Those
fixes were diagnosed against Linux/glibc/GNU-ld specifics; macOS uses a different linker
(ld64/lld) and libc++, not libstdc++, so none of the existing workarounds are known to be
needed *or* sufficient there. Extending `examples-tsan` to macOS is real, separate work
deferred to its own follow-up — not assumed by this item.

**Windows:** not attempted. Clang/LLVM TSan has no supported Windows target; this is a hard
tooling limitation, not a prioritization choice.

**Risk:** low-medium, assessed pre-implementation — turned out too optimistic. **Outcome
(PR #65, 2026-08-17): NOT LANDED, deferred.** Even the minimal `test-tsan-self-check` (two
threads, one deliberate race, no zzdds code at all) segfaults on macOS ARM64
(`macos-latest`) with zero sanitizer output before any application code runs. Ruled out:

- **macOS's nano-malloc-zone interaction** (`MallocNanoZone=0`, a real, documented
  TSan-vs-macOS issue) — tried, did not help.
- **The Linux ASLR/shadow-memory-layout class of bug** this section originally predicted —
  ruled out by reading Zig's bundled `libtsan` source directly: that failure path
  (`tsan_platform_posix.cpp`'s `CheckAndProtect`, shared between Linux and macOS) always
  prints a `WARNING`/`FATAL` diagnostic via sanitizer `Printf` (which bypasses libc
  buffering specifically so crash-adjacent output survives) before exiting cleanly. Zero
  output before a real SIGSEGV rules this path out.

Most likely cause based on that same source read: `InitializePlatform()`
(`tsan_platform_mac.cpp`) calls Apple's private, undocumented
`pthread_introspection_hook_install` API during TSan's startup constructor — sanitizer
runtimes breaking against private Apple APIs after the OS/Xcode version drifts from under a
pinned LLVM release is a long-established failure class for TSan/ASan on macOS. GitHub's
`macos-latest` image moves independently of Zig's release cadence, so a mismatch between
"macOS version the runner is on" and "what Zig 0.16.0's bundled compiler-rt TSan was
built/tested against" is plausible. No matching open issue found in `ziglang/zig`'s tracker.
This looks like an upstream Zig/LLVM gap, not something fixable from zzdds's CI config —
revisit when Zig bundles a newer LLVM, or if someone can reproduce/bisect on real macOS
hardware (this diagnosis was done entirely by reading source; nothing here was verified by
actually running on macOS).

## Item 4 — `ReleaseFast` built and tested

**Change, two parts:**

1. **`scripts/run_deterministic_matrix.py`**: add a `release-fast` step, same shape as the
   existing `release-safe` step:
   ```python
   Step("release-fast", [zig, "build", "test", "-Doptimize=ReleaseFast"]),
   ```
   Add `"release-fast"` to the `--only` choices list. This step runs automatically as part of
   `test-linux`'s existing `run_deterministic_matrix.py --include-tsan` call — no separate
   `ci.yml` wiring needed for Linux x86_64.

2. **`release.yml`**: add a `Test (ReleaseFast)` step to the `test` job's matrix, unrestricted
   by platform (unlike TSan, ReleaseFast has no OS-level tooling limitation):
   ```yaml
   - name: Test (ReleaseFast)
     run: zig build test -Doptimize=ReleaseFast
   ```

**Explicitly out of scope for item 4:** building the `self-interop` shape_main binary in
ReleaseFast (it stays ReleaseSafe, the deliberate safety-checked release-gate build) — that's
part of item 5 (interop-platform expansion), not this item. This item is about proving the
optimize mode itself compiles and passes the unit suite, not about extending the interop
gate's build mode.

**Risk:** medium, for a different reason than items 1-3: ReleaseFast strips runtime safety
checks (bounds, overflow, `unreachable`) and turns violations into UB instead of a panic. Any
test in the suite that depends on a safety-check panic actually firing (e.g. asserting a
specific panic message, or relying on `unreachable` being reached deterministically as a
"this path is impossible" check) may behave differently or not at all under ReleaseFast.
**This needs to be run locally first** (`zig build test -Doptimize=ReleaseFast`) before
wiring it into CI, specifically to find any such test and either fix it (make the assertion
`Debug`/`ReleaseSafe`-only, or rewrite it to not depend on safety-check panics) rather than
discover it as a confusing CI failure.

## Cross-cutting implementation notes

- **CI runtime cost.** `test-other`'s current 20-minute timeout (ci.yml:98, sized off a past
  Windows hang investigation) will need re-budgeting once it also runs
  DebugAllocator + bindings (+Java/JDK) + conditionally TSan. Suggest measuring actual added
  wall-clock per platform during implementation rather than guessing a new number upfront.
- **No new secrets/credentials.** Nothing here needs anything beyond what `test-linux`
  already uses (Zig, JDK via `setup-java`, zig's own C/C++ toolchain).
- **Ordering:** items 1 and 2 are independent and can land as separate PRs in either order.
  Item 3 (TSan) is independent of both. Item 4 is fully independent of 1-3 (different files:
  `run_deterministic_matrix.py` + `release.yml`, no `test-other` changes at all) and is the
  safest to land first if a low-risk starting point is wanted, *except* for the ReleaseFast
  safety-check caveat above, which should be checked locally regardless of landing order.
