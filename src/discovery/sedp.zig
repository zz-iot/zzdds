//! SEDP — Simple Endpoint Discovery Protocol (RTPS 2.5 §8.5.4).
//!
//! SedpEndpoints manages four StatefulWriter/StatefulReader pairs:
//!   publications writer / subscriptions reader → announcer side
//!   publications reader / subscriptions writer → detector side
//!
//! When SPDP discovers a new remote participant, SedpEndpoints.onParticipantDiscovered
//! is called.  It wires up proxies based on the remote's BuiltinEndpointSet and sends
//! our own endpoint announcements.
//!
//! When the SEDP readers receive DiscoveredWriterData or DiscoveredReaderData, QoS
//! matching is performed via dcps/qos_match.zig, and the appropriate discovery callback
//! fires (on_writer_discovered / on_reader_discovered).
//!
//! PL-CDR encode/decode goes through the zidl-generated codec in
//! `idl/rtps_discovery.idl` (imported as `Disc`); QoS is mapped to/from the
//! wire structs by `qos_adapter.zig`.

const std = @import("std");
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const iface = @import("interface.zig");
const adapter = @import("qos_adapter.zig");
const tr_iface = @import("../transport/interface.zig");
const guid_mod = @import("../rtps/guid.zig");
const pid_mod = @import("../rtps/pid.zig");
const qm_mod = @import("../dcps/qos_match.zig");
const zidl_rt = @import("zidl_rt");
const Disc = @import("zzdds_disc_generated");
const writer_sm_mod = @import("../rtps/writer_sm.zig");
const reader_sm_mod = @import("../rtps/reader_sm.zig");
const builtin_endpoint_mod = @import("builtin_endpoint.zig");
const msg_mod = @import("../rtps/message/root.zig");
const parser_mod = @import("../rtps/message/parser.zig");
const history_mod = @import("../rtps/history.zig");
const mutex_mod = @import("../util/mutex.zig");
const time_mod = @import("../util/time.zig");
const build_opts = @import("build_options");
const header_mod = @import("../rtps/message/header.zig");

const Transport = tr_iface.Transport;
const Locator = tr_iface.Locator;
const LocatorKind = tr_iface.LocatorKind;
const LocatorWire = tr_iface.LocatorWire;
const ReceiveHandler = tr_iface.ReceiveHandler;
const Guid = guid_mod.Guid;
const GuidPrefix = guid_mod.GuidPrefix;
const EntityIds = guid_mod.EntityIds;
const StatefulWriter = writer_sm_mod.StatefulWriter;
const StatefulReader = reader_sm_mod.StatefulReader;
const CacheChange = history_mod.CacheChange;
const ChangeKind = history_mod.ChangeKind;
const RtpsTimestamp = time_mod.RtpsTimestamp;
const Mutex = mutex_mod.Mutex;
const Callbacks = iface.Callbacks;
const ParticipantAnnouncement = iface.ParticipantAnnouncement;
const ParticipantData = iface.ParticipantData;
const WriterAnnouncement = iface.WriterAnnouncement;
const ReaderAnnouncement = iface.ReaderAnnouncement;
const WriterData = iface.WriterData;
const ReaderData = iface.ReaderData;
const PidTable = pid_mod.PidTable;
const BuiltinEndpointSet = pid_mod.BuiltinEndpointSet;
const BuiltinPair = builtin_endpoint_mod.BuiltinPair;

const PLCDR_LE_ENCAP: [4]u8 = .{ 0x00, 0x03, 0x00, 0x00 };

// ── PL-CDR I/O helpers (decode side; encode goes through the generated codec) ─

fn readU16LE(b: []const u8, le: bool) u16 {
    return std.mem.readInt(u16, b[0..2], if (le) .little else .big);
}
fn readU32LE(b: []const u8, le: bool) u32 {
    return std.mem.readInt(u32, b[0..4], if (le) .little else .big);
}

/// Build the 16-byte on-wire GUID (prefix[12] + entityId[4]) from a `Guid`.
fn guidBytes(g: Guid) [16]u8 {
    var b: [16]u8 = undefined;
    @memcpy(b[0..12], &g.prefix.bytes);
    b[12] = g.entity_id.entity_key[0];
    b[13] = g.entity_id.entity_key[1];
    b[14] = g.entity_id.entity_key[2];
    b[15] = g.entity_id.entity_kind;
    return b;
}

/// Parse a 16-byte on-wire GUID back into a `Guid`.
fn guidFromBytes(b: []const u8) Guid {
    return .{
        .prefix = .{ .bytes = b[0..12].* },
        .entity_id = .{ .entity_key = b[12..15].*, .entity_kind = b[15] },
    };
}

/// Serialize a `Disc.*` PL_CDR struct to a heap slice (encap header + params +
/// sentinel), owned by the caller.
fn emitPlCdr(comptime T: type, alloc: std.mem.Allocator, value: T) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var w = zidl_rt.PlCdrWriter.init(&buf, alloc);
    try w.writeEncapHeader();
    try T.serializePlCdr(&w, value);
    return buf.toOwnedSlice(alloc);
}

// ── DiscoveredWriterData encoding ─────────────────────────────────────────────

