//! SPDP — Simple Participant Discovery Protocol (RTPS 2.5 §8.5.3).
//!
//! SpdpEndpoints manages the two SPDP built-in endpoints:
//!   - StatelessWriter: periodically multicasts SPDPdiscoveredParticipantData
//!   - StatelessReader: receives those announcements from peers
//!
//! On `start()`:
//!   1. Serialise the local ParticipantAnnouncement to PL-CDR and write it into
//!      the StatelessWriter cache.
//!   2. Register the SPDP multicast locator as the writer's reader-locator.
//!   3. Call transport.listen + joinMulticast on the SPDP multicast port.
//!   4. Spawn a timer thread that periodically calls reannounce() (bumping the SN
//!      before resending) and checks leases.
//!
//! PL-CDR encoding is hand-written (no dependency on zidl-generated code here).

const std = @import("std");
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const iface = @import("interface.zig");
const wire_codec = @import("wire_codec.zig");
const tr_iface = @import("../transport/interface.zig");
const guid_mod = @import("../rtps/guid.zig");
const pid_mod = @import("../rtps/pid.zig");
const writer_sm_mod = @import("../rtps/writer_sm.zig");
const reader_sm_mod = @import("../rtps/reader_sm.zig");
const parser_mod = @import("../rtps/message/parser.zig");
const history_mod = @import("../rtps/history.zig");
const mutex_mod = @import("../util/mutex.zig");
const time_mod = @import("../util/time.zig");
const sn_mod = @import("../rtps/sequence_number.zig");
const header_mod = @import("../rtps/message/header.zig");
const zidl_rt = @import("zidl_rt");
const Disc = @import("zzdds_disc_generated");

const Transport = tr_iface.Transport;
const Locator = tr_iface.Locator;
const LocatorKind = tr_iface.LocatorKind;
const LocatorWire = tr_iface.LocatorWire;
const ReceiveHandler = tr_iface.ReceiveHandler;
const Guid = guid_mod.Guid;
const GuidPrefix = guid_mod.GuidPrefix;
const EntityIds = guid_mod.EntityIds;
const StatelessWriter = writer_sm_mod.StatelessWriter;
const StatelessReader = reader_sm_mod.StatelessReader;
const CacheChange = history_mod.CacheChange;
const ChangeKind = history_mod.ChangeKind;
const RtpsTimestamp = time_mod.RtpsTimestamp;
const Mutex = mutex_mod.Mutex;
const SequenceNumber = sn_mod.SequenceNumber;
const Callbacks = iface.Callbacks;
const ParticipantAnnouncement = iface.ParticipantAnnouncement;
const ParticipantData = iface.ParticipantData;
const Discovery = iface.Discovery;
const BuiltinEndpointSet = pid_mod.BuiltinEndpointSet;

/// Floor for genuine SPDP re-announcement intervals fed into the EMA in
/// processSpdpPayload. Real-world SPDP periods are seconds, never sub-100ms;
/// anything faster is almost certainly duplicate delivery of the same
/// announcement (e.g. a multi-homed peer transmitting redundantly across
/// several local interfaces), not a legitimately fast announcer.
const MIN_PLAUSIBLE_INTERVAL_NS: i64 = 50_000_000; // 50ms

// ── State for one known remote participant ────────────────────────────────────

pub const KnownParticipant = struct {
    data: ParticipantData,
    /// Monotonic expiry timestamp in ns (from timer_clock.nowNs()).
    expires_ns: i64,
    alloc: std.mem.Allocator,
    /// Monotonic timestamp (ns) of the most recently received SPDP announcement.
    last_seen_ns: i64,
    /// Smoothed (EMA) inter-announcement interval in ns; 0 until two announcements observed.
    observed_interval_ns: i64,
    /// True while a liveness probe is outstanding for this participant.
    probe_active: bool,
    /// SPDP builtin writer SN of the most recently processed announcement. Multi-homed
    /// peers commonly resend the *same* SPDP sample redundantly across several local
    /// interfaces within microseconds of each other; a repeated SN identifies that as
    /// duplicate delivery rather than a genuine (fast) re-announcement, so it doesn't
    /// poison observed_interval_ns. See processSpdpPayload.
    last_writer_sn: SequenceNumber,
    /// True once real SEDP endpoint traffic (a DiscoveredWriterData or
    /// DiscoveredReaderData) has been received from this participant. Set by
    /// SEDP via markSedpSeen; carried forward across re-announcements (a fresh
    /// decode always starts false). See the SEDP-traffic-seen heuristic in
    /// processSpdpPayload.
    sedp_seen: bool,

    pub fn deinit(self: *KnownParticipant) void {
        self.alloc.free(self.data.name);
        self.alloc.free(self.data.metatraffic_unicast_locators);
        self.alloc.free(self.data.metatraffic_multicast_locators);
        self.alloc.free(self.data.default_unicast_locators);
        self.alloc.free(self.data.default_multicast_locators);
        self.alloc.free(self.data.default_unicast_locators_for_data);
        self.alloc.free(self.data.default_multicast_locators_for_data);
    }
};

// ── SpdpEndpoints ─────────────────────────────────────────────────────────────

