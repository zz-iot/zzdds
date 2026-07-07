//! Phase 32 on_publication_matched / on_subscription_matched tests.
//!
//! Covers the polling path (get_publication/subscription_matched_status) and the
//! listener path (on_publication/subscription_matched callbacks).  Uses
//! IntraProcessDelivery + DirectDiscovery, which fires discovery callbacks
//! synchronously so every assertion is deterministic.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;

fn topicDesc(t: DDS.Topic) DDS.TopicDescription {
    return (@as(*TopicImpl, @ptrCast(@alignCast(t.ptr)))).toTopicDescription();
}

const testing = std.testing;

// ── Fixture ───────────────────────────────────────────────────────────────────
// Two separate participants: one on the writer side, one on the reader side.

const Fixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,

    t_w: *zzdds.intraprocess.MemoryTransport,
    d_w: *zzdds.intraprocess.DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    pub_w: DDS.Publisher,
    topic_w: DDS.Topic,

    t_r: *zzdds.intraprocess.MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_w.deinit();
        const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("MatchTopic", "MatchType", .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("MatchTopic", "MatchType", .{}, null, 0);

        return .{
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
        _ = self.factory_w.toDDSFactory().delete_participant(self.dp_w);
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        self.factory_w.deinit();
        self.factory_r.deinit();
        self.d_w.deinit();
        self.d_r.deinit();
        self.t_w.deinit();
        self.t_r.deinit();
        self.delivery.deinit();
    }
};

// ── Listener helpers ──────────────────────────────────────────────────────────

fn dwOnPubMatched(_: *anyopaque, s: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*DDS.PublicationMatchedStatus, @ptrCast(@alignCast(ld))).* = s.*;
}
fn drOnSubMatched(_: *anyopaque, s: *const DDS.SubscriptionMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*DDS.SubscriptionMatchedStatus, @ptrCast(@alignCast(ld))).* = s.*;
}

fn dwMatchedListener(ctx: *DDS.PublicationMatchedStatus) DDS.DataWriterListener {
    return .{ .listener_data = ctx, .on_publication_matched = dwOnPubMatched };
}
fn drMatchedListener(ctx: *DDS.SubscriptionMatchedStatus) DDS.DataReaderListener {
    return .{ .listener_data = ctx, .on_subscription_matched = drOnSubMatched };
}

// ── Tests: polling path ───────────────────────────────────────────────────────

test "pub_matched: status populated when reader is created after writer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Create the writer first; no readers yet.
    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    // No match yet.
    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.current_count);

    // Create a matching reader — DirectDiscovery fires synchronously.
    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.current_count);
    try testing.expect(s.last_subscription_handle != 0);
}

test "sub_matched: status populated when writer is created after reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Create the reader first.
    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    var s = DDS.SubscriptionMatchedStatus{};
    _ = dr_raw.vtable.get_subscription_matched_status(dr_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);

    // Now create the writer.
    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    _ = dr_raw.vtable.get_subscription_matched_status(dr_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.current_count);
    try testing.expect(s.last_publication_handle != 0);
}

test "pub_matched: total_count accumulates; change resets after read" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    // First reader matches.
    const dr1_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr1_raw);

    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.total_count_change);
    try testing.expectEqual(@as(i32, 1), s.current_count);
    try testing.expectEqual(@as(i32, 1), s.current_count_change);

    // Reading again resets the change fields.
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.total_count_change);
    try testing.expectEqual(@as(i32, 1), s.current_count);
    try testing.expectEqual(@as(i32, 0), s.current_count_change);

    // Second reader matches: total goes to 2.
    const dr2_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr2_raw);

    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 2), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.total_count_change);
    try testing.expectEqual(@as(i32, 2), s.current_count);
    try testing.expectEqual(@as(i32, 1), s.current_count_change);
}

test "pub_matched: current_count decrements when reader is deleted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);

    // Confirm match.
    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.current_count);

    // Delete the reader — retracts from discovery, fires onReaderLost.
    _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count); // total never decrements
    try testing.expectEqual(@as(i32, 0), s.current_count);
    try testing.expectEqual(@as(i32, -1), s.current_count_change);
}

