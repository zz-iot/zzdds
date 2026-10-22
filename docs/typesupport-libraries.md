# Experimental typesupport library registration

The opt-in Zig `zzdds.typesupport` API loads multiple generated wire typesupport
libraries, selects exports explicitly and registers them with DDS participants.
It also accepts static descriptors through the same lifetime/registration model.
The contract remains experimental. Linux has native validation; macOS and Windows
loader backends are implemented and cross-compiled, with native qualification still
pending. This is not a frozen ABI or a profile parser.

The library contract belongs to zidl; the loader and DDS registration adapter
belong to zzdds. Entity construction still uses the existing DDS API. This feature
introduces no agent-specific entity catalog or competing configuration format.

## Development build

zzdds pins zidl `v0.3.22-zig.0.17.0`, which includes the experimental descriptor
ABI and generator. Enable the feature without a separate checkout:

```sh
zig build -Dtypesupport-library=true
```

The ABI helpers and generator come from the same pinned dependency and share the
host's `zidl_rt` module. Ordinary builds keep the feature disabled. Optional
`-Dtypesupport-package=/absolute/path/to/zidl/packages/zidl-typesupport` and
`-Dtypesupport-generator=/absolute/path/to/zidl/zig-out/bin/zidl` overrides remain
available for cross-project development. This is a native Zig API; no C/Java
loader API is promised.

Generate/build the application libraries with the recipe in zidl's
`packages/zidl-typesupport/README.md`. Libraries operate on C descriptors and wire
bytes, so their private generated Zig objects never cross into the host's runtime.

## Load, inspect, select and register

The following fragment shows ownership and ordering using existing DDS construction:

```zig
var libraries = try zzdds.typesupport.Manager.init(allocator, 16);
defer libraries.deinit();
try libraries.load("project_a", "/absolute/path/libproject_a_types.so");
try libraries.load("project_b", "/absolute/path/libproject_b_types.so");

const provider = try libraries.acquire("project_a");
defer provider.deinit();
for (provider.types()) |descriptor| {
    const name = descriptor.name.data[0..@intCast(descriptor.name.size)];
    std.debug.print("export: {s}\n", .{name});
}
const selected = try provider.select("Telemetry::Reading");
defer selected.deinit();

var owner = try zzdds.createFactory();
defer owner.deinit();
const factory = owner.toDDSFactory();
const participant = factory.create_participant(0, .{}, null, 0);
if (participant.ptr == zzdds.dcps.NIL_PTR) return error.ParticipantCreationFailed;
defer _ = factory.delete_participant(participant);

// Registration precedes creation of any topic of this type.
const registration = try zzdds.typesupport.register(participant, selected);
defer registration.deinit();
const topic = participant.create_topic("Readings", selected.name(), .{}, null, 0);
const publisher = participant.create_publisher(.{}, null, 0);
var xcdr1 = [_]i16{0};
const writer = publisher.create_datawriter(topic, .{
    .data_representation = .{ .value = .{
        ._maximum = 1, ._length = 1, ._buffer = &xcdr1, ._release = false,
    } },
}, null, 0);

// complete_cdr contains the four-byte DDS encapsulation plus exact sample bytes.
// Configure representation explicitly to match the payload and discovery.
try registration.write(writer, .alive, complete_cdr);
```

`Provider`, `Selection` and `Registration` own references. Copying their values
is not an ownership operation; release each acquired handle once. `Selection.clone`
explicitly acquires another reference. Descriptor slices are borrowed and require
an owning view/selection/registration or another provider pin throughout use.
The manager's allocator must remain valid through all outstanding references,
including after manager destruction. Concurrent manager operations or final releases
require a thread-safe backing allocator. Factory/entity allocators likewise must
outlive deferred entity retirement.

`Manager.select(provider, name)` is the direct alternative to acquiring an inspection
view first. `Selection.validate` and `keyHash` expose checked wire operations.
`Registration.write` checks participant/type association, sample validity and writer
representation, derives the key and then calls the existing raw write path.
Lifecycle writes use genuine key-only CDR. Bypassing this helper with raw writer
APIs does not gain its sender-side validation.

