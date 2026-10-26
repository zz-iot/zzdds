# Loadable typesupport: inspect, publish and receive

This example loads two independent zidl typesupport libraries supplied on
its command line. Linux has native validation; macOS/Windows backends and binaries
are implemented but still await native runtime qualification. The host imports no application-generated Zig module. It
inspects every export and selects `sensors:LoadedDemo::Reading` and
`control:LoadedDemo::Pulse` explicitly. Both libraries export equivalent `Pulse`
types; there is no load-order winner. Each library also contains a project-specific
keyed type.

The publisher sends readings `(id=1, value=101)` and `(id=2, value=202)`, followed
by keyless pulse `count=7`. The subscriber checks the exact sample bytes and
asserts that the readings have different DDS instance handles. Both modes remove
the catalog mappings and release their selections before creating endpoints;
registrations keep provider code alive for subsequent traffic and teardown.

The host uses ordinary DDS entity APIs with reliable QoS and **explicit XCDR1**
representation, matching its encapsulated wire vectors. An empty representation
QoS is not a portable substitute: zzdds's XTypes-enabled discovery advertises
XCDR2 for that default. Payload production/interpretation remains application
code; this is not a generic IDL value editor or a resource/profile builder.

## Build and run

From the zzdds repository root, using Zig 0.17.0 and the pinned zidl
release (the shell commands below show Linux artifact names; the smoke
runner selects native filenames on Linux/macOS/Windows):

```sh
zig build typesupport-example \
  -Dtypesupport-library=true

zig-out/bin/typesupport-demo inspect \
  "$PWD/zig-out/lib/libdemo_sensors.so" "$PWD/zig-out/lib/libdemo_control.so"

python3 examples/zig/typesupport-library/smoke_test.py
```

The smoke check rejects a missing library and runs publisher/subscriber as separate
processes over UDP, with bounded readiness/reception/acknowledgment waits. It
requires Python 3 and permission to open DDS UDP sockets. No external DDS package
is needed for this check. Use `--domain 97` to choose an unused domain; keep other
applications off the example topics in that domain.

For manual execution, start these in separate terminals:

```sh
zig-out/bin/typesupport-demo sub \
  "$PWD/zig-out/lib/libdemo_sensors.so" "$PWD/zig-out/lib/libdemo_control.so" 98
zig-out/bin/typesupport-demo pub \
  "$PWD/zig-out/lib/libdemo_sensors.so" "$PWD/zig-out/lib/libdemo_control.so" 98
```

Library paths may point to separately built artifacts. The example build generates
the two providers independently for convenience; neither is linked into the host.
To build providers in another project, use zidl's
`packages/zidl-typesupport/README.md` recipe. The `pub`/`sub` modes require the
example's named exports and layouts; `inspect` reports any compatible libraries.

## Independent Fast DDS subscriber

An optional receive-only C++ peer uses Fast DDS 3 and its own implementation of
the two tiny IDL wire layouts. It has no zidl or zzdds dependency. Build it against
an existing Fast DDS installation; the normal example does not fetch or link it:

```sh
cmake -S examples/zig/typesupport-library/fastdds \
  -B /tmp/typesupport-fastdds -DCMAKE_PREFIX_PATH=/path/to/fastdds/install
cmake --build /tmp/typesupport-fastdds -j2
python3 examples/zig/typesupport-library/smoke_test.py \
  --fastdds-sub /tmp/typesupport-fastdds/typesupport-fastdds-sub
```

The peer forces UDP, explicitly requests XCDR1 and verifies decoded values and
distinct nonzero keyed instance handles. This checks ordinary name-based DDS
matching, reliable delivery and keyed/keyless samples. It does not qualify network
TypeLookup, XTypes equivalence/assignability negotiation, reverse-direction traffic,
other encodings or other operating systems. Provider equivalence is checked
locally using the descriptor's minimal TypeIdentifier.

See [the API guide](../../../docs/typesupport-libraries.md) for ownership,
replacement, registration conflicts and experimental contract limits.

Validated locally with Zig 0.17.0 and Fast DDS 3.6.2 in Debug and ReleaseSafe.
