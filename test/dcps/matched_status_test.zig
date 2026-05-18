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
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .random, .{});
        errdefer factory_w.deinit();
        const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        const pub_w = dp_w.vtable.create_publisher(dp_w.ptr, .{}, nil.nil_pub_listener, 0);
        const topic_w = dp_w.vtable.create_topic(dp_w.ptr, "MatchTopic", "MatchType", .{}, nil.nil_topic_listener, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        const sub_r = dp_r.vtable.create_subscriber(dp_r.ptr, .{}, nil.nil_sub_listener, 0);
        const topic_r = dp_r.vtable.create_topic(dp_r.ptr, "MatchTopic", "MatchType", .{}, nil.nil_topic_listener, 0);

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

fn dwOnPubMatched(ctx: *anyopaque, _: DDS.DataWriter, s: DDS.PublicationMatchedStatus) void {
    @as(*DDS.PublicationMatchedStatus, @ptrCast(@alignCast(ctx))).* = s;
}
fn dwNoopIncompat(_: *anyopaque, _: DDS.DataWriter, _: DDS.OfferedIncompatibleQosStatus) void {}
fn dwNoopDeadline(_: *anyopaque, _: DDS.DataWriter, _: DDS.OfferedDeadlineMissedStatus) void {}
fn dwNoopLiveliness(_: *anyopaque, _: DDS.DataWriter, _: DDS.LivelinessLostStatus) void {}
fn dwNoopDeinit(_: *anyopaque) void {}

fn drOnSubMatched(ctx: *anyopaque, _: DDS.DataReader, s: DDS.SubscriptionMatchedStatus) void {
    @as(*DDS.SubscriptionMatchedStatus, @ptrCast(@alignCast(ctx))).* = s;
}
fn drNoopIncompat(_: *anyopaque, _: DDS.DataReader, _: DDS.RequestedIncompatibleQosStatus) void {}
fn drNoopDeadline(_: *anyopaque, _: DDS.DataReader, _: DDS.RequestedDeadlineMissedStatus) void {}
fn drNoopSampleRejected(_: *anyopaque, _: DDS.DataReader, _: DDS.SampleRejectedStatus) void {}
fn drNoopLivelinessChanged(_: *anyopaque, _: DDS.DataReader, _: DDS.LivelinessChangedStatus) void {}
fn drNoopDataAvail(_: *anyopaque, _: DDS.DataReader) void {}
fn drNoopSampleLost(_: *anyopaque, _: DDS.DataReader, _: DDS.SampleLostStatus) void {}
fn drNoopDeinit(_: *anyopaque) void {}

const dw_matched_vtable = DDS.DataWriterListener.Vtable{
    .on_offered_deadline_missed = dwNoopDeadline,
    .on_offered_incompatible_qos = dwNoopIncompat,
    .on_liveliness_lost = dwNoopLiveliness,
    .on_publication_matched = dwOnPubMatched,
    .deinit = dwNoopDeinit,
};

const dr_matched_vtable = DDS.DataReaderListener.Vtable{
    .on_requested_deadline_missed = drNoopDeadline,
    .on_requested_incompatible_qos = drNoopIncompat,
    .on_sample_rejected = drNoopSampleRejected,
    .on_liveliness_changed = drNoopLivelinessChanged,
    .on_data_available = drNoopDataAvail,
    .on_subscription_matched = drOnSubMatched,
    .on_sample_lost = drNoopSampleLost,
    .deinit = drNoopDeinit,
};

// ── Tests: polling path ───────────────────────────────────────────────────────

test "pub_matched: status populated when reader is created after writer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Create the writer first; no readers yet.
    const dw_raw = fx.pub_w.vtable.create_datawriter(fx.pub_w.ptr, fx.topic_w, .{}, nil.nil_dw_listener, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    // No match yet.
    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.current_count);

    // Create a matching reader — DirectDiscovery fires synchronously.
    const dr_raw = fx.sub_r.vtable.create_datareader(fx.sub_r.ptr, topicDesc(fx.topic_r), .{}, nil.nil_dr_listener, 0);
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
    const dr_raw = fx.sub_r.vtable.create_datareader(fx.sub_r.ptr, topicDesc(fx.topic_r), .{}, nil.nil_dr_listener, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    var s = DDS.SubscriptionMatchedStatus{};
    _ = dr_raw.vtable.get_subscription_matched_status(dr_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);

    // Now create the writer.
    const dw_raw = fx.pub_w.vtable.create_datawriter(fx.pub_w.ptr, fx.topic_w, .{}, nil.nil_dw_listener, 0);
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

    const dw_raw = fx.pub_w.vtable.create_datawriter(fx.pub_w.ptr, fx.topic_w, .{}, nil.nil_dw_listener, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    // First reader matches.
    const dr1_raw = fx.sub_r.vtable.create_datareader(fx.sub_r.ptr, topicDesc(fx.topic_r), .{}, nil.nil_dr_listener, 0);
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
    const dr2_raw = fx.sub_r.vtable.create_datareader(fx.sub_r.ptr, topicDesc(fx.topic_r), .{}, nil.nil_dr_listener, 0);
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

    const dw_raw = fx.pub_w.vtable.create_datawriter(fx.pub_w.ptr, fx.topic_w, .{}, nil.nil_dw_listener, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    const dr_raw = fx.sub_r.vtable.create_datareader(fx.sub_r.ptr, topicDesc(fx.topic_r), .{}, nil.nil_dr_listener, 0);

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

    const dr_raw = fx.sub_r.vtable.create_datareader(fx.sub_r.ptr, topicDesc(fx.topic_r), .{}, nil.nil_dr_listener, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    const dw_raw = fx.pub_w.vtable.create_datawriter(fx.pub_w.ptr, fx.topic_w, .{}, nil.nil_dw_listener, 0);

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
    const listener = DDS.DataWriterListener{
        .ptr = &captured,
        .vtable = &dw_matched_vtable,
    };
    const dw_raw = fx.pub_w.vtable.create_datawriter(
        fx.pub_w.ptr,
        fx.topic_w,
        .{},
        listener,
        DDS.PUBLICATION_MATCHED_STATUS,
    );
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    // Listener not yet fired (no reader exists).
    try testing.expectEqual(@as(i32, 0), captured.total_count);

    const dr_raw = fx.sub_r.vtable.create_datareader(fx.sub_r.ptr, topicDesc(fx.topic_r), .{}, nil.nil_dr_listener, 0);
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
    const listener = DDS.DataWriterListener{
        .ptr = &captured,
        .vtable = &dw_matched_vtable,
    };
    const dw_raw = fx.pub_w.vtable.create_datawriter(
        fx.pub_w.ptr,
        fx.topic_w,
        .{},
        listener,
        DDS.PUBLICATION_MATCHED_STATUS,
    );
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    const dr_raw = fx.sub_r.vtable.create_datareader(fx.sub_r.ptr, topicDesc(fx.topic_r), .{}, nil.nil_dr_listener, 0);
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
    const listener = DDS.DataReaderListener{
        .ptr = &captured,
        .vtable = &dr_matched_vtable,
    };
    const dr_raw = fx.sub_r.vtable.create_datareader(
        fx.sub_r.ptr,
        topicDesc(fx.topic_r),
        .{},
        listener,
        DDS.SUBSCRIPTION_MATCHED_STATUS,
    );
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    try testing.expectEqual(@as(i32, 0), captured.total_count);

    const dw_raw = fx.pub_w.vtable.create_datawriter(fx.pub_w.ptr, fx.topic_w, .{}, nil.nil_dw_listener, 0);
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
    const listener = DDS.DataReaderListener{
        .ptr = &captured,
        .vtable = &dr_matched_vtable,
    };
    const dr_raw = fx.sub_r.vtable.create_datareader(
        fx.sub_r.ptr,
        topicDesc(fx.topic_r),
        .{},
        listener,
        DDS.SUBSCRIPTION_MATCHED_STATUS,
    );
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    const dw_raw = fx.pub_w.vtable.create_datawriter(fx.pub_w.ptr, fx.topic_w, .{}, nil.nil_dw_listener, 0);
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

    const dw_raw = fx.pub_w.vtable.create_datawriter(fx.pub_w.ptr, fx.topic_w, .{}, nil.nil_dw_listener, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);
    const dr_raw = fx.sub_r.vtable.create_datareader(fx.sub_r.ptr, topicDesc(fx.topic_r), .{}, nil.nil_dr_listener, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);

    var handles = DDS.InstanceHandleSeq.empty;
    defer handles.deinit(alloc);
    _ = dw_raw.vtable.get_matched_subscriptions(dw_raw.ptr, &handles);

    try testing.expectEqual(@as(usize, 1), handles.items.len);
    try testing.expectEqual(handles.items[0], s.last_subscription_handle);
}
