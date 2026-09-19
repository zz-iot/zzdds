//! Shared setup pieces for `MockNetwork`-based discovery-ordering tests.
//!
//! Decomposed from `test/dcps/mock_loopback_test.zig`'s original monolithic
//! `runMockLoopback`: that function does setup, delivery, and assertions all
//! inline, which is fine when every test just wants both sides to discover
//! each other "naturally". Discovery-ordering tests need to control
//! delivery explicitly between creating each side and writing/reading data
//! (see `docs/design/discovery-association-race-testing.md`), so this
//! module only does setup -- callers own the `net.deliverAll()` /
//! `side.transport.deliver()` calls themselves.
//!
//! Also the basis for later one-to-many scenarios: `createReaderSide` is
//! callable N times against one shared `MockNetwork` and writer.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

pub const MockNetwork = zzdds.mock_transport.MockNetwork;
pub const MockTransport = zzdds.mock_transport.MockTransport;
pub const Locator = zzdds.transport.Locator;
const SpdpSedpDiscovery = zzdds.combined_discovery.SpdpSedpDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
pub const DataWriterImpl = zzdds.dcps.DataWriterImpl;
pub const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;

/// One participant plus its transport/discovery, kept alive for the
/// caller's duration. Teardown order mirrors `mock_loopback_test.zig`'s
/// existing defer chain: delete_participant, then factory, then discovery,
/// then transport.
pub const Side = struct {
    transport: *MockTransport,
    disc: *SpdpSedpDiscovery,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,

    pub fn deinit(self: *Side) void {
        const dpf = self.factory.toDDSFactory();
        _ = dpf.delete_participant(self.dp);
        self.factory.deinit();
        self.disc.deinit();
        self.transport.deinit();
    }
};

fn createSide(alloc: std.mem.Allocator, net: *MockNetwork, locator: Locator, domain: u32) !Side {
    const t = try MockTransport.init(alloc, net, &.{locator});
    errdefer t.deinit();
    // 100 ms announcement period lets the SPDP timer fire during a poll loop
    // that sleeps between `deliver()`/`deliverAll()` rounds -- matches
    // mock_loopback_test.zig's existing, accepted pattern.
    const disc = try SpdpSedpDiscovery.init(alloc, t.transport(), 0, 100);
    errdefer disc.deinit();
    var factory = try DomainParticipantFactoryImpl.init(
        alloc,
        t.transport(),
        disc.toDiscovery(),
        noop_security,
        .spec_random,
        .{},
    );
    errdefer factory.deinit();
    const dpf = factory.toDDSFactory();
    const dp = dpf.create_participant(domain, .{}, null, 0);
    return .{ .transport = t, .disc = disc, .factory = factory, .dp = dp };
}

pub const WriterSide = struct {
    side: Side,
    dw: DDS.DataWriter,
    dw_impl: *DataWriterImpl,

    pub fn deinit(self: *WriterSide) void {
        self.side.deinit();
    }
};

pub const ReaderSide = struct {
    side: Side,
    dr: DDS.DataReader,
    dr_impl: *DataReaderImpl,

    pub fn deinit(self: *ReaderSide) void {
        self.side.deinit();
    }
};

pub fn createWriterSide(
    alloc: std.mem.Allocator,
    net: *MockNetwork,
    locator: Locator,
    domain: u32,
    topic_name: [:0]const u8,
    type_name: [:0]const u8,
    dw_qos: DDS.DataWriterQos,
) !WriterSide {
    var side = try createSide(alloc, net, locator, domain);
    errdefer side.deinit();
    const pub_w = side.dp.create_publisher(.{}, null, 0);
    const topic_w = side.dp.create_topic(topic_name, type_name, .{}, null, 0);
    const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    return .{ .side = side, .dw = dw, .dw_impl = dw_impl };
}

pub fn createReaderSide(
    alloc: std.mem.Allocator,
    net: *MockNetwork,
    locator: Locator,
    domain: u32,
    topic_name: [:0]const u8,
    type_name: [:0]const u8,
    dr_qos: DDS.DataReaderQos,
) !ReaderSide {
    var side = try createSide(alloc, net, locator, domain);
    errdefer side.deinit();
    const sub_r = side.dp.create_subscriber(.{}, null, 0);
    const topic_r = side.dp.create_topic(topic_name, type_name, .{}, null, 0);
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    const dr = sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));
    return .{ .side = side, .dr = dr, .dr_impl = dr_impl };
}
