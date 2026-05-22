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
//! PL-CDR encoding is hand-written (no dependency on zidl-generated code here).

const std = @import("std");
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const iface = @import("interface.zig");
const tr_iface = @import("../transport/interface.zig");
const guid_mod = @import("../rtps/guid.zig");
const pid_mod = @import("../rtps/pid.zig");
const qos_mod = @import("../qos/policy.zig");
const qm_mod = @import("../dcps/qos_match.zig");
const writer_sm_mod = @import("../rtps/writer_sm.zig");
const reader_sm_mod = @import("../rtps/reader_sm.zig");
const parser_mod = @import("../rtps/message/parser.zig");
const history_mod = @import("../rtps/history.zig");
const mutex_mod = @import("../util/mutex.zig");
const time_mod = @import("../util/time.zig");
const build_opts = @import("build_options");

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
const ReaderProxy = writer_sm_mod.ReaderProxy;
const WriterProxy = reader_sm_mod.WriterProxy;
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
const QosSnapshot = iface.QosSnapshot;
const PidTable = pid_mod.PidTable;
const BuiltinEndpointSet = pid_mod.BuiltinEndpointSet;

const PLCDR_LE_ENCAP: [4]u8 = .{ 0x00, 0x03, 0x00, 0x00 };

// ── Helpers for PL-CDR I/O ────────────────────────────────────────────────────

fn writePidHdr(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), pid: u16, length: u16) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], pid, .little);
    std.mem.writeInt(u16, hdr[2..4], length, .little);
    try buf.appendSlice(alloc, &hdr);
}
fn writeU32Le(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(alloc, &b);
}
fn writeI32Le(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: i32) !void {
    try writeU32Le(alloc, buf, @bitCast(v));
}
fn writeI16Le(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: i16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(i16, &b, v, .little);
    try buf.appendSlice(alloc, &b);
}
fn writeLocator(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), loc: Locator) !void {
    const w = loc.toRtpsWire();
    try writeI32Le(alloc, buf, w.kind);
    try writeU32Le(alloc, buf, w.port);
    try buf.appendSlice(alloc, &w.address);
}

fn writePartitionPid(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), names: []const []const u8) !void {
    // Compute payload size: seq_len(4) + sum of (len_field(4) + padded_data) per name.
    var payload: usize = 4; // sequence length field
    for (names) |name| {
        const slen: usize = name.len + 1; // +1 for null terminator
        payload += 4 + ((slen + 3) & ~@as(usize, 3));
    }
    try writePidHdr(alloc, buf, PidTable.PARTITION, @intCast(payload));
    try writeU32Le(alloc, buf, @intCast(names.len));
    for (names) |name| {
        const slen: u32 = @intCast(name.len + 1);
        try writeU32Le(alloc, buf, slen);
        try buf.appendSlice(alloc, name);
        try buf.append(alloc, 0); // null terminator
        const padded: usize = (slen + 3) & ~@as(usize, 3);
        var p: usize = padded - slen;
        while (p > 0) : (p -= 1) try buf.append(alloc, 0);
    }
}

fn readU16LE(b: []const u8, le: bool) u16 {
    return std.mem.readInt(u16, b[0..2], if (le) .little else .big);
}
fn readI16LE(b: []const u8, le: bool) i16 {
    return @bitCast(readU16LE(b, le));
}
fn readU32LE(b: []const u8, le: bool) u32 {
    return std.mem.readInt(u32, b[0..4], if (le) .little else .big);
}
fn readI32LE(b: []const u8, le: bool) i32 {
    return @bitCast(readU32LE(b, le));
}
fn readLocator(b: []const u8, le: bool) Locator {
    const kind = readI32LE(b[0..], le);
    const port = readU32LE(b[4..], le);
    var addr: [16]u8 = undefined;
    @memcpy(&addr, b[8..24]);
    const wire = LocatorWire{ .kind = kind, .port = port, .address = addr };
    return wire.toLocator();
}
fn readString(b: []const u8, le: bool) []const u8 {
    if (b.len < 4) return "";
    const slen = readU32LE(b[0..], le);
    if (slen == 0 or b.len < 4 + slen) return "";
    const end = 4 + slen - 1; // strip null
    return b[4..end];
}
fn readDuration(b: []const u8, le: bool) time_mod.Duration {
    if (b.len < 8) return time_mod.Duration.infinite;
    return .{ .sec = readI32LE(b[0..], le), .nanosec = readU32LE(b[4..], le) };
}

