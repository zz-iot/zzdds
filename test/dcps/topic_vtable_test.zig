//! Tests for TopicImpl and ContentFilteredTopicImpl vtable methods.

const std = @import("std");
const test_domain = @import("test_domain");
const ManualRuntime = @import("manual_runtime").ManualRuntime;
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
    /// Set when the participant runs on a manual runtime the test drives.
    mr: ?*ManualRuntime = null,
    delivery: IntraProcessDelivery,
    t: *zzdds.intraprocess.MemoryTransport,
    d: *zzdds.intraprocess.DirectDiscovery,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,

    fn init(alloc: std.mem.Allocator) !Fixture {
        return initWithFactoryQos(alloc, .{});
    }

    fn initWithFactoryQos(alloc: std.mem.Allocator, factory_qos: DDS.DomainParticipantFactoryQos) !Fixture {
        return initOn(alloc, factory_qos, false);
    }

    /// With `manual`, on a ManualRuntime installed for the participant to take.
    fn initOn(alloc: std.mem.Allocator, factory_qos: DDS.DomainParticipantFactoryQos, manual: bool) !Fixture {
        var mr: ?*ManualRuntime = null;
        if (manual) {
            const m = try std.heap.page_allocator.create(ManualRuntime);
            m.init();
            mr = m;
        }
        errdefer if (mr) |m| {
            m.deinit();
            std.heap.page_allocator.destroy(m);
        };
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        const factory = try DomainParticipantFactoryImpl.init(alloc, t.transport(), d.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory.deinit();
        try testing.expectEqual(DDS.RETCODE_OK, factory.toDDSFactory().set_qos(factory_qos));
        const dp = factory.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        return .{ .alloc = alloc, .mr = mr, .delivery = delivery, .t = t, .d = d, .factory = factory, .dp = dp };
    }

    fn deinit(self: *Fixture) void {
        // What the test left queued runs while the participant still exists.
        if (self.mr) |m| m.settle();
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        if (self.mr) |m| m.settle();
        self.factory.deinit();
        self.d.deinit();
        self.t.deinit();
        self.delivery.deinit();
        if (self.mr) |m| {
            m.deinit();
            std.heap.page_allocator.destroy(m);
        }
    }
};

// ── TopicImpl vtable tests ────────────────────────────────────────────────────

test "Topic: enable returns RETCODE_OK, idempotent when already enabled" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("TVtEnable", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.enable(topic.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.enable(topic.ptr));
}

test "Topic: created under a participant with autoenable_created_entities=false starts disabled, rejects get_inconsistent_topic_status with NOT_ENABLED, and enable() makes it work" {
    const alloc = testing.allocator;
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    const t = try delivery.newTransport();
    defer t.deinit();
    const d = try delivery.newDiscovery();
    defer d.deinit();
    const factory = try DomainParticipantFactoryImpl.init(alloc, t.transport(), d.toDiscovery(), noop_security, .spec_random, .{});
    defer factory.deinit();
    var disabled_dp_qos = DDS.DomainParticipantQos{};
    disabled_dp_qos.entity_factory.autoenable_created_entities = false;
    const dp = factory.toDDSFactory().create_participant(test_domain.get(), disabled_dp_qos, null, 0);
    defer _ = factory.toDDSFactory().delete_participant(dp);
    try testing.expect(dp.ptr != nil.nil_participant.ptr);
    const topic = dp.create_topic("TVtDisabled", "T", .{}, null, 0);
    try testing.expect(topic.ptr != nil.nil_topic.ptr);
    defer _ = dp.vtable.delete_topic(dp.ptr, topic);

    var status: DDS.InconsistentTopicStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_NOT_ENABLED, topic.vtable.get_inconsistent_topic_status(topic.ptr, &status));

    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.enable(topic.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, topic.vtable.get_inconsistent_topic_status(topic.ptr, &status));
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

