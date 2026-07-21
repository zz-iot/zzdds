//! C ABI exports for generated zzdds extension interfaces.

const std = @import("std");

const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const zidl_rt = @import("zidl_rt");
const c_abi_handle = @import("../util/c_abi_handle.zig");

const config_generated = @import("../config/generated.zig");
const config_mod = @import("../config/schema.zig");
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
const waitset_mod = @import("../dcps/waitset.zig");
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
    // Two distinct C-ABI views of the same FactoryOwner (ZZDDS.DomainParticipantFactory
    // via factory_vtable, DDS.DomainParticipantFactory via dds_factory_vtable) — each
    // needs its own cache slot, same as any other multi-view concrete impl.
    zzdds_fac_c_abi: c_abi_handle.CachedCAbiHandle = .{},
    dds_fac_c_abi: c_abi_handle.CachedCAbiHandle = .{},

    fn deinit(self: *@This()) void {
        self.zzdds_fac_c_abi.free(self.alloc);
        self.dds_fac_c_abi.free(self.alloc);
        for (self.stacks.items) |stack| stack.deinit();
        self.stacks.deinit(self.alloc);
        self.default_dp_qos.deinit(self.alloc);
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
    .deinit = factoryDeinit,
    .get_c_abi_handle = factoryGetCAbiHandleZzdds,
    .as_DomainParticipantFactory = factoryAsDdsFactory,
};

fn factoryAsDdsFactory(ctx: *anyopaque) DDS.DomainParticipantFactory {
    return .{ .ptr = ctx, .vtable = &dds_factory_vtable };
}

// Nil ZZDDS.* views (ptr == nil.NIL_PTR, but still the real vtable — see
// DDS_..._as_zzdds_... below) need their own dedicated cache, same reasoning
// as nil.zig's own nil-entity singletons: there's no real impl object to hang
// a cache field off of, and std.heap.c_allocator is the fixed default.
var nil_zzdds_fac_c_abi: c_abi_handle.CachedCAbiHandle = .{};

fn factoryGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_fac_c_abi.get(std.heap.c_allocator, ctx, &factory_vtable);
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    return owner.zzdds_fac_c_abi.get(owner.alloc, ctx, &factory_vtable);
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
    return owner.dds_fac_c_abi.get(owner.alloc, ctx, &dds_factory_vtable);
}

const participant_vtable = ZZDDS.DomainParticipant.Vtable{
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

fn participantGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_participant_c_abi.get(std.heap.c_allocator, ctx, &participant_vtable);
    const impl: *DomainParticipantImpl = @ptrCast(@alignCast(ctx));
    return impl.zzdds_participant_c_abi.get(impl.alloc, ctx, &participant_vtable);
}

const topic_vtable = ZZDDS.Topic.Vtable{
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

fn topicGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_topic_c_abi.get(std.heap.c_allocator, ctx, &topic_vtable);
    const impl: *TopicImpl = @ptrCast(@alignCast(ctx));
    return impl.zzdds_topic_c_abi.get(impl.alloc, ctx, &topic_vtable);
}

const writer_vtable = ZZDDS.DataWriter.Vtable{
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

fn writerGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_dw_c_abi.get(std.heap.c_allocator, ctx, &writer_vtable);
    const impl: *DataWriterImpl = @ptrCast(@alignCast(ctx));
    return impl.zzdds_dw_c_abi.get(impl.alloc, ctx, &writer_vtable);
}

