# CI Platform Coverage Expansion — Spec

## Scope

Implements the top 4 re-ranked items from `docs/roadmap.md`'s "CI / release platform
coverage gaps" section (re-reviewed 2026-08-16). All four are chosen because none require
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

**Risk:** medium. This is the item most likely to surface real, previously-invisible bugs
per the roadmap's own reasoning (linking/ABI divergence) — that's the point of doing it, but
expect this to be the item that actually takes iteration (e.g. a Windows-specific DLL export/
`__declspec` issue, or an ARM64 calling-convention mismatch) rather than landing clean on the
first try. `java-binding` additionally depends on JNI header layout under `findJniIncludeDir`
actually matching each runner's JDK layout in practice, which has literally never been
exercised outside Linux — treat "Java smoke test found nothing" on the first Windows/macOS
run with mild suspicion (verify the JNI native lib actually got built and dlopen'd, not
silently skipped — build.zig:1053's `std.log.warn("jni.h not found ...")` fallback would make
a skip look like a pass).

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

**Risk:** low-medium. The `.use_llvm = true` forcing and TSan step itself are OS-agnostic in
build.zig already; main risk is macOS-specific runtime flakiness analogous to the
Linux ASLR issue that `examples-tsan` hit — but that was specific to TSan-runtime-vs-ASLR
interaction at process startup in a way tied to Linux's `vm.mmap_rnd_bits`, not something
known to reproduce on macOS's ASLR implementation. Budget for at least one flake-diagnosis
cycle before treating a macOS TSan failure as a real bug rather than environment noise —
same posture the Linux TSan work already established.

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