test "Topic: status condition's trigger value reads status through getStatusFn" {
    // Exercises TopicImpl.getStatusFn -- the callback StatusConditionImpl
    // stores and calls from get_trigger_value, distinct from (and previously
    // uncovered unlike) the entity vtable's own get_status_changes.
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const topic = fx.dp.create_topic("TriggerTopic", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);
    const sc = topic.vtable.get_statuscondition(topic.ptr);
    try testing.expectEqual(false, sc.vtable.get_trigger_value(sc.ptr));
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

// ── Deletion while in use (DDS 1.4 2.2.2.2.1.6, 2.2.2.2.1.8) ─────────────────

fn deleteTopic(dp: DDS.DomainParticipant, topic: DDS.Topic) DDS.ReturnCode_t {
    return dp.vtable.delete_topic(dp.ptr, topic);
}

fn deleteCft(dp: DDS.DomainParticipant, cft: DDS.ContentFilteredTopic) DDS.ReturnCode_t {
    return dp.vtable.delete_contentfilteredtopic(dp.ptr, cft);
}

test "delete_topic: refused while a DataWriter uses the Topic" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("UsedByWriter", "T", .{}, null, 0);
    const pub_ = fx.dp.create_publisher(.{}, null, 0);
    const dw = pub_.create_datawriter(topic, .{}, null, 0);
    try testing.expect(dw.ptr != nil.nil_datawriter.ptr);

    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, deleteTopic(fx.dp, topic));
    try testing.expectEqualStrings("UsedByWriter", topic.get_name());

    try testing.expectEqual(DDS.RETCODE_OK, pub_.delete_datawriter(dw));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

test "delete_topic: refused while a DataReader uses the Topic" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("UsedByReader", "T", .{}, null, 0);
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const dr = sub.create_datareader(impl.toTopicDescription(), .{}, null, 0);
    try testing.expect(dr.ptr != nil.nil_datareader.ptr);

    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, deleteTopic(fx.dp, topic));

    try testing.expectEqual(DDS.RETCODE_OK, sub.delete_datareader(dr));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

test "delete_topic: refused while a ContentFilteredTopic relates to the Topic" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("UsedByCft", "T", .{}, null, 0);
    const cft = fx.dp.create_contentfilteredtopic("UsedByCft_f", topic, "x = 1", &DDS.StringSeq{});

    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, deleteTopic(fx.dp, topic));
    try testing.expectEqualStrings("UsedByCft", cft.get_related_topic().get_name());

    try testing.expectEqual(DDS.RETCODE_OK, deleteCft(fx.dp, cft));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

test "delete_contentfilteredtopic: refused while a DataReader uses it" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("CftUsed", "T", .{}, null, 0);
    const cft = fx.dp.create_contentfilteredtopic("CftUsed_f", topic, "x = 1", &DDS.StringSeq{});
    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const dr = sub.create_datareader(cft_impl.toTopicDescription(), .{}, null, 0);
    try testing.expect(dr.ptr != nil.nil_datareader.ptr);

    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, deleteCft(fx.dp, cft));
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, deleteTopic(fx.dp, topic));

    try testing.expectEqual(DDS.RETCODE_OK, sub.delete_datareader(dr));
    try testing.expectEqual(DDS.RETCODE_OK, deleteCft(fx.dp, cft));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

test "delete_topic and delete_contentfilteredtopic: another participant's is refused and unharmed" {
    var a = try Fixture.init(testing.allocator);
    defer a.deinit();
    var b = try Fixture.init(testing.allocator);
    defer b.deinit();
    const topic = a.dp.create_topic("OtherParticipant", "T", .{}, null, 0);
    const cft = a.dp.create_contentfilteredtopic("OtherParticipant_f", topic, "x = 1", &DDS.StringSeq{});

    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, deleteCft(b.dp, cft));
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, deleteTopic(b.dp, topic));
    try testing.expectEqualStrings("OtherParticipant_f", cft.get_name());
    try testing.expectEqualStrings("OtherParticipant", topic.get_name());

    try testing.expectEqual(DDS.RETCODE_OK, deleteCft(a.dp, cft));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(a.dp, topic));
}

