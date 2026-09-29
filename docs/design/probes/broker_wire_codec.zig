// Bounded codec evidence only; this is not broker admission validation.
const std = @import("std");
const rt = @import("zidl_rt");
const wire = @import("wire").BrokerWireDraft;
const testing = std.testing;

// These synthetic standalone headers label nested-body fixtures. Production
// broker bodies inherit XCDR2 from Frame and carry no encapsulation header.
// The general runtime reader does not currently accept PL_CDR2_LE; initialize
// its nested-body context explicitly here, without changing runtime support.
fn fixtureReader(bytes: []const u8) !rt.CdrReader {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], &.{ 0, 0x0b, 0, 0 })) {
        return .{ .data = bytes, .pos = 4, .byte_order = .little, .xcdr_version = .xcdr2, .is_pl_cdr = false };
    }
    return rt.CdrReader.init(bytes);
}

fn encode(comptime T: type, value: T) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    var w = rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try w.writeEncapHeader();
    if (T == wire.AcceptReply or T == wire.RegisterRequest or T == wire.AdmissionReject or T == wire.PathChallenge) buf.items[1] = 0x0b;
    try T.serialize(&w, value);
    return buf.toOwnedSlice(testing.allocator);
}

test "ACCEPT preserves independent recovery fields and optional cursor" {
    var value: wire.AcceptReply = .{};
    value.admission_attempt = @splat(9);
    value.session_id = @splat(7);
    value.owner_generation = 42;
    value.origin_inventory_required = true;
    value.downstream_outcome = wire.DOWNSTREAM_RESUME_ACCEPTED;
    value.resumed_cursor = .{ .view_generation = 3, .applied_delivery_seq = 19, .baseline_retained = true };
    const bytes = try encode(wire.AcceptReply, value);
    defer testing.allocator.free(bytes);
    var r = try fixtureReader(bytes);
    var out: wire.AcceptReply = .{};
    try wire.AcceptReply.deserializeInto(&out, &r, testing.allocator);
    try testing.expectEqual(value.owner_generation, out.owner_generation);
    try testing.expectEqualSlices(u8, &value.session_id, &out.session_id);
    try testing.expect(out.origin_inventory_required);
    try testing.expectEqual(wire.DOWNSTREAM_RESUME_ACCEPTED, out.downstream_outcome);
    try testing.expectEqual(@as(u64, 19), out.resumed_cursor.?.applied_delivery_seq);
    const again = try encode(wire.AcceptReply, out);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

test "snapshot end count and target roundtrip; truncation rejects" {
    const value: wire.ViewEnd = .{ .view_generation = 4, .store_cut = 12, .record_count = 2, .ready_through_delivery_seq = 27 };
    const bytes = try encode(wire.ViewEnd, value);
    defer testing.allocator.free(bytes);
    var r = try fixtureReader(bytes);
    var out: wire.ViewEnd = .{};
    try wire.ViewEnd.deserializeInto(&out, &r, testing.allocator);
    try testing.expectEqualDeep(value, out);
    var short = try fixtureReader(bytes[0 .. bytes.len - 1]);
    try testing.expectError(error.EndOfStream, wire.ViewEnd.deserializeInto(&out, &short, testing.allocator));
}

fn syncBytes(extra_required: ?bool, missing: bool, duplicate: bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    var w = rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try w.writeEncapHeader();
    buf.items[1] = 0x0b; // test-only mutable PL_CDR2_LE
    const dh = try w.reserveDheader();
    try w.writeEmheaderFixed(1, true, 3);
    try w.writeU64(5);
    if (!missing) {
        try w.writeEmheaderFixed(2, true, 3);
        try w.writeU64(23);
    }
    if (duplicate) {
        try w.writeEmheaderFixed(1, true, 3);
        try w.writeU64(99);
    }
    if (extra_required) |mu| {
        try w.writeEmheaderFixed(101, mu, 2);
        try w.writeU32(1234);
    }
    w.patchDheader(dh);
    return buf.toOwnedSlice(testing.allocator);
}

test "old body decoder skips new optional field and rejects new required field" {
    const optional = try syncBytes(false, false, false);
    defer testing.allocator.free(optional);
    var r = try fixtureReader(optional);
    var out: @import("wire").BrokerCodecProbe.Evolution = .{};
    try @import("wire").BrokerCodecProbe.Evolution.deserializeInto(&out, &r, testing.allocator);
    try testing.expectEqual(@as(u64, 5), out.view_generation);
    try testing.expectEqual(@as(u64, 23), out.ready_through_delivery_seq);
    const required = try syncBytes(true, false, false);
    defer testing.allocator.free(required);
    var rr = try fixtureReader(required);
    try testing.expectError(error.UnknownMustUnderstand, @import("wire").BrokerCodecProbe.Evolution.deserializeInto(&out, &rr, testing.allocator));
}

test "characterization: missing and duplicate members need admission validation" {
    const missing = try syncBytes(null, true, false);
    defer testing.allocator.free(missing);
    var r = try fixtureReader(missing);
    var out: @import("wire").BrokerCodecProbe.Evolution = .{};
    try @import("wire").BrokerCodecProbe.Evolution.deserializeInto(&out, &r, testing.allocator);
    try testing.expectEqual(@as(u64, 0), out.ready_through_delivery_seq);
    const duplicate = try syncBytes(null, false, true);
    defer testing.allocator.free(duplicate);
    var rr = try fixtureReader(duplicate);
    try @import("wire").BrokerCodecProbe.Evolution.deserializeInto(&out, &rr, testing.allocator);
    try testing.expectEqual(@as(u64, 99), out.view_generation);
    // These accepted malformed shapes are a documented production blocker, not
    // the intended future broker policy. Update this characterization when fixed.
}

test "bounded sequence representation footprint is explicit" {
    try testing.expect(@sizeOf(wire.Frame) >= 1048576);
    try testing.expect(@sizeOf(wire.OriginRecord) >= 524288);
}

test "freshness marker decodes a populated bounded sequence of structs" {
    var value: wire.FreshnessMarker = .{ .view_generation = 8, .challenge_nonce = @splat(3), .view_delivery_seq = 27, .common_remaining_lease_ns = 500000 };
    value.exceptions.appendAssumeCapacity(.{ .participant_guid = @splat(4), .incarnation_id = @splat(5), .remaining_lease_ns = 123456 });
    value.exceptions.appendAssumeCapacity(.{ .participant_guid = @splat(6), .incarnation_id = @splat(7) });
    const bytes = try encode(wire.FreshnessMarker, value);
    defer testing.allocator.free(bytes);
    var r = try fixtureReader(bytes);
    var out: wire.FreshnessMarker = .{};
    try wire.FreshnessMarker.deserializeInto(&out, &r, testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.exceptions.slice().len);
    try testing.expectEqual(value.view_delivery_seq, out.view_delivery_seq);
    try testing.expectEqual(value.common_remaining_lease_ns, out.common_remaining_lease_ns);
    try testing.expectEqualDeep(value.exceptions.slice()[0], out.exceptions.slice()[0]);
    try testing.expectEqualDeep(value.exceptions.slice()[1], out.exceptions.slice()[1]);
}

fn hexBytes(text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    const out = try testing.allocator.alloc(u8, trimmed.len / 2);
    errdefer testing.allocator.free(out);
    _ = try std.fmt.hexToBytes(out, trimmed);
    return out;
}

fn framed(operation: u16, body: []const u8) ![]u8 {
    const value = try testing.allocator.create(wire.Frame);
    defer testing.allocator.destroy(value);
    value.* = .{ .magic = "ZZDBRK03".*, .major_version = 1, .operation_code = operation, .encoding_id = 1 };
    for (body) |b| value.body.appendAssumeCapacity(b);
    const unpadded = try encode(wire.Frame, value.*);
    defer testing.allocator.free(unpadded);
    const padding = (4 - unpadded.len % 4) % 4;
    const result = try testing.allocator.alloc(u8, unpadded.len + padding);
    @memcpy(result[0..unpadded.len], unpadded);
    @memset(result[unpadded.len..], 0);
    result[3] = @intCast(padding);
    return result;
}

// Fixture-only bounded, borrowed Frame validator; not full broker admission.
fn frameBody(bytes: []const u8, maximum: usize) ![]const u8 {
    if (bytes.len > maximum or bytes.len < 24) return error.InvalidFrame;
    if (!std.mem.eql(u8, bytes[0..3], &.{ 0, 7, 0 }) or bytes[3] > 3) return error.InvalidFrame;
    if (!std.mem.eql(u8, bytes[4..12], "ZZDBRK03")) return error.InvalidFrame;
    if (std.mem.readInt(u16, bytes[12..14], .little) != 1 or std.mem.readInt(u16, bytes[14..16], .little) != 0) return error.InvalidFrame;
    if (std.mem.readInt(u16, bytes[18..20], .little) != 1) return error.InvalidFrame;
    const n: usize = std.mem.readInt(u32, bytes[20..24], .little);
    if (n > bytes.len - 24) return error.InvalidFrame;
    const pad = (4 - n % 4) % 4;
    if (bytes[3] != pad or bytes.len - 24 - n != pad) return error.InvalidFrame;
    for (bytes[24 + n ..]) |b| if (b != 0) return error.InvalidFrame;
    return bytes[24 .. 24 + n];
}

test "VIEW_SYNC body and final Frame match independent golden bytes" {
    const encoded = try encode(wire.ViewSync, .{ .view_generation = 5, .ready_through_delivery_seq = 23 });
    defer testing.allocator.free(encoded);
    const body = try hexBytes(@embedFile("broker_golden/view_sync_body.hex"));
    defer testing.allocator.free(body);
    try testing.expectEqualSlices(u8, body, encoded[4..]); // no inner encapsulation
    const env = try testing.allocator.create(wire.Envelope);
    defer testing.allocator.destroy(env);
    env.* = .{ .request_id = @splat(0x33) };
    for (body) |b| env.operation_body.appendAssumeCapacity(b);
    const env_bytes = try encode(wire.Envelope, env.*);
    defer testing.allocator.free(env_bytes);
    const env_golden = try hexBytes(@embedFile("broker_golden/view_sync_envelope.hex"));
    defer testing.allocator.free(env_golden);
    try testing.expectEqualSlices(u8, env_golden, env_bytes[4..]);
    const actual = try framed(wire.OP_VIEW_SYNC, env_bytes[4..]);
    defer testing.allocator.free(actual);
    const golden = try hexBytes(@embedFile("broker_golden/view_sync_frame.hex"));
    defer testing.allocator.free(golden);
    try testing.expectEqualSlices(u8, golden, actual);
    try testing.expectEqualSlices(u8, env_golden, try frameBody(actual, 1048600));
    var reader = try fixtureReader(actual);
    const decoded = try testing.allocator.create(wire.Frame);
    defer testing.allocator.destroy(decoded);
    decoded.* = .{};
    try wire.Frame.deserializeInto(decoded, &reader, testing.allocator);
    try testing.expectEqualSlices(u8, env_golden, decoded.body.slice());
}

test "Frame padding golden and malformed boundaries" {
    const actual = try framed(wire.OP_STATUS, &.{ 0x10, 0x20, 0x30 });
    defer testing.allocator.free(actual);
    const golden = try hexBytes(@embedFile("broker_golden/padding_frame.hex"));
    defer testing.allocator.free(golden);
    try testing.expectEqualSlices(u8, golden, actual);
    _ = try frameBody(actual, actual.len);
    try testing.expectError(error.InvalidFrame, frameBody(actual, actual.len - 1));
    try testing.expectError(error.InvalidFrame, frameBody(actual[0 .. actual.len - 1], actual.len));
    for ([_]usize{ 1, 2, 3, 4, 12, 14, 18, 20, 27 }) |offset| {
        const saved = actual[offset];
        actual[offset] ^= 0x80;
        try testing.expectError(error.InvalidFrame, frameBody(actual, actual.len));
        actual[offset] = saved;
    }
    std.mem.writeInt(u32, actual[20..24], 0xffffffff, .little);
    try testing.expectError(error.InvalidFrame, frameBody(actual, actual.len));
}

test "OriginRecord golden preserves original payload bytes" {
    const record = try testing.allocator.create(wire.OriginRecord);
    defer testing.allocator.destroy(record);
    record.* = .{};
    var guid: [16]u8 = undefined;
    for (0..12) |i| guid[i] = @intCast(i);
    @memcpy(guid[12..], &[_]u8{ 0, 0, 1, 0xc1 });
    record.entity = .{ .participant_guid = guid, .incarnation_id = @splat(0x11), .record_kind = wire.RECORD_PARTICIPANT, .entity_guid = guid };
    record.origin_revision = 1;
    record.change_kind = wire.CHANGE_UPSERT;
    record.discovery_encoding = 1;
    record.origin_protocol_version = .{ 2, 5 };
    record.origin_vendor_id = .{ 3, 0 };
    for ([_]u8{ 0, 0, 0, 0 }) |b| record.change_metadata.appendAssumeCapacity(b);
    for ([_]u8{ 0, 3, 0, 0, 1, 0, 0, 0 }) |b| record.discovery_payload.appendAssumeCapacity(b);
    const bytes = try encode(wire.OriginRecord, record.*);
    defer testing.allocator.free(bytes);
    const golden = try hexBytes(@embedFile("broker_golden/origin_record.hex"));
    defer testing.allocator.free(golden);
    try testing.expectEqualSlices(u8, golden, bytes[4..]);
}


test "metadata list matches independent endian-preserving golden values" {
    const list = try testing.allocator.create(wire.MetadataList);
    defer testing.allocator.destroy(list);
    const le = [_]u8{ 1, 0x71, 0, 4, 0, 0, 0, 0, 1, 1, 0, 0, 0 };
    const be = [_]u8{ 0, 0, 0x71, 0, 4, 0, 0, 0, 1, 0, 1, 0, 0 };
    const goldens = [_][]const u8{
        @embedFile("broker_golden/metadata_le.hex"),
        @embedFile("broker_golden/metadata_be.hex"),
    };
    for ([_][]const u8{ &le, &be }, goldens) |inline_qos, golden_text| {
        list.* = .{};
        const values = [_][]const u8{ &.{ 2, 0 }, &.{ 0, 0, 0, 1 }, inline_qos };
        for (values, 1..) |value, tag| {
            var entry: wire.MetadataEntry = .{ .tag = @intCast(tag), .required = true };
            for (value) |b| entry.value.appendAssumeCapacity(b);
            list.entries.appendAssumeCapacity(entry);
        }
        const bytes = try encode(wire.MetadataList, list.*);
        defer testing.allocator.free(bytes);
        const golden = try hexBytes(golden_text);
        defer testing.allocator.free(golden);
        try testing.expectEqualSlices(u8, golden, bytes[4..]);
        var reader = try fixtureReader(bytes);
        const decoded = try testing.allocator.create(wire.MetadataList);
        defer testing.allocator.destroy(decoded);
        decoded.* = .{};
        try wire.MetadataList.deserializeInto(decoded, &reader, testing.allocator);
        try testing.expectEqualSlices(u8, inline_qos, decoded.entries.slice()[2].value.slice());
    }
}

test "bootstrap endpoint octets use vendor no-key kinds" {
    const key = wire.BOOTSTRAP_ENTITY_KEY;
    const actual = [_]u8{
        @intCast(key >> 16), @truncate(key >> 8), @truncate(key), wire.BROKER_WRITER_KIND,
        @intCast(key >> 16), @truncate(key >> 8), @truncate(key), wire.BROKER_READER_KIND,
    };
    const golden = try hexBytes(@embedFile("broker_golden/bootstrap_endpoints.hex"));
    defer testing.allocator.free(golden);
    try testing.expectEqualSlices(u8, golden, &actual);
    try testing.expectEqual(@as(u8, 0x40), actual[3] & 0xc0);
    try testing.expectEqual(@as(u8, 0x40), actual[7] & 0xc0);
}


test "historical retired-OPEN rejection matches independent body and Frame golden bytes" {
    const value: wire.AdmissionReject = .{
        .admission_attempt = @splat(0x11),
        .client_nonce = @splat(0x22),
        .rejected_operation = wire.RESERVED_OP_OPEN,
        .reason = wire.ERROR_OWNER_CONFLICT,
        .retry_after_ns = 100000000,
        .request_digest = @splat(0x33),
    };
    const bytes = try encode(wire.AdmissionReject, value);
    defer testing.allocator.free(bytes);
    const golden = try hexBytes(@embedFile("broker_golden/admission_reject_body.hex"));
    defer testing.allocator.free(golden);
    try testing.expectEqualSlices(u8, golden, bytes[4..]);
    var reader = try fixtureReader(bytes);
    var decoded: wire.AdmissionReject = .{};
    try wire.AdmissionReject.deserializeInto(&decoded, &reader, testing.allocator);
    try testing.expectEqualDeep(value, decoded);
    const actual = try framed(wire.OP_ADMISSION_REJECT, bytes[4..]);
    defer testing.allocator.free(actual);
    const frame_golden = try hexBytes(@embedFile("broker_golden/admission_reject_frame.hex"));
    defer testing.allocator.free(frame_golden);
    try testing.expectEqualSlices(u8, frame_golden, actual);
    try testing.expectEqual(@as(usize, 144), actual.len);
}


test "view request separates new generation from retained resume cursor" {
    const value: wire.ViewRequest = .{
        .view_mode = wire.VIEW_ALL,
        .request_resume = true,
        .view_generation = 2,
        .cursor = .{
            .previous_epoch = @splat(7), .previous_session = @splat(8),
            .previous_owner_generation = 3, .view_generation = 19,
            .snapshot_cut = 41,
            .applied_delivery_seq = 57, .baseline_retained = true,
        },
    };
    const bytes = try encode(wire.ViewRequest, value);
    defer testing.allocator.free(bytes);
    var reader = try fixtureReader(bytes);
    var decoded: wire.ViewRequest = .{};
    try wire.ViewRequest.deserializeInto(&decoded, &reader, testing.allocator);
    try testing.expectEqualDeep(value, decoded);
    var short_reader = try fixtureReader(bytes[0 .. bytes.len - 1]);
    try testing.expectError(error.EndOfStream, wire.ViewRequest.deserializeInto(&decoded, &short_reader, testing.allocator));
}


test "freshness bounds roundtrip in REGISTER and empty marker is explicit" {
    var offer: wire.RegisterRequest = .{};
    offer.receive_limits.maximum_freshness_exceptions = 1024;
    offer.receive_limits.maximum_freshness_marker_bytes = 65536;
    const bytes = try encode(wire.RegisterRequest, offer);
    defer testing.allocator.free(bytes);
    var reader = try fixtureReader(bytes);
    var decoded: wire.RegisterRequest = .{};
    try wire.RegisterRequest.deserializeInto(&decoded, &reader, testing.allocator);
    try testing.expectEqualDeep(offer.receive_limits, decoded.receive_limits);
    const proof: wire.FreshnessMarker = .{
        .view_generation = 1, .challenge_nonce = @splat(5),
        .view_delivery_seq = 0, .common_remaining_lease_ns = 1000,
    };
    const proof_bytes = try encode(wire.FreshnessMarker, proof);
    defer testing.allocator.free(proof_bytes);
    var proof_reader = try fixtureReader(proof_bytes);
    var out: wire.FreshnessMarker = .{};
    try wire.FreshnessMarker.deserializeInto(&out, &proof_reader, testing.allocator);
    try testing.expectEqual(@as(u64, 1000), out.common_remaining_lease_ns);
    try testing.expectEqual(@as(usize, 0), out.exceptions.slice().len);
}


test "freshness query carries view and nonce" {
    const value: wire.FreshnessQuery = .{
        .view_generation = 4, .challenge_nonce = @splat(7),
    };
    const bytes = try encode(wire.FreshnessQuery, value);
    defer testing.allocator.free(bytes);
    var reader = try fixtureReader(bytes);
    var decoded: wire.FreshnessQuery = .{};
    try wire.FreshnessQuery.deserializeInto(&decoded, &reader, testing.allocator);
    try testing.expectEqualDeep(value, decoded);
}


fn originParameter(bytes: []const u8, endian: std.builtin.Endian) !?[]const u8 {
    var at: usize = 0;
    var found: ?[]const u8 = null;
    while (at < bytes.len) {
        if (bytes.len - at < 4) return error.InvalidParameter;
        const pid = std.mem.readInt(u16, bytes[at..][0..2], endian);
        const len = std.mem.readInt(u16, bytes[at + 2 ..][0..2], endian);
        at += 4;
        if (pid == 1) {
            if (len != 0 or at != bytes.len) return error.InvalidParameter;
            return found;
        }
        if (len % 4 != 0 or len > bytes.len - at) return error.InvalidParameter;
        if (pid == wire.PID_ZZDDS_ORIGIN_VERSION) {
            if (found != null or len != 24) return error.InvalidParameter;
            found = bytes[at .. at + len];
        }
        at += len;
    }
    return error.InvalidParameter;
}

test "origin version full and key-only inline fixtures preserve both byte orders" {
    const fulls = .{ @embedFile("broker_golden/origin_version_full_le.hex"), @embedFile("broker_golden/origin_version_full_be.hex") };
    const keys = .{ @embedFile("broker_golden/origin_version_key_le.hex"), @embedFile("broker_golden/origin_version_key_be.hex") };
    const inlines = .{ @embedFile("broker_golden/origin_version_inline_le.hex"), @embedFile("broker_golden/origin_version_inline_be.hex") };
    const values = .{ @embedFile("broker_golden/origin_version_value_le.hex"), @embedFile("broker_golden/origin_version_value_be.hex") };
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }, 0..) |endian, i| {
        const full = try hexBytes(fulls[i]);
        defer testing.allocator.free(full);
        const key = try hexBytes(keys[i]);
        defer testing.allocator.free(key);
        const iq = try hexBytes(inlines[i]);
        defer testing.allocator.free(iq);
        const expected = try hexBytes(values[i]);
        defer testing.allocator.free(expected);
        try testing.expectEqualSlices(u8, expected, (try originParameter(full[4..], endian)).?);
        try testing.expectEqualSlices(u8, expected, (try originParameter(iq, endian)).?);
        try testing.expect((try originParameter(key[4..], endian)) == null);
        try testing.expectEqual(@as(usize, 28), key.len); // encap, GUID PID/value, sentinel only
        var encoded: [28]u8 = undefined;
        @memcpy(encoded[0..4], &[_]u8{ 0, if (endian == .little) 1 else 0, 0, 0 });
        @memcpy(encoded[4..], expected);
        var reader = try fixtureReader(&encoded);
        var decoded: wire.OriginVersion = .{};
        try wire.OriginVersion.deserializeInto(&decoded, &reader, testing.allocator);
        try testing.expectEqual(@as(u64, 0x0102030405060708), decoded.origin_revision);
        for (decoded.incarnation_id, 1..) |b, n| try testing.expectEqual(@as(u8, @intCast(n)), b);
        if (endian == .little) {
            const written = try encode(wire.OriginVersion, decoded);
            defer testing.allocator.free(written);
            try testing.expectEqualSlices(u8, expected, written[4..]);
        }
        try testing.expectError(error.InvalidParameter, originParameter(iq[0 .. iq.len - 1], endian));
        const saved = iq[10];
        iq[10] = 0xff; // corrupt origin PID length
        try testing.expectError(error.InvalidParameter, originParameter(iq, endian));
        iq[10] = saved;
    }
}


