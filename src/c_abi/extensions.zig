//! C ABI exports for generated zzdds extension interfaces.

const std = @import("std");

const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const zidl_rt = @import("zidl_rt");
const c_abi_handle = @import("../util/c_abi_handle.zig");

const config_generated = @import("../config/generated.zig");
const config_mod = @import("../config/schema.zig");
const process_config = @import("../config/process.zig");
const DomainParticipantFactoryImpl = @import("../dcps/factory.zig").DomainParticipantFactoryImpl;
const participant_mod = @import("../dcps/participant.zig");
const DomainParticipantImpl = participant_mod.DomainParticipantImpl;
const PublisherImpl = @import("../dcps/publisher.zig").PublisherImpl;
const SubscriberImpl = @import("../dcps/subscriber.zig").SubscriberImpl;
const DataWriterImpl = @import("../dcps/writer.zig").DataWriterImpl;
const reader_mod = @import("../dcps/reader.zig");
const DataReaderImpl = reader_mod.DataReaderImpl;
const topic_mod = @import("../dcps/topic.zig");
const TopicImpl = topic_mod.TopicImpl;
const ContentFilteredTopicImpl = topic_mod.ContentFilteredTopicImpl;
const filter_mod = @import("../dcps/filter.zig");
const waitset_mod = @import("../dcps/waitset.zig");
const WaitSetImpl = waitset_mod.WaitSetImpl;
const GuardConditionImpl = waitset_mod.GuardConditionImpl;
const StatusConditionImpl = waitset_mod.StatusConditionImpl;
const ReadConditionImpl = waitset_mod.ReadConditionImpl;
const QueryConditionImpl = waitset_mod.QueryConditionImpl;
const Mutex = @import("../util/mutex.zig").Mutex;
const UdpTransport = @import("../transport/udp.zig").UdpTransport;
const SpdpSedpDiscovery = @import("../discovery/combined.zig").SpdpSedpDiscovery;
const noop_security = @import("../security/noop.zig").noop_security_plugins;
const history_mod = @import("../rtps/history.zig");
const time_mod = @import("../util/time.zig");
const nil = @import("../dcps/nil.zig");

const FactoryOwner = struct {
    alloc: std.mem.Allocator,
    mu: Mutex = .{},
    stacks: std.ArrayListUnmanaged(*ParticipantStack) = .empty,
    default_dp_qos: DDS.DomainParticipantQos = .{},
    factory_qos: DDS.DomainParticipantFactoryQos = .{},
    /// What plain create_participant() uses; seeded from the process-wide
    /// config at construction (see createFactory), independently overridable
    /// per-factory via set_default_participant_config from there on.
    default_config: ZZDDS.DomainParticipantConfig = .{},
    /// One box for the whole object, shared across both interface views
    /// (ZZDDS.DomainParticipantFactory via `factory_vtable`,
    /// DDS.DomainParticipantFactory via `dds_factory_vtable`) — see `views`
    /// below and zidl/docs/roadmap.md "Binding design review: decision".
    /// NOT the same object as `DomainParticipantFactoryImpl` (factory.zig) —
    /// see that struct's own doc comment; `FactoryOwner` is the real,
    /// app-visible factory identity, `DomainParticipantFactoryImpl` is an
    /// internal per-`ParticipantStack` delegate with its own, independent,
    /// single-view box.
    fac_c_abi: c_abi_handle.CachedCAbiHandle = .{},

    fn deinit(self: *@This()) void {
        self.fac_c_abi.free(self.alloc);
        for (self.stacks.items) |stack| stack.deinit();
        self.stacks.deinit(self.alloc);
        self.default_dp_qos.deinit(self.alloc);
        self.default_config.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn createParticipant(
        self: *@This(),
        domain_id: DDS.DomainId_t,
        qos: *const DDS.DomainParticipantQos,
        a_listener: ?*const DDS.DomainParticipantListener,
        mask: DDS.StatusMask,
        config: config_mod.Config,
        config_deinit_allocator: ?std.mem.Allocator,
    ) !DDS.DomainParticipant {
        const stack = try ParticipantStack.init(self.alloc, domain_id, config);
        errdefer stack.deinit();

        // Clone QoS under the lock so the snapshot owns its heap memory and
        // is safe to use after the lock is released.
        self.mu.lock();
        var dp_qos_snap = self.default_dp_qos.clone(self.alloc) catch |e| {
            self.mu.unlock();
            return e;
        };
        const fac_qos_snap = self.factory_qos;
        self.mu.unlock();
        defer dp_qos_snap.deinit(self.alloc);

        if (stack.factory_handle.vtable.set_default_participant_qos(stack.factory_handle.ptr, &dp_qos_snap) != DDS.RETCODE_OK)
            std.log.warn("createParticipant: failed to propagate default_dp_qos to inner factory; PARTICIPANT_QOS_DEFAULT will use defaults", .{});
        if (stack.factory_handle.vtable.set_qos(stack.factory_handle.ptr, &fac_qos_snap) != DDS.RETCODE_OK)
            std.log.warn("createParticipant: failed to propagate factory_qos to inner factory", .{});

        // Always use createParticipantWithConfigOwned so the `config` param is
        // honoured regardless of whether ownership is being transferred.  Pass
        // null for the allocator here; ownership is assigned after stacks.append
        // so that p.deinit() on any failure path doesn't free the config (the
        // caller's catch block in factoryCreateParticipantEx is the sole cleanup
        // site).
        const p = stack.factory.createParticipantWithConfigOwned(domain_id, qos, a_listener, mask, config, null) orelse
            return error.ParticipantFailed;

        self.mu.lock();
        defer self.mu.unlock();
        stack.domain_id = domain_id;
        stack.participant = p.toDDSParticipant();
        try self.stacks.append(self.alloc, stack);
        // config_deinit_allocator is written here under FactoryOwner.mu.
        // DomainParticipantImpl.deinit reads it without holding FactoryOwner.mu,
        // so this field must never be mutated outside a FactoryOwner.mu critical section.
        if (config_deinit_allocator) |cfg_alloc| p.config_deinit_allocator = cfg_alloc;
        return stack.participant;
    }

    fn deleteParticipant(self: *@This(), participant: DDS.DomainParticipant) DDS.ReturnCode_t {
        if (nil.isNil(participant)) return DDS.RETCODE_BAD_PARAMETER;
        // Find the stack without removing it yet. Calling the inner factory
        // vtable inside FactoryOwner.mu would invert lock order (FactoryOwner.mu
        // → inner factory mu), risking deadlock if a listener re-enters here.
        self.mu.lock();
        var found: ?*ParticipantStack = null;
        for (self.stacks.items) |stack| {
            if (stack.participant.ptr == participant.ptr) {
                found = stack;
                break;
            }
        }
        self.mu.unlock();
        const stack = found orelse return DDS.RETCODE_BAD_PARAMETER;
        // Call into the inner factory outside any lock. PRECONDITION_NOT_MET
        // means the participant still has live entities — do NOT destroy the stack.
        const rc = stack.factory_handle.vtable.delete_participant(stack.factory_handle.ptr, participant);
        if (rc != DDS.RETCODE_OK) return rc;
        // Inner factory accepted the deletion; now remove and destroy the stack.
        self.mu.lock();
        for (self.stacks.items, 0..) |s, i| {
            if (s.participant.ptr == participant.ptr) {
                _ = self.stacks.swapRemove(i);
                break;
            }
        }
        self.mu.unlock();
        stack.deinit();
        return DDS.RETCODE_OK;
    }

    fn lookupParticipant(self: *@This(), domain_id: DDS.DomainId_t) DDS.DomainParticipant {
        // Use the stored domain_id and participant handle to avoid calling the
        // inner factory vtable under self.mu (which would invert lock order).
        self.mu.lock();
        defer self.mu.unlock();
        for (self.stacks.items) |stack| {
            if (stack.domain_id == domain_id) return stack.participant;
        }
        return nil.nil_participant;
    }
};

const ParticipantStack = struct {
    alloc: std.mem.Allocator,
    factory: *DomainParticipantFactoryImpl,
    discovery: *SpdpSedpDiscovery,
    udp: *UdpTransport,
    factory_handle: DDS.DomainParticipantFactory,
    // The single participant created through this stack, and its domain id.
    // Stored so deleteParticipant and lookupParticipant can identify the stack
    // without calling the inner factory vtable while holding FactoryOwner.mu
    // (which would invert lock order: FactoryOwner.mu → inner factory mu).
    domain_id: DDS.DomainId_t = 0,
    participant: DDS.DomainParticipant = nil.nil_participant,

    fn deinit(self: *@This()) void {
        // factory.deinit() sends RTPS BYE announcements via the UDP transport,
        // so it must run BEFORE udp.deinit() closes the sockets.
        // UdpTransport owns a deep copy of its config.interfaces strings, so
        // factory.deinit() freeing the participant config is safe.
        self.factory.deinit();
        self.discovery.deinit();
        self.udp.deinit();
        self.alloc.destroy(self);
    }

    fn init(alloc: std.mem.Allocator, domain_id: DDS.DomainId_t, config: config_mod.Config) !*@This() {
        const stack = try alloc.create(@This());
        errdefer alloc.destroy(stack);

        const udp = try UdpTransport.init(alloc, config.transport.udp, domain_id, null);
        errdefer udp.deinit();

        const discovery = try SpdpSedpDiscovery.init(
            alloc,
            udp.transport(),
            domain_id,
            config.participant.announcement_period_ms,
        );
        errdefer discovery.deinit();

        const factory = try DomainParticipantFactoryImpl.init(
            alloc,
            udp.transport(),
            discovery.toDiscovery(),
            noop_security,
            config.participant.guid_strategy,
            .{},
        );
        errdefer factory.deinit();

        stack.* = .{
            .alloc = alloc,
            .factory = factory,
            .discovery = discovery,
            .udp = udp,
            .factory_handle = factory.toDDSFactory(),
        };
        return stack;
    }
};

pub const factory_vtable = ZZDDS.DomainParticipantFactory.Vtable{
    .create_participant_ex = factoryCreateParticipantEx,
    .set_default_participant_config = factorySetDefaultParticipantConfig,
    .get_default_participant_config = factoryGetDefaultParticipantConfig,
    .deinit = factoryDeinit,
    .get_c_abi_handle = factoryGetCAbiHandleZzdds,
    .as_DomainParticipantFactory = factoryAsDdsFactory,
};

fn factoryAsDdsFactory(ctx: *anyopaque) DDS.DomainParticipantFactory {
    return .{ .ptr = ctx, .vtable = &dds_factory_vtable };
}

/// One `CAbiViews` value for the whole `FactoryOwner` object, covering both
/// interface views it presents (DomainParticipantFactory, ZZDDS.
/// DomainParticipantFactory) — see `GuardConditionImpl.views`'s
/// identical-shape doc comment.
pub const factory_views = ZZDDS.DomainParticipantFactory.CAbiViews{
    .base = .{ .flat_vtable = &dds_factory_vtable },
    .flat_vtable = &factory_vtable,
};

// Nil ZZDDS.* views (ptr == nil.NIL_PTR, but still the real vtable — see
// DDS_..._as_zzdds_... below) need their own dedicated cache, same reasoning
// as nil.zig's own nil-entity singletons: there's no real impl object to hang
// a cache field off of, and std.heap.c_allocator is the fixed default.
var nil_zzdds_fac_c_abi: c_abi_handle.CachedCAbiHandle = .{};

fn factoryGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_fac_c_abi.get(std.heap.c_allocator, ctx, &factory_vtable);
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    return owner.fac_c_abi.get(owner.alloc, ctx, &factory_views);
}

