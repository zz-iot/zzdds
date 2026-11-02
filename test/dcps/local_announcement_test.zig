//! A local endpoint's announcement against its creation and deletion
//! (docs/design/concurrency/architecture.md#local-endpoint-publication-announcement-and-disposal).
//!
//! The writer-side participant's discovery is wrapped so a test can record
//! the SEDP operations it is asked for and run a step (a deletion) in the
//! window after the participant has captured an announcement and before it
//! is written: the window a concurrent `delete_datawriter` or
//! `delete_datareader` lands in.

const std = @import("std");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const disc = zzdds.discovery;
const Guid = zzdds.rtps.guid.Guid;
const noop_security = zzdds.noop_security.noop_security_plugins;

const testing = std.testing;

const TOPIC = "AnnounceTopic";

// ── Recording discovery ───────────────────────────────────────────────────────

const Op = enum { announce_writer, retract_writer, announce_reader, retract_reader };

/// Forwards to `inner`, recording each local endpoint operation, and runs
/// `before_announce` once, just before forwarding the next announcement.
/// With `fail_prepare`, preparing fails as for lack of memory, and with
/// `fail_after`, it does once that many more have succeeded. `nested` is
/// set when an announcement is asked for while one is being written.
const Recorder = struct {
    inner: disc.Discovery,
    ops: [16]Op = undefined,
    n: usize = 0,
    writing: bool = false,
    nested: bool = false,
    fail_prepare: bool = false,
    fail_after: ?usize = null,
    before_announce: ?*const fn (ctx: *anyopaque) void = null,
    before_ctx: *anyopaque = undefined,

    const vtable: disc.Discovery.Vtable = .{
        .start = start,
        .stop = stop,
        .prepare_writer = prepareWriter,
        .adopt_writer = adoptWriter,
        .abandon_writer = abandonWriter,
        .announce_writer = announceWriter,
        .retract_writer = retractWriter,
        .prepare_reader = prepareReader,
        .adopt_reader = adoptReader,
        .abandon_reader = abandonReader,
        .announce_reader = announceReader,
        .retract_reader = retractReader,
        .deinit = deinit,
        .wlp_tick = wlpTick,
    };

    fn discovery(self: *Recorder) disc.Discovery {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn of(ctx: *anyopaque) *Recorder {
        return @ptrCast(@alignCast(ctx));
    }

    fn record(self: *Recorder, op: Op) void {
        self.ops[self.n] = op;
        self.n += 1;
    }

    fn runBeforeAnnounce(self: *Recorder) void {
        const f = self.before_announce orelse return;
        self.before_announce = null;
        f(self.before_ctx);
    }

    fn recorded(self: *const Recorder) []const Op {
        return self.ops[0..self.n];
    }

    fn start(ctx: *anyopaque, local: *const disc.ParticipantAnnouncement, callbacks: *const disc.Callbacks) anyerror!void {
        return of(ctx).inner.start(local, callbacks);
    }
    fn stop(ctx: *anyopaque) void {
        of(ctx).inner.stop();
    }
    fn failing(self: *Recorder) bool {
        if (self.fail_prepare) return true;
        const n = self.fail_after orelse return false;
        if (n == 0) return true;
        self.fail_after = n - 1;
        return false;
    }
    fn prepareWriter(ctx: *anyopaque, info: *const disc.WriterAnnouncement) anyerror!void {
        if (of(ctx).failing()) return error.OutOfMemory;
        return of(ctx).inner.prepareWriter(info);
    }
    fn adoptWriter(ctx: *anyopaque, guid: Guid) void {
        of(ctx).inner.adoptWriter(guid);
    }
    fn abandonWriter(ctx: *anyopaque, guid: Guid) void {
        of(ctx).inner.abandonWriter(guid);
    }
    fn announceWriter(ctx: *anyopaque, guid: Guid) void {
        const self = of(ctx);
        if (self.writing) self.nested = true;
        self.writing = true;
        defer self.writing = false;
        self.runBeforeAnnounce();
        self.record(.announce_writer);
        self.inner.announceWriter(guid);
    }
    fn retractWriter(ctx: *anyopaque, guid: Guid) void {
        of(ctx).record(.retract_writer);
        of(ctx).inner.retractWriter(guid);
    }
    fn prepareReader(ctx: *anyopaque, info: *const disc.ReaderAnnouncement) anyerror!void {
        if (of(ctx).failing()) return error.OutOfMemory;
        return of(ctx).inner.prepareReader(info);
    }
    fn adoptReader(ctx: *anyopaque, guid: Guid) void {
        of(ctx).inner.adoptReader(guid);
    }
    fn abandonReader(ctx: *anyopaque, guid: Guid) void {
        of(ctx).inner.abandonReader(guid);
    }
    fn announceReader(ctx: *anyopaque, guid: Guid) void {
        const self = of(ctx);
        if (self.writing) self.nested = true;
        self.writing = true;
        defer self.writing = false;
        self.runBeforeAnnounce();
        self.record(.announce_reader);
        self.inner.announceReader(guid);
    }
    fn retractReader(ctx: *anyopaque, guid: Guid) void {
        of(ctx).record(.retract_reader);
        of(ctx).inner.retractReader(guid);
    }
    fn deinit(_: *anyopaque) void {}
    fn wlpTick(ctx: *anyopaque, now_ns: i64, info: disc.WlpTickInfo) void {
        of(ctx).inner.wlpTick(now_ns, info);
    }
};

// ── Fixture ───────────────────────────────────────────────────────────────────

/// Participant `a`, whose discovery is recorded, and participant `b`, over
/// IntraProcessDelivery (synchronous delivery). `a`'s Publisher and
/// Subscriber create their endpoints disabled.
const Fixture = struct {
    delivery: IntraProcessDelivery,
    rec: *Recorder,
    t_a: *zzdds.intraprocess.MemoryTransport,
    d_a: *zzdds.intraprocess.DirectDiscovery,
    factory_a: *DomainParticipantFactoryImpl,
    dp_a: DDS.DomainParticipant,
    pub_a: DDS.Publisher,
    sub_a: DDS.Subscriber,
    topic_a: DDS.Topic,
    t_b: *zzdds.intraprocess.MemoryTransport,
    d_b: *zzdds.intraprocess.DirectDiscovery,
    factory_b: *DomainParticipantFactoryImpl,
    dp_b: DDS.DomainParticipant,
    pub_b: DDS.Publisher,
    sub_b: DDS.Subscriber,
    topic_b: DDS.Topic,

    fn init(alloc: std.mem.Allocator, rec: *Recorder) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const config = zzdds.config.Config{};

        const t_a = try delivery.newTransport();
        errdefer t_a.deinit();
        const d_a = try delivery.newDiscovery();
        errdefer d_a.deinit();
        rec.* = .{ .inner = d_a.toDiscovery() };
        const factory_a = try DomainParticipantFactoryImpl.init(alloc, t_a.transport(), rec.discovery(), noop_security, .spec_random, config);
        errdefer factory_a.deinit();
        const dp_a = factory_a.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        var pub_qos = DDS.PublisherQos{};
        pub_qos.entity_factory.autoenable_created_entities = false;
        const pub_a = dp_a.create_publisher(pub_qos, null, 0);
        var sub_qos = DDS.SubscriberQos{};
        sub_qos.entity_factory.autoenable_created_entities = false;
        const sub_a = dp_a.create_subscriber(sub_qos, null, 0);
        const topic_a = dp_a.create_topic(TOPIC, "AnnounceType", .{}, null, 0);

        const t_b = try delivery.newTransport();
        errdefer t_b.deinit();
        const d_b = try delivery.newDiscovery();
        errdefer d_b.deinit();
        const factory_b = try DomainParticipantFactoryImpl.init(alloc, t_b.transport(), d_b.toDiscovery(), noop_security, .spec_random, config);
        errdefer factory_b.deinit();
        const dp_b = factory_b.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const pub_b = dp_b.create_publisher(.{}, null, 0);
        const sub_b = dp_b.create_subscriber(.{}, null, 0);
        const topic_b = dp_b.create_topic(TOPIC, "AnnounceType", .{}, null, 0);

        return .{
            .delivery = delivery,
            .rec = rec,
            .t_a = t_a,
            .d_a = d_a,
            .factory_a = factory_a,
            .dp_a = dp_a,
            .pub_a = pub_a,
            .sub_a = sub_a,
            .topic_a = topic_a,
            .t_b = t_b,
            .d_b = d_b,
            .factory_b = factory_b,
            .dp_b = dp_b,
            .pub_b = pub_b,
            .sub_b = sub_b,
            .topic_b = topic_b,
        };
    }

    fn deinit(self: *Fixture) void {
        _ = self.factory_a.toDDSFactory().delete_participant(self.dp_a);
        _ = self.factory_b.toDDSFactory().delete_participant(self.dp_b);
        self.factory_a.deinit();
        self.factory_b.deinit();
        self.d_a.deinit();
        self.d_b.deinit();
        self.t_a.deinit();
        self.t_b.deinit();
        self.delivery.deinit();
    }
};