test "SPDP service context and compact REGISTER roundtrip" {
    const context: wire.ServiceOfferContext = .{
        .descriptor_version = 1, .service_kind = wire.SERVICE_BROKER_DISCOVERY,
        .admission_attempt = @splat(1), .client_nonce = @splat(2),
        .introduction_id = @splat(3), .broker_epoch = @splat(4),
        .client_sample_digest = @splat(5), .server_sample_digest = @splat(6),
    };
    const ctx_bytes = try encode(wire.ServiceOfferContext, context);
    defer testing.allocator.free(ctx_bytes);
    var ctx_reader = try fixtureReader(ctx_bytes);
    var ctx_out: wire.ServiceOfferContext = .{};
    try wire.ServiceOfferContext.deserializeInto(&ctx_out, &ctx_reader, testing.allocator);
    try testing.expectEqualDeep(context, ctx_out);
    var req: wire.RegisterRequest = .{
        .introduction_id = context.introduction_id, .admission_attempt = context.admission_attempt,
        .client_nonce = context.client_nonce, .incarnation_id = @splat(7),
        .service_kind = wire.SERVICE_BROKER_DISCOVERY,
        .selected_major = 1, .selected_encoding = 1,
        .discovery_profile = wire.PROFILE_CACHED, .requested_view_mode = wire.VIEW_ALL,
    };
    req.control_endpoints.appendAssumeCapacity(.{ .channel_class = wire.CHANNEL_CONTROL });
    req.control_endpoints.appendAssumeCapacity(.{ .channel_class = wire.CHANNEL_STATE });
    req.resume_hint = .{ .baseline_retained = true, .view_generation = 9, .applied_delivery_seq = 13 };
    const bytes = try encode(wire.RegisterRequest, req);
    defer testing.allocator.free(bytes);
    var reader = try fixtureReader(bytes);
    var decoded: wire.RegisterRequest = .{};
    try wire.RegisterRequest.deserializeInto(&decoded, &reader, testing.allocator);
    try testing.expectEqualDeep(req, decoded);
    const frame = try framed(wire.OP_REGISTER, bytes[4..]);
    defer testing.allocator.free(frame);
    std.debug.print("\nnew REGISTER Frame bytes (empty domain tag, resume, two pairs): {d}\n", .{frame.len});
}