const dds_factory_vtable = DDS.DomainParticipantFactory.Vtable{
    .create_participant = factoryCreateParticipant,
    .delete_participant = factoryDeleteParticipant,
    .lookup_participant = factoryLookupParticipant,
    .set_default_participant_qos = factorySetDefaultParticipantQos,
    .get_default_participant_qos = factoryGetDefaultParticipantQos,
    .set_qos = factorySetQos,
    .get_qos = factoryGetQos,
    .deinit = factoryDeinit,
    .get_c_abi_handle = factoryGetCAbiHandleDds,
};

// Same reasoning as nil_zzdds_fac_c_abi above, for the DDS.* view.
var nil_dds_fac_c_abi: c_abi_handle.CachedCAbiHandle = .{};

fn factoryGetCAbiHandleDds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_dds_fac_c_abi.get(std.heap.c_allocator, ctx, &dds_factory_vtable);
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    return owner.fac_c_abi.get(owner.alloc, ctx, &factory_views);
}

pub const participant_vtable = ZZDDS.DomainParticipant.Vtable{
    .register_type_support = participantRegisterTypeSupport,
    .deinit = borrowedDeinit,
    .get_c_abi_handle = participantGetCAbiHandleZzdds,
    .as_DomainParticipant = participantAsDds,
};

fn participantAsDds(ctx: *anyopaque) DDS.DomainParticipant {
    if (ctx == nil.NIL_PTR) return nil.nil_participant;
    const impl: *DomainParticipantImpl = @ptrCast(@alignCast(ctx));
    return impl.toDDSParticipant();
}

var nil_zzdds_participant_c_abi: c_abi_handle.CachedCAbiHandle = .{};
const nil_zzdds_participant_views = ZZDDS.DomainParticipant.CAbiViews{
    .base = .{
        .base = .{ .flat_vtable = nil.nil_entity.vtable },
        .flat_vtable = nil.nil_participant.vtable,
    },
    .flat_vtable = &participant_vtable,
};

fn participantGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_participant_c_abi.get(std.heap.c_allocator, ctx, &nil_zzdds_participant_views);
    const impl: *DomainParticipantImpl = @ptrCast(@alignCast(ctx));
    return impl.c_abi.get(impl.alloc, ctx, &DomainParticipantImpl.views);
}

pub const topic_vtable = ZZDDS.Topic.Vtable{
    .as_topic_description = topicAsTopicDescription,
    .deinit = borrowedDeinit,
    .get_c_abi_handle = topicGetCAbiHandleZzdds,
    .as_Topic = topicAsDds,
};

fn topicAsDds(ctx: *anyopaque) DDS.Topic {
    if (ctx == nil.NIL_PTR) return nil.nil_topic;
    const impl: *TopicImpl = @ptrCast(@alignCast(ctx));
    return impl.toDDSTopic();
}

var nil_zzdds_topic_c_abi: c_abi_handle.CachedCAbiHandle = .{};
const nil_zzdds_topic_views = ZZDDS.Topic.CAbiViews{
    .base = .{
        .base = .{ .flat_vtable = nil.nil_entity.vtable },
        .flat_vtable = nil.nil_topic.vtable,
    },
    .flat_vtable = &topic_vtable,
};

fn topicGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_topic_c_abi.get(std.heap.c_allocator, ctx, &nil_zzdds_topic_views);
    const impl: *TopicImpl = @ptrCast(@alignCast(ctx));
    return impl.c_abi.get(impl.alloc, ctx, &TopicImpl.views);
}

pub const writer_vtable = ZZDDS.DataWriter.Vtable{
    .write_serialized = writerWriteSerialized,
    .set_listener_ex = writerSetListenerEx,
    .deinit = borrowedDeinit,
    .get_c_abi_handle = writerGetCAbiHandleZzdds,
    .as_DataWriter = writerAsDds,
};

fn writerAsDds(ctx: *anyopaque) DDS.DataWriter {
    if (ctx == nil.NIL_PTR) return nil.nil_datawriter;
    const impl: *DataWriterImpl = @ptrCast(@alignCast(ctx));
    return impl.toDDSDataWriter();
}

var nil_zzdds_dw_c_abi: c_abi_handle.CachedCAbiHandle = .{};
const nil_zzdds_dw_views = ZZDDS.DataWriter.CAbiViews{
    .base = .{
        .base = .{ .flat_vtable = nil.nil_entity.vtable },
        .flat_vtable = nil.nil_datawriter.vtable,
    },
    .flat_vtable = &writer_vtable,
};

