# RTPS submessage routing — entity-ID-based dispatch (proposal)

Status: PROPOSAL, not scheduled, 2026-09-16. Not a spec ready to implement — captures a
design direction and the reasoning behind deferring it, for whoever picks it up.

One-line goal: replace "every handler registered on a port independently re-parses the
whole packet and decides for itself what it owns" with "parse each incoming RTPS message
once, then route each decoded submessage directly to the one handler responsible for its
entity ID," using RTPS's own builtin-vs-user `entity_kind` bit pattern as the routing key.

## 0. Provenance

Fell out of fixing a real zzdds↔hdds interop regression (`zz-iot/dds-rtps` interop matrix,
2026-09-15/16 — see `zz-dev/backlog-index.md`-adjacent investigation notes, not reproduced
here). Summary of that investigation, needed as context for this doc:

* hdds's reader unconditionally routes ACKNACK/HEARTBEAT/GAP replies to the remote
  participant's `metatraffic_unicast_locator`, even for a non-builtin (user topic)
  writer/reader — confirmed directly against hdds's own source
  (`hdds-team/hdds:crates/hdds/src/dds/reader/heartbeat.rs`, `resolve_metatraffic_dest`,
  tagged `v219`, added to work around an unrelated FastDDS compound-message quirk and
  applied unconditionally rather than only for builtin entities).
* zzdds correctly advertises `metatraffic_unicast_locator` and `default_unicast_locator`
  as distinct locators (confirmed on the wire), and a writer/reader with no explicit SEDP
  locator is supposed to inherit the latter (RTPS §8.5.4) — so hdds's ACKNACK for our
  Square topic writer, in the failing case, arrives on our metatraffic port instead of the
  port we told it to use.
* `src/discovery/sedp.zig`'s `onReceive` — the sole thing listening on the metatraffic
  port — only recognizes builtin SPDP/SEDP/WLP entity IDs (via `BuiltinPair.tryHandle` and
  the WLP fallback). Anything else is silently dropped. That's what actually broke: the
  writer's `suppress_live_data` flag (durability replay gating) only ever clears inside
  `handleAckNack`, which was never reached, so no live data was ever sent.

Fixed in the near term (same PR as this doc) by registering `userDataOnReceive`
(`src/dcps/participant.zig`) as a *second* fan-out handler on the metatraffic port's
`PortEntry`, alongside SEDP's own handler — see §2 for why that's cheap and low-risk, and
§6 for exactly how it relates to the design proposed here.

## 1. Current design: handlers-maybe-route

Every port (`PortEntry` in `src/transport/udp.zig`) holds a list of `ReceiveHandler`s.
`PortEntry.dispatch` fans the raw UDP payload out to all of them unchanged:

```zig
for (snap[0..count]) |h| h.on_receive(h.ctx, buf, src, channel);
```

Each handler then independently does its own full `MessageIterator.init(raw)` parse and
decides, submessage by submessage, whether it owns the entity ID involved:

* `src/discovery/sedp.zig`'s `onReceive` parses the message and tries
  `pub_pair.tryHandle` → `sub_pair.tryHandle` → WLP's callback, in that order, for each
  submessage it sees — three sequential entity-ID comparisons per submessage before
  concluding "not mine."
* `src/dcps/participant.zig`'s `userDataOnReceive` does its own completely separate parse
  of the same class of message on the user-data port, matching submessage entity IDs
  against `active_writers`/`active_readers` (two `HashMap` lookups keyed by `entityIdKey`).

This is a broadcast-and-filter model: every registered handler sees every packet on "its"
port and decides for itself, from scratch, what (if anything) it cares about.

## 2. What the near-term fix does, and its cost

The immediate fix (this PR) adds `userDataOnReceive` as a *second* handler on the
metatraffic `PortEntry`, via a second `Transport.listen()` call. This works today with zero
transport changes because `vtListen`'s reuse-existing-`PortEntry` path —

```zig
const r = try self.port_entries.getOrPut(self.alloc, port);
if (r.found_existing) {
    try r.value_ptr.*.addHandler(handler);
    return;
}
```

— and `PortEntry.addHandler` itself have both existed since the repository's initial
commit (`769857f`), predating even the discovery-protocol work that assumed this wasn't
possible (a stale comment in `src/discovery/wlp.zig` / `docs/roadmap.md`, corrected in this
same PR — see §6).

Cost: every metatraffic-port packet now gets parsed twice — once by SEDP's dispatcher, once
by `userDataOnReceive`, which (for ordinary SPDP/SEDP traffic) will find no matching active
writer/reader and no-op. SPDP/SEDP volume is low relative to user data in any real
deployment, so this is very likely negligible in absolute terms, but it is real, constant
overhead on every metatraffic packet, not just the ones a peer misdirects — see §5 for how
the design below would remove it.

## 3. Proposed design: route-to-handler

Move the parse to the transport (or a thin protocol-demux layer directly above it) and
route each *decoded submessage* to the correct handler, instead of handing every handler
the raw bytes and letting them all re-parse and re-filter:

1. Parse the message once (`MessageIterator`, as today — just centrally, not per-handler).
2. For each decoded submessage, classify its relevant entity ID (writer entity ID for
   `.data`/`.heartbeat`/`.gap`; reader entity ID for `.acknack`) as **builtin** or **user**
   using the entity kind's own bit pattern (RTPS §9.3.1.2, already encoded in
   `src/rtps/guid.zig`):

   ```zig
   pub const EntityKind = struct {
       pub const user_writer_with_key: u8 = 0x02;
       // ...
       pub const builtin_writer_with_key: u8 = 0xC2;
       // ...
   };
   ```

   All builtin kinds are `0xC?`; no user kind sets that high nibble. So
   `is_builtin = (entity_kind & 0xC0) == 0xC0` classifies any entity ID, including
   `EntityIds.unknown` (`0x00`, correctly `false`), in one bitwise op — no registry lookup,
   no allocation.

