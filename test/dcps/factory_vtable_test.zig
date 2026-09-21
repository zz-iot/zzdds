//! DomainParticipantFactory vtable coverage tests.
//!
//! Exercises the vtable methods left uncovered by existing tests:
//! lookup_participant (found/nil), set/get_default_participant_qos,
//! set/get_qos, deinit-via-vtable.

const std = @import("std");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const dcps = zzdds.dcps;
const DomainParticipantFactoryImpl = dcps.DomainParticipantFactoryImpl;
const nil = dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const mock_tr = zzdds.mock_transport;
const iface = zzdds.discovery;

const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;
const Locator = mock_tr.Locator;
const testing = std.testing;
const alloc = testing.allocator;

// ── Noop discovery ────────────────────────────────────────────────────────────

var noop_disc_sentinel: u8 = 0;

const noop_vtable = iface.Discovery.Vtable{
    .start = struct {
        fn f(_: *anyopaque, _: *const iface.ParticipantAnnouncement, _: *const iface.Callbacks) anyerror!void {}
    }.f,
    .stop = struct {
        fn f(_: *anyopaque) void {}
    }.f,
    .announce_writer = struct {
        fn f(_: *anyopaque, _: *const iface.WriterAnnouncement) anyerror!void {}
    }.f,
    .retract_writer = struct {
        fn f(_: *anyopaque, _: iface.Guid) void {}
    }.f,
    .announce_reader = struct {
        fn f(_: *anyopaque, _: *const iface.ReaderAnnouncement) anyerror!void {}
    }.f,
    .retract_reader = struct {
        fn f(_: *anyopaque, _: iface.Guid) void {}
    }.f,
    .deinit = struct {
        fn f(_: *anyopaque) void {}
    }.f,
    .wlp_tick = struct {
        fn f(_: *anyopaque, _: i64, _: iface.WlpTickInfo) void {}
    }.f,
};

fn noopDisc() iface.Discovery {
    return .{ .ctx = &noop_disc_sentinel, .vtable = &noop_vtable };
}

// ── Harness ───────────────────────────────────────────────────────────────────

