# Zenzen DDS — Zig-native DDS Implementation

A spec-compliant Zig implementation of OMG DDS v1.4 DCPS with RTPS 2.5 wire interoperability.

## Goals

- Full DDS v1.4 DCPS compliance (formal/15-04-10)
- RTPS 2.5 wire interoperability
- Pluggable transport, discovery, and security — UDP and SPDP/SEDP default; DDS-Security v1.2 planned
- Language bindings for C, C++, Java, others via `zidl --generate-interfaces`
- Unified configuration: programmatic API > env vars > config file > built-in defaults

## Build

Requires Zig 0.16.0.

```sh
zig build       # generate DCPS interfaces + compile
zig build test  # 400+ unit and integration tests
```

## Documentation

See [`docs/overview.md`](docs/overview.md) for the full documentation index.

Quick links:
- [Architecture](docs/architecture.md) · [Implementation status](docs/implementation_status.md)
- [Testing](docs/testing.md) · [Roadmap](docs/roadmap.md)