3. Dispatch the submessage directly to the one handler responsible for that class — SEDP's
   dispatcher for builtin, `participant.zig`'s dispatcher for user — instead of trying every
   registered handler in sequence and letting each one re-parse to find out.

This is a coarser routing decision than "which specific writer/reader" — it only answers
"builtin or user," not "which one" — which is deliberate; see §4.

## 4. Why the "broadcast" submessages aren't a blocker

A HEARTBEAT/GAP/ACKNACK with `reader_entity_id` (or `writer_entity_id`) set to
`EntityIds.unknown` means "this applies to every locally matched reader/writer," not one
specific entity — `userDataOnReceive`'s existing `.heartbeat` arm already handles this:

```zig
if (hb.reader_entity_id.eql(EntityIds.unknown)) {
    var fan_it = self.active_readers.valueIterator();
    while (fan_it.next()) |ar| ar.proto.handleHeartbeat(...);
} else {
    // targeted lookup
}
```

Routing at the *handler* granularity (builtin vs. user), not the *entity* granularity,
sidesteps this entirely: the router's job stops at "this is DCPS's problem, not SEDP's."
Whichever handler gets picked still does its own internal fan-out exactly as it does today
— `userDataOnReceive`'s wildcard-to-all-active-readers loop, SEDP's own pub/sub/WLP
sequence for its builtin set — completely unchanged. The router doesn't need to know
`active_readers` exists any more than it needs to know about `BuiltinPair`.

## 5. What this would cost to build

Larger than it looks, for three reasons:

* **`ReceiveHandler`'s contract changes.** Today it's `on_receive(ctx, raw: []const u8,
  src, channel) void` — "here are bytes, parse them yourself." A router needs to hand out
  *decoded submessages* instead, which means every implementor's signature changes:
  `sedp.zig`, `spdp.zig`, `participant.zig`'s `userDataOnReceive`, and the
  mock/memory/TCP transports used in tests. `transport-channel.md` §2.3 already sized a
  comparable "extend `ReceiveHandler` in place" change at seven files, three mechanical —
  this would be a similar-shaped blast radius, on top of that one.
* **The router needs a home.** Not `transport/udp.zig` — parsing RTPS submessages there
  would make UDP-specific plumbing protocol-aware, arguably worse layering than today's
  "every handler parses independently." It wants a new module sitting between transport
  and discovery/DCPS that doesn't exist yet — genuinely new architecture, not a
  refactor of something in place.
* **The performance case, while real, is modest.** The thing being double-parsed today
  (SPDP/SEDP metatraffic) is the low-volume side of any real deployment's traffic. This is
  worth doing for the cleaner architecture and for removing SEDP's
  `pub_pair`/`sub_pair`/WLP fallback chain's redundancy with `userDataOnReceive`'s own
  dispatch, not primarily for CPU savings.

## 6. Relationship to the near-term fix

The near-term fix (§2, this same PR) is a special case of what this design would give you
"for free": under entity-ID routing, hdds's misdirected ACKNACK would reach
`userDataOnReceive` regardless of which port it physically arrived on, because routing
follows the entity ID in the submessage, not the socket it came in on. The `addHandler`-based
fix is the pragmatic version of that same outcome, achieved by listening in the specific
place we know we need to, rather than making port choice irrelevant everywhere.

This PR also corrects two places that asserted the underlying constraint this design
(and the near-term fix) both disprove — `src/discovery/wlp.zig`'s "the transport does not
support opening a second listener on the same port" comment and `docs/roadmap.md`'s "One
downstream listener per port" gap entry, both written when `PortEntry.addHandler` already
supported exactly that. WLP itself is a good candidate to migrate onto a plain second
`listen()` call the same way, decoupling it from SEDP's internals — not done in this PR to
keep its blast radius to the regression at hand, but a small, low-risk follow-up.

## 7. Explicitly out of scope / not decided here

* Any change to `ReceiveHandler`'s signature — sizing it precisely (what a decoded
  submessage handle looks like, ownership/lifetime of any borrowed inline-QoS buffers
  across the parse boundary, ...) is real design work, not attempted here.
* Where the router module lives, or whether it's worth a dedicated struct at all versus a
  free function the transport calls before fan-out.
* Migrating WLP off SEDP's internal callback chain (§6, noted as a candidate follow-up,
  not scoped).
* Extending `MAX_RECEIVE_HANDLERS` / the dispatch-snapshot cap
  (`interface.zig`) — unrelated axis, already tracked in `docs/roadmap.md`.

## 8. Pointers

* `src/transport/udp.zig` — `PortEntry`, `vtListen`, `addHandler`/`dispatch`.
* `src/discovery/sedp.zig` — `onReceive`, `BuiltinPair.tryHandle` chain.
* `src/dcps/participant.zig` — `userDataOnReceive`, `start()` (near-term fix site).
* `src/rtps/guid.zig` — `EntityKind`, the builtin/user bit pattern this design would route
  on.
* `docs/design/transport-channel.md` §2.3 — sizing precedent for a `ReceiveHandler`
  signature change of comparable shape.
