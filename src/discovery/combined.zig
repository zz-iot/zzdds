//! SpdpSedpDiscovery — combined SPDP + SEDP discovery plugin.
//!
//! Wraps SpdpEndpoints and SedpEndpoints into a single Discovery vtable.
//! Wires SPDP → SEDP notification so that when SPDP discovers a remote
//! participant, SEDP immediately creates the proxy endpoints needed for
//! endpoint-level discovery and data exchange.
//!
//! Usage:
//!   const disc = try SpdpSedpDiscovery.init(alloc, transport, domain_id, period_ms);
//!   defer disc.deinit();                      // after participant.deinit()
//!   const discovery = disc.toDiscovery();
//!   // Pass discovery to DomainParticipantFactoryImpl.init(...)

const std = @import("std");
const iface = @import("interface.zig");
const spdp = @import("spdp.zig");
const sedp = @import("sedp.zig");
const wlp_mod = @import("wlp.zig");
const tr = @import("../transport/interface.zig");
const trace = @import("../trace.zig");
const header_mod = @import("../rtps/message/header.zig");

pub const Discovery = iface.Discovery;
pub const Callbacks = iface.Callbacks;
pub const Guid = iface.Guid;
pub const Transport = tr.Transport;
pub const ParticipantAnnouncement = iface.ParticipantAnnouncement;
pub const WriterAnnouncement = iface.WriterAnnouncement;
pub const ReaderAnnouncement = iface.ReaderAnnouncement;

/// Fans a single SPDP "participant discovered" notification out to both SEDP
/// and WLP. SpdpEndpoints only supports one downstream listener (a single
/// `sedp_ctx`/fn slot, see spdp.zig's setSedp) -- this shim lets that one
/// slot reach two builtin-endpoint modules instead of hand-modifying SPDP
/// itself for a second listener.
const DiscoveredFanout = struct {
    sedp: *sedp.SedpEndpoints,
    wlp: *wlp_mod.WlpEndpoints,

    fn onParticipantDiscovered(ctx: *anyopaque, data: *const iface.ParticipantData) void {
        const self: *DiscoveredFanout = @ptrCast(@alignCast(ctx));
        sedp.SedpEndpoints.onParticipantDiscovered(self.sedp, data);
        wlp_mod.WlpEndpoints.onParticipantDiscovered(self.wlp, data);
    }
};