/// SPDP built-in endpoints + background timer thread.
/// Implements SPDP participant discovery only. Endpoint announce/retract vtable
/// methods are no-ops here; `SpdpSedpDiscovery` composes this with `SedpEndpoints`
/// and routes endpoint discovery calls to SEDP.
pub const SpdpEndpoints = struct {
    alloc: std.mem.Allocator,
    transport: Transport,
    domain_id: u32,

    // RTPS state machines
    //
    // `writer` starts null and is published exactly once, in `start()`, under
    // `mu`. Every other read/write of this field must also go under `mu` (a
    // snapshot-then-release pattern — never call into the writer itself while
    // holding `mu`, per the lock-order note on `processSpdpPayload`) even
    // though the pointer itself never changes after publication: without that,
    // the initial publish and a concurrent early read (e.g. from the receive
    // thread right after `transport.listen()` is wired up) race per TSan.
    writer: ?*StatelessWriter,
    reader: StatelessReader,

    // Known remote participants (protected by mu)
    mu: Mutex,
    known: std.AutoHashMap(GuidPrefix, KnownParticipant),
    unsupported_locator_mu: Mutex,
    unsupported_locator_kinds: std.AutoHashMap(i32, void),

    // Timer thread
    timer_thread: ?std.Thread,
    shutdown: std.atomic.Value(bool),
    announcement_period_ms: u32,

    // Set in start()
    callbacks: ?*const Callbacks,
    spdp_multicast_port: u16,
    /// Stash local name for re-announcement.
    local_payload: ?[]u8, // PL-CDR bytes, owned

    // Pluggable clock (default: realtime; swap for ManualClock in tests).
    clock: time_mod.Clock,

    // Wire trace (zero-size when disabled).
    tracer: trace.Tracer,

    // SEDP callback: called when a participant is (re-)discovered,
    // so SEDP can wire up the RTPS proxies.
    on_participant_discovered_sedp: ?*const fn (
        ctx: *anyopaque,
        data: *const ParticipantData,
    ) void,
    sedp_ctx: ?*anyopaque,

    // Fast-announce: when a new participant is discovered, halve the announcement
    // period for 2× the normal period instead of blasting an immediate unicast
    // reply (which causes an N² burst when N participants start simultaneously).
    // Monotonic ns timestamp; 0 = not in fast mode. Written by discovery callbacks,
    // read by the timer thread — accessed via atomic to avoid needing the mutex.
    fast_announce_until_ns: std.atomic.Value(i64),

    // Liveness probe: when SPDP silence exceeds the probe trigger threshold,
    // SPDP calls begin_probe_fn to start a directed non-final HB probe via the
    // SEDP reliable writers.  The probe result fires back via onProbeResult.
    begin_probe_fn: ?*const fn (*anyopaque, GuidPrefix, i64) void,
    begin_probe_ctx: ?*anyopaque,

    // Set in start() from ParticipantAnnouncement.data_reachable. Null (the
    // default) means the local participant's data transport is the same as
    // this discovery transport — see filterKnownParticipantLocators.
    data_reachable: ?iface.DataLocatorReachability,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        transport: Transport,
        domain_id: u32,
        announcement_period_ms: u32,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .transport = transport,
            .domain_id = domain_id,
            .writer = null,
            .reader = StatelessReader.init(Guid{
                .prefix = GuidPrefix.unknown,
                .entity_id = EntityIds.spdp_builtin_participant_reader,
            }),
            .mu = .{},
            .known = std.AutoHashMap(GuidPrefix, KnownParticipant).init(alloc),
            .unsupported_locator_mu = .{},
            .unsupported_locator_kinds = std.AutoHashMap(i32, void).init(alloc),
            .timer_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .announcement_period_ms = announcement_period_ms,
            .callbacks = null,
            .spdp_multicast_port = 0,
            .local_payload = null,
            .clock = time_mod.monotonicClock(),
            .tracer = trace.Tracer.noop(),
            .on_participant_discovered_sedp = null,
            .sedp_ctx = null,
            .fast_announce_until_ns = std.atomic.Value(i64).init(0),
            .begin_probe_fn = null,
            .begin_probe_ctx = null,
            .data_reachable = null,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        // No other thread should still be touching `self` by this point
        // (callers must `stop()`, which joins the timer thread and unlistens
        // the receive callback, before `deinit()`), but the lock is cheap and
        // keeps every access to `self.writer` uniformly guarded.
        self.mu.lock();
        const w_opt = self.writer;
        self.mu.unlock();
        if (w_opt) |w| w.deinit();
        if (self.local_payload) |p| self.alloc.free(p);
        var it = self.known.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        self.known.deinit();
        self.unsupported_locator_mu.lock();
        self.unsupported_locator_kinds.deinit();
        self.unsupported_locator_mu.unlock();
        self.alloc.destroy(self);
    }

    /// Override the wire tracer used by the SPDP StatelessWriter.
    /// Must be called before `start()` to take effect.
    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.tracer = t;
    }

    /// Swap the clock implementation. Pass a ManualClock for deterministic tests.
    pub fn setClock(self: *Self, c: time_mod.Clock) void {
        self.clock = c;
    }

    /// Optionally wire in the SEDP layer to be notified when participants change.
    pub fn setSedp(
        self: *Self,
        ctx: *anyopaque,
        cb: *const fn (*anyopaque, *const ParticipantData) void,
    ) void {
        self.on_participant_discovered_sedp = cb;
        self.sedp_ctx = ctx;
    }

    /// Wire the SEDP liveness-probe initiator.  When SPDP detects announcement
    /// silence, it calls fn_ptr(ctx, prefix, deadline_ns) to kick off a directed
    /// non-final HB probe on the SEDP reliable writers.
    pub fn setBeginProbeFn(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, GuidPrefix, i64) void,
    ) void {
        self.begin_probe_fn = fn_ptr;
        self.begin_probe_ctx = ctx;
    }

    /// Called by SEDP when a liveness probe resolves.
    ///   alive=true  → reset the participant's expiry/last-seen; clear probe flag.
    ///   alive=false → evict the participant and fire on_participant_lost.
    pub fn onProbeResult(ctx: *anyopaque, prefix: GuidPrefix, alive: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        const kp_ptr = self.known.getPtr(prefix) orelse {
            self.mu.unlock();
            return;
        };
        // Guard against a stale probe result arriving after re-announcement or
        // a second probe fired by a different SEDP writer.
        if (!kp_ptr.probe_active) {
            self.mu.unlock();
            return;
        }
        kp_ptr.probe_active = false;
        if (alive) {
            const now_ns = self.clock.nowNs();
            kp_ptr.expires_ns = now_ns + @as(i64, @intCast(kp_ptr.data.lease_duration_ms)) * std.time.ns_per_ms;
            kp_ptr.last_seen_ns = now_ns;
            self.mu.unlock();
        } else {
            var kp = self.known.fetchRemove(prefix).?;
            self.mu.unlock();
            const guid = kp.value.data.guid;
            kp.value.deinit();
            if (self.callbacks) |cbs| cbs.on_participant_lost(cbs.ctx, guid);
        }
    }

    /// Called by SEDP when a DiscoveredWriterData or DiscoveredReaderData is
    /// received from `prefix`. Marks the participant so processSpdpPayload
    /// stops retransmitting SPDP on its behalf. A no-op if the participant
    /// isn't (or is no longer) known.
    pub fn markSedpSeen(ctx: *anyopaque, prefix: GuidPrefix) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        if (self.known.getPtr(prefix)) |kp| kp.sedp_seen = true;
    }

    pub fn start(
        self: *Self,
        local: *const ParticipantAnnouncement,
        callbacks: *const Callbacks,
    ) !void {
        self.callbacks = callbacks;
        self.data_reachable = local.data_reachable;

        // Fix the GUID prefix now that we know it.
        self.reader.guid.prefix = local.guid.prefix;

        // Determine SPDP well-known multicast port from the announced locators.
        // Default = first metatraffic multicast locator's port; fall back to 7400.
        self.spdp_multicast_port = if (local.metatraffic_multicast_locators.len > 0)
            switch (local.metatraffic_multicast_locators[0]) {
                .udp_v4 => |u| u.port,
                .udp_v6 => |u| u.port,
                else => 7400,
            }
        else
            7400;

        // Build the StatelessWriter for the SPDP participant writer. Built up
        // fully through a local (`new_writer`) and only published to the
        // shared `self.writer` field (under `self.mu`) once it's ready to
        // receive traffic — `self.transport.listen()` below is the point
        // where another thread first gets a chance to read `self.writer`
        // (via `onReceive` -> `processSpdpPayload`), and that read is also
        // taken under `self.mu` (see there), so this publish establishes the
        // happens-before relationship TSan otherwise flags as a race.
        const writer_guid = Guid{
            .prefix = local.guid.prefix,
            .entity_id = EntityIds.spdp_builtin_participant_writer,
        };
        const new_writer = try StatelessWriter.init(
            self.alloc,
            writer_guid,
            self.transport,
            1, // keep_last 1: always the latest announcement
            EntityIds.spdp_builtin_participant_reader,
        );
        new_writer.setTracer(self.tracer);

        // Encode the participant announcement to PL-CDR.
        const payload = try encodeSpdpParticipant(self.alloc, local);
        self.local_payload = payload;

        // Store the announcement in the writer cache (SN = 1).
        _ = try new_writer.write(
            .alive,
            RtpsTimestamp.now(),
            history_mod.INSTANCE_HANDLE_NIL,
            std.mem.zeroes([16]u8),
            payload,
        );

        // Register all multicast locators as reader-locators on the SPDP writer.
        for (local.metatraffic_multicast_locators) |loc| {
            try new_writer.addReaderLocator(.{ .locator = loc });
        }

        // Register initial_peers as unicast reader-locators so SPDP announcements
        // are sent directly to each configured peer at startup.
        for (local.initial_peers) |peer_str| {
            if (parseLocatorStr(peer_str)) |loc| {
                new_writer.addReaderLocator(.{ .locator = loc }) catch {};
            } else {
                log.spdp.warn("spdp: ignoring unparseable initial_peer '{s}'", .{peer_str});
            }
        }

        self.mu.lock();
        self.writer = new_writer;
        self.mu.unlock();

        // Listen on SPDP multicast port and join the multicast group.
        const listen_locator = Locator.udp4(.{ 0, 0, 0, 0 }, self.spdp_multicast_port);
        // Non-fatal: writer still sends and unicast paths remain open if this fails.
        self.transport.listen(&listen_locator, ReceiveHandler{
            .ctx = self,
            .on_receive = onReceive,
        }) catch |err| log.spdp.warn("spdp: listen failed: {}", .{err});
        for (local.metatraffic_multicast_locators) |loc| {
            self.transport.joinMulticast(&loc) catch |err| {
                log.spdp.warn("spdp: joinMulticast failed: {}", .{err});
            };
        }

        // Send an immediate announcement before spawning the timer thread, so
        // there's no window where the timer's first cycle could race this send
        // and both end up transmitting the same SN.
        new_writer.sendAll();

        // Spawn the timer thread.
        self.shutdown.store(false, .release);
        self.timer_thread = try std.Thread.spawn(.{}, timerFn, .{self});
    }

    /// Re-announce with a fresh sequence number, then transmit. Called once per
    /// periodic announcement cycle (never per-interface — the transport layer
    /// fans a single logical send out to every joined interface using the same
    /// cached change/SN, so redundant per-interface copies stay deduplicable by
    /// receivers). Without this, every re-announcement for the life of the
    /// process would carry the same SN the participant was created with, which
    /// a peer's own SPDP dedup logic could (reasonably) mistake for redundant
    /// delivery of one announcement rather than a genuine new one.
    fn reannounce(self: *Self) void {
        self.mu.lock();
        const w_opt = self.writer;
        self.mu.unlock();
        const w = w_opt orelse return;
        const payload = self.local_payload orelse return;
        _ = w.write(
            .alive,
            RtpsTimestamp.now(),
            history_mod.INSTANCE_HANDLE_NIL,
            std.mem.zeroes([16]u8),
            payload,
        ) catch return;
        w.sendAll();
    }

    pub fn stop(self: *Self) void {
        self.shutdown.store(true, .release);
        if (self.timer_thread) |t| {
            t.join();
            self.timer_thread = null;
        }
        // Unlisten from transport.
        const listen_locator = Locator.udp4(.{ 0, 0, 0, 0 }, self.spdp_multicast_port);
        self.transport.unlisten(&listen_locator, ReceiveHandler{
            .ctx = self,
            .on_receive = onReceive,
        });
    }

    // ── Transport receive callback ────────────────────────────────────────────

    fn onReceive(ctx: *anyopaque, data: []const u8, from: Locator, channel: tr_iface.Channel) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = from;
        _ = channel;

        // Parse the RTPS message.
        var it = parser_mod.MessageIterator.init(data) catch return;
        var param_buf: [32]@import("../rtps/message/submessage.zig").InlineQosParam = undefined;

        while (it.next(&param_buf) catch return) |sm| {
            switch (sm) {
                .data => |d| {
                    if (!d.writer_entity_id.eql(EntityIds.spdp_builtin_participant_writer))
                        continue;
                    const src_prefix = it.header.guid_prefix;
                    // BYE detection: STATUS_INFO with DISPOSED (0x1) or UNREGISTERED (0x2).
                    // Per RTPS §9.4.5.11 the status bytes are always big-endian.
                    const is_bye = blk: {
                        if (d.inline_qos) |iq| {
                            if (iq.get(.status_info)) |si| {
                                if (si.len >= 4) break :blk std.mem.readInt(u32, si[0..4], .big) & 0x3 != 0;
                            }
                        }
                        break :blk false;
                    };
                    if (is_bye) {
                        // Participant is leaving — remove and notify.
                        self.mu.lock();
                        const kp_opt = self.known.fetchRemove(src_prefix);
                        self.mu.unlock();
                        if (kp_opt) |kp| {
                            var kp2 = kp;
                            if (self.callbacks) |cbs| cbs.on_participant_lost(cbs.ctx, kp2.value.data.guid);
                            kp2.value.deinit();
                        }
                        continue;
                    }
                    const payload = d.serialized_payload;
                    if (payload.len == 0) continue;
                    self.processSpdpPayload(src_prefix, d.writer_sn, payload, it.header.vendor_id);
                },
                else => {},
            }
        }
    }

    /// Relay entry point: called by SEDP when an SPDP DATA arrives on the
    /// metatraffic unicast port (Cyclone sends unicast responses there per RTPS §9.6.1.1).
    pub fn handleRelayedData(
        ctx: *anyopaque,
        prefix: GuidPrefix,
        writer_sn: SequenceNumber,
        payload: []const u8,
        vendor_id: header_mod.VendorId,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.processSpdpPayload(prefix, writer_sn, payload, vendor_id);
    }

    /// Called when a peer participant's SPDP BYE (dispose/unregister) is received.
    /// Removes the participant from the known map and fires on_participant_lost.
    pub fn removePeer(ctx: *anyopaque, prefix: GuidPrefix) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        const kp_opt = self.known.fetchRemove(prefix);
        self.mu.unlock();
        if (kp_opt) |kp| {
            var kp2 = kp;
            if (self.callbacks) |cbs| cbs.on_participant_lost(cbs.ctx, kp2.value.data.guid);
            kp2.value.deinit();
        }
    }

    pub fn processSpdpPayload(
        self: *Self,
        guid_prefix: GuidPrefix,
        writer_sn: SequenceNumber,
        payload: []const u8,
        vendor_id: header_mod.VendorId,
    ) void {
        // Ignore our own announcements.
        self.mu.lock();
        const own_writer_guid_prefix = if (self.writer) |w| w.guid.prefix else null;
        self.mu.unlock();
        if (own_writer_guid_prefix) |p| {
            if (p.eql(guid_prefix)) return;
        }

        log.spdp.debug("spdp: received from {x}", .{guid_prefix.bytes});

        var kp = decodeSpdpParticipant(self.alloc, guid_prefix, self.domain_id, payload, vendor_id) catch |err| {
            log.spdp.warn("spdp: decode error: {}", .{err});
            return;
        };
        self.filterKnownParticipantLocators(&kp);
        const now_ns = self.clock.nowNs();
        kp.expires_ns = now_ns + @as(i64, @intCast(kp.data.lease_duration_ms)) * std.time.ns_per_ms;
        kp.last_seen_ns = now_ns;
        kp.observed_interval_ns = 0; // updated below for re-announcements
        kp.probe_active = false; // receiving an announcement resolves any probe
        kp.last_writer_sn = writer_sn;

        // was_probing: true when a re-announcement arrives while a liveness probe is
        // in flight for this participant.  We must cancel the SEDP probe deadline
        // after releasing spdp.mu so that checkProbeDeadlines does not evict the
        // SEDP reader proxy for a participant that is demonstrably alive.
        // (Calling begin_probe_fn acquires writer.mu; spdp.mu must not be held.)
        //
        // Implementation note: discovery callbacks (on_participant_discovered, SEDP
        // wiring, addReaderLocator) must run INSIDE the block-scoped lock using
        // &kp.data (the stack-local copy).  They must NOT be called after the lock
        // is released with a pointer into gop.value_ptr, because a concurrent
        // hashmap mutation (re-announcement or eviction) could rehash and free the
        // pointed-to memory, causing use-after-free / "switch on corrupt value" panics.
        var was_probing = false;
        // SEDP-traffic-seen heuristic: if a peer keeps re-announcing itself over
        // SPDP but we've never received real SEDP endpoint traffic from it, our
        // own SPDP announcement may never have reached it (or was lost). Retransmit
        // it directly to the peer's unicast locators on every such re-announcement,
        // rather than waiting for the next periodic/fast-announce cycle. Populated
        // under the lock below; sent after releasing it (same discipline as
        // was_probing/begin_probe_fn — no network I/O while holding self.mu).
        var retransmit_locators: []Locator = &.{};
        {
            self.mu.lock();
            defer self.mu.unlock();

            const gop = self.known.getOrPut(guid_prefix) catch return;
            const is_new = !gop.found_existing;
            if (gop.found_existing) {
                // Update the smoothed announcement interval from the previous observation.
                const prev_last_seen = gop.value_ptr.last_seen_ns;
                const prev_interval = gop.value_ptr.observed_interval_ns;
                const same_sn = writer_sn != sn_mod.SEQUENCENUMBER_UNKNOWN and
                    writer_sn == gop.value_ptr.last_writer_sn;
                // True only for a genuinely new, plausibly-spaced re-announcement —
                // never for same-SN or implausibly-fast duplicate redelivery (see the
                // last_writer_sn field doc and MIN_PLAUSIBLE_INTERVAL_NS above). Gates
                // the SEDP-traffic-seen retransmit below so a multi-homed peer's
                // redundant per-interface copies of one announcement don't each
                // trigger their own unicast retransmit.
                var is_genuine_reannounce = false;
                if (same_sn) {
                    // Redelivery of the same SPDP sample (e.g. a multi-homed peer sending
                    // redundantly across several local interfaces within microseconds of
                    // each other). Not a genuine re-announcement — leave the EMA untouched,
                    // and keep last_seen_ns anchored to the original arrival rather than
                    // this duplicate's, so a slow secondary-path copy can't shift the
                    // baseline the next genuine re-announcement's interval is measured from.
                    kp.observed_interval_ns = prev_interval;
                    kp.last_seen_ns = prev_last_seen;
                } else if (prev_last_seen > 0 and now_ns > prev_last_seen) {
                    const interval = now_ns - prev_last_seen;
                    if (interval < MIN_PLAUSIBLE_INTERVAL_NS) {
                        // Backstop for peers that bump the SN on each redundant copy instead
                        // of reusing it: implausibly short for a real SPDP period, so treat
                        // it the same as a same-SN duplicate rather than let it poison the EMA
                        // — including keeping last_seen_ns anchored to the original arrival.
                        kp.observed_interval_ns = prev_interval;
                        kp.last_seen_ns = prev_last_seen;
                    } else {
                        kp.observed_interval_ns = if (prev_interval == 0)
                            interval
                        else
                            @divTrunc(prev_interval + interval, 2); // EMA α=0.5
                        is_genuine_reannounce = true;
                    }
                } else {
                    kp.observed_interval_ns = prev_interval;
                }
                // Capture whether a probe was active before we overwrite the entry.
                was_probing = gop.value_ptr.probe_active;
                // Carry sedp_seen forward — a fresh decode always starts false.
                kp.sedp_seen = gop.value_ptr.sedp_seen;
                if (is_genuine_reannounce and !kp.sedp_seen) {
                    retransmit_locators = self.alloc.dupe(
                        Locator,
                        kp.data.metatraffic_unicast_locators,
                    ) catch &.{};
                }
                gop.value_ptr.deinit();
            }
            gop.value_ptr.* = kp;

            // Fire callbacks and unicast reply only for genuinely new participants.
            // Re-announcements from known participants refresh expires_ns and locator
            // data silently; no DCPS notification or SEDP proxy establishment is needed.
            // Use &kp.data (stack-local) not &gop.value_ptr.data (heap) so the pointer
            // stays valid even if the hashmap rehashes inside a nested callback.
            if (is_new) {
                if (self.callbacks) |cbs| {
                    cbs.on_participant_discovered(cbs.ctx, &kp.data);
                }
                if (self.on_participant_discovered_sedp) |cb| {
                    cb(self.sedp_ctx.?, &kp.data);
                }
                // Register unicast locators for this peer so future sendAll() calls reach
                // it directly, then trigger fast-announce mode instead of calling sendAll()
                // here. An immediate sendAll() per discovery event causes an N² burst when
                // N participants start simultaneously; fast-announce fires once per half-period
                // and reaches everyone via the accumulated locator list.
                if (self.writer) |w| {
                    for (kp.data.metatraffic_unicast_locators) |loc| {
                        w.addReaderLocator(.{ .locator = loc }) catch {};
                    }
                }
                const until_ns = self.clock.nowNs() + 2 * @as(i64, self.announcement_period_ms) * std.time.ns_per_ms;
                self.fast_announce_until_ns.store(until_ns, .release);
            }
        } // spdp.mu released here by defer

        // Cancel the SEDP probe deadline now that the participant has re-announced.
        // Must happen outside spdp.mu because begin_probe_fn acquires writer.mu
        // (lock order: spdp.mu → writer.mu, never nested).
        if (was_probing) {
            if (self.begin_probe_fn) |f| f(self.begin_probe_ctx.?, guid_prefix, 0);
        }
        if (retransmit_locators.len > 0) {
            defer self.alloc.free(retransmit_locators);
            self.mu.lock();
            const w_opt = self.writer;
            self.mu.unlock();
            if (w_opt) |w| {
                for (retransmit_locators) |loc| w.sendToLocator(loc);
            }
        }
    }

    fn filterKnownParticipantLocators(self: *Self, kp: *KnownParticipant) void {
        const old_meta_uc = kp.data.metatraffic_unicast_locators;
        kp.data.metatraffic_unicast_locators = self.filterReachableLocators(old_meta_uc, "metatraffic unicast");
        self.alloc.free(old_meta_uc);

        const old_meta_mc = kp.data.metatraffic_multicast_locators;
        kp.data.metatraffic_multicast_locators = self.filterReachableLocators(old_meta_mc, "metatraffic multicast");
        self.alloc.free(old_meta_mc);

        // Capture the raw (not yet discovery-filtered) default locators before
        // either filter pass runs. The data-transport pass needs to see locator
        // kinds discovery itself can't reach (e.g. TCP) — the discovery filter
        // below would otherwise strip them irrecoverably before this pass ever
        // saw them.
        const old_data_uc = kp.data.default_unicast_locators;
        const old_data_mc = kp.data.default_multicast_locators;
        // This function runs on every SPDP re-announcement from an
        // already-known peer, not just the first — these two fields already
        // hold a real heap allocation from the previous call (or the
        // struct's `&.{}` default on the very first call, for which
        // Allocator.free is a guaranteed no-op regardless). Capture before
        // overwriting so both branches below free the prior allocation
        // instead of leaking it on every re-announcement.
        const old_data_uc_for_data = kp.data.default_unicast_locators_for_data;
        const old_data_mc_for_data = kp.data.default_multicast_locators_for_data;

        if (self.data_reachable) |dr| {
            kp.data.default_unicast_locators_for_data = iface.filterReachableLocatorsForData(self.alloc, old_data_uc, dr);
            kp.data.default_multicast_locators_for_data = iface.filterReachableLocatorsForData(self.alloc, old_data_mc, dr);
        }

        kp.data.default_unicast_locators = self.filterReachableLocators(old_data_uc, "default unicast");
        kp.data.default_multicast_locators = self.filterReachableLocators(old_data_mc, "default multicast");

        if (self.data_reachable == null) {
            // No separate data transport configured: the data transport IS the
            // discovery transport, so the discovery-filtered result just
            // computed above is already correct for data purposes too.
            kp.data.default_unicast_locators_for_data = self.alloc.dupe(Locator, kp.data.default_unicast_locators) catch &.{};
            kp.data.default_multicast_locators_for_data = self.alloc.dupe(Locator, kp.data.default_multicast_locators) catch &.{};
        }

        self.alloc.free(old_data_uc);
        self.alloc.free(old_data_mc);
        self.alloc.free(old_data_uc_for_data);
        self.alloc.free(old_data_mc_for_data);
    }

    fn filterReachableLocators(self: *Self, locators: []const Locator, context: []const u8) []Locator {
        return iface.filterReachableLocators(self.alloc, locators, self.transport, context, self);
    }

    pub fn warnUnsupportedLocatorOnce(self: *Self, loc: Locator, context: []const u8) void {
        const kind = loc.wireKind();
        self.unsupported_locator_mu.lock();
        defer self.unsupported_locator_mu.unlock();
        const gop = self.unsupported_locator_kinds.getOrPut(kind) catch return;
        if (!gop.found_existing) {
            log.spdp.warn("spdp: ignoring unsupported {s} locator kind={d}/0x{x}", .{
                context,
                kind,
                @as(u32, @bitCast(kind)),
            });
        }
    }

    // ── Timer thread ──────────────────────────────────────────────────────────

    fn timerFn(self: *Self) void {
        var last_announce_ns = self.clock.nowNs();

        while (!self.shutdown.load(.acquire)) {
            self.clock.sleepNs(100 * std.time.ns_per_ms);
            if (self.shutdown.load(.acquire)) break;

            const now_ns = self.clock.nowNs();
            const in_fast = now_ns < self.fast_announce_until_ns.load(.acquire);
            const period_ns: i64 = if (in_fast)
                @divTrunc(@as(i64, self.announcement_period_ms), 2) * std.time.ns_per_ms
            else
                @as(i64, self.announcement_period_ms) * std.time.ns_per_ms;

            if (now_ns - last_announce_ns >= period_ns) {
                last_announce_ns = now_ns;
                self.reannounce();
            }

            self.checkLeases();
        }
    }

    pub fn checkLeases(self: *Self) void {
        const now_ns = self.clock.nowNs();
        // Probe trigger: start a liveness probe when silence exceeds this threshold.
        // Use min(3× observed interval, 5 s) so we respond quickly for peers that
        // announce frequently (e.g. every 100 ms → threshold 300 ms) while still
        // catching peers whose interval is unknown or very long (cap at 5 s).
        const max_probe_trigger_ns: i64 = 5_000_000_000; // 5 seconds

        const ProbeEntry = struct { prefix: GuidPrefix, deadline_ns: i64 };
        var to_remove: std.ArrayListUnmanaged(GuidPrefix) = .empty;
        defer to_remove.deinit(self.alloc);
        var to_probe: std.ArrayListUnmanaged(ProbeEntry) = .empty;
        defer to_probe.deinit(self.alloc);
        var evict_guids: std.ArrayListUnmanaged(Guid) = .empty;
        defer evict_guids.deinit(self.alloc);

        self.mu.lock();

        var it = self.known.iterator();
        while (it.next()) |entry| {
            const kp = entry.value_ptr;
            if (now_ns >= kp.expires_ns) {
                to_remove.append(self.alloc, entry.key_ptr.*) catch {};
            } else if (!kp.probe_active and kp.last_seen_ns > 0) {
                const silence = now_ns - kp.last_seen_ns;
                const trigger = if (kp.observed_interval_ns > 0)
                    @min(3 * kp.observed_interval_ns, max_probe_trigger_ns)
                else
                    max_probe_trigger_ns;
                if (silence >= trigger) {
                    kp.probe_active = true;
                    to_probe.append(self.alloc, .{
                        .prefix = entry.key_ptr.*,
                        .deadline_ns = now_ns + 1_000_000_000,
                    }) catch {
                        kp.probe_active = false; // undo on OOM so we retry next cycle
                    };
                }
            }
        }

        for (to_remove.items) |prefix| {
            if (self.known.fetchRemove(prefix)) |kp| {
                var kp2 = kp;
                evict_guids.append(self.alloc, kp2.value.data.guid) catch {};
                kp2.value.deinit();
            }
        }

        self.mu.unlock();

        // Fire eviction callbacks outside the lock to avoid spdp.mu → participant.mu
        // → writer.mu → spdp.mu inversion with the probe result path.
        for (evict_guids.items) |guid| {
            if (self.callbacks) |cbs| cbs.on_participant_lost(cbs.ctx, guid);
        }

        // Start probes outside the lock: beginProbe acquires SEDP writer locks,
        // and the probe result callback acquires spdp.mu — holding it here would
        // create a potential cycle.
        for (to_probe.items) |pe| {
            if (self.begin_probe_fn) |f| f(self.begin_probe_ctx.?, pe.prefix, pe.deadline_ns);
        }
    }

    // ── Discovery vtable ──────────────────────────────────────────────────────

    const vtable = Discovery.Vtable{
        .start = vtStart,
        .stop = vtStop,
        .announce_writer = vtAnnounceWriter,
        .retract_writer = vtRetractWriter,
        .announce_reader = vtAnnounceReader,
        .retract_reader = vtRetractReader,
        .deinit = vtDeinit,
        // Standalone SpdpEndpoints has no SEDP/WLP siblings (used directly
        // only by narrow tests) -- production wiring goes through
        // combined.zig's SpdpSedpDiscovery instead.
        .wlp_tick = noopWlpTick,
    };

    fn noopWlpTick(_: *anyopaque, _: i64, _: iface.WlpTickInfo) void {}

    pub fn toDiscovery(self: *Self) Discovery {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn vtStart(ctx: *anyopaque, local: *const ParticipantAnnouncement, cbs: *const Callbacks) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.start(local, cbs);
    }
    fn vtStop(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.stop();
    }
    fn vtAnnounceWriter(_: *anyopaque, _: *const iface.WriterAnnouncement) anyerror!void {}
    fn vtRetractWriter(_: *anyopaque, _: Guid) void {}
    fn vtAnnounceReader(_: *anyopaque, _: *const iface.ReaderAnnouncement) anyerror!void {}
    fn vtRetractReader(_: *anyopaque, _: Guid) void {}
    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

