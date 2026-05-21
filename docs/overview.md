# Zenzen DDS — Documentation Overview

## Architecture and Status

| Document | Audience | Contents |
|---|---|---|
| [`architecture.md`](architecture.md) | Contributors | Layer model, plugin vtables, build options, configuration schema, logging, wire trace |
| [`implementation_status.md`](implementation_status.md) | All | What is and isn't implemented; known limitations; test counts |

## Developer Reference

| Document | Contents |
|---|---|
| [`testing.md`](testing.md) | How to run the test suite (all tiers) |
| [`dev-notes.md`](dev-notes.md) | Zig 0.16.0 API notes, build dependency layout, generated code table |
| [`roadmap.md`](roadmap.md) | Phase 33 remaining items, planned work, deferred items |
| [`decisions.md`](decisions.md) | Stable design decisions with rationale |

## Design Notes (`docs/design/`)

Focused rationale documents for individual subsystems. These describe *why* things are
designed the way they are, not step-by-step implementation plans.

| Document | Contents |
|---|---|
| [`design/history-cache.md`](design/history-cache.md) | Why caches store bytes not structs; allocator strategy; CDR encoding invariants |
| [`design/rtps-message-builder.md`](design/rtps-message-builder.md) | Iovec assembly, fragmentation, security scratch buffer |
| [`design/security-pipeline.md`](design/security-pipeline.md) | Protection scope model (planned); current status (noop only) |
| [`design/thread-model.md`](design/thread-model.md) | Thread ownership, explicit timer checks, callback delivery, current TypeInformation limits |
| [`design/testing-strategy.md`](design/testing-strategy.md) | Test tier philosophy (deterministic → mock → live → adversarial); clock abstraction |

## Contributor Quick-References (`docs/reference/`)

| Document | Contents |
|---|---|
| [`reference/rtps-reference.md`](reference/rtps-reference.md) | RTPS 2.5 spec quick-reference (port formula, entity IDs, PID table, encoding IDs, state machine summaries). **Not authoritative** — see `src/rtps/pid.zig` and `src/rtps/guid.zig` for values used in code. |

---

## Repository Layout

```
build.zig, build.zig.zon
idl/
  dcps.idl                # DDS v1.4 §2.3.3 normative IDL
  rtps_discovery.idl      # SPDP/SEDP discovery types (PL_CDR serialization)
src/
  root.zig, log.zig, trace.zig
  config/                 # Schema, TOML parser, config precedence resolver
  dcps/                   # Factory, participant, publisher, subscriber, writer, reader, topic, WaitSet
  discovery/              # SPDP, SEDP, combined wrapper
  protocol/               # DCPS ↔ RTPS vtable seam
  qos/                    # All 22 QoS policies
  rtps/                   # Message framing, history cache, writer/reader state machines
  security/               # Interface vtable + noop pass-through
  transport/              # UDP, mock, memory, lossy; interface monitor
  util/                   # time, guid_gen, clock registry, mutex, condvar
test/
  dcps/                   # DCPS-level integration tests
  rtps/                   # RTPS message-layer tests
  discovery/              # SPDP/SEDP tests
  fuzz/                   # Corpus regression (RTPS parser, PL_CDR deserializer)
  interop/                # Wire interop vs Cyclone DDS / OpenDDS
docs/
  overview.md             # This file — documentation index
  architecture.md         # Layer model, plugin interfaces, config, logging, wire trace
  implementation_status.md# What is and isn't implemented; known limitations
  testing.md              # How to run the test suite
  dev-notes.md            # Zig 0.16.0 API notes, developer gotchas
  roadmap.md              # Planned work + deferred items
  decisions.md            # Stable design decisions with rationale
  reference/
    rtps-reference.md     # RTPS 2.5 spec quick reference (contributor reference only)
  design/                 # Focused design notes per subsystem
```

---

## Specification References

### Primary
- [DDS v1.4 (formal/15-04-10)](https://www.omg.org/spec/DDS/1.4/) — DCPS API
- [RTPS 2.5 (formal/22-04-01)](https://www.omg.org/spec/DDSI-RTPS/2.5/) — wire format and discovery

### Supporting
- [DDS-XTypes v1.3 (formal/20-02-04)](https://www.omg.org/spec/DDS-XTypes/1.3/) — TypeObject/TypeIdentifier
- [DDS Security v1.2 (formal/25-03-06)](https://www.omg.org/spec/DDS-SECURITY/1.2/)
- [IDL 4.2 (formal/18-01-05)](https://www.omg.org/spec/IDL/4.2/) — via zidl
- [IDL4 to C++ v1.0 (formal/25-03-03)](https://www.omg.org/spec/IDL4-CPP/1.0/) — via zidl
- [IDL4 to Java v1.0 (formal/21-08-01)](https://www.omg.org/spec/IDL4-JAVA/1.0/) — via zidl
- [DDS-RPC v1.0 (formal/17-04-01)](https://www.omg.org/spec/DDS-RPC/1.0/) — deferred
- [DDS-XRCE v1.0 (formal/20-02-01)](https://www.omg.org/spec/DDS-XRCE/1.0/) — embedded profile, deferred
