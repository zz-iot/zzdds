//! Tests for the C-ABI TypeSupport registration shim.
//!
//! Verifies that zzdds_register_type_support_c correctly bridges a C-style
//! compute_key_hash function pointer into the Zig TypeSupport infrastructure.

const std = @import("std");
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const zidl_rt = @import("zidl_rt");

const c_abi_ts = zzdds.c_abi.typesupport;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const noop_security = zzdds.noop_security.noop_security_plugins;
const nil = zzdds.dcps;

// ── C-style compute_key_hash_from_cdr stub ───────────────────────────────────
//
// Simulates what `zidl -b c` generates: copies payload bytes [4..8] (after
// the 4-byte encap header) directly into the first 4 bytes of the hash.

fn stubComputeKeyHashFromCdr(
    payload: [*]const u8,
    len: usize,
    hash_out: *[16]u8,
) callconv(.c) c_int {
    hash_out.* = std.mem.zeroes([16]u8);
    if (len < 8) return -1;
    hash_out.*[0] = payload[4];
    hash_out.*[1] = payload[5];
    hash_out.*[2] = payload[6];
    hash_out.*[3] = payload[7];
    return 0;
}

// ── Minimal fixture ───────────────────────────────────────────────────────────

const MemoryTransport = zzdds.intraprocess.MemoryTransport;
const DirectDiscovery = zzdds.intraprocess.DirectDiscovery;

const Fixture = struct {
    delivery: IntraProcessDelivery,
    t: *MemoryTransport,
    d: *DirectDiscovery,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,
    /// Boxed C-ABI handle for `dp` -- what a real C caller actually has
    /// (zzdds_c.h's DDS_DomainParticipant is an opaque pointer, not the
    /// native {ptr, vtable} fat pointer). zzdds_register_type_support_c must
    /// be exercised with *this*, not `dp` directly, or the test never
    /// catches a C-ABI signature mismatch (it previously didn't: passing
    /// `dp` natively happened to typecheck against the function's old,
    /// incorrect `participant: DDS.DomainParticipant` signature, masking a
    /// real bug that crashed every actual C caller).
    dp_boxed: *anyopaque,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        const factory = try DomainParticipantFactoryImpl.init(
            alloc,
            t.transport(),
            d.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory.deinit();
        const dp = factory.toDDSFactory().create_participant(0, .{}, null, 0);
        const dp_boxed = try zidl_rt.boxEntity(alloc, dp.ptr, dp.vtable);
        return .{ .delivery = delivery, .t = t, .d = d, .factory = factory, .dp = dp, .dp_boxed = dp_boxed, .alloc = alloc };
    }

    fn deinit(self: *Fixture) void {
        zidl_rt.freeEntityBox(self.alloc, self.dp_boxed);
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        self.factory.deinit();
        self.d.deinit();
        self.t.deinit();
        self.delivery.deinit();
    }

    fn impl(self: *Fixture) *DomainParticipantImpl {
        return @ptrCast(@alignCast(self.dp.ptr));
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "c_abi TypeSupport: zzdds_register_type_support_c wires compute_key_hash" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const rc = c_abi_ts.zzdds_register_type_support_c(
        fx.dp_boxed,
        "TestType",
        stubComputeKeyHashFromCdr,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("TestType");
    try testing.expect(ts != null);

    // Payload: 4-byte encap + 4-byte key 0x01020304 in LE.
    // The stub copies payload[4..8] verbatim → hash[0..4] = {04, 03, 02, 01}.
    const payload = [_]u8{
        0x00, 0x07, 0x00, 0x00, // encap: XCDR2 LE
        0x04, 0x03, 0x02, 0x01, // id = 0x01020304 LE
    };
    const hash = ts.?.compute_key_hash(ts.?.ctx, &payload);
    try testing.expectEqual(@as(u8, 0x04), hash[0]);
    try testing.expectEqual(@as(u8, 0x03), hash[1]);
    try testing.expectEqual(@as(u8, 0x02), hash[2]);
    try testing.expectEqual(@as(u8, 0x01), hash[3]);
    try testing.expectEqualSlices(u8, &std.mem.zeroes([12]u8), hash[4..]);
}

test "c_abi TypeSupport: NULL compute_key_hash registers zeroed-hash fallback" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const rc = c_abi_ts.zzdds_register_type_support_c(
        fx.dp_boxed,
        "KeylessType",
        null,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("KeylessType");
    try testing.expect(ts != null);

    const payload = [_]u8{ 0x00, 0x07, 0x00, 0x00, 0xFF };
    const hash = ts.?.compute_key_hash(ts.?.ctx, &payload);
    try testing.expectEqualSlices(u8, &std.mem.zeroes([16]u8), &hash);
}
