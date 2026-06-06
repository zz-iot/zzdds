//! Fuzz target: RTPS message parser.
//!
//! Invariant: MessageIterator.init() + next() must never panic, access
//! out-of-bounds memory, or produce undefined behaviour for any input.
//! Malformed packets must return a ParseError, not a crash.
//!
//! Corpus regression tests run as part of `zig build test`.
//!
//! To run with libFuzzer:
//!   zig build-obj -OReleaseSafe test/fuzz/fuzz_rtps_parser.zig \
//!       -Mroot=test/fuzz/fuzz_rtps_parser.zig \
//!       --dep zzdds -Mzzdds=src/root.zig ...
//!   clang -fsanitize=fuzzer,address fuzz_rtps_parser.o -lc -o fuzz_rtps_parser
//!   ./fuzz_rtps_parser test/fuzz/corpus/rtps_parser/

const std = @import("std");
const zzdds = @import("zzdds");

const msg = zzdds.rtps.message;
const MessageIterator = msg.MessageIterator;
const InlineQosParam = msg.InlineQosParam;

/// The fuzzer entry point. Parses `data` as an RTPS message and iterates all
/// submessages. Returns silently on any parse error — only panics/crashes are bugs.
pub fn fuzzOne(data: []const u8) void {
    var params: [32]InlineQosParam = undefined;
    var it = MessageIterator.init(data) catch return;
    while (it.next(&params) catch return) |_| {}
}

fn replayCorpusDir() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, "test/fuzz/corpus/rtps_parser", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, "README.md")) continue;
        const data = try dir.readFileAlloc(io, entry.name, std.testing.allocator, std.Io.Limit.limited(1024 * 1024));
        defer std.testing.allocator.free(data);
        fuzzOne(data);
    }
}

/// libFuzzer entry point. Only called when this file is linked with libFuzzer.
/// In test binaries, this symbol is exported but never called.
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) i32 {
    fuzzOne(data[0..size]);
    return 0;
}

// ── Corpus regression tests ───────────────────────────────────────────────────
// These run under `zig build test` and guard against known-bad inputs.

// ── Valid RTPS header (20 bytes) ─────────────────────────────────────────────

const hdr = [_]u8{
    'R', 'T', 'P', 'S', // protocol ID
    0x02, 0x05, // version 2.5
    0x01, 0x0F, // vendor ID
} ++ [_]u8{0xAA} ** 12; // GUID prefix

// ── Submessage payloads ───────────────────────────────────────────────────────

// DATA (0x15), flags=E|D, body=24 bytes: extraFlags+qosOff+readerEid+writerEid+SN + 4B payload
const data_sm = [_]u8{
    0x15, 0x05, 0x18, 0x00, // id, flags, length=24 LE
    0x00, 0x00, 0x10, 0x00, // extraFlags=0, octetsToInlineQos=16
    0x00, 0x00, 0x00, 0x00, // reader entity ID
    0x00, 0x02, 0x00, 0x03, // writer entity ID
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, // SN {0,1} LE
    0x00, 0x01, 0x00, 0x00, // CDR LE encapsulation header
};

// HEARTBEAT (0x07), flags=E|F (both set → little-endian + final), body=28 bytes
const hb_sm = [_]u8{
    0x07, 0x03, 0x1C, 0x00, // id, flags=0x03 (E=1 LE, F=1 final), length=28 LE
    0x00, 0x00, 0x00, 0x00, // reader entity ID
    0x00, 0x02, 0x00, 0x03, // writer entity ID
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, // firstSN {0,1}
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, // lastSN  {0,2}
    0x01, 0x00, 0x00, 0x00, // count=1 LE
};

// ACKNACK (0x06), flags=E|F, body=24 bytes: rEid+wEid+SNSet(base+numBits=0)+count
const an_sm = [_]u8{
    0x06, 0x03, 0x18, 0x00, // id, flags, length=24 LE
    0x00, 0x00, 0x00, 0x00, // reader entity ID
    0x00, 0x02, 0x00, 0x03, // writer entity ID
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, // base SN {0,3}
    0x00, 0x00, 0x00, 0x00, // numBits=0 (empty bitmap)
    0x01, 0x00, 0x00, 0x00, // count=1 LE
};

// GAP (0x08), body=28 bytes: rEid+wEid+gapStart(8)+gapList(SNSet,base+numBits=0)
const gap_sm = [_]u8{
    0x08, 0x01, 0x1C, 0x00, // id, flags=E, length=28 LE
    0x00, 0x00, 0x00, 0x00, // reader entity ID
    0x00, 0x02, 0x00, 0x03, // writer entity ID
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, // gapStart SN {0,2}
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, // gapList.base {0,3}
    0x00, 0x00, 0x00, 0x00, // numBits=0
};