// ── DiscoveredWriterData encoding ─────────────────────────────────────────────

fn encodeWriterData(alloc: std.mem.Allocator, ann: *const WriterAnnouncement) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, &PLCDR_LE_ENCAP);

    // PID_ENDPOINT_GUID (0x005A): 16 bytes
    try writePidHdr(alloc, &buf, PidTable.ENDPOINT_GUID, 16);
    try buf.appendSlice(alloc, &ann.guid.prefix.bytes);
    try buf.appendSlice(alloc, &[_]u8{
        ann.guid.entity_id.entity_key[0],
        ann.guid.entity_id.entity_key[1],
        ann.guid.entity_id.entity_key[2],
        ann.guid.entity_id.entity_kind,
    });

    // PID_TOPIC_NAME (0x0005)
    {
        const slen: u32 = @intCast(ann.topic_name.len + 1);
        const total: u32 = 4 + slen;
        const padded: u16 = @intCast((total + 3) & ~@as(u32, 3));
        try writePidHdr(alloc, &buf, PidTable.TOPIC_NAME, padded);
        try writeU32Le(alloc, &buf, slen);
        try buf.appendSlice(alloc, ann.topic_name);
        try buf.append(alloc, 0);
        var p: usize = padded - total;
        while (p > 0) : (p -= 1) try buf.append(alloc, 0);
    }

    // PID_TYPE_NAME (0x0007)
    {
        const slen: u32 = @intCast(ann.type_name.len + 1);
        const total: u32 = 4 + slen;
        const padded: u16 = @intCast((total + 3) & ~@as(u32, 3));
        try writePidHdr(alloc, &buf, PidTable.TYPE_NAME, padded);
        try writeU32Le(alloc, &buf, slen);
        try buf.appendSlice(alloc, ann.type_name);
        try buf.append(alloc, 0);
        var p: usize = padded - total;
        while (p > 0) : (p -= 1) try buf.append(alloc, 0);
    }

    // QoS policies.
    // RTPS wire reliability: 1=BEST_EFFORT, 2=RELIABLE (DDS API: 0/1 → add 1 on wire).
    // PID_RELIABILITY is 12 bytes: kind (4) + max_blocking_time Duration_t (8).
    try writePidHdr(alloc, &buf, PidTable.RELIABILITY, 12);
    try writeU32Le(alloc, &buf, @as(u32, ann.qos.reliability_kind) + 1);
    try writeI32Le(alloc, &buf, 0); // max_blocking_time.sec = 0
    try writeU32Le(alloc, &buf, 0); // max_blocking_time.nanosec = 0
    try writePidHdr(alloc, &buf, PidTable.DURABILITY, 4);
    try writeU32Le(alloc, &buf, ann.qos.durability_kind);
    // PID_DEADLINE: only emitted when not INFINITE; omitting INFINITE avoids
    // encoding differences between implementations.
    if (ann.qos.deadline_sec != 0x7fff_ffff or ann.qos.deadline_nanosec != 0x7fff_ffff) {
        try writePidHdr(alloc, &buf, PidTable.DEADLINE, 8);
        try writeI32Le(alloc, &buf, ann.qos.deadline_sec);
        try writeU32Le(alloc, &buf, ann.qos.deadline_nanosec);
    }
    // PID_LIVELINESS is omitted: defaults to AUTOMATIC + INFINITE everywhere.
    // Cyclone and OpenDDS use different on-wire representations for Duration_t
    // INFINITE, so explicitly encoding it causes QoS-match failures.
    try writePidHdr(alloc, &buf, PidTable.OWNERSHIP, 4);
    try writeU32Le(alloc, &buf, ann.qos.ownership_kind);
    if (ann.qos.ownership_kind != 0) {
        try writePidHdr(alloc, &buf, PidTable.OWNERSHIP_STRENGTH, 4);
        try writeI32Le(alloc, &buf, ann.qos.ownership_strength);
    }
    try writePidHdr(alloc, &buf, PidTable.DESTINATION_ORDER, 4);
    try writeU32Le(alloc, &buf, ann.qos.destination_order_kind);
    try writePidHdr(alloc, &buf, PidTable.HISTORY, 8);
    try writeU32Le(alloc, &buf, ann.qos.history_kind);
    try writeI32Le(alloc, &buf, ann.qos.history_depth);

    // PID_DATA_REPRESENTATION: seq_len(4) + value(2) + pad(2) = 8 bytes.
    // Advertise a single representation matching the writer's QoS so that
    // remote readers using the intersection rule (Cyclone 11, DustDDS) can
    // correctly determine compatibility.
    {
        const repr: i16 = if (ann.qos.data_representation == 2) 2 else 0; // XCDR2=2, XCDR1=0
        try writePidHdr(alloc, &buf, PidTable.DATA_REPRESENTATION, 8);
        try writeU32Le(alloc, &buf, 1); // sequence length: 1 element
        try writeI16Le(alloc, &buf, repr);
        try writeI16Le(alloc, &buf, 0); // pad to 4-byte boundary
    }

    // PID_TYPE_INFORMATION (0x0075): CDR2-encoded XTypes TypeInformation blob.
    // Only emitted when the enable_xtypes build option is set; advertising this
    // PID without a functioning TypeLookup service causes OpenDDS to stall
    // endpoint matching waiting for a GET_TYPES response that never arrives.
    if (build_opts.xtypes and ann.type_info_cdr.len > 0) {
        const tlen: u16 = @intCast((ann.type_info_cdr.len + 3) & ~@as(usize, 3));
        try writePidHdr(alloc, &buf, PidTable.TYPE_INFORMATION, tlen);
        try buf.appendSlice(alloc, ann.type_info_cdr);
        var pad: usize = tlen - ann.type_info_cdr.len;
        while (pad > 0) : (pad -= 1) try buf.append(alloc, 0);
    }

    // PID_PARTITION (0x0029): CDR sequence<string>. Omitted when default (empty list).
    if (ann.qos.partition_names.len > 0) {
        try writePartitionPid(alloc, &buf, ann.qos.partition_names);
    }

    try buf.appendSlice(alloc, &[_]u8{ 0x01, 0x00, 0x00, 0x00 }); // SENTINEL
    return buf.toOwnedSlice(alloc);
}

