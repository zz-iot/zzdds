# Zenzen DDS — A Zig-powered DDS Implementation

[![codecov](https://codecov.io/gh/zz-iot/zzdds/graph/badge.svg)](https://codecov.io/gh/zz-iot/zzdds)

A Zig implementation of the DDS specification (v1.4) and RTPS 2.5 wire interoperability.

## Goals

- Full DDS v1.4 DCPS compliance (formal/15-04-10)
- RTPS 2.5 wire interoperability
- Pluggable transport, discovery, and security
  - RTPS/UDP and SPDP/SEDP default
  - DDS-Security v1.2 planned
- Language bindings for:
  - C, C++, Java (the formal specs for IDL mappings)
  - C#, Python, Rust, Haskell (planned)
  - and others via `zidl --generate-interfaces`
- Configuration: built-in defaults or a TOML config file, returned as a plain struct you can mutate directly

## Build

Requires Zig 0.16.0.

```sh
zig build       # generate DCPS interfaces + compile
zig build test  # unit and integration tests
```

## Documentation

See [`docs/overview.md`](docs/overview.md) for the full documentation index.

Quick links:
- [Architecture](docs/architecture.md) · [Implementation status](docs/implementation_status.md)
- [Testing](docs/testing.md) · [Roadmap](docs/roadmap.md)