const reader_vtable = ZZDDS.DataReader.Vtable{
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

fn readerGetCAbiHandleZzdds(ctx: *anyopaque) *anyopaque {
    if (ctx == nil.NIL_PTR) return nil_zzdds_dr_c_abi.get(std.heap.c_allocator, ctx, &reader_vtable);
    const impl: *DataReaderImpl = @ptrCast(@alignCast(ctx));
    return impl.zzdds_dr_c_abi.get(impl.alloc, ctx, &reader_vtable);
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
    const f = zidl_rt.unboxAs(ZZDDS.DomainParticipantFactory, factory);
    return f.ptr == nil.NIL_PTR;
}

pub export fn zzdds_destroy_factory(factory: *anyopaque) callconv(.c) void {
    const f = zidl_rt.unboxAs(ZZDDS.DomainParticipantFactory, factory);
    if (f.ptr == nil.NIL_PTR) return;
    f.vtable.deinit(f.ptr);
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

/// Only valid for participants created through a FactoryOwner factory (i.e., via
/// zzdds_create_factory → create_participant_ex). Returns a nil handle for any
/// handle not issued by this implementation.
pub export fn DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory(factory: *anyopaque) callconv(.c) *anyopaque {
    // factory_vtable methods cast ctx to *FactoryOwner, so this conversion is
    // only valid for handles that were originally issued by zzdds_create_factory
    // (which sets vtable = &dds_factory_vtable via the generated as_DomainParticipantFactory export).
    const f = zidl_rt.unboxAs(DDS.DomainParticipantFactory, factory);
    if (f.vtable != &dds_factory_vtable) return factoryGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.DomainParticipantFactory = .{ .ptr = f.ptr, .vtable = &factory_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Only valid for participants created through a FactoryOwner factory (i.e., via
/// zzdds_create_factory → create_participant_ex). Returns a nil handle for any
/// handle not issued by this implementation.
pub export fn DDS_DomainParticipant_as_zzdds_DomainParticipant(participant: *anyopaque) callconv(.c) *anyopaque {
    const p = zidl_rt.unboxAs(DDS.DomainParticipant, participant);
    if (p.vtable != &DomainParticipantImpl.vtable) return participantGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.DomainParticipant = .{ .ptr = p.ptr, .vtable = &participant_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Only valid for topics created through a FactoryOwner-owned participant.
/// Returns a nil handle for any handle not issued by this implementation.
pub export fn DDS_Topic_as_zzdds_Topic(topic: *anyopaque) callconv(.c) *anyopaque {
    const t = zidl_rt.unboxAs(DDS.Topic, topic);
    if (t.vtable != &TopicImpl.topic_vtable) return topicGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.Topic = .{ .ptr = t.ptr, .vtable = &topic_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Only valid for writers created through a FactoryOwner-owned participant.
/// Returns a nil handle for any handle not issued by this implementation.
pub export fn DDS_DataWriter_as_zzdds_DataWriter(writer: *anyopaque) callconv(.c) *anyopaque {
    const w = zidl_rt.unboxAs(DDS.DataWriter, writer);
    if (w.vtable != &DataWriterImpl.vtable) return writerGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.DataWriter = .{ .ptr = w.ptr, .vtable = &writer_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

/// Only valid for readers created through a FactoryOwner-owned participant.
/// Returns a nil handle for any handle not issued by this implementation.
pub export fn DDS_DataReader_as_zzdds_DataReader(reader: *anyopaque) callconv(.c) *anyopaque {
    const rd = zidl_rt.unboxAs(DDS.DataReader, reader);
    if (rd.vtable != &DataReaderImpl.vtable) return readerGetCAbiHandleZzdds(nil.NIL_PTR);
    const r: ZZDDS.DataReader = .{ .ptr = rd.ptr, .vtable = &reader_vtable };
    return r.vtable.get_c_abi_handle(r.ptr);
}

fn createFactory(allocator: ?*const zidl_rt.ZidlAllocator) !ZZDDS.DomainParticipantFactory {
    const alloc = if (allocator) |a| zidl_rt.toAllocator(a) else std.heap.c_allocator;
    const owner = try alloc.create(FactoryOwner);
    errdefer alloc.destroy(owner);
    owner.* = .{ .alloc = alloc };
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
    // config = .{} uses schema default literals (no heap allocation); config_deinit_allocator
    // = null tells DomainParticipantImpl.deinit not to call deinitRuntimeConfig.
    // factoryCreateParticipantEx uses runtime-converted config with config_deinit_allocator set.
    return owner.createParticipant(domain_id, qos, a_listener, mask, .{}, null) catch |err| {
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
/// existing content with c_allocator before writing the cloned default.
fn factoryGetDefaultParticipantQos(ctx: *anyopaque, qos: *DDS.DomainParticipantQos) DDS.ReturnCode_t {
    if (ctx == nil.NIL_PTR) return DDS.RETCODE_BAD_PARAMETER;
    const owner: *FactoryOwner = @ptrCast(@alignCast(ctx));
    owner.mu.lock();
    defer owner.mu.unlock();
    // Clone first so caller's existing QoS is untouched if OOM occurs.
    const cloned = owner.default_dp_qos.clone(owner.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
    qos.deinit(owner.alloc);
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

    const ext_dp = zidl_rt.unboxAs(ZZDDS.DomainParticipant, DDS_DomainParticipant_as_zzdds_DomainParticipant(dp.vtable.get_c_abi_handle(dp.ptr)));
    try std.testing.expectEqual(DDS.RETCODE_OK, ext_dp.register_type_support("KeylessSmoke"));

    const dds_factory = factory.vtable.as_DomainParticipantFactory(factory.ptr);
    try std.testing.expectEqual(DDS.RETCODE_OK, dds_factory.delete_participant(dp));
}
