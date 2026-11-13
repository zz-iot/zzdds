//! Tests for the C-ABI TypeSupport registration shim.
//!
//! Verifies that zzdds_register_type_support correctly bridges a C-style
//! compute_key_hash/compute_key_hash_key_only function pointer into the Zig
//! TypeSupport infrastructure.

const std = @import("std");
const test_domain = @import("test_domain");
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const zidl_bindings = @import("zidl_bindings");

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

// Distinguishable from stubComputeKeyHashFromCdr above by construction (a
// constant tag in hash[15], never written by the full-payload stub) -- proves
// which of the two slots a given call actually reached.
fn stubComputeKeyHashFromCdrKeyOnly(
    payload: [*]const u8,
    len: usize,
    hash_out: *[16]u8,
) callconv(.c) c_int {
    hash_out.* = std.mem.zeroes([16]u8);
    if (len < 5) return -1;
    hash_out.*[0] = payload[4];
    hash_out.*[15] = 0xC0;
    return 0;
}

// ── Minimal fixture ───────────────────────────────────────────────────────────

const MemoryTransport = zzdds.intraprocess.MemoryTransport;
const DirectDiscovery = zzdds.intraprocess.DirectDiscovery;

pub const Fixture = struct {
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

    pub fn init(alloc: std.mem.Allocator) !Fixture {
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
        const dp = factory.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const dp_boxed = try zidl_bindings.boxEntity(alloc, dp.ptr, &DomainParticipantImpl.views);
        return .{ .delivery = delivery, .t = t, .d = d, .factory = factory, .dp = dp, .dp_boxed = dp_boxed, .alloc = alloc };
    }

    pub fn deinit(self: *Fixture) void {
        zidl_bindings.freeEntityBox(self.alloc, self.dp_boxed);
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        self.factory.deinit();
        self.d.deinit();
        self.t.deinit();
        self.delivery.deinit();
    }

    pub fn impl(self: *Fixture) *DomainParticipantImpl {
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

test "c_abi TypeSupport: zzdds_register_type_support wires compute_key_hash_key_only separately from compute_key_hash" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const rc = c_abi_ts.zzdds_register_type_support(
        fx.dp_boxed,
        "KeyOnlyType",
        stubComputeKeyHashFromCdr,
        stubComputeKeyHashFromCdrKeyOnly,
        null,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("KeyOnlyType");
    try testing.expect(ts != null);
    try testing.expect(ts.?.compute_key_hash_key_only != null);

    // A genuine key-only payload: no 4-byte encap header, just the key byte
    // at offset 4 the way stubComputeKeyHashFromCdrKeyOnly reads it (this
    // test only needs to prove which stub got called, not a real CDR shape).
    const payload = [_]u8{ 0, 0, 0, 0, 0x2A };
    const full_hash = ts.?.compute_key_hash(ts.?.ctx, &payload);
    const key_only_hash = ts.?.compute_key_hash_key_only.?(ts.?.ctx, &payload);

    // stubComputeKeyHashFromCdrKeyOnly requires len >= 5; the full-payload
    // stub requires len >= 8, so it returns a zeroed hash for this payload --
    // itself already proof the two are wired to different functions, and the
    // 0xC0 tag confirms which one actually ran.
    try testing.expectEqualSlices(u8, &std.mem.zeroes([16]u8), &full_hash);
    try testing.expectEqual(@as(u8, 0x2A), key_only_hash[0]);
    try testing.expectEqual(@as(u8, 0xC0), key_only_hash[15]);
}

test "c_abi TypeSupport: NULL compute_key_hash_key_only_fn falls back to zero hash" {
    // TypeSupport.compute_key_hash_key_only itself is always the adapter
    // method here (same pattern as the required .compute_key_hash field
    // above it) -- it's the *C function pointer* that's null, and the
    // adapter checks that internally and returns a zero hash, same outcome
    // as resolveKeyHash's own "unset" fallback in dcps/participant.zig.
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    const rc = c_abi_ts.zzdds_register_type_support(
        fx.dp_boxed,
        "NoKeyOnlyType",
        stubComputeKeyHashFromCdr,
        null,
        null,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("NoKeyOnlyType");
    try testing.expect(ts != null);
    try testing.expect(ts.?.compute_key_hash_key_only != null);
    const payload = [_]u8{ 0, 0, 0, 0, 0x2A };
    const hash = ts.?.compute_key_hash_key_only.?(ts.?.ctx, &payload);
    try testing.expectEqualSlices(u8, &std.mem.zeroes([16]u8), &hash);
}

test "c_abi TypeSupport: NULL participant handle returns error instead of crashing" {
    // Regression test: zidl_bindings.unboxAs dereferences its argument
    // unconditionally, so a literal NULL passed by a C caller (a normal,
    // expected "no object" value in C, not UB) must be caught before
    // unboxing, not after -- @ptrFromInt(0) constructs the same bit pattern
    // a real C caller's NULL would produce at the ABI boundary.
    const rc = c_abi_ts.zzdds_register_type_support(
        makeNullHandle(),
        "TestType",
        stubComputeKeyHashFromCdr,
        null,
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

test "c_abi TypeSupport: zzdds_register_type_support_ctx wires compute_key_hash_key_only_fn separately, same ctx" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();

    var tag: u8 = 0xAB;
    const rc = c_abi_ts.zzdds_register_type_support_ctx(
        fx.dp_boxed,
        "CtxKeyOnlyType",
        stubComputeKeyHashCtx,
        stubComputeKeyHashCtx,
        null,
        &tag,
        null,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("CtxKeyOnlyType");
    try testing.expect(ts != null);
    try testing.expect(ts.?.compute_key_hash_key_only != null);

    // Same stub in both slots (it's ctx-only, no separate "key-only" shape
    // needed to prove the point) but a *different* payload byte per call --
    // proves compute_key_hash_key_only_fn is a real, independently-invoked
    // second call, not silently aliasing compute_key_hash_fn, while still
    // seeing the *same* ctx (tag) both times.
    const payload_a = [_]u8{0x11};
    const payload_b = [_]u8{0x22};
    const hash_a = ts.?.compute_key_hash(ts.?.ctx, &payload_a);
    const hash_b = ts.?.compute_key_hash_key_only.?(ts.?.ctx, &payload_b);
    try testing.expectEqual(@as(u8, 0xAB), hash_a[0]);
    try testing.expectEqual(@as(u8, 0x11), hash_a[1]);
    try testing.expectEqual(@as(u8, 0xAB), hash_b[0]);
    try testing.expectEqual(@as(u8, 0x22), hash_b[1]);
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
        null,
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
        null,
    );
    try testing.expectEqual(@as(c_int, 0), rc);

    const ts = fx.impl().type_support_registry.get("NoFilterType");
    try testing.expect(ts != null);
    try testing.expect(ts.?.get_field == null);
}

test "typesupport C ABI: registration allocation failure destroys each adapter exactly once" {
    for ([_]bool{ false, true }) |with_context| {
        // Adapter succeeds; fail either the owned type-name copy or map growth.
        for ([_]usize{ 1, 2 }) |fail_index| {
            var fx = try Fixture.init(testing.allocator);
            defer fx.deinit();
            var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
            fx.impl().alloc = failing.allocator();
            const Cleanup = struct {
                calls: usize = 0,
                fn destroy(ctx: ?*anyopaque) callconv(.c) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx.?));
                    self.calls += 1;
                }
            };
            var cleanup = Cleanup{};
            const result = if (with_context)
                c_abi_ts.zzdds_register_type_support_ctx(fx.dp_boxed, "FailedRegistration", null, null, null, &cleanup, Cleanup.destroy)
            else
                c_abi_ts.zzdds_register_type_support(fx.dp_boxed, "FailedRegistration", null, null, null);
            fx.impl().alloc = testing.allocator;
            try testing.expectEqual(@as(c_int, -1), result);
            try testing.expectEqual(@as(u32, 0), fx.impl().type_support_registry.count());
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            try testing.expectEqual(@as(usize, if (with_context) 1 else 0), cleanup.calls);
        }
    }
}

fn checkedSample(payload: [*]const u8, len: usize, key_only: c_int, hash: *[16]u8) callconv(.c) c_int {
    if (len != 2 or payload[0] != @as(u8, if (key_only == 0) 1 else 2)) return -1;
    hash.* = @splat(0);
    hash[0] = payload[1];
    return 0;
}
fn checkedGuid(value: u8, kind: u8) zzdds.rtps.Guid {
    return .{ .prefix = .{ .bytes = @splat(value) }, .entity_id = .{ .entity_key = .{ 0, 0, value }, .entity_kind = kind } };
}

test "checked C registration rejects before DATA, fragment and prematch admission" {
    const rtps = zzdds.rtps;
    for ([_]bool{ false, true }) |reliable| {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();
        try testing.expectEqual(@as(c_int, 0), c_abi_ts.zzdds_register_type_support_checked(fx.dp_boxed, "Checked", checkedSample, 1, null));
        const ts = fx.impl().type_support_registry.get("Checked").?;
        const reader = try rtps.StatefulReader.init(testing.allocator, checkedGuid(61, 7), fx.t.transport(), .keep_all, 0, reliable);
        defer reader.deinit();
        reader.setSampleProcessor(ts.sample_processor);
        const Delivered = struct {
            count: usize = 0,
            fn onData(ctx: *anyopaque, change: *const rtps.CacheChange) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                std.debug.assert(std.mem.allEqual(u8, &change.key_hash, 0));
                self.count += 1;
            }
        };
        var delivered = Delivered{};
        reader.setCallback(.{ .ctx = &delivered, .on_data = Delivered.onData });
        const writer = checkedGuid(62, 2);
        try reader.addMatchedWriter(try rtps.WriterProxy.init(testing.allocator, writer, &.{}, &.{}, reliable));
        var change = rtps.CacheChange{ .kind = .alive, .writer_guid = writer, .sequence_number = 1, .source_timestamp = .zero, .instance_handle = @splat(0), .key_hash = @splat(0xcc), .data = &.{ 0xff, 0 } };
        try testing.expectError(error.InvalidSample, reader.handleData(writer, change));
        try testing.expect(!reader.writer_proxies.items[0].received.contains(1));
        try testing.expectEqual(@as(usize, 0), delivered.count);
        change.data = &.{ 1, 0 };
        try reader.handleData(writer, change);
        try testing.expect(reader.writer_proxies.items[0].received.contains(1));
        try testing.expectEqual(@as(usize, 1), delivered.count);
        var first = rtps.message.submessage.DataFragSubmessage{ .flags = 0, .reader_entity_id = rtps.EntityIds.unknown, .writer_entity_id = writer.entity_id, .writer_sn = 2, .fragment_starting_num = 1, .fragments_in_submessage = 1, .fragment_size = 1, .data_size = 2, .inline_qos = null, .serialized_payload = &.{0xff} };
        var second = first;
        second.fragment_starting_num = 2;
        second.serialized_payload = &.{0};
        try reader.handleDataFrag(writer, .zero, first);
        try testing.expectError(error.InvalidSample, reader.handleDataFrag(writer, .zero, second));
        try testing.expect(!reader.writer_proxies.items[0].received.contains(2));
        try testing.expectEqual(@as(u32, 0), reader.writer_proxies.items[0].reassembly.count());
        first.serialized_payload = &.{1};
        try reader.handleDataFrag(writer, .zero, first);
        try reader.handleDataFrag(writer, .zero, second);
        try testing.expectEqual(@as(usize, 2), delivered.count);
        const unmatched_writer = checkedGuid(63, 2);
        var cache = rtps.unmatched_cache.UnmatchedCache.init(testing.allocator, .{ .max_bytes = 1024, .max_writers = 4, .max_samples_per_writer = 4, .max_partials_per_writer = 4 });
        defer cache.deinit();
        change.writer_guid = unmatched_writer;
        change.data = &.{ 0xff, 0 };
        change.sequence_number = 1;
        cache.put(unmatched_writer, rtps.EntityIds.unknown, &change, true, 0, 1000000);
        _ = try reader.addOrRefreshMatchedWriterWith(try rtps.WriterProxy.init(testing.allocator, unmatched_writer, &.{}, &.{}, reliable), &.{ .cache = &cache }, null);
        try testing.expect(!reader.writer_proxies.items[1].received.contains(1));
        try testing.expectEqual(@as(usize, 2), delivered.count);
        const processor = ts.sample_processor.?;
        const inline_hash: [16]u8 = @splat(7);
        try testing.expectEqualSlices(u8, &inline_hash, &try processor.process(processor.ctx, &.{}, .not_alive_disposed, inline_hash));
        try testing.expectError(error.InvalidSample, processor.process(processor.ctx, &.{ 0xff, 0 }, .not_alive_disposed, inline_hash));
        const zero: [16]u8 = @splat(0);
        try testing.expectEqualSlices(u8, &zero, &try processor.process(processor.ctx, &.{ 2, 0 }, .not_alive_disposed, inline_hash));
    }
}