fn topicDesc(t: DDS.Topic) DDS.TopicDescription {
    return @as(*TopicImpl, @ptrCast(@alignCast(t.ptr))).toTopicDescription();
}

fn subscriptionMatchedCount(dr: DDS.DataReader) !i32 {
    var st: DDS.SubscriptionMatchedStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_subscription_matched_status(dr.ptr, &st));
    return st.current_count;
}

fn publicationMatchedCount(dw: DDS.DataWriter) !i32 {
    var st: DDS.PublicationMatchedStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.get_publication_matched_status(dw.ptr, &st));
    return st.current_count;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "a writer deleted while its announcement is written is disposed after it" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    const dr_b = fx.sub_b.create_datareader(topicDesc(fx.topic_b), .{}, null, 0);
    const dw_a = fx.pub_a.create_datawriter(fx.topic_a, .{}, null, 0);

    const Delete = struct {
        var publisher: DDS.Publisher = undefined;
        var writer: DDS.DataWriter = undefined;
        fn f(_: *anyopaque) void {
            _ = publisher.vtable.delete_datawriter(publisher.ptr, writer);
        }
    };
    Delete.publisher = fx.pub_a;
    Delete.writer = dw_a;
    rec.before_announce = Delete.f;

    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.enable(dw_a.ptr));
    // The deletion's disposal waits for the announcement, and is its only one.
    try testing.expectEqualSlices(Op, &.{ .announce_writer, .retract_writer }, rec.recorded());
    try testing.expectEqual(@as(i32, 0), try subscriptionMatchedCount(dr_b));
}

