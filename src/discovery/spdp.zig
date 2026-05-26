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
//!   4. Spawn a timer thread that periodically calls sendAll() and checks leases.
//!
//! PL-CDR encoding is hand-written (no dependency on zidl-generated code here).

const std = @import("std");
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const iface = @import("interface.zig");
const tr_iface = @import("../transport/interface.zig");
const guid_mod = @import("../rtps/guid.zig");
const pid_mod = @import("../rtps/pid.zig");
const writer_sm_mod = @import("../rtps/writer_sm.zig");
const reader_sm_mod = @import("../rtps/reader_sm.zig");
const parser_mod = @import("../rtps/message/parser.zig");
const history_mod = @import("../rtps/history.zig");
const mutex_mod = @import("../util/mutex.zig");
const time_mod = @import("../util/time.zig");

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
const Callbacks = iface.Callbacks;
const ParticipantAnnouncement = iface.ParticipantAnnouncement;
const ParticipantData = iface.ParticipantData;
const Discovery = iface.Discovery;
const PidTable = pid_mod.PidTable;
const BuiltinEndpointSet = pid_mod.BuiltinEndpointSet;

// PL_CDR_LE encapsulation identifier (RTPS §10.2, PL_CDR little-endian)
const PLCDR_LE_ENCAP: [4]u8 = .{ 0x00, 0x03, 0x00, 0x00 };

// ── State for one known remote participant ────────────────────────────────────