fn serviceHash(label: []const u8, blobs: []const []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(label);
    hash.update(&.{0});
    for (blobs) |blob| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(blob.len), .little);
        hash.update(&length);
        hash.update(blob);
    }
    return hash.finalResult();
}

test "native CDR1 service parameters and path hashes match independent fixtures" {
    inline for (.{"le", "be"}, 0..) |suffix, index| {
        inline for (.{wire.ServiceCapabilities, wire.ServiceRequestContext, wire.ServiceOfferContext}, .{"capabilities", "request", "offer"}) |T, name| {
            const value = try hexBytes(@embedFile("broker_golden/service_" ++ name ++ "_" ++ suffix ++ ".hex"));
            defer testing.allocator.free(value);
            const encoded = try testing.allocator.alloc(u8, value.len + 4);
            defer testing.allocator.free(encoded);
            @memcpy(encoded[0..4], &[_]u8{0, if (index == 0) 1 else 0, 0, 0});
            @memcpy(encoded[4..], value);
            var reader = try fixtureReader(encoded);
            var decoded: T = .{};
            try T.deserializeInto(&decoded, &reader, testing.allocator);
            try testing.expectEqual(@as(u16, 1), decoded.descriptor_version);
            if (index == 0) {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(testing.allocator);
                var writer = rt.CdrWriter(.xcdr1).init(&buf, testing.allocator);
                try writer.writeEncapHeader();
                try T.serialize(&writer, decoded);
                try testing.expectEqualSlices(u8, value, buf.items[4..]);
            } else {
                // Compare all decoded fields with the independent LE encoding too.
                const little = try hexBytes(@embedFile("broker_golden/service_" ++ name ++ "_le.hex"));
                defer testing.allocator.free(little);
                if (T != wire.ServiceOfferContext) {
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(testing.allocator);
                    var writer = rt.CdrWriter(.xcdr1).init(&buf, testing.allocator);
                    try writer.writeEncapHeader();
                    try T.serialize(&writer, decoded);
                    try testing.expectEqualSlices(u8, little, buf.items[4..]);
                }
            }
        }
        const client = try hexBytes(@embedFile("broker_golden/service_client_spdp_" ++ suffix ++ ".hex"));
        defer testing.allocator.free(client);
        const server = try hexBytes(@embedFile("broker_golden/service_server_spdp_" ++ suffix ++ ".hex"));
        defer testing.allocator.free(server);
        const iq = try hexBytes(@embedFile("broker_golden/service_request_inline_" ++ suffix ++ ".hex"));
        defer testing.allocator.free(iq);
        const client_digest = try hexBytes(@embedFile("broker_golden/service_client_digest_" ++ suffix ++ ".hex"));
        defer testing.allocator.free(client_digest);
        const server_digest = try hexBytes(@embedFile("broker_golden/service_server_digest_" ++ suffix ++ ".hex"));
        defer testing.allocator.free(server_digest);
        const path_digest = try hexBytes(@embedFile("broker_golden/service_path_digest_" ++ suffix ++ ".hex"));
        defer testing.allocator.free(path_digest);
        try testing.expectEqualSlices(u8, client_digest, &serviceHash("zzdds-broker/client-spdp/v1", &.{client}));
        try testing.expectEqualSlices(u8, server_digest, &serviceHash("zzdds-broker/server-spdp/v1", &.{server}));
        try testing.expectEqualSlices(u8, path_digest, &serviceHash("zzdds-broker/service-path/v1", &.{client, client[0..2], iq[4 .. iq.len - 4]}));
        const truncated_context = serviceHash("zzdds-broker/service-path/v1", &.{client, client[0..2], iq[4 .. iq.len - 7]});
        try testing.expect(!std.mem.eql(u8, path_digest, &truncated_context));
    }
}

