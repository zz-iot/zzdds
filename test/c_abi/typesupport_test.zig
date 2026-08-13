//! Tests for the C-ABI TypeSupport registration shim.
//!
//! Verifies that zzdds_register_type_support correctly bridges a C-style
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

/// Constructs a genuinely NULL *anyopaque -- what a real C caller passing
/// NULL for a handle parameter actually produces at the `.c` calling
/// convention boundary. `@ptrFromInt(0)` alone is rejected by Zig's own
/// pointer-safety checks (comptime and runtime) since `*anyopaque` is a
/// non-optional, non-allowzero type; `@setRuntimeSafety(false)` opts out of
/// that check specifically to construct the exact input the ABI boundary
/// itself does not (and cannot) enforce against.
fn makeNullHandle() *anyopaque {
    @setRuntimeSafety(false);
    var addr: usize = 0;
    addr += 0;
    return @ptrFromInt(addr);
}

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
    /// native {ptr, vtable} fat pointer). zzdds_register_type_support must
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
        const dp_boxed = try zidl_rt.boxEntity(alloc, dp.ptr, &DomainParticipantImpl.views);
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

test "c_abi TypeSupport: zzdds_register_type_support wires compute_key_hash" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const rc = c_abi_ts.zzdds_register_type_support(
        fx.dp_boxed,
        "TestType",
        stubComputeKeyHashFromCdr,
        null,
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

test "c_abi TypeSupport: NULL participant handle returns error instead of crashing" {
    // Regression test: zidl_rt.unboxAs dereferences its argument
    // unconditionally, so a literal NULL passed by a C caller (a normal,
    // expected "no object" value in C, not UB) must be caught before
    // unboxing, not after -- @ptrFromInt(0) constructs the same bit pattern
    // a real C caller's NULL would produce at the ABI boundary.
    const rc = c_abi_ts.zzdds_register_type_support(
        makeNullHandle(),
        "TestType",
        stubComputeKeyHashFromCdr,
        null,
    );
    try testing.expectEqual(@as(c_int, -1), rc);
}

// ── ctx-carrying variant ──────────────────────────────────────────────────────
//
// Simulates a binding (e.g. Java/JNI) that can't generate a fresh, uniquely
// addressed native function per registered type -- one shared C function,
// disambiguated only by the ctx it's given.

fn stubComputeKeyHashCtx(ctx: ?*anyopaque, payload: [*]const u8, len: usize, hash_out: *[16]u8) callconv(.c) c_int {
    const tag: *const u8 = @ptrCast(@alignCast(ctx.?));
    hash_out.* = std.mem.zeroes([16]u8);
    if (len < 1) return -1;
    hash_out.*[0] = tag.*; // prove *this* ctx (not some other registration's) was used
    hash_out.*[1] = payload[0];
    return 0;
}

var ctx_deinit_calls: u32 = 0;

fn stubCtxDeinit(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    ctx_deinit_calls += 1;
}

test "c_abi TypeSupport: zzdds_register_type_support_ctx forwards ctx to every call" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    var tag: u8 = 0xAB;
    const rc = c_abi_ts.zzdds_register_type_support_ctx(
        fx.dp_boxed,
        "CtxType",
        stubComputeKeyHashCtx,
        null,
        &tag,
        null,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("CtxType");
    try testing.expect(ts != null);
    const payload = [_]u8{0x42};
    const hash = ts.?.compute_key_hash(ts.?.ctx, &payload);
    try testing.expectEqual(@as(u8, 0xAB), hash[0]);
    try testing.expectEqual(@as(u8, 0x42), hash[1]);
}

test "c_abi TypeSupport: ctx_deinit fires on replace and on participant deinit" {
    ctx_deinit_calls = 0;
    var tag: u8 = 1;
    {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();

        try testing.expectEqual(@as(c_int, 0), c_abi_ts.zzdds_register_type_support_ctx(
            fx.dp_boxed,
            "ReplacedType",
            stubComputeKeyHashCtx,
            null,
            &tag,
            stubCtxDeinit,
        ));
        try testing.expectEqual(@as(u32, 0), ctx_deinit_calls);

        // Re-registering the same type_name replaces the entry -- the OLD
        // registration's ctx_deinit must fire (see
        // DomainParticipantImpl.registerTypeSupport's replace path).
        try testing.expectEqual(@as(c_int, 0), c_abi_ts.zzdds_register_type_support_ctx(
            fx.dp_boxed,
            "ReplacedType",
            stubComputeKeyHashCtx,
            null,
            &tag,
            stubCtxDeinit,
        ));
        try testing.expectEqual(@as(u32, 1), ctx_deinit_calls);
    }
    // fx.deinit() destroys the participant -- the still-installed second
    // registration's ctx_deinit must fire too.
    try testing.expectEqual(@as(u32, 2), ctx_deinit_calls);
}

test "c_abi TypeSupport: ctx_deinit variant NULL participant handle returns error instead of crashing" {
    var tag: u8 = 0;
    const rc = c_abi_ts.zzdds_register_type_support_ctx(
        makeNullHandle(),
        "TestType",
        stubComputeKeyHashCtx,
        null,
        &tag,
        null,
    );
    try testing.expectEqual(@as(c_int, -1), rc);
}

test "c_abi TypeSupport: NULL compute_key_hash registers zeroed-hash fallback" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const rc = c_abi_ts.zzdds_register_type_support(
        fx.dp_boxed,
        "KeylessType",
        null,
        null,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("KeylessType");
    try testing.expect(ts != null);

    const payload = [_]u8{ 0x00, 0x07, 0x00, 0x00, 0xFF };
    const hash = ts.?.compute_key_hash(ts.?.ctx, &payload);
    try testing.expectEqualSlices(u8, &std.mem.zeroes([16]u8), &hash);
}

// ── get_field_from_cdr wiring ─────────────────────────────────────────────────
//
// Simulates what `zidl -b c` generates: reads a fake 1-byte "x" field at
// payload offset 4 (after the 4-byte encap header) when asked for field "x",
// otherwise reports no match. Exercises the scratch-buffer contract on a
// second, string-valued field ("name") to prove a real caller must copy into
// `scratch` rather than return a pointer into a local.

fn stubGetFieldFromCdr(
    payload: [*]const u8,
    payload_len: usize,
    field: [*]const u8,
    field_len: usize,
    out: *c_abi_ts.ZzddsFilterValue,
    scratch: [*]u8,
    scratch_len: usize,
) callconv(.c) bool {
    const field_name = field[0..field_len];
    if (std.mem.eql(u8, field_name, "x")) {
        if (payload_len < 5) return false;
        out.* = .{ .kind = 0, .i = payload[4] };
        return true;
    }
    if (std.mem.eql(u8, field_name, "name")) {
        // Deliberately materialize into a local first (as a real generated
        // deserializer would), then copy out of it -- proving the adapter's
        // contract (copy into `scratch`, don't point into a local) is
        // actually exercised, not just declared.
        const local_name = [_]u8{ 'R', 'E', 'D' };
        if (scratch_len < local_name.len) return false;
        @memcpy(scratch[0..local_name.len], &local_name);
        out.* = .{ .kind = 2, .s_ptr = scratch, .s_len = local_name.len };
        return true;
    }
    return false;
}

test "c_abi TypeSupport: zzdds_register_type_support wires get_field_from_cdr" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const rc = c_abi_ts.zzdds_register_type_support(
        fx.dp_boxed,
        "FilterableType",
        stubComputeKeyHashFromCdr,
        stubGetFieldFromCdr,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("FilterableType");
    try testing.expect(ts != null);
    try testing.expect(ts.?.get_field != null);

    const payload = [_]u8{
        0x00, 0x07, 0x00, 0x00, // encap: XCDR2 LE
        0x2A, // x = 42
    };
    var scratch: [64]u8 = undefined;

    const x_val = ts.?.get_field.?(ts.?.ctx, &payload, "x", &scratch);
    try testing.expect(x_val != null);
    try testing.expectEqual(@as(i64, 42), x_val.?.int);

    const name_val = ts.?.get_field.?(ts.?.ctx, &payload, "name", &scratch);
    try testing.expect(name_val != null);
    try testing.expectEqualStrings("RED", name_val.?.string);

    const missing_val = ts.?.get_field.?(ts.?.ctx, &payload, "nope", &scratch);
    try testing.expect(missing_val == null);
}

test "c_abi TypeSupport: NULL get_field_from_cdr leaves TypeSupport.get_field unset" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const rc = c_abi_ts.zzdds_register_type_support(
        fx.dp_boxed,
        "NoFilterType",
        stubComputeKeyHashFromCdr,
        null,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("NoFilterType");
    try testing.expect(ts != null);
    try testing.expect(ts.?.get_field == null);
}