pub const SpdpSedpDiscovery = struct {
    alloc: std.mem.Allocator,
    spdp: *spdp.SpdpEndpoints,
    sedp: *sedp.SedpEndpoints,
    wlp: *wlp_mod.WlpEndpoints,
    disc_fanout: DiscoveredFanout,

    const Self = @This();

    /// Create and wire the combined SPDP + SEDP discovery plugin.
    /// `domain_id` and `announcement_period_ms` are forwarded to SpdpEndpoints.
    pub fn init(
        alloc: std.mem.Allocator,
        transport: Transport,
        domain_id: u32,
        announcement_period_ms: u32,
    ) !*Self {
        const sp = try spdp.SpdpEndpoints.init(
            alloc,
            transport,
            domain_id,
            announcement_period_ms,
        );
        errdefer sp.deinit();

        const se = try sedp.SedpEndpoints.init(alloc, transport);
        errdefer se.deinit();

        const wl = try wlp_mod.WlpEndpoints.init(alloc, transport);
        errdefer wl.deinit();

        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .spdp = sp,
            .sedp = se,
            .wlp = wl,
            .disc_fanout = .{ .sedp = se, .wlp = wl },
        };

        // Wire SPDP → SEDP+WLP fanout: on each participant discovery event,
        // both create proxy state machines so they can exchange traffic.
        sp.setSedp(&self.disc_fanout, DiscoveredFanout.onParticipantDiscovered);

        // WLP shares SEDP's metatraffic unicast listener rather than opening
        // a second one on the same port (see sedp.zig's setWlpDispatch).
        se.setWlpDispatch(wl, wlp_mod.WlpEndpoints.tryHandleFromSedp);

        // Wire SEDP → SPDP relay: unicast SPDP responses arrive on the metatraffic
        // unicast port (RTPS §9.6.1.1), which SEDP owns.  Forward them to SPDP.
        se.setSpdpRelay(sp, spdp.SpdpEndpoints.handleRelayedData);
        // Wire SEDP → SPDP BYE: SPDP participant BYE messages arriving on the
        // metatraffic unicast port are forwarded to the SPDP handler.
        se.setSpdpByeFn(sp, spdp.SpdpEndpoints.removePeer);
        // Wire SPDP silence detection → SEDP liveness probe.
        sp.setBeginProbeFn(se, sedp.SedpEndpoints.beginProbe);
        // Wire SEDP probe result → SPDP participant eviction/renewal.
        se.setProbeResultFn(sp, spdp.SpdpEndpoints.onProbeResult);
        // Wire SEDP-traffic-seen → SPDP: stop targeted-retransmit once real SEDP
        // endpoint data has been received from a peer.
        se.setSedpSeenFn(sp, spdp.SpdpEndpoints.markSedpSeen);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.wlp.deinit();
        self.sedp.deinit();
        self.spdp.deinit();
        self.alloc.destroy(self);
    }

    /// Set the wire tracer on SPDP, SEDP, and WLP state machines.
    /// Call before the factory creates a participant (before `start()` is invoked).
    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.spdp.setTracer(t);
        self.sedp.setTracer(t);
        self.wlp.setTracer(t);
    }

    pub fn toDiscovery(self: *Self) Discovery {
        return .{ .ctx = self, .vtable = &vtable };
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
        .wlp_tick = vtWlpTick,
    };

    fn vtWlpTick(ctx: *anyopaque, now_ns: i64, info: iface.WlpTickInfo) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.wlp.tick(now_ns, info);
    }

    fn vtStart(
        ctx: *anyopaque,
        local: *const ParticipantAnnouncement,
        cbs: *const Callbacks,
    ) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // SEDP must be started first so its metatraffic unicast listen is active
        // before SPDP fires its initial announcement and the remote peer begins
        // sending SEDP traffic. WLP follows the same requirement for the same
        // reason (its own metatraffic unicast listener must be up before any
        // peer's WLP writer starts sending ParticipantMessageData).
        try self.sedp.start(local, cbs);
        try self.wlp.start(local, cbs);

        // SPDP deliberately never "discovers" this participant itself (see
        // spdp.zig's processSpdpPayload "ignore our own announcements" check --
        // a legitimate anti-echo optimization: a participant already knows its
        // own info, it doesn't need to receive its own multicast back to learn
        // it). But SEDP's built-in publications/subscriptions writer<->reader
        // matching is bootstrapped ONLY via that same SPDP "participant
        // discovered" notification (see sedp.onParticipantDiscovered, wired
        // below via setSedp) -- so without this call, the local participant's
        // own SEDP built-in writers never get a matched-reader-proxy for its
        // own SEDP built-in readers, and endpoint-discovery data for user
        // topics never transmits between a participant and itself, at any
        // timing: a writer and reader on the same participant/topic would
        // never match over the real transport.
        //
        // Fix: call the exact same function SPDP uses for every genuinely
        // remote discovered participant, once, for ourselves -- reusing the
        // proven-correct proxy-wiring/data-exchange path rather than adding a
        // separate self-matching shortcut. ParticipantAnnouncement and
        // ParticipantData share every field this needs (see interface.zig);
        // vendor_id uses the same VENDOR_ID constant SPDP stamps on its own
        // outgoing announcement.
        //
        // default_unicast/multicast_locators_for_data must mirror the plain
        // default_unicast/multicast_locators fields, NOT their zero default:
        // sedp.zig's handleEndpointChange falls back to participant_locs'
        // *_for_data fields specifically (the locators reachable by this
        // participant's user-data transport) when an endpoint's own
        // announcement omits explicit locators (the normal case -- zzdds
        // never sets per-endpoint locators locally). For a real remote
        // participant, spdp.zig's filterKnownParticipantLocators populates
        // these by duplicating the plain locators whenever no data_reachable
        // override is configured (the common case, matched here) -- leaving
        // them at `&.{}` would make every local writer/reader look
        // unreachable and silently drop the match without a real proxy.
        const self_data = iface.ParticipantData{
            .guid = local.guid,
            .domain_id = local.domain_id,
            .name = local.name,
            .metatraffic_unicast_locators = local.metatraffic_unicast_locators,
            .metatraffic_multicast_locators = local.metatraffic_multicast_locators,
            .default_unicast_locators = local.default_unicast_locators,
            .default_multicast_locators = local.default_multicast_locators,
            .default_unicast_locators_for_data = local.default_unicast_locators,
            .default_multicast_locators_for_data = local.default_multicast_locators,
            .lease_duration_ms = local.lease_duration_ms,
            .builtin_endpoint_set = local.builtin_endpoint_set,
            .vendor_id = header_mod.VENDOR_ID,
        };
        DiscoveredFanout.onParticipantDiscovered(&self.disc_fanout, &self_data);

        try self.spdp.start(local, cbs);
    }

    fn vtStop(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.spdp.stop();
        self.wlp.stop();
        self.sedp.stop();
    }

    fn vtAnnounceWriter(ctx: *anyopaque, info: *const iface.WriterAnnouncement) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.sedp.announceWriter(info);
    }

    fn vtRetractWriter(ctx: *anyopaque, guid: Guid) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.sedp.retractWriter(guid);
    }

    fn vtAnnounceReader(ctx: *anyopaque, info: *const iface.ReaderAnnouncement) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.sedp.announceReader(info);
    }

    fn vtRetractReader(ctx: *anyopaque, guid: Guid) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.sedp.retractReader(guid);
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};