// ── PL-CDR serialization ──────────────────────────────────────────────────────
//
// Goes through the zidl-generated `Disc.SPDPdiscoveredParticipantData` codec
// (`idl/rtps_discovery.idl`, `--zig-pl-cdr`, `@pl_retain_unknown`) instead of a
// hand-rolled parser — see docs/design/discovery-codec.md. `participantGuid`
// and `leaseDuration` are `@optional` in the IDL purely for the decode side
// (a peer may omit them); zzdds's own encoder always fills both.

/// Encode SPDPdiscoveredParticipantData as PL-CDR little-endian.
/// Returns a heap-allocated slice owned by the caller.
pub fn encodeSpdpParticipant(alloc: std.mem.Allocator, ann: *const ParticipantAnnouncement) ![]u8 {
    const lease = time_mod.RtpsDuration.fromDuration(.{
        .sec = @intCast(ann.lease_duration_ms / 1000),
        .nanosec = (ann.lease_duration_ms % 1000) * 1_000_000,
    });

    var out: Disc.SPDPdiscoveredParticipantData = .{
        .protocolVersion = .{ .major = 2, .minor = 5 },
        .vendorId = .{ .vendorId = pid_mod.ZZDDS_VENDOR_ID },
        // RTPS §9.3.1.5: a participant's GUID entity_id is always the
        // well-known "participant" value — not whatever `ann.guid.entity_id`
        // holds (defensively ignored, same as the previous hand encoder).
        .participantGuid = wire_codec.guidBytes(.{ .prefix = ann.guid.prefix, .entity_id = EntityIds.participant }),
        .builtinEndpointSet = ann.builtin_endpoint_set,
        .leaseDuration = .{ .seconds = lease.seconds, .fraction = lease.fraction },
    };
    if (ann.name.len > 0) out.participantName = ann.name;

    const meta_uc = try wire_codec.ownedDiscLocatorSeq(alloc, ann.metatraffic_unicast_locators);
    defer alloc.free(meta_uc);
    const meta_mc = try wire_codec.ownedDiscLocatorSeq(alloc, ann.metatraffic_multicast_locators);
    defer alloc.free(meta_mc);
    const def_uc = try wire_codec.ownedDiscLocatorSeq(alloc, ann.default_unicast_locators);
    defer alloc.free(def_uc);
    const def_mc = try wire_codec.ownedDiscLocatorSeq(alloc, ann.default_multicast_locators);
    defer alloc.free(def_mc);

    out.metatrafficUnicastLocatorList = wire_codec.discLocatorSeqField(
        @FieldType(Disc.SPDPdiscoveredParticipantData, "metatrafficUnicastLocatorList"),
        meta_uc,
    );
    out.metatrafficMulticastLocatorList = wire_codec.discLocatorSeqField(
        @FieldType(Disc.SPDPdiscoveredParticipantData, "metatrafficMulticastLocatorList"),
        meta_mc,
    );
    out.defaultUnicastLocatorList = wire_codec.discLocatorSeqField(
        @FieldType(Disc.SPDPdiscoveredParticipantData, "defaultUnicastLocatorList"),
        def_uc,
    );
    out.defaultMulticastLocatorList = wire_codec.discLocatorSeqField(
        @FieldType(Disc.SPDPdiscoveredParticipantData, "defaultMulticastLocatorList"),
        def_mc,
    );

    return wire_codec.emitPlCdr(Disc.SPDPdiscoveredParticipantData, alloc, out);
}