pub fn encodeWriterData(alloc: std.mem.Allocator, ann: *const WriterAnnouncement) ![]u8 {
    var out = adapter.writerDiscoveredData(ann.qos, ann.presentation);
    out.writerGuid = guidBytes(ann.guid);
    if (ann.group_guid) |gg| out.groupGuid = guidBytes(gg);
    out.topicName = ann.topic_name;
    out.typeName = ann.type_name;

    // PID_PARTITION: NUL-terminate the names for the generated seq<string>.
    var part_ptrs: std.ArrayList([*:0]const u8) = .empty;
    defer {
        for (part_ptrs.items) |p| alloc.free(std.mem.span(p));
        part_ptrs.deinit(alloc);
    }
    if (ann.partition_names.len > 0) {
        for (ann.partition_names) |name| {
            const z = try alloc.dupeZ(u8, name);
            part_ptrs.append(alloc, z.ptr) catch |e| {
                alloc.free(z);
                return e;
            };
        }
        out.partition = .{
            ._maximum = @intCast(part_ptrs.items.len),
            ._length = @intCast(part_ptrs.items.len),
            ._buffer = part_ptrs.items.ptr,
            ._release = false,
        };
    }

    // PID_TYPE_INFORMATION: opaque XTypes blob, injected via unknown_params
    // (no declared member — see idl/rtps_discovery.idl). Only when XTypes is
    // built in AND a blob is available (advertising it without a TypeLookup
    // service stalls OpenDDS endpoint matching).
    var uparams: [1]zidl_rt.RawParam = undefined;
    var un: usize = 0;
    if (build_opts.xtypes and ann.type_info_cdr.len > 0) {
        uparams[0] = .{ .pid = 0x0075, .bytes = @constCast(ann.type_info_cdr) };
        un = 1;
    }
    out.unknown_params = uparams[0..un];

    return emitPlCdr(Disc.DiscoveredWriterData, alloc, out);
}

// ── DiscoveredReaderData encoding ─────────────────────────────────────────────

pub fn encodeReaderData(alloc: std.mem.Allocator, ann: *const ReaderAnnouncement) ![]u8 {
    var out = adapter.readerDiscoveredData(ann.qos, ann.presentation);
    out.readerGuid = guidBytes(ann.guid);
    out.topicName = ann.topic_name;
    out.typeName = ann.type_name;
    // Readers have historically never advertised PID_DESTINATION_ORDER; the
    // adapter fills it for local QoS matching only. Keep it off the wire.
    out.destinationOrder = null;

    var part_ptrs: std.ArrayList([*:0]const u8) = .empty;
    defer {
        for (part_ptrs.items) |p| alloc.free(std.mem.span(p));
        part_ptrs.deinit(alloc);
    }
    if (ann.partition_names.len > 0) {
        for (ann.partition_names) |name| {
            const z = try alloc.dupeZ(u8, name);
            part_ptrs.append(alloc, z.ptr) catch |e| {
                alloc.free(z);
                return e;
            };
        }
        out.partition = .{
            ._maximum = @intCast(part_ptrs.items.len),
            ._length = @intCast(part_ptrs.items.len),
            ._buffer = part_ptrs.items.ptr,
            ._release = false,
        };
    }

    // Readers deliberately never emit PID_TYPE_INFORMATION (OpenDDS TypeLookup
    // round-trip stall — see the git history of this comment).
    return emitPlCdr(Disc.DiscoveredReaderData, alloc, out);
}

// ── Decode ──────────────────────────────────────────────────────────────────

/// Decoded remote endpoint: owns the generated wire struct — whose
/// `unknown_params` retains every unrecognised PID verbatim — plus the
/// transport-typed per-endpoint locator slices converted from its
/// `unicastLocatorList` / `multicastLocatorList` members (rare; zzdds never
/// emits per-endpoint locators, but a remote peer may).
fn DecodedEndpoint(comptime T: type) type {
    return struct {
        const Self2 = @This();
        data: T, // owned via T.deinit
        unicast: []Locator, // owned
        multicast: []Locator, // owned
        alloc: std.mem.Allocator,

        fn deinit(self: *Self2) void {
            self.data.deinit(self.alloc);
            self.alloc.free(self.unicast);
            self.alloc.free(self.multicast);
        }
    };
}

/// Convert a decoded `@pl_repeated sequence<Locator_t>` member to owned
/// transport `Locator`s.
fn wireLocatorsOwned(alloc: std.mem.Allocator, opt_seq: anytype) ![]Locator {
    const s = opt_seq orelse return alloc.alloc(Locator, 0);
    const b = s._buffer orelse return alloc.alloc(Locator, 0);
    const n: usize = s._length;
    const out = try alloc.alloc(Locator, n);
    errdefer alloc.free(out);
    for (0..n) |i| {
        const lw = LocatorWire{ .kind = b[i].kind, .port = b[i].port_number, .address = b[i].address };
        out[i] = lw.toLocator();
    }
    return out;
}

fn decodeEndpointT(comptime T: type, alloc: std.mem.Allocator, payload: []const u8) !DecodedEndpoint(T) {
    if (payload.len < 4) return error.TooShort;
    var r = try zidl_rt.CdrReader.init(payload);
    var data: T = .{};
    errdefer data.deinit(alloc);
    // `.lenient`: skip/retain unknowns, tolerate a truncated tail, round a
    // misaligned length — matches the old hand parser's leniency. The native
    // path never uses `.strict` (reserved for a broker's ingress validation).
    try T.deserializeFromPlCdr(&data, &r, alloc, .lenient);
    const uc = try wireLocatorsOwned(alloc, data.unicastLocatorList);
    errdefer alloc.free(uc);
    const mc = try wireLocatorsOwned(alloc, data.multicastLocatorList);
    return .{ .data = data, .unicast = uc, .multicast = mc, .alloc = alloc };
}

