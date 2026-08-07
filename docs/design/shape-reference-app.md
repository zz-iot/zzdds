# Shape example — what it demonstrates

A configurable, portable pub/sub example, implemented identically across all
four zzdds bindings (Zig native, C, C++, Java). Two things it's for:

1. **Cross-binding interop** — every binding speaks the same wire type, so
   any publisher/subscriber pair across Zig, C, C++, and Java can talk to
   each other, not just within one language.
2. **A CLI-driven diagnostic tool** — most DDS QoS policies and a wide range
   of runtime behavior are exposed as command-line flags, so you can
   reproduce a specific interop scenario (a QoS mismatch, a content filter,
   a coherent set, ...) without writing any code.

`zig/shape` is the reference implementation; `c/shape`, `cpp/shape`, and
`java/shape` match its CLI and behavior exactly. See each one's own README
for build/run steps.

## The type

Matches the OMG DDS interoperability demo shape, so it's meaningful input
for other DDS-interop tooling too:

```idl
struct ShapeType {
    @key string color;
    long x;
    long y;
    long shapesize;
};
```

Topic name is one of `Square`/`Circle`/`Triangle` (`-t`, default `Square`) —
these are different topics of the same `ShapeType`, not different IDL types.

## CLI

Run any binding's `shape_main`-equivalent with `-h`/`--help` for the full,
authoritative flag list — it changes independently of this doc, so this is a
summary, not a source of truth:

- **Mode:** `-P`/`-S` (publisher/subscriber, required)
- **QoS:** `-b`/`-r` (reliability), `-k` (history depth), `-D` (durability),
  `-f`/`--deadline`, `--lifespan`, `-s` (ownership strength), `-x`
  (XCDR1/XCDR2), `-p` (partition)
- **Topic/data:** `-t`, `-c` (color/key), `-z` (size), `-n` (instance count),
  `--num-topics`, `--additional-payload`, `--cft` (content filter)
- **Timing:** `-i`/`--num-iterations`, `--write-period`, `--read-period`
- **Presentation/coherent sets:** `--access-scope`, `--ordered`,
  `--coherent`, `--coherent-sample-count`
- **Other:** `-d` (domain), `-w` (print writer-side samples), `--take-read`,
  `-R` (read instead of take)

QoS here is entirely CLI-driven, built fresh per run — the `--config` file
support below is separate and doesn't affect these flags.

## Config-file support (`--config <path>`)

Point any binding at a `zzdds.toml`-style file to control participant,
transport, and discovery behavior (domain, lease duration, UDP/TCP
transport settings, static peers, port allocation, ...) without CLI flags
or code changes. `zzdds-examples/config/` has a small library of example
files — see the top-level README's "Config file library" section for what
each one isolates.

- **C/C++:** call `zzdds_process_configure_from_file(path, &allocator)`
  once, before creating the factory.
- **Zig:** the native equivalent in zzdds's `src/config/process.zig`.
- **Java:** no native wrapper for that call exists yet — `java/shape`
  works around it by copying the chosen file to `./zzdds.toml` before
  starting, which every binding (including Java) picks up automatically
  from the process's working directory.