## Registration and conflicts

Handwritten native `TypeSupport` registrations should supply `.has_key = Type.has_key`
from their generated type for key-hash handling. Legacy registrations retain their
previous RTPS endpoint kinds for compatibility with older adapters that omit this
field. Checked provider registrations use their explicit descriptor keyedness to
choose keyed/keyless endpoint kinds.

A provider export is not automatically registered in every participant. Registration
copies the name and pins the chosen provider. It must precede any topic with that
type name; this closes the race with endpoint construction taking keyedness and
callback snapshots. Each participant/type name selects exactly one generation.

- Repeating registration of the same provider generation/type is idempotent.
- Equivalent exports from another generation/provider produce
  `EquivalentProviderAlreadyRegistered`; the existing provider remains installed.
- Different minimal identities under an already-registered name produce
  `ConflictingTypeRegistration`.
- A pre-existing ordinary typesupport entry produces `TypeAlreadyRegistered`.
- A first registration after topic creation produces `TypeInUse`.
- Legacy registration cannot replace a pinned library entry.

Names and provider provenance remain distinct even when `Selection.equivalent`
reports equal minimal TypeIdentifiers. This does not test assignability or native
object ABI compatibility. No type aliases, callback mixing or implicit load-order
winner is introduced. The host performs the descriptor/hash/dependency checks in
the experimental zidl contract, not a complete canonical TypeObject parsing audit.

The participant owns its registration independently of returned handles. A protocol
reader acquires a further pin before publication and releases it only at physical
teardown. Deferred/in-flight work can therefore outlive participant deletion without
unloading its provider. Final releases occur outside registry/participant/reader
locks. There is no early participant-type unregistration operation in this slice.

## Generation replacement and removal

```zig
try libraries.replace("project_a", "/absolute/path/libproject_a_types_v2.so");
try libraries.remove("project_b");
```

`replace` opens and verifies a candidate before publishing it for future selections.
A failed candidate preserves the old mapping. Use separately named immutable
artifacts; the same artifact path is rejected. Do not overwrite mapped files or use
symlinks/path aliases to pretend an existing artifact is new code.

Existing views, selections, registrations and protocol readers keep the old generation.
A newly selected provider may be registered with a new participant, but it cannot
silently replace an existing participant registration. A caller may deliberately
continue using a previously acquired selection. Removing a provider prevents new
manager acquisitions; the OS library handle is closed on the final reference release.
The loader may retain an image after that close (macOS dyld does so for these
providers); physical unmapping is not guaranteed. `liveGenerations`
includes retired but still referenced generations, which count against the configured
limit along with candidates. Thus old users cannot bypass the resource bound by
repeatedly removing/reloading libraries. This bounds owned generations, not memory
that the OS loader chooses to retain after closing a handle.

Manager load/acquire/select/replace/remove operations are synchronized. Manager
`deinit` requires concurrent manager operations to have stopped; existing independent
handles may remain alive. No filesystem watcher, multi-provider atomic configuration
transaction, live callback swap, native-object migration or schema migration is
implemented. Generation IDs are diagnostic process-local identities, not persistent
schema identifiers.

`addStatic(provider, descriptor)` skips OS loading, but the caller must keep descriptor
storage and callback code valid until all users retire. Build with
`-Dtypesupport-dynamic=false` to omit the OS loader while retaining the same Manager,
Selection and participant registration API. `load`/`replace` then return
`DynamicLoadingUnavailable`; static descriptors remain usable. This is a hosted
zzdds API, not a new freestanding DDS runtime. The zidl descriptor contract is also
available independently of this service.

## Platform loading and qualification

All dynamic candidates require absolute, NUL-free artifact paths. Relative names
are rejected rather than resolved through the process working directory. Continue
to use distinct immutable artifacts for replacement.

- Linux and macOS use Zig's native POSIX dynamic loader. Dependency resolution
  follows that OS loader's rules.