fn writerGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_dw_c_abi.get(std.heap.c_allocator, ctx, &nil_zzdds_dw_views);
    const impl: *DataWriterImpl = @ptrCast(@alignCast(ctx));
    return impl.c_abi.get(impl.alloc, ctx, &DataWriterImpl.views);
}

pub const reader_vtable = ZZDDS.DataReader.Vtable{
    .take_serialized = readerTakeSerialized,
    .take_next_instance_serialized = readerTakeNextInstanceSerialized,
    .deinit = borrowedDeinit,
    .get_c_abi_handle = readerGetCAbiHandleZzdds,
    .as_DataReader = readerAsDds,
};

fn readerAsDds(ctx: *anyopaque) DDS.DataReader {
    if (ctx == nil.NIL_PTR) return nil.nil_datareader;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(ctx));
    return impl.toDDSDataReader();
}

var nil_zzdds_dr_c_abi: c_abi_handle.CachedCAbiHandle = .{};
const nil_zzdds_dr_views = ZZDDS.DataReader.CAbiViews{
    .base = .{
        .base = .{ .flat_vtable = nil.nil_entity.vtable },
        .flat_vtable = nil.nil_datareader.vtable,
    },
    .flat_vtable = &reader_vtable,
};

fn readerGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_dr_c_abi.get(std.heap.c_allocator, ctx, &nil_zzdds_dr_views);
    const impl: *DataReaderImpl = @ptrCast(@alignCast(ctx));
    return impl.c_abi.get(impl.alloc, ctx, &DataReaderImpl.views);
}

pub export fn zzdds_create_factory() callconv(.c) *anyopaque {
    return zzdds_create_factory_with_allocator(null);
}

