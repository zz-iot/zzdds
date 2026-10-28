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
const builtin = @import("builtin");
const iface = @import("interface.zig");
const spdp = @import("spdp.zig");
const sedp = @import("sedp.zig");
const wlp_mod = @import("wlp.zig");
const tr = @import("../transport/interface.zig");
const trace = @import("../trace.zig");
const header_mod = @import("../rtps/message/header.zig");
const runtime_mod = @import("../runtime/core.zig");
const CloseLatch = @import("../runtime/close_latch.zig").CloseLatch;
const QueuedReceive = @import("../transport/queued_receive.zig").QueuedReceive;
const Mutex = @import("../util/mutex.zig").Mutex;

pub const Discovery = iface.Discovery;
pub const Callbacks = iface.Callbacks;
pub const Guid = iface.Guid;
pub const Transport = tr.Transport;
pub const ParticipantAnnouncement = iface.ParticipantAnnouncement;
pub const WriterAnnouncement = iface.WriterAnnouncement;
pub const ReaderAnnouncement = iface.ReaderAnnouncement;

/// Fans a single SPDP "participant discovered" or "participant lost"
/// notification out to both SEDP and WLP. SpdpEndpoints only supports one
/// downstream listener (a single `sedp_ctx` slot, see spdp.zig's setSedp) --
/// this shim lets that one slot reach two builtin-endpoint modules instead
/// of hand-modifying SPDP itself for a second listener.
const DiscoveredFanout = struct {
    sedp: *sedp.SedpEndpoints,
    wlp: *wlp_mod.WlpEndpoints,

    fn onParticipantDiscovered(ctx: *anyopaque, data: *const iface.ParticipantData) void {
        const self: *DiscoveredFanout = @ptrCast(@alignCast(ctx));
        sedp.SedpEndpoints.onParticipantDiscovered(self.sedp, data);
        wlp_mod.WlpEndpoints.onParticipantDiscovered(self.wlp, data);
    }

    fn onParticipantLost(ctx: *anyopaque, prefix: iface.GuidPrefix) void {
        const self: *DiscoveredFanout = @ptrCast(@alignCast(ctx));
        sedp.SedpEndpoints.onParticipantLost(self.sedp, prefix);
        wlp_mod.WlpEndpoints.onParticipantLost(self.wlp, prefix);
    }
};