test "delete_topic and delete_contentfilteredtopic: a nil handle is a bad parameter" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, deleteTopic(fx.dp, nil.nil_topic));
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, deleteCft(fx.dp, nil.nil_cft));
}

test "creating on another participant's Topic fails and takes no reference" {
    var a = try Fixture.init(testing.allocator);
    defer a.deinit();
    var b = try Fixture.init(testing.allocator);
    defer b.deinit();
    const topic = a.dp.create_topic("Foreign", "T", .{}, null, 0);
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const cft = a.dp.create_contentfilteredtopic("Foreign_f", topic, "x = 1", &DDS.StringSeq{});
    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));

    const pub_ = b.dp.create_publisher(.{}, null, 0);
    const sub = b.dp.create_subscriber(.{}, null, 0);
    try testing.expectEqual(nil.nil_datawriter.ptr, pub_.create_datawriter(topic, .{}, null, 0).ptr);
    try testing.expectEqual(nil.nil_datareader.ptr, sub.create_datareader(impl.toTopicDescription(), .{}, null, 0).ptr);
    try testing.expectEqual(nil.nil_datareader.ptr, sub.create_datareader(cft_impl.toTopicDescription(), .{}, null, 0).ptr);
    try testing.expectEqual(nil.nil_cft.ptr, b.dp.create_contentfilteredtopic("Foreign_g", topic, "x = 1", &DDS.StringSeq{}).ptr);
    const builtin = b.dp.get_builtin_subscriber();
    try testing.expectEqual(nil.nil_datareader.ptr, builtin.create_datareader(impl.toTopicDescription(), .{}, null, 0).ptr);
    try testing.expectEqual(nil.nil_datareader.ptr, builtin.create_datareader(cft_impl.toTopicDescription(), .{}, null, 0).ptr);

    try testing.expectEqual(DDS.RETCODE_OK, deleteCft(a.dp, cft));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(a.dp, topic));
}

test "delete_topic and delete_contentfilteredtopic: refused while a reader on the builtin Subscriber uses them" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("BuiltinUsed", "T", .{}, null, 0);
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const cft = fx.dp.create_contentfilteredtopic("BuiltinUsed_f", topic, "x = 1", &DDS.StringSeq{});
    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));
    const builtin = fx.dp.get_builtin_subscriber();
    const on_topic = builtin.create_datareader(impl.toTopicDescription(), .{}, null, 0);
    const on_cft = builtin.create_datareader(cft_impl.toTopicDescription(), .{}, null, 0);
    try testing.expect(on_topic.ptr != nil.nil_datareader.ptr);
    try testing.expect(on_cft.ptr != nil.nil_datareader.ptr);

    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, deleteCft(fx.dp, cft));
    try testing.expectEqual(DDS.RETCODE_OK, builtin.delete_datareader(on_cft));
    try testing.expectEqual(DDS.RETCODE_OK, deleteCft(fx.dp, cft));
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, deleteTopic(fx.dp, topic));
    try testing.expectEqualStrings("BuiltinUsed", on_topic.get_topicdescription().get_name());
    try testing.expectEqual(DDS.RETCODE_OK, builtin.delete_datareader(on_topic));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

test "the builtin Subscriber takes its own topic descriptions, but no other participant's" {
    var a = try Fixture.init(testing.allocator);
    defer a.deinit();
    var b = try Fixture.init(testing.allocator);
    defer b.deinit();
    const builtin = a.dp.get_builtin_subscriber();
    const description = builtin.lookup_datareader("DCPSPublication").get_topicdescription();
    const reader = builtin.create_datareader(description, .{}, null, 0);
    try testing.expect(reader.ptr != nil.nil_datareader.ptr);
    try testing.expectEqualStrings("DCPSPublication", reader.get_topicdescription().get_name());
    try testing.expectEqual(DDS.RETCODE_OK, builtin.delete_datareader(reader));

    const other = b.dp.get_builtin_subscriber();
    try testing.expectEqual(nil.nil_datareader.ptr, other.create_datareader(description, .{}, null, 0).ptr);
}

