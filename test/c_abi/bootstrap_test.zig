//! Tests for the C-ABI bootstrap shim (src/c_abi/bootstrap.zig).
//!
//! - Factory lifecycle test: zzdds_create_factory + generated create/delete
//! - key-hash/instance-handle lookup tests: use IntraProcessDelivery for
//!   synchronous delivery so no timing sensitivity; samples are written via
//!   the real DDS.DataWriter.write_raw IDL op (see writeRawViaOp), not the
//!   old hand-written bootstrap raw family (superseded -- see
//!   bootstrap.zig's file-level doc comment).
//! - topic_as_description: verified against the CFT TopicDescription vtable.

const std = @import("std");
const test_domain = @import("test_domain");
const ManualRuntime = @import("manual_runtime").ManualRuntime;
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = zzdds.ZZDDS;

const bootstrap = zzdds.c_abi.bootstrap;
const extensions = zzdds.c_abi.extensions;
const allocator_adapter = zzdds.c_abi.allocator_adapter;
const zidl_bindings = @import("zidl_bindings");
const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const MemoryTransport = zzdds.intraprocess.MemoryTransport;
const DirectDiscovery = zzdds.intraprocess.DirectDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const nil = zzdds.dcps;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;

/// Constructs a genuinely NULL *anyopaque -- what a real C caller passing
/// NULL for a handle parameter actually produces at the `.c` calling
/// convention boundary. `@ptrFromInt(0)` alone is rejected by Zig's own
/// pointer-safety checks (comptime and runtime) since `*anyopaque` is a
/// non-optional, non-allowzero type; `@setRuntimeSafety(false)` opts out of
/// that check specifically to construct the exact input the ABI boundary
/// itself does not (and cannot) enforce against.
fn makeNullHandle() *anyopaque {
    @setRuntimeSafety(false);
    var addr: usize = 0;
    addr += 0;
    return @ptrFromInt(addr);
}
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const GuardConditionImpl = zzdds.dcps.GuardConditionImpl;
const StatusConditionImpl = zzdds.dcps.StatusConditionImpl;
const ReadConditionImpl = zzdds.dcps.ReadConditionImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;
const generated_config = zzdds.generated_config;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history = zzdds.rtps.history;

// CDR_LE encapsulation header + 1-byte payload.
const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAB };
const KEY_HASH = std.mem.zeroes([16]u8);

// ── Intraprocess fixture ──────────────────────────────────────────────────────

const Fixture = struct {
    alloc: std.mem.Allocator,
    mr: *ManualRuntime,
    delivery: IntraProcessDelivery,
    t_w: *MemoryTransport,
    d_w: *DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    pub_w: DDS.Publisher,
    topic_w: DDS.Topic,
    t_r: *MemoryTransport,
    d_r: *DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,
    /// Boxed C-ABI handles from the most recent makeWriterReader() call --
    /// what a real C caller actually has (zzdds_c.h's DDS_DataWriter/
    /// DDS_DataReader are opaque pointers, not the native {ptr, vtable} fat
    /// pointer). Freed in deinit(); at most one pair per Fixture instance in
    /// this test file, so tracking "the last one" is sufficient.
    dw_box: ?*anyopaque = null,
    dr_box: ?*anyopaque = null,

    fn init(alloc: std.mem.Allocator) !Fixture {
        const mr = try std.heap.page_allocator.create(ManualRuntime);
        errdefer std.heap.page_allocator.destroy(mr);
        mr.init();
        errdefer mr.deinit();
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();

        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_w.deinit();
        const dp_w = factory_w.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("BootTopic", "BootType", .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("BootTopic", "BootType", .{}, null, 0);

        return .{
            .mr = mr,
            .alloc = alloc,
            .delivery = delivery,
            .t_w = t_w,
            .d_w = d_w,
            .factory_w = factory_w,
            .dp_w = dp_w,
            .pub_w = pub_w,
            .topic_w = topic_w,
            .t_r = t_r,
            .d_r = d_r,
            .factory_r = factory_r,
            .dp_r = dp_r,
            .sub_r = sub_r,
            .topic_r = topic_r,
        };
    }

    fn deinit(self: *Fixture) void {
        if (self.dw_box) |b| zidl_bindings.freeEntityBox(self.alloc, b);
        if (self.dr_box) |b| zidl_bindings.freeEntityBox(self.alloc, b);
        _ = self.factory_w.toDDSFactory().delete_participant(self.dp_w);
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        self.mr.settle();
        self.factory_w.deinit();
        self.factory_r.deinit();
        self.d_w.deinit();
        self.d_r.deinit();
        self.t_w.deinit();
        self.t_r.deinit();
        self.delivery.deinit();
        self.mr.deinit();
        std.heap.page_allocator.destroy(self.mr);
    }

    /// Delivers what was sent so far (a no-op on the default build).
    fn settle(self: *Fixture) void {
        self.mr.settle();
    }

    /// Returns both the native fat-pointer structs (dw/dr -- for calling
    /// vtable methods directly, as some tests do) and their *boxed* C-ABI
    /// handle equivalents (dw_boxed/dr_boxed -- what a real C caller actually
    /// has and must pass to bootstrap.zzdds_register_instance_raw/
    /// zzdds_get_key_value_writer/etc; zzdds_c.h's DDS_DataWriter/
    /// DDS_DataReader are opaque pointers, not the native struct).
    /// Exercising the bootstrap functions with the native structs directly
    /// previously masked a real C-ABI signature mismatch bug (see
    /// bootstrap.zig's file-level doc comment).
    fn makeWriterReader(self: *Fixture) struct { dw: DDS.DataWriter, dr: DDS.DataReader, dw_boxed: *anyopaque, dr_boxed: *anyopaque } {
        const td = @as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr = self.sub_r.create_datareader(td, .{}, null, 0);
        const dw = self.pub_w.create_datawriter(self.topic_w, .{}, null, 0);
        // Matching runs on the runtime too.
        self.mr.settle();
        const dw_box = zidl_bindings.boxEntity(self.alloc, dw.ptr, &DataWriterImpl.views) catch @panic("test OOM boxing DataWriter");
        const dr_box = zidl_bindings.boxEntity(self.alloc, dr.ptr, &DataReaderImpl.views) catch @panic("test OOM boxing DataReader");
        self.dw_box = dw_box;
        self.dr_box = dr_box;
        return .{ .dw = dw, .dr = dr, .dw_boxed = dw_box, .dr_boxed = dr_box };
    }
};

// ── Factory lifecycle ─────────────────────────────────────────────────────────

test "support factory: destroy_factory is safe on nil handle" {
    const alloc = testing.allocator;
    // Must use the real ZZDDS.DomainParticipantFactory.Vtable here, not some
    // other interface's vtable — zzdds_destroy_factory checks ptr == NIL_PTR
    // before touching .vtable today, but boxing with a mismatched vtable type
    // would be unsound if that guard ever moved.
    const boxed = try zidl_bindings.boxEntity(alloc, zzdds.dcps.NIL_PTR, &extensions.factory_views);
    defer zidl_bindings.freeEntityBox(alloc, boxed);
    extensions.zzdds_destroy_factory(boxed); // must not crash or call deinit
}

test "support factory: generated create_participant and delete_participant" {
    const ext_factory_boxed = extensions.zzdds_create_factory().?;
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, ext_factory_boxed);

    const factory = ext_factory.vtable.as_DomainParticipantFactory(ext_factory.ptr);
    const dp = DDS_DomainParticipantFactory_create_participant_for_test(factory, test_domain.get(), null);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
}

test "support factory: generated create_participant_ex uses config defaults" {
    const ext_factory_boxed = extensions.zzdds_create_factory().?;
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, ext_factory_boxed);

    const cfg = ZZDDS.DomainParticipantConfig.default();
    const qos = DDS.DomainParticipantQos{};
    const dp = ext_factory.create_participant_ex(test_domain.get(), qos, null, 0, cfg);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);

    const factory = ext_factory.vtable.as_DomainParticipantFactory(ext_factory.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
}

// ── zzdds_create_factory_with_allocator ────────────────────────────────────────
//
// Proves the C-ABI allocator injection actually reaches every downstream
// allocation (factory bootstrap, transport, discovery, participant), not just
// that the new export compiles. TrackingCtx forwards every call to
// std.testing.allocator's raw vtable functions, so Zig's own leak/double-free
// detection for `testing.allocator` continues to apply transparently across
// the C-ABI round trip — a missing free anywhere in the injected path would
// fail this test the same way any other testing.allocator leak would.

const TrackingCtx = struct {
    child: std.mem.Allocator,
    // Atomic: a real DomainParticipantImpl (RTPS receive threads, timer thread,
    // etc.) allocates/frees through this same injected allocator concurrently
    // with the main thread, so plain `usize += 1` here is a genuine data race
    // (caught by ThreadSanitizer, not just theoretical).
    alloc_calls: std.atomic.Value(usize) = .init(0),
    resize_calls: std.atomic.Value(usize) = .init(0),
    free_calls: std.atomic.Value(usize) = .init(0),
};

// The actual std.mem.Allocator <-> ZidlAllocator forwarding logic lives in
// the promoted src/c_abi/allocator_adapter.zig; these trampolines only add
// the call counting this test needs, delegating everything else to it.
fn trackAlloc(ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?[*]u8 {
    const self: *TrackingCtx = @ptrCast(@alignCast(ctx.?));
    _ = self.alloc_calls.fetchAdd(1, .monotonic);
    const inner = allocator_adapter.fromAllocator(&self.child);
    return inner.alloc(inner.ctx, len, alignment);
}

fn trackResize(ctx: ?*anyopaque, ptr: ?[*]u8, old_len: usize, new_len: usize, alignment: usize) callconv(.c) bool {
    const self: *TrackingCtx = @ptrCast(@alignCast(ctx.?));
    _ = self.resize_calls.fetchAdd(1, .monotonic);
    const inner = allocator_adapter.fromAllocator(&self.child);
    return inner.resize(inner.ctx, ptr, old_len, new_len, alignment);
}

fn trackFree(ctx: ?*anyopaque, ptr: ?[*]u8, len: usize, alignment: usize) callconv(.c) void {
    const self: *TrackingCtx = @ptrCast(@alignCast(ctx.?));
    _ = self.free_calls.fetchAdd(1, .monotonic);
    const inner = allocator_adapter.fromAllocator(&self.child);
    inner.free(inner.ctx, ptr, len, alignment);
}

test "support factory: zzdds_create_factory_with_allocator(NULL) matches zzdds_create_factory" {
    const ext_factory_boxed = extensions.zzdds_create_factory_with_allocator(null).?;
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, ext_factory_boxed);
    try testing.expect(ext_factory.ptr != zzdds.dcps.NIL_PTR);
}

test "support factory: zzdds_create_factory_with_allocator routes every allocation through the caller's allocator" {
    var track = TrackingCtx{ .child = testing.allocator };
    const c_alloc = zidl_bindings.ZidlAllocator{
        .ctx = &track,
        .alloc = trackAlloc,
        .resize = trackResize,
        .free = trackFree,
    };

    const ext_factory_boxed = extensions.zzdds_create_factory_with_allocator(&c_alloc).?;
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, ext_factory_boxed);

    // Bootstrapping the factory itself (FactoryOwner) already allocates.
    try testing.expect(track.alloc_calls.load(.monotonic) > 0);
    const calls_after_bootstrap = track.alloc_calls.load(.monotonic);

    // Creating a participant spins up a real UdpTransport + SpdpSedpDiscovery +
    // DomainParticipantFactoryImpl/DomainParticipantImpl stack (ParticipantStack.init)
    // — every one of those allocates, and every one must inherit the injected
    // allocator, not silently fall back to std.heap.c_allocator.
    const cfg = ZZDDS.DomainParticipantConfig.default();
    const qos = DDS.DomainParticipantQos{};
    const dp = ext_factory.create_participant_ex(test_domain.get(), qos, null, 0, cfg);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    try testing.expect(track.alloc_calls.load(.monotonic) > calls_after_bootstrap);

    const factory = ext_factory.vtable.as_DomainParticipantFactory(ext_factory.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
    try testing.expect(track.free_calls.load(.monotonic) > 0);
}

test "support factory: get_default_participant_config on a custom-allocator factory doesn't mismatch the caller's c_allocator-owned input" {
    var track = TrackingCtx{ .child = testing.allocator };
    const c_alloc = zidl_bindings.ZidlAllocator{
        .ctx = &track,
        .alloc = trackAlloc,
        .resize = trackResize,
        .free = trackFree,
    };
    const ext_factory_boxed = extensions.zzdds_create_factory_with_allocator(&c_alloc).?;
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, ext_factory_boxed);

    // Simulate a caller-supplied config whose existing content came from
    // c_allocator (e.g. zzdds_DomainParticipantConfig_default()'s strdup),
    // per the documented caller contract -- deliberately NOT from this
    // factory's own (testing.allocator-tracked) custom allocator. Before the
    // fix, get_default_participant_config freed *config with owner.alloc
    // (the factory's custom allocator) instead of c_allocator, which
    // testing.allocator's own tracking would reject as an invalid free.
    var config = ZZDDS.DomainParticipantConfig{};
    // The flag marks the struct whose strings the caller allocated, so
    // freeing it frees both of them: every string there must be owned.
    config.transport.udp._toml_applied = true;
    config.transport.udp.multicast_group_v4 = try std.heap.c_allocator.dupe(u8, "external-default");
    config.transport.udp.multicast_group_v6 = try std.heap.c_allocator.dupe(u8, "ff05::1");
    defer config.deinit(std.heap.c_allocator);

    try testing.expectEqual(DDS.RETCODE_OK, ext_factory.get_default_participant_config(&config));
    // The returned config must be genuinely c_allocator-owned -- not
    // owner.alloc-owned -- so the `defer` above (and any subsequent call)
    // frees it correctly regardless of the factory's own allocator.
    try testing.expectEqualStrings("239.255.0.1", config.transport.udp.multicast_group_v4);
}