pub const SpdpSedpDiscovery = struct {
    alloc: std.mem.Allocator,
    transport: Transport,
    domain_id: u32,
    announcement_period_ms: u32,
    tracer: ?trace.Tracer = null,
    spdp: *spdp.SpdpEndpoints,
    sedp: *sedp.SedpEndpoints,
    wlp: *wlp_mod.WlpEndpoints,
    disc_fanout: DiscoveredFanout,

    /// With a runtime (`attachRuntime`): the contexts that process received
    /// datagrams, one at a time, and run the SPDP timers. Writers'
    /// heartbeats run in contexts of their own.
    runtime: ?*runtime_mod.Runtime = null,
    ingress: runtime_mod.Context = undefined,
    ingress_latch: CloseLatch = .{},
    timers: runtime_mod.Context = undefined,
    timers_latch: CloseLatch = .{},
    /// The plugin serves one participant at a time. Once that participant
    /// has stopped it, the next one gets fresh SPDP, SEDP and WLP state, on
    /// any runtime.
    phase: enum { fresh, started, stopping, stopped } = .fresh,
    /// Guards `phase` and the replacement of the parts and runtime:
    /// participants are created and deleted on different threads.
    mu: Mutex = .{},
    test_hooks: if (builtin.is_test) TestHooks else void = if (builtin.is_test) .{} else {},

    /// Seams for deterministic tests of races; absent outside test builds.
    pub const TestHooks = struct {
        /// Runs once in `stop`, after the plugin is marked stopping and
        /// before its parts stop.
        while_stopping: ?*const fn (self: *Self) void = null,
    };

    /// Bound on the datagrams queued for ingress and not yet processed. A
    /// placeholder, as the participant's own.
    pub const ingress_pending_limit: u32 = 256;

    const Self = @This();

    /// Create and wire the combined SPDP + SEDP discovery plugin.
    /// `domain_id` and `announcement_period_ms` are forwarded to SpdpEndpoints.
    pub fn init(
        alloc: std.mem.Allocator,
        transport: Transport,
        domain_id: u32,
        announcement_period_ms: u32,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .transport = transport,
            .domain_id = domain_id,
            .announcement_period_ms = announcement_period_ms,
            .spdp = undefined,
            .sedp = undefined,
            .wlp = undefined,
            .disc_fanout = undefined,
        };
        try self.initParts();
        return self;
    }

    /// Creates and wires SPDP, SEDP and WLP.
    fn initParts(self: *Self) !void {
        const alloc = self.alloc;
        const sp = try spdp.SpdpEndpoints.init(
            alloc,
            self.transport,
            self.domain_id,
            self.announcement_period_ms,
        );
        errdefer sp.deinit();

        const se = try sedp.SedpEndpoints.init(alloc, self.transport);
        errdefer se.deinit();

        const wl = try wlp_mod.WlpEndpoints.init(alloc, self.transport);
        errdefer wl.deinit();

        self.spdp = sp;
        self.sedp = se;
        self.wlp = wl;
        self.disc_fanout = .{ .sedp = se, .wlp = wl };
        if (self.tracer) |t| {
            sp.setTracer(t);
            se.setTracer(t);
            wl.setTracer(t);
        }

        // Wire SPDP → SEDP+WLP fanout: on each participant discovery event,
        // both create proxy state machines so they can exchange traffic, and
        // on each loss both drop them.
        sp.setSedp(&self.disc_fanout, DiscoveredFanout.onParticipantDiscovered, DiscoveredFanout.onParticipantLost);

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
    }

    /// Frees SPDP, SEDP and WLP and, with a runtime, its closed contexts.
    fn deinitParts(self: *Self) void {
        self.wlp.deinit();
        self.sedp.deinit();
        self.spdp.deinit();
        if (self.runtime != null) {
            self.ingress.deinit();
            self.timers.deinit();
        }
    }

    pub fn deinit(self: *Self) void {
        self.deinitParts();
        self.alloc.destroy(self);
    }

    /// Gives a participant after a stopped one, or one on another runtime
    /// than a participant that never started, the state of a new plugin on
    /// `rt`: nothing of the earlier participant's peers or announcements
    /// remains. Unstarted or stopped, the old parts have nothing armed or
    /// queued. With `mu` held.
    fn reset(self: *Self, rt: ?*runtime_mod.Runtime) !void {
        std.debug.assert(self.phase == .fresh or self.phase == .stopped);
        const sp = self.spdp;
        const se = self.sedp;
        const wl = self.wlp;
        try self.initParts();
        wl.deinit();
        se.deinit();
        sp.deinit();
        if (self.runtime != null) {
            self.ingress.deinit();
            self.timers.deinit();
        }
        self.runtime = null;
        self.ingress_latch = .{};
        self.timers_latch = .{};
        self.phase = .fresh;
        if (rt) |r| self.attachParts(r);
    }

    /// Runs discovery on `rt` instead of threads of its own: SPDP's
    /// announcements and lease checks and the built-in writers' heartbeats
    /// are timers on its clock, and what discovery receives is queued for
    /// its ingress context (docs/design/concurrency/runtime.md#thread-mapping).
    /// Call before `start`; attaching the runtime already attached is a
    /// no-op. A started plugin stays on its runtime until it has stopped;
    /// after that, the next participant's runtime replaces it.
    pub fn attachRuntime(self: *Self, rt: *runtime_mod.Runtime) error{ AttachedElsewhere, OutOfMemory }!void {
        self.mu.lock();
        defer self.mu.unlock();
        switch (self.phase) {
            .started, .stopping => if (self.runtime != rt) return error.AttachedElsewhere,
            .stopped => try self.reset(rt),
            .fresh => if (self.runtime) |cur| {
                if (cur != rt) try self.reset(rt);
            } else self.attachParts(rt),
        }
    }

    /// Puts the parts' work on `rt`, in new contexts.
    fn attachParts(self: *Self, rt: *runtime_mod.Runtime) void {
        self.runtime = rt;
        self.ingress = runtime_mod.Context.init(rt, ingress_pending_limit);
        self.ingress.on_closed = self.ingress_latch.hook();
        // Only timer fires run here, with internal credit.
        self.timers = runtime_mod.Context.init(rt, 0);
        self.timers.on_closed = self.timers_latch.hook();
        self.spdp.attachRuntime(rt, &self.ingress, &self.timers);
        self.sedp.attachRuntime(rt, &self.ingress);
        self.wlp.attachRuntime(rt);
    }

    /// Set the wire tracer on SPDP, SEDP, and WLP state machines.
    /// Call before the factory creates a participant (before `start()` is invoked).
    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.tracer = t;
        self.spdp.setTracer(t);
        self.sedp.setTracer(t);
        self.wlp.setTracer(t);
    }

    pub fn toDiscovery(self: *Self) Discovery {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // ── Discovery vtable ──────────────────────────────────────────────────────

    const vtable = Discovery.Vtable{
        .shared_runtime_ready = true,
        .start = vtStart,
        .stop = vtStop,
        .announce_writer = vtAnnounceWriter,
        .retract_writer = vtRetractWriter,
        .announce_reader = vtAnnounceReader,
        .retract_reader = vtRetractReader,
        .deinit = vtDeinit,
        .wlp_tick = vtWlpTick,
        .attach_runtime = vtAttachRuntime,
    };

    fn vtAttachRuntime(ctx: *anyopaque, rt: *runtime_mod.Runtime) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.attachRuntime(rt);
    }

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
        {
            self.mu.lock();
            defer self.mu.unlock();
            switch (self.phase) {
                // Another participant's: one at a time.
                .started, .stopping => return error.AlreadyStarted,
                // On the runtime the participant attached, if any.
                .stopped => try self.reset(self.runtime),
                .fresh => {},
            }
            self.phase = .started;
        }
        // The participant stops only what started.
        errdefer self.stopParts();
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
        self.stopParts();
    }

    fn stopParts(self: *Self) void {
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.phase != .started) return;
            // Not replaced while they stop.
            self.phase = .stopping;
        }
        if (builtin.is_test) {
            if (self.test_hooks.while_stopping) |hook| {
                self.test_hooks.while_stopping = null;
                hook(self);
            }
        }
        self.spdp.stop();
        self.wlp.stop();
        self.sedp.stop();
        if (self.runtime != null) {
            // Unlistened and disarmed above: what is queued is dropped, and a
            // turn running elsewhere finishes first. Never stopped from
            // inside one of these turns: participant deletion does not run
            // in discovery's work.
            const ingress_closed = self.ingress_latch.close(&self.ingress, QueuedReceive.discard);
            const timers_closed = self.timers_latch.close(&self.timers, discardTimer);
            std.debug.assert(ingress_closed and timers_closed);
        }
        self.mu.lock();
        defer self.mu.unlock();
        self.phase = .stopped;
    }

    /// A queued fire is the timer's own embedded request: nothing to free.
    fn discardTimer(_: *runtime_mod.Request) void {}

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