test "a reader deleted while its announcement is written is disposed after it" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    const dw_b = fx.pub_b.create_datawriter(fx.topic_b, .{}, null, 0);
    const dr_a = fx.sub_a.create_datareader(topicDesc(fx.topic_a), .{}, null, 0);

    const Delete = struct {
        var subscriber: DDS.Subscriber = undefined;
        var reader: DDS.DataReader = undefined;
        fn f(_: *anyopaque) void {
            _ = subscriber.vtable.delete_datareader(subscriber.ptr, reader);
        }
    };
    Delete.subscriber = fx.sub_a;
    Delete.reader = dr_a;
    rec.before_announce = Delete.f;

    try testing.expectEqual(DDS.RETCODE_OK, dr_a.vtable.enable(dr_a.ptr));
    try testing.expectEqualSlices(Op, &.{ .announce_reader, .retract_reader }, rec.recorded());
    try testing.expectEqual(@as(i32, 0), try publicationMatchedCount(dw_b));
}

test "a writer is in its Publisher when its announcement's matches are reported" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    _ = fx.sub_b.create_datareader(topicDesc(fx.topic_b), .{}, null, 0);

    const Probe = struct {
        var publisher: DDS.Publisher = undefined;
        var calls: u32 = 0;
        var found: bool = false;
        fn onMatched(_: *anyopaque, _: *const DDS.PublicationMatchedStatus, _: ?*anyopaque) callconv(.c) void {
            calls += 1;
            found = publisher.lookup_datawriter(TOPIC).ptr != zzdds.dcps.NIL_PTR;
        }
    };
    // An autoenabling Publisher, so creation announces the writer and the
    // already-discovered reader is matched by that announcement.
    const pub_ = fx.dp_a.create_publisher(.{}, null, 0);
    Probe.publisher = pub_;
    Probe.calls = 0;
    _ = pub_.create_datawriter(fx.topic_a, .{}, .{ .on_publication_matched = Probe.onMatched }, DDS.PUBLICATION_MATCHED_STATUS);
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expect(Probe.found);
}