test "a reader left on the builtin Subscriber keeps its Topic through delete_contained_entities and delete_participant" {
    // The builtin Subscriber is not a contained entity, so its reader stays
    // until the participant goes. testing.allocator catches a leak or double
    // free when Fixture.deinit tears it down.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("BuiltinKept", "T", .{}, null, 0);
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const reader = fx.dp.get_builtin_subscriber().create_datareader(impl.toTopicDescription(), .{}, null, 0);
    try testing.expect(reader.ptr != nil.nil_datareader.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, fx.dp.delete_contained_entities());
    try testing.expectEqualStrings("BuiltinKept", reader.get_topicdescription().get_name());
}

test "create_contentfilteredtopic: a ContentFilteredTopic as the related Topic is refused and left unused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("RelatedCft", "T", .{}, null, 0);
    const cft = fx.dp.create_contentfilteredtopic("RelatedCft_f", topic, "x = 1", &DDS.StringSeq{});
    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));
    const related = DDS.Topic{ .ptr = cft.ptr, .vtable = topic.vtable };

    try testing.expectEqual(nil.nil_cft.ptr, fx.dp.create_contentfilteredtopic("RelatedCft_g", related, "x = 1", &DDS.StringSeq{}).ptr);
    try testing.expect(!cft_impl.inUse());
    try testing.expectEqual(DDS.RETCODE_OK, deleteCft(fx.dp, cft));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

// ── A create that fails leaves its Topic as it found it ─────────────────

fn failProtoReader(
    _: *anyopaque,
    _: []const u8,
    _: []const u8,
    _: DDS.DataReaderQos,
    _: DDS.PresentationQosPolicy,
    _: *DDS.InstanceHandle_t,
    _: *zzdds.protocol.Guid,
) anyerror!zzdds.protocol.ProtocolReader {
    return error.OutOfMemory;
}

test "create_datareader: a protocol reader that cannot be created leaves the Topic and ContentFilteredTopic unused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("NoProtoReader", "T", .{}, null, 0);
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const cft = fx.dp.create_contentfilteredtopic("NoProtoReader_f", topic, "x = 1", &DDS.StringSeq{});
    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const sub_impl: *zzdds.dcps.SubscriberImpl = @ptrCast(@alignCast(sub.ptr));
    sub_impl.cbs.create_proto_reader = failProtoReader;

    try testing.expectEqual(nil.nil_datareader.ptr, sub.create_datareader(cft_impl.toTopicDescription(), .{}, null, 0).ptr);
    try testing.expectEqual(DDS.RETCODE_OK, deleteCft(fx.dp, cft));
    try testing.expectEqual(nil.nil_datareader.ptr, sub.create_datareader(impl.toTopicDescription(), .{}, null, 0).ptr);
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

test "create_datareader: an announcement that cannot be prepared leaves the Topic unused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("NoReaderAnnouncement", "T", .{}, null, 0);
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const sub_impl: *zzdds.dcps.SubscriberImpl = @ptrCast(@alignCast(sub.ptr));
    const Fail = struct {
        fn prepare(_: *anyopaque, _: []const DDS.InstanceHandle_t, _: []const []const u8, _: DDS.PresentationQosPolicy) anyerror!void {
            return error.OutOfMemory;
        }
    };
    sub_impl.cbs.prepare_readers = Fail.prepare;

    try testing.expectEqual(nil.nil_datareader.ptr, sub.create_datareader(impl.toTopicDescription(), .{}, null, 0).ptr);
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