const Harness = struct {
    net: *MockNetwork,
    transport: *MockTransport,
    factory: *DomainParticipantFactoryImpl,

    fn init(pid: u8) !Harness {
        const net = try MockNetwork.init(alloc);
        errdefer net.deinit();
        const loc = Locator.udp4(.{ 127, 0, 0, pid }, 7900 + @as(u16, pid));
        const t = try MockTransport.init(alloc, net, &.{loc});
        errdefer t.deinit();
        const factory = try DomainParticipantFactoryImpl.init(
            alloc,
            t.transport(),
            noopDisc(),
            noop_security,
            .spec_random,
            .{},
        );
        return .{ .net = net, .transport = t, .factory = factory };
    }

    fn deinit(self: *Harness) void {
        self.factory.deinit();
        self.transport.deinit();
        self.net.deinit();
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "lookup_participant: returns participant for matching domain_id" {
    var h = try Harness.init(1);
    defer h.deinit();
    const f = h.factory.toDDSFactory();
    const dp = f.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = f.vtable.delete_participant(f.ptr, dp);

    const found = f.vtable.lookup_participant(f.ptr, test_domain.get());
    try testing.expect(found.ptr == dp.ptr);
}

test "lookup_participant: returns nil for unknown domain_id" {
    var h = try Harness.init(2);
    defer h.deinit();
    const f = h.factory.toDDSFactory();
    const dp = f.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = f.vtable.delete_participant(f.ptr, dp);

    const found = f.vtable.lookup_participant(f.ptr, 99);
    try testing.expect(found.ptr == dcps.NIL_PTR);
}

test "set_default_participant_qos / get_default_participant_qos: round-trips" {
    var h = try Harness.init(3);
    defer h.deinit();
    const f = h.factory.toDDSFactory();

    var qos = DDS.DomainParticipantQos{};
    qos.entity_factory.autoenable_created_entities = false;
    _ = f.set_default_participant_qos(qos);

    var out: DDS.DomainParticipantQos = .{};
    _ = f.vtable.get_default_participant_qos(f.ptr, &out);
    try testing.expectEqual(false, out.entity_factory.autoenable_created_entities);
}

test "set_qos / get_qos: round-trips" {
    var h = try Harness.init(4);
    defer h.deinit();
    const f = h.factory.toDDSFactory();

    var qos = DDS.DomainParticipantFactoryQos{};
    qos.entity_factory.autoenable_created_entities = false;
    _ = f.set_qos(qos);

    var out: DDS.DomainParticipantFactoryQos = .{};
    _ = f.vtable.get_qos(f.ptr, &out);
    try testing.expectEqual(false, out.entity_factory.autoenable_created_entities);
}

test "create_participant with autoenable_created_entities=false: children stay disabled despite their own default (true) QoS" {
    // Regression for a real bug (PR #91, Greptile review): child.enabled was
    // set from ONLY the parent's entity_factory QoS flag, never ANDed with
    // whether the parent itself is currently enabled. Since
    // autoenable_created_entities now correctly defaults to true (see this
    // PR's idl/dcps.idl fix), a Publisher created under a disabled
    // participant with the default PublisherQos was wrongly marked enabled
    // -- it could pass every NOT_ENABLED guard and (transitively, for its
    // own future DataWriters) attempt discovery before the participant had
    // even called start(). Verified below via enable()'s own
    // PRECONDITION_NOT_MET check, which only fires on a genuinely disabled
    // entity -- the bugged code path returned RETCODE_OK (already-enabled
    // no-op) instead, silently.
    const net = try MockNetwork.init(alloc);
    defer net.deinit();
    const loc = Locator.udp4(.{ 127, 0, 0, 6 }, 7906);
    const t = try MockTransport.init(alloc, net, &.{loc});
    defer t.deinit();
    const factory = try DomainParticipantFactoryImpl.init(
        alloc,
        t.transport(),
        noopDisc(),
        noop_security,
        .spec_random,
        .{},
    );
    defer factory.deinit();
    const f = factory.toDDSFactory();

    var factory_qos = DDS.DomainParticipantFactoryQos{};
    factory_qos.entity_factory.autoenable_created_entities = false;
    try testing.expectEqual(DDS.RETCODE_OK, f.set_qos(factory_qos));

    const dp = f.create_participant(test_domain.get(), .{}, null, 0);
    defer _ = f.delete_participant(dp);
    try testing.expect(dp.ptr != nil.nil_participant.ptr);
    // The participant itself must be disabled -- sanity check before testing
    // its children. Can't use dp.vtable.enable() for this: a participant has
    // no "factory not enabled" precondition (it isn't an Entity's child per
    // spec) and calling it would immediately flip enabled=true, destroying
    // the very state this test needs. Use a NOT_ENABLED-guarded operation
    // instead.
    try testing.expectEqual(DDS.RETCODE_NOT_ENABLED, dp.vtable.ignore_participant(dp.ptr, DDS.HANDLE_NIL));

    // Default PublisherQos: entity_factory.autoenable_created_entities is
    // now correctly true, but the PARTICIPANT is disabled, so the Publisher
    // must come in disabled regardless.
    const publisher = dp.create_publisher(.{}, null, 0);
    defer _ = dp.vtable.delete_publisher(dp.ptr, publisher);
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, publisher.vtable.enable(publisher.ptr));

    // Enabling the participant should then let the Publisher's own enable()
    // succeed -- confirms this is a real, unstuck precondition chain, not a
    // permanently-wedged entity.
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.enable(dp.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, publisher.vtable.enable(publisher.ptr));
}

test "deinit via vtable: does not double-free" {
    const net = try MockNetwork.init(alloc);
    defer net.deinit();
    const loc = Locator.udp4(.{ 127, 0, 0, 5 }, 7905);
    const t = try MockTransport.init(alloc, net, &.{loc});
    defer t.deinit();
    const factory = try DomainParticipantFactoryImpl.init(
        alloc,
        t.transport(),
        noopDisc(),
        noop_security,
        .spec_random,
        .{},
    );
    // Exercise the vtable deinit path (not factory.deinit() directly).
    const f = factory.toDDSFactory();
    f.vtable.deinit(f.ptr);
    // Transport and network are still alive; test just verifies no crash.
}

test "DomainParticipantFactory: set_default_participant_qos with user_data — clone survives replacement" {
    const net = try MockNetwork.init(alloc);
    defer net.deinit();
    const loc = Locator.udp4(.{ 127, 0, 0, 0xC0 }, 7900 + 0xC0);
    const t = try MockTransport.init(alloc, net, &.{loc});
    defer t.deinit();
    const factory = try DomainParticipantFactoryImpl.init(alloc, t.transport(), noopDisc(), noop_security, .spec_random, .{});
    defer factory.deinit();
    const f = factory.toDDSFactory();

    var d1 = [_]u8{0x11};
    var q1 = DDS.DomainParticipantQos{};
    q1.user_data.value = .{ ._buffer = &d1, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, f.vtable.set_default_participant_qos(f.ptr, &q1));

    var d2 = [_]u8{0x22};
    var q2 = DDS.DomainParticipantQos{};
    q2.user_data.value = .{ ._buffer = &d2, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, f.vtable.set_default_participant_qos(f.ptr, &q2));

    var got = DDS.DomainParticipantQos{};
    try testing.expectEqual(DDS.RETCODE_OK, f.vtable.get_default_participant_qos(f.ptr, &got));
    try testing.expectEqual(@as(u32, 1), got.user_data.value._length);
    got.deinit(alloc);
}