test "support factory: get_default_participant_qos on a custom-allocator factory doesn't mismatch the caller's c_allocator-owned input" {
    var track = TrackingCtx{ .child = testing.allocator };
    const c_alloc = zidl_bindings.ZidlAllocator{
        .ctx = &track,
        .alloc = trackAlloc,
        .resize = trackResize,
        .free = trackFree,
    };
    const ext_factory_boxed = extensions.zzdds_create_factory_with_allocator(&c_alloc).?;
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, ext_factory_boxed);
    const factory = ext_factory.vtable.as_DomainParticipantFactory(ext_factory.ptr);

    // Same scenario as the config test above, for the sibling QoS getter,
    // which had the identical bug (and an already-incorrect doc comment
    // claiming it didn't).
    var qos = DDS.DomainParticipantQos{};
    qos.user_data.value = .{ ._buffer = (try std.heap.c_allocator.dupe(u8, "abc")).ptr, ._length = 3, ._maximum = 3, ._release = true };
    defer qos.deinit(std.heap.c_allocator);

    try testing.expectEqual(DDS.RETCODE_OK, factory.get_default_participant_qos(&qos));
}

// ── get_allocator ────────────────────────────────────────────────────────────
//
// Regression coverage for the `get_allocator` vtable slot added across every
// entity interface (generated-class-lifecycle-design.md's "Allocator
// resolution") -- previously zero tests anywhere in this suite called
// `.vtable.get_allocator(...)` on anything, native or C-ABI-layer, real or
// nil. Each of these tests exercises a *different* set of vtable literals
// (native impl vtables via Fixture, extensions.zig's separate C-ABI-layer
// vtables via zzdds_create_factory_with_allocator, nil singletons), since the
// same-looking `get_allocator = xGetAllocator` addition was made
// independently in each place, not generated from one shared site -- a typo
// in any one of them (wrong impl type in the cast, wrong nil constant) would
// compile fine and silently return the wrong allocator; only a real
// assertion catches that class of mistake.

test "get_allocator: native entity vtables return the allocator each entity was constructed with" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    try testing.expectEqual(alloc, fx.dp_w.vtable.get_allocator(fx.dp_w.ptr));
    try testing.expectEqual(alloc, fx.pub_w.vtable.get_allocator(fx.pub_w.ptr));
    try testing.expectEqual(alloc, fx.topic_w.vtable.get_allocator(fx.topic_w.ptr));
    try testing.expectEqual(alloc, fx.sub_r.vtable.get_allocator(fx.sub_r.ptr));
    try testing.expectEqual(alloc, pair.dw.vtable.get_allocator(pair.dw.ptr));
    try testing.expectEqual(alloc, pair.dr.vtable.get_allocator(pair.dr.ptr));
}

test "get_allocator: extensions-layer C-ABI vtables return the injected custom allocator, not a process-wide guess" {
    var track = TrackingCtx{ .child = testing.allocator };
    const c_alloc = zidl_bindings.ZidlAllocator{
        .ctx = &track,
        .alloc = trackAlloc,
        .resize = trackResize,
        .free = trackFree,
    };
    // toAllocator is a pure, allocation-free function of its input pointer
    // (see zidl_bindings's own doc comment) -- calling it again here with the same
    // &c_alloc reconstructs a byte-identical std.mem.Allocator to whatever
    // extensions.zig built internally, making expectEqual a precise check,
    // not an approximation.
    const expected = zidl_bindings.toAllocator(&c_alloc);

    const ext_factory_boxed = extensions.zzdds_create_factory_with_allocator(&c_alloc).?;
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, ext_factory_boxed);
    try testing.expectEqual(expected, ext_factory.vtable.get_allocator(ext_factory.ptr));

    const factory = ext_factory.vtable.as_DomainParticipantFactory(ext_factory.ptr);
    try testing.expectEqual(expected, factory.vtable.get_allocator(factory.ptr));

    const cfg = ZZDDS.DomainParticipantConfig.default();
    const qos = DDS.DomainParticipantQos{};
    const dp = ext_factory.create_participant_ex(test_domain.get(), qos, null, 0, cfg);
    defer _ = factory.delete_participant(dp);
    try testing.expectEqual(expected, dp.vtable.get_allocator(dp.ptr));

    const topic = dp.create_topic("GAllocTopic", "GAllocType", .{}, null, 0);
    try testing.expectEqual(expected, topic.vtable.get_allocator(topic.ptr));

    const pub_ent = dp.create_publisher(.{}, null, 0);
    const dw = pub_ent.create_datawriter(topic, .{}, null, 0);
    try testing.expectEqual(expected, dw.vtable.get_allocator(dw.ptr));

    const sub_ent = dp.create_subscriber(.{}, null, 0);
    const td = topic.vtable.as_TopicDescription(topic.ptr);
    const dr = sub_ent.create_datareader(td, .{}, null, 0);
    try testing.expectEqual(expected, dr.vtable.get_allocator(dr.ptr));

    // The above all resolve through the *native* src/dcps/*.zig vtables
    // (already covered by the native-entity test above) -- create_topic /
    // create_datawriter / create_datareader / create_participant_ex all
    // return plain DDS.* fat pointers per dcps.idl, never the ZZDDS.* wrapper
    // types directly. Exercise extensions.zig's *own*, separately-defined
    // participant_vtable / topic_vtable / writer_vtable / reader_vtable (each
    // with its own get_allocator, e.g. participantGetAllocator at
    // extensions.zig) via the DDS_X_as_zzdds_X checked-downcast path a real
    // C caller would use to reach the ZZDDS namespace -- otherwise a typo'd
    // get_allocator in any of those four vtable literals would compile fine
    // and go completely unexercised by this suite.
    const zdp_boxed = extensions.DDS_DomainParticipant_as_zzdds_DomainParticipant(dp.vtable.get_c_abi_handle(dp.ptr)).?;
    const zdp = zidl_bindings.unboxAsView(ZZDDS.DomainParticipant, zdp_boxed);
    try testing.expectEqual(expected, zdp.vtable.get_allocator(zdp.ptr));

    const ztopic_boxed = extensions.DDS_Topic_as_zzdds_Topic(topic.vtable.get_c_abi_handle(topic.ptr)).?;
    const ztopic = zidl_bindings.unboxAsView(ZZDDS.Topic, ztopic_boxed);
    try testing.expectEqual(expected, ztopic.vtable.get_allocator(ztopic.ptr));

    const zdw_boxed = extensions.DDS_DataWriter_as_zzdds_DataWriter(dw.vtable.get_c_abi_handle(dw.ptr)).?;
    const zdw = zidl_bindings.unboxAsView(ZZDDS.DataWriter, zdw_boxed);
    try testing.expectEqual(expected, zdw.vtable.get_allocator(zdw.ptr));

    const zdr_boxed = extensions.DDS_DataReader_as_zzdds_DataReader(dr.vtable.get_c_abi_handle(dr.ptr)).?;
    const zdr = zidl_bindings.unboxAsView(ZZDDS.DataReader, zdr_boxed);
    try testing.expectEqual(expected, zdr.vtable.get_allocator(zdr.ptr));

    const zpub_boxed = extensions.DDS_Publisher_as_zzdds_Publisher(pub_ent.vtable.get_c_abi_handle(pub_ent.ptr)).?;
    const zpub = zidl_bindings.unboxAsView(ZZDDS.Publisher, zpub_boxed);
    try testing.expectEqual(expected, zpub.vtable.get_allocator(zpub.ptr));

    const zsub_boxed = extensions.DDS_Subscriber_as_zzdds_Subscriber(sub_ent.vtable.get_c_abi_handle(sub_ent.ptr)).?;
    const zsub = zidl_bindings.unboxAsView(ZZDDS.Subscriber, zsub_boxed);
    try testing.expectEqual(expected, zsub.vtable.get_allocator(zsub.ptr));

    const cft = dp.create_contentfilteredtopic("GAllocCft", topic, "", &DDS.StringSeq{});
    const zcft_boxed = extensions.DDS_ContentFilteredTopic_as_zzdds_ContentFilteredTopic(cft.vtable.get_c_abi_handle(cft.ptr)).?;
    const zcft = zidl_bindings.unboxAsView(ZZDDS.ContentFilteredTopic, zcft_boxed);
    try testing.expectEqual(expected, zcft.vtable.get_allocator(zcft.ptr));
}

test "get_allocator: every nil singleton returns the fixed nil allocator" {
    const nd = zzdds.dcps;
    inline for (.{
        nd.nil_status_condition,
        nd.nil_entity,
        nd.nil_participant,
        nd.nil_publisher,
        nd.nil_subscriber,
        nd.nil_datawriter,
        nd.nil_datareader,
        nd.nil_topic_description,
        nd.nil_topic,
        nd.nil_cft,
        nd.nil_multitopic,
        nd.nil_condition,
        nd.nil_readcondition,
        nd.nil_querycondition,
        nd.nil_guardcondition,
        nd.nil_waitset,
        nd.nil_factory,
    }) |nil_handle| {
        // Every nil singleton is documented to deliberately share one fixed
        // std.heap.c_allocator, not a real per-instance one (no real impl
        // object exists to draw one from) -- see nil.zig's nilGetAllocator.
        try testing.expectEqual(std.heap.c_allocator, nil_handle.vtable.get_allocator(nil_handle.ptr));
    }
}

// An allocator that always fails, for the constructors' failure path.

fn alwaysFailAlloc(ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = len;
    _ = alignment;
    return null;
}
fn alwaysFailResize(ctx: ?*anyopaque, ptr: ?[*]u8, old_len: usize, new_len: usize, alignment: usize) callconv(.c) bool {
    _ = ctx;
    _ = ptr;
    _ = old_len;
    _ = new_len;
    _ = alignment;
    return false;
}
fn alwaysFailFree(ctx: ?*anyopaque, ptr: ?[*]u8, len: usize, alignment: usize) callconv(.c) void {
    _ = ctx;
    _ = ptr;
    _ = len;
    _ = alignment;
}

// ── Generated constructors (dcps.idl @constructor/@destructor) ───────────────

/// The generated C constructors, which only a build generating the C ABI
/// (-Dc-binding) exports; resolved only when a test runs.
const GeneratedCtors = struct {
    const H = ?*anyopaque;
    const A = ?*const zidl_bindings.ZidlAllocator;
    const available = @hasDecl(DDS.WaitSet, "exportCAbiConstructors");
    fn get(comptime T: type, comptime name: []const u8) T {
        return @extern(T, .{ .name = name });
    }
    const ws_create = get(*const fn () callconv(.c) H, "DDS_WaitSet_create");
    const ws_create_with = get(*const fn (A) callconv(.c) H, "DDS_WaitSet_create_with_allocator");
    const ws_destroy = get(*const fn (*anyopaque) callconv(.c) DDS.ReturnCode_t, "DDS_WaitSet_destroy");
    const ws_attach = get(*const fn (*anyopaque, H) callconv(.c) DDS.ReturnCode_t, "DDS_WaitSet_attach_condition");
    const gc_create = get(*const fn () callconv(.c) H, "DDS_GuardCondition_create");
    const gc_create_with = get(*const fn (A) callconv(.c) H, "DDS_GuardCondition_create_with_allocator");
    const gc_destroy = get(*const fn (*anyopaque) callconv(.c) DDS.ReturnCode_t, "DDS_GuardCondition_destroy");
    const gc_as_condition = get(*const fn (*anyopaque) callconv(.c) H, "DDS_GuardCondition_as_DDS_Condition");
};

fn createAndDestroyThroughCAbi() !void {
    const C = GeneratedCtors;
    const ws = C.ws_create().?;
    const gc = C.gc_create().?;
    try testing.expectEqual(DDS.RETCODE_OK, C.ws_attach(ws, C.gc_as_condition(gc)));
    // Destroying an attached condition detaches it from the WaitSet first.
    try testing.expectEqual(DDS.RETCODE_OK, C.gc_destroy(gc));
    try testing.expectEqual(DDS.RETCODE_OK, C.ws_destroy(ws));
}

test "generated constructors: WaitSet and GuardCondition are created and destroyed through the C ABI" {
    if (comptime GeneratedCtors.available) try createAndDestroyThroughCAbi() else return error.SkipZigTest;
}

fn allocatorFormsThroughCAbi() !void {
    const C = GeneratedCtors;
    var track = TrackingCtx{ .child = testing.allocator };
    const c_alloc = zidl_bindings.ZidlAllocator{
        .ctx = &track,
        .alloc = trackAlloc,
        .resize = trackResize,
        .free = trackFree,
    };
    const expected = zidl_bindings.toAllocator(&c_alloc);

    const ws_boxed = C.ws_create_with(&c_alloc).?;
    const ws = zidl_bindings.unboxAs(DDS.WaitSet, ws_boxed);
    try testing.expectEqual(expected, ws.vtable.get_allocator(ws.ptr));
    const gc_boxed = C.gc_create_with(&c_alloc).?;
    const gc = zidl_bindings.unboxAsView(DDS.GuardCondition, gc_boxed);
    try testing.expectEqual(expected, gc.vtable.get_allocator(gc.ptr));
    // Attaching grows the WaitSet's condition list through the same allocator.
    const calls_after_create = track.alloc_calls.load(.monotonic);
    try testing.expectEqual(DDS.RETCODE_OK, C.ws_attach(ws_boxed, C.gc_as_condition(gc_boxed)));
    try testing.expect(track.alloc_calls.load(.monotonic) > calls_after_create);
    try testing.expectEqual(DDS.RETCODE_OK, C.gc_destroy(gc_boxed));
    try testing.expectEqual(DDS.RETCODE_OK, C.ws_destroy(ws_boxed));
    try testing.expect(track.alloc_calls.load(.monotonic) > 0);
    try testing.expectEqual(track.alloc_calls.load(.monotonic), track.free_calls.load(.monotonic));

    const failing_alloc = zidl_bindings.ZidlAllocator{
        .ctx = undefined,
        .alloc = alwaysFailAlloc,
        .resize = alwaysFailResize,
        .free = alwaysFailFree,
    };
    try testing.expect(C.ws_create_with(&failing_alloc) == null);
    try testing.expect(C.gc_create_with(&failing_alloc) == null);
}