fn registrationFixture() wire.RegisterRequest {
    var req: wire.RegisterRequest = .{
        .introduction_id = @splat(3), .admission_attempt = @splat(1), .client_nonce = @splat(2),
        .incarnation_id = @splat(7), .service_kind = 1, .selected_major = 1,
        .selected_encoding = 1, .discovery_profile = 1, .requested_view_mode = 1,
        .requested_lease_ns = 10_000_000_000,
        .receive_limits = .{
            .maximum_frame_bytes = 4096, .maximum_record_bytes = 2048,
            .maximum_inventory_bytes = 65536, .maximum_view_bytes = 65536,
            .maximum_records = 32, .maximum_orphan_items = 4, .maximum_orphan_bytes = 8192,
            .maximum_freshness_exceptions = 32,
            .maximum_freshness_marker_bytes = 8192,
        },
    };
    for ("realm") |b| req.scope.domain_tag.appendAssumeCapacity(b);
    req.scope.domain_id = 7;
    req.control_endpoints.appendAssumeCapacity(.{ .channel_class = 1, .writer_guid = @splat(8), .reader_guid = @splat(9) });
    req.control_endpoints.appendAssumeCapacity(.{ .channel_class = 2, .writer_guid = @splat(10), .reader_guid = @splat(11) });
    return req;
}

