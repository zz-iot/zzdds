# Shape reference app — spec

A configurable, portable pub/sub reference app, ported identically to all
four zzdds bindings (Zig native, C, C++, Java), for two purposes:

1. **Cross-binding interop testing beyond `custom-allocator`'s fixed
   `SensorSample` scenario** — one publisher/subscriber implementation per
   binding, all speaking the same wire type, so any pub↔sub pair across all
   four bindings can be exercised, not just C↔C++ (`interop/cross-binding-smoke-test.sh`
   today only covers two of the four bindings).
2. **A config-file-driven diagnostic tool** — point any binding's instance
   at one of a small library of example `zzdds.toml` scenarios (IPv4-only,
   IPv6-only, TCP, custom ports, static peers, etc.) to reproduce/isolate a
   reported interop or config-resolution bug without writing new code each
   time.

**Only the Zig port is a real adapt-don't-reinvent candidate — C, C++, and
Java are all fresh implementations.** I initially assumed dds-rtps had
working zzdds ports of `shape_main` in Zig, C, and C++ and that this was
mostly a porting job; checked each one directly rather than trust that
assumption, and two of the three don't hold up:

- **`srcZig/shape_main.zig`** — real, tracked, committed, and it's what
  zzdds's own CI actually builds today (`self-interop`/`self-interop-tsan`
  jobs in `zzdds/.github/workflows/ci.yml` build exactly this file via `zig
  build -Doptimize=ReleaseSafe`). **This is the authoritative reference for
  CLI/behavior below, and the one binding worth literally adapting.**
- **`srcC/shape_configurator_zzdds.h` + `srcC/zzdds-cmake/`** — exist on disk
  in a local dds-rtps checkout, but `git status` shows both as untracked
  (`??`) — never committed, never pushed. Tried actually building it against
  current zzdds: `shape_main.c` (the tracked, shared C file) hardcodes
  `#include "shape_configurator_cyclone_dds.h"` and calls Cyclone's native C
  API directly throughout (`dds_write`, `dds_entity_t`, `dds_delete`, ...) —
  there's no vendor-neutral abstraction layer to swap a header under. Editing
  that one include line to point at the zzdds configurator and building
  anyway surfaces two problems, not one: (1) `shape_configurator_zzdds.h`
  hand-declares its own copies of raw zzdds C-ABI functions
  (`zzdds_write_raw`, `zzdds_create_participant_udp`, ...) that **predate the
  current `zzdds_c.h`** — e.g. its `zzdds_write_raw` signature is missing the
  `handle` parameter the real one now requires — and (2) it predates the
  zidl-generated-wrapper convention `c/custom-allocator` already uses
  cleanly. Not worth resurrecting. **Write the C port fresh**, using
  `c/custom-allocator`'s existing CMake/zidl-wrapper pattern, driven by the
  Zig reference's CLI/behavior spec below.
- **C++**: there is no zzdds integration for `srcCxx/shape_main.cxx` at all —
  no `shape_configurator_zzdds.h`, no `zzdds-cmake` directory (only
  `fast-dds-cmake`/`opendds-cmake`/`intercom-dds-cmake` exist under
  `srcCxx/`). **Write this fresh too**, using `cpp/custom-allocator`'s
  pattern, same spec.
- **Java**: as expected, no existing port anywhere. **Write fresh**, using
  `java/listener-pubsub`'s JNI patterns.