test "generated constructors: the allocator forms allocate through it, and a failed one returns NULL" {
    if (comptime GeneratedCtors.available) try allocatorFormsThroughCAbi() else return error.SkipZigTest;
}

test "generated constructors: the nil sentinel refuses destroy" {
    const nd = zzdds.dcps;
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, nd.nil_waitset.vtable.destroy(nd.nil_waitset.ptr));
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, nd.nil_guardcondition.vtable.destroy(nd.nil_guardcondition.ptr));
}

fn DDS_DomainParticipantFactory_create_participant_for_test(
    factory: DDS.DomainParticipantFactory,
    domain_id: DDS.DomainId_t,
    listener: ?*const DDS.DomainParticipantListener,
) DDS.DomainParticipant {
    const qos = DDS.DomainParticipantQos{};
    return factory.vtable.create_participant(factory.ptr, domain_id, &qos, listener, 0);
}

// ── topic_as_description ──────────────────────────────────────────────────────

test "bootstrap: topic_as_description returns TopicDescription with correct name" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // zzdds_topic_as_description takes/returns *boxed* C-ABI handles, matching
    // what a real C caller has (zzdds_c.h's DDS_Topic/DDS_TopicDescription are
    // opaque pointers, not the native {ptr, vtable} fat pointer) -- box
    // fx.topic_w the same way, then unbox the result to call its vtable.
    const topic_w_boxed = try zidl_bindings.boxEntity(alloc, fx.topic_w.ptr, &TopicImpl.views);
    defer zidl_bindings.freeEntityBox(alloc, topic_w_boxed);

    const td_boxed = bootstrap.zzdds_topic_as_description(topic_w_boxed).?;
    const td = zidl_bindings.unboxAsView(DDS.TopicDescription, td_boxed);
    try testing.expectEqualStrings("BootTopic", std.mem.span(td.vtable.get_name(td.ptr)));
}

test "bootstrap: topic_as_description of NULL is NULL" {
    // At the C ABI, NULL is every interface's nil, both ways.
    try testing.expect(bootstrap.zzdds_topic_as_description(null) == null);
}

// ── register_instance_raw ─────────────────────────────────────────────────────

test "bootstrap: register_instance_raw gives a key one handle per writer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const h1 = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH);
    try testing.expect(h1 != 0);
    try testing.expectEqual(h1, bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH));
    var other_key: [16]u8 = undefined;
    @memset(&other_key, 0x01);
    const h3 = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &other_key);
    try testing.expect(h3 != 0 and h1 != h3);
}

// ── write_raw_w_timestamp ─────────────────────────────────────────────────────

// ── get_key_value_writer / lookup_instance_writer ─────────────────────────────

/// Writes `payload` for `key_hash` through the real `DDS.DataWriter.write_raw`
/// IDL op (the replacement for the deleted `zzdds_write_raw` bootstrap
/// export), using the fixture pair's unboxed `pair.dw` fat pointer.
fn writeRawViaOp(dw: DDS.DataWriter, key_hash: [16]u8, payload: []const u8) void {
    var kh = key_hash;
    var key_hash_seq = DDS.OctetSeq{ ._maximum = 16, ._length = 16, ._buffer = &kh, ._release = false };
    var pl_buf: [4096]u8 = undefined;
    @memcpy(pl_buf[0..payload.len], payload);
    var payload_seq = DDS.OctetSeq{ ._maximum = @intCast(payload.len), ._length = @intCast(payload.len), ._buffer = &pl_buf, ._release = false };
    const ts = DDS.Time_t{ .sec = DDS.TIME_INVALID_SEC, .nanosec = DDS.TIME_INVALID_NSEC };
    _ = dw.vtable.write_raw(dw.ptr, &key_hash_seq, DDS.HANDLE_NIL, &payload_seq, .ALIVE_WRITE_KIND, &ts);
}

test "bootstrap: get_key_value_writer returns CDR payload after alive write" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    writeRawViaOp(pair.dw, KEY_HASH, &PAYLOAD);
    fx.settle();

    const ih = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, ih, &buf, buf.len, &len);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(PAYLOAD.len, len);
    try testing.expectEqualSlices(u8, &PAYLOAD, buf[0..len]);
}

test "bootstrap: get_key_value_writer returns BAD_PARAMETER for a handle with no alive write" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var dummy_key: [16]u8 = undefined;
    @memset(&dummy_key, 0xFF);
    const ih = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &dummy_key);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, ih, &buf, buf.len, &len);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rc);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, DDS.HANDLE_NIL, &buf, buf.len, &len));
    try testing.expectError(error.BadParameter, zzdds.getKeyValueWriter(pair.dw, ih, alloc));
}

test "bootstrap: lookup_instance_writer matches register_instance_raw" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    // A key never registered or written has no handle.
    try testing.expectEqual(@as(DDS.InstanceHandle_t, 0), bootstrap.zzdds_lookup_instance_writer(pair.dw_boxed, &KEY_HASH));
    const h1 = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH);
    const h2 = bootstrap.zzdds_lookup_instance_writer(pair.dw_boxed, &KEY_HASH);
    try testing.expectEqual(h1, h2);
}

test "bootstrap: get_key_value_writer reports the size of a payload that does not fit" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    writeRawViaOp(pair.dw, KEY_HASH, &PAYLOAD);
    fx.settle();
    const ih = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH);

    // Too short: PRECONDITION_NOT_MET, as read for a sequence too short,
    // with the size needed.
    var small: [2]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, ih, &small, small.len, &len));
    try testing.expectEqual(PAYLOAD.len, len);
    // A NULL buffer of size 0 asks for the size the same way.
    len = 0;
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, ih, null, 0, &len));
    try testing.expectEqual(PAYLOAD.len, len);
    // Unusable arguments.
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, ih, null, 8, &len));
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, ih, &small, small.len, null));
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, bootstrap.zzdds_get_key_value_reader(pair.dr_boxed, ih, null, 8, &len));
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, bootstrap.zzdds_get_key_value_reader(pair.dr_boxed, ih, &small, small.len, null));

    // The raw op returns a copy of the same payload.
    const copy = try zzdds.getKeyValueWriter(pair.dw, ih, alloc);
    defer alloc.free(copy);
    try testing.expectEqualSlices(u8, &PAYLOAD, copy);
}

// DDS 1.4 §2.2.2.1.1.7: get_key_value is none of the operations a disabled
// entity takes, so it returns NOT_ENABLED.
test "bootstrap: get_key_value returns NOT_ENABLED for a disabled writer and reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var pub_qos = DDS.PublisherQos{};
    pub_qos.entity_factory.autoenable_created_entities = false;
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_w.vtable.set_qos(fx.pub_w.ptr, &pub_qos));
    var sub_qos = DDS.SubscriberQos{};
    sub_qos.entity_factory.autoenable_created_entities = false;
    try testing.expectEqual(DDS.RETCODE_OK, fx.sub_r.vtable.set_qos(fx.sub_r.ptr, &sub_qos));
    const pair = fx.makeWriterReader();
    try testing.expect(!@as(*DataWriterImpl, @ptrCast(@alignCast(pair.dw.ptr))).enabled.load(.acquire));
    try testing.expect(!@as(*DataReaderImpl, @ptrCast(@alignCast(pair.dr.ptr))).enabled.load(.acquire));

    var buf: [64]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(DDS.RETCODE_NOT_ENABLED, bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, 1, &buf, buf.len, &len));
    try testing.expectEqual(DDS.RETCODE_NOT_ENABLED, bootstrap.zzdds_get_key_value_reader(pair.dr_boxed, 1, &buf, buf.len, &len));
    try testing.expectError(error.NotEnabled, zzdds.getKeyValueWriter(pair.dw, 1, alloc));
    try testing.expectError(error.NotEnabled, zzdds.getKeyValueReader(pair.dr, 1, alloc));
}

// A call in flight keeps a deleted writer or reader allocated (the test's
// own quiesce reference stands in for it): get_key_value then returns
// ALREADY_DELETED, and register_instance and lookup_instance HANDLE_NIL.
test "bootstrap: get_key_value returns ALREADY_DELETED for a deleted writer and reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();
    writeRawViaOp(pair.dw, KEY_HASH, &PAYLOAD);
    fx.settle();
    const ih = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH);

    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(pair.dw.ptr));
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(pair.dr.ptr));
    try testing.expect(dw_impl.acquireQuiesce());
    try testing.expect(dr_impl.acquireQuiesce());
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_w.delete_datawriter(pair.dw));
    try testing.expectEqual(DDS.RETCODE_OK, fx.sub_r.delete_datareader(pair.dr));

    var buf: [64]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, ih, &buf, buf.len, &len));
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, bootstrap.zzdds_get_key_value_reader(pair.dr_boxed, ih, &buf, buf.len, &len));
    try testing.expectError(error.AlreadyDeleted, zzdds.getKeyValueWriter(pair.dw, ih, alloc));
    try testing.expectError(error.AlreadyDeleted, zzdds.getKeyValueReader(pair.dr, ih, alloc));
    try testing.expectEqual(DDS.HANDLE_NIL, bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH));
    try testing.expectEqual(DDS.HANDLE_NIL, bootstrap.zzdds_lookup_instance_writer(pair.dw_boxed, &KEY_HASH));
    try testing.expectEqual(DDS.HANDLE_NIL, bootstrap.zzdds_lookup_instance_reader(pair.dr_boxed, &KEY_HASH));

    dw_impl.releaseQuiesce();
    dr_impl.releaseQuiesce();
}

// ── get_key_value_reader / lookup_instance_reader ─────────────────────────────

test "bootstrap: get_key_value_reader returns CDR payload after receive" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    writeRawViaOp(pair.dw, KEY_HASH, &PAYLOAD);
    fx.settle();

    const ih = bootstrap.zzdds_lookup_instance_reader(pair.dr_boxed, &KEY_HASH);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_reader(pair.dr_boxed, ih, &buf, buf.len, &len);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(PAYLOAD.len, len);
    try testing.expectEqualSlices(u8, &PAYLOAD, buf[0..len]);
}

test "bootstrap: get_key_value_reader returns BAD_PARAMETER for a handle with no alive sample" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    // The writer's handle for a key the reader has not received.
    var dummy_key: [16]u8 = undefined;
    @memset(&dummy_key, 0xFF);
    const ih = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &dummy_key);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_reader(pair.dr_boxed, ih, &buf, buf.len, &len);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rc);
    try testing.expectError(error.BadParameter, zzdds.getKeyValueReader(pair.dr, ih, alloc));
}

test "bootstrap: lookup_instance_reader returns handle for alive instance, 0 when not found" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    writeRawViaOp(pair.dw, KEY_HASH, &PAYLOAD);
    fx.settle();

    // Known alive instance returns its handle.
    const ih = bootstrap.zzdds_lookup_instance_reader(pair.dr_boxed, &KEY_HASH);
    try testing.expect(ih != 0);

    // Unknown key returns 0 (HANDLE_NIL).
    var unknown_key: [16]u8 = undefined;
    @memset(&unknown_key, 0xFF);
    const ih2 = bootstrap.zzdds_lookup_instance_reader(pair.dr_boxed, &unknown_key);
    try testing.expectEqual(@as(DDS.InstanceHandle_t, 0), ih2);
}

// ── Conversion nil-guard tests ────────────────────────────────────────────────
//
// The DDS-internal upcasts (DDS_X_as_DDS_Y, where Y is an IDL-declared base
// of X) are now generated via the `as_{Base}` vtable slot mechanism (see
// zidl's docs/roadmap.md) rather than hand-written free functions with their
// own defensive vtable-identity check. That check — "is this really the
// vtable I expect, else return nil" — doesn't have an analogue to test
// anymore: dispatch through the vtable is correct by construction (you can
// only ever call `.vtable.as_X()` on a value that already has *some* real
// vtable for the interface type it claims to be), so there's no
// "wrong-implementation" runtime branch left to exercise here.

// ── Conversion valid-handle tests (using IntraProcess fixture) ────────────────

test "extensions: entity conversion functions return valid handles for real entities" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const np = zzdds.dcps.NIL_PTR;

    try testing.expect(fx.dp_w.vtable.as_Entity(fx.dp_w.ptr).ptr != np);
    try testing.expect(fx.topic_w.vtable.as_Entity(fx.topic_w.ptr).ptr != np);
    try testing.expect(fx.pub_w.vtable.as_Entity(fx.pub_w.ptr).ptr != np);
    try testing.expect(fx.sub_r.vtable.as_Entity(fx.sub_r.ptr).ptr != np);
    try testing.expect(pair.dw.vtable.as_Entity(pair.dw.ptr).ptr != np);
    try testing.expect(pair.dr.vtable.as_Entity(pair.dr.ptr).ptr != np);

    const td = fx.topic_w.vtable.as_TopicDescription(fx.topic_w.ptr);
    try testing.expect(td.ptr != np);
    try testing.expectEqualStrings("BootTopic", std.mem.span(td.vtable.get_name(td.ptr)));
}