fn checkRegistrationGolden(comptime T: type, value: T, op: u16, comptime name: []const u8) !void {
    const encoded = try encode(T, value);
    defer testing.allocator.free(encoded);
    const body = try hexBytes(@embedFile("broker_golden/" ++ name ++ "_body.hex"));
    defer testing.allocator.free(body);
    try testing.expectEqualSlices(u8, body, encoded[4..]);
    const actual_frame = try framed(op, encoded[4..]);
    defer testing.allocator.free(actual_frame);
    const expected_frame = try hexBytes(@embedFile("broker_golden/" ++ name ++ "_frame.hex"));
    defer testing.allocator.free(expected_frame);
    try testing.expectEqualSlices(u8, expected_frame, actual_frame);
    var reader = try fixtureReader(encoded);
    var decoded: T = .{};
    try T.deserializeInto(&decoded, &reader, testing.allocator);
    try testing.expectEqualDeep(value, decoded);
}

test "REGISTER and both outcomes match independent bytes and exact-request hashes" {
    const req = registrationFixture();
    try checkRegistrationGolden(wire.RegisterRequest, req, wire.OP_REGISTER, "register");
    const encoded = try encode(wire.RegisterRequest, req);
    defer testing.allocator.free(encoded);
    const binding = serviceHash("zzdds-broker/register/v1", &.{&req.introduction_id, encoded[4..]});
    const expected_binding = try hexBytes(@embedFile("broker_golden/register_binding.hex"));
    defer testing.allocator.free(expected_binding);
    try testing.expectEqualSlices(u8, expected_binding, &binding);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zzdds-broker/rejected-request/v1\x00");
    var prefix: [10]u8 = undefined;
    std.mem.writeInt(u16, prefix[0..2], wire.OP_REGISTER, .little);
    std.mem.writeInt(u64, prefix[2..10], @intCast(encoded.len - 4), .little);
    hash.update(&prefix);
    hash.update(encoded[4..]);
    const rejected = hash.finalResult();
    const expected_rejected = try hexBytes(@embedFile("broker_golden/register_rejected_digest.hex"));
    defer testing.allocator.free(expected_rejected);
    try testing.expectEqualSlices(u8, expected_rejected, &rejected);
    const accept: wire.AcceptReply = .{
        .admission_attempt = req.admission_attempt, .introduction_id = req.introduction_id,
        .transcript_binding = binding, .scope = req.scope, .broker_epoch = @splat(4),
        .session_id = @splat(5), .owner_generation = 1, .selected_major = 1,
        .selected_encoding = 1, .selected_features = req.selected_features, .receive_limits = req.receive_limits,
        .origin_lease_ns = 10_000_000_000, .renewal_period_ns = 3_000_000_000,
        .establishment_timeout_ns = 5_000_000_000, .admission_retry_window_ns = 2_000_000_000,
        .control_endpoints = req.control_endpoints, .origin_inventory_required = true,
        .downstream_outcome = wire.DOWNSTREAM_SNAPSHOT_REQUIRED, .selected_profile = 1, .selected_view_mode = 1,
    };
    try checkRegistrationGolden(wire.AcceptReply, accept, wire.OP_ACCEPT, "register_accept");
    try checkRegistrationGolden(wire.AdmissionReject, .{
        .admission_attempt = req.admission_attempt, .client_nonce = req.client_nonce,
        .rejected_operation = wire.OP_REGISTER, .reason = wire.ERROR_LIMIT,
        .retry_after_ns = 100_000_000, .request_digest = rejected,
    }, wire.OP_ADMISSION_REJECT, "register_reject");
    var changed = req;
    changed.requested_lease_ns += 1;
    const changed_bytes = try encode(wire.RegisterRequest, changed);
    defer testing.allocator.free(changed_bytes);
    try testing.expect(!std.mem.eql(u8, &binding, &serviceHash("zzdds-broker/register/v1", &.{&req.introduction_id, changed_bytes[4..]})));
    try testing.expect(!std.mem.eql(u8, &binding, &serviceHash("zzdds-broker/register/v1", &.{&req.client_nonce, encoded[4..]})));
    // Encapsulation is not part of Frame.body, and must not accidentally enter this hash.
    try testing.expect(!std.mem.eql(u8, &binding, &serviceHash("zzdds-broker/register/v1", &.{&req.introduction_id, encoded})));
}