test "a writer its announcement's match callback deletes is not returned by create_datawriter" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    _ = fx.sub_b.create_datareader(topicDesc(fx.topic_b), .{}, null, 0);

    const Probe = struct {
        var publisher: DDS.Publisher = undefined;
        var rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR;
        fn onMatched(_: *anyopaque, _: *const DDS.PublicationMatchedStatus, _: ?*anyopaque) callconv(.c) void {
            rc = publisher.delete_datawriter(publisher.lookup_datawriter(TOPIC));
        }
    };
    const pub_ = fx.dp_a.create_publisher(.{}, null, 0);
    Probe.publisher = pub_;
    Probe.rc = DDS.RETCODE_ERROR;
    const dw = pub_.create_datawriter(fx.topic_a, .{}, .{ .on_publication_matched = Probe.onMatched }, DDS.PUBLICATION_MATCHED_STATUS);
    try testing.expectEqual(DDS.RETCODE_OK, Probe.rc);
    try testing.expect(dw.ptr == zzdds.dcps.NIL_PTR);
}

test "a reader its announcement's match callback deletes is not returned by create_datareader" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    _ = fx.pub_b.create_datawriter(fx.topic_b, .{}, null, 0);

    const Probe = struct {
        var subscriber: DDS.Subscriber = undefined;
        var rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR;
        fn onMatched(_: *anyopaque, _: *const DDS.SubscriptionMatchedStatus, _: ?*anyopaque) callconv(.c) void {
            rc = subscriber.delete_datareader(subscriber.lookup_datareader(TOPIC));
        }
    };
    const sub = fx.dp_a.create_subscriber(.{}, null, 0);
    Probe.subscriber = sub;
    Probe.rc = DDS.RETCODE_ERROR;
    const dr = sub.create_datareader(topicDesc(fx.topic_a), .{}, .{ .on_subscription_matched = Probe.onMatched }, DDS.SUBSCRIPTION_MATCHED_STATUS);
    try testing.expectEqual(DDS.RETCODE_OK, Probe.rc);
    try testing.expect(dr.ptr == zzdds.dcps.NIL_PTR);
}

test "a writer whose announcement cannot be reserved is not created" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    rec.fail_prepare = true;
    const pub_ = fx.dp_a.create_publisher(.{}, null, 0);
    const dw = pub_.create_datawriter(fx.topic_a, .{}, null, 0);
    try testing.expect(dw.ptr == zzdds.dcps.NIL_PTR);
    try testing.expect(pub_.lookup_datawriter(TOPIC).ptr == zzdds.dcps.NIL_PTR);
    // Only the rollback's retract, which finds nothing prepared.
    try testing.expectEqualSlices(Op, &.{.retract_writer}, rec.recorded());
}

test "a reader whose announcement cannot be reserved is not created" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    rec.fail_prepare = true;
    const sub = fx.dp_a.create_subscriber(.{}, null, 0);
    const dr = sub.create_datareader(topicDesc(fx.topic_a), .{}, null, 0);
    try testing.expect(dr.ptr == zzdds.dcps.NIL_PTR);
    try testing.expect(sub.lookup_datareader(TOPIC).ptr == zzdds.dcps.NIL_PTR);
    try testing.expectEqualSlices(Op, &.{.retract_reader}, rec.recorded());
}

fn partitionNames(names: []const [*:0]const u8) DDS.PartitionQosPolicy {
    const len: u32 = @intCast(names.len);
    return .{ .name = .{ ._buffer = @constCast(names.ptr), ._length = len, ._maximum = len, ._release = false } };
}

fn partitionCount(p: DDS.PartitionQosPolicy) u32 {
    return if (p.name._buffer != null) p.name._length else 0;
}

fn offeredIncompatibleCount(dw: DDS.DataWriter) !i32 {
    var st: DDS.OfferedIncompatibleQosStatus = .{};
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.get_offered_incompatible_qos_status(dw.ptr, &st));
    return st.total_count;
}

fn requestedIncompatibleCount(dr: DDS.DataReader) !i32 {
    var st: DDS.RequestedIncompatibleQosStatus = .{};
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_requested_incompatible_qos_status(dr.ptr, &st));
    return st.total_count;
}

const other_partition = [_][*:0]const u8{"other"};