pub const KnownParticipant = struct {
    data: ParticipantData,
    /// Monotonic expiry timestamp in ns (from timer_clock.nowNs()).
    expires_ns: i64,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *KnownParticipant) void {
        self.alloc.free(self.data.name);
        self.alloc.free(self.data.metatraffic_unicast_locators);
        self.alloc.free(self.data.metatraffic_multicast_locators);
        self.alloc.free(self.data.default_unicast_locators);
        self.alloc.free(self.data.default_multicast_locators);
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
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.writer) |w| w.deinit();
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

    pub fn start(
        self: *Self,
        local: *const ParticipantAnnouncement,
        callbacks: *const Callbacks,
    ) !void {
        self.callbacks = callbacks;

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

        // Build the StatelessWriter for the SPDP participant writer.
        const writer_guid = Guid{
            .prefix = local.guid.prefix,
            .entity_id = EntityIds.spdp_builtin_participant_writer,
        };
        self.writer = try StatelessWriter.init(
            self.alloc,
            writer_guid,
            self.transport,
            1, // keep_last 1: always the latest announcement
            EntityIds.spdp_builtin_participant_reader,
        );
        self.writer.?.setTracer(self.tracer);

        // Encode the participant announcement to PL-CDR.
        const payload = try encodeSpdpParticipant(self.alloc, local);
        self.local_payload = payload;

        // Store the announcement in the writer cache (SN = 1).
        _ = try self.writer.?.write(
            .alive,
            RtpsTimestamp.now(),
            history_mod.INSTANCE_HANDLE_NIL,
            std.mem.zeroes([16]u8),
            payload,
        );

        // Register all multicast locators as reader-locators on the SPDP writer.
        for (local.metatraffic_multicast_locators) |loc| {
            try self.writer.?.addReaderLocator(.{ .locator = loc });
        }

        // Also register any initial_peers from config (not yet plumbed; skip for now).

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

        // Spawn the timer thread.
        self.shutdown.store(false, .release);
        self.timer_thread = try std.Thread.spawn(.{}, timerFn, .{self});

        // Send an immediate announcement.
        self.writer.?.sendAll();
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

    fn onReceive(ctx: *anyopaque, data: []const u8, from: Locator) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = from;

        // Parse the RTPS message.
        var it = parser_mod.MessageIterator.init(data) catch return;
        var param_buf: [32]@import("../rtps/message/submessage.zig").InlineQosParam = undefined;

        while (it.next(&param_buf) catch return) |sm| {
            switch (sm) {
                .data => |d| {
                    if (!d.writer_entity_id.eql(EntityIds.spdp_builtin_participant_writer))
                        continue;
                    const payload = d.serialized_payload;
                    if (payload.len == 0) continue;
                    self.processSpdpPayload(it.header.guid_prefix, payload);
                },
                else => {},
            }
        }
    }

    /// Relay entry point: called by SEDP when an SPDP DATA arrives on the
    /// metatraffic unicast port (Cyclone sends unicast responses there per RTPS §9.6.1.1).
    pub fn handleRelayedData(ctx: *anyopaque, prefix: GuidPrefix, payload: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.processSpdpPayload(prefix, payload);
    }

    pub fn processSpdpPayload(
        self: *Self,
        guid_prefix: GuidPrefix,
        payload: []const u8,
    ) void {
        // Ignore our own announcements.
        if (self.writer) |w| {
            if (w.guid.prefix.eql(guid_prefix)) return;
        }

        log.spdp.debug("spdp: received from {x}", .{guid_prefix.bytes});

        var kp = decodeSpdpParticipant(self.alloc, guid_prefix, self.domain_id, payload) catch |err| {
            log.spdp.warn("spdp: decode error: {}", .{err});
            return;
        };
        self.filterKnownParticipantLocators(&kp);
        kp.expires_ns = self.clock.nowNs() +
            @as(i64, @intCast(kp.data.lease_duration_ms)) * std.time.ns_per_ms;

        self.mu.lock();
        defer self.mu.unlock();

        const gop = self.known.getOrPut(guid_prefix) catch return;
        const is_new = !gop.found_existing;
        if (gop.found_existing) {
            // Update expiry; replace data only when locators changed (full replace is simpler).
            gop.value_ptr.deinit();
        }
        gop.value_ptr.* = kp;

        // Fire callbacks and unicast reply only for genuinely new participants.
        // Re-announcements from known participants refresh expires_ns and locator
        // data silently; no DCPS notification or SEDP proxy establishment is needed.
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
    }

    fn filterKnownParticipantLocators(self: *Self, kp: *KnownParticipant) void {
        const old_meta_uc = kp.data.metatraffic_unicast_locators;
        kp.data.metatraffic_unicast_locators = self.filterReachableLocators(old_meta_uc, "metatraffic unicast");
        self.alloc.free(old_meta_uc);

        const old_meta_mc = kp.data.metatraffic_multicast_locators;
        kp.data.metatraffic_multicast_locators = self.filterReachableLocators(old_meta_mc, "metatraffic multicast");
        self.alloc.free(old_meta_mc);

        const old_data_uc = kp.data.default_unicast_locators;
        kp.data.default_unicast_locators = self.filterReachableLocators(old_data_uc, "default unicast");
        self.alloc.free(old_data_uc);

        const old_data_mc = kp.data.default_multicast_locators;
        kp.data.default_multicast_locators = self.filterReachableLocators(old_data_mc, "default multicast");
        self.alloc.free(old_data_mc);
    }

    fn filterReachableLocators(self: *Self, locators: []const Locator, context: []const u8) []Locator {
        var out: std.ArrayList(Locator) = .empty;
        for (locators) |loc| {
            if (loc.isInvalidOrReserved()) continue;
            if (self.transport.canReach(&loc)) {
                out.append(self.alloc, loc) catch {
                    out.deinit(self.alloc);
                    return &.{};
                };
                continue;
            }
            // Unknown custom locators are opaque extension/vendor locators.
            // If no configured transport claims them, ignore them without
            // promoting them into participant or endpoint locator lists.
            if (loc.isOpaqueCustom()) continue;
            self.warnUnsupportedLocatorOnce(loc, context);
        }
        return out.toOwnedSlice(self.alloc) catch {
            out.deinit(self.alloc);
            return &.{};
        };
    }

    fn warnUnsupportedLocatorOnce(self: *Self, loc: Locator, context: []const u8) void {
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
                if (self.writer) |w| w.sendAll();
            }

            self.checkLeases();
        }
    }

    pub fn checkLeases(self: *Self) void {
        const now_ns = self.clock.nowNs();
        self.mu.lock();
        defer self.mu.unlock();

        var to_remove: [64]GuidPrefix = undefined;
        var to_remove_count: usize = 0;
        var it = self.known.iterator();
        while (it.next()) |entry| {
            if (now_ns >= entry.value_ptr.expires_ns and to_remove_count < 64) {
                to_remove[to_remove_count] = entry.key_ptr.*;
                to_remove_count += 1;
            }
        }
        for (to_remove[0..to_remove_count]) |prefix| {
            var kp = self.known.fetchRemove(prefix) orelse continue;
            if (self.callbacks) |cbs| {
                cbs.on_participant_lost(cbs.ctx, kp.value.data.guid);
            }
            kp.value.deinit();
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
    };

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

/// Encode SPDPdiscoveredParticipantData as PL-CDR little-endian.
/// Returns a heap-allocated slice owned by the caller.
fn encodeSpdpParticipant(alloc: std.mem.Allocator, ann: *const ParticipantAnnouncement) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    // Encapsulation header
    try buf.appendSlice(alloc, &PLCDR_LE_ENCAP);

    // PID_PROTOCOL_VERSION (0x0015): major=2, minor=5 + 2 pad bytes → len=4
    try writePidHdr(alloc, &buf, PidTable.PROTOCOL_VERSION, 4);
    try buf.appendSlice(alloc, &[_]u8{ 2, 5, 0, 0 });

    // PID_VENDORID (0x0016): 2 bytes + 2 pad → len=4
    try writePidHdr(alloc, &buf, PidTable.VENDORID, 4);
    try buf.appendSlice(alloc, &pid_mod.ZZDDS_VENDOR_ID);
    try buf.appendSlice(alloc, &[_]u8{ 0, 0 });

    // PID_PARTICIPANT_GUID (0x0050): 16 bytes (prefix[12] + entity_id[4])
    try writePidHdr(alloc, &buf, PidTable.PARTICIPANT_GUID, 16);
    try buf.appendSlice(alloc, &ann.guid.prefix.bytes);
    try buf.appendSlice(alloc, &[_]u8{
        EntityIds.participant.entity_key[0],
        EntityIds.participant.entity_key[1],
        EntityIds.participant.entity_key[2],
        EntityIds.participant.entity_kind,
    });

    // PID_BUILTIN_ENDPOINT_SET (0x0058): u32
    try writePidHdr(alloc, &buf, PidTable.BUILTIN_ENDPOINT_SET, 4);
    try writeU32Le(alloc, &buf, ann.builtin_endpoint_set);

    // PID_PARTICIPANT_LEASE_DURATION (0x0002): RTPS Duration_t (seconds + fraction) = 8 bytes
    try writePidHdr(alloc, &buf, PidTable.PARTICIPANT_LEASE_DURATION, 8);
    const lease = time_mod.Duration{
        .sec = @intCast(ann.lease_duration_ms / 1000),
        .nanosec = (ann.lease_duration_ms % 1000) * 1_000_000,
    };
    try writeRtpsDuration(alloc, &buf, lease);

    // Metatraffic unicast locators (one PID entry per locator)
    for (ann.metatraffic_unicast_locators) |loc| {
        try writePidHdr(alloc, &buf, PidTable.METATRAFFIC_UNICAST_LOCATOR, 24);
        try writeLocator(alloc, &buf, loc);
    }

    // Metatraffic multicast locators
    for (ann.metatraffic_multicast_locators) |loc| {
        try writePidHdr(alloc, &buf, PidTable.METATRAFFIC_MULTICAST_LOCATOR, 24);
        try writeLocator(alloc, &buf, loc);
    }

    // Default unicast locators
    for (ann.default_unicast_locators) |loc| {
        try writePidHdr(alloc, &buf, PidTable.DEFAULT_UNICAST_LOCATOR, 24);
        try writeLocator(alloc, &buf, loc);
    }

    // Default multicast locators
    for (ann.default_multicast_locators) |loc| {
        try writePidHdr(alloc, &buf, PidTable.DEFAULT_MULTICAST_LOCATOR, 24);
        try writeLocator(alloc, &buf, loc);
    }

    // PID_ENTITY_NAME (participant name) if non-empty
    if (ann.name.len > 0) {
        const str_len: u32 = @intCast(ann.name.len + 1); // including null
        const total = 4 + str_len; // length field + content
        const padded: u16 = @intCast((total + 3) & ~@as(u32, 3));
        try writePidHdr(alloc, &buf, PidTable.ENTITY_NAME, padded);
        try writeU32Le(alloc, &buf, str_len);
        try buf.appendSlice(alloc, ann.name);
        try buf.append(alloc, 0); // null terminator
        var p: usize = padded - total;
        while (p > 0) : (p -= 1) try buf.append(alloc, 0);
    }

    // PID_SENTINEL
    try buf.appendSlice(alloc, &[_]u8{ 0x01, 0x00, 0x00, 0x00 });

    return buf.toOwnedSlice(alloc);
}