test "current bootstrap sizing covers domain tag resume feature and cookie bounds" {
    inline for (.{ @as(u8, 0), 1, 2 }) |variant| {
        const large = variant != 0;
        var req = registrationFixture();
        req.scope.domain_tag.clearRetainingCapacity();
        for (0..if (large) @as(usize, 256) else 8) |_| req.scope.domain_tag.appendAssumeCapacity('r');
        if (large) req.resume_hint = .{ .baseline_retained = true, .view_generation = 9 };
        const feature_count: usize = if (variant == 2) 128 else if (large) 3 else 2;
        req.selected_features.clearRetainingCapacity();
        for (0..feature_count) |i| req.selected_features.appendAssumeCapacity(if (variant == 1 and i == 2) 6 else @intCast(i + 1));
        const accept: wire.AcceptReply = .{
            .admission_attempt = req.admission_attempt, .introduction_id = req.introduction_id,
            .scope = req.scope, .selected_features = req.selected_features,
            .control_endpoints = req.control_endpoints, .resumed_cursor = req.resume_hint,
            .origin_inventory_required = true,
        };
        var challenge: wire.PathChallenge = .{ .admission_attempt = req.admission_attempt, .client_nonce = req.client_nonce };
        for (0..64) |_| challenge.cookie.appendAssumeCapacity(0xaa);
        var sizes: [3]usize = undefined;
        inline for (.{wire.RegisterRequest, wire.AcceptReply, wire.PathChallenge}, .{req, accept, challenge}, .{wire.OP_REGISTER, wire.OP_ACCEPT, wire.OP_PATH_CHALLENGE}, 0..) |T, value, op, i| {
            const bytes = try encode(T, value);
            defer testing.allocator.free(bytes);
            const frame = try framed(op, bytes[4..]);
            defer testing.allocator.free(frame);
            sizes[i] = frame.len;
        }
        std.debug.print("\nbootstrap sizing large={any} features={d} REGISTER/ACCEPT/PATH Frames={any}\n", .{large, feature_count, sizes});
    }
}