// ── DiscoveredReaderData encoding ─────────────────────────────────────────────

fn encodeReaderData(alloc: std.mem.Allocator, ann: *const ReaderAnnouncement) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, &PLCDR_LE_ENCAP);

    try writePidHdr(alloc, &buf, PidTable.ENDPOINT_GUID, 16);
    try buf.appendSlice(alloc, &ann.guid.prefix.bytes);
    try buf.appendSlice(alloc, &[_]u8{
        ann.guid.entity_id.entity_key[0],
        ann.guid.entity_id.entity_key[1],
        ann.guid.entity_id.entity_key[2],
        ann.guid.entity_id.entity_kind,
    });

    {
        const slen: u32 = @intCast(ann.topic_name.len + 1);
        const total: u32 = 4 + slen;
        const padded: u16 = @intCast((total + 3) & ~@as(u32, 3));
        try writePidHdr(alloc, &buf, PidTable.TOPIC_NAME, padded);
        try writeU32Le(alloc, &buf, slen);
        try buf.appendSlice(alloc, ann.topic_name);
        try buf.append(alloc, 0);
        var p: usize = padded - total;
        while (p > 0) : (p -= 1) try buf.append(alloc, 0);
    }
    {
        const slen: u32 = @intCast(ann.type_name.len + 1);
        const total: u32 = 4 + slen;
        const padded: u16 = @intCast((total + 3) & ~@as(u32, 3));
        try writePidHdr(alloc, &buf, PidTable.TYPE_NAME, padded);
        try writeU32Le(alloc, &buf, slen);
        try buf.appendSlice(alloc, ann.type_name);
        try buf.append(alloc, 0);
        var p: usize = padded - total;
        while (p > 0) : (p -= 1) try buf.append(alloc, 0);
    }

    // RTPS wire reliability: 1=BEST_EFFORT, 2=RELIABLE (DDS API: 0/1 → add 1 on wire).
    // PID_RELIABILITY is 12 bytes: kind (4) + max_blocking_time Duration_t (8).
    try writePidHdr(alloc, &buf, PidTable.RELIABILITY, 12);
    try writeU32Le(alloc, &buf, @as(u32, ann.qos.reliability_kind) + 1);
    try writeI32Le(alloc, &buf, 0); // max_blocking_time.sec = 0
    try writeU32Le(alloc, &buf, 0); // max_blocking_time.nanosec = 0
    try writePidHdr(alloc, &buf, PidTable.DURABILITY, 4);
    try writeU32Le(alloc, &buf, ann.qos.durability_kind);
    try writePidHdr(alloc, &buf, PidTable.OWNERSHIP, 4);
    try writeU32Le(alloc, &buf, ann.qos.ownership_kind);

    // PID_DATA_REPRESENTATION: emit exactly the configured representation so that
    // remote writers can detect incompatible data_representation QoS.
    // Sequence layout: seq_len(4) + i16 + pad(2) = 8 bytes.
    {
        const repr: i16 = if (ann.qos.data_representation == 2) 2 else 0; // XCDR2=2, XCDR1=0
        try writePidHdr(alloc, &buf, PidTable.DATA_REPRESENTATION, 8);
        try writeU32Le(alloc, &buf, 1); // sequence length: 1 element
        try writeI16Le(alloc, &buf, repr);
        try writeI16Le(alloc, &buf, 0); // pad to 4-byte boundary
    }

    // PID_DEADLINE: only emitted when not INFINITE; omitting INFINITE avoids
    // encoding differences between implementations.
    if (ann.qos.deadline_sec != 0x7fff_ffff or ann.qos.deadline_nanosec != 0x7fff_ffff) {
        try writePidHdr(alloc, &buf, PidTable.DEADLINE, 8);
        try writeI32Le(alloc, &buf, ann.qos.deadline_sec);
        try writeU32Le(alloc, &buf, ann.qos.deadline_nanosec);
    }
    // PID_LIVELINESS is omitted: defaults to AUTOMATIC + INFINITE everywhere.

    // PID_TYPE_INFORMATION is omitted from reader announcements: when present,
    // OpenDDS 3.x initiates a TypeLookup round-trip to the remote reader, which
    // we don't implement.  Cyclone falls back to type-name matching when the
    // remote reader has no TypeInformation, so S2 still passes.

    // PID_PARTITION (0x0029): CDR sequence<string>. Omitted when default (empty list).
    if (ann.qos.partition_names.len > 0) {
        try writePartitionPid(alloc, &buf, ann.qos.partition_names);
    }

    try buf.appendSlice(alloc, &[_]u8{ 0x01, 0x00, 0x00, 0x00 });
    return buf.toOwnedSlice(alloc);
}

