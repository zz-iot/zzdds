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
const Recorder = struct {
    inner: disc.Discovery,
    ops: [16]Op = undefined,
    n: usize = 0,
    before_announce: ?*const fn (ctx: *anyopaque) void = null,
    before_ctx: *anyopaque = undefined,

    const vtable: disc.Discovery.Vtable = .{
        .start = start,
        .stop = stop,
        .announce_writer = announceWriter,
        .retract_writer = retractWriter,
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

    fn last(self: *const Recorder) Op {
        return self.ops[self.n - 1];
    }

    fn start(ctx: *anyopaque, local: *const disc.ParticipantAnnouncement, callbacks: *const disc.Callbacks) anyerror!void {
        return of(ctx).inner.start(local, callbacks);
    }
    fn stop(ctx: *anyopaque) void {
        of(ctx).inner.stop();
    }
    fn announceWriter(ctx: *anyopaque, info: *const disc.WriterAnnouncement) anyerror!void {
        const self = of(ctx);
        self.runBeforeAnnounce();
        self.record(.announce_writer);
        return self.inner.announceWriter(info);
    }
    fn retractWriter(ctx: *anyopaque, guid: Guid) void {
        of(ctx).record(.retract_writer);
        of(ctx).inner.retractWriter(guid);
    }
    fn announceReader(ctx: *anyopaque, info: *const disc.ReaderAnnouncement) anyerror!void {
        const self = of(ctx);
        self.runBeforeAnnounce();
        self.record(.announce_reader);
        return self.inner.announceReader(info);
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
    try testing.expectEqual(Op.retract_writer, rec.last());
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
    try testing.expectEqual(Op.retract_reader, rec.last());
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