test "draft3 freshness bodies match independent vectors" {
    const q = try encode(wire.FreshnessQuery, .{ .view_generation = 8, .challenge_nonce = @splat(3) });
    defer testing.allocator.free(q);
    const qg = try hexBytes(@embedFile("broker_golden/freshness_query_body.hex"));
    defer testing.allocator.free(qg);
    try testing.expectEqualSlices(u8, qg, q[4..]);
    var marker: wire.FreshnessMarker = .{
        .view_generation = 8, .challenge_nonce = @splat(3),
        .view_delivery_seq = 27, .common_remaining_lease_ns = 500000,
    };
    const empty = try encode(wire.FreshnessMarker, marker);
    defer testing.allocator.free(empty);
    const eg = try hexBytes(@embedFile("broker_golden/freshness_empty_marker_body.hex"));
    defer testing.allocator.free(eg);
    try testing.expectEqualSlices(u8, eg, empty[4..]);
    marker.exceptions.appendAssumeCapacity(.{ .participant_guid = @splat(4), .incarnation_id = @splat(5), .remaining_lease_ns = 123456 });
    marker.exceptions.appendAssumeCapacity(.{ .participant_guid = @splat(6), .incarnation_id = @splat(7), .remaining_lease_ns = 0 });
    const full = try encode(wire.FreshnessMarker, marker);
    defer testing.allocator.free(full);
    const fg = try hexBytes(@embedFile("broker_golden/freshness_marker_body.hex"));
    defer testing.allocator.free(fg);
    try testing.expectEqualSlices(u8, fg, full[4..]);
}

