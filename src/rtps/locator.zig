//! RTPS Locator_t (RTPS 2.5 §9.3.2 Table 9.19).
//!
//! Re-exported here so RTPS code can import a single file for all RTPS primitives
//! rather than reaching into the transport layer. The canonical definitions live
//! in transport/interface.zig; this file re-exports and adds RTPS-specific helpers.

pub const transport_iface = @import("../transport/interface.zig");

pub const Locator = transport_iface.Locator;
pub const LocatorWire = transport_iface.LocatorWire;
pub const LocatorKind = transport_iface.LocatorKind;

const std = @import("std");

/// RTPS §9.6.1.1: default SPDP well-known multicast port for domain 0.
pub const SPDP_WELL_KNOWN_MULTICAST_PORT = 7400; // PB for domain 0

/// Construct the default SPDP well-known multicast locator for a given domain.
/// group_base is the first three octets of the multicast group (e.g. 239.255.0).
/// The fourth octet is (domain_id & 0xFF) + 1 (common convention).
pub fn spdpMulticastLocator(group_base: [3]u8, domain_id: u32, port: u16) Locator {
    return Locator.udp4(.{
        group_base[0],
        group_base[1],
        group_base[2],
        @as(u8, @intCast((domain_id & 0xFF) + 1)),
    }, port);
}

// ── Conversion helpers ────────────────────────────────────────────────────────

/// Convert a zidl-generated `Locator_t` value to a native `Locator`.
///
/// The generated type (from rtps_discovery.idl) uses `port_number` instead of
/// `port` to avoid the IDL 4.2 reserved keyword. This function bridges the gap
/// without importing the generated module into the core RTPS layer.
///
/// Usage:
///   const loc = locator.fromRtpsLocatorT(lt);
///
/// Reverse direction (Locator → Locator_t fields):
///   const w = loc.toRtpsWire();
///   const lt = GeneratedLocatorT{ .kind = w.kind, .port_number = w.port, .address = w.address };
pub inline fn fromRtpsLocatorT(lt: anytype) Locator {
    const wire = LocatorWire{ .kind = lt.kind, .port = lt.port_number, .address = lt.address };
    return wire.toLocator();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Locator.udp4 addr and port" {
    const loc = Locator.udp4(.{ 192, 168, 1, 100 }, 7400);
    try std.testing.expect(loc == .udp_v4);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 100 }, loc.udp_v4.addr);
    try std.testing.expectEqual(@as(u16, 7400), loc.udp_v4.port);
}

test "Locator.invalid is tagged .invalid" {
    const loc = Locator.invalid;
    try std.testing.expect(loc == .invalid);
}

test "Locator.eql" {
    const a = Locator.udp4(.{ 10, 0, 0, 1 }, 7400);
    const b = Locator.udp4(.{ 10, 0, 0, 1 }, 7400);
    const c = Locator.udp4(.{ 10, 0, 0, 2 }, 7400);
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(.invalid));
}

test "Locator.isMulticast" {
    try std.testing.expect(Locator.udp4(.{ 239, 255, 0, 1 }, 7400).isMulticast());
    try std.testing.expect(!Locator.udp4(.{ 10, 0, 0, 1 }, 7400).isMulticast());
}

test "Locator round-trips through LocatorWire (udp4)" {
    const orig = Locator.udp4(.{ 192, 168, 1, 5 }, 7411);
    const wire = orig.toRtpsWire();
    try std.testing.expectEqual(LocatorKind.udp_v4, wire.kind);
    try std.testing.expectEqual(@as(u32, 7411), wire.port);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 5 }, wire.address[12..16].*);
    const back = wire.toLocator();
    try std.testing.expect(orig.eql(back));
}

test "LocatorWire preserves unknown locator kinds as custom" {
    const wire = LocatorWire{
        .kind = 0x4000_0001,
        .port = 7411,
        .address = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 192, 168, 1, 5 },
    };
    const loc = wire.toLocator();

    try std.testing.expect(loc == .custom);
    try std.testing.expectEqual(@as(i32, 0x4000_0001), loc.wireKind());
    try std.testing.expect(loc.isOpaqueCustom());
    try std.testing.expect(!loc.isInvalidOrReserved());
    try std.testing.expectEqual(wire, loc.toRtpsWire());
}

test "Locator reserved and invalid classification" {
    const invalid: Locator = .invalid;
    try std.testing.expect(invalid.isInvalidOrReserved());
    try std.testing.expect(!invalid.isOpaqueCustom());

    const reserved = (LocatorWire{
        .kind = LocatorKind.reserved,
        .port = 0,
        .address = std.mem.zeroes([16]u8),
    }).toLocator();
    try std.testing.expect(reserved == .custom);
    try std.testing.expect(reserved.isOpaqueCustom());
    try std.testing.expect(reserved.isInvalidOrReserved());
    try std.testing.expectEqual(LocatorKind.reserved, reserved.wireKind());
}

test "spdpMulticastLocator domain 0 → 239.255.0.1" {
    const loc = spdpMulticastLocator(.{ 239, 255, 0 }, 0, 7400);
    try std.testing.expectEqual([4]u8{ 239, 255, 0, 1 }, loc.udp_v4.addr);
}

test "spdpMulticastLocator domain 5 → 239.255.0.6" {
    const loc = spdpMulticastLocator(.{ 239, 255, 0 }, 5, 7400);
    try std.testing.expectEqual([4]u8{ 239, 255, 0, 6 }, loc.udp_v4.addr);
}

test "fromRtpsLocatorT bridges generated Locator_t to native Locator" {
    // Simulate a zidl-generated Locator_t (same fields, port_number instead of port).
    const lt = struct { kind: i32, port_number: u32, address: [16]u8 }{
        .kind = LocatorKind.udp_v4,
        .port_number = 7411,
        .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 192, 168, 1, 5 },
    };
    const loc = fromRtpsLocatorT(lt);
    try std.testing.expect(loc == .udp_v4);
    try std.testing.expectEqual(@as(u16, 7411), loc.udp_v4.port);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 5 }, loc.udp_v4.addr);
}

test "fromRtpsLocatorT → toRtpsWire round-trips cleanly" {
    const orig = Locator.udp4(.{ 10, 0, 0, 1 }, 7400);
    const w = orig.toRtpsWire();
    // Simulate Locator → Locator_t → Locator round-trip.
    const lt = struct { kind: i32, port_number: u32, address: [16]u8 }{
        .kind = w.kind,
        .port_number = w.port,
        .address = w.address,
    };
    try std.testing.expect(orig.eql(fromRtpsLocatorT(lt)));
}
