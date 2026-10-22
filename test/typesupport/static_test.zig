//! A genuinely linked provider: no OS-loaded source descriptor or fixture path.
const std = @import("std");
const zzdds = @import("zzdds");
const ts = zzdds.typesupport;
const provider = @import("static_provider");
const options = @import("provider_options");
extern fn zidl_ts_c_probe(*const ts.wire.Library) callconv(.c) c_int;
const sample = [_]u8{ 0, 1, 0, 0, 0, 0, 128, 63, 42, 0, 0, 0 };

test "linked descriptor C ABI and registration survive catalog removal" {
    try std.testing.expectEqual(@as(c_int, 0), zidl_ts_c_probe(&provider.library));
    var libraries = try ts.Manager.init(std.testing.allocator, 1);
    defer libraries.deinit();
    try libraries.addStatic("linked", &provider.library);
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(std.testing.allocator);
    defer delivery.deinit();
    const transport = try delivery.newTransport();
    defer transport.deinit();
    const discovery = try delivery.newDiscovery();
    defer discovery.deinit();
    const owner = try zzdds.dcps.DomainParticipantFactoryImpl.init(std.testing.allocator, transport.transport(), discovery.toDiscovery(), zzdds.noop_security.noop_security_plugins, .spec_random, .{});
    defer owner.deinit();
    const factory = owner.toDDSFactory();
    const participant = factory.create_participant(188, .{}, null, 0);
    try std.testing.expect(participant.ptr != zzdds.dcps.NIL_PTR);
    defer _ = factory.delete_participant(participant);
    const selected = try libraries.select("linked", "LibraryTest::Reading");
    const registered = ts.register(participant, selected) catch |err| {
        selected.deinit();
        return err;
    };
    selected.deinit();
    defer registered.deinit();
    try libraries.remove("linked");
    const topic = participant.create_topic("LinkedReading", "LibraryTest::Reading", .{}, null, 0);
    try std.testing.expect(topic.ptr != zzdds.dcps.NIL_PTR);
    const publisher = participant.create_publisher(.{}, null, 0);
    try std.testing.expect(publisher.ptr != zzdds.dcps.NIL_PTR);
    const writer = publisher.create_datawriter(topic, .{}, null, 0);
    try std.testing.expect(writer.ptr != zzdds.dcps.NIL_PTR);
    try registered.write(writer, .alive, &sample);
    try std.testing.expectEqual(@as(usize, 1), libraries.liveGenerations());
}

test "static-only build rejects dynamic loading without publishing a generation" {
    if (options.dynamic_enabled) return error.SkipZigTest;
    try std.testing.expect(!ts.dynamic_loading_available);
    var libraries = try ts.Manager.init(std.testing.allocator, 1);
    defer libraries.deinit();
    try std.testing.expectError(error.DynamicLoadingUnavailable, libraries.load("dynamic", "absent-library"));
    try std.testing.expectEqual(@as(usize, 0), libraries.liveGenerations());
    try libraries.addStatic("linked", &provider.library);
    const selection = try libraries.select("linked", "LibraryTest::Reading");
    defer selection.deinit();
    try selection.validate(&sample);
}
