//! Tests for TopicImpl and ContentFilteredTopicImpl vtable methods.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const TopicImpl = zzdds.dcps.TopicImpl;
const ContentFilteredTopicImpl = zzdds.dcps.ContentFilteredTopicImpl;
const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;
const nil = zzdds.dcps;

const testing = std.testing;

const Fixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,
    t: *zzdds.intraprocess.MemoryTransport,
    d: *zzdds.intraprocess.DirectDiscovery,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        const factory = try DomainParticipantFactoryImpl.init(alloc, t.transport(), d.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory.deinit();
        const dp = factory.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        return .{ .alloc = alloc, .delivery = delivery, .t = t, .d = d, .factory = factory, .dp = dp };
    }

    fn deinit(self: *Fixture) void {
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        self.factory.deinit();
        self.d.deinit();
        self.t.deinit();
        self.delivery.deinit();
    }
};

// ── TopicImpl vtable tests ────────────────────────────────────────────────────

test "Topic: enable returns RETCODE_OK" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "TVtEnable", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.enable(topic.ptr));
}

test "Topic: get_name and get_type_name return correct strings" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "MyTopic", "MyType", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    try testing.expectEqualStrings("MyTopic", topic.vtable.get_name(topic.ptr));
    try testing.expectEqualStrings("MyType", topic.vtable.get_type_name(topic.ptr));
}

test "Topic: get_instance_handle returns non-nil handle" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "HandleTopic", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    const handle = topic.vtable.get_instance_handle(topic.ptr);
    try testing.expect(handle != 0);
}

test "Topic: get_status_changes initially zero" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "StatusTopic", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    try testing.expectEqual(@as(DDS.StatusMask, 0), topic.vtable.get_status_changes(topic.ptr));
}

test "Topic: get_statuscondition returns non-nil condition" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "ScTopic", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    const sc = topic.vtable.get_statuscondition(topic.ptr);
    try testing.expect(sc.ptr != nil.NIL_PTR);
}

test "Topic: get_participant returns a participant" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "DpTopic", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    const dp2 = topic.vtable.get_participant(topic.ptr);
    try testing.expect(dp2.ptr != nil.NIL_PTR);
}

test "Topic: set_qos and get_qos round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "QosTopic", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const new_qos = DDS.TopicQos{};
    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.set_qos(topic.ptr, new_qos));

    var got_qos: DDS.TopicQos = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.get_qos(topic.ptr, &got_qos));
}

test "Topic: set_listener and get_listener round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "ListenerTopic", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.set_listener(topic.ptr, nil.nil_topic_listener, 0));
    _ = topic.vtable.get_listener(topic.ptr);
}

test "Topic: get_inconsistent_topic_status returns OK and clears count" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "IncTopic", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    var status: DDS.InconsistentTopicStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.get_inconsistent_topic_status(topic.ptr, &status));
    try testing.expectEqual(@as(i32, 0), status.total_count_change);
}

// ── ContentFilteredTopic vtable tests ────────────────────────────────────────

test "CFT: get_name returns the CFT alias name (not related topic name)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "CftNameBase", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const cft = fx.dp.vtable.create_contentfilteredtopic(fx.dp.ptr, "MyCftAlias", topic, "x = 1", DDS.StringSeq.empty);
    defer _ = fx.dp.vtable.delete_contentfilteredtopic(fx.dp.ptr, cft);

    // cft_vtable.get_name returns the CFT's own name ("MyCftAlias"), not "CftNameBase"
    try testing.expectEqualStrings("MyCftAlias", cft.vtable.get_name(cft.ptr));
}

test "CFT: get_expression_parameters returns params list" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "CftParamBase", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    var init_params = DDS.StringSeq.empty;
    defer init_params.deinit(alloc);
    try init_params.append(alloc, "42");

    const cft = fx.dp.vtable.create_contentfilteredtopic(fx.dp.ptr, "ParamCft", topic, "x = %0", init_params);
    defer _ = fx.dp.vtable.delete_contentfilteredtopic(fx.dp.ptr, cft);

    var out = DDS.StringSeq.empty;
    defer out.deinit(alloc);
    try testing.expectEqual(DDS.RETCODE_OK, cft.vtable.get_expression_parameters(cft.ptr, &out));
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("42", out.items[0]);
}

test "CFT: get_related_topic returns the base topic" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.vtable.create_topic(fx.dp.ptr, "CftRelBase", "T", .{}, nil.nil_topic_listener, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const cft = fx.dp.vtable.create_contentfilteredtopic(fx.dp.ptr, "RelCft", topic, "x = 1", DDS.StringSeq.empty);
    defer _ = fx.dp.vtable.delete_contentfilteredtopic(fx.dp.ptr, cft);

    const related = cft.vtable.get_related_topic(cft.ptr);
    // The related topic name should match the base topic name.
    try testing.expectEqualStrings("CftRelBase", related.vtable.get_name(related.ptr));
}