test "extensions: DDS_DataReader_as_zzdds and back round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const np = zzdds.dcps.NIL_PTR;

    // DDS → ZZDDS: still hand-written (genuine downcast, no IDL relationship
    // zidl could derive it from).
    const zdr_boxed = extensions.DDS_DataReader_as_zzdds_DataReader(pair.dr.vtable.get_c_abi_handle(pair.dr.ptr)).?;
    const zdr = zidl_bindings.unboxAsView(ZZDDS.DataReader, zdr_boxed);
    try testing.expect(zdr.ptr != np);

    // ZZDDS → DDS round-trip: generated upcast (ZZDDS.DataReader : DDS::DataReader).
    const ddr = zdr.vtable.as_DataReader(zdr.ptr);
    try testing.expect(ddr.ptr != np);
    try testing.expectEqual(pair.dr.ptr, ddr.ptr);

    // Same for DataWriter
    const zdw_boxed = extensions.DDS_DataWriter_as_zzdds_DataWriter(pair.dw.vtable.get_c_abi_handle(pair.dw.ptr)).?;
    const zdw = zidl_bindings.unboxAsView(ZZDDS.DataWriter, zdw_boxed);
    try testing.expect(zdw.ptr != np);
    const ddw = zdw.vtable.as_DataWriter(zdw.ptr);
    try testing.expectEqual(pair.dw.ptr, ddw.ptr);
}

test "extensions: DataReader's Entity, DataReader, and ZZDDS.DataReader views all share the SAME boxed C-ABI handle" {
    // Phase 2 regression for the same anchor bug Phase 1 fixed for the
    // Condition family (zidl/docs/design/binding-c-abi-identity.md) --
    // confirms the fix generalizes across a real 3-level
    // chain (Entity <- DataReader <- ZZDDS.DataReader) and across the
    // dcps.idl/zzdds.idl module boundary, not just within one IDL file.
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    // DataReader's own box (real get_c_abi_handle path, DataReaderImpl.
    // vtGetCAbiHandle -- the canonical box every view below must match).
    const dr_boxed = pair.dr.vtable.get_c_abi_handle(pair.dr.ptr);

    // Entity view, reached via native as_Entity upcast then boxed.
    const entity_native = pair.dr.vtable.as_Entity(pair.dr.ptr);
    const entity_boxed = entity_native.vtable.get_c_abi_handle(entity_native.ptr);
    try testing.expectEqual(dr_boxed, entity_boxed);

    // ZZDDS.DataReader view, reached via the hand-written checked downcast
    // (extensions.zig -- the one hand-written call site zidl's codegen sweep
    // can't reach, per this test file's own "DDS → ZZDDS: still hand-written"
    // comment above).
    const zdr_boxed = extensions.DDS_DataReader_as_zzdds_DataReader(dr_boxed).?;
    try testing.expectEqual(dr_boxed, zdr_boxed);
}

test "extensions: DDS_ContentFilteredTopic_as_zzdds_ContentFilteredTopic shares the boxed handle and sets the filter expression" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const cft = fx.dp_r.create_contentfilteredtopic("BootCft", fx.topic_r, "x > 1", &DDS.StringSeq{});
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft);
    const cft_boxed = cft.vtable.get_c_abi_handle(cft.ptr);
    const zcft_boxed = extensions.DDS_ContentFilteredTopic_as_zzdds_ContentFilteredTopic(cft_boxed).?;
    try testing.expectEqual(cft_boxed, zcft_boxed);
    const zcft = zidl_bindings.unboxAsView(ZZDDS.ContentFilteredTopic, zcft_boxed);
    try testing.expectEqual(cft.ptr, zcft.ptr);
    try testing.expectEqual(cft.ptr, zcft.vtable.as_ContentFilteredTopic(zcft.ptr).ptr);

    var p_strs = [1][*:0]const u8{"3"};
    var p = DDS.StringSeq{ ._buffer = @ptrCast(&p_strs), ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, zcft.vtable.set_filter_expression(zcft.ptr, "x < %0", &p));
    try testing.expectEqualStrings("x < %0", cft.get_filter_expression());
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, zcft.vtable.set_filter_expression(zcft.ptr, "x < <", null));
    try testing.expectEqualStrings("x < %0", cft.get_filter_expression());
}

const ExReaderState = struct {
    matched_current: i32 = 0,
    ready_calls: usize = 0,
};

fn exOnSubscriptionMatched(_: *anyopaque, s: *const DDS.SubscriptionMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*ExReaderState, @ptrCast(@alignCast(ld))).matched_current = s.current_count;
}

fn exOnWriterReady(_: DDS.InstanceHandle_t, ready: bool, ld: ?*anyopaque) callconv(.c) void {
    if (ready) @as(*ExReaderState, @ptrCast(@alignCast(ld))).ready_calls += 1;
}

test "extensions: DDS_Publisher/Subscriber_as_zzdds_* share the boxed handle and create entities through the C-ABI vtables" {
    // What a C caller does: upcast its boxed DDS_Publisher/DDS_Subscriber to
    // the zzdds extension view, then call create_datawriter_ex/
    // create_datareader_ex through that view's vtable (with a listener
    // pointer, or NULL).
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const np = zzdds.dcps.NIL_PTR;

    const pub_boxed = fx.pub_w.vtable.get_c_abi_handle(fx.pub_w.ptr);
    const zpub_boxed = extensions.DDS_Publisher_as_zzdds_Publisher(pub_boxed).?;
    try testing.expectEqual(pub_boxed, zpub_boxed);
    const zpub = zidl_bindings.unboxAsView(ZZDDS.Publisher, zpub_boxed);
    try testing.expectEqual(fx.pub_w.ptr, zpub.ptr);
    try testing.expectEqual(fx.pub_w.ptr, zpub.vtable.as_Publisher(zpub.ptr).ptr);

    const sub_boxed = fx.sub_r.vtable.get_c_abi_handle(fx.sub_r.ptr);
    const zsub_boxed = extensions.DDS_Subscriber_as_zzdds_Subscriber(sub_boxed).?;
    try testing.expectEqual(sub_boxed, zsub_boxed);
    const zsub = zidl_bindings.unboxAsView(ZZDDS.Subscriber, zsub_boxed);
    try testing.expectEqual(fx.sub_r.ptr, zsub.ptr);
    try testing.expectEqual(fx.sub_r.ptr, zsub.vtable.as_Subscriber(zsub.ptr).ptr);

    // BEST_EFFORT on both sides, so readiness fires at match (no handshake).
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;

    var state = ExReaderState{};
    const listener = ZZDDS.DataReaderListenerEx{
        .listener_data = &state,
        .on_subscription_matched = exOnSubscriptionMatched,
        .on_reliable_writer_ready = exOnWriterReady,
    };
    const td = fx.topic_r.vtable.as_TopicDescription(fx.topic_r.ptr);
    const dr = zsub.vtable.create_datareader_ex(zsub.ptr, td, &dr_qos, &listener, DDS.SUBSCRIPTION_MATCHED_STATUS);
    try testing.expect(dr.ptr != np);
    defer _ = fx.sub_r.delete_datareader(dr);

    // NULL listener: allowed, like create_datawriter's.
    const dw = zpub.vtable.create_datawriter_ex(zpub.ptr, fx.topic_w, &dw_qos, null, 0);
    try testing.expect(dw.ptr != np);
    defer _ = fx.pub_w.delete_datawriter(dw);
    try testing.expectEqual(fx.pub_w.ptr, dw.get_publisher().ptr);
    fx.settle();

    try testing.expectEqual(@as(i32, 1), state.matched_current);
    try testing.expectEqual(@as(usize, 1), state.ready_calls);

    // NULL listener on the reader side too.
    const dr_plain = zsub.vtable.create_datareader_ex(zsub.ptr, td, &dr_qos, null, 0);
    try testing.expect(dr_plain.ptr != np);
    defer _ = fx.sub_r.delete_datareader(dr_plain);
}

// ── Condition conversion valid-handle tests ───────────────────────────────────

test "extensions: DDS_GuardCondition_as_DDS_Condition with real GuardCondition" {
    const gc_impl = try GuardConditionImpl.init(testing.allocator);
    defer gc_impl.deinit();

    const gc = gc_impl.toDDSGuardCondition();
    const c = gc.vtable.as_Condition(gc.ptr);
    try testing.expect(c.ptr != zzdds.dcps.NIL_PTR);
    try testing.expect(!c.vtable.get_trigger_value(c.ptr));

    _ = gc.set_trigger_value(true);
    try testing.expect(c.vtable.get_trigger_value(c.ptr));
}

test "extensions: DDS_StatusCondition_as_DDS_Condition with participant status condition" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const sc = fx.dp_w.get_statuscondition();
    const c = sc.vtable.as_Condition(sc.ptr);
    try testing.expect(c.ptr != zzdds.dcps.NIL_PTR);
}

test "extensions: DDS_ReadCondition_as_DDS_Condition with real ReadCondition" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const rc = pair.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = pair.dr.delete_readcondition(rc);

    const c = rc.vtable.as_Condition(rc.ptr);
    try testing.expect(c.ptr != zzdds.dcps.NIL_PTR);
}

// ── Extension serialized take via ZZDDS DataReader vtable ─────────────────────

test "extensions: RTPS GUIDs identify participants and endpoints" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const zdp = zidl_bindings.unboxAsView(
        ZZDDS.DomainParticipant,
        extensions.DDS_DomainParticipant_as_zzdds_DomainParticipant(fx.dp_w.vtable.get_c_abi_handle(fx.dp_w.ptr)).?,
    );
    const zdp_reader = zidl_bindings.unboxAsView(
        ZZDDS.DomainParticipant,
        extensions.DDS_DomainParticipant_as_zzdds_DomainParticipant(fx.dp_r.vtable.get_c_abi_handle(fx.dp_r.ptr)).?,
    );
    const zdw = zidl_bindings.unboxAsView(
        ZZDDS.DataWriter,
        extensions.DDS_DataWriter_as_zzdds_DataWriter(pair.dw.vtable.get_c_abi_handle(pair.dw.ptr)).?,
    );
    const zdr = zidl_bindings.unboxAsView(
        ZZDDS.DataReader,
        extensions.DDS_DataReader_as_zzdds_DataReader(pair.dr.vtable.get_c_abi_handle(pair.dr.ptr)).?,
    );

    var participant_guid: ZZDDS.RtpsGuid = undefined;
    var reader_participant_guid: ZZDDS.RtpsGuid = undefined;
    var writer_guid: ZZDDS.RtpsGuid = undefined;
    var reader_guid: ZZDDS.RtpsGuid = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, zdp.vtable.get_rtps_guid(zdp.ptr, &participant_guid));
    try testing.expectEqual(DDS.RETCODE_OK, zdp_reader.vtable.get_rtps_guid(zdp_reader.ptr, &reader_participant_guid));
    try testing.expectEqual(DDS.RETCODE_OK, zdw.vtable.get_rtps_guid(zdw.ptr, &writer_guid));
    try testing.expectEqual(DDS.RETCODE_OK, zdr.vtable.get_rtps_guid(zdr.ptr, &reader_guid));

    // Every endpoint created by a participant shares its 12-byte GUID prefix,
    // while its four-byte entity id is distinct.
    try testing.expectEqualSlices(u8, participant_guid.value[0..12], writer_guid.value[0..12]);
    try testing.expect(!std.mem.eql(u8, participant_guid.value[12..16], writer_guid.value[12..16]));
    try testing.expectEqualSlices(u8, reader_participant_guid.value[0..12], reader_guid.value[0..12]);
    try testing.expect(!std.mem.eql(u8, writer_guid.value[0..12], reader_guid.value[0..12]));

    var subscription_handles: DDS.InstanceHandleSeq = .{};
    defer if (subscription_handles._buffer) |buffer| alloc.free(buffer[0..subscription_handles._maximum]);
    try testing.expectEqual(DDS.RETCODE_OK, pair.dw.get_matched_subscriptions(&subscription_handles));
    try testing.expectEqual(@as(u32, 1), subscription_handles._length);

    // The symmetric writer operation expands a matched subscription handle.
    const subscription_handle = subscription_handles._buffer.?[0];
    var resolved_reader_guid: ZZDDS.RtpsGuid = undefined;
    try testing.expectEqual(
        DDS.RETCODE_OK,
        zdw.vtable.get_matched_subscription_rtps_guid(zdw.ptr, subscription_handle, &resolved_reader_guid),
    );
    try testing.expectEqualSlices(u8, &reader_guid.value, &resolved_reader_guid.value);

    var publication_handles: DDS.InstanceHandleSeq = .{};
    defer if (publication_handles._buffer) |buffer| alloc.free(buffer[0..publication_handles._maximum]);
    try testing.expectEqual(DDS.RETCODE_OK, pair.dr.get_matched_publications(&publication_handles));
    try testing.expectEqual(@as(u32, 1), publication_handles._length);

    // The reader can expand SampleInfo.publication_handle's compact DDS handle
    // back to the remote writer's full RTPS GUID.
    const publication_handle = publication_handles._buffer.?[0];
    var resolved_guid: ZZDDS.RtpsGuid = undefined;
    try testing.expectEqual(
        DDS.RETCODE_OK,
        zdr.vtable.get_matched_publication_rtps_guid(zdr.ptr, publication_handle, &resolved_guid),
    );
    try testing.expectEqualSlices(u8, &writer_guid.value, &resolved_guid.value);

    try testing.expectEqual(
        DDS.RETCODE_BAD_PARAMETER,
        zdw.vtable.get_matched_subscription_rtps_guid(zdw.ptr, DDS.HANDLE_NIL, &resolved_reader_guid),
    );
    try testing.expectEqual(
        DDS.RETCODE_BAD_PARAMETER,
        zdr.vtable.get_matched_publication_rtps_guid(zdr.ptr, DDS.HANDLE_NIL, &resolved_guid),
    );

    // Keep the association after unmatching: samples already queued in the
    // reader can continue to carry this publication_handle.
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_w.delete_datawriter(pair.dw));
    try testing.expectEqual(
        DDS.RETCODE_OK,
        zdr.vtable.get_matched_publication_rtps_guid(zdr.ptr, publication_handle, &resolved_guid),
    );
    try testing.expectEqualSlices(u8, &writer_guid.value, &resolved_guid.value);
}