// ── Decode helpers ────────────────────────────────────────────────────────────

const DecodedEndpoint = struct {
    guid: Guid,
    topic_name: []u8, // owned
    type_name: []u8, // owned
    unicast: []Locator, // owned
    multicast: []Locator, // owned
    partition_names: [][]u8, // owned: each string individually allocated
    qos: QosSnapshot,
    alloc: std.mem.Allocator,

    fn deinit(self: *DecodedEndpoint) void {
        self.alloc.free(self.topic_name);
        self.alloc.free(self.type_name);
        self.alloc.free(self.unicast);
        self.alloc.free(self.multicast);
        for (self.partition_names) |name| self.alloc.free(name);
        self.alloc.free(self.partition_names);
    }
};

fn decodeEndpoint(alloc: std.mem.Allocator, payload: []const u8, is_writer: bool) !DecodedEndpoint {
    if (payload.len < 4) return error.TooShort;
    const le = (payload[1] & 0x01) != 0;

    var guid = Guid.unknown;
    var topic: []u8 = &.{};
    var typ: []u8 = &.{};
    var uc: std.ArrayList(Locator) = .empty;
    var mc: std.ArrayList(Locator) = .empty;
    var partitions: std.ArrayList([]u8) = .empty;
    errdefer {
        uc.deinit(alloc);
        mc.deinit(alloc);
        for (partitions.items) |name| alloc.free(name);
        partitions.deinit(alloc);
    }
    // DDS spec defaults: DataWriter reliability = RELIABLE (1), DataReader = BEST_EFFORT (0).
    // Implementations may omit PID_RELIABILITY when it matches the default.
    var qos = QosSnapshot{ .reliability_kind = if (is_writer) 1 else 0 };

    var pos: usize = 4;
    while (pos + 4 <= payload.len) {
        const pid = readU16LE(payload[pos..], le);
        const len = readU16LE(payload[pos + 2 ..], le);
        pos += 4;
        if (pid == PidTable.SENTINEL) break;
        if (pos + len > payload.len) break;
        const v = payload[pos .. pos + len];
        pos += len;

        switch (pid) {
            PidTable.ENDPOINT_GUID => {
                if (v.len >= 16) {
                    @memcpy(&guid.prefix.bytes, v[0..12]);
                    guid.entity_id = .{
                        .entity_key = v[12..15].*,
                        .entity_kind = v[15],
                    };
                }
            },
            PidTable.TOPIC_NAME => {
                const s = readString(v, le);
                topic = try alloc.dupe(u8, s);
            },
            PidTable.TYPE_NAME => {
                const s = readString(v, le);
                typ = try alloc.dupe(u8, s);
            },
            PidTable.UNICAST_LOCATOR => { // 0x002F — endpoint-specific unicast locator in SEDP
                if (v.len >= 24) try uc.append(alloc, readLocator(v, le));
            },
            PidTable.MULTICAST_LOCATOR => { // 0x0030
                if (v.len >= 24) try mc.append(alloc, readLocator(v, le));
            },
            PidTable.RELIABILITY => {
                // Wire: 1=BEST_EFFORT, 2=RELIABLE. Internal: 0=BEST_EFFORT, 1=RELIABLE.
                if (v.len >= 4) {
                    const wire = readU32LE(v, le);
                    qos.reliability_kind = if (wire >= 1) @intCast(wire - 1) else 0;
                }
            },
            PidTable.DURABILITY => {
                if (v.len >= 4) qos.durability_kind = @intCast(readU32LE(v, le));
            },
            PidTable.LIVELINESS => {
                if (v.len >= 4) qos.liveliness_kind = @intCast(readU32LE(v, le));
            },
            PidTable.DEADLINE => {
                if (v.len >= 8) {
                    const dur = readDuration(v, le);
                    qos.deadline_sec = dur.sec;
                    qos.deadline_nanosec = dur.nanosec;
                }
            },
            PidTable.OWNERSHIP => {
                if (v.len >= 4) qos.ownership_kind = @intCast(readU32LE(v, le));
            },
            PidTable.OWNERSHIP_STRENGTH => {
                if (v.len >= 4) qos.ownership_strength = readI32LE(v, le);
            },
            PidTable.HISTORY => {
                if (v.len >= 8) {
                    qos.history_kind = @intCast(readU32LE(v[0..], le));
                    qos.history_depth = readI32LE(v[4..], le);
                }
            },
            PidTable.DESTINATION_ORDER => {
                if (v.len >= 4) qos.destination_order_kind = @intCast(readU32LE(v, le));
            },
            PidTable.DATA_REPRESENTATION => {
                // seq_len (4) + first id (2) — only the first value matters for matching
                if (v.len >= 6) {
                    const seq_len = readU32LE(v, le);
                    if (seq_len >= 1) {
                        const id = readI16LE(v[4..], le);
                        // Map wire value: 0=XCDR1, 2=XCDR2. Store as 1/2.
                        qos.data_representation = if (id == 2) 2 else 1;
                    }
                }
            },
            PidTable.PARTITION, PidTable.PARTITION_LEGACY => {
                // CDR sequence<string>: seq_len(4) + N × (str_len(4) + chars + null + pad)
                if (v.len >= 4) {
                    const count = readU32LE(v, le);
                    var off: usize = 4;
                    var i: u32 = 0;
                    while (i < count and off + 4 <= v.len) : (i += 1) {
                        const slen = readU32LE(v[off..], le);
                        off += 4;
                        if (slen == 0 or off + slen > v.len) break;
                        const s = v[off .. off + slen - 1]; // strip null terminator
                        try partitions.append(alloc, try alloc.dupe(u8, s));
                        // Advance to the next 4-byte aligned boundary after the string data.
                        const end = off + slen;
                        off = (end + 3) & ~@as(usize, 3);
                    }
                }
            },
            else => {},
        }
    }

    const part_slice = try partitions.toOwnedSlice(alloc);
    // Point qos.partition_names into the owned slice (valid while DecodedEndpoint is alive).
    qos.partition_names = @ptrCast(part_slice);

    return DecodedEndpoint{
        .alloc = alloc,
        .guid = guid,
        .topic_name = topic,
        .type_name = typ,
        .unicast = try uc.toOwnedSlice(alloc),
        .multicast = try mc.toOwnedSlice(alloc),
        .partition_names = part_slice,
        .qos = qos,
    };
}