// ── PL-CDR deserialization ────────────────────────────────────────────────────

/// Decode SPDPdiscoveredParticipantData from a PL-CDR payload (including
/// 4-byte encap header). `.lenient` matches the old hand parser's tolerance
/// for a truncated tail or a missing sentinel. All slices in the returned
/// KnownParticipant are heap-allocated; caller owns them.
pub fn decodeSpdpParticipant(
    alloc: std.mem.Allocator,
    guid_prefix: GuidPrefix,
    domain_id: u32,
    payload: []const u8,
    vendor_id: header_mod.VendorId,
) !KnownParticipant {
    if (payload.len < 4) return error.TooShort;
    var r = try zidl_rt.CdrReader.init(payload);
    var data: Disc.SPDPdiscoveredParticipantData = .{};
    defer data.deinit(alloc);
    try Disc.SPDPdiscoveredParticipantData.deserializeFromPlCdr(&data, &r, alloc, .lenient);

    const decoded_prefix = if (data.participantGuid) |g|
        wire_codec.guidFromBytes(&g).prefix
    else
        guid_prefix;

    const lease_ms: u32 = if (data.leaseDuration) |ld| blk: {
        const lease = (time_mod.RtpsDuration{ .seconds = ld.seconds, .fraction = ld.fraction }).toDuration();
        if (lease.isInfinite()) break :blk std.math.maxInt(u32);
        const ns = lease.toNs() orelse break :blk std.math.maxInt(u32);
        if (ns <= 0) break :blk 0;
        break :blk @intCast(@min(@as(i64, std.math.maxInt(u32)), @divTrunc(ns, std.time.ns_per_ms)));
    } else 10_000;

    const name: []u8 = if (data.participantName) |n| try alloc.dupe(u8, n) else &.{};
    errdefer alloc.free(name);

    const meta_uc = try wire_codec.wireLocatorsOwned(alloc, data.metatrafficUnicastLocatorList);
    errdefer alloc.free(meta_uc);
    const meta_mc = try wire_codec.wireLocatorsOwned(alloc, data.metatrafficMulticastLocatorList);
    errdefer alloc.free(meta_mc);
    const data_uc = try wire_codec.wireLocatorsOwned(alloc, data.defaultUnicastLocatorList);
    errdefer alloc.free(data_uc);
    const data_mc = try wire_codec.wireLocatorsOwned(alloc, data.defaultMulticastLocatorList);
    errdefer alloc.free(data_mc);

    log.spdp.debug("spdp: decoded data_uc={d} data_mc={d}", .{ data_uc.len, data_mc.len });
    for (data_uc) |loc| log.spdp.debug("spdp:   data_unicast_locator={any}", .{loc});

    return KnownParticipant{
        .alloc = alloc,
        .expires_ns = 0, // caller sets this
        .last_seen_ns = 0, // caller sets this
        .observed_interval_ns = 0,
        .probe_active = false,
        .last_writer_sn = sn_mod.SEQUENCENUMBER_UNKNOWN, // caller sets this
        .sedp_seen = false, // caller carries forward on re-announcement
        .data = ParticipantData{
            .guid = .{
                .prefix = decoded_prefix,
                .entity_id = EntityIds.participant,
            },
            .domain_id = domain_id,
            .name = name,
            .metatraffic_unicast_locators = meta_uc,
            .metatraffic_multicast_locators = meta_mc,
            .default_unicast_locators = data_uc,
            .default_multicast_locators = data_mc,
            .lease_duration_ms = lease_ms,
            .builtin_endpoint_set = data.builtinEndpointSet,
            .vendor_id = vendor_id,
        },
    };
}

/// Parse "a.b.c.d:port" into a UDP4 Locator. Returns null on any parse failure.
fn parseLocatorStr(s: []const u8) ?Locator {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return null;
    var addr: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s[0..colon], '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        addr[i] = std.fmt.parseInt(u8, part, 10) catch return null;
        i += 1;
    }
    if (i != 4) return null;
    return Locator.udp4(addr, port);
}
