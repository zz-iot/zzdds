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
        const dp = factory.toDDSFactory().create_participant(0, .{}, null, 0);
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
    const topic = fx.dp.create_topic("TVtEnable", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.enable(topic.ptr));
}

test "Topic: get_name and get_type_name return correct strings" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("MyTopic", "MyType", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    try testing.expectEqualStrings("MyTopic", topic.get_name());
    try testing.expectEqualStrings("MyType", topic.get_type_name());
}

test "Topic: get_instance_handle returns non-nil handle" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("HandleTopic", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    const handle = topic.vtable.get_instance_handle(topic.ptr);
    try testing.expect(handle != 0);
}

test "Topic: get_status_changes initially zero" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("StatusTopic", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    try testing.expectEqual(@as(DDS.StatusMask, 0), topic.vtable.get_status_changes(topic.ptr));
}

test "Topic: get_statuscondition returns non-nil condition" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("ScTopic", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    const sc = topic.vtable.get_statuscondition(topic.ptr);
    try testing.expect(sc.ptr != nil.NIL_PTR);
}

test "Topic: get_participant returns a participant" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("DpTopic", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    const dp2 = topic.vtable.get_participant(topic.ptr);
    try testing.expect(dp2.ptr != nil.NIL_PTR);
}

test "Topic: set_qos and get_qos round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("QosTopic", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const new_qos = DDS.TopicQos{};
    try testing.expectEqual(DDS.RETCODE_OK, topic.set_qos(new_qos));

    var got_qos: DDS.TopicQos = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.get_qos(topic.ptr, &got_qos));
}

test "Topic: set_listener and get_listener round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("ListenerTopic", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    try testing.expectEqual(DDS.RETCODE_OK, topic.set_listener(null, 0));
    _ = topic.vtable.get_listener(topic.ptr);
}

test "Topic: get_inconsistent_topic_status returns OK and clears count" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("IncTopic", "T", .{}, null, 0);
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
    const topic = fx.dp.create_topic("CftNameBase", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const cft = fx.dp.create_contentfilteredtopic("MyCftAlias", topic, "x = 1", &DDS.StringSeq{});
    defer _ = fx.dp.vtable.delete_contentfilteredtopic(fx.dp.ptr, cft);

    // cft_vtable.get_name returns the CFT's own name ("MyCftAlias"), not "CftNameBase"
    try testing.expectEqualStrings("MyCftAlias", cft.get_name());
}

test "CFT: get_expression_parameters returns params list" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("CftParamBase", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    var init_param_strs: [1][*:0]const u8 = .{"42"};
    const init_params = DDS.StringSeq{ ._buffer = @ptrCast(&init_param_strs), ._length = 1, ._maximum = 1, ._release = false };

    const cft = fx.dp.create_contentfilteredtopic("ParamCft", topic, "x = %0", &init_params);
    defer _ = fx.dp.vtable.delete_contentfilteredtopic(fx.dp.ptr, cft);

    var out = DDS.StringSeq{};
    defer if (out._release) {
        if (out._buffer) |_b| {
            for (_b[0..out._length]) |p| {
                const s = std.mem.span(p);
                alloc.free(s.ptr[0 .. s.len + 1]);
            }
            alloc.free(_b[0..out._length]);
        }
    };
    try testing.expectEqual(DDS.RETCODE_OK, cft.vtable.get_expression_parameters(cft.ptr, &out));
    try testing.expectEqual(@as(u32, 1), out._length);
    try testing.expectEqualStrings("42", std.mem.span(out._buffer.?[0]));
}

test "CFT: get_related_topic returns the base topic" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("CftRelBase", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const cft = fx.dp.create_contentfilteredtopic("RelCft", topic, "x = 1", &DDS.StringSeq{});
    defer _ = fx.dp.vtable.delete_contentfilteredtopic(fx.dp.ptr, cft);

    const related = cft.vtable.get_related_topic(cft.ptr);
    // The related topic name should match the base topic name.
    try testing.expectEqualStrings("CftRelBase", related.get_name());
}

test "CFT: toTopicDescription get_name returns related topic name (wire name)" {
    // The td_vtable.get_name intentionally returns the *related* topic name so
    // that create_datareader can use the TopicDescription directly for RTPS matching.
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("TdBase", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const cft = fx.dp.create_contentfilteredtopic("TdAlias", topic, "x = 1", &DDS.StringSeq{});
    defer _ = fx.dp.vtable.delete_contentfilteredtopic(fx.dp.ptr, cft);

    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));
    const td = cft_impl.toTopicDescription();
    try testing.expectEqualStrings("TdBase", std.mem.span(td.vtable.get_name(td.ptr)));
}

test "CFT: toTopicDescription get_participant returns the owning participant" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("TdPartBase", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const cft = fx.dp.create_contentfilteredtopic("TdPartAlias", topic, "x = 1", &DDS.StringSeq{});
    defer _ = fx.dp.vtable.delete_contentfilteredtopic(fx.dp.ptr, cft);

    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));
    const td = cft_impl.toTopicDescription();
    const dp2 = td.vtable.get_participant(td.ptr);
    try testing.expect(dp2.ptr == fx.dp.ptr);
}

test "CFT: set_expression_parameters replaces pre-existing params" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("TdSetBase", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    var init_strs: [1][*:0]const u8 = .{"old"};
    const init_params = DDS.StringSeq{ ._buffer = @ptrCast(&init_strs), ._length = 1, ._maximum = 1, ._release = false };
    const cft = fx.dp.create_contentfilteredtopic("TdSetCft", topic, "x = %0", &init_params);
    defer _ = fx.dp.vtable.delete_contentfilteredtopic(fx.dp.ptr, cft);

    // Replace with new params — exercises the free loop over expr_params.items.
    var new_strs: [1][*:0]const u8 = .{"new"};
    const new_params = DDS.StringSeq{ ._buffer = @ptrCast(&new_strs), ._length = 1, ._maximum = 1, ._release = false };
    const rc = cft.vtable.set_expression_parameters(cft.ptr, &new_params);
    try testing.expectEqual(DDS.RETCODE_OK, rc);

    var out = DDS.StringSeq{};
    defer if (out._release) {
        if (out._buffer) |b| {
            for (b[0..out._length]) |p| alloc.free(std.mem.span(p).ptr[0 .. std.mem.span(p).len + 1]);
            alloc.free(b[0..out._maximum]);
        }
    };
    _ = cft.vtable.get_expression_parameters(cft.ptr, &out);
    try testing.expectEqual(@as(u32, 1), out._length);
    try testing.expectEqualStrings("new", std.mem.span(out._buffer.?[0]));
}