// Fixture strict boundary: generated deserialization alone need not reject trailing bytes.
fn decodeFinalExact(comptime T: type, bytes: []const u8) !T {
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], &.{ 0, 7, 0, 0 })) return error.InvalidFrame;
    var reader = try fixtureReader(bytes);
    var value: T = .{};
    try T.deserializeInto(&value, &reader, testing.allocator);
    if (reader.remaining() != 0) return error.TrailingBytes;
    return value;
}
fn checkFinalGolden(comptime T: type, value: T, comptime name: []const u8) !void {
    const encoded = try encode(T, value);
    defer testing.allocator.free(encoded);
    const golden = try hexBytes(@embedFile("broker_golden/" ++ name ++ ".hex"));
    defer testing.allocator.free(golden);
    try testing.expectEqualSlices(u8, golden, encoded[4..]);
    try testing.expectEqualDeep(value, try decodeFinalExact(T, encoded));
    try testing.expectError(error.EndOfStream, decodeFinalExact(T, encoded[0 .. encoded.len - 1]));
    const extra = try testing.allocator.alloc(u8, encoded.len + 1);
    defer testing.allocator.free(extra);
    @memcpy(extra[0..encoded.len], encoded);
    extra[encoded.len] = 0;
    try testing.expectError(error.TrailingBytes, decodeFinalExact(T, extra));
}
test "draft3 final transaction and resume bodies have exact positional extent" {
    try checkFinalGolden(wire.InventoryEnd, .{ .inventory_generation = 3, .record_count = 2 }, "final_inventory_end");
    try checkFinalGolden(wire.ViewEnd, .{ .view_generation = 4, .store_cut = 12, .record_count = 2, .ready_through_delivery_seq = 27 }, "final_snapshot_end");
    try checkFinalGolden(wire.Applied, .{ .view_generation = 4, .snapshot_cut = 12, .applied_delivery_seq = 27 }, "final_applied");
    try checkFinalGolden(wire.ResumeCursor, .{ .previous_epoch = @splat(1), .previous_session = @splat(2), .previous_owner_generation = 3, .view_generation = 4, .snapshot_cut = 12, .applied_delivery_seq = 27, .baseline_retained = true }, "final_resume_cursor");
}
test "draft3 rejects previous frame magic and mutable VIEW_SYNC grammar" {
    const frame = try framed(wire.OP_VIEW_SYNC, &.{});
    defer testing.allocator.free(frame);
    frame[11] = '2';
    try testing.expectError(error.InvalidFrame, frameBody(frame, frame.len));
    frame[11] = '1';
    try testing.expectError(error.InvalidFrame, frameBody(frame, frame.len));
    const old = try syncBytes(null, false, false);
    defer testing.allocator.free(old);
    try testing.expectError(error.InvalidFrame, decodeFinalExact(wire.ViewSync, old));
    old[1] = 7; // relabeling the old mutable body cannot evade exact extent validation
    try testing.expectError(error.TrailingBytes, decodeFinalExact(wire.ViewSync, old));
}

test "final ErrorBody optional presence flags match independent bytes" {
    var value: wire.ErrorBody = .{ .error_code = 1, .recovery_action = 2, .related_request = @splat(3) };
    try checkFinalGolden(wire.ErrorBody, value, "final_error_absent");
    value.affected_entity = .{ .participant_guid = @splat(4), .incarnation_id = @splat(5), .record_kind = 1, .entity_guid = @splat(6) };
    value.affected_revision = 7;
    value.retry_after_ns = 8;
    try checkFinalGolden(wire.ErrorBody, value, "final_error_present");
}
