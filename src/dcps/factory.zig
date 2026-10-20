//! DomainParticipantFactoryImpl — DCPS DomainParticipantFactory implementation.
//!
//! Not a singleton. Each DomainParticipantFactoryImpl holds a transport, discovery
//! plugin, and security plugins. Multiple factory instances may coexist in a process.
//!
//! Usage:
//!   var factory = try DomainParticipantFactoryImpl.init(alloc, transport, discovery, security, .spec_random, .{});
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
const generated_config_mod = @import("../config/generated.zig");
const trace_mod = @import("../trace.zig");
const clock_registry_mod = @import("../util/clock_registry.zig");
const c_abi_handle = @import("../util/c_abi_handle.zig");
const runtime_mod = @import("../runtime/core.zig");
const log_mod = @import("../log.zig");
const build_opts = @import("build_options");

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

    /// The runtime new participants use in a `-Dshared-runtime` build, with
    /// the factory's own owner reference; guarded by `mu`. There is no
    /// default runtime yet, so creation fails until one is selected
    /// (docs/design/concurrency/runtime.md#selected-selection-hierarchy).
    runtime: ?*runtime_mod.Runtime = null,

    fac_c_abi: c_abi_handle.CachedCAbiHandle = .{},

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
        self.fac_c_abi.free(self.alloc);
        for (self.participants.items) |p| p.deinit();
        self.participants.deinit(self.alloc);
        if (self.runtime) |rt| rt.releaseOwner();
        self.clock_registry.deinit();
        self.default_dp_qos.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Configure the wire tracer applied to all participants created by this factory.
    /// Call before `create_participant`; has no effect on already-created participants.
    pub fn setTraceConfig(self: *Self, tc: trace_mod.TraceConfig) void {
        self.trace_config = tc;
    }

    /// Selects the runtime for participants created from now on, taking an
    /// owner reference to it and releasing the previous selection's.
    /// Existing participants keep theirs. Fails if `rt` is already retiring.
    pub fn selectRuntime(self: *Self, rt: ?*runtime_mod.Runtime) error{ SharedRuntimeDisabled, Retiring }!void {
        if (!build_opts.shared_runtime) return error.SharedRuntimeDisabled;
        if (rt) |r| if (!r.tryRetainOwner()) return error.Retiring;
        self.mu.lock();
        const old = self.runtime;
        self.runtime = rt;
        self.mu.unlock();
        if (old) |o| o.releaseOwner();
    }

    /// Takes an owner reference to the selected runtime for a new participant,
    /// after checking the participant's transports and discovery can run on
    /// it; null (with a diagnostic) when creation must fail. The migration
    /// build never falls back to the threaded path
    /// (docs/design/concurrency/runtime.md#coexistence-during-migration).
    fn acquireRuntimeFor(self: *Self, config: config_mod.Config) ?*runtime_mod.Runtime {
        if (!self.transport.vtable.shared_runtime_ready or config.transport.tcp.enabled) {
            log_mod.dcps.warn("create_participant: the transport is not supported on the shared runtime yet", .{});
            return null;
        }
        if (!self.discovery.vtable.shared_runtime_ready) {
            log_mod.dcps.warn("create_participant: the discovery plugin is not supported on the shared runtime yet", .{});
            return null;
        }
        self.mu.lock();
        defer self.mu.unlock();
        const rt = self.runtime orelse {
            log_mod.dcps.warn("create_participant: no runtime selected", .{});
            return null;
        };
        if (!rt.tryRetainOwner()) {
            log_mod.dcps.warn("create_participant: the selected runtime is retiring", .{});
            return null;
        }
        return rt;
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
        .get_c_abi_handle = vtGetCAbiHandleFactory,
        .get_allocator = vtGetAllocatorFactory,
    };

    fn vtGetCAbiHandleFactory(ctx: *anyopaque) *anyopaque {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.fac_c_abi.get(self.alloc, ctx, &vtable);
    }

    fn vtGetAllocatorFactory(ctx: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.alloc;
    }

    fn vtCreateParticipant(
        ctx: *anyopaque,
        domain_id: DDS.DomainId_t,
        qos: *const DDS.DomainParticipantQos,
        a_listener: ?*const DDS.DomainParticipantListener,
        mask: DDS.StatusMask,
    ) DDS.DomainParticipant {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.createParticipantWithConfig(domain_id, qos, a_listener, mask, self.config);
    }

    pub fn createParticipantWithConfig(
        self: *Self,
        domain_id: DDS.DomainId_t,
        qos: *const DDS.DomainParticipantQos,
        a_listener: ?*const DDS.DomainParticipantListener,
        mask: DDS.StatusMask,
        config: config_mod.Config,
    ) DDS.DomainParticipant {
        const p = self.createParticipantWithConfigOwned(domain_id, qos, a_listener, mask, config, null) orelse
            return nil.nil_participant;
        return p.toDDSParticipant();
    }

    pub fn createParticipantWithConfigOwned(
        self: *Self,
        domain_id: DDS.DomainId_t,
        qos: *const DDS.DomainParticipantQos,
        a_listener: ?*const DDS.DomainParticipantListener,
        mask: DDS.StatusMask,
        config: config_mod.Config,
        config_deinit_allocator: ?std.mem.Allocator,
    ) ?*participant_mod.DomainParticipantImpl {
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

        const timer_clock = self.clock_registry.get(config.participant.timer_clock_name);

        const rt: ?*runtime_mod.Runtime = if (build_opts.shared_runtime)
            self.acquireRuntimeFor(config) orelse return null
        else
            null;

        const p = participant_mod.DomainParticipantImpl.init(
            self.alloc,
            domain_id,
            guid,
            self.transport,
            self.discovery,
            self.security,
            config,
            qos.*,
            if (a_listener) |l| l.* else DDS.noop_DomainParticipantListener,
            mask,
            handle,
            self.trace_config.tracer(),
            // On a runtime, timed QoS runs on its clock.
            if (rt) |r| r.clock else timer_clock,
        ) catch {
            if (rt) |r| r.releaseOwner();
            return null;
        };
        if (rt) |r| p.attachRuntime(r);
        // config_deinit_allocator is set AFTER participants.append so that p.deinit()
        // on any failure path below doesn't free config — the caller retains ownership
        // and handles cleanup on error.

        p.enabled.store(self.factory_qos.entity_factory.autoenable_created_entities, .release);

        // Start discovery; if it fails we still own the participant and must clean up.
        // Deferred entirely when created disabled (ENTITY_FACTORY QoS) -- enable()
        // calls p.start() itself once the app is ready to go live (participant.zig's
        // vtEnable). Per spec, a participant's own enabled state comes from the
        // FACTORY's entity_factory QoS (self.factory_qos, set via
        // set_qos()/DomainParticipantFactory_get_instance()) -- mirroring how a
        // Publisher's enabled state comes from its owning participant's
        // entity_factory, not its own -- NOT from `qos.entity_factory`, which is
        // the QoS being applied to the new participant itself and has no
        // factory-level meaning here.
        if (self.factory_qos.entity_factory.autoenable_created_entities) {
            p.start() catch {
                p.deinit();
                return null;
            };
        }

        self.mu.lock();
        self.participants.append(self.alloc, p) catch {
            self.mu.unlock();
            p.deinit();
            return null;
        };
        self.mu.unlock();

        p.config_deinit_allocator = config_deinit_allocator;
        return p;
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

    fn vtSetDefaultDpQos(ctx: *anyopaque, qos: *const DDS.DomainParticipantQos) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.default_dp_qos.deinit(self.alloc);
        self.default_dp_qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultDpQos(ctx: *anyopaque, qos: *DDS.DomainParticipantQos) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        qos.* = self.default_dp_qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtSetQos(ctx: *anyopaque, qos: *const DDS.DomainParticipantFactoryQos) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.factory_qos = qos.*;
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