test "empty input returns TooShort" {
    const err = MessageIterator.init(&.{});
    try std.testing.expectError(error.TooShort, err);
}

test "partial header (4 bytes) returns TooShort" {
    const err = MessageIterator.init("RTPS");
    try std.testing.expectError(error.TooShort, err);
}

test "wrong protocol ID returns BadProtocolId" {
    var bad = hdr;
    bad[0] = 'X';
    const err = MessageIterator.init(&bad);
    try std.testing.expectError(error.BadProtocolId, err);
}

test "valid header, no submessages: next returns null" {
    var it = try MessageIterator.init(&hdr);
    var params: [32]InlineQosParam = undefined;
    const sm = try it.next(&params);
    try std.testing.expectEqual(@as(?msg.SubMessage, null), sm);
}

test "corpus files replay without crash" {
    try replayCorpusDir();
}

test "valid header + DATA: parses correctly" {
    const pkt = hdr ++ data_sm;
    var it = try MessageIterator.init(&pkt);
    var params: [32]InlineQosParam = undefined;
    const sm = try it.next(&params);
    try std.testing.expect(sm != null);
    try std.testing.expect(sm.? == .data);
    try std.testing.expectEqual(@as(i64, 1), sm.?.data.writer_sn);
}

test "valid header + HEARTBEAT: parses correctly" {
    const pkt = hdr ++ hb_sm;
    var it = try MessageIterator.init(&pkt);
    var params: [32]InlineQosParam = undefined;
    const sm = try it.next(&params);
    try std.testing.expect(sm != null);
    try std.testing.expect(sm.? == .heartbeat);
    try std.testing.expectEqual(@as(i64, 1), sm.?.heartbeat.first_sn);
    try std.testing.expectEqual(@as(i64, 2), sm.?.heartbeat.last_sn);
    try std.testing.expectEqual(@as(i32, 1), sm.?.heartbeat.count);
    try std.testing.expect(sm.?.heartbeat.isFinal());
}

test "valid header + ACKNACK: parses correctly" {
    const pkt = hdr ++ an_sm;
    var it = try MessageIterator.init(&pkt);
    var params: [32]InlineQosParam = undefined;
    const sm = try it.next(&params);
    try std.testing.expect(sm != null);
    try std.testing.expect(sm.? == .acknack);
    try std.testing.expectEqual(@as(i64, 3), sm.?.acknack.reader_sn_state.base);
    try std.testing.expect(sm.?.acknack.isFinal());
}

test "valid header + GAP: parses correctly" {
    const pkt = hdr ++ gap_sm;
    var it = try MessageIterator.init(&pkt);
    var params: [32]InlineQosParam = undefined;
    const sm = try it.next(&params);
    try std.testing.expect(sm != null);
    try std.testing.expect(sm.? == .gap);
}

test "valid header + multiple submessages" {
    const pkt = hdr ++ data_sm ++ hb_sm;
    var it = try MessageIterator.init(&pkt);
    var params: [32]InlineQosParam = undefined;
    const sm1 = try it.next(&params);
    try std.testing.expect(sm1 != null and sm1.? == .data);
    const sm2 = try it.next(&params);
    try std.testing.expect(sm2 != null and sm2.? == .heartbeat);
    const sm3 = try it.next(&params);
    try std.testing.expectEqual(@as(?msg.SubMessage, null), sm3);
}

test "submessage length exceeds remaining bytes: error, not OOB" {
    // Claim length=0xFFFF but there's no data after the submessage header.
    const pkt = hdr ++ [_]u8{ 0x15, 0x05, 0xFF, 0xFF };
    fuzzOne(&pkt); // must not crash
}

test "submessage length=0: end of message sentinel" {
    // length=0 means 'consume rest of message' in RTPS
    const pkt = hdr ++ [_]u8{ 0x15, 0x05, 0x00, 0x00 };
    fuzzOne(&pkt);
}

test "unknown submessage ID: skipped without crash" {
    const pkt = hdr ++ [_]u8{ 0xFE, 0x01, 0x00, 0x00 };
    fuzzOne(&pkt);
}

test "all-zeros after header: no crash" {
    const pkt = hdr ++ [_]u8{0x00} ** 64;
    fuzzOne(&pkt);
}

test "all-ones after header: no crash" {
    const pkt = hdr ++ [_]u8{0xFF} ** 64;
    fuzzOne(&pkt);
}