test "create_datawriter: a protocol writer that cannot be created leaves the Topic unused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("NoProtoWriter", "T", .{}, null, 0);
    const pub_ = fx.dp.create_publisher(.{}, null, 0);
    const pub_impl: *zzdds.dcps.PublisherImpl = @ptrCast(@alignCast(pub_.ptr));
    const Fail = struct {
        fn create(
            _: *anyopaque,
            _: []const u8,
            _: []const u8,
            _: DDS.DataWriterQos,
            _: DDS.PresentationQosPolicy,
            _: *DDS.InstanceHandle_t,
            _: *zzdds.protocol.Guid,
        ) anyerror!zzdds.protocol.ProtocolWriter {
            return error.OutOfMemory;
        }
    };
    pub_impl.cbs.create_proto_writer = Fail.create;

    try testing.expectEqual(nil.nil_datawriter.ptr, pub_.create_datawriter(topic, .{}, null, 0).ptr);
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

test "create_datawriter: an announcement that cannot be prepared leaves the Topic unused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("NoWriterAnnouncement", "T", .{}, null, 0);
    const pub_ = fx.dp.create_publisher(.{}, null, 0);
    const pub_impl: *zzdds.dcps.PublisherImpl = @ptrCast(@alignCast(pub_.ptr));
    const Fail = struct {
        fn prepare(_: *anyopaque, _: []const DDS.InstanceHandle_t, _: DDS.InstanceHandle_t, _: []const []const u8, _: DDS.PresentationQosPolicy) anyerror!void {
            return error.OutOfMemory;
        }
    };
    pub_impl.cbs.prepare_writers = Fail.prepare;

    try testing.expectEqual(nil.nil_datawriter.ptr, pub_.create_datawriter(topic, .{}, null, 0).ptr);
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
}

/// A participant never enabled, so it runs no thread that could allocate through
/// what a test swaps. The factory's QoS decides that; the participant's own only
/// governs what it creates. Stays disabled through `fx.deinit()`, which frees what
/// is left without the deletes a disabled participant refuses.
/// `fa` is what entities created under it keep allocating through, so it must
/// outlive them; declare it before this, and reset it before `fx.deinit()`.
/// On a runtime, a manual one, driven only at teardown: a hosted worker would
/// deliver what creating a Topic pushes to the builtin reader, reading the
/// participant's allocator as a test swaps it.
fn initForFailingAllocations(alloc: std.mem.Allocator) !Fixture {
    var fx = try Fixture.initOn(alloc, .{ .entity_factory = .{ .autoenable_created_entities = false } }, true);
    errdefer fx.deinit();
    const dp_impl: *zzdds.dcps.DomainParticipantImpl = @ptrCast(@alignCast(fx.dp.ptr));
    try testing.expect(!dp_impl.enabled.load(.acquire));
    return fx;
}

/// Runs `ctx.create()` with each allocation through `target` failing in turn,
/// until one run reaches no failure. A create that fails must leave `topic` as
/// it found it. One that succeeds despite a failure it could tolerate is kept.
fn expectFailedCreatesLeaveTopic(fa: *std.testing.FailingAllocator, target: *std.mem.Allocator, topic: *TopicImpl, ctx: anytype) !void {
    const backing = target.*;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        const users = topic.users.load(.acquire);
        const refs = topic.refs.load(.acquire);
        fa.* = .init(backing, .{ .fail_index = fail_index });
        target.* = fa.allocator();
        const created = ctx.create();
        target.* = backing;
        if (!created) {
            try testing.expectEqual(users, topic.users.load(.acquire));
            try testing.expectEqual(refs, topic.refs.load(.acquire));
        }
        if (!fa.has_induced_failure) {
            try testing.expect(created);
            break;
        }
    }
    try testing.expect(fail_index > 0);
}