// ── PL-CDR deserialization ────────────────────────────────────────────────────

/// Decode SPDPdiscoveredParticipantData from a PL-CDR payload (including 4-byte encap header).
/// All slices in the returned KnownParticipant are heap-allocated; caller owns them.
pub fn decodeSpdpParticipant(
    alloc: std.mem.Allocator,
    guid_prefix: GuidPrefix,
    domain_id: u32,
    payload: []const u8,
) !KnownParticipant {
    if (payload.len < 4) return error.TooShort;
    const le = (payload[1] & 0x01) != 0;

    var meta_uc: std.ArrayList(Locator) = .empty;
    var meta_mc: std.ArrayList(Locator) = .empty;
    var data_uc: std.ArrayList(Locator) = .empty;
    var data_mc: std.ArrayList(Locator) = .empty;
    errdefer {
        meta_uc.deinit(alloc);
        meta_mc.deinit(alloc);
        data_uc.deinit(alloc);
        data_mc.deinit(alloc);
    }

    var lease_ms: u32 = 10_000;
    var builtin_eps: u32 = 0;
    var name: []u8 = &.{};
    var decoded_prefix = guid_prefix; // override if PID_PARTICIPANT_GUID present

    var pos: usize = 4;
    while (pos + 4 <= payload.len) {
        const pid = readU16LE(payload[pos..], le);
        const len = readU16LE(payload[pos + 2 ..], le);
        pos += 4;
        if (pid == PidTable.SENTINEL) break;
        if (pos + len > payload.len) break;
        const v = payload[pos .. pos + len];
        pos += len;

        switch (pid) {
            PidTable.PARTICIPANT_GUID => {
                if (v.len >= 12) @memcpy(&decoded_prefix.bytes, v[0..12]);
            },
            PidTable.PARTICIPANT_LEASE_DURATION => {
                if (v.len >= 8) {
                    const lease = readRtpsDuration(v, le).toDuration();
                    lease_ms = if (lease.isInfinite()) std.math.maxInt(u32) else blk: {
                        const ns = lease.toNs() orelse break :blk std.math.maxInt(u32);
                        if (ns <= 0) break :blk 0;
                        break :blk @intCast(@min(@as(i64, std.math.maxInt(u32)), @divTrunc(ns, std.time.ns_per_ms)));
                    };
                }
            },
            PidTable.BUILTIN_ENDPOINT_SET => {
                if (v.len >= 4) builtin_eps = readU32LE(v[0..], le);
            },
            PidTable.METATRAFFIC_UNICAST_LOCATOR => {
                if (v.len >= 24) try meta_uc.append(alloc, readLocator(v, le));
            },
            PidTable.METATRAFFIC_MULTICAST_LOCATOR => {
                if (v.len >= 24) try meta_mc.append(alloc, readLocator(v, le));
            },
            PidTable.DEFAULT_UNICAST_LOCATOR => {
                if (v.len >= 24) try data_uc.append(alloc, readLocator(v, le));
            },
            PidTable.DEFAULT_MULTICAST_LOCATOR => {
                if (v.len >= 24) try data_mc.append(alloc, readLocator(v, le));
            },
            PidTable.ENTITY_NAME => {
                if (v.len >= 4) {
                    const slen = readU32LE(v[0..], le);
                    if (slen > 0 and v.len >= 4 + slen) {
                        const raw = v[4 .. 4 + slen - 1]; // strip null
                        name = try alloc.dupe(u8, raw);
                    }
                }
            },
            else => {
                log.spdp.debug("spdp: unknown pid=0x{x:0>4} len={d}", .{ pid, len });
            },
        }
    }

    log.spdp.debug("spdp: decoded data_uc={d} data_mc={d}", .{ data_uc.items.len, data_mc.items.len });
    for (data_uc.items) |loc| log.spdp.debug("spdp:   data_unicast_locator={any}", .{loc});

    return KnownParticipant{
        .alloc = alloc,
        .expires_ns = 0, // caller sets this
        .data = ParticipantData{
            .guid = .{
                .prefix = decoded_prefix,
                .entity_id = EntityIds.participant,
            },
            .domain_id = domain_id,
            .name = name,
            .metatraffic_unicast_locators = try meta_uc.toOwnedSlice(alloc),
            .metatraffic_multicast_locators = try meta_mc.toOwnedSlice(alloc),
            .default_unicast_locators = try data_uc.toOwnedSlice(alloc),
            .default_multicast_locators = try data_mc.toOwnedSlice(alloc),
            .lease_duration_ms = lease_ms,
            .builtin_endpoint_set = builtin_eps,
        },
    };
}