const CheckedContext = struct {
    destroyed: usize = 0,
    fn process(_: ?*anyopaque, payload: [*]const u8, len: usize, key_only: c_int, out: *[16]u8) callconv(.c) c_int {
        return checkedSample(payload, len, key_only, out);
    }
    fn destroy(ctx: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.destroyed += 1;
    }
};
test "checked contexts are immutable, idempotent and pinned through endpoint retirement" {
    var state = CheckedContext{};
    var fx = try Fixture.init(testing.allocator);
    var live = true;
    defer if (live) fx.deinit();
    try testing.expectEqual(@as(c_int, 0), c_abi_ts.zzdds_register_type_support_checked_ctx(fx.dp_boxed, "Pinned", CheckedContext.process, 0, null, &state, CheckedContext.destroy));
    try testing.expectEqual(@as(c_int, 0), c_abi_ts.zzdds_register_type_support_checked_ctx(fx.dp_boxed, "Pinned", CheckedContext.process, 0, null, &state, CheckedContext.destroy));
    try testing.expectEqual(@as(c_int, -1), c_abi_ts.zzdds_register_type_support_checked_ctx(fx.dp_boxed, "Pinned", CheckedContext.process, 1, null, &state, CheckedContext.destroy));
    try testing.expectEqual(@as(c_int, -1), c_abi_ts.zzdds_register_type_support(fx.dp_boxed, "Pinned", stubComputeKeyHashFromCdr, null, null));
    const processor = fx.impl().type_support_registry.get("Pinned").?.sample_processor.?;
    processor.retain.?(processor.ctx);
    fx.deinit();
    live = false;
    try testing.expectEqual(@as(usize, 0), state.destroyed);
    const zero: [16]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &zero, &try processor.process(processor.ctx, &.{ 1, 42 }, .alive, @splat(1)));
    try testing.expectError(error.InvalidSample, processor.process(processor.ctx, &.{ 0xff, 0 }, .alive, @splat(0)));
    processor.release.?(processor.ctx);
    try testing.expectEqual(@as(usize, 1), state.destroyed);
}