So in practice: verify/refresh the Zig port first (real code, lowest risk),
then write C and C++ fresh against the same CLI/behavior spec (each using its
sibling `custom-allocator` example as the "how do we talk to zzdds
idiomatically in this language" template), smoke-testing each against the
Zig reference as it lands, before starting Java.

## Directory layout

zzdds-examples currently has `c/`, `cpp/`, `java/` top-level directories —
**no `zig/` directory exists yet**; adding one (testing zzdds's native Zig
API directly, not through the C ABI) is part of this task. Proposed layout,
matching the existing one-example-per-directory convention:

```
zig/shape/        -- new top-level language directory
c/shape/
cpp/shape/
java/shape/
```

Each gets its own `idl/shape.idl` (byte-identical across all four — same
discipline `custom-allocator`'s `idl/sensor.idl` already follows, verified by
diffing non-comment lines), its own README, and its own build unit matching
what already exists in that language directory:

- `c/shape/`, `cpp/shape/`: own `CMakeLists.txt` (copy `custom-allocator`'s
  structure: `find_package(ZZDDS REQUIRED)`, `zidl` codegen via
  `add_custom_command`, `configure_file(... zzdds.toml ... COPYONLY)`). Add
  `add_subdirectory(shape)` to `c/CMakeLists.txt` / `cpp/CMakeLists.txt`
  (watch for target-name collisions with `custom-allocator` the way the
  `embedded`/`embedded-config` merge had to — give targets here distinct
  names, e.g. `shape_publisher`/`shape_subscriber`, not `publisher`/`subscriber`).
- `java/shape/`: own `build.sh`/`run.sh` pair (copy `listener-pubsub`'s).
  `java/build_all.sh`/`run_all.sh` already loop over every subdirectory with
  a `build.sh` — no changes needed there, just add the files.
- `zig/shape/`: no CMake — this binding is native Zig, so it should be its
  own small `build.zig` (`zig build` / `zig build run-pub` / `zig build
  run-sub`-style steps), pointed at a local zzdds via `build.zig.zon` path
  dependency or `--search-prefix`/equivalent, matching how zzdds's own
  `build.zig` already depends on `zidl`. **Needs a new top-level
  `zig/CMakeLists.txt`-equivalent entrypoint doesn't apply here — instead add
  a `zig/README.md`** documenting the plain `zig build` invocation, and wire
  it into `run-all.sh` as its own section (see "CI integration" below).

## The Shape type

Match the OMG interop demo shape exactly (this is what makes vendor-interop
tooling like dds-rtps meaningful, and there's no reason to diverge from it
here): a keyed struct with a string color key, integer x/y position, and an
integer shape size. Topic name is one of `Square`/`Circle`/`Triangle`,
selected by the `-t` flag (default `Square`) — these are three different
topics of the same type in the DDS Interoperability demo convention, not
three different IDL types.

```idl
struct ShapeType {
    @key string color;
    long x;
    long y;
    long shapesize;
};
```

## CLI surface — spec is `srcZig/shape_main.zig`, the only real existing port

Its `-h` output (in dds-rtps) is the authoritative reference for exact flag
names/defaults — read it directly rather than relying on this list going
stale. C, C++, and Java should all match this behavior exactly (see above —
none of them have a working existing port to copy, so this Zig file is the
spec they're all implemented against). Summary, grouped by priority for a
first pass:

**Must-have (v1):**
- `-P` / `-S` — publisher / subscriber mode (required, mutually exclusive)
- `-d <id>` — domain ID (default 0)
- `-t <name>` — topic name (default `Square`)
- `-c <color>` — color/key value (default `BLUE` for publisher)
- `-z <size>` — shape size, 0 = auto-increment (default 20)
- `-b` / `-r` — BEST_EFFORT / RELIABLE reliability (default RELIABLE)
- `-k <depth>` — history depth, 0 = KEEP_ALL (default KEEP_LAST 1)
- `-D v|l|t|p` — durability: volatile/transient-local/transient/persistent
- `-i, --num-iterations <n>` — stop after n samples, -1 = infinite (default)
- `--write-period <ms>` / `--read-period <ms>` — timing (defaults 33/100)
- `-w` — print each sample on the writer side (useful for manual debugging)
- `-h, --help`

**Stretch (implement only if the must-haves are solid and verified working
cross-binding first):** `-f/--deadline`, `--lifespan`, `-s` (ownership
strength), `-x` (XCDR1/2), `-p` (partition), `-n` (instance count),
`--num-topics`, `--additional-payload`, `--size-modulo`, `--cft`, presentation/
coherent-access flags (`--access-scope`, `--ordered`, `--coherent`,
`--coherent-sample-count`), `--take-read`, `-R`.

QoS (reliability/durability/history/etc.) stays **CLI- and code-driven**,
same as dds-rtps's existing shape_main — see the config-file section below
for why this can't move into the config file yet.

## New: config-file support (`--config <path>`)

This is the actual new capability dds-rtps's shape_main doesn't have.

**What's real today, verified against the current zzdds source** (don't
trust this list without re-checking — it's a snapshot): `zzdds::
DomainParticipantConfig` (`idl/zzdds.idl`) covers `domain.id`,
`participant.{name, lease_duration_ms, announcement_period_ms,
guid_strategy, timer_clock_name}`, `transport.udp.{enabled, ipv4_enabled,
ipv6_enabled, port_base, domain_gain, participant_gain, multicast groups/ttl,
interfaces, initial_peers, bind_wildcard, interface_poll_interval_ms, ...}`,
`transport.tcp.{enabled, bind_address, reuse_connection_by_host}`,
`rtps.fragment_size`, `discovery.{kind, initial_peers, static_config_file}`.

**What is declared but NOT actually applied anywhere** (verified by
grepping the runtime — `schema.Config.qos`/`QosDefaults`, converted by
`config/generated.zig`, is never read again by any entity-creation code
path): `qos.{reliability_kind, durability_kind, history_kind, history_depth}`.
**Do not build config-file-driven QoS scenarios — they will silently do
nothing.** This is a real gap in zzdds itself; if you want to fix it as part
of this work that's a legitimate (bigger, separate) task, but don't assume
it works without re-verifying first.

**Loading mechanism — reuse the exact pattern already proven in
`c/custom-allocator` and `cpp/custom-allocator` (their "Milestone 3"; read
those `README.md`s and `src/publisher.c`/`.cpp` before writing this):** call
`zzdds_process_configure_from_file(path, allocator)` **once, before creating
the factory** — not `create_participant_ex` with a manually-populated
`zzdds_DomainParticipantConfig` (there's no C-ABI "resolve a file into a
struct without installing it" entry point exposed today, only the
install-directly one, so per-call config isn't practically reachable from
C/C++ without writing your own TOML parser — don't do that). After the
`configure_from_file` call, `zzdds_create_factory()`/`create_participant()`
just works normally and picks up the resolved config as its default.

- **C/C++**: `zzdds_process_configure_from_file(path, &allocator)` — same
  call custom-allocator's Milestone 3 already makes.
- **Zig**: the native equivalent in `src/config/process.zig`
  (`configureFromFile` or equivalent — check current naming, this module has
  changed shape before) — same call, Zig-native, no C ABI involved.
- **Java: this doesn't exist yet.** `zig-out/java/io/zzdds/runtime/
  ZzddsRuntime.java` has no native method wrapping
  `zzdds_process_configure_from_file` (verified — grepped every `native`
  declaration in that file). Two options, pick based on time budget:
  - **MVP (no zzdds changes needed):** before calling `createFactory()`, copy
    the user's chosen `--config` file to `./zzdds.toml` in the process's cwd.
    Every binding (including Java, via its own ambient ProcessConfig
    lazy-resolve) already picks up a file with exactly that name/location
    with zero explicit call — this is the same mechanism
    `java/listener-pubsub`'s own `zzdds.toml` already relies on, just staged
    at run time instead of build time.
  - **Stretch:** add a real JNI wrapper for `zzdds_process_configure_from_file`
    to zzdds's Java binding (a good, self-contained zzdds follow-up PR,
    separate from this examples work) so Java doesn't need the copy trick.

## Config file collection to ship

A `zzdds-examples/config/` directory (new — doesn't exist yet) with a
handful of `.toml` files any of the four `shape` ports can be pointed at via
`--config`, each isolating exactly one of the fields confirmed real above.
Name them for what they demonstrate, not generically:

- `ipv4-only.toml` — `[transport.udp] ipv6_enabled = false`
- `ipv6-only.toml` — `[transport.udp] ipv4_enabled = false`
- `tcp-non-discovery.toml` — `[transport.tcp] enabled = true`. Naming this
  precisely matters: confirmed by reading `src/dcps/participant.zig` directly
  (see the `transport`/`discovery_transport` field comments there) that
  `transport.tcp.enabled` gives **user-data** (DataWriter/DataReader traffic)
  its own privately-owned `TcpTransport`, while SPDP/SEDP **discovery
  unconditionally stays on UDP regardless of this setting** — there's no
  "TCP for discovery too" mode, and none is planned as far as this doc knows.
  This scenario is specifically "exercise the non-discovery (user-data)
  transport over TCP while discovery still happens over UDP" — not "run
  fully over TCP," which zzdds doesn't support. Say that in the file's
  comment, not just "tcp enabled", so nobody misreads it as full-TCP.
- `unicast-only.toml` — explicit `transport.udp.initial_peers`, no
  multicast — good for reproducing "why don't these two hosts discover each
  other" reports where multicast is blocked
- `custom-ports.toml` — non-default `port_base`/gain values, to verify port
  computation and to let two independent zzdds-examples runs coexist on one
  machine without colliding
- `short-lease.toml` — small `participant.lease_duration_ms` /
  `announcement_period_ms`, for fast liveliness-expiry testing without
  waiting out the 10s default

Each file should have a one-line comment at the top saying what it isolates
and why, same style as `c/custom-allocator/zzdds.toml`'s existing comments.

## Implementation order

1. **Zig first.** Bring `zig/shape` up from `srcZig/shape_main.zig` — this is
   the one real port, lowest risk, and it becomes the CLI/behavior reference
   the other three are built against. Get it building and running standalone
   in zzdds-examples before touching any other language.
2. **C, then C++, each written fresh** against the Zig reference (not the
   stale/nonexistent dds-rtps C/C++ files — see above), using
   `c/custom-allocator` / `cpp/custom-allocator` as the "how this repo talks
   to zzdds" template. After each lands, **smoke-test it against the Zig
   port** (pub in the new language, sub in Zig, and reverse) before moving on
   — catch a binding-specific bug immediately against a known-good reference
   rather than after all three languages exist and something's wrong
   somewhere in the combinatorics.
3. **Java last**, once Zig/C/C++ are solid and cross-verified — it's the
   most work (fresh JNI-facing code, no existing reference at all) and
   benefits most from a already-proven, already-debugged CLI/behavior spec to
   build against rather than one still in flux.
4. **Config-file support** (`--config`, the file collection) can land
   alongside step 2 or 3, whenever convenient — it doesn't depend on Java and
   nothing about it is Java-specific except the loading mechanism.

**On the two gaps this doc flags — deliberately not scheduled above, address
opportunistically:**
- **`QosDefaults` not wired into entity creation** is a zzdds *core* gap,
  independent of which language is being worked on — it doesn't block any
  step here (every step uses CLI/code-driven QoS regardless). Don't fix it
  as part of this work; file it as its own separate zzdds issue/PR whenever
  someone wants config-file-driven QoS scenarios to actually do something.
- **Java's missing `zzdds_process_configure_from_file` JNI wrapper** is
  Java-specific by construction — decide MVP-copy-trick vs. real-JNI-wrapper
  when you actually reach step 3, with real information about how much
  effort is left in the budget at that point, not now.

## CI integration checklist

Everything below already has an established pattern in this repo — extend
it, don't invent a parallel mechanism:

- [ ] `c/CMakeLists.txt`, `cpp/CMakeLists.txt`: add `add_subdirectory(shape)`
- [ ] `java/build_all.sh`/`run_all.sh`: automatic (they scan subdirectories)
- [ ] `zig/` needs its own aggregator equivalent if/when more than one Zig
      example ever exists; for just one example, `run-all.sh` can invoke
      `zig build` directly in `zig/shape/`
- [ ] `run-all.sh`: add a `zig` section (gated on... there's no
      "zig-binding" concept, zzdds always builds the native Zig API; gate
      instead on the zzdds checkout being buildable at all, which
      `run-all.sh` already assumes) and extend existing sections' scope
      where `shape` binaries need to be built/run alongside `custom-allocator`
- [ ] `interop/`: either extend `cross-binding-smoke-test.sh` to include
      `shape` pairs, or add a new `interop/shape-cross-binding-smoke-test.sh`
      if the combinatorics (4 bindings) get unwieldy in one script — your
      call, but don't silently drop coverage of any binding pair
- [ ] Top-level `README.md`: add `zig/` to the layout listing, document
      `--config` and the `config/` directory
- [ ] `zzdds/.github/workflows/ci.yml`'s `examples` job already builds all
      three C-ABI-reachable bindings (`-Dc-binding -Dcpp-binding
      -Djava-binding`) and runs `run-all.sh --strict` — it needs no changes
      *unless* the Zig-native `zig/shape` section requires something the
      `examples` job doesn't already install (it already has Zig itself via
      `mlugg/setup-zig`, so likely nothing)

## Acceptance criteria

1. All four ports build clean via their normal per-language entrypoint.
2. Default invocation (no `--config`) behaves identically to today's
   `custom-allocator`-style same-language and cross-binding (C↔C++) pub/sub —
   no regression.
3. **Every binding can publish to every other binding's subscriber, in both
   directions** — not just C↔C++. At minimum, a rotation covering each of
   the four bindings as both publisher and subscriber at least once (doesn't
   have to be all 12 ordered pairs if that's too slow for CI; a ring —
   Zig→C→C++→Java→Zig — covers every binding both ways with 4 runs instead
   of 12).
4. At least two of the example config files produce an *externally
   observable* difference — e.g. `custom-ports.toml` actually binds a
   different UDP port (checkable via `ss -uln` in the smoke test), proving
   the config file was actually read and applied, not just accepted and
   ignored.
5. Java's `--config` support (whichever option was chosen above) is covered
   by at least one test case, not just implemented and unverified.

## Explicit non-goals for v1

- Coherent-set / presentation QoS, content-filtered topics, partitions —
  stretch-list CLI flags above; skip unless everything else is solid.
- Wiring `QosDefaults` into actual entity creation in zzdds core — real gap,
  worth fixing eventually, but it's a zzdds core task, not an examples-repo
  task. Don't scope-creep into it here.
- Python/.NET/Rust ports — those bindings don't exist in zzdds yet.
