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
