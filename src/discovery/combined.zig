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
const tr = @import("../transport/interface.zig");
const trace = @import("../trace.zig");

pub const Discovery = iface.Discovery;
pub const Callbacks = iface.Callbacks;
pub const Guid = iface.Guid;
pub const Transport = tr.Transport;
pub const ParticipantAnnouncement = iface.ParticipantAnnouncement;
pub const WriterAnnouncement = iface.WriterAnnouncement;
pub const ReaderAnnouncement = iface.ReaderAnnouncement;

pub const SpdpSedpDiscovery = struct {
    alloc: std.mem.Allocator,
    spdp: *spdp.SpdpEndpoints,
    sedp: *sedp.SedpEndpoints,

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

        // Wire SPDP → SEDP: on each participant discovery event, SEDP creates
        // proxy state machines so it can exchange endpoint announcements.
        sp.setSedp(se, sedp.SedpEndpoints.onParticipantDiscovered);

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

        const self = try alloc.create(Self);
        self.* = .{ .alloc = alloc, .spdp = sp, .sedp = se };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.sedp.deinit();
        self.spdp.deinit();
        self.alloc.destroy(self);
    }

    /// Set the wire tracer on both SPDP and SEDP state machines.
    /// Call before the factory creates a participant (before `start()` is invoked).
    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.spdp.setTracer(t);
        self.sedp.setTracer(t);
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
    };

    fn vtStart(
        ctx: *anyopaque,
        local: *const ParticipantAnnouncement,
        cbs: *const Callbacks,
    ) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // SEDP must be started first so its metatraffic unicast listen is active
        // before SPDP fires its initial announcement and the remote peer begins
        // sending SEDP traffic.
        try self.sedp.start(local, cbs);
        try self.spdp.start(local, cbs);
    }

    fn vtStop(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.spdp.stop();
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
