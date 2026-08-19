//! Shared machinery for RTPS builtin endpoint pairs matched by well-known
//! EntityId (SEDP's publications/subscriptions pairs, WLP's participant
//! message pair, and future XTypes/DDS-Security builtin endpoints).
//!
//! Deliberately excludes SPDP: SPDP is stateless/multicast (a bootstrap
//! protocol with no matched-proxy reliability), structurally different
//! enough that forcing it into this shape would be a bad fit rather than a
//! simplification.
//!
//! Two things are common across every StatefulWriter/StatefulReader-based
//! builtin endpoint pair and are generalized here:
//!   - matching: given a remote participant's advertised BuiltinEndpointSet
//!     bitmask, decide whether to add a WriterProxy/ReaderProxy.
//!   - dispatch: given one already-parsed incoming submessage, route it to
//!     the pair whose well-known EntityId it addresses.
//! The wire codec (payload encode/decode) is deliberately NOT shared — each
//! protocol's payload shape differs too much (SEDP: PL_CDR/PID parameter
//! lists; WLP: a small fixed plain-CDR struct; DDS-Security's will carry
//! real crypto/session state) for a shared codec to be a good fit. Each
//! owning module keeps its own codec, matching the existing SPDP/SEDP
//! convention.
//!
//! BuiltinPair does not own construction of the underlying StatefulWriter/
//! StatefulReader — the owning module constructs those directly (as SEDP
//! already does), so it retains full control over per-protocol setup like
//! tracers, probe-result callbacks, or data callbacks. BuiltinPair only
//! wraps the resulting pointers to provide the matching/dispatch/teardown
//! behavior that's common across pairs.

const std = @import("std");
const iface = @import("interface.zig");
const tr_iface = @import("../transport/interface.zig");
const guid_mod = @import("../rtps/guid.zig");
const writer_sm_mod = @import("../rtps/writer_sm.zig");
const reader_sm_mod = @import("../rtps/reader_sm.zig");
const history_mod = @import("../rtps/history.zig");
const time_mod = @import("../util/time.zig");
const msg_mod = @import("../rtps/message/root.zig");

const Locator = tr_iface.Locator;
const Guid = guid_mod.Guid;
const GuidPrefix = guid_mod.GuidPrefix;
const EntityId = guid_mod.EntityId;
const StatefulWriter = writer_sm_mod.StatefulWriter;
const StatefulReader = reader_sm_mod.StatefulReader;
const ReaderProxy = writer_sm_mod.ReaderProxy;
const WriterProxy = reader_sm_mod.WriterProxy;
const CacheChange = history_mod.CacheChange;
const RtpsTimestamp = time_mod.RtpsTimestamp;
const ParticipantData = iface.ParticipantData;
const SubMessage = msg_mod.SubMessage;

/// Build a plain "alive" CacheChange from a raw incoming DATA submessage
/// payload — the common shape every builtin-endpoint reader needs to feed
/// into `StatefulReader.handleData`. Callers with protocol-specific needs
/// (e.g. SEDP's disposal handling) construct their own CacheChange instead
/// of going through this helper.
pub fn makeAliveCacheChange(
    prefix: GuidPrefix,
    eid: EntityId,
    sn: history_mod.SequenceNumber,
    data: []const u8,
) CacheChange {
    return CacheChange{
        .kind = .alive,
        .writer_guid = .{ .prefix = prefix, .entity_id = eid },
        .sequence_number = sn,
        .source_timestamp = RtpsTimestamp.now(),
        .instance_handle = history_mod.INSTANCE_HANDLE_NIL,
        .key_hash = std.mem.zeroes([16]u8),
        .data = @constCast(data),
    };
}

