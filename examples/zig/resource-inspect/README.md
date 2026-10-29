# Resource/provider inspection

Build from the zzdds repository root:

```sh
zig build resource-inspect resource-provider-fixtures -Dresource-authoring=true -Dtypesupport-library=true
```

The example resource file selects keyed Reading and keyless Pulse types. Provider A
exports both; provider B exports Reading independently. Only the explicitly selected
exports are registered when a program later builds the prepared graph.

Use `validate` or `plan` for offline checks, and `inspect` to explicitly load providers
and check exports, identifiers and capabilities without creating DDS entities. See
[the API, commands and ownership guide](../../../docs/resource-providers.md).
