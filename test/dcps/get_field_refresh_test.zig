//! Regression tests for DataReaderImpl.refreshGetFieldFn and the
//! participant/subscriber wiring that drives it (see reader.zig's cft_ptr
//! field and subscriber.zig's ParticipantCbs.register_get_field_refresh doc
//! comment).
//!
//! Both bugs here were flagged by review after the fact:
//!   1. A reader-creation race where the get_field getter returned by
//!      register_get_field_refresh could be assigned to dr.get_field_fn
//!      *after* a concurrent TypeSupport replacement had already refreshed
//!      (and freed the old ctx behind) that same field -- fixed by having
//!      the participant invoke the refresh callback synchronously, under
//!      its own lock, instead of returning a value for the caller to assign.
//!   2. refreshGetFieldFn dropping the whole cft_filter (including cft_ptr)
//!      whenever a TypeSupport replacement temporarily had no get_field,
//!      permanently losing the CFT association even if a later replacement
//!      brought get_field back -- fixed by storing cft_ptr separately on the
//!      reader and always deriving cft_filter from it.
//!
//! This file directly exercises (2), which is fully deterministic. (1) is a
//! genuine timing race between threads; the fix closes it structurally (the
//! racy "return current getter, then have the caller assign it outside the
//! lock" API no longer exists -- see subscriber.zig), which isn't practical
//! to reproduce with a single-threaded interleaving test.

const std = @import("std");
const test_domain = @import("test_domain");
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const filter = zzdds.dcps.filter;
const FilterValue = filter.FilterValue;
const ContentFilteredTopicImpl = zzdds.dcps.ContentFilteredTopicImpl;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;

// get_field implementations distinguishable by identity (compared via
// function pointer equality on TypeSupport.get_field / CdrFieldGetter.func).
fn getFieldA(_: *anyopaque, _: []const u8, _: []const u8, _: []u8) ?FilterValue {
    return .{ .int = 1 };
}
fn getFieldB(_: *anyopaque, _: []const u8, _: []const u8, _: []u8) ?FilterValue {
    return .{ .int = 2 };
}
fn noopKeyHash(_: *anyopaque, _: []const u8) [16]u8 {
    return std.mem.zeroes([16]u8);
}

const Fixture = struct {
    alloc: std.mem.Allocator,
    delivery: zzdds.intraprocess.IntraProcessDelivery,
    t_r: *zzdds.intraprocess.MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("GfrTopic", "GfrType", .{}, null, 0);

        return .{
            .alloc = alloc,
            .delivery = delivery,
            .t_r = t_r,
            .d_r = d_r,
            .factory_r = factory_r,
            .dp_r = dp_r,
            .sub_r = sub_r,
            .topic_r = topic_r,
        };
    }

    fn deinit(self: *Fixture) void {
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        self.factory_r.deinit();
        self.d_r.deinit();
        self.t_r.deinit();
        self.delivery.deinit();
    }

    fn dpImpl(self: *const Fixture) *DomainParticipantImpl {
        return @ptrCast(@alignCast(self.dp_r.ptr));
    }
};

test "get_field refresh: CFT association survives a getter loss and restore" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Register TypeSupport with a get_field getter *before* creating the
    // reader, so cft_filter is populated right away at creation time.
    _ = fx.dpImpl().registerTypeSupport("GfrType", .{
        .ctx = undefined,
        .compute_key_hash = noopKeyHash,
        .get_field = getFieldA,
    });

    const cft_dds = fx.dp_r.create_contentfilteredtopic("GfrCft", fx.topic_r, "", &DDS.StringSeq{});
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft_dds);
    const cft: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft_dds.ptr));

    const dr_raw = fx.sub_r.create_datareader(cft.toTopicDescription(), .{}, null, 0);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    dr.mu.lock();
    try testing.expect(dr.cft_ptr == cft);
    try testing.expect(dr.cft_filter != null);
    try testing.expectEqual(&getFieldA, dr.cft_filter.?.get_field_fn.func);
    dr.mu.unlock();

    // Replace TypeSupport with one that offers no get_field at all -- this
    // is the "type re-registered without get_field" scenario. cft_filter
    // should drop (there's no CftFilterState shape for "CFT but no
    // getter"), but the CFT association itself (cft_ptr) must survive.
    _ = fx.dpImpl().registerTypeSupport("GfrType", .{
        .ctx = undefined,
        .compute_key_hash = noopKeyHash,
        .get_field = null,
    });

    dr.mu.lock();
    try testing.expect(dr.get_field_fn == null);
    try testing.expect(dr.cft_filter == null);
    try testing.expect(dr.cft_ptr == cft); // association preserved
    dr.mu.unlock();

    // Replace TypeSupport a third time with get_field available again.
    // Without the fix, cft_ptr would have been discarded in the previous
    // step and this reader's CFT filtering would stay disabled forever.
    _ = fx.dpImpl().registerTypeSupport("GfrType", .{
        .ctx = undefined,
        .compute_key_hash = noopKeyHash,
        .get_field = getFieldB,
    });

    dr.mu.lock();
    defer dr.mu.unlock();
    try testing.expect(dr.cft_filter != null);
    try testing.expect(dr.cft_filter.?.cft_ptr == cft);
    try testing.expectEqual(&getFieldB, dr.cft_filter.?.get_field_fn.func);
}

test "get_field refresh: reader created against a CFT before any TypeSupport has no cft_filter yet" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const cft_dds = fx.dp_r.create_contentfilteredtopic("GfrCft2", fx.topic_r, "", &DDS.StringSeq{});
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft_dds);
    const cft: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft_dds.ptr));

    const dr_raw = fx.sub_r.create_datareader(cft.toTopicDescription(), .{}, null, 0);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    dr.mu.lock();
    try testing.expect(dr.cft_ptr == cft);
    try testing.expect(dr.cft_filter == null);
    try testing.expect(dr.get_field_fn == null);
    dr.mu.unlock();
}