/// PID_PARTITION_LEGACY (0x0035): the generated switch keys on `@id` 0x0029, so
/// a peer that sends partition as the legacy PID lands it in `unknown_params`.
/// Parse it as a CDR `sequence<string>` (LE — every zzdds/DDS peer emits
/// PL_CDR_LE) into `buf`, returning borrowed slices into the RawParam bytes
/// (valid while the decoded struct lives). Returns `null` when absent.
fn legacyPartitionNames(unknown: []const zidl_rt.RawParam, buf: [][]const u8) ?[]const []const u8 {
    for (unknown) |rp| {
        if (rp.pid != PidTable.PARTITION_LEGACY) continue;
        const v = rp.bytes;
        if (v.len < 4) return &.{};
        const count = readU32LE(v, true);
        var off: usize = 4;
        var i: usize = 0;
        while (i < count and i < buf.len and off + 4 <= v.len) : (i += 1) {
            const slen = readU32LE(v[off..], true);
            off += 4;
            if (slen == 0 or off + slen > v.len) break;
            buf[i] = v[off .. off + slen - 1]; // strip NUL
            off = (off + slen + 3) & ~@as(usize, 3);
        }
        return buf[0..i];
    }
    return null;
}

/// The PID_TYPE_INFORMATION (0x0075) blob out of `unknown_params`, borrowed.
fn typeInfoBlob(unknown: []const zidl_rt.RawParam) []const u8 {
    for (unknown) |rp| {
        if (rp.pid == 0x0075) return rp.bytes;
    }
    return &.{};
}

// ── SedpEndpoints ─────────────────────────────────────────────────────────────

/// Cached default locators for a known remote participant.
/// Used as a fallback when SEDP endpoint data omits explicit locators.
const ParticipantLocators = struct {
    unicast: []Locator, // owned
    multicast: []Locator, // owned
    /// Same locators, filtered for reachability by the local participant's
    /// data transport instead of discovery. Equal in practice to unicast/
    /// multicast above when no data_reachable override is configured (the
    /// common case) — see onParticipantDiscovered.
    unicast_for_data: []Locator, // owned
    multicast_for_data: []Locator, // owned
    alloc: std.mem.Allocator,

    fn deinit(self: *ParticipantLocators) void {
        self.alloc.free(self.unicast);
        self.alloc.free(self.multicast);
        self.alloc.free(self.unicast_for_data);
        self.alloc.free(self.multicast_for_data);
    }
};