test "a Publisher's partitions do not change when its writers' announcements cannot all be prepared, and do with them announced when they can" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    const dr_b = fx.sub_b.create_datareader(topicDesc(fx.topic_b), .{}, null, 0);
    const topic2_b = fx.dp_b.create_topic("AnnounceTopic2", "AnnounceType", .{}, null, 0);
    const dr_b2 = fx.sub_b.create_datareader(topicDesc(topic2_b), .{}, null, 0);
    // A writer left disabled, prepared first; then one enabled.
    const topic2 = fx.dp_a.create_topic("AnnounceTopic2", "AnnounceType", .{}, null, 0);
    const dw_a2 = fx.pub_a.create_datawriter(topic2, .{}, null, 0);
    const dw_a = fx.pub_a.create_datawriter(fx.topic_a, .{}, null, 0);
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.enable(dw_a.ptr));
    try testing.expectEqual(@as(i32, 1), try subscriptionMatchedCount(dr_b));

    var q = DDS.PublisherQos{};
    q.entity_factory.autoenable_created_entities = false;
    q.partition = partitionNames(&other_partition);
    // The enabled writer's preparation fails after the disabled one's
    // succeeded.
    rec.fail_after = 1;
    try testing.expectEqual(DDS.RETCODE_OUT_OF_RESOURCES, fx.pub_a.vtable.set_qos(fx.pub_a.ptr, &q));
    var got: DDS.PublisherQos = .{};
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_a.vtable.get_qos(fx.pub_a.ptr, &got));
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), partitionCount(got.partition));
    // Nothing was announced again, and the match stands.
    try testing.expectEqualSlices(Op, &.{.announce_writer}, rec.recorded());
    try testing.expectEqual(@as(i32, 1), try subscriptionMatchedCount(dr_b));
    // The disabled writer kept its announcement too: enabled, it is
    // announced in the default partition.
    rec.fail_after = null;
    try testing.expectEqual(DDS.RETCODE_OK, dw_a2.vtable.enable(dw_a2.ptr));
    try testing.expectEqual(@as(i32, 1), try subscriptionMatchedCount(dr_b2));

    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_a.vtable.set_qos(fx.pub_a.ptr, &q));
    try testing.expectEqualSlices(Op, &.{ .announce_writer, .announce_writer, .announce_writer, .announce_writer }, rec.recorded());
    try testing.expectEqual(@as(i32, 0), try subscriptionMatchedCount(dr_b2));
    // The reader is outside the new partition: unmatched on both sides.
    try testing.expectEqual(@as(i32, 0), try subscriptionMatchedCount(dr_b));
    try testing.expectEqual(@as(i32, 0), try publicationMatchedCount(dw_a));
}

test "a Subscriber's partitions do not change when its readers' announcements cannot all be prepared, and do with them announced when they can" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    const dw_b = fx.pub_b.create_datawriter(fx.topic_b, .{}, null, 0);
    const topic2_b = fx.dp_b.create_topic("AnnounceTopic2", "AnnounceType", .{}, null, 0);
    const dw_b2 = fx.pub_b.create_datawriter(topic2_b, .{}, null, 0);
    const topic2 = fx.dp_a.create_topic("AnnounceTopic2", "AnnounceType", .{}, null, 0);
    const dr_a2 = fx.sub_a.create_datareader(topicDesc(topic2), .{}, null, 0);
    const dr_a = fx.sub_a.create_datareader(topicDesc(fx.topic_a), .{}, null, 0);
    try testing.expectEqual(DDS.RETCODE_OK, dr_a.vtable.enable(dr_a.ptr));
    try testing.expectEqual(@as(i32, 1), try publicationMatchedCount(dw_b));

    var q = DDS.SubscriberQos{};
    q.entity_factory.autoenable_created_entities = false;
    q.partition = partitionNames(&other_partition);
    rec.fail_after = 1;
    try testing.expectEqual(DDS.RETCODE_OUT_OF_RESOURCES, fx.sub_a.vtable.set_qos(fx.sub_a.ptr, &q));
    var got: DDS.SubscriberQos = .{};
    try testing.expectEqual(DDS.RETCODE_OK, fx.sub_a.vtable.get_qos(fx.sub_a.ptr, &got));
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), partitionCount(got.partition));
    try testing.expectEqualSlices(Op, &.{.announce_reader}, rec.recorded());
    try testing.expectEqual(@as(i32, 1), try publicationMatchedCount(dw_b));
    rec.fail_after = null;
    try testing.expectEqual(DDS.RETCODE_OK, dr_a2.vtable.enable(dr_a2.ptr));
    try testing.expectEqual(@as(i32, 1), try publicationMatchedCount(dw_b2));

    try testing.expectEqual(DDS.RETCODE_OK, fx.sub_a.vtable.set_qos(fx.sub_a.ptr, &q));
    try testing.expectEqualSlices(Op, &.{ .announce_reader, .announce_reader, .announce_reader, .announce_reader }, rec.recorded());
    try testing.expectEqual(@as(i32, 0), try publicationMatchedCount(dw_b2));
    try testing.expectEqual(@as(i32, 0), try publicationMatchedCount(dw_b));
    try testing.expectEqual(@as(i32, 0), try subscriptionMatchedCount(dr_a));
}

