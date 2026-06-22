# C/C++ Binding Release Notes

This release track makes generated C and C++ bindings usable as first-class
zzdds client surfaces.

## Release Gates

- Release zidl with `--generate-zzdds-wrappers` support for Zig, C, and C++.
- Update `build.zig.zon` from the local `../zidl` path to the released zidl
  package URL/hash after that tag exists.
- Keep `idl/dcps.idl` normative and put zzdds-specific configuration and
  extension interfaces in `idl/zzdds.idl`.
- Keep `include/zzdds_c.h` as a small support ABI for generated wrappers; prefer
  generated DDS/zzdds IDL bindings as the user-facing API.
- Gate release candidates with `zig build test` and
  `zig build test-bindings -Dc-binding=true -Dcpp-binding=true`.

## Current Smoke Surface

`test/bindings/smoke/binding_smoke.idl` is generated for Zig, C, and C++ with
`--generate-zzdds-wrappers`. The smoke binaries verify:

- generated CDR serialize/deserialize functions compile and round-trip data;
- key-hash helpers agree between typed values and serialized CDR;
- typed DataWriter/DataReader wrapper constructors compile and link against
  the zzdds support ABI.
- the Zig wrapper can write through its local `dds` adapter and read the
  captured raw sample back through the generated typed DataReader.

The next step is a process-level traffic matrix using the same topic IDL:
Zig/C/C++ pub/sub apps with common CLI flags for mode, domain, topic, sample
count, timeout, basic QoS, and read strategy.
