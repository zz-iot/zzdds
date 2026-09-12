# Transport channel / ingress-context abstraction

Status: DRAFT, revision 0.3, 2026-09-11. MUST / SHOULD / MAY express requirements of the
change, not additional OMG requirements.

One-line goal: give the `Transport` interface an optional notion of "the channel this
message arrived on" so a reply can be sent back down that exact channel, instead of the
transport always resolving a destination `Locator` to an outbound socket/connection of its
own choosing.

## 0. Provenance and status

Fell out of the `discovery-broker.md` review (`discovery-broker-review.md` §2, §4.3, §4.4,
§10, branch `broker_spec`, inspection baseline `f083f95`) as one of two prep tasks safe to
do now, independent of whether the broker ships — sibling to `discovery-codec.md`, which has
since landed (SEDP path, zzdds `c86934e`). This spec re-inspects the transport source
directly (zzdds `c86934e`, main) rather than trusting the handoff note's line numbers, and
resolves every open question the handoff left for "the spec step." Implemented on branch
`transport-channel`, zzdds PR #84.

### 0.1 What changed in revision 0.2

Revision 0.1's §4.3.1 concluded that channel-death detection could stay purely **lazy**
(discovered only when the holder next calls `sendOnChannel` and gets `error.ChannelClosed`)
and deferred a push notification as unbuilt follow-up work with no consumer yet. That framing
is gone. Revision 0.2 instead designs a real, **push**-based topology-change notification —
built now, specified precisely enough to support every platform this project targets and
every current transport type, so the currently-deferred platform-specific `InterfaceMonitor`
backends (netlink/PF_ROUTE/Windows) have zero remaining design ambiguity when someone
eventually writes them, and so TCP — which had **no** interface-change awareness at all
before this revision — gets it for the first time. New §5. The decisions table, out-of-scope
list, verification list, risks, and pointers are updated accordingly; §§1-4.3 are unchanged
from revision 0.1 (still accurate against `c86934e`).

### 0.2 What changed in revision 0.3

Revision 0.2's §5 bundled two things that turned out not to belong in the same PR: the
`on_channel_closed` **API** (a small, generically useful addition to `ReceiveHandler`), and
TCP **actually growing its own `InterfaceMonitor` integration** to call that API for a new
reason (local-interface loss, §5.2/§5.3 in revision 0.2) — a materially larger, riskier, and
more separable piece of work. Direction: build the API now; decide what/how it gets called
for TCP later, as part of a larger, already-partly-scoped "make `InterfaceMonitor` a real,
complete thing for zzdds" initiative that also covers the platform-specific backends
(netlink/PF_ROUTE/Windows) and the shared-monitor-instance optimization — bundled together
in `docs/roadmap.md` rather than scattered. Revision 0.2's §5.2/§5.3/§5.5 design work is not
lost — it was concrete enough to move, close to verbatim, into that roadmap entry as the
starting point for whoever picks it up. §5 here is rewritten to describe only what ships in
this task: the `on_channel_closed` API and its two pre-existing firing sites (TCP natural
death, UDP's existing interface-monitor-driven teardown). This also collapses §11's
implementation sequencing from five PRs down to one — the topology-awareness work that
justified splitting it was exactly what got removed.

## 1. Why this is a standalone task, not "broker prep"

The plain TCP-user-data path already has the same latent defect the broker would hit.
`DomainParticipantImpl` (`src/dcps/participant.zig:801`+) builds a dedicated `TcpTransport`
for user data when `config.transport.tcp.enabled` (`owned_tcp_transport`, field at `:831`,
doc comment starting `:818`): "Normally the same handle as `discovery_transport`; ... this is
instead a privately-owned TcpTransport ... so user data rides TCP while SPDP/SEDP keep using
UDP unconditionally." A TCP DataWriter replying to a TCP DataReader that sits behind NAT cannot
dial the reader's *advertised* listening locator — but `send(locator, …)` forces exactly
that attempt. `discovery/interface.zig`'s `DataLocatorReachability` shim (constructed at
`participant.zig:1159` when TCP is enabled) already works around the same asymmetry one
layer up, by letting discovery filter locators the *current* transport can reach — it has no
way to express "reachable specifically via the connection this peer already opened to us."

`Transport.Vtable.connection_generation` (`transport/interface.zig:459`) already established
the precedent for an optional, nullable, transport-lifecycle vtable hook that UDP/memory/
mock simply don't implement — "so RTPS code can check for a change unconditionally without
needing to know which transport kind it's talking to." This task is the same shape, one
level richer: not just "has the connection changed" but "here is a handle to which one."

## 2. Current state (zzdds `c86934e`, `src/transport/`)

### 2.1 The vtable today

`Transport.send(ctx, locator, data)` (`interface.zig:419`) takes a **destination locator**;
the transport decides the local socket/connection:

* TCP `vtSend` (`tcp.zig:563`) → `ensureConnection(locatorToRemoteKey(loc))` (`:478`) →
  looks up an existing connection by `(remote_ip, remote_port)`, or **dials outbound** if
  none exists (`dialConnection`, `:1017`).
* UDP `vtSend` (`udp.zig:910`) sends via `self.send_fd_v4` / `self.send_fd_v6` — one shared
  send socket per address family, cached independently of whichever per-interface
  `SocketEntry` a reply might logically belong to (multicast destinations fan out across
  `mc_send_ifaces`; unicast sends always go out the single shared fd).

`ReceiveHandler.on_receive(ctx, data, src: Locator)` (`interface.zig:388`) hands the caller a
**synthesized peer address** and nothing else:

* TCP: `recvLoop` (`tcp.zig:892`) computes `src = remoteKeyToLocator(&conn.remote)` and calls
  `conn.owner.dispatchToHandlers(buf, src)` (`:404`) — the actual `*TcpConnection` the bytes
  arrived on is discarded before the callback fires.
* UDP: `recvThread` (`udp.zig:1285`) is one thread **per `SocketEntry`** — one bound socket
  per active interface address when `bind_wildcard = false` (the default; `decisions.md`:
  "one unicast socket per interface address ... Cyclone style"). It computes
  `src_loc = sockaddrToLocator(&src_store)` from the datagram's actual source and calls
  `entry.handler.on_receive(entry.handler.ctx, buf[0..n], src_loc)` (`:1334`) — the
  `*SocketEntry` (which fd, which bound interface) is likewise discarded before the callback.

