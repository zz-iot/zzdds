//! DomainParticipantFactoryImpl — DCPS DomainParticipantFactory implementation.
//!
//! Not a singleton. Each DomainParticipantFactoryImpl holds a transport, discovery
//! plugin, and security plugins. Multiple factory instances may coexist in a process.
//!
//! Usage:
//!   var factory = try DomainParticipantFactoryImpl.init(alloc, transport, discovery, security, .random, .{});
//!   defer factory.deinit();
//!   const dp = factory.toDDSFactory().create_participant(0, .{}, nil_dp_listener, 0);
//!   defer dp.deinit();

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const nil = @import("nil.zig");
const participant_mod = @import("participant.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const guid_gen = @import("../util/guid_gen.zig");
const config_mod = @import("../config/schema.zig");
const trace_mod = @import("../trace.zig");
const clock_registry_mod = @import("../util/clock_registry.zig");

pub const ClockRegistry = clock_registry_mod.ClockRegistry;

pub const Transport = participant_mod.Transport;
pub const Discovery = participant_mod.Discovery;
pub const SecurityPlugins = participant_mod.SecurityPlugins;
pub const GuidStrategy = config_mod.GuidStrategy;

pub const DomainParticipantFactoryImpl = struct {
    alloc: std.mem.Allocator,
    transport: Transport,
    discovery: Discovery,
    security: SecurityPlugins,
    config: config_mod.Config,
    guid_strategy: GuidStrategy,
    factory_qos: DDS.DomainParticipantFactoryQos,
    default_dp_qos: DDS.DomainParticipantQos,
    trace_config: trace_mod.TraceConfig,
    clock_registry: ClockRegistry,

    /// Active participants owned by this factory; guarded by `mu`.
    participants: std.ArrayListUnmanaged(*participant_mod.DomainParticipantImpl),
    /// Handle counter for participants; guarded by `mu`.
    next_handle: DDS.InstanceHandle_t,

    mu: Mutex,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        transport: Transport,
        discovery: Discovery,
        security: SecurityPlugins,
        guid_strategy: GuidStrategy,
        config: config_mod.Config,
    ) !*Self {
        var reg = try ClockRegistry.init(alloc);
        errdefer reg.deinit();
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .transport = transport,
            .discovery = discovery,
            .security = security,
            .config = config,
            .guid_strategy = guid_strategy,
            .factory_qos = .{},
            .default_dp_qos = .{},
            .trace_config = .{},
            .clock_registry = reg,
            .participants = .empty,
            .next_handle = 1,
            .mu = .{},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.participants.items) |p| p.deinit();
        self.participants.deinit(self.alloc);
        self.clock_registry.deinit();
        self.alloc.destroy(self);
    }

    /// Configure the wire tracer applied to all participants created by this factory.
    /// Call before `create_participant`; has no effect on already-created participants.
    pub fn setTraceConfig(self: *Self, tc: trace_mod.TraceConfig) void {
        self.trace_config = tc;
    }

    pub fn toDDSFactory(self: *Self) DDS.DomainParticipantFactory {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ── Vtable ────────────────────────────────────────────────────────────────

    const vtable = DDS.DomainParticipantFactory.Vtable{
        .create_participant = vtCreateParticipant,
        .delete_participant = vtDeleteParticipant,
        .lookup_participant = vtLookupParticipant,
        .set_default_participant_qos = vtSetDefaultDpQos,
        .get_default_participant_qos = vtGetDefaultDpQos,
        .set_qos = vtSetQos,
        .get_qos = vtGetQos,
        .deinit = vtDeinit,
    };

    fn vtCreateParticipant(
        ctx: *anyopaque,
        domain_id: DDS.DomainId_t,
        qos: DDS.DomainParticipantQos,
        a_listener: DDS.DomainParticipantListener,
        mask: DDS.StatusMask,
    ) DDS.DomainParticipant {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Allocate a handle for this participant.
        self.mu.lock();
        const handle = self.next_handle;
        self.next_handle +%= 1;
        self.mu.unlock();

        // Generate a GUID prefix.
        const prefix = guid_gen.generate(self.guid_strategy);
        const guid = participant_mod.Guid{
            .prefix = prefix,
            .entity_id = participant_mod.EntityIds.participant,
        };

        const timer_clock = self.clock_registry.get(self.config.participant.timer_clock_name);

        const p = participant_mod.DomainParticipantImpl.init(
            self.alloc,
            domain_id,
            guid,
            self.transport,
            self.discovery,
            self.security,
            self.config,
            qos,
            a_listener,
            mask,
            handle,
            self.trace_config.tracer(),
            timer_clock,
        ) catch return nil.nil_participant;

        // Start discovery; if it fails we still own the participant and must clean up.
        p.start() catch {
            p.deinit();
            return nil.nil_participant;
        };

        self.mu.lock();
        self.participants.append(self.alloc, p) catch {
            self.mu.unlock();
            p.deinit();
            return nil.nil_participant;
        };
        self.mu.unlock();

        return p.toDDSParticipant();
    }

    fn vtDeleteParticipant(ctx: *anyopaque, a_participant: DDS.DomainParticipant) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        var found_idx: ?usize = null;
        var found_p: ?*participant_mod.DomainParticipantImpl = null;
        for (self.participants.items, 0..) |p, i| {
            if (p.toDDSParticipant().ptr == a_participant.ptr) {
                found_idx = i;
                found_p = p;
                break;
            }
        }
        self.mu.unlock();
        const p = found_p orelse return DDS.RETCODE_BAD_PARAMETER;
        // Spec §2.2.2.2.1.10: return PRECONDITION_NOT_MET if any entities remain.
        p.mu.lock();
        const has_children = p.publishers.items.len > 0 or
            p.subscribers.items.len > 0 or
            p.topics.items.len > 0 or
            p.cft_topics.items.len > 0;
        p.mu.unlock();
        if (has_children) return DDS.RETCODE_PRECONDITION_NOT_MET;
        self.mu.lock();
        _ = self.participants.swapRemove(found_idx.?);
        self.mu.unlock();
        p.deinit();
        return DDS.RETCODE_OK;
    }

    fn vtLookupParticipant(ctx: *anyopaque, domain_id: DDS.DomainId_t) DDS.DomainParticipant {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.participants.items) |p| {
            if (p.domain_id == domain_id) return p.toDDSParticipant();
        }
        return nil.nil_participant;
    }

    fn vtSetDefaultDpQos(ctx: *anyopaque, qos: DDS.DomainParticipantQos) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.default_dp_qos = qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultDpQos(ctx: *anyopaque, qos: *DDS.DomainParticipantQos) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        qos.* = self.default_dp_qos;
        return DDS.RETCODE_OK;
    }

    fn vtSetQos(ctx: *anyopaque, qos: DDS.DomainParticipantFactoryQos) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.factory_qos = qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetQos(ctx: *anyopaque, qos: *DDS.DomainParticipantFactoryQos) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        qos.* = self.factory_qos;
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};