/// Same as zzdds_create_factory, but every allocation the factory and
/// everything it ever creates makes (participants, topics, writers, readers,
/// history cache entries, ...) is routed through `allocator` instead of the
/// default std.heap.c_allocator (libc malloc) — every concrete impl already
/// stores `self.alloc`, inherited from whatever created it, so this one
/// injection point is sufficient for the whole Zig core; nothing downstream
/// needs its own separate configuration surface. Pass NULL for the default.
/// `allocator` must outlive the factory returned here and everything created
/// through it — see ZidlAllocator's contract in zidl_allocator.h.
pub export fn zzdds_create_factory_with_allocator(allocator: ?*const zidl_rt.ZidlAllocator) callconv(.c) *anyopaque {
    const r: ZZDDS.DomainParticipantFactory = createFactory(allocator) catch |err| {
        std.log.err("zzdds_create_factory_with_allocator: {}", .{err});
        return factoryGetCAbiHandleZzdds(nil.NIL_PTR);
    };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn zzdds_factory_is_nil(factory: *anyopaque) callconv(.c) bool {
    const f = zidl_rt.unboxAsView(ZZDDS.DomainParticipantFactory, factory);
    return f.ptr == nil.NIL_PTR;
}

pub export fn zzdds_destroy_factory(factory: *anyopaque) callconv(.c) void {
    const f = zidl_rt.unboxAsView(ZZDDS.DomainParticipantFactory, factory);
    if (f.ptr == nil.NIL_PTR) return;
    f.vtable.deinit(f.ptr);
}

/// `WaitSet` and `GuardCondition` are the only two condition-family types
/// with no factory operation in dcps.idl (per OMG spec, both are
/// app-instantiated directly, not obtained from an existing entity/reader —
/// unlike StatusCondition/ReadCondition/QueryCondition, which already have a
/// full C-ABI path via get_statuscondition()/create_readcondition()). These
/// four functions are the hand-written bootstrap for that gap, mirroring
/// zzdds_create_factory()/zzdds_create_factory_with_allocator() exactly.
pub export fn zzdds_create_waitset() callconv(.c) *anyopaque {
    return zzdds_create_waitset_with_allocator(null);
}

/// Same as zzdds_create_waitset, but every allocation the WaitSet itself
/// makes (its `conditions` list) is routed through `allocator` instead of
/// the default std.heap.c_allocator. Pass NULL for the default. `allocator`
/// must outlive the WaitSet returned here — see ZidlAllocator's contract in
/// zidl_allocator.h.
pub export fn zzdds_create_waitset_with_allocator(allocator: ?*const zidl_rt.ZidlAllocator) callconv(.c) *anyopaque {
    const alloc = if (allocator) |a| zidl_rt.toAllocator(a) else std.heap.c_allocator;
    const ws = WaitSetImpl.init(alloc) catch |err| {
        std.log.err("zzdds_create_waitset_with_allocator: {}", .{err});
        return nil.nil_waitset.vtable.get_c_abi_handle(nil.nil_waitset.ptr);
    };
    const r = ws.toDDSWaitSet();
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn zzdds_create_guardcondition() callconv(.c) *anyopaque {
    return zzdds_create_guardcondition_with_allocator(null);
}

/// Same as zzdds_create_guardcondition, but the GuardCondition itself is
/// allocated through `allocator` instead of the default std.heap.c_allocator.
/// Pass NULL for the default. `allocator` must outlive the GuardCondition
/// returned here — see ZidlAllocator's contract in zidl_allocator.h.
pub export fn zzdds_create_guardcondition_with_allocator(allocator: ?*const zidl_rt.ZidlAllocator) callconv(.c) *anyopaque {
    const alloc = if (allocator) |a| zidl_rt.toAllocator(a) else std.heap.c_allocator;
    const gc = GuardConditionImpl.init(alloc) catch |err| {
        std.log.err("zzdds_create_guardcondition_with_allocator: {}", .{err});
        return nil.nil_guardcondition.vtable.get_c_abi_handle(nil.nil_guardcondition.ptr);
    };
    const r = gc.toDDSGuardCondition();
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Mirrors zzdds_factory_is_nil -- lets a caller (e.g. the C++ binding's
/// create_waitset()/create_guardcondition() wrappers, which need to know
/// whether to return an empty shared_ptr) tell a real WaitSet/GuardCondition
/// apart from the boxed nil sentinel zzdds_create_waitset[_with_allocator]
/// returns on allocation failure.
pub export fn zzdds_waitset_is_nil(waitset: *anyopaque) callconv(.c) bool {
    const w = zidl_rt.unboxAs(DDS.WaitSet, waitset);
    return w.ptr == nil.NIL_PTR;
}

pub export fn zzdds_guardcondition_is_nil(guardcondition: *anyopaque) callconv(.c) bool {
    const g = zidl_rt.unboxAsView(DDS.GuardCondition, guardcondition);
    return g.ptr == nil.NIL_PTR;
}

/// WaitSet/GuardCondition have no owning factory to delete them through
/// (see zzdds_create_waitset's doc comment) — mirrors zzdds_destroy_factory.
pub export fn zzdds_destroy_waitset(waitset: *anyopaque) callconv(.c) void {
    const w = zidl_rt.unboxAs(DDS.WaitSet, waitset);
    if (w.ptr == nil.NIL_PTR) return;
    w.vtable.deinit(w.ptr);
}

pub export fn zzdds_destroy_guardcondition(guardcondition: *anyopaque) callconv(.c) void {
    const g = zidl_rt.unboxAsView(DDS.GuardCondition, guardcondition);
    if (g.ptr == nil.NIL_PTR) return;
    g.vtable.deinit(g.ptr);
}

/// Same as the generated `attach_condition`, except `release_fn` (if
/// non-null) fires exactly once when this specific attachment ends —
/// however it ends: an explicit `detach_condition()`, `waitset` being
/// destroyed while `condition` is still attached, or `condition` being
/// destroyed while still attached to `waitset`. No IDL op exists for this
/// (same reason `WaitSet`/`GuardCondition` needed hand-written
/// create/destroy bootstrap above) — the equivalent of `release_listener_data`
/// for a condition attachment, which no C-ABI-visible hook existed for
/// before this: a binding wrapping an attached condition in something with
/// its own lifetime tracking (e.g. a `std::shared_ptr`) previously had no
/// way to learn "this condition just got detached/destroyed" — see
/// zidl/docs/roadmap.md "Binding design review: decision".
///
/// `release_ctx`/`release_fn` are ignored (as if this were a plain
/// `attach_condition()` call) if `condition` is already attached to
/// `waitset` — see `WaitSetImpl.attachConditionWithRelease`'s own doc
/// comment for why a second registration is never silently swapped in.
pub export fn zzdds_waitset_attach_condition_with_release(
    waitset: *anyopaque,
    condition: *anyopaque,
    release_ctx: ?*anyopaque,
    release_fn: ?*const fn (?*anyopaque) callconv(.c) void,
) callconv(.c) DDS.ReturnCode_t {
    const w = zidl_rt.unboxAs(DDS.WaitSet, waitset);
    if (w.ptr == nil.NIL_PTR) return DDS.RETCODE_ERROR;
    const c = zidl_rt.unboxAsView(DDS.Condition, condition);
    const impl: *WaitSetImpl = @ptrCast(@alignCast(w.ptr));
    return impl.attachConditionWithRelease(c, release_ctx, release_fn);
}

/// Explicitly install the process-wide configuration. Must be called before
/// any factory has been created in this process (zzdds_create_factory
/// resolves+commits the ambient default lazily on first use if this was never
/// called) — returns RETCODE_PRECONDITION_NOT_MET if a process-wide config is
/// already installed either way. See config/process.zig.
///
/// NOTE: not currently a safely-callable C entry point — `config`'s pointee
/// (`ZZDDS.ProcessConfig`, the `--zig-generate-toml-config` type used
/// internally) is a plain Zig struct with `[]const u8` string fields, not an
/// `extern struct`; there is no C-ABI-compatible way to actually construct
/// one from outside Zig, and it is (deliberately) not declared in
/// `zzdds_c.h`. Exported for Zig-native callers and internal tests only.
/// Always clones via `std.heap.c_allocator` internally, regardless of the
/// caller — a real gap for a Zig-native caller wanting to avoid libc
/// `malloc` here too, but out of scope for the embedded C/C++ showcase this
/// was written for (see `zzdds_process_configure_from_file` below, which is
/// the actual supported entry point for that).
pub export fn zzdds_process_configure(config: *const ZZDDS.ProcessConfig) callconv(.c) DDS.ReturnCode_t {
    const cloned = config.clone(std.heap.c_allocator) catch return DDS.RETCODE_OUT_OF_RESOURCES;
    process_config.configure(std.heap.c_allocator, cloned) catch return DDS.RETCODE_PRECONDITION_NOT_MET;
    return DDS.RETCODE_OK;
}

/// Resolve `path` as a zzdds TOML config file and install the result as the
/// process-wide configuration, in one step — entirely through `allocator`
/// (NULL for the default, `std.heap.c_allocator`). This is the actual,
/// C/C++-usable way to avoid `zzdds_create_factory_with_allocator`'s ambient
/// lazy-default path (`config/process.zig`'s `getForNewFactory`), which
/// always resolves through `std.heap.c_allocator` regardless of the
/// allocator passed to it: call this first, with the SAME allocator you'll
/// later pass to `zzdds_create_factory_with_allocator`, and the process-wide
/// singleton's own persistent storage will live in that allocator for the
/// rest of the process's lifetime instead.
///
/// Must be called before any factory has been created in this process —
/// returns RETCODE_PRECONDITION_NOT_MET if a process-wide config is already
/// installed (whether from an earlier call to this function, to
/// zzdds_process_configure, or from a factory already having resolved the
/// ambient default), RETCODE_ERROR if `path` doesn't exist or fails to parse
/// (a missing/malformed file is treated as a real error here, not silently
/// ignored — a caller who named a specific path almost certainly wants to
/// know if it didn't work).
pub export fn zzdds_process_configure_from_file(
    path: [*:0]const u8,
    allocator: ?*const zidl_rt.ZidlAllocator,
) callconv(.c) DDS.ReturnCode_t {
    const alloc = if (allocator) |a| zidl_rt.toAllocator(a) else std.heap.c_allocator;
    process_config.configureFromFile(alloc, std.mem.span(path)) catch |err| {
        std.log.err("zzdds_process_configure_from_file: {}", .{err});
        return switch (err) {
            error.AlreadyConfigured => DDS.RETCODE_PRECONDITION_NOT_MET,
            else => DDS.RETCODE_ERROR,
        };
    };
    return DDS.RETCODE_OK;
}

// Every ZZDDS.* → DDS.* upcast (zzdds_X_as_DDS_X) and every DDS-internal
// upcast (DDS_X_as_DDS_Y, where Y is a declared base of X) is now generated
// by zidl directly from the IDL-declared inheritance (`interface Topic :
// DDS::Topic` in zzdds.idl; `interface Topic : Entity, TopicDescription` in
// dcps.idl) via the `as_{Base}` vtable slot / export mechanism — see the
// `.as_*` fields wired into each concrete impl's vtable literal and zidl's
// `docs/roadmap.md`. Only genuine *downcasts* (DDS_X_as_zzdds_X, going from
// a base handle down to a specific derived type) remain hand-written below —
// IDL inheritance can't express "which concrete derived type is this," so
// these still need a runtime vtable-identity check.
//
// `participant_vtable`/`topic_vtable`/`writer_vtable`/`reader_vtable` below
// are `pub` so `raw_ops.zig`'s pure-Zig `asZzdds{Topic,DataWriter,DataReader,
// DomainParticipant}` (the same runtime check, minus the C-ABI handle-boxing
// step) can reference the same canonical vtable instances rather than a
// second, address-distinct copy.

/// Only valid for participants created through a FactoryOwner factory (i.e., via
/// zzdds_create_factory → create_participant_ex). Returns a nil handle for any
/// handle not issued by this implementation.
pub export fn DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory(factory: *anyopaque) callconv(.c) *anyopaque {
    // factory_vtable methods cast ctx to *FactoryOwner, so this conversion is
    // only valid for handles that were originally issued by zzdds_create_factory
    // (which sets vtable = &dds_factory_vtable via the generated as_DomainParticipantFactory export).
    const f = zidl_rt.unboxAsView(DDS.DomainParticipantFactory, factory);
    if (f.vtable != &dds_factory_vtable) return factoryGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.DomainParticipantFactory = .{ .ptr = f.ptr, .vtable = &factory_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Only valid for participants created through a FactoryOwner factory (i.e., via
/// zzdds_create_factory → create_participant_ex). Returns a nil handle for any
/// handle not issued by this implementation.
pub export fn DDS_DomainParticipant_as_zzdds_DomainParticipant(participant: *anyopaque) callconv(.c) *anyopaque {
    const p = zidl_rt.unboxAsView(DDS.DomainParticipant, participant);
    if (p.vtable != &DomainParticipantImpl.vtable) return participantGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.DomainParticipant = .{ .ptr = p.ptr, .vtable = &participant_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Only valid for topics created through a FactoryOwner-owned participant.
/// Returns a nil handle for any handle not issued by this implementation.
pub export fn DDS_Topic_as_zzdds_Topic(topic: *anyopaque) callconv(.c) *anyopaque {
    const t = zidl_rt.unboxAsView(DDS.Topic, topic);
    if (t.vtable != &TopicImpl.topic_vtable) return topicGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.Topic = .{ .ptr = t.ptr, .vtable = &topic_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Only valid for writers created through a FactoryOwner-owned participant.
/// Returns a nil handle for any handle not issued by this implementation.
pub export fn DDS_DataWriter_as_zzdds_DataWriter(writer: *anyopaque) callconv(.c) *anyopaque {
    const w = zidl_rt.unboxAsView(DDS.DataWriter, writer);
    if (w.vtable != &DataWriterImpl.vtable) return writerGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.DataWriter = .{ .ptr = w.ptr, .vtable = &writer_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Only valid for readers created through a FactoryOwner-owned participant.
/// Returns a nil handle for any handle not issued by this implementation.
pub export fn DDS_DataReader_as_zzdds_DataReader(reader: *anyopaque) callconv(.c) *anyopaque {
    const rd = zidl_rt.unboxAsView(DDS.DataReader, reader);
    if (rd.vtable != &DataReaderImpl.vtable) return readerGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.DataReader = .{ .ptr = rd.ptr, .vtable = &reader_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

// ── Condition hierarchy checked downcasts ─────────────────────────────────────
//
// zidl's C backend declares a checked downcast (`<Base>_as_<Derived>`) for
// every direct interface-inheritance edge in dcps.h, documented as
// "returns a null handle when the base object is not an instance of
// <Derived>" -- a literal NULL, unlike the DDS_X_as_zzdds_X nil-sentinel
// conversions above. But zig.zig's native C-API generator only auto-emits
// the always-safe upcast direction (via each concrete impl's own
// `as_{Base}` vtable slot; see emitCApiAsBase) -- it has no visibility into
// which hand-written zzdds-core struct backs a given vtable, so it can't
// generically answer "is this handle actually a GuardCondition". These
// four are hand-written for exactly that reason, mirroring the vtable-
// identity checks waitset.zig's own vtAttach/vtDetach already use
// internally. Condition is the only interface in zzdds with multiple
// concrete sibling implementors, so it's the only hierarchy that needs this.
pub export fn DDS_Condition_as_DDS_GuardCondition(base: *anyopaque) callconv(.c) ?*anyopaque {
    const c = zidl_rt.unboxAsView(DDS.Condition, base);
    if (c.vtable != &GuardConditionImpl.cond_vtable) return null;
    const r: DDS.GuardCondition = .{ .ptr = c.ptr, .vtable = &GuardConditionImpl.vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn DDS_Condition_as_DDS_StatusCondition(base: *anyopaque) callconv(.c) ?*anyopaque {
    const c = zidl_rt.unboxAsView(DDS.Condition, base);
    if (c.vtable != &StatusConditionImpl.cond_vtable) return null;
    const r: DDS.StatusCondition = .{ .ptr = c.ptr, .vtable = &StatusConditionImpl.vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn DDS_Condition_as_DDS_ReadCondition(base: *anyopaque) callconv(.c) ?*anyopaque {
    const c = zidl_rt.unboxAsView(DDS.Condition, base);
    if (c.vtable != &ReadConditionImpl.cond_vtable) return null;
    const r: DDS.ReadCondition = .{ .ptr = c.ptr, .vtable = &ReadConditionImpl.vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Implemented (2026-08-12, binding-design-review Phase 2 follow-up) using the
/// real distinguishing signal the Phase 1 `owner_qc` redirect created: a
/// QueryCondition's ReadCondition-view box unboxes (via `zidl_rt.unboxAsView`)
/// to `&QueryConditionImpl.rc_thunk_vtable`, never `&ReadConditionImpl.vtable`
/// — the two are genuinely distinguishable at the C-ABI level even though
/// QueryConditionImpl embeds (rather than separately allocates) its
/// ReadConditionImpl field and native `toCondition()`/`as_ReadCondition()`
/// calls still return that embedded field's own vtable/ptr directly (see the
/// comment on `QueryConditionImpl` in `waitset.zig` — that sharing is what
/// lets `WaitSetImpl.vtAttach`/`vtDetach` treat a QueryCondition exactly like
/// a ReadCondition, and is untouched by this function). No pointer-arithmetic
/// reversal needed either: per that same `owner_qc` redirect, this box's
/// `.ptr` is already the outer `*QueryConditionImpl`, not `&owner_qc.rc` —
/// unlike a naive expectation, and unlike this function's three siblings
/// above (which all return the input `.ptr` unchanged, since none of them
/// have an embedding wrinkle to correct for).
pub export fn DDS_ReadCondition_as_DDS_QueryCondition(base: *anyopaque) callconv(.c) ?*anyopaque {
    const c = zidl_rt.unboxAsView(DDS.ReadCondition, base);
    if (c.vtable != &QueryConditionImpl.rc_thunk_vtable) return null;
    const r: DDS.QueryCondition = .{ .ptr = c.ptr, .vtable = &QueryConditionImpl.vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

// ── Entity hierarchy checked downcasts ────────────────────────────────────────
//
// Same reasoning as the Condition hierarchy downcasts above: zidl's C backend
// declares `DDS_Entity_as_DDS_<Derived>` in dcps.h for every direct
// Entity-derived interface (Entity is `@shared_c_abi_box`), but generates no
// body -- it has no way to know which concrete zzdds struct backs a given
// `DDS.Entity` view. Left undefined until now because nothing called them: the
// only existing runtime-type-check caller of a `_box_as_most_derived`-style
// dispatcher was the Java backend's sequence-only mechanism (WaitSet's
// `ConditionSeq`, Condition family only). Generalizing that mechanism to
// single-value entity returns/attributes (`StatusCondition::get_entity()`,
// zidl PR #39 Greptile fix) made the Java JNI bridge's own generated
// `Entity_box_as_most_derived` dispatcher call these for the first time --
// caught as an `UnsatisfiedLinkError: undefined symbol` at JNI library load,
// not a compile-time error, since the C-ABI declaration alone was enough to
// satisfy the generated caller's own compilation.
pub export fn DDS_Entity_as_DDS_DomainParticipant(base: *anyopaque) callconv(.c) ?*anyopaque {
    const e = zidl_rt.unboxAsView(DDS.Entity, base);
    if (e.vtable != &DomainParticipantImpl.entity_vtable) return null;
    const r: DDS.DomainParticipant = .{ .ptr = e.ptr, .vtable = &DomainParticipantImpl.vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn DDS_Entity_as_DDS_Topic(base: *anyopaque) callconv(.c) ?*anyopaque {
    const e = zidl_rt.unboxAsView(DDS.Entity, base);
    if (e.vtable != &TopicImpl.entity_vtable) return null;
    const r: DDS.Topic = .{ .ptr = e.ptr, .vtable = &TopicImpl.topic_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn DDS_Entity_as_DDS_Publisher(base: *anyopaque) callconv(.c) ?*anyopaque {
    const e = zidl_rt.unboxAsView(DDS.Entity, base);
    if (e.vtable != &PublisherImpl.entity_vtable) return null;
    const r: DDS.Publisher = .{ .ptr = e.ptr, .vtable = &PublisherImpl.vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn DDS_Entity_as_DDS_Subscriber(base: *anyopaque) callconv(.c) ?*anyopaque {
    const e = zidl_rt.unboxAsView(DDS.Entity, base);
    if (e.vtable != &SubscriberImpl.entity_vtable) return null;
    const r: DDS.Subscriber = .{ .ptr = e.ptr, .vtable = &SubscriberImpl.vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn DDS_Entity_as_DDS_DataWriter(base: *anyopaque) callconv(.c) ?*anyopaque {
    const e = zidl_rt.unboxAsView(DDS.Entity, base);
    if (e.vtable != &DataWriterImpl.entity_vtable) return null;
    const r: DDS.DataWriter = .{ .ptr = e.ptr, .vtable = &DataWriterImpl.vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn DDS_Entity_as_DDS_DataReader(base: *anyopaque) callconv(.c) ?*anyopaque {
    const e = zidl_rt.unboxAsView(DDS.Entity, base);
    if (e.vtable != &DataReaderImpl.entity_vtable) return null;
    const r: DDS.DataReader = .{ .ptr = e.ptr, .vtable = &DataReaderImpl.vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

// ── TopicDescription hierarchy checked downcasts ──────────────────────────────
//
// Same reasoning as the Entity/Condition downcasts above. `MultiTopic` is
// permanently a nil-only stub in zzdds (`participant.zig`'s `vtCreateMultiTopic`
// never returns a real handle -- no `MultiTopicImpl` exists at all), so no real
// `DDS.TopicDescription` view can ever actually be one; the checked downcast
// always returns null rather than comparing against a vtable nothing real ever
// installs.
pub export fn DDS_TopicDescription_as_DDS_Topic(base: *anyopaque) callconv(.c) ?*anyopaque {
    const td = zidl_rt.unboxAsView(DDS.TopicDescription, base);
    if (td.vtable != &TopicImpl.td_vtable) return null;
    const r: DDS.Topic = .{ .ptr = td.ptr, .vtable = &TopicImpl.topic_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn DDS_TopicDescription_as_DDS_ContentFilteredTopic(base: *anyopaque) callconv(.c) ?*anyopaque {
    const td = zidl_rt.unboxAsView(DDS.TopicDescription, base);
    if (td.vtable != &ContentFilteredTopicImpl.td_vtable) return null;
    const r: DDS.ContentFilteredTopic = .{ .ptr = td.ptr, .vtable = &ContentFilteredTopicImpl.cft_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

pub export fn DDS_TopicDescription_as_DDS_MultiTopic(base: *anyopaque) callconv(.c) ?*anyopaque {
    _ = base;
    return null;
}

// ── ContentFilteredTopic matching for C/C++/Java app-side post-filtering ──────
//
// zzdds's own internal CFT filtering (reader.zig's cft_filter) activates
// automatically once TypeSupport.get_field is wired up -- zzdds_register_type_support{,_ctx}
// both take a get_field_fn parameter (see zzdds_c.h), and every generated
// binding (Zig/C/C++/Java) now populates it, so a DataReader created against
// a ContentFilteredTopic filters on its own with no app-side re-checking.
// This export remains as a documented fallback/lower-level tool: for a type
// with no get_field (e.g. a hand-written TypeSupport predating that
// contract), or to test an already-deserialized sample against a filter
// outside the context of a live DataReader (tooling/tests). Exports
// ContentFilteredTopicImpl's own, single, canonical matchSample directly:
// callers supply a field accessor via ctx+get, same shape as filter.zig's own
// FieldAccessor, translated to a C-callable extern struct/fn pointer pair.

/// Discriminated value returned by a caller-supplied `ZzddsFieldGetFn`.
/// kind: 0 = int (`i` valid), 1 = float (`f` valid), 2 = string (`s_ptr`/`s_len` valid).
/// A plain extern struct with one field per variant (rather than a real
/// tagged union) sidesteps any C-ABI union-layout ambiguity across
/// C/C++/JNI callers.
pub const ZzddsFilterValue = extern struct {
    kind: c_int = 0,
    i: i64 = 0,
    f: f64 = 0,
    s_ptr: ?[*]const u8 = null,
    s_len: usize = 0,
};

/// Resolves a named ShapeType-style field (e.g. "color", "x") to a
/// ZzddsFilterValue. Returns false if the field is unknown -- matches
/// filter.zig's FieldAccessor.get returning `null`.
pub const ZzddsFieldGetFn = *const fn (
    ctx: ?*anyopaque,
    field: [*]const u8,
    field_len: usize,
    out: *ZzddsFilterValue,
) callconv(.c) bool;

/// Evaluate `cft`'s filter expression against one sample, via `get` for field
/// lookups. Returns true if the sample passes the filter (should be
/// delivered) -- also true for a NULL/nil `cft` handle or a handle that isn't
/// actually a ContentFilteredTopic, matching filter.zig's own "no filter ==
/// everything passes" convention rather than silently dropping samples on a
/// caller error.
pub export fn zzdds_cft_match_sample(
    cft: *anyopaque,
    ctx: ?*anyopaque,
    get: ZzddsFieldGetFn,
) callconv(.c) bool {
    if (@intFromPtr(cft) == 0) return true;
    const c = zidl_rt.unboxAsView(DDS.ContentFilteredTopic, cft);
    if (nil.isNil(c)) return true;
    if (c.vtable != &ContentFilteredTopicImpl.cft_vtable) return true;
    const impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(c.ptr));

    const Wrap = struct {
        ctx: ?*anyopaque,
        get: ZzddsFieldGetFn,

        fn getField(wctx: *anyopaque, field: []const u8) ?filter_mod.FilterValue {
            const self: *@This() = @ptrCast(@alignCast(wctx));
            var out: ZzddsFilterValue = .{};
            if (!self.get(self.ctx, field.ptr, field.len, &out)) return null;
            return switch (out.kind) {
                0 => filter_mod.FilterValue{ .int = out.i },
                1 => filter_mod.FilterValue{ .float = out.f },
                2 => filter_mod.FilterValue{ .string = (out.s_ptr orelse return null)[0..out.s_len] },
                else => null,
            };
        }
    };
    var wrap = Wrap{ .ctx = ctx, .get = get };
    const accessor = filter_mod.FieldAccessor{ .ctx = &wrap, .get = Wrap.getField };
    return impl.matchSample(accessor);
}

fn createFactory(allocator: ?*const zidl_rt.ZidlAllocator) !ZZDDS.DomainParticipantFactory {
    const alloc = if (allocator) |a| zidl_rt.toAllocator(a) else std.heap.c_allocator;
    const owner = try alloc.create(FactoryOwner);
    errdefer alloc.destroy(owner);
    // Lazily resolves+commits the process-wide config on the very first factory
    // in the process, if the app never called zzdds_process_configure itself.
    // ProcessConfig has exactly one field today, so taking it by value here and
    // never separately deinit-ing proc_cfg is a full, non-leaking ownership
    // transfer into owner.default_config — if ProcessConfig ever grows more
    // fields, whichever of them aren't moved into `owner` will need freeing here.
    const proc_cfg = try process_config.getForNewFactory(alloc);
    owner.* = .{ .alloc = alloc, .default_config = proc_cfg.default_participant_config };
    return .{ .ptr = owner, .vtable = &factory_vtable };
}

/// Each create_participant call allocates an independent ParticipantStack with its
/// own UdpTransport.  UdpTransport.init auto-assigns a participant_id that maps to
/// a unique RTPS port (PB + DG*domain + PG*participant_id + offset), so multiple
/// participants within the same domain on the same host do not collide on port binding.
fn factoryCreateParticipant(
    ctx: *anyopaque,
    domain_id: DDS.DomainId_t,
    qos: *const DDS.DomainParticipantQos,
    a_listener: ?*const DDS.DomainParticipantListener,
    mask: DDS.StatusMask,
) DDS.DomainParticipant {
    if (ctx == nil.NIL_PTR) return nil.nil_participant;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));

    owner.mu.lock();
    var cfg_snap = owner.default_config.clone(owner.alloc) catch |err| {
        owner.mu.unlock();
        std.log.err("create_participant: default_config clone failed: {}", .{err});
        return nil.nil_participant;
    };
    owner.mu.unlock();
    // toRuntimeConfig dupes whatever it needs into its own runtime_config; this
    // snapshot's own memory is never kept past this call either way.
    defer cfg_snap.deinit(owner.alloc);

    const runtime_config = config_generated.toRuntimeConfig(owner.alloc, &cfg_snap) catch |err| {
        std.log.err("create_participant: config conversion failed: {}", .{err});
        return nil.nil_participant;
    };
    return owner.createParticipant(domain_id, qos, a_listener, mask, runtime_config, owner.alloc) catch |err| {
        var cfg = runtime_config;
        config_generated.deinitRuntimeConfig(owner.alloc, &cfg);
        std.log.err("create_participant: {}", .{err});
        return nil.nil_participant;
    };
}

fn factoryCreateParticipantEx(
    ctx: *anyopaque,
    domain_id: DDS.DomainId_t,
    qos: *const DDS.DomainParticipantQos,
    a_listener: ?*const DDS.DomainParticipantListener,
    mask: DDS.StatusMask,
    config: *const ZZDDS.DomainParticipantConfig,
) DDS.DomainParticipant {
    if (ctx == nil.NIL_PTR) return nil.nil_participant;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    const runtime_config = config_generated.toRuntimeConfig(owner.alloc, config) catch |err| {
        std.log.err("create_participant_ex: config conversion failed: {}", .{err});
        return nil.nil_participant;
    };
    return owner.createParticipant(domain_id, qos, a_listener, mask, runtime_config, owner.alloc) catch |err| {
        var cfg = runtime_config;
        config_generated.deinitRuntimeConfig(owner.alloc, &cfg);
        std.log.err("create_participant_ex: {}", .{err});
        return nil.nil_participant;
    };
}

fn factoryDeleteParticipant(ctx: *anyopaque, participant: DDS.DomainParticipant) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    return owner.deleteParticipant(participant);
}

fn factoryLookupParticipant(ctx: *anyopaque, domain_id: DDS.DomainId_t) DDS.DomainParticipant {
    if (ctx == nil.NIL_PTR) return nil.nil_participant;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    return owner.lookupParticipant(domain_id);
}

fn factorySetDefaultParticipantConfig(ctx: *anyopaque, config: *const ZZDDS.DomainParticipantConfig) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    const new_config = config.clone(owner.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
    owner.mu.lock();
    defer owner.mu.unlock();
    owner.default_config.deinit(owner.alloc);
    owner.default_config = new_config;
    // Only affects participants created after this call, same as
    // set_default_participant_qos — no propagation to existing inner factories.
    return DDS.RETCODE_OK;
}

/// Caller contract: any heap-allocated fields in *config must have been
/// allocated with c_allocator (or *config must be zero-initialised) — same
/// contract as get_default_participant_qos. The returned config is always
/// c_allocator-owned too, regardless of which allocator this factory itself
/// was created with (owner.alloc) — decoupling the caller-facing contract
/// from the factory's own internal allocator is what makes repeated calls
/// safe on a factory created via zzdds_create_factory_with_allocator(custom):
/// freeing/filling *config with owner.alloc would free caller-supplied,
/// c_allocator-owned memory through the wrong allocator (or vice versa on a
/// second call), an invalid free / memory corruption either way.
fn factoryGetDefaultParticipantConfig(ctx: *anyopaque, config: *ZZDDS.DomainParticipantConfig) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    owner.mu.lock();
    defer owner.mu.unlock();
    const cloned = owner.default_config.clone(std.heap.c_allocator) catch return DDS.RETCODE_OUT_OF_RESOURCES;
    config.deinit(std.heap.c_allocator);
    config.* = cloned;
    return DDS.RETCODE_OK;
}

fn factorySetDefaultParticipantQos(ctx: *anyopaque, qos: *const DDS.DomainParticipantQos) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    const new_qos = qos.clone(owner.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
    owner.mu.lock();
    defer owner.mu.unlock();
    owner.default_dp_qos.deinit(owner.alloc);
    owner.default_dp_qos = new_qos;
    // Do NOT propagate to existing inner factories here: calling inner vtables
    // while holding owner.mu inverts the lock order (FactoryOwner.mu → inner
    // factory mu).  Each ParticipantStack's inner factory already received the
    // default QoS snapshot at createParticipant time; newly created participants
    // always snapshot the then-current default, so no propagation is needed.
    return DDS.RETCODE_OK;
}

/// Caller contract: any heap-allocated fields in *qos must have been allocated
/// with c_allocator (or *qos must be zero-initialised). The function frees
/// existing content with c_allocator before writing the cloned default —
/// this used to say that but actually free/fill with owner.alloc instead, an
/// allocator mismatch on a factory created via
/// zzdds_create_factory_with_allocator(custom) (same class of bug as
/// factoryGetDefaultParticipantConfig above; found while fixing that one).
fn factoryGetDefaultParticipantQos(ctx: *anyopaque, qos: *DDS.DomainParticipantQos) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    owner.mu.lock();
    defer owner.mu.unlock();
    // Clone first so caller's existing QoS is untouched if OOM occurs.
    const cloned = owner.default_dp_qos.clone(std.heap.c_allocator) catch return DDS.RETCODE_OUT_OF_RESOURCES;
    qos.deinit(std.heap.c_allocator);
    qos.* = cloned;
    return DDS.RETCODE_OK;
}

fn factorySetQos(ctx: *anyopaque, qos: *const DDS.DomainParticipantFactoryQos) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    owner.mu.lock();
    defer owner.mu.unlock();
    owner.factory_qos = qos.*;
    // Do NOT propagate to existing inner factories: calling inner vtables under
    // owner.mu inverts the lock order (FactoryOwner.mu → inner factory mu).
    // New participants snapshot factory_qos at createParticipant time, so no
    // propagation is needed for correctness.
    return DDS.RETCODE_OK;
}

fn factoryGetQos(ctx: *anyopaque, qos: *DDS.DomainParticipantFactoryQos) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    owner.mu.lock();
    defer owner.mu.unlock();
    qos.* = owner.factory_qos;
    return DDS.RETCODE_OK;
}

fn factoryDeinit(ctx: *anyopaque) void {
    if (ctx == nil.NIL_PTR) return;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    owner.deinit();
}

fn participantRegisterTypeSupport(ctx: *anyopaque, type_name: [*:0]const u8) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const impl: *DomainParticipantImpl = @ptrCast(@alignCast(ctx));
    const name = std.mem.span(type_name);
    if (!impl.registerTypeSupport(name, .{
        .ctx = &keyless_type_support_ctx,
        .compute_key_hash = keylessComputeKeyHash,
    })) return DDS.RETCODE_OUT_OF_RESOURCES;
    return DDS.RETCODE_OK;
}

var keyless_type_support_ctx: u8 = 0;

fn keylessComputeKeyHash(_: *anyopaque, _: []const u8) [16]u8 {
    return [_]u8{0} ** 16;
}

fn topicAsTopicDescription(ctx: *anyopaque) DDS.TopicDescription {
    if (ctx == nil.NIL_PTR) return nil.nil_topic_description;
    const impl: *TopicImpl = @ptrCast(@alignCast(ctx));
    return impl.toTopicDescription();
}

fn writerWriteSerialized(
    ctx: *anyopaque,
    kind: ZZDDS.WriteKind,
    key_hash: ?*const ZZDDS.OctetSeq,
    cdr: ?*const ZZDDS.OctetSeq,
) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const impl: *DataWriterImpl = @ptrCast(@alignCast(ctx));
    const payload = octets(cdr) orelse return DDS.RETCODE_BAD_PARAMETER;
    var hash = [_]u8{0} ** 16;
    if (octets(key_hash)) |bytes| {
        const n = @min(bytes.len, hash.len);
        @memcpy(hash[0..n], bytes[0..n]);
    } else if (key_hash != null) {
        return DDS.RETCODE_BAD_PARAMETER;
    }
    const change_kind: history_mod.ChangeKind = switch (kind) {
        .WRITE_ALIVE => .alive,
        .WRITE_DISPOSE => .not_alive_disposed,
        .WRITE_UNREGISTER => if (impl.qos.writer_data_lifecycle.autodispose_unregistered_instances)
            .not_alive_disposed
        else
            .not_alive_unregistered,
        _ => .alive,
    };
    _ = impl.writeRaw(change_kind, time_mod.RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, hash, payload) catch return DDS.RETCODE_ERROR;
    return DDS.RETCODE_OK;
}

fn writerSetListenerEx(
    ctx: *anyopaque,
    a_listener: ?*const ZZDDS.DataWriterListenerEx,
    mask: DDS.StatusMask,
) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const impl: *DataWriterImpl = @ptrCast(@alignCast(ctx));
    impl.setListenerEx(if (a_listener) |l| l.* else ZZDDS.noop_DataWriterListenerEx, mask);
    return DDS.RETCODE_OK;
}

/// NOTE: concurrent readers on the same DataReader must be externally
/// synchronized. Between readRaw (peek) and takeRaw, a concurrent consumer
/// could remove the front sample; takeRaw would then return a different,
/// potentially larger sample silently truncated to peek_len bytes.
fn readerTakeSerialized(ctx: *anyopaque, sample: *ZZDDS.SerializedSample) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(ctx));
    // Peek the first sample non-destructively to pre-allocate the c_allocator
    // buffer before taking.  Without this, an OOM after takeRaw would permanently
    // discard the sample with no recovery path.
    var peek: std.ArrayListUnmanaged(reader_mod.TakenSample) = .empty;
    defer {
        for (peek.items) |s| impl.alloc.free(s.data);
        peek.deinit(impl.alloc);
    }
    impl.readRaw(&peek, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 1, null, null) catch return DDS.RETCODE_ERROR;
    if (peek.items.len == 0) return DDS.RETCODE_NO_DATA;
    const peek_len = peek.items[0].data.len;
    if (peek_len > std.math.maxInt(u32)) return DDS.RETCODE_OUT_OF_RESOURCES;
    const copy = std.heap.c_allocator.alloc(u8, peek_len) catch return DDS.RETCODE_OUT_OF_RESOURCES;
    const taken = impl.takeRaw() orelse {
        std.heap.c_allocator.free(copy);
        return DDS.RETCODE_NO_DATA;
    };
    defer impl.alloc.free(taken.data);
    // A KEEP_LAST-1 writer may have replaced the queued sample between peek and
    // take, making taken.data larger than copy.  Reallocate to avoid truncated CDR.
    // If realloc fails the sample is already consumed — log so the loss is visible.
    var buf = copy;
    if (taken.data.len > copy.len) {
        std.heap.c_allocator.free(copy);
        if (taken.data.len > std.math.maxInt(u32)) {
            std.log.err("readerTakeSerialized: sample permanently lost — payload {d} bytes exceeds u32", .{taken.data.len});
            return DDS.RETCODE_OUT_OF_RESOURCES;
        }
        buf = std.heap.c_allocator.alloc(u8, taken.data.len) catch {
            std.log.err("readerTakeSerialized: sample permanently lost — OOM reallocating {d}-byte buffer after KEEP_LAST-1 replacement", .{taken.data.len});
            return DDS.RETCODE_OUT_OF_RESOURCES;
        };
    }
    @memcpy(buf[0..taken.data.len], taken.data);
    if (taken.data.len < buf.len) {
        // Sample shrank between peek and take; resize down so _maximum == _length.
        buf = std.heap.c_allocator.realloc(buf, taken.data.len) catch buf;
    }
    sample.* = .{
        .cdr = .{ ._maximum = @intCast(buf.len), ._length = @intCast(taken.data.len), ._buffer = buf.ptr, ._release = true },
        .instance_handle = taken.info.instance_handle,
        .valid_data = taken.info.valid_data,
        .instance_state = taken.info.instance_state,
    };
    return DDS.RETCODE_OK;
}

/// NOTE: concurrent readers on the same DataReader must be externally
/// synchronized. If two threads call this concurrently, the peek and take may
/// see different instances; the smaller peek buffer is used for the copy,
/// silently truncating if the taken sample is larger.
fn readerTakeNextInstanceSerialized(
    ctx: *anyopaque,
    previous_instance: DDS.InstanceHandle_t,
    sample: *ZZDDS.SerializedSample,
) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(ctx));
    // Peek (non-destructive) to pre-allocate the copy buffer before removing
    // the sample — same guarantee as readerTakeSerialized.
    const peeked = impl.readNextInstanceRaw(previous_instance) orelse return DDS.RETCODE_NO_DATA;
    defer impl.alloc.free(peeked.data);
    const peek_len = peeked.data.len;
    if (peek_len > std.math.maxInt(u32)) return DDS.RETCODE_OUT_OF_RESOURCES;
    const copy = std.heap.c_allocator.alloc(u8, peek_len) catch return DDS.RETCODE_OUT_OF_RESOURCES;
    const taken = impl.takeNextInstanceRaw(previous_instance) orelse {
        std.heap.c_allocator.free(copy);
        return DDS.RETCODE_NO_DATA;
    };
    defer impl.alloc.free(taken.data);
    // Same KEEP_LAST-1 realloc guard as readerTakeSerialized.
    // If realloc fails the sample is already consumed — log so the loss is visible.
    var buf = copy;
    if (taken.data.len > copy.len) {
        std.heap.c_allocator.free(copy);
        if (taken.data.len > std.math.maxInt(u32)) {
            std.log.err("readerTakeNextInstanceSerialized: sample permanently lost — payload {d} bytes exceeds u32", .{taken.data.len});
            return DDS.RETCODE_OUT_OF_RESOURCES;
        }
        buf = std.heap.c_allocator.alloc(u8, taken.data.len) catch {
            std.log.err("readerTakeNextInstanceSerialized: sample permanently lost — OOM reallocating {d}-byte buffer after KEEP_LAST-1 replacement", .{taken.data.len});
            return DDS.RETCODE_OUT_OF_RESOURCES;
        };
    }
    @memcpy(buf[0..taken.data.len], taken.data);
    if (taken.data.len < buf.len) {
        buf = std.heap.c_allocator.realloc(buf, taken.data.len) catch buf;
    }
    sample.* = .{
        .cdr = .{ ._maximum = @intCast(buf.len), ._length = @intCast(taken.data.len), ._buffer = buf.ptr, ._release = true },
        .instance_handle = taken.info.instance_handle,
        .valid_data = taken.info.valid_data,
        .instance_state = taken.info.instance_state,
    };
    return DDS.RETCODE_OK;
}

const borrowedDeinit = nil.nilDeinit;

fn octets(seq: ?*const ZZDDS.OctetSeq) ?[]const u8 {
    const s = seq orelse return null;
    const buf = s._buffer orelse return if (s._length == 0) &.{} else null;
    return buf[0..s._length];
}

test "zzdds extension factory creates participant with generated default config" {
    const factory = try createFactory(null);
    defer factory.vtable.deinit(factory.ptr);

    const qos = DDS.DomainParticipantQos{};
    const cfg = ZZDDS.DomainParticipantConfig.default();
    const dp = factory.create_participant_ex(203, qos, null, 0, cfg);
    try std.testing.expect(!nil.isNil(dp));

    const ext_dp = zidl_rt.unboxAsView(ZZDDS.DomainParticipant, DDS_DomainParticipant_as_zzdds_DomainParticipant(dp.vtable.get_c_abi_handle(dp.ptr)));
    try std.testing.expectEqual(DDS.RETCODE_OK, ext_dp.register_type_support("KeylessSmoke"));

    const dds_factory = factory.vtable.as_DomainParticipantFactory(factory.ptr);
    try std.testing.expectEqual(DDS.RETCODE_OK, dds_factory.delete_participant(dp));
}

test "zzdds_cft_match_sample: real filter evaluation through the C ABI" {
    const factory = try createFactory(null);
    defer factory.vtable.deinit(factory.ptr);
    const dds_factory = factory.vtable.as_DomainParticipantFactory(factory.ptr);

    const dp = dds_factory.create_participant(204, .{}, null, 0);
    try std.testing.expect(!nil.isNil(dp));
    defer _ = dds_factory.delete_participant(dp);

    const topic = dp.create_topic("CftMatchSampleT", "CftMatchSampleT", .{}, null, 0);
    const cft = dp.create_contentfilteredtopic("CftMatchSampleT_cft", topic, "x = 5", null);
    try std.testing.expect(!nil.isNil(cft));
    defer _ = dp.delete_contentfilteredtopic(cft);
    const cft_handle = cft.vtable.get_c_abi_handle(cft.ptr);

    // A minimal FieldAccessor-shaped C struct resolving only "x", mirroring
    // what a real app (c/shape's ShapeAccessor) supplies for its own fields.
    const Sample = struct {
        x: i64,

        fn get(ctx: ?*anyopaque, field: [*]const u8, field_len: usize, out: *ZzddsFilterValue) callconv(.c) bool {
            const self: *const @This() = @ptrCast(@alignCast(ctx.?));
            if (std.mem.eql(u8, field[0..field_len], "x")) {
                out.* = .{ .kind = 0, .i = self.x };
                return true;
            }
            return false;
        }
    };

    const matching = Sample{ .x = 5 };
    try std.testing.expect(zzdds_cft_match_sample(cft_handle, @constCast(&matching), Sample.get));

    const non_matching = Sample{ .x = 6 };
    try std.testing.expect(!zzdds_cft_match_sample(cft_handle, @constCast(&non_matching), Sample.get));
}
