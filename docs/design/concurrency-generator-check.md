# Construction reference generator check

Date: 2026-09-16. zidl main 26dc737; local Zig 0.16.0. This is a bounded generation
probe and generated-source inspection, not an end-to-end binding execution test.

Built current zidl successfully using isolated /tmp caches and install prefix.
Generated the retained fixture probes/concurrency-reference.idl for C, C++, Java and
Zig, with --generate-interfaces --no-typesupport --no-typeobject-support; additionally
generated Zig with --zig-generate-c-api --zig-generate-toml-config. All generation
commands succeeded after avoiding the case-insensitive Config/config name collision
in the initial fixture. No production generator or IDL changes were made.

## Results

| Shape | Observed result | Implication |
| --- | --- | --- |
| Interface field in Config | C opaque handle; C++ shared_ptr; Java reference; Zig fat interface view defaulted to undefined | Default Config does not safely mean nil across bindings |
| Interface sequence | Containers emitted; Zig clone copies elements without retaining object ownership | Constructor/adapter ownership needs an explicit contract |
| TOML application | Generated applyToml contains compileError for Config.runtime | Generation success does not imply callable TOML support |
| inout interface operation | C takes Ref pointer; C++ takes shared_ptr reference; Zig takes Ref by value, exported wrapper takes one opaque handle; Java takes Ref by value | Cannot publish a replacement output reference consistently |
| Config C-ABI mirror | Zig mirror retains Probe.Ref and copies c.runtime directly, while C Config holds an opaque handle | Aggregate interface-field conversion/layout is not implemented correctly for this probe |
| Mirror sequence clone | Generated conversion uses catch .{} for sequence allocation failure | Fallible construction must not silently convert failed runtime selection into an empty set |

The mirror finding follows directly from emitted declarations, not a reproduced
memory-corruption test. Java/JNI runtime behavior and C++ aggregate bridging were not
compiled or exercised. The build reported Java tools unavailable. No retain/release
or multiple-inheritance runtime fixture has yet been run.

Reproduce with a built zidl, for example:

```
zidl -b zig --generate-interfaces --no-typesupport --no-typeobject-support \
  --zig-generate-c-api --zig-generate-toml-config \
  -o /tmp/reference-check docs/design/probes/concurrency-reference.idl
```

Ordinary backend probes omit the two --zig-* flags and substitute -b c/cpp/java/zig.
Generated artifacts for this run are in /tmp/zidl-ref-probe; the source fixture is
retained in the design tree. Source inspection: zig.zig emitStructApplyTomlFn /
memberApplyTomlSupported rejects interface types; generated probe confirms the path.

## Recommended specification adjustment

Preserve Config-taking _ex entity construction. Do not put process-local references
into the existing recursively TOML-applied DomainParticipantConfig until an explicit
construction-only field mechanism exists. Recommend separating file-loadable scalar
settings from construction-only reference options inside the public configuration
model, with a generator-supported exclusion/conversion rule. This preserves the
preferred constructor shape but requires deliberate zidl work; a nested struct alone
will not fix recursive applyToml rejection.

Two implementable routes need a choice before signature freeze:

1. Extend zidl with construction-only members/types: safe nil initialization, explicit
   TOML exclusion (reject attempts to set excluded fields), correct C-ABI conversion,
   fallible reference/sequence conversion and documented reference transfer. Keep a
   Config argument containing both settings and construction-only options.
2. Keep scalar Config unchanged and pass references through a separate versioned
   construction-options envelope at the bootstrap/API boundary. This avoids changing
   file parsing but still needs correct interface output and reference ownership, and
   changes the proposed public constructor shape if exposed directly.

Prefer route 1 for the user's chosen _ex(..., Config) pattern. Do not silently ignore
arbitrary unsupported fields or silently manufacture nil on conversion failure.
No annotation spelling is selected yet.

Separately fix inout interface result generation before using try_acquire_owner's
proposed signature, or adopt an explicitly reviewed result-object mapping. Changing
to an output struct is not an automatic workaround: aggregate handle conversion is
also affected. Standalone reference wrappers require lease semantics independent of
DDS entity deletion and existing cached entity-box lifetime conventions.

## Exit criteria

A generator follow-up must compile and exercise scalar/sequence reference fields,
nil defaults, inout replacement, allocation failure, base/extension aliases and
retain/release across all four bindings. TOML must still apply scalar settings while
rejecting attempts to configure live references. Existing participant config loading
must remain covered. The current concurrency design is not invalidated, but its draft
IDL is not ready to freeze or advertise as supported until this dependency is resolved.
