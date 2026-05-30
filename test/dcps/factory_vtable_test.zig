//! DomainParticipantFactory vtable coverage tests.
//!
//! Exercises the vtable methods left uncovered by existing tests:
//! lookup_participant (found/nil), set/get_default_participant_qos,
//! set/get_qos, deinit-via-vtable.

const std = @import("std");
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
    const dp = f.vtable.create_participant(f.ptr, 7, .{}, nil.nil_dp_listener, 0);
    defer _ = f.vtable.delete_participant(f.ptr, dp);

    const found = f.vtable.lookup_participant(f.ptr, 7);
    try testing.expect(found.ptr == dp.ptr);
}

test "lookup_participant: returns nil for unknown domain_id" {
    var h = try Harness.init(2);
    defer h.deinit();
    const f = h.factory.toDDSFactory();
    const dp = f.vtable.create_participant(f.ptr, 7, .{}, nil.nil_dp_listener, 0);
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
    _ = f.vtable.set_default_participant_qos(f.ptr, qos);

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
    _ = f.vtable.set_qos(f.ptr, qos);

    var out: DDS.DomainParticipantFactoryQos = .{};
    _ = f.vtable.get_qos(f.ptr, &out);
    try testing.expectEqual(false, out.entity_factory.autoenable_created_entities);
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
