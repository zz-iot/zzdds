// Bounded codec evidence only; this is not broker admission validation.
const std = @import("std");
const rt = @import("zidl_rt");
const wire = @import("wire").BrokerWireDraft;
const testing = std.testing;

fn encode(comptime T: type, value: T) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    var w = rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try w.writeEncapHeader();
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
    var r = try rt.CdrReader.init(bytes);
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

test "snapshot end digest and target roundtrip; truncation rejects" {
    const value: wire.ViewEnd = .{ .view_generation = 4, .store_cut = 12, .record_count = 2, .digest = @splat(0xab), .ready_through_delivery_seq = 27 };
    const bytes = try encode(wire.ViewEnd, value);
    defer testing.allocator.free(bytes);
    var r = try rt.CdrReader.init(bytes);
    var out: wire.ViewEnd = .{};
    try wire.ViewEnd.deserializeInto(&out, &r, testing.allocator);
    try testing.expectEqualDeep(value, out);
    var short = try rt.CdrReader.init(bytes[0 .. bytes.len - 1]);
    try testing.expectError(error.EndOfStream, wire.ViewEnd.deserializeInto(&out, &short, testing.allocator));
}

fn syncBytes(extra_required: ?bool, missing: bool, duplicate: bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    var w = rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try w.writeEncapHeader();
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
    var r = try rt.CdrReader.init(optional);
    var out: wire.ViewSync = .{};
    try wire.ViewSync.deserializeInto(&out, &r, testing.allocator);
    try testing.expectEqual(@as(u64, 5), out.view_generation);
    try testing.expectEqual(@as(u64, 23), out.ready_through_delivery_seq);
    const required = try syncBytes(true, false, false);
    defer testing.allocator.free(required);
    var rr = try rt.CdrReader.init(required);
    try testing.expectError(error.UnknownMustUnderstand, wire.ViewSync.deserializeInto(&out, &rr, testing.allocator));
}

test "characterization: missing and duplicate members need admission validation" {
    const missing = try syncBytes(null, true, false);
    defer testing.allocator.free(missing);
    var r = try rt.CdrReader.init(missing);
    var out: wire.ViewSync = .{};
    try wire.ViewSync.deserializeInto(&out, &r, testing.allocator);
    try testing.expectEqual(@as(u64, 0), out.ready_through_delivery_seq);
    const duplicate = try syncBytes(null, false, true);
    defer testing.allocator.free(duplicate);
    var rr = try rt.CdrReader.init(duplicate);
    try wire.ViewSync.deserializeInto(&out, &rr, testing.allocator);
    try testing.expectEqual(@as(u64, 99), out.view_generation);
    // These accepted malformed shapes are a documented production blocker, not
    // the intended future broker policy. Update this characterization when fixed.
}

test "bounded sequence representation footprint is explicit" {
    try testing.expect(@sizeOf(wire.Frame) >= 1048576);
    try testing.expect(@sizeOf(wire.OriginRecord) >= 524288);
}

test "presence proof decodes a populated bounded sequence of structs" {
    var value: wire.PresenceProof = .{ .view_generation = 8, .challenge_nonce = @splat(3), .chunk_count = 1, .view_delivery_seq = 27, .query_serial = 12 };
    value.entries.appendAssumeCapacity(.{ .participant_guid = @splat(4), .incarnation_id = @splat(5), .freshness_generation = 9, .remaining_lease_ns = 123456, .availability = wire.PRESENCE_AVAILABLE });
    value.entries.appendAssumeCapacity(.{ .participant_guid = @splat(6), .incarnation_id = @splat(7), .availability = wire.PRESENCE_UNAVAILABLE });
    const bytes = try encode(wire.PresenceProof, value);
    defer testing.allocator.free(bytes);
    var r = try rt.CdrReader.init(bytes);
    var out: wire.PresenceProof = .{};
    try wire.PresenceProof.deserializeInto(&out, &r, testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.entries.slice().len);
    try testing.expectEqual(value.view_delivery_seq, out.view_delivery_seq);
    try testing.expectEqual(value.query_serial, out.query_serial);
    try testing.expectEqualDeep(value.entries.slice()[0], out.entries.slice()[0]);
    try testing.expectEqualDeep(value.entries.slice()[1], out.entries.slice()[1]);
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
    value.* = .{ .magic = "ZZDBRK01".*, .major_version = 1, .operation_code = operation, .encoding_id = 1 };
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
    if (!std.mem.eql(u8, bytes[4..12], "ZZDBRK01")) return error.InvalidFrame;
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
    env.* = .{ .broker_epoch = @splat(0x11), .session_id = @splat(0x22), .owner_generation = 9, .request_id = @splat(0x33) };
    env.scope.domain_id = 7;
    env.scope.domain_tag.appendAssumeCapacity('r');
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
    var reader = try rt.CdrReader.init(actual);
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

fn recordDigest(label: []const u8, records: []const []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(label);
    var n: [8]u8 = undefined;
    std.mem.writeInt(u64, &n, @intCast(records.len), .little);
    h.update(&n);
    for (records) |record| {
        std.mem.writeInt(u64, &n, @intCast(record.len), .little);
        h.update(&n);
        h.update(record);
    }
    return h.finalResult();
}

fn expectDigest(actual: [32]u8, expected_text: []const u8) !void {
    const expected = try hexBytes(expected_text);
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, &actual);
}