test "checked registration installs the processor on a real legacy DataReader" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    try testing.expectEqual(@as(c_int, 0), c_abi_ts.zzdds_register_type_support_checked(fx.dp_boxed, "CheckedReader", checkedSample, 1, null));
    const topic = fx.dp.create_topic("CheckedTopic", "CheckedReader", .{}, null, 0);
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const description = @as(*zzdds.dcps.TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();
    const reader = sub.create_datareader(description, .{}, null, 0);
    try testing.expect(reader.ptr != nil.NIL_PTR);
    const dr: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    var active = fx.impl().active_readers.valueIterator();
    var protocol: ?zzdds.protocol.ProtocolReader = null;
    while (active.next()) |entry| {
        if (std.mem.eql(u8, entry.type_name, "CheckedReader")) protocol = entry.proto;
    }
    const pr = protocol.?;
    const writer = checkedGuid(64, 2);
    _ = try pr.addMatchedWriter(&.{ .guid = writer, .unicast_locators = &.{}, .multicast_locators = &.{}, .reliability = .best_effort });
    pr.handleIncomingChange(writer, 1, .zero, @splat(0xcc), &.{ 0xff, 0 }, .alive, null, null, null, null);
    try testing.expectEqual(@as(usize, 0), dr.pending.items.len);
    pr.handleIncomingChange(writer, 1, .zero, @splat(0xcc), &.{ 1, 0 }, .alive, null, null, null, null);
    try testing.expectEqual(@as(usize, 1), dr.pending.items.len);
    // A conflicting or newly checked install must not alter an existing topic.
    const late = fx.dp.create_topic("LateCheckedTopic", "LateCheckedType", .{}, null, 0);
    try testing.expect(late.ptr != nil.NIL_PTR);
    try testing.expectEqual(@as(c_int, -1), c_abi_ts.zzdds_register_type_support_checked(fx.dp_boxed, "LateCheckedType", checkedSample, 1, null));
}