test "a writer created disabled in a Publisher whose partitions changed is announced in the new ones" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    const dr_b = fx.sub_b.create_datareader(topicDesc(fx.topic_b), .{}, null, 0);
    const dw_a = fx.pub_a.create_datawriter(fx.topic_a, .{}, null, 0);
    var q = DDS.PublisherQos{};
    q.entity_factory.autoenable_created_entities = false;
    q.partition = partitionNames(&other_partition);
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_a.vtable.set_qos(fx.pub_a.ptr, &q));
    // Prepared by the change, so enabling it cannot fail.
    rec.fail_prepare = true;
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.enable(dw_a.ptr));
    try testing.expectEqualSlices(Op, &.{.announce_writer}, rec.recorded());
    try testing.expectEqual(@as(i32, 0), try subscriptionMatchedCount(dr_b));
}

test "a writer whose Publisher's partitions change while it is created is announced in the new ones" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    const dr_b = fx.sub_b.create_datareader(topicDesc(fx.topic_b), .{}, null, 0);
    const pub_impl: *zzdds.dcps.PublisherImpl = @ptrCast(@alignCast(fx.pub_a.ptr));
    const qos = DDS.DataWriterQos{};
    const parts = try pub_impl.createProtoWriter(fx.topic_a, &qos);
    // Between creation's two steps, the change cannot find the writer.
    var q = DDS.PublisherQos{};
    q.entity_factory.autoenable_created_entities = false;
    q.partition = partitionNames(&other_partition);
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_a.vtable.set_qos(fx.pub_a.ptr, &q));
    const dw_a = pub_impl.finishDataWriter(fx.topic_a, &qos, .{}, 0, parts);
    try testing.expect(dw_a.ptr != zzdds.dcps.NIL_PTR);
    // Prepared by its creation, so enabling it cannot fail.
    rec.fail_prepare = true;
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.enable(dw_a.ptr));
    try testing.expectEqualSlices(Op, &.{.announce_writer}, rec.recorded());
    try testing.expectEqual(@as(i32, 0), try subscriptionMatchedCount(dr_b));
    try testing.expectEqual(@as(i32, 0), try publicationMatchedCount(dw_a));
}

test "a match decided before a Publisher's partition change is not made after it" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    const Probe = struct {
        var publisher: DDS.Publisher = undefined;
        var changed: bool = false;
        var rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR;
        fn onMatched(_: *anyopaque, _: *const DDS.PublicationMatchedStatus, _: ?*anyopaque) callconv(.c) void {
            if (changed) return;
            changed = true;
            var q = DDS.PublisherQos{};
            q.entity_factory.autoenable_created_entities = false;
            q.partition = partitionNames(&other_partition);
            rc = publisher.vtable.set_qos(publisher.ptr, &q);
        }
    };
    Probe.publisher = fx.pub_a;
    Probe.changed = false;
    Probe.rc = DDS.RETCODE_ERROR;
    const listener: DDS.DataWriterListener = .{ .on_publication_matched = Probe.onMatched };
    const dw_1 = fx.pub_a.create_datawriter(fx.topic_a, .{}, listener, DDS.PUBLICATION_MATCHED_STATUS);
    const dw_2 = fx.pub_a.create_datawriter(fx.topic_a, .{}, listener, DDS.PUBLICATION_MATCHED_STATUS);
    try testing.expectEqual(DDS.RETCODE_OK, dw_1.vtable.enable(dw_1.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, dw_2.vtable.enable(dw_2.ptr));
    // Its discovery decides a match with each writer; the first one made
    // moves both writers out of its partition before the second is made.
    const dr_b = fx.sub_b.create_datareader(topicDesc(fx.topic_b), .{}, null, 0);
    try testing.expect(Probe.changed);
    try testing.expectEqual(DDS.RETCODE_OK, Probe.rc);
    try testing.expectEqual(@as(i32, 0), try publicationMatchedCount(dw_1));
    try testing.expectEqual(@as(i32, 0), try publicationMatchedCount(dw_2));
    try testing.expectEqual(@as(i32, 0), try subscriptionMatchedCount(dr_b));
}