test "OriginRecord golden preserves payload bytes and domain-separated digests" {
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
    try expectDigest(recordDigest("zzdds-broker/snapshot/v1\x00", &.{}), @embedFile("broker_golden/empty_snapshot.sha256"));
    try expectDigest(recordDigest("zzdds-broker/inventory/v1\x00", &.{golden}), @embedFile("broker_golden/one_origin_inventory.sha256"));
    try expectDigest(recordDigest("zzdds-broker/snapshot/v1\x00", &.{golden}), @embedFile("broker_golden/one_origin_snapshot.sha256"));
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
        var reader = try rt.CdrReader.init(bytes);
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
    var reader = try rt.CdrReader.init(bytes);
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
            .snapshot_cut = 41, .snapshot_digest = @splat(9),
            .applied_delivery_seq = 57, .baseline_retained = true,
        },
    };
    const bytes = try encode(wire.ViewRequest, value);
    defer testing.allocator.free(bytes);
    var reader = try rt.CdrReader.init(bytes);
    var decoded: wire.ViewRequest = .{};
    try wire.ViewRequest.deserializeInto(&decoded, &reader, testing.allocator);
    try testing.expectEqualDeep(value, decoded);
    var short_reader = try rt.CdrReader.init(bytes[0 .. bytes.len - 1]);
    try testing.expectError(error.EndOfStream, wire.ViewRequest.deserializeInto(&decoded, &short_reader, testing.allocator));
}


test "presence budgets roundtrip in HELLO and empty proof is explicit" {
    var offer: wire.LegacyHello = .{};
    offer.receive_limits.maximum_presence_queries = 2;
    offer.receive_limits.maximum_presence_entries = 1024;
    offer.receive_limits.maximum_presence_chunks = 8;
    offer.receive_limits.maximum_presence_bytes = 65536;
    const bytes = try encode(wire.LegacyHello, offer);
    defer testing.allocator.free(bytes);
    var reader = try rt.CdrReader.init(bytes);
    var decoded: wire.LegacyHello = .{};
    try wire.LegacyHello.deserializeInto(&decoded, &reader, testing.allocator);
    try testing.expectEqualDeep(offer.receive_limits, decoded.receive_limits);
    const proof: wire.PresenceProof = .{
        .view_generation = 1, .challenge_nonce = @splat(5),
        .chunk_count = 1, .chunk_index = 0, .view_delivery_seq = 0, .query_serial = 1,
    };
    const proof_bytes = try encode(wire.PresenceProof, proof);
    defer testing.allocator.free(proof_bytes);
    var proof_reader = try rt.CdrReader.init(proof_bytes);
    var out: wire.PresenceProof = .{};
    try wire.PresenceProof.deserializeInto(&out, &proof_reader, testing.allocator);
    try testing.expectEqual(@as(u32, 1), out.chunk_count);
    try testing.expectEqual(@as(usize, 0), out.entries.slice().len);
}


test "presence query carries independent serial and nonce" {
    const value: wire.PresenceQuery = .{
        .view_generation = 4, .challenge_nonce = @splat(7),
        .full_view = true, .query_serial = 23,
    };
    const bytes = try encode(wire.PresenceQuery, value);
    defer testing.allocator.free(bytes);
    var reader = try rt.CdrReader.init(bytes);
    var decoded: wire.PresenceQuery = .{};
    try wire.PresenceQuery.deserializeInto(&decoded, &reader, testing.allocator);
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
        var reader = try rt.CdrReader.init(&encoded);
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
    var ctx_reader = try rt.CdrReader.init(ctx_bytes);
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
    var reader = try rt.CdrReader.init(bytes);
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
            var reader = try rt.CdrReader.init(encoded);
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
            .maximum_presence_queries = 2, .maximum_presence_entries = 32,
            .maximum_presence_chunks = 4, .maximum_presence_bytes = 8192,
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
    var reader = try rt.CdrReader.init(encoded);
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
    inline for (.{ false, true }) |large| {
        var req = registrationFixture();
        req.scope.domain_tag.clearRetainingCapacity();
        for (0..if (large) @as(usize, 256) else 8) |_| req.scope.domain_tag.appendAssumeCapacity('r');
        if (large) req.resume_hint = .{ .baseline_retained = true, .view_generation = 9 };
        const feature_count: usize = if (large) 128 else 2;
        for (0..feature_count) |i| req.selected_features.appendAssumeCapacity(@intCast(i + 1));
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
        std.debug.print("\ncurrent bootstrap large={any} features={d} REGISTER/ACCEPT/PATH Frames={any}\n", .{large, feature_count, sizes});
    }
}
