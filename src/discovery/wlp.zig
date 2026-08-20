//! WLP — Writer Liveliness Protocol (RTPS 2.5 §8.4.13).
//!
//! Propagates AUTOMATIC and MANUAL_BY_PARTICIPANT liveliness assertions to
//! remote readers without requiring an application data write, via the
//! built-in ParticipantMessageWriter/Reader pair. MANUAL_BY_TOPIC is
//! explicitly excluded from WLP by the spec (§8.4.13.5) -- see
//! src/dcps/writer.zig's vtAssertLiveliness / src/rtps/writer_sm.zig's
//! sendLivelinessHeartbeat for that separate, writer-scoped on-demand
//! Heartbeat mechanism instead.
//!
//! Two orthogonal instances share one topic, distinguished by DDS key
//! (participantGuidPrefix, kind): one for AUTOMATIC, one for
//! MANUAL_BY_PARTICIPANT (§8.4.13.5). Sent periodically by tick() (driven by
//! participant.zig's checkTimers() via Discovery.Vtable.wlp_tick) rather than
//! per assert_liveliness() call, matching §8.7.2.2.3's literal algorithm:
//! AUTOMATIC is a pure periodic broadcast; MANUAL_BY_PARTICIPANT is a
//! periodic *check* ("did anything assert since the last check?") that only
//! sends when the check is positive.
//!
//! Builtin-endpoint matching/dispatch reuses BuiltinPair (builtin_endpoint.zig)
//! -- the same shared machinery SEDP's publications/subscriptions pairs use.
//! The wire codec here (plain-CDR ParticipantMessageData, not SEDP's
//! PL_CDR/PID parameter lists) is WLP-specific and not shared.

const std = @import("std");
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const iface = @import("interface.zig");
const tr_iface = @import("../transport/interface.zig");
const guid_mod = @import("../rtps/guid.zig");
const pid_mod = @import("../rtps/pid.zig");
const writer_sm_mod = @import("../rtps/writer_sm.zig");
const reader_sm_mod = @import("../rtps/reader_sm.zig");
const submessage_mod = @import("../rtps/message/submessage.zig");
const history_mod = @import("../rtps/history.zig");
const time_mod = @import("../util/time.zig");
const mutex_mod = @import("../util/mutex.zig");
const builtin_endpoint_mod = @import("builtin_endpoint.zig");

const Transport = tr_iface.Transport;
const Locator = tr_iface.Locator;
const Guid = guid_mod.Guid;
const GuidPrefix = guid_mod.GuidPrefix;
const EntityIds = guid_mod.EntityIds;
const StatefulWriter = writer_sm_mod.StatefulWriter;
const StatefulReader = reader_sm_mod.StatefulReader;
const RtpsTimestamp = time_mod.RtpsTimestamp;
const Callbacks = iface.Callbacks;
const ParticipantAnnouncement = iface.ParticipantAnnouncement;
const ParticipantData = iface.ParticipantData;
const WlpTickInfo = iface.WlpTickInfo;
const BuiltinEndpointSet = pid_mod.BuiltinEndpointSet;
const BuiltinPair = builtin_endpoint_mod.BuiltinPair;

/// DDS LivelinessQosPolicyKind enum ordinal order (dcps.idl) -- matches the
/// constants of the same name in src/dcps/reader.zig/writer.zig.
const LIVELINESS_AUTOMATIC: u8 = 0;
const LIVELINESS_MANUAL_BY_PARTICIPANT: u8 = 1;

/// RTPS §8.4.13.5 ParticipantMessageData kind octets.
const KIND_AUTOMATIC: [4]u8 = .{ 0, 0, 0, 0x01 };
const KIND_MANUAL: [4]u8 = .{ 0, 0, 0, 0x02 };

/// Plain CDR_LE encapsulation header (§10.2) -- ParticipantMessageData is a
/// plain CDR struct, not a PL_CDR parameter list (unlike SEDP's payloads).
const CDR_LE_ENCAP: [4]u8 = .{ 0x00, 0x01, 0x00, 0x00 };

fn encodeParticipantMessageData(alloc: std.mem.Allocator, prefix: GuidPrefix, kind: [4]u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, &CDR_LE_ENCAP);
    try buf.appendSlice(alloc, &prefix.bytes);
    try buf.appendSlice(alloc, &kind);
    // data: sequence<octet>, always empty here (4-byte LE length = 0).
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });
    return buf.toOwnedSlice(alloc);
}

const DecodedParticipantMessage = struct {
    prefix: GuidPrefix,
    kind: [4]u8,
};

fn decodeParticipantMessageData(payload: []const u8) ?DecodedParticipantMessage {
    // encap(4) + prefix(12) + kind(4) + seq_len(4) = 24 minimum.
    if (payload.len < 24) return null;
    var prefix: GuidPrefix = undefined;
    @memcpy(&prefix.bytes, payload[4..16]);
    const kind: [4]u8 = payload[16..20].*;
    return .{ .prefix = prefix, .kind = kind };
}