test "extensions: take_serialized via ZZDDS DataReader vtable" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    writeRawViaOp(pair.dw, KEY_HASH, &PAYLOAD);
    fx.settle();

    const zdr = zidl_bindings.unboxAsView(ZZDDS.DataReader, extensions.DDS_DataReader_as_zzdds_DataReader(pair.dr.vtable.get_c_abi_handle(pair.dr.ptr)).?);
    var sample: ZZDDS.SerializedSample = std.mem.zeroes(ZZDDS.SerializedSample);
    const rc = zdr.vtable.take_serialized(zdr.ptr, &sample);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(u32, @intCast(PAYLOAD.len)), sample.cdr._length);
    try testing.expect(sample.cdr._release);
    try testing.expectEqualSlices(u8, &PAYLOAD, sample.cdr._buffer.?[0..sample.cdr._length]);
    std.heap.c_allocator.free(sample.cdr._buffer.?[0..sample.cdr._maximum]);

    // Queue is now empty.
    var sample2: ZZDDS.SerializedSample = std.mem.zeroes(ZZDDS.SerializedSample);
    try testing.expectEqual(DDS.RETCODE_NO_DATA, zdr.vtable.take_serialized(zdr.ptr, &sample2));
}

// ── Config: stringSeqSlice null-buffer and null-element guards ────────────────

test "generated: toRuntimeConfig returns NullBuffer when StringSeq has length>0 but null buffer" {
    const alloc = testing.allocator;
    var cfg = ZZDDS.DomainParticipantConfig.default();
    // interfaces has length=0 by default; set length=1 with null buffer.
    cfg.transport.udp.interfaces._length = 1;
    cfg.transport.udp.interfaces._buffer = null;
    try testing.expectError(error.NullBuffer, generated_config.toRuntimeConfig(alloc, &cfg));
}

// ── C-ABI handle coverage: get_c_abi_handle / as_Base on nil singletons ───────

test "nil singletons: get_c_abi_handle boxes every nil entity/condition view" {
    const np = zzdds.dcps.NIL_PTR;
    const nd = zzdds.dcps;

    // Every nil.* singleton's get_c_abi_handle must box (NIL_PTR, its own
    // vtable) rather than returning some raw sentinel, and must be
    // identity-stable across repeated calls, same as any real entity's.
    inline for (.{
        nd.nil_status_condition,
        nd.nil_entity,
        nd.nil_participant,
        nd.nil_publisher,
        nd.nil_subscriber,
        nd.nil_datawriter,
        nd.nil_datareader,
        nd.nil_topic_description,
        nd.nil_topic,
        nd.nil_cft,
        nd.nil_multitopic,
        nd.nil_condition,
        nd.nil_readcondition,
        nd.nil_querycondition,
        nd.nil_factory,
    }) |nil_handle| {
        const T = @TypeOf(nil_handle);
        const boxed = nil_handle.vtable.get_c_abi_handle(nil_handle.ptr);
        const unboxed = zidl_bindings.unboxAs(T, boxed);
        try testing.expectEqual(np, unboxed.ptr);
        try testing.expectEqual(boxed, nil_handle.vtable.get_c_abi_handle(nil_handle.ptr));
    }
}

test "nil singletons: as_Base upcast slots return the correct nil singleton" {
    const nd = zzdds.dcps;

    const e1 = nd.nil_participant.vtable.as_Entity(nd.nil_participant.ptr);
    try testing.expectEqual(nd.nil_entity.ptr, e1.ptr);
    try testing.expectEqual(nd.nil_entity.vtable, e1.vtable);

    const c1 = nd.nil_status_condition.vtable.as_Condition(nd.nil_status_condition.ptr);
    try testing.expectEqual(nd.nil_condition.ptr, c1.ptr);
    try testing.expectEqual(nd.nil_condition.vtable, c1.vtable);

    const td1 = nd.nil_topic.vtable.as_TopicDescription(nd.nil_topic.ptr);
    try testing.expectEqual(nd.nil_topic_description.ptr, td1.ptr);
    try testing.expectEqual(nd.nil_topic_description.vtable, td1.vtable);

    const rc1 = nd.nil_querycondition.vtable.as_ReadCondition(nd.nil_querycondition.ptr);
    try testing.expectEqual(nd.nil_readcondition.ptr, rc1.ptr);
    try testing.expectEqual(nd.nil_readcondition.vtable, rc1.vtable);
}

// ── C-ABI handle coverage: extensions.zig nil-guard regression ────────────────

test "extensions: DDS_X_as_zzdds_X is NULL for NULL and for a handle zzdds did not issue" {
    const nd = zzdds.dcps;
    try testing.expect(extensions.DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory(null) == null);
    try testing.expect(extensions.DDS_DomainParticipant_as_zzdds_DomainParticipant(null) == null);
    try testing.expect(extensions.DDS_Topic_as_zzdds_Topic(null) == null);
    try testing.expect(extensions.DDS_ContentFilteredTopic_as_zzdds_ContentFilteredTopic(null) == null);
    try testing.expect(extensions.DDS_DataWriter_as_zzdds_DataWriter(null) == null);
    try testing.expect(extensions.DDS_DataReader_as_zzdds_DataReader(null) == null);
    try testing.expect(extensions.DDS_Publisher_as_zzdds_Publisher(null) == null);
    try testing.expect(extensions.DDS_Subscriber_as_zzdds_Subscriber(null) == null);

    // A nil's handle is not one of zzdds's entities.
    try testing.expect(extensions.DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory(nd.nil_factory.vtable.get_c_abi_handle(nd.nil_factory.ptr)) == null);
    try testing.expect(extensions.DDS_DomainParticipant_as_zzdds_DomainParticipant(nd.nil_participant.vtable.get_c_abi_handle(nd.nil_participant.ptr)) == null);
    try testing.expect(extensions.DDS_Topic_as_zzdds_Topic(nd.nil_topic.vtable.get_c_abi_handle(nd.nil_topic.ptr)) == null);
    try testing.expect(extensions.DDS_ContentFilteredTopic_as_zzdds_ContentFilteredTopic(nd.nil_cft.vtable.get_c_abi_handle(nd.nil_cft.ptr)) == null);
    try testing.expect(extensions.DDS_DataWriter_as_zzdds_DataWriter(nd.nil_datawriter.vtable.get_c_abi_handle(nd.nil_datawriter.ptr)) == null);
    try testing.expect(extensions.DDS_DataReader_as_zzdds_DataReader(nd.nil_datareader.vtable.get_c_abi_handle(nd.nil_datareader.ptr)) == null);
    try testing.expect(extensions.DDS_Publisher_as_zzdds_Publisher(nd.nil_publisher.vtable.get_c_abi_handle(nd.nil_publisher.ptr)) == null);
    try testing.expect(extensions.DDS_Subscriber_as_zzdds_Subscriber(nd.nil_subscriber.vtable.get_c_abi_handle(nd.nil_subscriber.ptr)) == null);
}

test "extensions: the zzdds extension nils are safe to call through" {
    // What a NULL zzdds_* handle stands for at the C ABI: NIL_PTR with the
    // extension's own vtable, whose functions answer for NIL_PTR.
    const nd = zzdds.dcps;

    const zdp: ZZDDS.DomainParticipant = .{ .ptr = nd.NIL_PTR, .vtable = &extensions.participant_vtable };
    const back_dp = zdp.vtable.as_DomainParticipant(zdp.ptr);
    try testing.expectEqual(nd.nil_participant.ptr, back_dp.ptr);
    try testing.expectEqual(nd.nil_participant.vtable, back_dp.vtable);

    const ztopic: ZZDDS.Topic = .{ .ptr = nd.NIL_PTR, .vtable = &extensions.topic_vtable };
    try testing.expectEqual(nd.nil_topic.ptr, ztopic.vtable.as_Topic(ztopic.ptr).ptr);

    const zdw: ZZDDS.DataWriter = .{ .ptr = nd.NIL_PTR, .vtable = &extensions.writer_vtable };
    try testing.expectEqual(nd.nil_datawriter.ptr, zdw.vtable.as_DataWriter(zdw.ptr).ptr);

    const zdr: ZZDDS.DataReader = .{ .ptr = nd.NIL_PTR, .vtable = &extensions.reader_vtable };
    try testing.expectEqual(nd.nil_datareader.ptr, zdr.vtable.as_DataReader(zdr.ptr).ptr);

    const zpub: ZZDDS.Publisher = .{ .ptr = nd.NIL_PTR, .vtable = &extensions.publisher_vtable };
    try testing.expectEqual(nd.nil_publisher.ptr, zpub.vtable.as_Publisher(zpub.ptr).ptr);
    try testing.expectEqual(std.heap.c_allocator, zpub.vtable.get_allocator(zpub.ptr));
    const dw_qos = DDS.DataWriterQos{};
    try testing.expectEqual(nd.NIL_PTR, zpub.vtable.create_datawriter_ex(zpub.ptr, nd.nil_topic, &dw_qos, null, 0).ptr);

    const zsub: ZZDDS.Subscriber = .{ .ptr = nd.NIL_PTR, .vtable = &extensions.subscriber_vtable };
    try testing.expectEqual(nd.nil_subscriber.ptr, zsub.vtable.as_Subscriber(zsub.ptr).ptr);
    try testing.expectEqual(std.heap.c_allocator, zsub.vtable.get_allocator(zsub.ptr));
    const dr_qos = DDS.DataReaderQos{};
    try testing.expectEqual(nd.NIL_PTR, zsub.vtable.create_datareader_ex(zsub.ptr, nd.nil_topic_description, &dr_qos, null, 0).ptr);

    const zcft: ZZDDS.ContentFilteredTopic = .{ .ptr = nd.NIL_PTR, .vtable = &extensions.cft_vtable };
    try testing.expectEqual(nd.nil_cft.ptr, zcft.vtable.as_ContentFilteredTopic(zcft.ptr).ptr);
    try testing.expectEqual(std.heap.c_allocator, zcft.vtable.get_allocator(zcft.ptr));
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, zcft.vtable.set_filter_expression(zcft.ptr, "x = 1", null));
}

test "extensions: factory DDS-view get_c_abi_handle boxes nil handle correctly" {
    const alloc = testing.allocator;
    const boxed = try zidl_bindings.boxEntity(alloc, zzdds.dcps.NIL_PTR, &extensions.factory_views);
    defer zidl_bindings.freeEntityBox(alloc, boxed);
    const zf = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, boxed);

    const dds_view = zf.vtable.as_DomainParticipantFactory(zf.ptr);
    const dds_boxed = dds_view.vtable.get_c_abi_handle(dds_view.ptr);
    const unboxed = zidl_bindings.unboxAsView(DDS.DomainParticipantFactory, dds_boxed);
    try testing.expectEqual(zzdds.dcps.NIL_PTR, unboxed.ptr);
}

test "extensions: zzdds_destroy_factory of NULL does nothing" {
    extensions.zzdds_destroy_factory(null);
}

// ── C-ABI handle coverage: real WaitSet / conditions ───────────────────────────

test "waitset: get_c_abi_handle boxes real WaitSet, conditions, and their Condition views" {
    const alloc = testing.allocator;

    const ws = try zzdds.dcps.WaitSetImpl.init(alloc);
    defer ws.deinit();
    const ws_dds = ws.toDDSWaitSet();
    const ws_boxed = ws_dds.vtable.get_c_abi_handle(ws_dds.ptr);
    try testing.expectEqual(ws_boxed, ws_dds.vtable.get_c_abi_handle(ws_dds.ptr));

    const gc = try GuardConditionImpl.init(alloc);
    defer gc.deinit();
    const gc_dds = gc.toDDSGuardCondition();
    _ = gc_dds.vtable.get_c_abi_handle(gc_dds.ptr);
    const gc_cond = gc.toCondition();
    _ = gc_cond.vtable.get_c_abi_handle(gc_cond.ptr);

    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const sc = fx.dp_w.get_statuscondition();
    _ = sc.vtable.get_c_abi_handle(sc.ptr);
    const sc_cond = sc.vtable.as_Condition(sc.ptr);
    _ = sc_cond.vtable.get_c_abi_handle(sc_cond.ptr);

    const rc = pair.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = pair.dr.delete_readcondition(rc);
    _ = rc.vtable.get_c_abi_handle(rc.ptr);
    const rc_cond = rc.vtable.as_Condition(rc.ptr);
    _ = rc_cond.vtable.get_c_abi_handle(rc_cond.ptr);

    var empty_params = DDS.StringSeq{};
    const qc = pair.dr.create_querycondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, "", &empty_params);
    try testing.expect(qc.ptr != zzdds.dcps.NIL_PTR);
    defer qc.deinit();
    _ = qc.vtable.get_c_abi_handle(qc.ptr);
    const qc_as_rc = qc.vtable.as_ReadCondition(qc.ptr);
    try testing.expect(qc_as_rc.ptr != zzdds.dcps.NIL_PTR);
    _ = qc_as_rc.vtable.get_c_abi_handle(qc_as_rc.ptr);
}

test "extensions: DDS_ReadCondition_as_DDS_QueryCondition recovers a real QueryCondition, rejects a standalone ReadCondition" {
    // Regression for the fix landed 2026-08-12 (see this function's own doc
    // comment in extensions.zig) -- previously always returned null, since no
    // signal existed to distinguish a QueryCondition's embedded ReadCondition
    // view from a genuinely standalone one. The Phase 1 owner_qc redirect
    // created that signal as a side effect; this test proves the downcast
    // now actually uses it correctly, both ways (positive and negative case).
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    // Positive case: a real QueryCondition's ReadCondition-view box downcasts
    // back to the SAME QueryCondition box it started from.
    var empty_params = DDS.StringSeq{};
    const qc = pair.dr.create_querycondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, "", &empty_params);
    try testing.expect(qc.ptr != zzdds.dcps.NIL_PTR);
    defer qc.deinit();
    const qc_boxed = qc.vtable.get_c_abi_handle(qc.ptr);
    const qc_as_rc = qc.vtable.as_ReadCondition(qc.ptr);
    const qc_as_rc_boxed = qc_as_rc.vtable.get_c_abi_handle(qc_as_rc.ptr);

    const recovered_boxed = extensions.DDS_ReadCondition_as_DDS_QueryCondition(qc_as_rc_boxed);
    try testing.expect(recovered_boxed != null);
    try testing.expectEqual(qc_boxed, recovered_boxed.?);

    // Negative case: a genuinely standalone ReadCondition must still report
    // "not a match", not a false positive.
    const rc = pair.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = pair.dr.delete_readcondition(rc);
    const rc_boxed = rc.vtable.get_c_abi_handle(rc.ptr);
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_ReadCondition_as_DDS_QueryCondition(rc_boxed));
}