- Windows accepts fully qualified UTF-8 paths, converts them to UTF-16 and uses
  `LoadLibraryExW`/`GetProcAddress`/`FreeLibrary`. Rooted paths without a drive/share
  are rejected. Dependency search is restricted to the candidate DLL's directory
  and System32; it does not search PATH/current-directory or change global search
  policy. Keep private dependencies alongside their provider DLL. Loaded DLLs must
  remain immutable until all users retire; file replacement/deletion is not the
  reload interface.
- `dynamic_loading_available` reports whether the backend is compiled in for this
  target, not whether the platform has passed native qualification. Other OS targets
  can use the static path where zzdds itself builds; dynamic loading returns
  `DynamicLoadingUnavailable`.

Library artifacts are specific to OS/architecture: `.so`, `.dylib` or `.dll`. The C
contract, callback calling convention and generation ownership stay shared. The
Windows and macOS backends have compile/link checks locally; native behavior is
not yet advertised as supported. The PR-triggered and manually dispatchable `typesupport-platforms.yml` CI workflow
runs native Linux/macOS/Windows Debug and ReleaseSafe checks against the pinned
zidl release. No separate zidl revision or checkout is required.

Run the same qualification locally:

```sh
python3 scripts/check_typesupport_platform.py --optimize Debug
python3 scripts/check_typesupport_platform.py --optimize ReleaseSafe
```

Use `--zidl /absolute/path/to/zidl` only to qualify a development checkout.

It checks genuine linked providers (also with dynamic loading compiled out), C
layout and C-to-provider callbacks, multiple libraries, candidate failures,
allocation failures, generation pinning, native module retirement, and UDP exchange
with spaces/Unicode in installed artifact paths. The native module observation
check verifies residency while pinned on every native OS and immediate unmapping
for the Linux/Windows fixtures. It does not require dyld to unmap a closed image;
[Apple documents loader-controlled image removal](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/DynamicLibraryUsageGuidelines.html).
The residency probe is skipped for musl's separate static ELF loader. Compile-only target checks
are also available through `zig build check-typesupport-library -Dtarget=...` with
`-Dtypesupport-library=true`; code generation runs on the build host.

## Receive processing and limitations

The reader's shared complete-sample path applies the selected provider before
sequence accounting/history admission. It checks DATA, completed DATA_FRAG and
samples held before a match. Errors do not become a successful zero key. Completed
fragment buffers are retired even when validation fails, allowing repair to rebuild
the sample. Protocol coherent-end markers bypass application type validation;
lifecycle notifications containing only an inline key hash preserve that hash.

The processor is bounded, synchronous and nonblocking. It may not call DDS APIs,
retain buffers or run cleanup. The generated provider's wire callbacks meet that
contract; this is not a general application callback hook.

The prototype's final/bounded type subset and strict encapsulation/extent rules
still apply: exact CDR bytes, supported final-type representation, no nonzero
encapsulation options or trailing RTPS padding normalization. Generic field
extraction/CFT support is absent from this descriptor version. Complete metadata,
network TypeLookup, general assignability and language-native objects remain future
work. This slice does not establish the wider reception/admission, allocation-failure
ACK or historical-wait guarantees tracked elsewhere in the roadmap.

## Validation

With localhost UDP access:

```sh
zig build test-typesupport-library \
  -Dtypesupport-library=true
zig build test -j2 \
  -Dtypesupport-library=true
```

The focused suite builds equivalent/conflicting libraries independently and exercises
candidate rejection, enumeration, static descriptors, generation limits, concurrent
selection/replacement, allocation failures, keyed DDS exchange over direct in-process
transport, immutable conflicts and teardown with an outstanding protocol reference.
Core regressions cover malformed DATA/fragments/prematch input before sequence
accounting, completed-buffer cleanup and exactly-once C-ABI adapter cleanup on OOM.
The [runnable example](../examples/zig/typesupport-library/README.md) adds
inspection and separate-process UDP publishing/reception with two libraries,
equivalent overlapping exports, keyed-instance separation and keyless delivery.
Its optional independent Fast DDS 3 subscriber checks decoded values and instance
handles without depending on zidl or zzdds. It exercises name-based matching;
network TypeLookup/assignability negotiation and native non-Linux qualification
remain separate gates.