test "sub_matched: current_count decrements when writer is deleted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);

    var s = DDS.SubscriptionMatchedStatus{};
    _ = dr_raw.vtable.get_subscription_matched_status(dr_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.current_count);

    _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    _ = dr_raw.vtable.get_subscription_matched_status(dr_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.current_count);
    try testing.expectEqual(@as(i32, -1), s.current_count_change);
}

// ── Tests: listener path ──────────────────────────────────────────────────────

test "pub_matched: listener fires with correct status on match" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var captured = DDS.PublicationMatchedStatus{};
    const listener = dwMatchedListener(&captured);
    const dw_raw = fx.pub_w.create_datawriter(
        fx.topic_w,
        .{},
        listener,
        DDS.PUBLICATION_MATCHED_STATUS,
    );
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    // Listener not yet fired (no reader exists).
    try testing.expectEqual(@as(i32, 0), captured.total_count);

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    // Listener fired synchronously by DirectDiscovery.
    try testing.expectEqual(@as(i32, 1), captured.total_count);
    try testing.expectEqual(@as(i32, 1), captured.total_count_change);
    try testing.expectEqual(@as(i32, 1), captured.current_count);
    try testing.expectEqual(@as(i32, 1), captured.current_count_change);
    try testing.expect(captured.last_subscription_handle != 0);
}

test "pub_matched: listener fires on unmatch when reader deleted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var captured = DDS.PublicationMatchedStatus{};
    const listener = dwMatchedListener(&captured);
    const dw_raw = fx.pub_w.create_datawriter(
        fx.topic_w,
        .{},
        listener,
        DDS.PUBLICATION_MATCHED_STATUS,
    );
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    try testing.expectEqual(@as(i32, 1), captured.total_count);

    // Reset the capture, then delete the reader.
    captured = .{};
    _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    // Listener fires with current_count = 0, change = -1.
    try testing.expectEqual(@as(i32, 0), captured.total_count_change); // no new matches
    try testing.expectEqual(@as(i32, 0), captured.current_count);
    try testing.expectEqual(@as(i32, -1), captured.current_count_change);
}

test "sub_matched: listener fires with correct status on match" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var captured = DDS.SubscriptionMatchedStatus{};
    const listener = drMatchedListener(&captured);
    const dr_raw = fx.sub_r.create_datareader(
        topicDesc(fx.topic_r),
        .{},
        listener,
        DDS.SUBSCRIPTION_MATCHED_STATUS,
    );
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    try testing.expectEqual(@as(i32, 0), captured.total_count);

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    try testing.expectEqual(@as(i32, 1), captured.total_count);
    try testing.expectEqual(@as(i32, 1), captured.total_count_change);
    try testing.expectEqual(@as(i32, 1), captured.current_count);
    try testing.expectEqual(@as(i32, 1), captured.current_count_change);
    try testing.expect(captured.last_publication_handle != 0);
}

test "sub_matched: listener fires on unmatch when writer deleted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var captured = DDS.SubscriptionMatchedStatus{};
    const listener = drMatchedListener(&captured);
    const dr_raw = fx.sub_r.create_datareader(
        topicDesc(fx.topic_r),
        .{},
        listener,
        DDS.SUBSCRIPTION_MATCHED_STATUS,
    );
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    try testing.expectEqual(@as(i32, 1), captured.total_count);

    captured = .{};
    _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    try testing.expectEqual(@as(i32, 0), captured.total_count_change);
    try testing.expectEqual(@as(i32, 0), captured.current_count);
    try testing.expectEqual(@as(i32, -1), captured.current_count_change);
}

test "pub_matched: last_subscription_handle matches get_matched_subscriptions handle" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);
    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);

    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| alloc.free(b[0..handles._length]);
    };
    _ = dw_raw.vtable.get_matched_subscriptions(dw_raw.ptr, &handles);

    try testing.expectEqual(@as(u32, 1), handles._length);
    try testing.expectEqual(handles._buffer.?[0], s.last_subscription_handle);
}