// ── Condition hierarchy checked downcasts: DDS_Condition_as_DDS_* ─────────────
//
// Coverage gap closed 2026-08-13: these three checked downcasts (and the six
// DDS_Entity_as_DDS_*/three DDS_TopicDescription_as_DDS_* ones below) had
// zero direct unit tests before this -- only the ONE-level-deeper
// DDS_ReadCondition_as_DDS_QueryCondition above did. They were only ever
// exercised indirectly (Java's StatusCondition.get_entity() smoke test hits
// DDS_Entity_as_DDS_DomainParticipant specifically), and that path isn't
// visible to kcov at all (a separate JVM process calling into a separately
// built .so, not a `zig build emit-tests` binary) -- so from the Zig test
// suite's own coverage perspective they were entirely dark. Each test below
// proves both branches: a real match recovers the SAME boxed handle the
// concrete type's own get_c_abi_handle produces, and a genuine mismatch
// returns null rather than a false positive.
test "extensions: DDS_Condition_as_DDS_* checked downcasts recover the real concrete condition, reject the others" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const gc = try GuardConditionImpl.init(alloc);
    defer gc.deinit();
    const gc_dds = gc.toDDSGuardCondition();
    const gc_boxed = gc_dds.vtable.get_c_abi_handle(gc_dds.ptr);
    const gc_cond = gc_dds.vtable.as_Condition(gc_dds.ptr);
    const gc_cond_boxed = gc_cond.vtable.get_c_abi_handle(gc_cond.ptr);

    const sc = fx.dp_w.get_statuscondition();
    const sc_boxed = sc.vtable.get_c_abi_handle(sc.ptr);
    const sc_cond = sc.vtable.as_Condition(sc.ptr);
    const sc_cond_boxed = sc_cond.vtable.get_c_abi_handle(sc_cond.ptr);

    const rc = pair.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = pair.dr.delete_readcondition(rc);
    const rc_boxed = rc.vtable.get_c_abi_handle(rc.ptr);
    const rc_cond = rc.vtable.as_Condition(rc.ptr);
    const rc_cond_boxed = rc_cond.vtable.get_c_abi_handle(rc_cond.ptr);

    // DDS_Condition_as_DDS_GuardCondition
    try testing.expectEqual(gc_boxed, extensions.DDS_Condition_as_DDS_GuardCondition(gc_cond_boxed).?);
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Condition_as_DDS_GuardCondition(sc_cond_boxed));
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Condition_as_DDS_GuardCondition(rc_cond_boxed));

    // DDS_Condition_as_DDS_StatusCondition
    try testing.expectEqual(sc_boxed, extensions.DDS_Condition_as_DDS_StatusCondition(sc_cond_boxed).?);
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Condition_as_DDS_StatusCondition(gc_cond_boxed));
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Condition_as_DDS_StatusCondition(rc_cond_boxed));

    // DDS_Condition_as_DDS_ReadCondition
    try testing.expectEqual(rc_boxed, extensions.DDS_Condition_as_DDS_ReadCondition(rc_cond_boxed).?);
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Condition_as_DDS_ReadCondition(gc_cond_boxed));
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Condition_as_DDS_ReadCondition(sc_cond_boxed));
}

// ── Entity hierarchy checked downcasts: DDS_Entity_as_DDS_* ───────────────────

test "extensions: DDS_Entity_as_DDS_* checked downcasts recover the real concrete entity, reject the others" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const dp_boxed = fx.dp_w.vtable.get_c_abi_handle(fx.dp_w.ptr);
    const dp_ent = fx.dp_w.vtable.as_Entity(fx.dp_w.ptr);
    const dp_ent_boxed = dp_ent.vtable.get_c_abi_handle(dp_ent.ptr);

    const topic_boxed = fx.topic_w.vtable.get_c_abi_handle(fx.topic_w.ptr);
    const topic_ent = fx.topic_w.vtable.as_Entity(fx.topic_w.ptr);
    const topic_ent_boxed = topic_ent.vtable.get_c_abi_handle(topic_ent.ptr);

    const pub_boxed = fx.pub_w.vtable.get_c_abi_handle(fx.pub_w.ptr);
    const pub_ent = fx.pub_w.vtable.as_Entity(fx.pub_w.ptr);
    const pub_ent_boxed = pub_ent.vtable.get_c_abi_handle(pub_ent.ptr);

    const sub_boxed = fx.sub_r.vtable.get_c_abi_handle(fx.sub_r.ptr);
    const sub_ent = fx.sub_r.vtable.as_Entity(fx.sub_r.ptr);
    const sub_ent_boxed = sub_ent.vtable.get_c_abi_handle(sub_ent.ptr);

    const dw_boxed = pair.dw.vtable.get_c_abi_handle(pair.dw.ptr);
    const dw_ent = pair.dw.vtable.as_Entity(pair.dw.ptr);
    const dw_ent_boxed = dw_ent.vtable.get_c_abi_handle(dw_ent.ptr);

    const dr_boxed = pair.dr.vtable.get_c_abi_handle(pair.dr.ptr);
    const dr_ent = pair.dr.vtable.as_Entity(pair.dr.ptr);
    const dr_ent_boxed = dr_ent.vtable.get_c_abi_handle(dr_ent.ptr);

    // Each downcast: positive match on its own Entity view, negative (null)
    // against every one of the other five.
    const others_for_dp = [_]*anyopaque{ topic_ent_boxed, pub_ent_boxed, sub_ent_boxed, dw_ent_boxed, dr_ent_boxed };
    try testing.expectEqual(dp_boxed, extensions.DDS_Entity_as_DDS_DomainParticipant(dp_ent_boxed).?);
    for (others_for_dp) |other| try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Entity_as_DDS_DomainParticipant(other));

    const others_for_topic = [_]*anyopaque{ dp_ent_boxed, pub_ent_boxed, sub_ent_boxed, dw_ent_boxed, dr_ent_boxed };
    try testing.expectEqual(topic_boxed, extensions.DDS_Entity_as_DDS_Topic(topic_ent_boxed).?);
    for (others_for_topic) |other| try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Entity_as_DDS_Topic(other));

    const others_for_pub = [_]*anyopaque{ dp_ent_boxed, topic_ent_boxed, sub_ent_boxed, dw_ent_boxed, dr_ent_boxed };
    try testing.expectEqual(pub_boxed, extensions.DDS_Entity_as_DDS_Publisher(pub_ent_boxed).?);
    for (others_for_pub) |other| try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Entity_as_DDS_Publisher(other));

    const others_for_sub = [_]*anyopaque{ dp_ent_boxed, topic_ent_boxed, pub_ent_boxed, dw_ent_boxed, dr_ent_boxed };
    try testing.expectEqual(sub_boxed, extensions.DDS_Entity_as_DDS_Subscriber(sub_ent_boxed).?);
    for (others_for_sub) |other| try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Entity_as_DDS_Subscriber(other));

    const others_for_dw = [_]*anyopaque{ dp_ent_boxed, topic_ent_boxed, pub_ent_boxed, sub_ent_boxed, dr_ent_boxed };
    try testing.expectEqual(dw_boxed, extensions.DDS_Entity_as_DDS_DataWriter(dw_ent_boxed).?);
    for (others_for_dw) |other| try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Entity_as_DDS_DataWriter(other));

    const others_for_dr = [_]*anyopaque{ dp_ent_boxed, topic_ent_boxed, pub_ent_boxed, sub_ent_boxed, dw_ent_boxed };
    try testing.expectEqual(dr_boxed, extensions.DDS_Entity_as_DDS_DataReader(dr_ent_boxed).?);
    for (others_for_dr) |other| try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_Entity_as_DDS_DataReader(other));
}

// ── TopicDescription hierarchy checked downcasts: DDS_TopicDescription_as_DDS_* ──

test "extensions: DDS_TopicDescription_as_DDS_* checked downcasts recover the real concrete topic/CFT, reject the other; MultiTopic always null" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const topic_boxed = fx.topic_w.vtable.get_c_abi_handle(fx.topic_w.ptr);
    const topic_td = fx.topic_w.vtable.as_TopicDescription(fx.topic_w.ptr);
    const topic_td_boxed = topic_td.vtable.get_c_abi_handle(topic_td.ptr);

    const cft = fx.dp_r.create_contentfilteredtopic("BootCftDowncast", fx.topic_r, "", &DDS.StringSeq{});
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft);
    const cft_boxed = cft.vtable.get_c_abi_handle(cft.ptr);
    const cft_td = cft.vtable.as_TopicDescription(cft.ptr);
    const cft_td_boxed = cft_td.vtable.get_c_abi_handle(cft_td.ptr);

    try testing.expectEqual(topic_boxed, extensions.DDS_TopicDescription_as_DDS_Topic(topic_td_boxed).?);
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_TopicDescription_as_DDS_Topic(cft_td_boxed));

    try testing.expectEqual(cft_boxed, extensions.DDS_TopicDescription_as_DDS_ContentFilteredTopic(cft_td_boxed).?);
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_TopicDescription_as_DDS_ContentFilteredTopic(topic_td_boxed));

    // MultiTopic is a permanent nil-only stub in zzdds (no MultiTopicImpl
    // exists at all -- see the function's own doc comment in extensions.zig)
    // -- no real TopicDescription view can ever be one, checked against both
    // real views on hand here.
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_TopicDescription_as_DDS_MultiTopic(topic_td_boxed));
    try testing.expectEqual(@as(?*anyopaque, null), extensions.DDS_TopicDescription_as_DDS_MultiTopic(cft_td_boxed));
}

// ── WaitSet / GuardCondition through the C ABI ─────────────────────────────────
//
// WaitSet and GuardCondition have no factory operation in dcps.idl (per OMG
// spec, both are app-instantiated directly). dcps.idl declares their
// constructors, which zidl generates as DDS_WaitSet_create and the like (see
// "generated constructors" above), but only in a language-binding build.
// The tests here only need handles, and make them as the generated export
// does (newWaitSetHandle below), so they run in every build.

/// A new WaitSet's C-ABI handle, boxed as DDS_WaitSet_create boxes it.
fn newWaitSetHandle() !*anyopaque {
    const ws = try zzdds.createWaitSet(std.heap.c_allocator);
    return ws.vtable.get_c_abi_handle(ws.ptr);
}

/// A new GuardCondition's C-ABI handle, boxed as DDS_GuardCondition_create boxes it.
fn newGuardConditionHandle() !*anyopaque {
    const gc = try zzdds.createGuardCondition(std.heap.c_allocator);
    return gc.vtable.get_c_abi_handle(gc.ptr);
}

/// DDS_WaitSet_destroy's body.
fn destroyWaitSetHandle(h: *anyopaque) void {
    const ws = zidl_bindings.unboxAs(DDS.WaitSet, h);
    std.debug.assert(ws.vtable.destroy(ws.ptr) == DDS.RETCODE_OK);
}

/// DDS_GuardCondition_destroy's body.
fn destroyGuardConditionHandle(h: *anyopaque) void {
    const gc = zidl_bindings.unboxAsView(DDS.GuardCondition, h);
    std.debug.assert(gc.vtable.destroy(gc.ptr) == DDS.RETCODE_OK);
}

test "waitset: WaitSet.wait() returns the SAME boxed C-ABI handle the app derived for its own GuardCondition, not a different one" {
    // Regression for the anchor bug in
    // zidl/docs/design/binding-c-abi-identity.md (2026-08-12): before that
    // fix, GuardCondition
    // and Condition views of the same object boxed to two independently-
    // allocated EntityBox addresses (GuardConditionImpl.gc_c_abi vs
    // .cond_c_abi), so an app holding a GuardCondition handle it attached
    // earlier could not recognize it in wait()'s result by raw handle
    // equality -- only by re-deriving identity out of band (comparing
    // get_trigger_value() directly, as zzdds-examples' cpp/waitset works
    // around it).
    //
    // Deliberately does NOT call the `--zig-generate-c-api`-generated
    // DDS_GuardCondition_as_DDS_Condition/DDS_WaitSet_attach_condition/
    // DDS_WaitSet_wait free functions directly -- those symbols only exist
    // when a language binding build option is set, and this test file
    // compiles unconditionally. Instead it replicates exactly what those
    // generated wrappers do internally (`zidl_bindings.unboxAsView` +
    // `.vtable.get_c_abi_handle`), which is the actual mechanism under test
    // and is always available. attach_condition/wait themselves are called
    // as plain native vtable dispatch (never boxed, never broken -- see the
    // design doc) so this test's own plumbing doesn't accidentally
    // depend on the very fix it's meant to verify.
    const ws_boxed = try newWaitSetHandle();
    defer destroyWaitSetHandle(ws_boxed);
    const gc_boxed = try newGuardConditionHandle();
    defer destroyGuardConditionHandle(gc_boxed);

    // The app derives its own Condition-view handle once -- exactly what a C
    // caller must do, since DDS_WaitSet_attach_condition's C signature takes
    // DDS_Condition, not DDS_GuardCondition -- mirroring
    // DDS_GuardCondition_as_DDS_Condition's generated body exactly.
    const gc = zidl_bindings.unboxAsView(DDS.GuardCondition, gc_boxed);
    const cond_native = gc.vtable.as_Condition(gc.ptr);
    const c_boxed = cond_native.vtable.get_c_abi_handle(cond_native.ptr);

    const ws = zidl_bindings.unboxAs(DDS.WaitSet, ws_boxed);
    try testing.expectEqual(DDS.RETCODE_OK, ws.vtable.attach_condition(ws.ptr, zidl_bindings.unboxAsView(DDS.Condition, c_boxed)));
    try testing.expectEqual(DDS.RETCODE_OK, gc.vtable.set_trigger_value(gc.ptr, true));

    var active = DDS.ConditionSeq{};
    const zero = DDS.Duration_t{ .sec = 0, .nanosec = 0 };
    try testing.expectEqual(DDS.RETCODE_OK, ws.vtable.wait(ws.ptr, &active, &zero));
    defer if (active._release) {
        if (active._buffer) |b| std.heap.c_allocator.free(b[0..active._maximum]);
    };
    try testing.expectEqual(@as(u32, 1), active._length);

    // Box wait()'s one returned native element exactly like the generated
    // C-ABI export wrapper would (`_r.vtable.get_c_abi_handle(_r.ptr)` per
    // element -- see zig.zig's emitCApiOp).
    const returned_native = active._buffer.?[0];
    const returned_boxed = returned_native.vtable.get_c_abi_handle(returned_native.ptr);

    // The actual regression assertion: wait()'s returned handle is the
    // IDENTICAL boxed pointer the app already derived above, not a second,
    // independently-boxed one for the same underlying condition.
    try testing.expectEqual(c_boxed, returned_boxed);

    // Stronger version of the same property, one step earlier: GuardCondition's
    // OWN creation box and its OWN Condition-view upcast box are the very same
    // address too, not just "wait() agrees with whatever the app derived" --
    // both the GuardCondition's own handle and the Condition-view boxing above
    // dispatch through the same shared `GuardConditionImpl.c_abi` cache.
    try testing.expectEqual(gc_boxed, c_boxed);
}