test "create_datawriter: running out of memory leaves the Topic as it was" {
    var fa: std.testing.FailingAllocator = undefined;
    var fx = try initForFailingAllocations(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("WriterOom", "T", .{}, null, 0);
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const pub_ = fx.dp.create_publisher(.{}, null, 0);
    const pub_impl: *zzdds.dcps.PublisherImpl = @ptrCast(@alignCast(pub_.ptr));
    const Create = struct {
        pub_: DDS.Publisher,
        topic: DDS.Topic,
        fn create(self: @This()) bool {
            return self.pub_.create_datawriter(self.topic, .{}, null, 0).ptr != nil.nil_datawriter.ptr;
        }
    };
    const backing = pub_impl.alloc;
    try expectFailedCreatesLeaveTopic(&fa, &pub_impl.alloc, impl, Create{ .pub_ = pub_, .topic = topic });
    fa = .init(backing, .{});
}

test "create_datareader: running out of memory leaves the Topic as it was" {
    var fa: std.testing.FailingAllocator = undefined;
    var fx = try initForFailingAllocations(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("ReaderOom", "T", .{}, null, 0);
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const sub_impl: *zzdds.dcps.SubscriberImpl = @ptrCast(@alignCast(sub.ptr));
    const Create = struct {
        sub: DDS.Subscriber,
        description: DDS.TopicDescription,
        fn create(self: @This()) bool {
            return self.sub.create_datareader(self.description, .{}, null, 0).ptr != nil.nil_datareader.ptr;
        }
    };
    const backing = sub_impl.alloc;
    try expectFailedCreatesLeaveTopic(&fa, &sub_impl.alloc, impl, Create{ .sub = sub, .description = impl.toTopicDescription() });
    fa = .init(backing, .{});
}

test "create_contentfilteredtopic: running out of memory leaves the related Topic as it was" {
    var fa: std.testing.FailingAllocator = undefined;
    var fx = try initForFailingAllocations(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("CftOom", "T", .{}, null, 0);
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const dp_impl: *zzdds.dcps.DomainParticipantImpl = @ptrCast(@alignCast(fx.dp.ptr));
    const Create = struct {
        dp: DDS.DomainParticipant,
        topic: DDS.Topic,
        fn create(self: @This()) bool {
            return self.dp.create_contentfilteredtopic("CftOom_f", self.topic, "x = 1", &DDS.StringSeq{}).ptr != nil.nil_cft.ptr;
        }
    };
    const backing = dp_impl.alloc;
    try expectFailedCreatesLeaveTopic(&fa, &dp_impl.alloc, impl, Create{ .dp = fx.dp, .topic = topic });
    fa = .init(backing, .{});
}

test "create_topic: running out of memory leaves no Topic behind" {
    var fa: std.testing.FailingAllocator = undefined;
    var fx = try initForFailingAllocations(testing.allocator);
    defer fx.deinit();
    const dp_impl: *zzdds.dcps.DomainParticipantImpl = @ptrCast(@alignCast(fx.dp.ptr));
    const backing = dp_impl.alloc;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        const before = dp_impl.topics.items.len;
        fa = .init(backing, .{ .fail_index = fail_index });
        dp_impl.alloc = fa.allocator();
        const topic = fx.dp.create_topic("TopicOom", "T", .{}, null, 0);
        dp_impl.alloc = backing;
        // testing.allocator catches the Topic itself leaking.
        if (topic.ptr == nil.nil_topic.ptr) try testing.expectEqual(before, dp_impl.topics.items.len);
        if (!fa.has_induced_failure) break;
    }
    try testing.expect(fail_index > 0);
    fa = .init(backing, .{});
}

test "a reader with a delivery in flight keeps its filter through delete_contained_entities" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("InFlight", "T", .{}, null, 0);
    const topic_impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const cft = fx.dp.create_contentfilteredtopic("InFlight_f", topic, "x = 1", &DDS.StringSeq{});
    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const dr = sub.create_datareader(cft_impl.toTopicDescription(), .{}, null, 0);
    const dr_impl: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    // What a delivery holds while it evaluates the filter.
    try testing.expect(dr_impl.acquireQuiesce());
    try testing.expectEqual(DDS.RETCODE_OK, fx.dp.delete_contained_entities());

    // The participant's references are gone; the reader's and, through the
    // filter, its related Topic's remain. The allocator reports a leak if the
    // last release below does not free them.
    try testing.expectEqual(@as(u32, 1), cft_impl.refs.load(.acquire));
    try testing.expectEqual(@as(u32, 1), topic_impl.refs.load(.acquire));
    try testing.expectEqualStrings("InFlight_f", cft_impl.name);
    try testing.expectEqualStrings("InFlight", topic_impl.topic_name);

    dr_impl.releaseQuiesce();
}

test "delete_topic: a deleted DataWriter still finishing no longer uses the Topic" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("WriterFinishing", "T", .{}, null, 0);
    const topic_impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const pub_ = fx.dp.create_publisher(.{}, null, 0);
    const dw = pub_.create_datawriter(topic, .{}, null, 0);
    const dw_impl: *zzdds.dcps.DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    // What a background callback holds while it runs.
    try testing.expect(dw_impl.acquireQuiesce());
    try testing.expectEqual(DDS.RETCODE_OK, pub_.delete_datawriter(dw));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));

    // The writer's reference keeps the Topic's memory, not the Topic: its name
    // is free again. The allocator reports a leak if the last release below
    // does not free it.
    try testing.expectEqual(@as(u32, 1), topic_impl.refs.load(.acquire));
    try testing.expectEqualStrings("WriterFinishing", topic_impl.topic_name);
    const again = fx.dp.create_topic("WriterFinishing", "T", .{}, null, 0);
    try testing.expect(again.ptr != nil.nil_topic.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, again));

    dw_impl.releaseQuiesce();
}

