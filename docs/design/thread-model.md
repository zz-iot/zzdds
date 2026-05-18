# Thread Model and TypeObject Registration

## Thread model

**Default: background threads per domain.**

- One receive thread per bound transport port
- One timer thread for lease monitoring and deadline tracking
- Listener/callback invocations happen on the receive thread (user must not block)
- `WaitSet.wait()` blocks the calling thread

**Embedded / single-threaded use:** expose `DomainParticipant.drive(timeout)` which
processes pending I/O and timers from the caller's thread. This requires the transport
to support non-blocking poll. (Not yet implemented; design must not preclude it.)

## TypeObject registration

zidl generates `type_object`, `equivalence_hash`, and `type_identifier` constants on each
generated struct type. `TypeSupport.register_type(participant)` stashes the TypeObject
bytes in `DomainParticipant.type_registry`.

SEDP includes TypeObjects in `DiscoveredWriterData` for remote type matching per
DDS-XTypes §7.6. This enables schema-evolution scenarios where a reader holds a different
type version than the writer.