/// SEDP built-in endpoints + endpoint announcement/detection.
pub const SedpEndpoints = struct {
    alloc: std.mem.Allocator,
    transport: Transport,

    // Four built-in state machines.
    // pub_writer  → publishes local DataWriter announcements
    // pub_reader  → receives remote DataWriter announcements
    // sub_writer  → publishes local DataReader announcements
    // sub_reader  → receives remote DataReader announcements
    pub_writer: ?*StatefulWriter,
    pub_reader: ?*StatefulReader,
    sub_writer: ?*StatefulWriter,
    sub_reader: ?*StatefulReader,

    mu: Mutex,
    participant_locs_mu: Mutex,
    callbacks: ?*const Callbacks,
    tracer: trace.Tracer,

    // Metatraffic unicast port (where we listen for SEDP data).
    meta_unicast_port: u16,
    local_prefix: GuidPrefix,

    // Optional relay for SPDP packets that arrive on the metatraffic unicast port.
    spdp_relay_ctx: ?*anyopaque,
    spdp_relay_fn: ?*const fn (*anyopaque, GuidPrefix, history_mod.SequenceNumber, []const u8, header_mod.VendorId) void,
    // Optional handler for SPDP BYE (participant dispose/unregister).
    spdp_bye_ctx: ?*anyopaque,
    spdp_bye_fn: ?*const fn (*anyopaque, GuidPrefix) void,
    // Optional callback fired by SEDP reliable writers when a liveness probe resolves.
    // Forwarded to pub_writer and sub_writer during start().
    probe_result_ctx: ?*anyopaque,
    probe_result_fn: ?*const fn (*anyopaque, GuidPrefix, bool) void,
    // Optional callback fired when real SEDP endpoint traffic (a DiscoveredWriterData
    // or DiscoveredReaderData) is received from a peer. Forwarded to SPDP so it can
    // stop retransmitting on that peer's behalf. See spdp.zig's SEDP-traffic-seen heuristic.
    sedp_seen_ctx: ?*anyopaque,
    sedp_seen_fn: ?*const fn (*anyopaque, GuidPrefix) void,
    // Optional WLP dispatch fallback: WLP shares SEDP's metatraffic unicast
    // listener rather than opening a second one on the same port (which the
    // transport does not support) -- see combined.zig's wiring. Tried after
    // SEDP's own pub/sub routing fails to match a submessage.
    wlp_ctx: ?*anyopaque,
    wlp_try_handle_fn: ?*const fn (*anyopaque, msg_mod.SubMessage, GuidPrefix) bool,

    // Cached default locators per participant (RTPS: endpoints inherit these
    // when DiscoveredWriter/ReaderData omits explicit locator PIDs).
    participant_locs: std.AutoHashMap(GuidPrefix, ParticipantLocators),
    unsupported_locator_mu: Mutex,
    unsupported_locator_kinds: std.AutoHashMap(i32, void),

    // Set in start() from ParticipantAnnouncement.data_reachable. Null (the
    // default) means the local participant's data transport is the same as
    // this discovery transport.
    data_reachable: ?iface.DataLocatorReachability,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, transport: Transport) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .transport = transport,
            .pub_writer = null,
            .pub_reader = null,
            .sub_writer = null,
            .sub_reader = null,
            .mu = .{},
            .participant_locs_mu = .{},
            .callbacks = null,
            .tracer = trace.Tracer.noop(),
            .meta_unicast_port = 0,
            .local_prefix = GuidPrefix.unknown,
            .participant_locs = std.AutoHashMap(GuidPrefix, ParticipantLocators).init(alloc),
            .unsupported_locator_mu = .{},
            .unsupported_locator_kinds = std.AutoHashMap(i32, void).init(alloc),
            .spdp_relay_ctx = null,
            .spdp_relay_fn = null,
            .spdp_bye_ctx = null,
            .spdp_bye_fn = null,
            .probe_result_ctx = null,
            .probe_result_fn = null,
            .sedp_seen_ctx = null,
            .sedp_seen_fn = null,
            .wlp_ctx = null,
            .wlp_try_handle_fn = null,
            .data_reachable = null,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.pub_writer) |w| w.deinit();
        if (self.pub_reader) |r| r.deinit();
        if (self.sub_writer) |w| w.deinit();
        if (self.sub_reader) |r| r.deinit();
        self.participant_locs_mu.lock();
        var it = self.participant_locs.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        self.participant_locs.deinit();
        self.participant_locs_mu.unlock();
        self.unsupported_locator_mu.lock();
        self.unsupported_locator_kinds.deinit();
        self.unsupported_locator_mu.unlock();
        self.alloc.destroy(self);
    }

    /// Override the wire tracer used by all SEDP state machines.
    /// Wire an SPDP relay so that SPDP DATA packets arriving on the metatraffic
    /// unicast port are forwarded to the SPDP handler.  Must be called before `start()`.
    pub fn setSpdpRelay(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, GuidPrefix, history_mod.SequenceNumber, []const u8, header_mod.VendorId) void,
    ) void {
        self.spdp_relay_ctx = ctx;
        self.spdp_relay_fn = fn_ptr;
    }

    /// WLP shares this module's metatraffic unicast listener instead of
    /// opening a second one on the same port. Must be called before start().
    pub fn setWlpDispatch(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, msg_mod.SubMessage, GuidPrefix) bool,
    ) void {
        self.wlp_ctx = ctx;
        self.wlp_try_handle_fn = fn_ptr;
    }

    pub fn setSpdpByeFn(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, GuidPrefix) void,
    ) void {
        self.spdp_bye_ctx = ctx;
        self.spdp_bye_fn = fn_ptr;
    }

    /// Register a callback to receive liveness-probe results from the SEDP reliable
    /// writers.  If the writers are already created (post-start), applies immediately.
    pub fn setProbeResultFn(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, GuidPrefix, bool) void,
    ) void {
        self.probe_result_ctx = ctx;
        self.probe_result_fn = fn_ptr;
        if (self.pub_writer) |pw| pw.setProbeResult(ctx, fn_ptr);
        if (self.sub_writer) |sw| sw.setProbeResult(ctx, fn_ptr);
    }

    /// Register a callback fired when real SEDP endpoint traffic (a
    /// DiscoveredWriterData or DiscoveredReaderData) arrives from a peer.
    pub fn setSedpSeenFn(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, GuidPrefix) void,
    ) void {
        self.sedp_seen_ctx = ctx;
        self.sedp_seen_fn = fn_ptr;
    }

    /// Initiate a liveness probe for the participant identified by `prefix`.
    /// Sets `probe_deadline_ns` on matching reader proxies in pub_writer and
    /// sub_writer; the periodic heartbeat thread handles the actual probe HBs.
    /// Called by SPDP when announcement silence exceeds the trigger threshold.
    pub fn beginProbe(ctx: *anyopaque, prefix: GuidPrefix, deadline_ns: i64) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.pub_writer) |pw| pw.beginProbe(prefix, deadline_ns);
        if (self.sub_writer) |sw| sw.beginProbe(prefix, deadline_ns);
    }

    /// Must be called before `start()` to take effect.
    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.tracer = t;
    }

    pub fn start(
        self: *Self,
        local: *const ParticipantAnnouncement,
        callbacks: *const Callbacks,
    ) !void {
        self.callbacks = callbacks;
        self.local_prefix = local.guid.prefix;
        self.data_reachable = local.data_reachable;

        // Metatraffic unicast port = first unicast locator port.
        if (local.metatraffic_unicast_locators.len > 0) {
            self.meta_unicast_port = switch (local.metatraffic_unicast_locators[0]) {
                .udp_v4 => |u| u.port,
                .udp_v6 => |u| u.port,
                else => 7410,
            };
        }

        // Publications writer/reader
        self.pub_writer = try StatefulWriter.init(
            self.alloc,
            Guid{ .prefix = local.guid.prefix, .entity_id = EntityIds.sedp_builtin_publications_writer },
            self.transport,
            .keep_last,
            1,
            EntityIds.sedp_builtin_publications_reader,
            writer_sm_mod.DEFAULT_FRAG_SIZE,
            true, // SEDP always replays to late-joining participants
        );
        self.pub_writer.?.setTracer(self.tracer);
        if (self.probe_result_fn) |f| self.pub_writer.?.setProbeResult(self.probe_result_ctx.?, f);
        self.pub_reader = try StatefulReader.init(
            self.alloc,
            Guid{ .prefix = local.guid.prefix, .entity_id = EntityIds.sedp_builtin_publications_reader },
            self.transport,
            .keep_last,
            1,
            true, // SEDP builtin readers are RELIABLE (RTPS §8.5)
        );
        self.pub_reader.?.setTracer(self.tracer);
        self.pub_reader.?.setCallback(.{ .ctx = self, .on_data = onPubData });

        // Subscriptions writer/reader
        self.sub_writer = try StatefulWriter.init(
            self.alloc,
            Guid{ .prefix = local.guid.prefix, .entity_id = EntityIds.sedp_builtin_subscriptions_writer },
            self.transport,
            .keep_last,
            1,
            EntityIds.sedp_builtin_subscriptions_reader,
            writer_sm_mod.DEFAULT_FRAG_SIZE,
            true, // SEDP always replays to late-joining participants
        );
        self.sub_writer.?.setTracer(self.tracer);
        if (self.probe_result_fn) |f| self.sub_writer.?.setProbeResult(self.probe_result_ctx.?, f);
        self.sub_reader = try StatefulReader.init(
            self.alloc,
            Guid{ .prefix = local.guid.prefix, .entity_id = EntityIds.sedp_builtin_subscriptions_reader },
            self.transport,
            .keep_last,
            1,
            true, // SEDP builtin readers are RELIABLE (RTPS §8.5)
        );
        self.sub_reader.?.setTracer(self.tracer);
        self.sub_reader.?.setCallback(.{ .ctx = self, .on_data = onSubData });

        // Listen on the metatraffic unicast port for SEDP traffic.
        if (self.meta_unicast_port != 0) {
            const loc = Locator.udp4(.{ 0, 0, 0, 0 }, self.meta_unicast_port);
            self.transport.listen(&loc, ReceiveHandler{
                .ctx = self,
                .on_receive = onReceive,
            }) catch |err| log.sedp.warn("sedp: listen error: {}", .{err});
        }
    }

    pub fn stop(self: *Self) void {
        // Stop and join both writers' heartbeat threads before unlistening —
        // they hold probe_result_ctx/probe_result_fn pointing back at
        // whatever registered them (typically a DomainParticipantImpl), and
        // that object's own teardown sequence (e.g. a factory.deinit() that
        // runs before this discovery object's own deinit()) may free it
        // shortly after this call returns. Without this, the heartbeat
        // thread can fire onProbeResult -> onParticipantLost on freed memory.
        if (self.pub_writer) |w| w.stopHeartbeat();
        if (self.sub_writer) |w| w.stopHeartbeat();
        if (self.meta_unicast_port != 0) {
            const loc = Locator.udp4(.{ 0, 0, 0, 0 }, self.meta_unicast_port);
            self.transport.unlisten(&loc, ReceiveHandler{
                .ctx = self,
                .on_receive = onReceive,
            });
        }
    }

    // ── BuiltinPair views over the pub/sub state machines ──────────────────────
    // Ephemeral wrappers (borrow the existing pointer fields, own no state of
    // their own) used to share matching/dispatch logic with other builtin
    // endpoint pairs (see builtin_endpoint.zig) without disturbing any other
    // call site in this file — pub_writer/pub_reader/sub_writer/sub_reader
    // remain the single source of truth.

    fn pubPair(self: *Self) BuiltinPair {
        return .{
            .writer = self.pub_writer,
            .reader = self.pub_reader,
            .writer_entity_id = EntityIds.sedp_builtin_publications_writer,
            .reader_entity_id = EntityIds.sedp_builtin_publications_reader,
            .remote_writer_bit = BuiltinEndpointSet.DISC_BUILTIN_ENDPOINT_PUBLICATIONS_ANNOUNCER,
            .remote_reader_bit = BuiltinEndpointSet.DISC_BUILTIN_ENDPOINT_PUBLICATIONS_DETECTOR,
            .reliable = true,
        };
    }

    fn subPair(self: *Self) BuiltinPair {
        return .{
            .writer = self.sub_writer,
            .reader = self.sub_reader,
            .writer_entity_id = EntityIds.sedp_builtin_subscriptions_writer,
            .reader_entity_id = EntityIds.sedp_builtin_subscriptions_reader,
            .remote_writer_bit = BuiltinEndpointSet.DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_ANNOUNCER,
            .remote_reader_bit = BuiltinEndpointSet.DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_DETECTOR,
            .reliable = true,
        };
    }

    // ── Called by SpdpEndpoints when a remote participant is found ────────────

    /// Wire the remote participant's SEDP built-in endpoints into our proxies.
    pub fn onParticipantDiscovered(
        ctx: *anyopaque,
        data: *const ParticipantData,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const uc = self.filterReachableLocators(data.metatraffic_unicast_locators, "metatraffic unicast");
        defer self.alloc.free(uc);
        const mc = self.filterReachableLocators(data.metatraffic_multicast_locators, "metatraffic multicast");
        defer self.alloc.free(mc);
        const data_uc = self.filterReachableLocators(data.default_unicast_locators, "default unicast");
        const data_mc = self.filterReachableLocators(data.default_multicast_locators, "default multicast");
        // SPDP already computed the data-transport-filtered variants (from the
        // raw, pre-discovery-filter locators — see filterKnownParticipantLocators);
        // just dupe them here rather than re-filtering.
        const data_uc_for_data: []Locator = self.alloc.dupe(Locator, data.default_unicast_locators_for_data) catch &.{};
        const data_mc_for_data: []Locator = self.alloc.dupe(Locator, data.default_multicast_locators_for_data) catch &.{};

        // Cache the participant's default data locators so endpoints that omit
        // explicit locators in their SEDP announcement can fall back to them.
        // Lock is released before calling addMatchedWriter/addMatchedReader to
        // avoid a lock-order inversion with sub_reader.mu.
        {
            self.participant_locs_mu.lock();
            const gop = self.participant_locs.getOrPut(data.guid.prefix) catch {
                self.participant_locs_mu.unlock();
                self.alloc.free(data_uc);
                self.alloc.free(data_mc);
                self.alloc.free(data_uc_for_data);
                self.alloc.free(data_mc_for_data);
                return;
            };
            if (gop.found_existing) gop.value_ptr.deinit();
            gop.value_ptr.* = .{
                .alloc = self.alloc,
                .unicast = data_uc,
                .multicast = data_mc,
                .unicast_for_data = data_uc_for_data,
                .multicast_for_data = data_mc_for_data,
            };
            self.participant_locs_mu.unlock();
        }

        // Match the remote's advertised BuiltinEndpointSet bits against our
        // pub/sub pairs — see BuiltinPair.matchRemote for the shared logic
        // (4 near-identical if-blocks previously hand-written here).
        var pub_pair = self.pubPair();
        pub_pair.matchRemote(self.alloc, data, uc, mc);
        var sub_pair = self.subPair();
        sub_pair.matchRemote(self.alloc, data, uc, mc);
    }

    // ── Local endpoint announcement ───────────────────────────────────────────

    pub fn announceWriter(self: *Self, ann: *const WriterAnnouncement) !void {
        const payload = try encodeWriterData(self.alloc, ann);
        defer self.alloc.free(payload);
        // Each endpoint is a separate SEDP instance keyed by GUID so KEEP_LAST 1
        // retains all endpoints rather than overwriting with the most recent.
        const kh = guidToKeyHash(ann.guid);
        if (self.pub_writer) |pw| {
            _ = try pw.write(.alive, RtpsTimestamp.now(), kh, kh, payload);
        }
    }

    pub fn retractWriter(self: *Self, guid: Guid) void {
        const kh = guidToKeyHash(guid);
        const payload = encodeEndpointDisposalPayload(self.alloc, guid) catch return;
        defer self.alloc.free(payload);
        if (self.pub_writer) |pw| {
            _ = pw.write(.not_alive_disposed, RtpsTimestamp.now(), kh, kh, payload) catch {};
        }
    }

    pub fn announceReader(self: *Self, ann: *const ReaderAnnouncement) !void {
        const payload = try encodeReaderData(self.alloc, ann);
        defer self.alloc.free(payload);
        const kh = guidToKeyHash(ann.guid);
        if (self.sub_writer) |sw| {
            _ = try sw.write(.alive, RtpsTimestamp.now(), kh, kh, payload);
        }
    }

    pub fn retractReader(self: *Self, guid: Guid) void {
        const kh = guidToKeyHash(guid);
        const payload = encodeEndpointDisposalPayload(self.alloc, guid) catch return;
        defer self.alloc.free(payload);
        if (self.sub_writer) |sw| {
            _ = sw.write(.not_alive_disposed, RtpsTimestamp.now(), kh, kh, payload) catch {};
        }
    }

    // ── Transport receive callback ────────────────────────────────────────────

    fn onReceive(ctx: *anyopaque, data: []const u8, from: Locator) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = from;
        var pub_pair = self.pubPair();
        var sub_pair = self.subPair();
        var it = parser_mod.MessageIterator.init(data) catch return;
        var param_buf: [32]@import("../rtps/message/submessage.zig").InlineQosParam = undefined;

        while (it.next(&param_buf) catch return) |sm| {
            const src_prefix = it.header.guid_prefix;
            switch (sm) {
                .data => |d| {
                    const wid = d.writer_entity_id;

                    // Detect NOT_ALIVE_DISPOSED / NOT_ALIVE_UNREGISTERED via
                    // PID_STATUS_INFO inline QoS (RTPS §9.6.3.6).
                    if (d.inline_qos) |iqos| {
                        if (iqos.get(.status_info)) |si_bytes| {
                            if (si_bytes.len >= 4) {
                                // StatusInfo_t is {unused,unused,unused,status} (RTPS §9.4.5.11):
                                // an octet array, always big-endian regardless of message endianness.
                                const si = std.mem.readInt(u32, si_bytes[0..4], .big);
                                if (si & 0x00000003 != 0) { // DISPOSED or UNREGISTERED
                                    if (wid.eql(EntityIds.spdp_builtin_participant_writer)) {
                                        // SPDP BYE arriving on the metatraffic unicast port.
                                        if (self.spdp_bye_fn) |f| f(self.spdp_bye_ctx.?, src_prefix);
                                    } else {
                                        // Extract endpoint GUID: prefer PID_KEY_HASH in inline_qos
                                        // (RTPS §9.6.3.6 MAY), fall back to PID_ENDPOINT_GUID in payload.
                                        const ep_guid: ?Guid = if (iqos.get(.key_hash)) |kh_bytes|
                                            if (kh_bytes.len >= 16) keyHashToGuid(kh_bytes[0..16].*) else null
                                        else
                                            guidFromDisposalPayload(d.serialized_payload);
                                        // The reliable builtin reader must also consume the
                                        // disposal's sequence number.  Skipping its state machine
                                        // leaves an artificial gap and blocks later announcements,
                                        // even when the optional endpoint key could not be decoded.
                                        if (wid.eql(EntityIds.sedp_builtin_publications_writer)) {
                                            _ = pub_pair.tryHandle(sm, src_prefix);
                                        } else if (wid.eql(EntityIds.sedp_builtin_subscriptions_writer)) {
                                            _ = sub_pair.tryHandle(sm, src_prefix);
                                        }
                                        // Consuming a previously missing sequence can synchronously
                                        // deliver buffered ALIVE changes.  Apply the loss notification
                                        // afterwards so one of those older changes cannot resurrect
                                        // the endpoint that this disposal removes.
                                        if (ep_guid) |g| {
                                            if (wid.eql(EntityIds.sedp_builtin_publications_writer)) {
                                                if (self.callbacks) |cbs|
                                                    cbs.on_writer_lost(cbs.ctx, g);
                                            } else if (wid.eql(EntityIds.sedp_builtin_subscriptions_writer)) {
                                                if (self.callbacks) |cbs|
                                                    cbs.on_reader_lost(cbs.ctx, g);
                                            }
                                        }
                                    }
                                    continue; // disposal handled; skip alive processing
                                }
                            }
                        }
                    }

                    const payload = d.serialized_payload;
                    if (payload.len == 0) continue;

                    if (wid.eql(EntityIds.spdp_builtin_participant_writer)) {
                        if (self.spdp_relay_fn) |relay|
                            relay(self.spdp_relay_ctx.?, src_prefix, d.writer_sn, payload, it.header.vendor_id);
                        continue;
                    }
                    // Generic entity-ID-matched routing (BuiltinPair.tryHandle)
                    // replaces the hand-written pub/sub wid.eql chains that
                    // used to live here. Falls through to WLP (sharing this
                    // module's metatraffic unicast listener, see
                    // setWlpDispatch) if neither pub nor sub matched.
                    if (pub_pair.tryHandle(sm, src_prefix)) {
                        if (self.sedp_seen_fn) |f| f(self.sedp_seen_ctx.?, src_prefix);
                    } else if (sub_pair.tryHandle(sm, src_prefix)) {
                        if (self.sedp_seen_fn) |f| f(self.sedp_seen_ctx.?, src_prefix);
                    } else if (self.wlp_try_handle_fn) |f| {
                        _ = f(self.wlp_ctx.?, sm, src_prefix);
                    }
                },
                .heartbeat, .gap, .acknack => {
                    if (!pub_pair.tryHandle(sm, src_prefix) and !sub_pair.tryHandle(sm, src_prefix)) {
                        if (self.wlp_try_handle_fn) |f| _ = f(self.wlp_ctx.?, sm, src_prefix);
                    }
                },
                else => {},
            }
        }
    }

    // ── SEDP reader data callbacks ────────────────────────────────────────────

    fn onPubData(ctx: *anyopaque, ch: *const CacheChange) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.handleEndpointChange(ch, true);
    }

    fn onSubData(ctx: *anyopaque, ch: *const CacheChange) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.handleEndpointChange(ch, false);
    }

    fn handleEndpointChange(self: *Self, ch: *const CacheChange, is_writer: bool) void {
        if (ch.kind != .alive) return;
        const cbs = self.callbacks orelse return;
        if (is_writer) {
            var ep = decodeEndpointT(Disc.DiscoveredWriterData, self.alloc, ch.data) catch |err| {
                log.sedp.warn("sedp: failed to decode writer announcement: {s}", .{@errorName(err)});
                return;
            };
            defer ep.deinit();
            const g = guidFromBytes(&ep.data.writerGuid);
            var eff = self.resolveEffectiveLocators(g.prefix, ep.unicast, ep.multicast);
            defer eff.deinit(self.alloc);
            if (!eff.reachable) return;
            var pn_buf: [32][]const u8 = undefined;
            const pnames = legacyPartitionNames(ep.data.unknown_params, &pn_buf) orelse
                iface.partitionNames(ep.data.partition, &pn_buf);
            const wd = WriterData{
                .guid = g,
                .participant_guid = .{ .prefix = g.prefix, .entity_id = EntityIds.participant },
                .topic_name = ep.data.topicName,
                .type_name = ep.data.typeName,
                .qos = &ep.data,
                .partition_names = pnames,
                .unicast_locators = eff.uc,
                .multicast_locators = eff.mc,
                .type_object = typeInfoBlob(ep.data.unknown_params),
                .raw_parameter_list = ch.data,
            };
            cbs.on_writer_discovered(cbs.ctx, &wd);
        } else {
            var ep = decodeEndpointT(Disc.DiscoveredReaderData, self.alloc, ch.data) catch |err| {
                log.sedp.warn("sedp: failed to decode reader announcement: {s}", .{@errorName(err)});
                return;
            };
            defer ep.deinit();
            const g = guidFromBytes(&ep.data.readerGuid);
            var eff = self.resolveEffectiveLocators(g.prefix, ep.unicast, ep.multicast);
            defer eff.deinit(self.alloc);
            if (!eff.reachable) return;
            var pn_buf: [32][]const u8 = undefined;
            const pnames = legacyPartitionNames(ep.data.unknown_params, &pn_buf) orelse
                iface.partitionNames(ep.data.partition, &pn_buf);
            const rd = ReaderData{
                .guid = g,
                .participant_guid = .{ .prefix = g.prefix, .entity_id = EntityIds.participant },
                .topic_name = ep.data.topicName,
                .type_name = ep.data.typeName,
                .qos = &ep.data,
                .partition_names = pnames,
                .unicast_locators = eff.uc,
                .multicast_locators = eff.mc,
                .raw_parameter_list = ch.data,
            };
            cbs.on_reader_discovered(cbs.ctx, &rd);
        }
    }

    const EffectiveLocators = struct {
        uc: []Locator, // owned
        mc: []Locator, // owned
        reachable: bool,

        fn deinit(self: *EffectiveLocators, alloc: std.mem.Allocator) void {
            alloc.free(self.uc);
            alloc.free(self.mc);
        }
    };

    /// RTPS spec: when endpoint data omits explicit locators, fall back to the
    /// discovering participant's default unicast/multicast locators (from SPDP).
    /// `ep_uc` / `ep_mc` are the endpoint's own PID_*_LOCATOR values (rare —
    /// zzdds never emits per-endpoint locators locally). Returns owned slices;
    /// `reachable` is false only when a data-transport override is configured
    /// and nothing reachable was found (treat as a QoS-incompatible non-match).
    fn resolveEffectiveLocators(
        self: *Self,
        prefix: GuidPrefix,
        ep_uc_raw: []const Locator,
        ep_mc_raw: []const Locator,
    ) EffectiveLocators {
        // Snapshot the participant's default locators under the lock so the SPDP
        // thread can mutate the map concurrently. Read the *_for_data variants
        // (== the plain fields unless a data_reachable override is configured).
        var pl_uc: ?[]Locator = null;
        var pl_mc: ?[]Locator = null;
        self.participant_locs_mu.lock();
        if (self.participant_locs.get(prefix)) |pl| {
            pl_uc = self.alloc.dupe(Locator, pl.unicast_for_data) catch null;
            pl_mc = self.alloc.dupe(Locator, pl.multicast_for_data) catch null;
        }
        self.participant_locs_mu.unlock();
        defer if (pl_uc) |s| self.alloc.free(s);
        defer if (pl_mc) |s| self.alloc.free(s);

        var uc = if (self.data_reachable) |dr|
            iface.filterReachableLocatorsForData(self.alloc, ep_uc_raw, dr)
        else
            self.filterReachableLocators(ep_uc_raw, "endpoint unicast");
        var mc = if (self.data_reachable) |dr|
            iface.filterReachableLocatorsForData(self.alloc, ep_mc_raw, dr)
        else
            self.filterReachableLocators(ep_mc_raw, "endpoint multicast");

        if (uc.len == 0) {
            if (pl_uc) |s| {
                self.alloc.free(uc);
                uc = self.alloc.dupe(Locator, s) catch &.{};
            }
        }
        if (mc.len == 0) {
            if (pl_mc) |s| {
                self.alloc.free(mc);
                mc = self.alloc.dupe(Locator, s) catch &.{};
            }
        }

        const reachable = !(self.data_reachable != null and uc.len == 0 and mc.len == 0);
        return .{ .uc = uc, .mc = mc, .reachable = reachable };
    }

    fn filterReachableLocators(self: *Self, locators: []const Locator, context: []const u8) []Locator {
        return iface.filterReachableLocators(self.alloc, locators, self.transport, context, self);
    }

    pub fn warnUnsupportedLocatorOnce(self: *Self, loc: Locator, context: []const u8) void {
        const kind = loc.wireKind();
        self.unsupported_locator_mu.lock();
        defer self.unsupported_locator_mu.unlock();
        const gop = self.unsupported_locator_kinds.getOrPut(kind) catch return;
        if (!gop.found_existing) {
            log.sedp.warn("sedp: ignoring unsupported {s} locator kind={d}/0x{x}", .{
                context,
                kind,
                @as(u32, @bitCast(kind)),
            });
        }
    }
};

