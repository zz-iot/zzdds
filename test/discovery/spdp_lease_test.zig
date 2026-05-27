//! SPDP lease-expiry tests using ManualClock.
//!
//! These tests exercise the participant-discovery and lease-eviction paths of
//! SpdpEndpoints without starting the timer thread or a real network. The
//! ManualClock lets us jump forward in time deterministically.

const std = @import("std");
const zzdds = @import("zzdds");

const spdp_mod = zzdds.spdp_discovery;
const iface = zzdds.discovery;
const time_mod = zzdds.util.time;
const mock_tr = zzdds.mock_transport;

const SpdpEndpoints = spdp_mod.SpdpEndpoints;
const ManualClock = time_mod.ManualClock;
const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;
const GuidPrefix = iface.GuidPrefix;
const Guid = iface.Guid;
const Callbacks = iface.Callbacks;
const ParticipantData = iface.ParticipantData;
const WriterData = iface.WriterData;
const ReaderData = iface.ReaderData;

const testing = std.testing;

// ── Helpers ───────────────────────────────────────────────────────────────────

fn prefix(b: u8) GuidPrefix {
    return .{ .bytes = [_]u8{b} ** 12 };
}

/// Build a minimal PL-CDR-LE SPDP participant payload with the given GUID
/// prefix and lease duration.
fn buildPayload(alloc: std.mem.Allocator, p: GuidPrefix, lease_ms: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    // PL_CDR_LE encapsulation header
    try buf.appendSlice(alloc, &.{ 0x00, 0x03, 0x00, 0x00 });

    // PID_PARTICIPANT_GUID (0x0050), length = 16
    try buf.appendSlice(alloc, &.{ 0x50, 0x00, 0x10, 0x00 });
    try buf.appendSlice(alloc, &p.bytes);
    try buf.appendSlice(alloc, &.{ 0x00, 0x00, 0x01, 0xc1 }); // participant entity_id

    // PID_PARTICIPANT_LEASE_DURATION (0x0002), length = 8: RTPS seconds + fraction.
    const lease = time_mod.RtpsDuration.fromDuration(.{
        .sec = @intCast(lease_ms / 1000),
        .nanosec = (lease_ms % 1000) * 1_000_000,
    });
    try buf.appendSlice(alloc, &.{ 0x02, 0x00, 0x08, 0x00 });
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(i32, &tmp, lease.seconds, .little);
    try buf.appendSlice(alloc, &tmp);
    std.mem.writeInt(u32, &tmp, lease.fraction, .little);
    try buf.appendSlice(alloc, &tmp);

    // PID_SENTINEL (0x0001), length = 0
    try buf.appendSlice(alloc, &.{ 0x01, 0x00, 0x00, 0x00 });

    return buf.toOwnedSlice(alloc);
}

// ── Event tracker ─────────────────────────────────────────────────────────────

const Tracker = struct {
    discovered: u32 = 0,
    lost: u32 = 0,
    lost_guid: ?Guid = null,

    fn cbs(self: *Tracker) Callbacks {
        return .{
            .ctx = self,
            .on_participant_discovered = onDiscovered,
            .on_participant_lost = onLost,
            .on_writer_discovered = noopWd,
            .on_writer_lost = noopGuid,
            .on_reader_discovered = noopRd,
            .on_reader_lost = noopGuid,
        };
    }

    fn onDiscovered(ctx: *anyopaque, _: *const ParticipantData) void {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.discovered += 1;
    }

    fn onLost(ctx: *anyopaque, guid: Guid) void {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.lost += 1;
        self.lost_guid = guid;
    }

    fn noopWd(_: *anyopaque, _: *const WriterData) void {}
    fn noopRd(_: *anyopaque, _: *const ReaderData) void {}
    fn noopGuid(_: *anyopaque, _: Guid) void {}
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "SPDP: processSpdpPayload fires on_participant_discovered" {
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();
    const mt = try MockTransport.init(alloc, net, &.{});
    defer mt.deinit();

    const spdp = try SpdpEndpoints.init(alloc, mt.transport(), 0, 3000);
    defer spdp.deinit();

    var clock = ManualClock.init(0);
    spdp.setClock(clock.clock());

    var tr = Tracker{};
    const c = tr.cbs();
    spdp.callbacks = &c;

    const peer = prefix(0xCC);
    const payload = try buildPayload(alloc, peer, 500);
    defer alloc.free(payload);

    spdp.processSpdpPayload(peer, payload);

    try testing.expectEqual(@as(u32, 1), tr.discovered);
    try testing.expectEqual(@as(u32, 0), tr.lost);
}

test "SPDP: lease expiry fires on_participant_lost" {
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();
    const mt = try MockTransport.init(alloc, net, &.{});
    defer mt.deinit();

    const spdp = try SpdpEndpoints.init(alloc, mt.transport(), 0, 3000);
    defer spdp.deinit();

    var clock = ManualClock.init(0);
    spdp.setClock(clock.clock());

    var tr = Tracker{};
    const c = tr.cbs();
    spdp.callbacks = &c;

    const peer = prefix(0xDD);
    // lease_ms = 100 → expires_ns = clock(0) + 100ms = 100_000_000 ns
    const payload = try buildPayload(alloc, peer, 100);
    defer alloc.free(payload);

    spdp.processSpdpPayload(peer, payload);
    try testing.expectEqual(@as(u32, 1), tr.discovered);

    // T=99ms: not yet expired
    clock.set(99 * std.time.ns_per_ms);
    spdp.checkLeases();
    try testing.expectEqual(@as(u32, 0), tr.lost);

    // T=100ms: at expiry boundary → evicted
    clock.set(100 * std.time.ns_per_ms);
    spdp.checkLeases();
    try testing.expectEqual(@as(u32, 1), tr.lost);
    try testing.expect(tr.lost_guid != null);
    try testing.expect(tr.lost_guid.?.prefix.eql(peer));
}

test "SPDP: re-announcement before expiry refreshes lease" {
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();
    const mt = try MockTransport.init(alloc, net, &.{});
    defer mt.deinit();

    const spdp = try SpdpEndpoints.init(alloc, mt.transport(), 0, 3000);
    defer spdp.deinit();

    var clock = ManualClock.init(0);
    spdp.setClock(clock.clock());

    var tr = Tracker{};
    const c = tr.cbs();
    spdp.callbacks = &c;

    const peer = prefix(0xEE);
    const payload = try buildPayload(alloc, peer, 100);
    defer alloc.free(payload);

    // Initial announcement at T=0: expires at T=100.
    spdp.processSpdpPayload(peer, payload);

    // At T=80ms the peer re-announces: expires_ns refreshed to 80ms+100ms=180ms.
    clock.set(80 * std.time.ns_per_ms);
    spdp.processSpdpPayload(peer, payload);

    // T=110ms: would have expired under old lease but not the refreshed one.
    clock.set(110 * std.time.ns_per_ms);
    spdp.checkLeases();
    try testing.expectEqual(@as(u32, 0), tr.lost);

    // T=180ms: now expired.
    clock.set(180 * std.time.ns_per_ms);
    spdp.checkLeases();
    try testing.expectEqual(@as(u32, 1), tr.lost);
}
