const std = @import("std");
const zzdds = @import("zzdds");
const iface = zzdds.transport;
const Locator = iface.Locator;
const LocatorKind = iface.LocatorKind;
const LocatorWire = iface.LocatorWire;
const LocatorTier = iface.LocatorTier;

const testing = std.testing;

// ── LocatorWire.toLocator ─────────────────────────────────────────────────────

test "LocatorWire.toLocator: invalid" {
    try testing.expectEqual(Locator.invalid, LocatorWire.invalid.toLocator());
}

test "LocatorWire.toLocator: udp_v4" {
    const w = LocatorWire{
        .kind = LocatorKind.udp_v4,
        .port = 7400,
        .address = [_]u8{0} ** 12 ++ [_]u8{ 192, 168, 1, 1 },
    };
    const loc = w.toLocator();
    try testing.expectEqual(
        Locator{ .udp_v4 = .{ .addr = .{ 192, 168, 1, 1 }, .port = 7400 } },
        loc,
    );
}

test "LocatorWire.toLocator: udp_v6" {
    var addr = [_]u8{0} ** 16;
    addr[0] = 0xFE;
    addr[15] = 1;
    const w = LocatorWire{ .kind = LocatorKind.udp_v6, .port = 7400, .address = addr };
    const loc = w.toLocator();
    try testing.expectEqual(
        Locator{ .udp_v6 = .{ .addr = addr, .port = 7400 } },
        loc,
    );
}

test "LocatorWire.toLocator: shmem" {
    var addr = [_]u8{0} ** 16;
    std.mem.writeInt(u64, addr[0..8], 0xDEAD_BEEF_1234_5678, .little);
    const w = LocatorWire{ .kind = LocatorKind.shmem, .port = 42, .address = addr };
    try testing.expectEqual(
        Locator{ .shmem = .{ .host_id = 0xDEAD_BEEF_1234_5678, .channel_id = 42 } },
        w.toLocator(),
    );
}

test "LocatorWire.toLocator: shmem_zc" {
    var addr = [_]u8{0} ** 16;
    std.mem.writeInt(u64, addr[0..8], 0x1122_3344_5566_7788, .little);
    addr[8] = 0xAA;
    addr[9] = 0xBB;
    addr[10] = 0xCC;
    addr[11] = 0xDD;
    const w = LocatorWire{ .kind = LocatorKind.shmem_zc, .port = 0, .address = addr };
    try testing.expectEqual(
        Locator{ .shmem_zc = .{
            .host_id = 0x1122_3344_5566_7788,
            .writer_entity = .{ 0xAA, 0xBB, 0xCC, 0xDD },
        } },
        w.toLocator(),
    );
}

test "LocatorWire.toLocator: custom (unknown kind)" {
    const w = LocatorWire{ .kind = 99, .port = 7, .address = [_]u8{0xDE} ** 16 };
    const loc = w.toLocator();
    const c = switch (loc) {
        .custom => |c| c,
        else => return error.WrongTag,
    };
    try testing.expectEqual(@as(i32, 99), c.kind);
    try testing.expectEqual(@as(u32, 7), c.port);
}

// ── Locator round-trip ────────────────────────────────────────────────────────

test "Locator.toRtpsWire: invalid maps to LocatorWire.invalid" {
    const inv: Locator = .invalid;
    try testing.expectEqual(LocatorWire.invalid, inv.toRtpsWire());
}

test "Locator.toRtpsWire round-trip: shmem" {
    const orig = Locator{ .shmem = .{ .host_id = 0xCAFE_F00D_0000_0001, .channel_id = 100 } };
    const wire = orig.toRtpsWire();
    try testing.expectEqual(orig, wire.toLocator());
}

test "Locator.toRtpsWire round-trip: shmem_zc" {
    const orig = Locator{ .shmem_zc = .{ .host_id = 0xABCD_EF01_0203_0405, .writer_entity = .{ 1, 2, 3, 4 } } };
    try testing.expectEqual(orig, orig.toRtpsWire().toLocator());
}

// ── Locator.isMulticast ───────────────────────────────────────────────────────