test "checked field getter contexts retain independent DataReader ownership" {
    const State = struct {
        destroyed: usize = 0,
        fn process(_: ?*anyopaque, payload: [*]const u8, len: usize, key_only: c_int, hash: *[16]u8) callconv(.c) c_int {
            return checkedSample(payload, len, key_only, hash);
        }
        fn field(_: ?*anyopaque, _: [*]const u8, _: usize, _: [*]const u8, _: usize, out: *c_abi_ts.ZzddsFilterValue, _: [*]u8, _: usize) callconv(.c) bool {
            out.* = .{ .kind = 0, .i = 42 };
            return true;
        }
        fn destroy(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.destroyed += 1;
        }
    };
    var state = State{};
    var fx = try Fixture.init(testing.allocator);
    var live = true;
    defer if (live) fx.deinit();
    try testing.expectEqual(@as(c_int, 0), c_abi_ts.zzdds_register_type_support_checked_ctx(fx.dp_boxed, "CheckedField", State.process, 1, State.field, &state, State.destroy));
    const topic = fx.dp.create_topic("CheckedFieldTopic", "CheckedField", .{}, null, 0);
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const td = @as(*zzdds.dcps.TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();
    const dr = sub.create_datareader(td, .{}, null, 0);
    const impl: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(dr.ptr));
    const getter = impl.get_field_fn.?;
    try testing.expect(getter.retain != null and getter.release != null);
    // Hold the same kind of reference a deferred reader operation owns.
    getter.retain.?(getter.ctx);
    fx.deinit();
    live = false;
    try testing.expectEqual(@as(usize, 0), state.destroyed);
    var scratch: [1]u8 = undefined;
    try testing.expectEqual(@as(i64, 42), getter.get(&.{}, "field", &scratch).?.int);
    getter.release.?(getter.ctx);
    try testing.expectEqual(@as(usize, 1), state.destroyed);
}