// ── zzdds_waitset_attach_condition_with_release ──────────────────────────────

const ReleaseTracker = struct {
    fired_count: u32 = 0,
    last_ctx: ?*anyopaque = null,
};

fn trackRelease(ctx: ?*anyopaque) callconv(.c) void {
    const tracker: *ReleaseTracker = @ptrCast(@alignCast(ctx.?));
    tracker.fired_count += 1;
    tracker.last_ctx = ctx;
}

test "waitset: attach_condition_with_release fires on explicit detach_condition, exactly once" {
    const ws_boxed = try newWaitSetHandle();
    defer destroyWaitSetHandle(ws_boxed);
    const gc_boxed = try newGuardConditionHandle();
    defer destroyGuardConditionHandle(gc_boxed);

    var tracker = ReleaseTracker{};
    // Manual native-level equivalent of the generated
    // DDS_GuardCondition_as_DDS_Condition (a --zig-generate-c-api-only
    // symbol this file can't reference unconditionally, since it compiles
    // even without that flag -- see the DataReader cross-view identity
    // test above for the identical reasoning).
    const gc_native = zidl_bindings.unboxAsView(DDS.GuardCondition, gc_boxed);
    const cond_native = gc_native.vtable.as_Condition(gc_native.ptr);
    const c_boxed = cond_native.vtable.get_c_abi_handle(cond_native.ptr);
    var accepted = false;
    try testing.expectEqual(
        DDS.RETCODE_OK,
        extensions.zzdds_waitset_attach_condition_with_release(ws_boxed, c_boxed, &tracker, trackRelease, &accepted),
    );
    try testing.expect(accepted);
    try testing.expectEqual(@as(u32, 0), tracker.fired_count);

    const ws = zidl_bindings.unboxAs(DDS.WaitSet, ws_boxed);
    const c = zidl_bindings.unboxAsView(DDS.Condition, c_boxed);
    try testing.expectEqual(DDS.RETCODE_OK, ws.detach_condition(c));

    try testing.expectEqual(@as(u32, 1), tracker.fired_count);
    try testing.expectEqual(@as(?*anyopaque, &tracker), tracker.last_ctx);

    // Detaching again is a no-op (already gone) — must not double-fire.
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, ws.detach_condition(c));
    try testing.expectEqual(@as(u32, 1), tracker.fired_count);
}

test "waitset: attach_condition_with_release fires when the WaitSet is destroyed while still attached" {
    const ws_boxed = try newWaitSetHandle();
    const gc_boxed = try newGuardConditionHandle();
    defer destroyGuardConditionHandle(gc_boxed);

    var tracker = ReleaseTracker{};
    // Manual native-level equivalent of the generated
    // DDS_GuardCondition_as_DDS_Condition (a --zig-generate-c-api-only
    // symbol this file can't reference unconditionally, since it compiles
    // even without that flag -- see the DataReader cross-view identity
    // test above for the identical reasoning).
    const gc_native = zidl_bindings.unboxAsView(DDS.GuardCondition, gc_boxed);
    const cond_native = gc_native.vtable.as_Condition(gc_native.ptr);
    const c_boxed = cond_native.vtable.get_c_abi_handle(cond_native.ptr);
    try testing.expectEqual(
        DDS.RETCODE_OK,
        extensions.zzdds_waitset_attach_condition_with_release(ws_boxed, c_boxed, &tracker, trackRelease, null),
    );

    // No explicit detach_condition() first -- exactly the case this hook
    // exists for (WaitSet attachment is not ownership; nothing else would
    // ever tell a binding this attachment just ended).
    destroyWaitSetHandle(ws_boxed);

    try testing.expectEqual(@as(u32, 1), tracker.fired_count);
}

test "waitset: attach_condition_with_release fires when the condition is destroyed while still attached, and does not double-fire when the WaitSet is destroyed afterward" {
    // No defer for ws_boxed's own destruction -- the test explicitly
    // destroys it itself below, as part of what it's proving.
    const ws_boxed = try newWaitSetHandle();
    const gc_boxed = try newGuardConditionHandle();

    var tracker = ReleaseTracker{};
    // Manual native-level equivalent of the generated
    // DDS_GuardCondition_as_DDS_Condition (a --zig-generate-c-api-only
    // symbol this file can't reference unconditionally, since it compiles
    // even without that flag -- see the DataReader cross-view identity
    // test above for the identical reasoning).
    const gc_native = zidl_bindings.unboxAsView(DDS.GuardCondition, gc_boxed);
    const cond_native = gc_native.vtable.as_Condition(gc_native.ptr);
    const c_boxed = cond_native.vtable.get_c_abi_handle(cond_native.ptr);
    try testing.expectEqual(
        DDS.RETCODE_OK,
        extensions.zzdds_waitset_attach_condition_with_release(ws_boxed, c_boxed, &tracker, trackRelease, null),
    );

    // No explicit detach_condition() first -- the condition's own teardown
    // (WakeupList.invalidateAll -> WaitSetImpl.vtInvalidateHandle) is what
    // must fire this.
    destroyGuardConditionHandle(gc_boxed);
    try testing.expectEqual(@as(u32, 1), tracker.fired_count);

    // The condition already removed itself from ws.conditions above -- the
    // WaitSet's own teardown (reallyDeinit) below must find nothing left to
    // fire a second time for.
    destroyWaitSetHandle(ws_boxed);
    try testing.expectEqual(@as(u32, 1), tracker.fired_count);
}

test "waitset: attach_condition_with_release on an already-attached condition does not replace the original registration" {
    const ws_boxed = try newWaitSetHandle();
    defer destroyWaitSetHandle(ws_boxed);
    const gc_boxed = try newGuardConditionHandle();
    defer destroyGuardConditionHandle(gc_boxed);

    var first = ReleaseTracker{};
    var second = ReleaseTracker{};
    // Manual native-level equivalent of the generated
    // DDS_GuardCondition_as_DDS_Condition (a --zig-generate-c-api-only
    // symbol this file can't reference unconditionally, since it compiles
    // even without that flag -- see the DataReader cross-view identity
    // test above for the identical reasoning).
    const gc_native = zidl_bindings.unboxAsView(DDS.GuardCondition, gc_boxed);
    const cond_native = gc_native.vtable.as_Condition(gc_native.ptr);
    const c_boxed = cond_native.vtable.get_c_abi_handle(cond_native.ptr);
    var first_accepted = false;
    try testing.expectEqual(
        DDS.RETCODE_OK,
        extensions.zzdds_waitset_attach_condition_with_release(ws_boxed, c_boxed, &first, trackRelease, &first_accepted),
    );
    try testing.expect(first_accepted);
    // Redundant attach with a DIFFERENT context -- must be a no-op, per
    // WaitSetImpl.attachConditionWithRelease's own doc comment (silently
    // swapping the registration risks never firing `first`'s release).
    // out_accepted must report false here -- this is the exact signal
    // callers (java_runtime/zzdds_java_runtime.c, zzdds_cpp.hpp) now rely on
    // to know, race-free, that `second` was never stored and must be
    // cleaned up locally rather than waiting for a release that will never
    // come (Greptile PR #62 review history).
    var second_accepted = true;
    try testing.expectEqual(
        DDS.RETCODE_OK,
        extensions.zzdds_waitset_attach_condition_with_release(ws_boxed, c_boxed, &second, trackRelease, &second_accepted),
    );
    try testing.expect(!second_accepted);

    const ws = zidl_bindings.unboxAs(DDS.WaitSet, ws_boxed);
    const c = zidl_bindings.unboxAsView(DDS.Condition, c_boxed);
    try testing.expectEqual(DDS.RETCODE_OK, ws.detach_condition(c));

    try testing.expectEqual(@as(u32, 1), first.fired_count);
    try testing.expectEqual(@as(u32, 0), second.fired_count);
}

// ── Zig-native createWaitSet / createGuardCondition (raw_ops.zig) ───────────────

test "waitset: Zig-native zzdds.createWaitSet/createGuardCondition round trip" {
    const alloc = testing.allocator;

    const ws = try zzdds.createWaitSet(alloc);
    defer ws.deinit();
    const gc = try zzdds.createGuardCondition(alloc);
    defer gc.deinit();

    const cond = gc.vtable.as_Condition(gc.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, ws.attach_condition(cond));
    try testing.expectEqual(DDS.RETCODE_OK, gc.set_trigger_value(true));

    var active = DDS.ConditionSeq{};
    const zero = DDS.Duration_t{ .sec = 0, .nanosec = 0 };
    try testing.expectEqual(DDS.RETCODE_OK, ws.wait(&active, zero));
    try testing.expectEqual(@as(u32, 1), active._length);
    if (active._release) {
        if (active._buffer) |b| alloc.free(b[0..active._maximum]);
    }
}

// ── C-ABI handle coverage: real Topic / ContentFilteredTopic ──────────────────

test "topic: get_c_abi_handle boxes Topic, Entity, and TopicDescription views" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.topic_w.vtable.get_c_abi_handle(fx.topic_w.ptr);
    const ent = fx.topic_w.vtable.as_Entity(fx.topic_w.ptr);
    _ = ent.vtable.get_c_abi_handle(ent.ptr);
    const td = fx.topic_w.vtable.as_TopicDescription(fx.topic_w.ptr);
    _ = td.vtable.get_c_abi_handle(td.ptr);

    const cft = fx.dp_r.create_contentfilteredtopic("BootCft", fx.topic_r, "", &DDS.StringSeq{});
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft);
    _ = cft.vtable.get_c_abi_handle(cft.ptr);
    const cft_td = cft.vtable.as_TopicDescription(cft.ptr);
    try testing.expect(cft_td.ptr != zzdds.dcps.NIL_PTR);
    _ = cft_td.vtable.get_c_abi_handle(cft_td.ptr);
}

// ── C-ABI handle coverage: real factory / participant / pub / sub / writer / reader ──

test "entities: get_c_abi_handle boxes every remaining real entity and Entity view" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const factory_dds = fx.factory_w.toDDSFactory();
    _ = factory_dds.vtable.get_c_abi_handle(factory_dds.ptr);

    _ = fx.dp_w.vtable.get_c_abi_handle(fx.dp_w.ptr);
    _ = fx.dp_w.vtable.as_Entity(fx.dp_w.ptr).vtable.get_c_abi_handle(fx.dp_w.vtable.as_Entity(fx.dp_w.ptr).ptr);

    _ = fx.pub_w.vtable.get_c_abi_handle(fx.pub_w.ptr);
    _ = fx.pub_w.vtable.as_Entity(fx.pub_w.ptr).vtable.get_c_abi_handle(fx.pub_w.vtable.as_Entity(fx.pub_w.ptr).ptr);

    _ = fx.sub_r.vtable.get_c_abi_handle(fx.sub_r.ptr);
    _ = fx.sub_r.vtable.as_Entity(fx.sub_r.ptr).vtable.get_c_abi_handle(fx.sub_r.vtable.as_Entity(fx.sub_r.ptr).ptr);

    _ = pair.dw.vtable.get_c_abi_handle(pair.dw.ptr);
    _ = pair.dw.vtable.as_Entity(pair.dw.ptr).vtable.get_c_abi_handle(pair.dw.vtable.as_Entity(pair.dw.ptr).ptr);

    _ = pair.dr.vtable.get_c_abi_handle(pair.dr.ptr);
    _ = pair.dr.vtable.as_Entity(pair.dr.ptr).vtable.get_c_abi_handle(pair.dr.vtable.as_Entity(pair.dr.ptr).ptr);
}

const ReadyState = struct {
    calls: usize = 0,
    last_ready: bool = false,
};

fn onReadyCb(_: DDS.InstanceHandle_t, ready: bool, ld: ?*anyopaque) callconv(.c) void {
    const state: *ReadyState = @ptrCast(@alignCast(ld.?));
    state.calls += 1;
    state.last_ready = ready;
}