test "Locator.isMulticast: udp_v6 multicast (0xFF leading byte)" {
    const mc = Locator{ .udp_v6 = .{ .addr = [16]u8{ 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .port = 7400 } };
    try testing.expect(mc.isMulticast());
}

test "Locator.isMulticast: udp_v6 non-multicast" {
    const uc = Locator{ .udp_v6 = .{ .addr = [16]u8{ 0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .port = 7400 } };
    try testing.expect(!uc.isMulticast());
}

// ── Locator.tier ─────────────────────────────────────────────────────────────

test "Locator.tier: udp_v4 loopback (127.0.0.0/8)" {
    const loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);
    try testing.expectEqual(LocatorTier.loopback, loc.tier());
}

test "Locator.tier: udp_v4 link-local (169.254.0.0/16)" {
    const loc = Locator.udp4(.{ 169, 254, 1, 2 }, 7400);
    try testing.expectEqual(LocatorTier.link_local, loc.tier());
}

test "Locator.tier: udp_v4 private (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)" {
    try testing.expectEqual(LocatorTier.private, Locator.udp4(.{ 10, 1, 2, 3 }, 1).tier());
    try testing.expectEqual(LocatorTier.private, Locator.udp4(.{ 172, 16, 0, 1 }, 1).tier());
    try testing.expectEqual(LocatorTier.private, Locator.udp4(.{ 172, 31, 255, 255 }, 1).tier());
    try testing.expectEqual(LocatorTier.private, Locator.udp4(.{ 192, 168, 0, 1 }, 1).tier());
    // 172.15.x.x and 172.32.x.x are outside the /12 range and must not match.
    try testing.expectEqual(LocatorTier.public, Locator.udp4(.{ 172, 15, 0, 1 }, 1).tier());
    try testing.expectEqual(LocatorTier.public, Locator.udp4(.{ 172, 32, 0, 1 }, 1).tier());
}

test "Locator.tier: udp_v4 public" {
    const loc = Locator.udp4(.{ 8, 8, 8, 8 }, 53);
    try testing.expectEqual(LocatorTier.public, loc.tier());
}

test "Locator.tier: udp_v6 loopback (::1)" {
    var addr = [_]u8{0} ** 16;
    addr[15] = 1;
    try testing.expectEqual(LocatorTier.loopback, Locator.udp6(addr, 7400).tier());
}

test "Locator.tier: udp_v6 link-local (fe80::/10)" {
    var addr = [_]u8{0} ** 16;
    addr[0] = 0xFE;
    addr[1] = 0x80;
    try testing.expectEqual(LocatorTier.link_local, Locator.udp6(addr, 7400).tier());
}

test "Locator.tier: udp_v6 ULA (fc00::/7)" {
    var addr = [_]u8{0} ** 16;
    addr[0] = 0xFD;
    try testing.expectEqual(LocatorTier.private, Locator.udp6(addr, 7400).tier());
}

test "Locator.tier: udp_v6 public" {
    var addr = [_]u8{0} ** 16;
    addr[0] = 0x20;
    addr[1] = 0x01; // 2001:: — a real public documentation prefix range
    try testing.expectEqual(LocatorTier.public, Locator.udp6(addr, 7400).tier());
}

test "Locator.tier: shmem and shmem_zc are loopback" {
    const s = Locator{ .shmem = .{ .host_id = 1, .channel_id = 1 } };
    const sz = Locator{ .shmem_zc = .{ .host_id = 1, .writer_entity = .{ 0, 0, 0, 0 } } };
    try testing.expectEqual(LocatorTier.loopback, s.tier());
    try testing.expectEqual(LocatorTier.loopback, sz.tier());
}

test "Locator.tier: custom and invalid are public" {
    const inv: Locator = .invalid;
    const custom = Locator{ .custom = .{ .kind = 99, .port = 0, .address = [_]u8{0} ** 16 } };
    try testing.expectEqual(LocatorTier.public, inv.tier());
    try testing.expectEqual(LocatorTier.public, custom.tier());
}

// ── Locator.eql ──────────────────────────────────────────────────────────────

test "Locator.eql: equal and unequal" {
    const a = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 7400 } };
    const b = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 7400 } };
    const c = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 7401 } };
    const inv: Locator = .invalid;
    try testing.expect(Locator.eql(a, b));
    try testing.expect(!Locator.eql(a, c));
    try testing.expect(!Locator.eql(a, inv));
}

// ── Locator.wireKind ─────────────────────────────────────────────────────────

test "Locator.wireKind: all variants" {
    const inv: Locator = .invalid;
    try testing.expectEqual(LocatorKind.invalid, inv.wireKind());
    try testing.expectEqual(LocatorKind.udp_v4, (Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 1 } }).wireKind());
    try testing.expectEqual(LocatorKind.udp_v6, (Locator{ .udp_v6 = .{ .addr = [_]u8{0} ** 16, .port = 1 } }).wireKind());
    try testing.expectEqual(LocatorKind.shmem, (Locator{ .shmem = .{ .host_id = 0, .channel_id = 0 } }).wireKind());
    try testing.expectEqual(LocatorKind.shmem_zc, (Locator{ .shmem_zc = .{ .host_id = 0, .writer_entity = .{0} ** 4 } }).wireKind());
    try testing.expectEqual(@as(i32, 77), (Locator{ .custom = .{ .kind = 77, .port = 0, .address = [_]u8{0} ** 16 } }).wireKind());
}

// ── Locator.isOpaqueCustom ───────────────────────────────────────────────────

test "Locator.isOpaqueCustom: custom is opaque, others are not" {
    const inv: Locator = .invalid;
    try testing.expect((Locator{ .custom = .{ .kind = 99, .port = 0, .address = [_]u8{0} ** 16 } }).isOpaqueCustom());
    try testing.expect(!inv.isOpaqueCustom());
    try testing.expect(!(Locator{ .udp_v4 = .{ .addr = .{ 0, 0, 0, 0 }, .port = 0 } }).isOpaqueCustom());
}

// ── Locator.isInvalidOrReserved ───────────────────────────────────────────────

test "Locator.isInvalidOrReserved: custom with reserved kind" {
    const reserved = Locator{ .custom = .{ .kind = LocatorKind.reserved, .port = 0, .address = [_]u8{0} ** 16 } };
    try testing.expect(reserved.isInvalidOrReserved());
}

test "Locator.isInvalidOrReserved: custom with non-reserved kind is not reserved" {
    const custom = Locator{ .custom = .{ .kind = 99, .port = 0, .address = [_]u8{0} ** 16 } };
    try testing.expect(!custom.isInvalidOrReserved());
}