/// Instance key for StatefulWriter.write(): participantGuidPrefix ++ kind.
/// Per RTPS §8.4.13.5 the DDS key IS exactly this pair, so it's used
/// directly as both key_hash and instance_handle -- no hashing needed
/// (unlike SEDP's guidToKeyHash, which packs a full 16-byte Guid instead).
fn instanceKey(prefix: GuidPrefix, kind: [4]u8) [16]u8 {
    var kh: [16]u8 = undefined;
    @memcpy(kh[0..12], &prefix.bytes);
    @memcpy(kh[12..16], &kind);
    return kh;
}

/// AUTOMATIC send period: spec requires only "faster than the smallest
/// lease" -- no concrete divisor is mandated. 1/3 of the lease (floored at
/// the 100ms granularity of participant.zig's existing timer tick) matches
/// common DDS-vendor practice of asserting roughly 3x per lease window for
/// jitter margin.
fn automaticSendPeriodNs(min_lease_ns: i64) i64 {
    const MIN_PERIOD_NS: i64 = 100 * std.time.ns_per_ms;
    const period = @divTrunc(min_lease_ns, 3);
    return @max(period, MIN_PERIOD_NS);
}

pub const WlpEndpoints = struct {
    alloc: std.mem.Allocator,
    transport: Transport,
    pair: BuiltinPair = .{
        .writer_entity_id = EntityIds.p2p_builtin_participant_message_writer,
        .reader_entity_id = EntityIds.p2p_builtin_participant_message_reader,
        .remote_writer_bit = BuiltinEndpointSet.BUILTIN_ENDPOINT_PARTICIPANT_MESSAGE_DATA_WRITER,
        .remote_reader_bit = BuiltinEndpointSet.BUILTIN_ENDPOINT_PARTICIPANT_MESSAGE_DATA_READER,
        .reliable = true,
    },
    local_prefix: GuidPrefix = GuidPrefix.unknown,
    callbacks: ?*const Callbacks = null,
    tracer: trace.Tracer = trace.Tracer.noop(),

    // Periodic-tick timing state, owned entirely by this module -- tick()'s
    // caller (participant.zig) only ever supplies raw facts (WlpTickInfo).
    last_automatic_send_ns: i64 = 0,
    last_manual_check_ns: i64 = 0,

    unsupported_locator_mu: mutex_mod.Mutex = .{},
    unsupported_locator_kinds: std.AutoHashMapUnmanaged(i32, void) = .empty,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, transport: Transport) !*Self {
        const self = try alloc.create(Self);
        self.* = .{ .alloc = alloc, .transport = transport };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.pair.deinit();
        self.unsupported_locator_kinds.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.tracer = t;
    }

    pub fn start(self: *Self, local: *const ParticipantAnnouncement, callbacks: *const Callbacks) !void {
        self.callbacks = callbacks;
        self.local_prefix = local.guid.prefix;

        self.pair.writer = try StatefulWriter.init(
            self.alloc,
            Guid{ .prefix = local.guid.prefix, .entity_id = EntityIds.p2p_builtin_participant_message_writer },
            self.transport,
            .keep_last,
            1,
            EntityIds.p2p_builtin_participant_message_reader,
            writer_sm_mod.DEFAULT_FRAG_SIZE,
            true, // TRANSIENT_LOCAL (§8.4.13.3) -- replay to late joiners.
        );
        self.pair.writer.?.setTracer(self.tracer);

        self.pair.reader = try StatefulReader.init(
            self.alloc,
            Guid{ .prefix = local.guid.prefix, .entity_id = EntityIds.p2p_builtin_participant_message_reader },
            self.transport,
            .keep_last,
            1,
            // RELIABLE unconditionally -- a deliberate simplification of the
            // spec's optional BEST_EFFORT reader path (§8.4.13.3), which
            // would additionally require advertising
            // BEST_EFFORT_PARTICIPANT_MESSAGE_DATA_READER in
            // ParticipantProxy::builtinEndpointQos. Not implemented here.
            true,
        );
        self.pair.reader.?.setTracer(self.tracer);
        self.pair.reader.?.setCallback(.{ .ctx = self, .on_data = onPmData });

        // WLP does not open its own transport listener -- it shares SEDP's
        // metatraffic unicast listener (see tryHandleFromSedp / combined.zig's
        // setWlpDispatch wiring), since the transport does not support two
        // independent listeners bound to the same port.
    }

    pub fn stop(self: *Self) void {
        self.pair.stop();
    }

    /// Called by SpdpEndpoints (via combined.zig's DiscoveredFanout) when a
    /// remote participant is found.
    pub fn onParticipantDiscovered(ctx: *anyopaque, data: *const ParticipantData) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const uc = iface.filterReachableLocators(self.alloc, data.metatraffic_unicast_locators, self.transport, "wlp metatraffic unicast", self);
        defer self.alloc.free(uc);
        const mc = iface.filterReachableLocators(self.alloc, data.metatraffic_multicast_locators, self.transport, "wlp metatraffic multicast", self);
        defer self.alloc.free(mc);
        self.pair.matchRemote(self.alloc, data, uc, mc);
    }

    /// Wired into SEDP via setWlpDispatch (combined.zig) as its receive-side
    /// fallback once SEDP's own pub/sub routing fails to match a submessage.
    pub fn tryHandleFromSedp(ctx: *anyopaque, sm: submessage_mod.SubMessage, src_prefix: GuidPrefix) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.pair.tryHandle(sm, src_prefix);
    }

    pub fn warnUnsupportedLocatorOnce(self: *Self, loc: Locator, context: []const u8) void {
        const kind = loc.wireKind();
        self.unsupported_locator_mu.lock();
        defer self.unsupported_locator_mu.unlock();
        const gop = self.unsupported_locator_kinds.getOrPut(self.alloc, kind) catch return;
        if (!gop.found_existing) {
            log.wlp.warn("wlp: ignoring unsupported {s} locator kind={d}/0x{x}", .{
                context,
                kind,
                @as(u32, @bitCast(kind)),
            });
        }
    }

    fn onPmData(ctx: *anyopaque, change: *const history_mod.CacheChange) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const decoded = decodeParticipantMessageData(change.data) orelse return;
        const kind: u8 = if (std.mem.eql(u8, &decoded.kind, &KIND_AUTOMATIC))
            LIVELINESS_AUTOMATIC
        else if (std.mem.eql(u8, &decoded.kind, &KIND_MANUAL))
            LIVELINESS_MANUAL_BY_PARTICIPANT
        else
            return;
        if (self.callbacks) |cbs| cbs.on_wlp_alive(cbs.ctx, decoded.prefix, kind);
    }

    /// Periodic driver (RTPS §8.7.2.2.3), called from participant.zig's
    /// checkTimers() via Discovery.Vtable.wlp_tick.
    pub fn tick(self: *Self, now_ns: i64, info: WlpTickInfo) void {
        if (self.pair.writer == null) return;
        // AUTOMATIC: purely periodic, rate faster than the smallest lease --
        // no relation to assert_liveliness() (a no-op for AUTOMATIC writers
        // per the DDS spec).
        if (info.has_automatic) {
            const period = automaticSendPeriodNs(info.min_automatic_lease_ns);
            if (now_ns - self.last_automatic_send_ns >= period) {
                self.send(KIND_AUTOMATIC);
                self.last_automatic_send_ns = now_ns;
            }
        }
        // MANUAL_BY_PARTICIPANT: periodic *check*, not periodic send -- only
        // send when something was actually asserted since the last check, at
        // a period equal to the smallest lease among such writers (§8.7.2.2.3
        // literal algorithm).
        if (info.has_manual_by_participant) {
            if (now_ns - self.last_manual_check_ns >= info.min_manual_lease_ns) {
                if (info.manual_asserted_since_ns > self.last_manual_check_ns) {
                    self.send(KIND_MANUAL);
                }
                self.last_manual_check_ns = now_ns;
            }
        }
    }

    fn send(self: *Self, kind: [4]u8) void {
        const payload = encodeParticipantMessageData(self.alloc, self.local_prefix, kind) catch return;
        defer self.alloc.free(payload);
        const kh = instanceKey(self.local_prefix, kind);
        _ = self.pair.writer.?.write(.alive, RtpsTimestamp.now(), kh, kh, payload) catch {};
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "encodeParticipantMessageData / decodeParticipantMessageData round-trip" {
    const alloc = testing.allocator;
    const prefix = GuidPrefix{ .bytes = [_]u8{0xAB} ** 12 };

    const encoded = try encodeParticipantMessageData(alloc, prefix, KIND_MANUAL);
    defer alloc.free(encoded);

    const decoded = decodeParticipantMessageData(encoded) orelse return error.TestUnexpectedResult;
    try testing.expect(decoded.prefix.eql(prefix));
    try testing.expectEqualSlices(u8, &KIND_MANUAL, &decoded.kind);
}

test "decodeParticipantMessageData rejects a too-short payload" {
    try testing.expect(decodeParticipantMessageData(&.{ 0, 0, 0, 0 }) == null);
}

test "automaticSendPeriodNs floors at the 100ms timer-tick granularity" {
    // A pathologically short 10ms lease must not spam the wire faster than
    // participant.zig's own checkTimers() tick can even observe.
    try testing.expectEqual(@as(i64, 100 * std.time.ns_per_ms), automaticSendPeriodNs(10 * std.time.ns_per_ms));
    // A generous lease uses the 1/3 formula.
    try testing.expectEqual(@as(i64, 1 * std.time.ns_per_s), automaticSendPeriodNs(3 * std.time.ns_per_s));
}

test "instanceKey packs prefix and kind directly with no hashing" {
    const prefix = GuidPrefix{ .bytes = [_]u8{0x11} ** 12 };
    const kh = instanceKey(prefix, KIND_AUTOMATIC);
    try testing.expectEqualSlices(u8, &prefix.bytes, kh[0..12]);
    try testing.expectEqualSlices(u8, &KIND_AUTOMATIC, kh[12..16]);
}