test "readerSetListenerEx: real C-ABI set_listener_ex delegates to DataReaderImpl.setListenerEx" {
    // kcov showed 0% coverage on readerSetListenerEx (extensions.zig) --
    // every existing on_reliable_writer_ready test calls
    // DataReaderImpl.setListenerEx directly at the Zig level, never through
    // this actual C-ABI entry point (zzdds_DataReader_set_listener_ex), the
    // one a real C/C++/Java caller uses. Mirrors "get_allocator:
    // extensions-layer C-ABI vtables..." above: reach extensions.zig's own
    // ZZDDS.DataReader.Vtable via the DDS_DataReader_as_zzdds_DataReader
    // checked-downcast path a real caller would use, not the native fat
    // pointer directly.
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Install the listener on the reader *before* the writer exists --
    // default QoS is BEST_EFFORT, so on_reliable_writer_ready fires
    // immediately at match (no heartbeat handshake to wait for), and the
    // match is made by the time create_datawriter has settled:
    // deterministic, no polling needed.
    const td = @as(*TopicImpl, @ptrCast(@alignCast(fx.topic_r.ptr))).toTopicDescription();
    const dr = fx.sub_r.create_datareader(td, .{}, null, 0);

    const zdr_boxed = extensions.DDS_DataReader_as_zzdds_DataReader(dr.vtable.get_c_abi_handle(dr.ptr)).?;
    const zdr = zidl_bindings.unboxAsView(ZZDDS.DataReader, zdr_boxed);

    var state = ReadyState{};
    const listener = ZZDDS.DataReaderListenerEx{
        .listener_data = &state,
        .on_reliable_writer_ready = onReadyCb,
    };
    try testing.expectEqual(DDS.RETCODE_OK, zdr.vtable.set_listener_ex(zdr.ptr, &listener, DDS.STATUS_MASK_ALL));

    _ = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    fx.settle();

    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expect(state.last_ready == true);
}

// ── Destroying the last factory from a listener ──────────────────────────────

/// Deletes its participant and then destroys the factory from the writer's
/// deadline listener. The participant is freed only after the listener
/// returns, so a -Ddebug-allocator build must not check for leaks then.
const DestroyFromListener = struct {
    boxed: *anyopaque,
    dp: DDS.DomainParticipant,
    armed: std.Io.Event = .unset,
    done: std.Io.Event = .unset,
    rc: DDS.ReturnCode_t = -1,

    fn onMissed(_: *anyopaque, _: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
        const self: *DestroyFromListener = @ptrCast(@alignCast(ld.?));
        if (!self.armed.isSet() or self.done.isSet()) return;
        const ext = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, self.boxed);
        const f = ext.vtable.as_DomainParticipantFactory(ext.ptr);
        self.rc = self.dp.delete_contained_entities();
        if (self.rc == DDS.RETCODE_OK) self.rc = f.delete_participant(self.dp);
        extensions.zzdds_destroy_factory(self.boxed);
        self.done.set(testing.io);
    }
};

test "support factory: the last factory can be destroyed from a listener that deleted its participant" {
    const boxed = extensions.zzdds_create_factory().?;
    const ext = zidl_bindings.unboxAsView(ZZDDS.DomainParticipantFactory, boxed);
    const dp = ext.create_participant_ex(test_domain.get(), .{}, null, 0, ZZDDS.DomainParticipantConfig.default());
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    var ctx: DestroyFromListener = .{ .boxed = boxed, .dp = dp };
    const topic = dp.create_topic("DestroyTopic", "DestroyType", .{}, null, 0);
    const publisher = dp.create_publisher(.{}, null, 0);
    var q: DDS.DataWriterQos = .{};
    q.deadline.period = .{ .sec = 0, .nanosec = 50_000_000 };
    const dw = publisher.create_datawriter(topic, q, .{ .listener_data = &ctx, .on_offered_deadline_missed = DestroyFromListener.onMissed }, DDS.OFFERED_DEADLINE_MISSED_STATUS);
    try testing.expect(dw.ptr != zzdds.dcps.NIL_PTR);
    writeRawViaOp(dw, KEY_HASH, &PAYLOAD);
    // Under Valgrind the first deadline can fire before create_datawriter's
    // announcement returns. This test destroys the factory from a listener
    // after setup, so explicitly order that destruction after the API calls.
    ctx.armed.set(testing.io);
    try ctx.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try testing.expectEqual(DDS.RETCODE_OK, ctx.rc);
}

// ── Generated factory construction, get_instance and delete_instance ─────────
//
// Through the provider functions zidl's generated C functions call
// (extensions.CAbiProvider): this test build generates no C API. The C
// functions themselves are exercised by test/bindings/smoke.

const Ctors = extensions.CAbiProvider.constructors(ZZDDS.DomainParticipantFactory);
const Statics = extensions.CAbiProvider.statics(DDS.DomainParticipantFactory);

fn createOwn() !ZZDDS.DomainParticipantFactory {
    // libc's allocator is what the generated function passes for "none".
    return Ctors.create(std.heap.c_allocator);
}

test "factory: get_instance returns one process-wide factory until delete_instance" {
    try testing.expectEqual(DDS.RETCODE_OK, Statics.delete_instance());
    const factory = Statics.get_instance();
    try testing.expect(factory.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(factory.ptr, Statics.get_instance().ptr);

    // Nobody owns it: its zzdds view's destroy refuses, and release and the
    // deprecated zzdds_destroy_factory leave it alone.
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, extensions.factory_vtable.destroy(factory.ptr));
    extensions.factory_vtable.release(factory.ptr);
    extensions.zzdds_destroy_factory(factory.vtable.get_c_abi_handle(factory.ptr));

    const dp = DDS_DomainParticipantFactory_create_participant_for_test(factory, test_domain.get(), null);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, Statics.delete_instance());
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
    try testing.expectEqual(DDS.RETCODE_OK, Statics.delete_instance());
    try testing.expectEqual(DDS.RETCODE_OK, Statics.delete_instance());

    // The next get_instance creates a new one, which works.
    const next = Statics.get_instance();
    const dp2 = DDS_DomainParticipantFactory_create_participant_for_test(next, test_domain.get(), null);
    try testing.expect(dp2.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(DDS.RETCODE_OK, next.delete_participant(dp2));
    try testing.expectEqual(DDS.RETCODE_OK, Statics.delete_instance());
}

test "factory: the constructor's destroy refuses while participants remain, and release deletes them" {
    const own = try createOwn();
    const factory = own.vtable.as_DomainParticipantFactory(own.ptr);
    const dp = DDS_DomainParticipantFactory_create_participant_for_test(factory, test_domain.get(), null);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, own.vtable.destroy(own.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
    try testing.expectEqual(DDS.RETCODE_OK, own.vtable.destroy(own.ptr));

    const own2 = try createOwn();
    const factory2 = own2.vtable.as_DomainParticipantFactory(own2.ptr);
    try testing.expect(DDS_DomainParticipantFactory_create_participant_for_test(factory2, test_domain.get(), null).ptr != zzdds.dcps.NIL_PTR);
    own2.vtable.release(own2.ptr); // deletes the participant too
}

test "factory: the constructor allocates through a caller's allocator" {
    var track = TrackingCtx{ .child = testing.allocator };
    const c_alloc = zidl_bindings.ZidlAllocator{
        .ctx = &track,
        .alloc = trackAlloc,
        .resize = trackResize,
        .free = trackFree,
    };
    const own = try Ctors.create(zidl_bindings.toAllocator(&c_alloc));
    try testing.expect(track.alloc_calls.load(.monotonic) > 0);
    try testing.expectEqual(DDS.RETCODE_OK, own.vtable.destroy(own.ptr));
}

test "factory: delete_contained_entities deletes every participant, or none while a loan is out" {
    const own = try createOwn();
    defer own.vtable.release(own.ptr);
    const factory = own.vtable.as_DomainParticipantFactory(own.ptr);

    const quiet = DDS_DomainParticipantFactory_create_participant_for_test(factory, test_domain.get(), null);
    const dp = DDS_DomainParticipantFactory_create_participant_for_test(factory, test_domain.get(), null);
    try testing.expect(quiet.ptr != zzdds.dcps.NIL_PTR and dp.ptr != zzdds.dcps.NIL_PTR);
    const ext_dp = zidl_bindings.unboxAsView(ZZDDS.DomainParticipant, extensions.DDS_DomainParticipant_as_zzdds_DomainParticipant(dp.vtable.get_c_abi_handle(dp.ptr)).?);
    try testing.expectEqual(DDS.RETCODE_OK, ext_dp.register_type_support("KeylessSmoke"));
    const topic = dp.create_topic("FactoryDceLoan", "KeylessSmoke", .{}, null, 0);
    const publisher = dp.create_publisher(.{}, null, 0);
    const dw = publisher.create_datawriter(topic, .{}, null, 0);
    try testing.expect(dw.ptr != zzdds.dcps.NIL_PTR);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    const buf = try dw_impl.loanForWrite(1);

    // One participant has a loan out: nothing is deleted, either one.
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, factory.vtable.delete_contained_entities(factory.ptr));
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, own.vtable.destroy(own.ptr));
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, dw_impl.checkDeletePrecondition());

    dw_impl.cancelLoan(buf);
    try testing.expectEqual(DDS.RETCODE_OK, factory.vtable.delete_contained_entities(factory.ptr));
    // Both participants are gone: the factory no longer knows either.
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, factory.delete_participant(quiet));
    try testing.expect(factory.lookup_participant(test_domain.get()).ptr == zzdds.dcps.NIL_PTR);
}

test "factory: release with a write loan out leaves the writer to take the loan back" {
    const own = try createOwn();
    const factory = own.vtable.as_DomainParticipantFactory(own.ptr);
    const dp = DDS_DomainParticipantFactory_create_participant_for_test(factory, test_domain.get(), null);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    const ext_dp = zidl_bindings.unboxAsView(ZZDDS.DomainParticipant, extensions.DDS_DomainParticipant_as_zzdds_DomainParticipant(dp.vtable.get_c_abi_handle(dp.ptr)).?);
    try testing.expectEqual(DDS.RETCODE_OK, ext_dp.register_type_support("KeylessSmoke"));
    const topic = dp.create_topic("FactoryReleaseLoan", "KeylessSmoke", .{}, null, 0);
    var qos: DDS.DataWriterQos = .{};
    qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dw = dp.create_publisher(.{}, null, 0).create_datawriter(topic, qos, null, 0);
    try testing.expect(dw.ptr != zzdds.dcps.NIL_PTR);
    const dw_handle = dw.vtable.get_c_abi_handle(dw.ptr);
    var loan = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.loan_raw(dw.ptr, 4, &loan));

    // The cascade tears the participant down, its transport included; the
    // writer and its protocol writer stay until the loan comes back.
    own.vtable.release(own.ptr);
    try testing.expect(!zidl_bindings.isEntityBoxRetired(dw_handle));
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, dw.assert_liveliness());
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.return_loan_raw(dw.ptr, &loan));
}

const FactoryDceThread = struct {
    factory: DDS.DomainParticipantFactory,
    rc: std.atomic.Value(DDS.ReturnCode_t) = .init(-1),

    fn run(self: *FactoryDceThread) void {
        self.rc.store(self.factory.vtable.delete_contained_entities(self.factory.ptr), .release);
    }
};

test "factory: strict destroy refuses while delete_contained_entities is checking participants" {
    const own = try createOwn();
    var destroyed = false;
    defer if (!destroyed) own.vtable.release(own.ptr);
    const factory = own.vtable.as_DomainParticipantFactory(own.ptr);
    const domain = test_domain.get();

    const dp = DDS_DomainParticipantFactory_create_participant_for_test(factory, domain, null);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    const ext_dp = zidl_bindings.unboxAsView(ZZDDS.DomainParticipant, extensions.DDS_DomainParticipant_as_zzdds_DomainParticipant(dp.vtable.get_c_abi_handle(dp.ptr)).?);
    try testing.expectEqual(DDS.RETCODE_OK, ext_dp.register_type_support("KeylessSmoke"));
    const topic = dp.create_topic("FactoryDceRace", "KeylessSmoke", .{}, null, 0);
    const dw = dp.create_publisher(.{}, null, 0).create_datawriter(topic, .{}, null, 0);
    try testing.expect(dw.ptr != zzdds.dcps.NIL_PTR);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    const buf = try dw_impl.loanForWrite(1);
    defer dw_impl.cancelLoan(buf);

    // Holding the participant's lock stops delete_contained_entities in its
    // loan check, after it has taken the participant out of the factory's
    // list (lookup_participant no longer finds it).
    const dp_impl: *zzdds.dcps.DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    dp_impl.mu.lock();
    var locked = true;
    errdefer if (locked) dp_impl.mu.unlock();
    var dce: FactoryDceThread = .{ .factory = factory };
    const t = try std.Thread.spawn(.{}, FactoryDceThread.run, .{&dce});
    defer t.join();
    // Unlocks before the join on a failure.
    errdefer if (locked) {
        locked = false;
        dp_impl.mu.unlock();
    };
    var spins: usize = 0;
    while (factory.lookup_participant(domain).ptr != zzdds.dcps.NIL_PTR) : (spins += 1) {
        try testing.expect(spins < 1_000_000);
        std.Thread.yield() catch {};
    }

    // The participant still exists, so the strict destroy refuses.
    const destroy_rc = own.vtable.destroy(own.ptr);
    destroyed = destroy_rc == DDS.RETCODE_OK;
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, destroy_rc);

    locked = false;
    dp_impl.mu.unlock();
    while (dce.rc.load(.acquire) == -1) std.Thread.yield() catch {};
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, dce.rc.load(.acquire));
    // Put back, in a factory that is still open.
    try testing.expectEqual(dp.ptr, factory.lookup_participant(domain).ptr);
    const dp2 = DDS_DomainParticipantFactory_create_participant_for_test(factory, domain, null);
    try testing.expect(dp2.ptr != zzdds.dcps.NIL_PTR);
}

test "factory: the nil factory's delete_contained_entities fails" {
    const n = extensions.CAbiProvider.nil(DDS.DomainParticipantFactory);
    try testing.expect(n.vtable.delete_contained_entities(n.ptr) != DDS.RETCODE_OK);
    const zn = extensions.CAbiProvider.nil(ZZDDS.DomainParticipantFactory);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, zn.vtable.destroy(zn.ptr));
}