// ── SedpEndpoints ─────────────────────────────────────────────────────────────

/// Cached default locators for a known remote participant.
/// Used as a fallback when SEDP endpoint data omits explicit locators.
const ParticipantLocators = struct {
    unicast: []Locator, // owned
    multicast: []Locator, // owned
    alloc: std.mem.Allocator,

    fn deinit(self: *ParticipantLocators) void {
        self.alloc.free(self.unicast);
        self.alloc.free(self.multicast);
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
    spdp_relay_fn: ?*const fn (*anyopaque, GuidPrefix, []const u8) void,

    // Cached default locators per participant (RTPS: endpoints inherit these
    // when DiscoveredWriter/ReaderData omits explicit locator PIDs).
    participant_locs: std.AutoHashMap(GuidPrefix, ParticipantLocators),

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
            .spdp_relay_ctx = null,
            .spdp_relay_fn = null,
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
        self.alloc.destroy(self);
    }

    /// Override the wire tracer used by all SEDP state machines.
    /// Wire an SPDP relay so that SPDP DATA packets arriving on the metatraffic
    /// unicast port are forwarded to the SPDP handler.  Must be called before `start()`.
    pub fn setSpdpRelay(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, GuidPrefix, []const u8) void,
    ) void {
        self.spdp_relay_ctx = ctx;
        self.spdp_relay_fn = fn_ptr;
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
        if (self.meta_unicast_port != 0) {
            const loc = Locator.udp4(.{ 0, 0, 0, 0 }, self.meta_unicast_port);
            self.transport.unlisten(&loc, ReceiveHandler{
                .ctx = self,
                .on_receive = onReceive,
            });
        }
    }

    // ── Called by SpdpEndpoints when a remote participant is found ────────────

    /// Wire the remote participant's SEDP built-in endpoints into our proxies.
    pub fn onParticipantDiscovered(
        ctx: *anyopaque,
        data: *const ParticipantData,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const eps = data.builtin_endpoint_set;
        const uc = data.metatraffic_unicast_locators;
        const mc = data.metatraffic_multicast_locators;

        log.sedp.debug("sedp: onParticipantDiscovered prefix={x} eps=0x{x} uc_count={d}", .{
            data.guid.prefix.bytes, eps, uc.len,
        });
        for (uc) |loc| log.sedp.debug("sedp:   metatraffic_unicast_locator={any}", .{loc});

        // Cache the participant's default data locators so endpoints that omit
        // explicit locators in their SEDP announcement can fall back to them.
        // Lock is released before calling addMatchedWriter/addMatchedReader to
        // avoid a lock-order inversion with sub_reader.mu.
        {
            self.participant_locs_mu.lock();
            const gop = self.participant_locs.getOrPut(data.guid.prefix) catch {
                self.participant_locs_mu.unlock();
                return;
            };
            if (gop.found_existing) gop.value_ptr.deinit();
            gop.value_ptr.* = .{
                .alloc = self.alloc,
                .unicast = self.alloc.dupe(Locator, data.default_unicast_locators) catch &.{},
                .multicast = self.alloc.dupe(Locator, data.default_multicast_locators) catch &.{},
            };
            self.participant_locs_mu.unlock();
        }

        // Remote has a publications announcer → add proxy to our pub_reader.
        if (eps & BuiltinEndpointSet.DISC_BUILTIN_ENDPOINT_PUBLICATIONS_ANNOUNCER != 0) {
            const rw_guid = Guid{
                .prefix = data.guid.prefix,
                .entity_id = EntityIds.sedp_builtin_publications_writer,
            };
            if (self.pub_reader) |pr| {
                const wp = WriterProxy.init(self.alloc, rw_guid, uc, mc, true) catch return;
                pr.addMatchedWriter(wp) catch {};
            }
        }

        // Remote has a publications detector → add proxy to our pub_writer.
        if (eps & BuiltinEndpointSet.DISC_BUILTIN_ENDPOINT_PUBLICATIONS_DETECTOR != 0) {
            const rr_guid = Guid{
                .prefix = data.guid.prefix,
                .entity_id = EntityIds.sedp_builtin_publications_reader,
            };
            if (self.pub_writer) |pw| {
                const rp = ReaderProxy.init(self.alloc, rr_guid, uc, mc, false, true) catch return;
                pw.addMatchedReader(rp) catch {};
            }
        }

        // Remote has a subscriptions announcer → add proxy to our sub_reader.
        if (eps & BuiltinEndpointSet.DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_ANNOUNCER != 0) {
            const rw_guid = Guid{
                .prefix = data.guid.prefix,
                .entity_id = EntityIds.sedp_builtin_subscriptions_writer,
            };
            if (self.sub_reader) |sr| {
                const wp = WriterProxy.init(self.alloc, rw_guid, uc, mc, true) catch return;
                sr.addMatchedWriter(wp) catch {};
            }
        }

        // Remote has a subscriptions detector → add proxy to our sub_writer.
        if (eps & BuiltinEndpointSet.DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_DETECTOR != 0) {
            const rr_guid = Guid{
                .prefix = data.guid.prefix,
                .entity_id = EntityIds.sedp_builtin_subscriptions_reader,
            };
            if (self.sub_writer) |sw| {
                const rp = ReaderProxy.init(self.alloc, rr_guid, uc, mc, false, true) catch return;
                sw.addMatchedReader(rp) catch {};
            }
        }
    }

    // ── Local endpoint announcement ───────────────────────────────────────────

    pub fn announceWriter(self: *Self, ann: *const WriterAnnouncement) !void {
        const payload = try encodeWriterData(self.alloc, ann);
        defer self.alloc.free(payload);
        if (self.pub_writer) |pw| {
            _ = try pw.write(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), payload);
        }
    }

    pub fn retractWriter(self: *Self, guid: Guid) void {
        const kh = guidToKeyHash(guid);
        const payload = encodeEndpointDisposalPayload(self.alloc, guid) catch return;
        defer self.alloc.free(payload);
        if (self.pub_writer) |pw| {
            _ = pw.write(.not_alive_disposed, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, kh, payload) catch {};
        }
    }

    pub fn announceReader(self: *Self, ann: *const ReaderAnnouncement) !void {
        const payload = try encodeReaderData(self.alloc, ann);
        defer self.alloc.free(payload);
        if (self.sub_writer) |sw| {
            _ = try sw.write(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), payload);
        }
    }

    pub fn retractReader(self: *Self, guid: Guid) void {
        const kh = guidToKeyHash(guid);
        const payload = encodeEndpointDisposalPayload(self.alloc, guid) catch return;
        defer self.alloc.free(payload);
        if (self.sub_writer) |sw| {
            _ = sw.write(.not_alive_disposed, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, kh, payload) catch {};
        }
    }

    // ── Transport receive callback ────────────────────────────────────────────

    fn onReceive(ctx: *anyopaque, data: []const u8, _: Locator) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
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
                                const si = std.mem.readInt(u32, si_bytes[0..4], .little);
                                if (si & 0x00000003 != 0) { // DISPOSED or UNREGISTERED
                                    if (iqos.get(.key_hash)) |kh_bytes| {
                                        if (kh_bytes.len >= 16) {
                                            const ep_guid = keyHashToGuid(kh_bytes[0..16].*);
                                            if (wid.eql(EntityIds.sedp_builtin_publications_writer)) {
                                                if (self.callbacks) |cbs|
                                                    cbs.on_writer_lost(cbs.ctx, ep_guid);
                                            } else if (wid.eql(EntityIds.sedp_builtin_subscriptions_writer)) {
                                                if (self.callbacks) |cbs|
                                                    cbs.on_reader_lost(cbs.ctx, ep_guid);
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
                            relay(self.spdp_relay_ctx.?, src_prefix, payload);
                        continue;
                    } else if (wid.eql(EntityIds.sedp_builtin_publications_writer)) {
                        if (self.pub_reader) |pr| {
                            const ch = makeCacheChange(src_prefix, wid, d.writer_sn, payload);
                            pr.handleData(Guid{ .prefix = src_prefix, .entity_id = wid }, ch) catch {};
                        }
                    } else if (wid.eql(EntityIds.sedp_builtin_subscriptions_writer)) {
                        if (self.sub_reader) |sr| {
                            const ch = makeCacheChange(src_prefix, wid, d.writer_sn, payload);
                            sr.handleData(Guid{ .prefix = src_prefix, .entity_id = wid }, ch) catch {};
                        }
                    }
                },
                .heartbeat => |hb| {
                    const wid = hb.writer_entity_id;
                    const wguid = Guid{ .prefix = src_prefix, .entity_id = wid };
                    if (wid.eql(EntityIds.sedp_builtin_publications_writer)) {
                        if (self.pub_reader) |pr|
                            pr.handleHeartbeat(wguid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal());
                    } else if (wid.eql(EntityIds.sedp_builtin_subscriptions_writer)) {
                        if (self.sub_reader) |sr|
                            sr.handleHeartbeat(wguid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal());
                    }
                },
                .acknack => |an| {
                    const rid = an.reader_entity_id;
                    const rguid = Guid{ .prefix = src_prefix, .entity_id = rid };
                    if (rid.eql(EntityIds.sedp_builtin_publications_reader)) {
                        if (self.pub_writer) |pw|
                            pw.handleAckNack(rguid, an.reader_sn_state.base - 1, an.reader_sn_state, an.count, an.isFinal());
                    } else if (rid.eql(EntityIds.sedp_builtin_subscriptions_reader)) {
                        if (self.sub_writer) |sw|
                            sw.handleAckNack(rguid, an.reader_sn_state.base - 1, an.reader_sn_state, an.count, an.isFinal());
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
        var ep = decodeEndpoint(self.alloc, ch.data, is_writer) catch return;
        defer ep.deinit();

        const cbs = self.callbacks orelse return;

        // RTPS spec: if endpoint data omits explicit locators, fall back to the
        // participant's default unicast/multicast locators (from SPDP).
        // Take a local copy under participant_locs_mu so the SPDP thread can
        // safely mutate the map while we use the locators below.
        var pl_uc_copy: ?[]Locator = null;
        var pl_mc_copy: ?[]Locator = null;
        self.participant_locs_mu.lock();
        if (self.participant_locs.get(ep.guid.prefix)) |pl| {
            pl_uc_copy = self.alloc.dupe(Locator, pl.unicast) catch null;
            pl_mc_copy = self.alloc.dupe(Locator, pl.multicast) catch null;
        }
        self.participant_locs_mu.unlock();
        defer if (pl_uc_copy) |s| self.alloc.free(s);
        defer if (pl_mc_copy) |s| self.alloc.free(s);

        const eff_uc: []const Locator = if (ep.unicast.len > 0)
            ep.unicast
        else if (pl_uc_copy) |s|
            s
        else
            ep.unicast;

        const eff_mc: []const Locator = if (ep.multicast.len > 0)
            ep.multicast
        else if (pl_mc_copy) |s|
            s
        else
            ep.multicast;

        if (is_writer) {
            const wd = WriterData{
                .guid = ep.guid,
                .participant_guid = .{
                    .prefix = ep.guid.prefix,
                    .entity_id = EntityIds.participant,
                },
                .topic_name = ep.topic_name,
                .type_name = ep.type_name,
                .qos = ep.qos,
                .unicast_locators = eff_uc,
                .multicast_locators = eff_mc,
                .type_object = &.{},
            };
            cbs.on_writer_discovered(cbs.ctx, &wd);
        } else {
            const rd = ReaderData{
                .guid = ep.guid,
                .participant_guid = .{
                    .prefix = ep.guid.prefix,
                    .entity_id = EntityIds.participant,
                },
                .topic_name = ep.topic_name,
                .type_name = ep.type_name,
                .qos = ep.qos,
                .unicast_locators = eff_uc,
                .multicast_locators = eff_mc,
            };
            cbs.on_reader_discovered(cbs.ctx, &rd);
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

/// Unpack a 16-byte key hash back into a GUID.
fn keyHashToGuid(kh: [16]u8) Guid {
    return .{
        .prefix = .{ .bytes = kh[0..12].* },
        .entity_id = .{ .entity_key = kh[12..15].*, .entity_kind = kh[15] },
    };
}

/// Encode a minimal PL-CDR disposal payload: PLCDR_LE_ENCAP + PID_ENDPOINT_GUID + PID_SENTINEL.
/// Used as the serialized_payload of NOT_ALIVE_DISPOSED DATA messages.
fn encodeEndpointDisposalPayload(alloc: std.mem.Allocator, guid: Guid) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, &PLCDR_LE_ENCAP);
    try writePidHdr(alloc, &buf, PidTable.ENDPOINT_GUID, 16);
    try buf.appendSlice(alloc, &guid.prefix.bytes);
    try buf.appendSlice(alloc, &[_]u8{
        guid.entity_id.entity_key[0],
        guid.entity_id.entity_key[1],
        guid.entity_id.entity_key[2],
        guid.entity_id.entity_kind,
    });
    try writePidHdr(alloc, &buf, PidTable.SENTINEL, 0);
    return buf.toOwnedSlice(alloc);
}

fn makeCacheChange(
    prefix: GuidPrefix,
    eid: guid_mod.EntityId,
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