// ── PL-CDR write helpers ──────────────────────────────────────────────────────

fn writePidHdr(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), pid: u16, length: u16) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], pid, .little);
    std.mem.writeInt(u16, hdr[2..4], length, .little);
    try buf.appendSlice(alloc, &hdr);
}

fn writeU32Le(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(alloc, &b);
}

fn writeI32Le(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: i32) !void {
    try writeU32Le(alloc, buf, @bitCast(v));
}

fn writeLocator(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), loc: Locator) !void {
    const w = loc.toRtpsWire();
    try writeI32Le(alloc, buf, w.kind);
    try writeU32Le(alloc, buf, w.port);
    try buf.appendSlice(alloc, &w.address);
}

fn writeRtpsDuration(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), duration: time_mod.Duration) !void {
    const wire = time_mod.RtpsDuration.fromDuration(duration);
    try writeI32Le(alloc, buf, wire.seconds);
    try writeU32Le(alloc, buf, wire.fraction);
}

// ── PL-CDR read helpers ───────────────────────────────────────────────────────

fn readU16LE(buf: []const u8, le: bool) u16 {
    return std.mem.readInt(u16, buf[0..2], if (le) .little else .big);
}

fn readU32LE(buf: []const u8, le: bool) u32 {
    return std.mem.readInt(u32, buf[0..4], if (le) .little else .big);
}

fn readI32LE(buf: []const u8, le: bool) i32 {
    return @bitCast(readU32LE(buf, le));
}

fn readRtpsDuration(buf: []const u8, le: bool) time_mod.RtpsDuration {
    return .{ .seconds = readI32LE(buf[0..], le), .fraction = readU32LE(buf[4..], le) };
}

fn readLocator(buf: []const u8, le: bool) Locator {
    const kind = readI32LE(buf[0..], le);
    const port = readU32LE(buf[4..], le);
    var addr: [16]u8 = undefined;
    @memcpy(&addr, buf[8..24]);
    const wire = LocatorWire{ .kind = kind, .port = port, .address = addr };
    return wire.toLocator();
}