test "a writer's QoS changed while its announcement is written is announced after it, not within it" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.deadline.period = .{ .sec = 2, .nanosec = 0 };
    const dr_b = fx.sub_b.create_datareader(topicDesc(fx.topic_b), dr_qos, null, 0);
    const Change = struct {
        var dw: DDS.DataWriter = undefined;
        var rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR;
        fn f(_: *anyopaque) void {
            var within = DDS.DataWriterQos{};
            within.deadline.period = .{ .sec = 1, .nanosec = 0 };
            rc = dw.vtable.set_qos(dw.ptr, &within);
        }
    };
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.deadline.period = .{ .sec = 1, .nanosec = 0 };
    const dw_a = fx.pub_a.create_datawriter(fx.topic_a, dw_qos, null, 0);
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.enable(dw_a.ptr));
    try testing.expectEqual(@as(i32, 1), try subscriptionMatchedCount(dr_b));

    // While the longer deadline's announcement is written, the writer goes
    // back within what the reader requests.
    Change.dw = dw_a;
    Change.rc = DDS.RETCODE_ERROR;
    rec.before_announce = Change.f;
    var longer = dw_qos;
    longer.deadline.period = .{ .sec = 5, .nanosec = 0 };
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.set_qos(dw_a.ptr, &longer));
    try testing.expectEqual(DDS.RETCODE_OK, Change.rc);
    try testing.expect(!rec.nested);
    try testing.expectEqualSlices(Op, &.{ .announce_writer, .announce_writer, .announce_writer }, rec.recorded());
    try testing.expectEqual(@as(i32, 1), try subscriptionMatchedCount(dr_b));
    try testing.expectEqual(@as(i32, 1), try publicationMatchedCount(dw_a));
}

test "a writer's QoS does not change when its announcement cannot be prepared, and does with it announced when it can" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.deadline.period = .{ .sec = 2, .nanosec = 0 };
    const dr_b = fx.sub_b.create_datareader(topicDesc(fx.topic_b), dr_qos, null, 0);
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.deadline.period = .{ .sec = 1, .nanosec = 0 };
    const dw_a = fx.pub_a.create_datawriter(fx.topic_a, dw_qos, null, 0);
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.enable(dw_a.ptr));
    try testing.expectEqual(@as(i32, 1), try subscriptionMatchedCount(dr_b));

    // Offering a longer deadline than the reader requests.
    var longer = dw_qos;
    longer.deadline.period = .{ .sec = 5, .nanosec = 0 };
    rec.fail_prepare = true;
    try testing.expectEqual(DDS.RETCODE_OUT_OF_RESOURCES, dw_a.vtable.set_qos(dw_a.ptr, &longer));
    var got: DDS.DataWriterQos = .{};
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.get_qos(dw_a.ptr, &got));
    try testing.expectEqual(@as(i32, 1), got.deadline.period.sec);
    got.deinit(testing.allocator);
    try testing.expectEqualSlices(Op, &.{.announce_writer}, rec.recorded());
    try testing.expectEqual(@as(i32, 1), try subscriptionMatchedCount(dr_b));

    rec.fail_prepare = false;
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.set_qos(dw_a.ptr, &longer));
    try testing.expectEqualSlices(Op, &.{ .announce_writer, .announce_writer }, rec.recorded());
    try testing.expectEqual(@as(i32, 0), try subscriptionMatchedCount(dr_b));
    try testing.expectEqual(@as(i32, 0), try publicationMatchedCount(dw_a));
    // Each side counts the mismatch once.
    try testing.expectEqual(@as(i32, 1), try requestedIncompatibleCount(dr_b));
    try testing.expectEqual(@as(i32, 1), try offeredIncompatibleCount(dw_a));

    // Back within what the reader requests: matched again.
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.set_qos(dw_a.ptr, &dw_qos));
    try testing.expectEqual(@as(i32, 1), try subscriptionMatchedCount(dr_b));
    try testing.expectEqual(@as(i32, 1), try publicationMatchedCount(dw_a));
}