/// One RTPS builtin endpoint pair matched by well-known EntityId.
pub const BuiltinPair = struct {
    writer: ?*StatefulWriter = null,
    reader: ?*StatefulReader = null,
    writer_entity_id: EntityId,
    reader_entity_id: EntityId,
    /// Remote's "announcer" bit: remote has a writer of this kind, so we add
    /// a WriterProxy to our own reader.
    remote_writer_bit: u32,
    /// Remote's "detector" bit: remote has a reader of this kind, so we add
    /// a ReaderProxy to our own writer.
    remote_reader_bit: u32,
    reliable: bool,

    const Self = @This();

    /// Match a newly-discovered remote participant's advertised
    /// BuiltinEndpointSet against this pair. `uc`/`mc` are the remote's
    /// already-reachability-filtered metatraffic locators — computed once
    /// by the caller and shared across every pair it owns, since the
    /// filtering itself has nothing to do with any individual pair.
    pub fn matchRemote(
        self: *Self,
        alloc: std.mem.Allocator,
        remote: *const ParticipantData,
        uc: []const Locator,
        mc: []const Locator,
    ) void {
        const eps = remote.builtin_endpoint_set;
        if (eps & self.remote_writer_bit != 0) {
            if (self.reader) |r| {
                const guid = Guid{ .prefix = remote.guid.prefix, .entity_id = self.writer_entity_id };
                const wp = WriterProxy.init(alloc, guid, uc, mc, self.reliable) catch return;
                r.addMatchedWriter(wp) catch {};
            }
        }
        if (eps & self.remote_reader_bit != 0) {
            if (self.writer) |w| {
                const guid = Guid{ .prefix = remote.guid.prefix, .entity_id = self.reader_entity_id };
                const rp = ReaderProxy.init(alloc, guid, uc, mc, false, self.reliable) catch return;
                w.addMatchedReader(rp) catch {};
            }
        }
    }

    /// Route one already-parsed submessage to this pair if its writer/reader
    /// entity ID matches; returns true if handled (caller should stop trying
    /// other pairs). Only covers the plain alive-data/heartbeat/gap/acknack
    /// routing common to every builtin pair — protocol-specific
    /// preprocessing (e.g. SEDP's StatusInfo-based dispose detection, or an
    /// SPDP-relay heuristic) must happen in the caller's own onReceive
    /// *before* falling back to this, since neither applies to every pair.
    pub fn tryHandle(self: *Self, sm: SubMessage, src_prefix: GuidPrefix) bool {
        switch (sm) {
            .data => |d| {
                if (!d.writer_entity_id.eql(self.writer_entity_id)) return false;
                if (self.reader) |r| {
                    const payload = d.serialized_payload;
                    if (payload.len != 0) {
                        const ch = makeAliveCacheChange(src_prefix, self.writer_entity_id, d.writer_sn, payload);
                        const wguid = Guid{ .prefix = src_prefix, .entity_id = self.writer_entity_id };
                        r.handleData(wguid, ch) catch {};
                    }
                }
                return true;
            },
            .heartbeat => |hb| {
                if (!hb.writer_entity_id.eql(self.writer_entity_id)) return false;
                if (self.reader) |r| {
                    const wguid = Guid{ .prefix = src_prefix, .entity_id = self.writer_entity_id };
                    r.handleHeartbeat(wguid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal());
                }
                return true;
            },
            .gap => |g| {
                if (!g.writer_entity_id.eql(self.writer_entity_id)) return false;
                if (self.reader) |r| {
                    const wguid = Guid{ .prefix = src_prefix, .entity_id = self.writer_entity_id };
                    r.handleGap(wguid, g.gap_start, g.gap_list);
                }
                return true;
            },
            .acknack => |an| {
                if (!an.reader_entity_id.eql(self.reader_entity_id)) return false;
                if (self.writer) |w| {
                    const rguid = Guid{ .prefix = src_prefix, .entity_id = self.reader_entity_id };
                    w.handleAckNack(rguid, an.reader_sn_state.base - 1, an.reader_sn_state, an.count, an.isFinal());
                }
                return true;
            },
            else => return false,
        }
    }

    /// Join background heartbeat threads before deinit() frees anything —
    /// same discipline as every other RTPS writer teardown in this codebase
    /// (heartbeat threads hold raw pointers back into the owning module's
    /// callback context, which may be freed shortly after stop() returns).
    pub fn stop(self: *Self) void {
        if (self.writer) |w| w.stopHeartbeat();
    }

    pub fn deinit(self: *Self) void {
        if (self.writer) |w| w.deinit();
        if (self.reader) |r| r.deinit();
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Minimal no-op transport for testing — mirrors writer_sm.zig's own
// null_transport test helper (not reused directly since it's private there).
const TestNullCtx = struct {
    fn canReach(_: *anyopaque, _: *const Locator) bool {
        return true;
    }
    fn send(_: *anyopaque, _: *const Locator, _: []const u8) anyerror!void {}
    fn listen(_: *anyopaque, _: *const Locator, _: tr_iface.ReceiveHandler) anyerror!void {}
    fn joinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {}
    fn leaveMulticast(_: *anyopaque, _: *const Locator) void {}
    fn unlisten(_: *anyopaque, _: *const Locator, _: tr_iface.ReceiveHandler) void {}
    fn unicastLocators(_: *anyopaque, out: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {
        out.clearRetainingCapacity();
    }
    fn setLocatorChangeHandler(_: *anyopaque, _: ?tr_iface.LocatorChangeHandler) void {}
    fn close(_: *anyopaque) void {}
};

const test_null_vtable = tr_iface.Transport.Vtable{
    .capabilities = .{},
    .can_reach = TestNullCtx.canReach,
    .send = TestNullCtx.send,
    .listen = TestNullCtx.listen,
    .join_multicast = TestNullCtx.joinMulticast,
    .leave_multicast = TestNullCtx.leaveMulticast,
    .unlisten = TestNullCtx.unlisten,
    .unicast_locators = TestNullCtx.unicastLocators,
    .set_locator_change_handler = TestNullCtx.setLocatorChangeHandler,
    .close = TestNullCtx.close,
};

var test_null_ctx: TestNullCtx = .{};
const test_null_transport = tr_iface.Transport{ .ctx = &test_null_ctx, .vtable = &test_null_vtable };

fn testPrefix(b: u8) GuidPrefix {
    return .{ .bytes = [_]u8{b} ** 12 };
}

const TEST_WRITER_BIT: u32 = 0x1000;
const TEST_READER_BIT: u32 = 0x2000;
const TEST_WRITER_EID: EntityId = .{ .entity_key = .{ 0x00, 0x03, 0x00 }, .entity_kind = 0xC2 };
const TEST_READER_EID: EntityId = .{ .entity_key = .{ 0x00, 0x03, 0x00 }, .entity_kind = 0xC7 };

fn makeTestPair(alloc: std.mem.Allocator, local_prefix: GuidPrefix, with_writer: bool, with_reader: bool) !BuiltinPair {
    var pair = BuiltinPair{
        .writer_entity_id = TEST_WRITER_EID,
        .reader_entity_id = TEST_READER_EID,
        .remote_writer_bit = TEST_WRITER_BIT,
        .remote_reader_bit = TEST_READER_BIT,
        .reliable = true,
    };
    if (with_writer) {
        pair.writer = try StatefulWriter.init(
            alloc,
            Guid{ .prefix = local_prefix, .entity_id = TEST_WRITER_EID },
            test_null_transport,
            .keep_last,
            1,
            TEST_READER_EID,
            writer_sm_mod.DEFAULT_FRAG_SIZE,
            true,
        );
    }
    if (with_reader) {
        pair.reader = try StatefulReader.init(
            alloc,
            Guid{ .prefix = local_prefix, .entity_id = TEST_READER_EID },
            test_null_transport,
            .keep_last,
            1,
            true,
        );
    }
    return pair;
}

fn testParticipantData(remote_prefix: GuidPrefix, eps: u32) ParticipantData {
    return ParticipantData{
        .guid = .{ .prefix = remote_prefix, .entity_id = guid_mod.EntityIds.participant },
        .domain_id = 0,
        .name = "",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 10_000,
        .builtin_endpoint_set = eps,
        .vendor_id = .{ .bytes = .{ 0x00, 0x00 } },
    };
}

test "BuiltinPair.matchRemote adds a WriterProxy when the remote advertises the writer bit" {
    const alloc = testing.allocator;
    var pair = try makeTestPair(alloc, testPrefix(1), false, true);
    defer pair.deinit();

    const remote = testParticipantData(testPrefix(2), TEST_WRITER_BIT);
    pair.matchRemote(alloc, &remote, &.{}, &.{});

    try testing.expectEqual(@as(usize, 1), pair.reader.?.writer_proxies.items.len);
}

test "BuiltinPair.matchRemote adds a ReaderProxy when the remote advertises the reader bit" {
    const alloc = testing.allocator;
    var pair = try makeTestPair(alloc, testPrefix(1), true, false);
    defer pair.deinit();

    const remote = testParticipantData(testPrefix(2), TEST_READER_BIT);
    pair.matchRemote(alloc, &remote, &.{}, &.{});

    try testing.expectEqual(@as(usize, 1), pair.writer.?.reader_proxies.items.len);
}

test "BuiltinPair.matchRemote adds nothing when the remote advertises neither bit" {
    const alloc = testing.allocator;
    var pair = try makeTestPair(alloc, testPrefix(1), true, true);
    defer pair.deinit();

    const remote = testParticipantData(testPrefix(2), 0);
    pair.matchRemote(alloc, &remote, &.{}, &.{});

    try testing.expectEqual(@as(usize, 0), pair.reader.?.writer_proxies.items.len);
    try testing.expectEqual(@as(usize, 0), pair.writer.?.reader_proxies.items.len);
}

test "BuiltinPair.tryHandle routes a DATA submessage addressed to this pair's writer" {
    const alloc = testing.allocator;
    var pair = try makeTestPair(alloc, testPrefix(1), false, true);
    defer pair.deinit();

    const remote = testParticipantData(testPrefix(2), TEST_WRITER_BIT);
    pair.matchRemote(alloc, &remote, &.{}, &.{});

    const sm = SubMessage{ .data = .{
        .flags = 0,
        .reader_entity_id = TEST_READER_EID,
        .writer_entity_id = TEST_WRITER_EID,
        .writer_sn = 1,
        .inline_qos = null,
        .serialized_payload = "payload",
    } };
    const handled = pair.tryHandle(sm, testPrefix(2));
    try testing.expect(handled);
}

test "BuiltinPair.tryHandle ignores a submessage addressed to a different writer" {
    const alloc = testing.allocator;
    var pair = try makeTestPair(alloc, testPrefix(1), false, true);
    defer pair.deinit();

    const other_eid: EntityId = .{ .entity_key = .{ 0x00, 0x09, 0x00 }, .entity_kind = 0xC2 };
    const sm = SubMessage{ .data = .{
        .flags = 0,
        .reader_entity_id = TEST_READER_EID,
        .writer_entity_id = other_eid,
        .writer_sn = 1,
        .inline_qos = null,
        .serialized_payload = "payload",
    } };
    try testing.expect(!pair.tryHandle(sm, testPrefix(2)));
}