test "delete_topic: a deleted DataReader still finishing no longer uses the Topic" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("ReaderFinishing", "T", .{}, null, 0);
    const topic_impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const dr = sub.create_datareader(topic_impl.toTopicDescription(), .{}, null, 0);
    const dr_impl: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    try testing.expect(dr_impl.acquireQuiesce());
    try testing.expectEqual(DDS.RETCODE_OK, sub.delete_datareader(dr));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));
    try testing.expectEqual(@as(u32, 1), topic_impl.refs.load(.acquire));
    try testing.expectEqualStrings("ReaderFinishing", topic_impl.topic_name);

    dr_impl.releaseQuiesce();
}

test "a deleted DataReader still finishing no longer uses its filter, nor the filter its Topic" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    const topic = fx.dp.create_topic("FilterFinishing", "T", .{}, null, 0);
    const topic_impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    const cft = fx.dp.create_contentfilteredtopic("FilterFinishing_f", topic, "x = 1", &DDS.StringSeq{});
    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const dr = sub.create_datareader(cft_impl.toTopicDescription(), .{}, null, 0);
    const dr_impl: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    try testing.expect(dr_impl.acquireQuiesce());
    try testing.expectEqual(DDS.RETCODE_OK, sub.delete_datareader(dr));
    try testing.expectEqual(DDS.RETCODE_OK, deleteCft(fx.dp, cft));
    try testing.expectEqual(DDS.RETCODE_OK, deleteTopic(fx.dp, topic));

    // The delivery still evaluates the filter, which still reads its Topic.
    try testing.expectEqual(@as(u32, 1), cft_impl.refs.load(.acquire));
    try testing.expectEqual(@as(u32, 1), topic_impl.refs.load(.acquire));
    try testing.expectEqualStrings("FilterFinishing_f", cft_impl.name);
    try testing.expectEqualStrings("FilterFinishing", topic_impl.topic_name);

    dr_impl.releaseQuiesce();
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