test "a reader's QoS does not change when its announcement cannot be prepared, and does with it announced when it can" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.deadline.period = .{ .sec = 2, .nanosec = 0 };
    const dw_b = fx.pub_b.create_datawriter(fx.topic_b, dw_qos, null, 0);
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.deadline.period = .{ .sec = 5, .nanosec = 0 };
    const dr_a = fx.sub_a.create_datareader(topicDesc(fx.topic_a), dr_qos, null, 0);
    try testing.expectEqual(DDS.RETCODE_OK, dr_a.vtable.enable(dr_a.ptr));
    try testing.expectEqual(@as(i32, 1), try publicationMatchedCount(dw_b));

    // Requesting a shorter deadline than the writer offers.
    var shorter = dr_qos;
    shorter.deadline.period = .{ .sec = 1, .nanosec = 0 };
    rec.fail_prepare = true;
    try testing.expectEqual(DDS.RETCODE_OUT_OF_RESOURCES, dr_a.vtable.set_qos(dr_a.ptr, &shorter));
    var got: DDS.DataReaderQos = .{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_a.vtable.get_qos(dr_a.ptr, &got));
    try testing.expectEqual(@as(i32, 5), got.deadline.period.sec);
    got.deinit(testing.allocator);
    try testing.expectEqualSlices(Op, &.{.announce_reader}, rec.recorded());
    try testing.expectEqual(@as(i32, 1), try publicationMatchedCount(dw_b));

    rec.fail_prepare = false;
    try testing.expectEqual(DDS.RETCODE_OK, dr_a.vtable.set_qos(dr_a.ptr, &shorter));
    try testing.expectEqualSlices(Op, &.{ .announce_reader, .announce_reader }, rec.recorded());
    try testing.expectEqual(@as(i32, 0), try publicationMatchedCount(dw_b));
    try testing.expectEqual(@as(i32, 0), try subscriptionMatchedCount(dr_a));
    try testing.expectEqual(@as(i32, 1), try offeredIncompatibleCount(dw_b));
    try testing.expectEqual(@as(i32, 1), try requestedIncompatibleCount(dr_a));

    try testing.expectEqual(DDS.RETCODE_OK, dr_a.vtable.set_qos(dr_a.ptr, &dr_qos));
    try testing.expectEqual(@as(i32, 1), try publicationMatchedCount(dw_b));
    try testing.expectEqual(@as(i32, 1), try subscriptionMatchedCount(dr_a));
}

test "an immutable policy does not change, enabled or not, and nothing is announced" {
    var rec: Recorder = undefined;
    var fx = try Fixture.init(testing.allocator, &rec);
    defer fx.deinit();

    const dw_a = fx.pub_a.create_datawriter(fx.topic_a, .{}, null, 0);
    const dr_a = fx.sub_a.create_datareader(topicDesc(fx.topic_a), .{}, null, 0);
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.history.depth = 9;
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    try testing.expectEqual(DDS.RETCODE_IMMUTABLE_POLICY, dw_a.vtable.set_qos(dw_a.ptr, &dw_qos));
    try testing.expectEqual(DDS.RETCODE_IMMUTABLE_POLICY, dr_a.vtable.set_qos(dr_a.ptr, &dr_qos));
    try testing.expectEqual(DDS.RETCODE_OK, dw_a.vtable.enable(dw_a.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, dr_a.vtable.enable(dr_a.ptr));
    try testing.expectEqual(DDS.RETCODE_IMMUTABLE_POLICY, dw_a.vtable.set_qos(dw_a.ptr, &dw_qos));
    try testing.expectEqual(DDS.RETCODE_IMMUTABLE_POLICY, dr_a.vtable.set_qos(dr_a.ptr, &dr_qos));
    // An enabled Publisher's presentation is immutable too.
    var pq = DDS.PublisherQos{};
    pq.entity_factory.autoenable_created_entities = false;
    pq.presentation.coherent_access = true;
    try testing.expectEqual(DDS.RETCODE_IMMUTABLE_POLICY, fx.pub_a.vtable.set_qos(fx.pub_a.ptr, &pq));
    try testing.expectEqualSlices(Op, &.{ .announce_writer, .announce_reader }, rec.recorded());
}