`connection_generation(ctx, locator)` (`interface.zig:459`) is the only connection-lifecycle
signal, keyed by **locator**, not by a specific connection — `vtConnectionGeneration`
(`tcp.zig:735`) maps the locator to a `RemoteKey` and reads
`connection_generations.get(key)`, a map bumped once per *first-connect-or-reconnect* for
that remote endpoint (`bumpGenerationLocked`, `:393`; called from `acceptLoop` `:885` and,
implicitly via `ensureConnection`'s dial path, on outbound reconnect).

`reuse_connection_by_host` (`schema.TcpConfig`, checked at `tcp.zig:484`,`503`) can collapse
multiple logical peers that share a source host IP onto a single TCP connection via
`findConnectionByHostLocked` (`:543`) — deliberately host-scoped, so it actively defeats any
attempt to demux by more than address.

### 2.2 What each transport already has that a channel design can reuse

* **TCP connection identity already outlives the socket.** `TcpConnection` objects are
  removed from the live `connections` lookup map on close (`removeConnection`, `:458`) but
  stay in `all_connections` — and are **not freed** — until the whole `TcpTransport` is
  torn down (`deinit`, `:350`, joins every recv thread and only then `destroy`s each
  connection). Liveness is a separate atomic, `fd_open: std.atomic.Value(bool)` (`:263`),
  CAS'd exactly once by whichever of `recvLoop` or `deinit` gets there first
  (`closeConnFdOnce`, `:272`). A `*TcpConnection` pointer is therefore safe to dereference
  for the transport's whole lifetime — this is exactly the retention a persistent channel
  handle needs, already built for an unrelated reason (avoiding use-after-free between
  `vtSend`'s dead-connection removal and a racing `recvLoop` exit).
* **UDP does not have the equivalent.** `SocketEntry` structs, one per bound interface
  socket, ARE individually freed — `removeSockets` (`udp.zig:718`, called from
  `vtUnlisten`/multicast-group-empty paths) and interface-loss handling both
  `self.alloc.destroy(s)` (`:545`, `:690`, `:733`) after `stop()`. A UDP path token built
  from a raw `*SocketEntry` pointer would dangle across an interface flap — see §4.3, §9.
* **Thread-safety contract on the receive path is already strict.** `ReceiveHandler.on_receive`
  is documented "Called from the transport's receive thread. Must not block." — both
  `dispatchToHandlers` (TCP) and `PortEntry.dispatch`/`recvThread` (UDP) snapshot the
  handler list under a lock and call out lock-free. Any channel-carrying extension of this
  callback must preserve that: no new lock acquisition inside the callback that isn't
  already there.

### 2.3 `ReceiveHandler` blast radius

Everything that constructs a `ReceiveHandler{ .ctx = ..., .on_receive = ... }` literal, or
calls `.on_receive(...)`, is a call site any signature change touches:

| Role | Files |
| --- | --- |
| Constructs `ReceiveHandler` (registers a listener) | `src/dcps/participant.zig`, `src/discovery/sedp.zig`, `src/discovery/spdp.zig` |
| Implements the transport side (calls `.on_receive`) | `src/transport/tcp.zig` (`dispatchToHandlers`), `src/transport/udp.zig` (`PortEntry.dispatch`, `recvThread`), `src/transport/memory.zig` (`:154`), `src/transport/mock.zig` (`:211`) |
| Pure pass-through wrapper (forwards the handler verbatim, no logic touching `on_receive`'s body) | `src/transport/lossy.zig` — `LossyTransport.listen` hands the caller's `ReceiveHandler` straight to the wrapped transport; only its own unit test (`:311`) constructs a raw literal, and only to exercise the callback directly |

Seven files total, three of which (`memory.zig`, `mock.zig`, `lossy.zig`) need no new logic
— just the wider function-pointer type — because none of them have a channel concept.

### 2.4 `LocatorSelector`

`transport/locator_selector.zig`'s `selectInto` (`:33`) is a pure function over `Locator`
slices — it has no notion of connections or sockets, only address tiering
(loopback/link-local/private/public) and family tiebreak. `ReaderProxy`/`WriterProxy`
(`rtps/writer_sm.zig`, `rtps/reader_sm.zig`) call it to narrow a matched peer's advertised
locators down to the ones actually sent to, then hand the result to `Transport.send`. A
channel-routed reply must never pass through this — it already knows exactly which
socket/connection to use and ranking candidate locators is meaningless there.

## 3. The problem, precisely

1. **No accepted-connection reply.** A TCP endpoint that receives on an accepted connection
   cannot say "reply on this connection." `send` dials the peer's advertised locator, which
   for a NATed peer is unreachable — this is broker spec §6.4's exact requirement ("the
   broker replies over that accepted connection, even when the client's listening locator is
   unreachable from the broker") but it is equally true of the plain TCP-user-data path
   today (§1).
2. **No stable ingress identity.** `on_receive` gives a synthesized `src` locator, so the
   receiver cannot bind "this byte stream = session N / owner X" and must fall back to
   demultiplexing by address — which `reuse_connection_by_host` actively breaks by design
   (two peers behind one NAT collapse onto one connection).
3. **UDP reply path is the transport's choice, not the caller's.** Return-routability
   (broker §6.3: "Replies MUST return through the same socket/path, and the broker MUST use
   the service address contacted by the client as the reply source") needs replies to exit
   the exact local socket the client's datagram arrived on. `send(locator, …)`'s shared
   `send_fd_v4`/`send_fd_v6` cannot express that — it picks whichever cached fd is set,
   independent of which `SocketEntry` actually received the datagram being replied to.
4. **`connection_generation` is too coarse.** Locator-keyed (`RemoteKey`), so it cannot
   distinguish two connections that were ever open to the same locator or identify "the one
   this arrived on" — it only answers "has *a* reconnect happened since I last checked."

## 4. Target design

### 4.1 `Channel`: one handle type for both transports

```zig
/// A handle to the specific local socket/connection a message arrived on, or
/// was previously observed on. Meaningless outside the Transport instance
/// that produced it — never compared across transports, never put on the
/// wire, never persisted past that Transport's close().
pub const Channel = struct {
    /// Opaque, transport-private identity.
    ///   TCP: @intFromPtr(*TcpConnection) for the connection this arrived on
    ///        (accepted or dialed — both are valid targets for a reply).
    ///   UDP: @intFromPtr(*SocketEntry) for the socket this arrived on.
    token: u64,
    /// Staleness generation, transport-assigned; see §4.2/§4.3 for how each
    /// transport maintains it. Distinct from Transport.connectionGeneration()
    /// (interface.zig:459), which is keyed by Locator ("has this peer's
    /// connection been re-established") — this is keyed by Channel identity
    /// ("is this specific handle still the same underlying connection/socket,
    /// or has the slot been torn down and possibly reused").
    generation: u32,

    pub const none: Channel = .{ .token = 0, .generation = 0 };
    pub fn isNone(self: Channel) bool {
        return self.token == 0;
    }
};
```

One type, not a TCP "connection handle" and a UDP "path token" behind a shared interface —
resolves the handoff's first open question. The two transports fill `token` from an existing
heap pointer they already retain (TCP: §2.2; UDP: hardened in §4.3), so no new allocation or
lookup table is needed to produce a `Channel`.

### 4.2 TCP: reuses existing connection retention

Add one field to `TcpConnection` (`tcp.zig:257`):

```zig
generation: u32,
```

Set once, at connection creation — both `ensureConnection`'s dial path (`:490`) and
`acceptLoop`'s accept path (`:849`) already call `bumpGenerationLocked` (defined `:393`,
called `:538` and `:885` respectively) immediately after registering the connection; copy
that same returned/looked-up value onto `new_conn.generation` / `conn.generation` at the
same call site. No new counter, no new map.

`dispatchToHandlers` (`:404`) gains the connection as an argument and builds
`Channel{ .token = @intFromPtr(conn), .generation = conn.generation }` alongside the existing
`src` locator.

`sendOnChannel` for TCP (§4.5) resolves `token` back to `*TcpConnection` (a plain
`@ptrFromInt` cast — no map lookup, since the pointer is self-describing and known to be
alive per §2.2), checks `conn.fd_open.load(.acquire)` and `conn.generation == channel.generation`,
and on success does exactly what `vtSend`'s happy path already does: acquire `send_mu`,
write the 4-byte length prefix, write `data`. It does **not** retry-and-redial on failure —
a stale/closed channel is a typed error (`error.ChannelClosed`) back to the caller, who
(for a broker session) already has to handle "this peer disconnected" as a real state
transition, not something to paper over with a silent reconnect to a different socket than
the one the caller explicitly asked for.

`reuse_connection_by_host`: a channel-carrying `TcpTransport` still needs the ability to
*disable* reuse for the connections a channel-based caller cares about — broker spec §6.4:
"Disable `reuse_connection_by_host` for broker channels. Participants behind one NAT must
not share a route simply because their source IP is equal." Today `reuse_connection_by_host`
is one `schema.TcpConfig` field, transport-instance-wide (`tcp.zig:484`, `:503`) — it affects
`vtSend`'s outbound dial path only, and has no bearing on `acceptLoop`'s accepted connections
(each accept always gets its own `TcpConnection`, keyed by the actual `RemoteKey` off the
`accept()` call — reuse-by-host only ever collapses *outbound* dials in `ensureConnection`).
So accepted-connection channels are already immune to this collapsing; the risk is purely
that a caller who later drops the channel and falls back to `send(locator, …)` could still
have its *outbound* reply collapsed onto an unrelated peer's connection if
`reuse_connection_by_host = true` process-wide. Recommendation: **keep the config
transport-instance-scoped** (no new per-send override) and require broker/channel-consuming
code to run its own `TcpTransport` instance (or a dedicated participant-owned one, as
`owned_tcp_transport` already demonstrates) with `reuse_connection_by_host = false`, rather
than adding a per-call flag to the vtable. Simpler, and consistent with today's shape where
the flag is already a construction-time transport property, not a per-message one.

### 4.3 UDP: SocketEntry must survive interface churn before a Channel can

Today, `SocketEntry` is individually freed on interface loss / `unlisten` /
empty-multicast-group teardown (`udp.zig:545`, `:690`, `:733`). A `Channel.token` built from
`@intFromPtr(*SocketEntry)` would dangle across exactly the event the design most needs to
survive (a client rebinding after its interface flaps — broker spec §15's own transport
matrix: "UDP rebinding"). This PR must hardens `SocketEntry` lifetime to match what TCP's
`TcpConnection` already does:

* Add `closed: std.atomic.Value(bool)` to `SocketEntry`, set by `stop()`/`requestStop()` +
  close, mirroring `TcpConnection.fd_open`.
* Stop freeing `SocketEntry` at `removeSockets`/interface-loss time. Instead: close the fd,
  mark `closed`, and move the entry to a `dead_sockets: std.ArrayListUnmanaged(*SocketEntry)`
  retained until `UdpTransport.close()` (`:572`) — the same "graveyard, freed only at
  transport deinit" shape `all_connections` already uses for TCP.
* `sendOnChannel` checks `!entry.closed.load(.acquire)` and `entry.generation ==
  channel.generation` (a new `generation: u32` field, bumped whenever a `SocketEntry` is
  (re)created for a given `(port, addr_kind, bound_ip)` — mirrors `bumpGenerationLocked`,
  new but small: a `std.AutoHashMapUnmanaged` keyed the same way sockets already are, or
  simply a transport-wide monotonic counter stamped at creation, since per-slot reuse
  detection is the only property needed and collisions across *different* slots are
  harmless — a stale generation on the wrong slot still fails the pointer-identity check
  first).
* On success, `sendOnChannel` calls `socketSendTo(entry.fd, data, dest_sockaddr, ...)`
  directly — the same primitive `vtSend` already uses, just against `entry.fd` instead of
  the shared `send_fd_v4`/`send_fd_v6`. Because `entry.fd` is the exact socket bound to the
  interface the datagram arrived on, the OS naturally uses that interface's address as the
  outgoing source — satisfying broker §6.3's "use the service address contacted by the
  client as the reply source" with no extra bookkeeping.

Watch-item: this trades individually-freed sockets for a graveyard bounded only by interface
churn over the transport's lifetime, not by live socket count — see §9.

#### 4.3.1 Interaction with `InterfaceMonitor` (background; decision superseded by §5)

`removeUnicastSockets` is not a standalone teardown path — it is called from exactly one
place, `onIfaceChange` (`udp.zig:815`), the callback every `InterfaceMonitor` implementation
invokes when the interface set changes. This is the mechanism the §4.3 hardening plugs into,
so it is worth being precise about what drives it and what doesn't. The facts below still
hold in revision 0.2; only the "what do we do about it" conclusion changed (§5 replaces it):

* **Only one backend exists.** `InterfaceMonitor` (`interface.zig:350`) is a vtable with a
  single implementation today, `monitor/polling.zig` — enumerate-and-diff on a timer, default
  `interface_poll_interval_ms = 5_000` (`config/schema.zig:191`). The event-driven backends —
  `monitor/netlink.zig` (Linux `NETLINK_ROUTE`), `monitor/pf_route.zig` (macOS/BSD),
  `monitor/windows.zig` (`NotifyIpInterfaceChange`) — are explicit roadmap items, "deferred;
  the polling monitor is sufficient" (`roadmap.md:497`). `onIfaceChange`'s reconciliation
  logic (diff → `addUnicastSocketFromFd` / `removeUnicastSockets`) is identical regardless of
  which backend calls it — §4.3's graveyard change lives entirely inside that reconciliation,
  not inside the polling loop, so it needs no rework when an event-driven backend lands and
  automatically gets faster (near-instant instead of poll-interval-bounded) detection for
  free at that point. This same property is why §5 can build a real push notification today
  without waiting for those backends to exist.
* **Interface monitoring can be compiled out.** When `build_opts.interface_monitor == false`,
  the poll interval is forced to `0`, PollingMonitor's own sentinel for "enumerate once at
  startup, never re-poll" (`udp.zig:495`-`499`). In that build, `onIfaceChange` never fires
  reactively at all — `removeUnicastSockets` is only ever reached via `vtUnlisten`/multicast-
  group-empty paths, not interface loss. A `Channel` in that build is never invalidated by a
  NIC event, only by an explicit `unlisten`/`close` or a lost `recvfrom`/`sendto` at the OS
  level (unchanged from today — this build mode already has no interface-change awareness,
  and §5's push notification is correspondingly silent for topology causes in this build,
  same as `onIfaceChange` itself).
* **Reachability loss without an address change is out of scope, unchanged from today.** An
  interface whose IP is still assigned but is no longer physically reachable (cable pulled,
  Wi-Fi association lost without a DHCP release) is invisible to `InterfaceMonitor` — it only
  diffs *interface/address presence*, not link reachability. `send()` already has this blind
  spot; `sendOnChannel` inherits it unchanged. Not this task's problem to solve.

### 4.4 `sendOnChannel`: destination stays explicit

```zig
/// Send `data` on the specific local socket/connection identified by
/// `channel`, to `locator`, bypassing normal locator→connection resolution
/// (LocatorSelector, ensureConnection's dial-or-reuse, send_fd selection).
/// - TCP: `channel` must identify the connection; `locator` is not consulted
///   to choose a route (debug builds may assert it matches the connection's
///   peer) — a TCP channel already has exactly one peer.
/// - UDP: `channel` pins the local socket (and therefore the reply's source
///   address/interface); `locator` is the actual destination, since one UDP
///   socket serves many peers. Typically the caller passes back the `src`
///   it received alongside this same `channel`.
/// Returns error.ChannelClosed if the channel is stale (see Channel.generation).
send_on_channel: ?*const fn (ctx: *anyopaque, channel: Channel, locator: *const Locator, data: []const u8) anyerror!void = null,
```

Keeping `locator` in the signature — rather than a bare `sendOnChannel(channel, data)` —
answers the handoff's framing directly: for UDP the destination is *not* implied by the
channel (one socket, many peers), so dropping it would force a second, UDP-only entry point.
A single shape that both transports implement (TCP ignoring the locator's routing role,
UDP requiring it) is smaller than two.

`connection_generation`/`Channel.generation` interaction: unchanged, additive.
`connectionGeneration(locator)` keeps answering "has *this remote* reconnected since I last
checked" (still locator-keyed, still what `StatefulWriter`/`StatefulReader` use for proxy
resync — broker §6.4's "a new TCP connection generation does not establish discovery state
consistency by itself" is about *that* mechanism, unaffected by this change).
`Channel.generation` is narrower and newer: "is this specific handle I'm holding still good."
Neither subsumes the other; no unification attempted.

### 4.5 `on_receive` signature change: extend in place

The handoff's remaining open question — extend `ReceiveHandler` in place, or add a parallel
`on_receive_ex` — is decided in favor of **extending in place**:

```zig
pub const ReceiveHandler = struct {
    ctx: *anyopaque,
    /// Called from the transport's receive thread. Must not block.
    /// `channel` is Channel.none for a transport with no channel concept
    /// (UDP-simple builds that skip §4.3's hardening — none exist; memory,
    /// mock, lossy) or for any receive path that doesn't populate one.
    on_receive: *const fn (ctx: *anyopaque, data: []const u8, src: Locator, channel: Channel) void,
    /// Called from the transport's receive/monitor thread — same "must not
    /// block" contract as on_receive — when a channel on this handler's
    /// port/connection closes. Optional: leave null to ignore. Never called
    /// with Channel.none.
    ///
    /// Fan-out matches on_receive's: every handler currently registered on
    /// the same port (UDP) or connection (TCP) is notified, not only
    /// handlers that specifically observed this channel via on_receive — a
    /// handler that registers after a channel's last on_receive but before
    /// that channel closes will still be notified of a channel it was never
    /// handed. Callers needing precise per-channel recipient tracking must
    /// do it themselves. See §5.
    on_channel_closed: ?*const fn (ctx: *anyopaque, channel: Channel) void = null,
};
```

Rationale: a parallel `on_receive_ex` bifurcates every future transport and every future
consumer forever — every new transport implementation would need to decide which one(s) to
implement, and every RTPS/discovery caller would need to decide which one(s) to register,
in perpetuity. The project has repeatedly chosen one generalized mechanism over a
parallel/bolt-on one when the same tradeoff came up (`ListenerBox` refcount generalized
across all six entity types rather than kept JNI-only; `EntityQuiesce` generalized from
`ListenerBox`'s pattern to the whole entity rather than adding a second parallel guard). The
blast radius (§2.3) is seven files, three of which need only a type-signature change with no
logic change (`memory.zig`, `mock.zig`, `lossy.zig` pass `Channel.none` or forward whatever
they're given). The other four (`tcp.zig`, `udp.zig`, `sedp.zig`, `spdp.zig`) already have to
change for this feature to exist at all. `on_channel_closed` rides the same struct rather than
a separate registration mechanism for the same reason — see §5.

### 4.6 `LocatorSelector` stays untouched, explicitly bypassed

No change to `locator_selector.zig` itself (§2.4: it's already locator-only, no connection
concept to add). The requirement is at the call sites: a channel-routed reply must call
`Transport.sendOnChannel` directly, never go through `selectInto` → `Transport.send`. This is
naturally true for every consumer this task targets (a broker session reply, a NAT'd TCP
data reply) because those callers already have the exact channel they want to use — they
were never going to rank candidate locators in the first place. Verification (§8) adds an
explicit test that proves it.

## 5. `on_channel_closed`: the push-notification API surface

Revision 0.1 stopped at "the holder finds out lazily, on next send" and explicitly deferred a
push notification as speculative. Revision 0.2 built a real one — and, alongside it, a full
design for TCP to actively call it on a new event class (local-interface loss). Revision 0.3
keeps the API, drops the new TCP caller: build the notification mechanism now, since it's
small and immediately useful for what UDP already does (§5.1); decide what/how TCP grows the
awareness to call it for a topology reason later, as part of the larger "make
`InterfaceMonitor` a real, complete thing for zzdds" roadmap effort (§5.2) — that decision was
explicitly deferred by direction, not by default.

### 5.1 What ships in this task

* `ReceiveHandler.on_channel_closed` (§4.5) — the field, the "must not block" contract, and
  the "never called with `Channel.none`" contract, fanned out through the exact same
  snapshot-then-call mechanism `dispatchToHandlers`/`PortEntry.dispatch` already use for
  `on_receive` (§2.2's thread-safety contract applies identically — no new lock inside the
  callback).
* Two firing sites, both already-existing close paths — no new triggering logic:
  * **TCP, natural death:** `closeConnFdOnce`'s winning CAS (`tcp.zig:272`) — the single
    choke point both `recvLoop`'s natural-death path (peer RST/close) and `deinit`'s
    forced-teardown path already funnel through. This is the *only* TCP trigger in this task.
  * **UDP:** the graveyard-move inside `removeUnicastSockets` (§4.3) — driven by UDP's
    *existing* `onIfaceChange`/`InterfaceMonitor` integration, which predates this task
    entirely. §4.3's job is making that pre-existing teardown *safe* for a `Channel` holder
    (no dangling pointer); this section's job is making it *observable* (a push, not just
    `error.ChannelClosed` discovered lazily on next `sendOnChannel`). Promptness here is
    exactly §4.3.1's existing analysis: bounded by whichever `InterfaceMonitor` backend is
    active (default 5s with only `PollingMonitor` today; better whenever an event-driven
    backend eventually lands, unaffected by whether it does).
* A caller that doesn't register `on_channel_closed` sees no behavior change — it still has
  §4.2/§4.3's `error.ChannelClosed` on next use, exactly as revision 0.1 specified. Strictly
  additive.

### 5.2 What's deliberately deferred: TCP proactively firing on interface loss

TCP has no mechanism today to detect that *its own* local interface disappeared — no
`InterfaceMonitor` integration at all, no keepalive, no connect/write deadline (`TcpConfig`,
`config/schema.zig:70`-`:86` — none of those fields exist), so established connections rely
entirely on the OS's own passive TCP failure detection (a peer RST, or an eventual
retransmission-timeout on a black-holed route — unbounded and platform-dependent, commonly
tens of minutes on Linux with default `tcp_retries2` and no keepalive configured). A TCP
connection whose local interface vanishes today stays "open" from this task's point of view
until the OS eventually notices — `on_channel_closed` does not fire for that case in this
task, only for natural death (§5.1).

This is a real, named, accepted gap, not an oversight, and revision 0.2 worked out a concrete
fix for it before this revision moved that work out of this task's scope: give `TcpTransport`
its own `InterfaceMonitor` (mirroring `UdpTransport.init`'s existing optional-injection
pattern), track each connection's concrete local address via `getsockname()` (already used
elsewhere in `tcp.zig` for a different purpose, so the primitive is proven in this codebase),
and on a topology event proactively close any connection whose local address just
disappeared — which would also complete `TcpTransport.vtSetLocatorChangeHandler`
(`tcp.zig:723`), a callback that is registered today and silently never fired (grepped
`locator_change_handler` in `tcp.zig`: the field, its `null` initializer, and the setter —
zero `.on_change(` call sites). None of that design work is lost: it moved, close to
verbatim, into `docs/roadmap.md` → *Discovery / RTPS / transport* → "Make `InterfaceMonitor` a
real, complete thing for zzdds", item 2 — including the exact `getsockname()` call sites, the
`local_ip` field sketch, and the dead-`locator_change_handler` finding — as the starting point
for whoever picks it up. `on_channel_closed`'s API needs no change when that lands: it just
gains a second TCP firing site (that future reconciliation function calling the existing
`closeConnFdOnce`), the same shape UDP already has today.

### 5.3 The backend contract, and the shared-monitor question, also live in the roadmap now

Two more pieces of revision 0.2's design also moved into the same consolidated roadmap entry
rather than staying here, since neither requires any code in this task:

* **What a future platform-specific `InterfaceMonitor` backend (netlink/PF_ROUTE/Windows)
  must guarantee** — prompt delivery with a bounded coalescing window, graceful fallback to
  `PollingMonitor` on init failure, `enumerate()` staying the single source of truth
  regardless of how a backend internally tracks changes. This constrains any future backend,
  not this task's transport code, so it belongs with the backends' own roadmap item.
* **Whether UDP and TCP should eventually share one `InterfaceMonitor` instance** instead of
  each owning an independent one — moot for *this* task (TCP doesn't own a monitor at all
  here), relevant once §5.2's deferred work gives it one. Recorded as its own point in the
  same roadmap entry, with the concrete constructor-chain blast radius already enumerated
  (`DomainParticipantFactoryImpl.init`/`DomainParticipantImpl.init` and at least six call
  sites in `raw_ops.zig`/`c_abi/extensions.zig`) so it isn't re-derived from scratch later.

See `docs/roadmap.md` → *Discovery / RTPS / transport* → "Make `InterfaceMonitor` a real,
complete thing for zzdds" for all three, together.

## 6. Decisions on the handoff's open questions

| Question | Decision |
| --- | --- |
| One channel-handle type for both transports, or TCP handle + UDP path token? | One `Channel{ token: u64, generation: u32 }` (§4.1); UDP fills `token` with a socket identity instead of a connection identity, and `sendOnChannel` keeps `locator` explicit so UDP's "many peers per socket" shape doesn't need a second type. |
| Handle representation across the C ABI boundary? | Zig-internal, per the handoff's own lean. No `src/c_abi/*` file references `transport.Transport` or `iface.Transport` today (grepped, zero hits) — there is no existing C-ABI transport surface to extend, and the broker client is Zig. Not revisited unless a future non-Zig broker client is proposed. |
| Extend `ReceiveHandler` in place, or add `on_receive_ex`? | Extend in place (§4.5). Seven-file blast radius, three of them mechanical. `on_channel_closed` (§5) rides the same struct for the same reason. |
| Interaction with `connection_generation`? | Layer alongside, not replace (§4.4). Different keys (locator vs. channel identity), different questions ("has a reconnect happened" vs. "is this handle still good"). |
| Stale-handle safety — how is a caller told, must the transport keep the allocation alive? | Typed `error.ChannelClosed` from `sendOnChannel` (§4.2), checked via `generation` + a liveness flag (`fd_open` / `closed`) already present (TCP) or added (UDP, §4.3) — a correctness guarantee. **Also** a push `on_channel_closed` notification (§5) — a liveness guarantee, from two pre-existing close paths (TCP natural death, UDP's existing interface-monitor-driven teardown); TCP does not yet fire it for local-interface loss (§5.2, deferred). Allocation lifetime: TCP already keeps it until transport `close()`; UDP must be changed to match (§4.3). |
| `bind_wildcard` / multi-homed UDP interaction? | Unaffected. `bind_wildcard = true` (single `0.0.0.0` socket) still yields exactly one `SocketEntry`, so `sendOnChannel` degenerates to "the one socket there is" — same code path, no special case. `bind_wildcard = false` (default) is the case §4.3 is written for: one `SocketEntry` per interface, and the channel pins the correct one. |
| How does this interact with `InterfaceMonitor`, including the deferred platform-specific backends? | §5: `on_channel_closed` fires from UDP's *existing* interface-monitor integration (no new UDP work beyond §4.3's safety hardening) and from TCP's natural death only. TCP gaining its own `InterfaceMonitor` to fire it for local-interface loss too, the platform-specific backend contract, and the shared-monitor-instance question are all deliberately deferred to `docs/roadmap.md`'s consolidated "Make `InterfaceMonitor` a real, complete thing for zzdds" entry (§5.2/§5.3) — a scope decision, not an open design question left for later. |

## 7. Explicitly out of scope

* The broker itself, its wire protocol, session/admission logic, NAT traversal, ICE/STUN.
* Any new transport implementation. This is interface + UDP/TCP plumbing only.
* Reworking UDP's source-socket selection for `send()` (the non-channel path) beyond what
  `sendOnChannel` itself needs — `send_fd_v4`/`send_fd_v6` and `mc_send_ifaces` are
  untouched.
* An evented/async TCP backend (roadmap, "Concurrency model" design task, still unscoped).
  This change must not preclude it: `Channel.token` as a bare pointer assumes today's
  threaded ownership model where the referenced object's memory is stable; an evented
  backend revisits transport internals wholesale and would need to re-derive what `Channel`
  means for it, but nothing here commits the evented design to pointer-shaped handles.
* Raising or restructuring the `MAX_RECEIVE_HANDLERS = 64` dispatch-snapshot cap
  (`interface.zig:401`, roadmap: "revisit before the factory pattern makes spinning up many
  participants easy"). Unrelated axis; noted only because both live in the same struct.
* Making `reuse_connection_by_host` a per-send override (§4.2: stays transport-instance-scoped).
* **TCP proactively firing `on_channel_closed` on local-interface loss** — the whole
  `TcpTransport`-owns-a-monitor / `local_ip`-via-`getsockname` / proactive-eviction /
  complete-`locator_change_handler` design (§5.2). Moved to `docs/roadmap.md`'s consolidated
  entry, by explicit direction, rather than split into its own PR alongside this one. TCP's
  `on_channel_closed` covers natural death only in this task.
* Writing the event-driven `InterfaceMonitor` backends themselves
  (`netlink.zig`/`pf_route.zig`/`windows.zig`), their delivery/fallback contract, and whether
  UDP and TCP should eventually share one monitor instance — all in the same roadmap entry
  (§5.3), none of it requiring code in this task.
* Automatic TCP listen-socket rebinding when the locally bound address changes (e.g. a DHCP
  renewal) — moot in this task since TCP gains no interface-change awareness here at all;
  would be a question for whoever picks up §5.2's deferred work, not this one.

## 8. Verification expectations

* **Accepted-connection reply.** A `TcpTransport` client dials in; the server's handler
  receives a `Channel`; `sendOnChannel` back to it succeeds even when the client's
  advertised listening locator is deliberately unreachable (simulate NAT: client listens on
  a port the server is never told to route to, only the accepted connection works).
* **UDP reply pinned to the contacted socket/path.** Two `SocketEntry`s bound to two
  different local interfaces (loopback + a second interface, or two bound addresses in a
  test harness); a datagram arriving on socket A gets its `sendOnChannel` reply verified to
  exit socket A's fd (assert via `getsockname`/observed source address on the receiving
  peer), not socket B, even when B's cached `send_fd` would otherwise have been picked by
  plain `send()`.
* **UDP rebind survives.** A client's interface goes down and comes back (or is simulated by
  tearing down and recreating a `SocketEntry` for the same port) — a `Channel` obtained
  before the flap correctly returns `error.ChannelClosed` afterward rather than a
  use-after-free or a silently-wrong send (validates §4.3's graveyard). Drive this by calling
  `onIfaceChange` directly with a synthetic before/after interface list (the existing UDP
  tests already do this — e.g. the `on_change` fixtures around `udp.zig:1972`,`:2185` — rather
  than waiting out `interface_poll_interval_ms` in real time.
* **Interface monitoring compiled out.** With `build_opts.interface_monitor = false`
  (§4.3.1), `sendOnChannel` and channel dispatch still build and behave correctly — no
  reactive teardown occurs, which is the existing, unrelated behavior of that build mode, not
  a new failure.
* **Same source host IP, two logical peers, no route collision.** With
  `reuse_connection_by_host = false` (the broker/channel-consumer configuration, §4.2), two
  accepted connections from the same source IP (different ports) each get a distinct,
  independently addressable `Channel` and neither's replies land on the other's socket.
* **`LocatorSelector` is not consulted.** A focused test instruments (or wraps)
  `selectInto`/`Transport.send` to assert zero calls occur on a code path that uses
  `sendOnChannel` exclusively (§4.6).
* **`on_channel_closed` fires exactly once per channel, on every death path this task
  builds (§5):** peer-initiated TCP close, `deinit`-forced TCP teardown, and UDP
  graveyard-move (§4.3) via a synthetic `onIfaceChange`. A handler that leaves
  `on_channel_closed = null` observes no change in behavior (regression coverage for every
  existing `ReceiveHandler` registrant — `participant.zig`, `sedp.zig`, `spdp.zig`). No test
  for a TCP topology-triggered fire — there is no such trigger in this task (§5.2).
* **IPv4/IPv6**, and `memory`/`mock`/`lossy` still build and pass with `send_on_channel` left
  `null` and every `on_receive` call site passing/forwarding `Channel.none` — extend
  `test/transport/transport_interface_test.zig`, `test/transport/lossy_transport_test.zig`,
  `test/rtps/mock_transport_test.zig`.
* **Existing TCP/UDP unit tests unchanged in behavior** — `test/transport/tcp_transport_test.zig`
  and `udp.zig`'s in-file `test` blocks (e.g. the `bind_wildcard` cases around `:1617`+) pass
  without behavior changes beyond the new fields; the live interop suite
  (`interoperability_report.py`) unaffected, since native SPDP/SEDP/user-data paths never
  populate or consult a non-`none` `Channel` and never register `on_channel_closed`.
* `zig build test-tsan` clean — `dispatchToHandlers`/`PortEntry.dispatch`/`recvThread` gain
  fields to copy into the snapshot, no new lock there; the TCP/UDP graveyard-append paths
  (§4.2, §4.3) need their own lock discipline reviewed under TSan given this repo's history of
  exactly this shape of bug (`project-rtps-proto-quiesce`: `participant.mu` held across
  discovery I/O; `project-tsan-allocator-expansion`: `writer.zig` had zero mutex).

## 9. Risks and watch-items

* **`on_channel_closed` fan-out is "every handler currently registered on the port/
  connection," not "only handlers that actually received this channel."** Found in PR #84
  review (Greptile): a handler that registers on a shared port after a channel's last
  `on_receive` but before that channel closes is still notified of a channel it was never
  handed. Building precise per-channel recipient tracking (a per-channel set of handler
  `ctx` pointers, updated on every dispatch, pruned on unregister) was considered and
  rejected as disproportionate to the actual risk: `on_receive` already has the identical
  broadcast-to-everyone-currently-registered semantics (no consumer of this codebase relies
  on per-handler receive filtering today), and nothing in the tree consumes
  `on_channel_closed` yet to be broken by it. Resolution: the contract in §4.5/`interface.zig`
  is corrected to state the real, broadcast behavior plainly rather than promise scoped
  delivery the implementation doesn't provide. A future real consumer that needs scoped
  delivery must track token+generation itself and ignore closures for channels it never saw.
* **UDP `SocketEntry` graveyard is unbounded by live-socket count.** §4.3 trades
  individually-freed sockets for retention until `UdpTransport.close()`. A long-running
  process on a host with frequent interface churn (laptop suspend/resume, container network
  reconfiguration, VPN flap) accumulates dead `SocketEntry` structs for the transport's
  lifetime. Each is small (one `fd` slot already closed, no buffers retained), but this is a
  real, open-ended memory-growth axis that TCP's equivalent (`all_connections`) does not
  share to the same degree, because TCP connection count is naturally bounded by peer count
  rather than by interface-flap count. Worth a periodic-compaction follow-up (e.g., prune
  graveyard entries whose `generation` no caller could plausibly still be holding) if it
  proves to matter in practice — not attempted in this PR.
* **`Channel.token` as a raw pointer relies on today's "never freed until close" retention.**
  If a future change reintroduces early freeing on either side (e.g., a memory-pressure
  reap of idle TCP connections — not currently proposed anywhere, but plausible future work)
  it would reopen the UAF this design just closed for UDP. The `generation` check catches
  reuse of the *same* slot, not a dangling pointer into freed memory for a *different*
  reason. Any future change to either retention policy must re-examine this.
* **Blast radius touches TSan-sensitive receive paths.** `dispatchToHandlers` (TCP) and
  `PortEntry.dispatch`/`recvThread` (UDP) are exactly the code the project has twice found
  real concurrency bugs in during scaling/hardening passes (`project-rtps-proto-quiesce`,
  `project-tsan-allocator-expansion`). The signature change itself is mechanical, but the new
  graveyard-append/lookup logic on both sides is new locking surface and deserves the same
  scrutiny those passes gave the existing code, not a rubber stamp because "it's just adding
  a field."
* **This does not fix `MAX_RECEIVE_HANDLERS = 64`** (§7) — a channel-heavy broker session
  design that registers many per-session handlers on one port would hit that cap sooner than
  today's one-handler-per-participant-per-transport pattern. Flagged, not addressed.
* **TCP's local-interface-loss blind spot is unchanged by this task.** A TCP connection whose
  local interface disappears is still detected only by the OS's own unbounded passive failure
  detection (§5.2) — `on_channel_closed` does not fire for that case here. This is a real,
  present gap (worse than UDP's, which at least degrades to the poll interval), deliberately
  not closed by this PR, tracked instead in `roadmap.md`'s consolidated "Make
  `InterfaceMonitor` a real, complete thing for zzdds" entry. Worth being explicit that this
  spec *identifies* the gap without *fixing* it, so it doesn't read as newly discovered later.
* **Evented-backend non-preclusion is asserted, not proven.** §7 states the intent; the
  actual "Concurrency model" design task (roadmap, still unscoped) is the place that would
  either confirm `Channel`'s pointer-handle shape survives an evented rewrite or require a
  revision. This spec does not attempt to pre-solve that.

## 10. Pointers

* Handoff (superseded by this spec; keep for the original framing/provenance):
  `zz-dev/transport-channel-handoff.md`.
* Review: `docs/design/discovery-broker-review.md` §2, §4.3, §4.4, §10 (branch `broker_spec`).
* Broker spec: `docs/design/discovery-broker.md` §6.3 (UDP obligations), §6.4 (TCP
  obligations), §14 rows for `transport/interface.zig` / `udp.zig` / `tcp.zig` /
  `participant.zig`, §15 (transport matrix) (branch `broker_spec`).
* `src/transport/interface.zig` (`Transport.Vtable` `:410`, `ReceiveHandler` `:385`,
  `connection_generation` `:459`, `MAX_RECEIVE_HANDLERS` `:401`, `InterfaceMonitor` `:350`).
* `src/transport/tcp.zig` (`TcpConnection` `:257`, `TcpTransport` `:280`, `ensureConnection`
  `:478`, `vtSend` `:563`, `acceptLoop` `:762`, `recvLoop` `:892`, `bumpGenerationLocked`
  `:393`, `reuse_connection_by_host` checks `:484`,`:503`, `deinit`'s shutdown+close pair
  `:365`-`:366`; `getsockname` uses `:661`,`:667` and `locator_change_handler`
  field `:322`/setter `:727` — registered but never fired — are background for §5.2's
  deferred work, detailed in `roadmap.md` instead).
* `src/transport/udp.zig` (`SocketEntry` `:209`, `PortEntry` `:282`, `vtSend` `:910`,
  `recvThread` `:1285`, `removeSockets` `:718`, `onIfaceChange` `:815`, `addUnicastSocketFromFd`
  `:655`, `removeUnicastSockets` `:677`, monitor wiring `:486`-`:514`).
* `src/transport/monitor/polling.zig` (only implemented backend; fallback-intent comment
  `:7`-`:9`; `PollingMonitor` `:231`).
* `src/config/schema.zig` (`interface_poll_interval_ms` `:191`).
* `src/transport/locator_selector.zig` (`selectInto` `:33`).
* `src/dcps/participant.zig` (`owned_tcp_transport` doc comment `:818`, field `:831`,
  `TcpTransport.init` call `:968`, `DataLocatorReachability` wiring `:1157`+).
* `src/discovery/interface.zig` (`DataLocatorReachability` `:109`).
* `docs/design/thread-model.md` (current thread ownership: accept thread + recv thread per
  connection/socket; receive-thread callback contract).
* `docs/decisions.md` → *Transport / Discovery* ("RTPS framing is not a plugin"; NIC/
  multicast interface selection — `bind_wildcard` default).
* `docs/roadmap.md` → *Discovery / RTPS / transport* → "Make `InterfaceMonitor` a real,
  complete thing for zzdds" (§5.2/§5.3's deferred design work lives here — TCP topology
  awareness, platform-specific backend contract, shared-monitor-instance question — including
  the `src/raw_ops.zig`/`src/c_abi/extensions.zig` constructor-chain citations); also
  64-handlers-per-port cap, "TCP for discovery too" mode; and *Design Tasks* → *Concurrency
  model* (evented-backend direction this change must not preclude).
* `docs/architecture.md` → *InterfaceMonitor* (`:76`-`:99`): vtable shape, implemented vs.
  deferred backends.

## 11. Implementation sequencing

One PR, entirely within `zzdds` (no cross-repo split, unlike `discovery-codec.md`'s PR A/PR
B). Revision 0.2 split this into five PRs; the piece that justified the split — TCP growing
its own `InterfaceMonitor` integration (old PR 4) — is exactly what §5.2 moved out to the
roadmap. What remains is one coherent, non-separable feature: `Channel`/`sendOnChannel` for
both transports, plus `on_channel_closed` firing from the close paths that already exist.
None of its pieces has independent value in isolation — a `Channel` type nothing produces
yet, or a notification nothing fires yet, aren't reviewable slices on their own — so there is
no dependency graph to draw.

Contents, mapped to design sections and §8 verification:

* `Channel` type (§4.1), `Transport.Vtable.send_on_channel` (§4.4).
* `ReceiveHandler.channel`/`on_channel_closed` fields (§4.5) — touches the seven files from
  §2.3, mechanically for four of them (`memory.zig`, `mock.zig`, `lossy.zig` pass/forward
  `Channel.none`; `sedp.zig`/`spdp.zig` as registrants need no logic change at all).
* `TcpConnection.generation` (§4.2), `dispatchToHandlers` populates a real `Channel`,
  `sendOnChannel` implemented for TCP, `on_channel_closed` fired from `closeConnFdOnce`'s
  winning CAS (§5.1) — natural death only (§5.2 explicitly out of scope).
* `SocketEntry` hardening — `closed` flag, graveyard, `generation` (§4.3) — `sendOnChannel`
  implemented for UDP, `on_channel_closed` fired from the graveyard-move inside
  `removeUnicastSockets` (§5.1) — UDP's existing `InterfaceMonitor` integration, unchanged,
  just now observable.
* Verification: the full §8 list minus the two bullets that no longer apply (TCP proactive
  eviction, platform-specific-monitor fallback — both moved with §5.2/§5.3 to the roadmap).

What's deliberately not in this PR: everything in §7, most notably TCP proactively firing
`on_channel_closed` on local-interface loss and everything else now tracked in `roadmap.md`'s
"Make `InterfaceMonitor` a real, complete thing for zzdds" entry (§5.2/§5.3).