// ── Utility ───────────────────────────────────────────────────────────────────

/// Pack a GUID into a 16-byte key hash (prefix[12] ++ entity_id[4]).
fn guidToKeyHash(guid: Guid) [16]u8 {
    var kh: [16]u8 = undefined;
    @memcpy(kh[0..12], &guid.prefix.bytes);
    kh[12] = guid.entity_id.entity_key[0];
    kh[13] = guid.entity_id.entity_key[1];
    kh[14] = guid.entity_id.entity_key[2];
    kh[15] = guid.entity_id.entity_kind;
    return kh;
}

/// Scan a PL-CDR disposal payload for PID_ENDPOINT_GUID and return the GUID.
/// Called when PID_KEY_HASH is absent from inline_qos (RTPS §9.6.3.6: MAY).
fn guidFromDisposalPayload(payload: []const u8) ?Guid {
    if (payload.len < 4) return null;
    const le = (payload[1] & 0x01) != 0;
    var pos: usize = 4;
    while (pos + 4 <= payload.len) {
        const pid = readU16LE(payload[pos..], le);
        const len = readU16LE(payload[pos + 2 ..], le);
        pos += 4;
        if (pid == PidTable.SENTINEL) break;
        if (pos + len > payload.len) break;
        const v = payload[pos .. pos + len];
        pos += len;
        if (pid == PidTable.ENDPOINT_GUID and v.len >= 16) {
            return .{
                .prefix = .{ .bytes = v[0..12].* },
                .entity_id = .{ .entity_key = v[12..15].*, .entity_kind = v[15] },
            };
        }
    }
    return null;
}

/// Unpack a 16-byte key hash back into a GUID.
fn keyHashToGuid(kh: [16]u8) Guid {
    return .{
        .prefix = .{ .bytes = kh[0..12].* },
        .entity_id = .{ .entity_key = kh[12..15].*, .entity_kind = kh[15] },
    };
}

/// Encode a minimal PL-CDR disposal payload: PLCDR_LE_ENCAP + PID_ENDPOINT_GUID + PID_SENTINEL.
/// Used as the serialized_payload of NOT_ALIVE_DISPOSED DATA messages.
pub fn encodeEndpointDisposalPayload(alloc: std.mem.Allocator, guid: Guid) ![]u8 {
    return emitPlCdr(Disc.EndpointDisposal, alloc, .{ .endpointGuid = guidBytes(guid) });
}
