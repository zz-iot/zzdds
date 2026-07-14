//! RTPS Message Header (RTPS 2.5 §9.4.1).
//!
//! Every RTPS message begins with a fixed 20-byte header:
//!
//!   Bytes  0–3   protocolId   "RTPS"
//!   Bytes  4–5   protocolVersion  major.minor
//!   Bytes  6–7   vendorId
//!   Bytes  8–19  guidPrefix
//!
//! The header is always in network byte order (big-endian for the magic bytes;
//! individual submessages carry their own endianness flag).

const std = @import("std");
const GuidPrefix = @import("../guid.zig").GuidPrefix;

// ── Protocol constants ────────────────────────────────────────────────────────

/// "RTPS" magic bytes that begin every RTPS message.
pub const PROTOCOL_ID: [4]u8 = .{ 'R', 'T', 'P', 'S' };

/// Protocol version supported by this implementation (RTPS 2.5).
pub const PROTOCOL_VERSION: ProtocolVersion = .{ .major = 2, .minor = 5 };

/// Zenzen DDS vendor ID.
/// TODO: register a real vendor ID with the OMG/DDS Foundation before shipping.
/// Using 0x0123 as a placeholder; verify it is unregistered before release at
/// https://www.dds-foundation.org/dds-rtps-vendor-and-product-ids
pub const VENDOR_ID: VendorId = .{ .bytes = .{ 0x01, 0x23 } };

// ── Types ─────────────────────────────────────────────────────────────────────

/// RTPS protocol version (§9.3.1).
pub const ProtocolVersion = extern struct {
    major: u8,
    minor: u8,

    pub fn eql(a: ProtocolVersion, b: ProtocolVersion) bool {
        return a.major == b.major and a.minor == b.minor;
    }
};

/// RTPS vendor identifier (§9.3.3 Table 9.4).
pub const VendorId = extern struct {
    bytes: [2]u8,

    pub fn eql(a: VendorId, b: VendorId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

/// Eclipse Cyclone DDS's VendorId as observed on the wire from
/// eclipse_cyclone-11.0.1's shape_main binary (2026-07-14, via
/// dds-rtps/rtps_pcap.py packet capture) — {0x01, 0x10}. Note this differs
/// from the "Eclipse CycloneDDS" entry (0x0113) some vendor-ID reference
/// tables list; always verify against a real capture rather than a table.
pub const VENDOR_ID_ECLIPSE_CYCLONE: VendorId = .{ .bytes = .{ 0x01, 0x10 } };

/// True for remote vendors whose RTPS reader is known, by direct empirical
/// testing, to reject a fully-bare end-of-coherent-set DATA submessage (RTPS
/// 2.5 §9.6.4.2 Table 9.22 "Example 3": DataFlag=0, InlineQosFlag=0) as a
/// malformed packet, and therefore need the explicit
/// PID_COHERENT_SET=SEQUENCENUMBER_UNKNOWN form ("Example 2") instead.
///
/// Both forms are spec-legal and declared equivalent by RTPS 2.5 §9.6.4.2:
/// "A Data Submessage ... that does not contain a coherent set in-line QoS
/// parameter or alternatively, contains a coherent set in-line QoS parameter
/// with value SEQUENCENUMBER_UNKNOWN. Both approaches are equivalent." This
/// is a parser-strictness accommodation, not a spec deviation — the value
/// sent is always the spec-correct SEQUENCENUMBER_UNKNOWN ({-1,0}); only the
/// choice of which of the two equally-valid Table 9.22 forms to use varies
/// per remote reader.
///
/// Verified directly against eclipse_cyclone-11.0.1's shape_main: it logs
/// "malformed packet ... state parse:shortmsg" when sent Example 3, and logs
/// no error when sent Example 2 with the spec-correct value. Example 3 is the
/// default (smaller, and what every other tested vendor — RTI Connext 7.7.0 —
/// correctly accepts); this list should only grow when a new vendor is
/// concretely observed to have the same defect.
pub fn needsPidCoherentSetMarker(vendor_id: VendorId) bool {
    return vendor_id.eql(VENDOR_ID_ECLIPSE_CYCLONE);
}

/// RTPS Message Header (§9.4.1).
/// Serialized layout: 20 bytes, no padding.
pub const Header = extern struct {
    protocol_id: [4]u8,
    protocol_version: ProtocolVersion,
    vendor_id: VendorId,
    guid_prefix: GuidPrefix,

    comptime {
        // RTPS §9.4.1: header is exactly 20 bytes.
        std.debug.assert(@sizeOf(Header) == 20);
    }

    /// Construct a message header for the given sender GUID prefix.
    pub fn init(prefix: GuidPrefix) Header {
        return .{
            .protocol_id = PROTOCOL_ID,
            .protocol_version = PROTOCOL_VERSION,
            .vendor_id = VENDOR_ID,
            .guid_prefix = prefix,
        };
    }

    /// True if the first 4 bytes match "RTPS".
    pub fn isValid(self: Header) bool {
        return std.mem.eql(u8, &self.protocol_id, &PROTOCOL_ID);
    }

    /// Serialize to bytes (for transmission).
    /// The header is written in the same byte order it occupies in memory
    /// because all fields are either magic bytes or explicitly sized.
    pub fn toBytes(self: Header) [20]u8 {
        return @bitCast(self);
    }

    /// Parse from raw bytes. Returns null if protocol magic is wrong.
    pub fn fromBytes(bytes: *const [20]u8) ?Header {
        const h: Header = @bitCast(bytes.*);
        if (!h.isValid()) return null;
        return h;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Header size is 20 bytes" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(Header));
}

test "Header.init sets protocol magic and version" {
    const prefix = GuidPrefix{ .bytes = .{1} ++ .{0} ** 11 };
    const h = Header.init(prefix);
    try std.testing.expect(std.mem.eql(u8, &h.protocol_id, "RTPS"));
    try std.testing.expectEqual(@as(u8, 2), h.protocol_version.major);
    try std.testing.expectEqual(@as(u8, 5), h.protocol_version.minor);
}

test "Header round-trip via bytes" {
    const prefix = GuidPrefix{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } };
    const h = Header.init(prefix);
    const bytes = h.toBytes();
    const h2 = Header.fromBytes(&bytes) orelse return error.ParseFailed;
    try std.testing.expect(std.mem.eql(u8, &h.guid_prefix.bytes, &h2.guid_prefix.bytes));
}

test "Header.fromBytes rejects bad magic" {
    var bytes = [_]u8{0} ** 20;
    bytes[0] = 'X'; // corrupt magic
    try std.testing.expectEqual(@as(?Header, null), Header.fromBytes(&bytes));
}

test "ProtocolVersion eql" {
    const v = PROTOCOL_VERSION;
    try std.testing.expect(v.eql(ProtocolVersion{ .major = 2, .minor = 5 }));
    try std.testing.expect(!v.eql(ProtocolVersion{ .major = 2, .minor = 3 }));
}
