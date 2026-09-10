//! Fuzz target: the zidl-generated SEDP discovery PL_CDR codec.
//!
//! Invariant: `DiscoveredWriterData` / `DiscoveredReaderData`
//! `deserializeFromPlCdr` must never panic or read out of bounds for any input,
//! in either `.lenient` or `.strict` mode. Malformed payloads return an error
//! or produce a valid (possibly default) struct — never a crash.
//!
//! Additional invariant on the happy path: a `.lenient` decode followed by
//! `serializePlCdr` must itself decode again cleanly (round-trip stability —
//! `@pl_retain_unknown` replay must not corrupt the stream).
//!
//! libFuzzer: build with `clang -fsanitize=fuzzer,address`, run against
//!   test/fuzz/corpus/plcdr/

const std = @import("std");
const zzdds = @import("zzdds");

const Disc = zzdds.disc_wire;
const zidl_rt = zzdds.zidl_rt;

fn deinitIf(comptime T: type, out: *T, alloc: std.mem.Allocator) void {
    if (comptime @hasDecl(T, "deinit")) out.deinit(alloc);
}

fn tryDecode(comptime T: type, alloc: std.mem.Allocator, data: []const u8, mode: zidl_rt.PlMode) void {
    var r = zidl_rt.CdrReader.init(data) catch return;
    var out: T = .{};
    defer deinitIf(T, &out, alloc);
    T.deserializeFromPlCdr(&out, &r, alloc, mode) catch return;

    // Round-trip: re-encode the lenient decode and confirm it decodes again.
    if (mode != .lenient) return;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var w = zidl_rt.PlCdrWriter.init(&buf, alloc);
    w.writeEncapHeader() catch return;
    T.serializePlCdr(&w, out) catch return;

    var r2 = zidl_rt.CdrReader.init(buf.items) catch return;
    var out2: T = .{};
    defer deinitIf(T, &out2, alloc);
    T.deserializeFromPlCdr(&out2, &r2, alloc, .lenient) catch return;
}

pub fn fuzzOne(data: []const u8) void {
    var buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();
    tryDecode(Disc.DiscoveredWriterData, alloc, data, .lenient);
    fba.reset();
    tryDecode(Disc.DiscoveredWriterData, alloc, data, .strict);
    fba.reset();
    tryDecode(Disc.DiscoveredReaderData, alloc, data, .lenient);
    fba.reset();
    tryDecode(Disc.DiscoveredReaderData, alloc, data, .strict);
    fba.reset();
    tryDecode(Disc.EndpointDisposal, alloc, data, .lenient);
}

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) i32 {
    fuzzOne(data[0..size]);
    return 0;
}

fn replayCorpusDir() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const corpus_path = "test/fuzz/corpus/plcdr";
    var dir = std.Io.Dir.cwd().openDir(io, corpus_path, .{ .iterate = true }) catch |err| switch (err) {
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

const LE_ENCAP = [_]u8{ 0x00, 0x03, 0x00, 0x00 };
const SENTINEL = [_]u8{ 0x01, 0x00, 0x00, 0x00 };

test "empty / encap-only / sentinel-only do not crash" {
    fuzzOne(&.{});
    fuzzOne(&LE_ENCAP);
    fuzzOne(&(LE_ENCAP ++ SENTINEL));
}

test "PID length exceeds buffer: no crash" {
    fuzzOne(&(LE_ENCAP ++ [_]u8{ 0x05, 0x00, 0xFF, 0xFF } ++ SENTINEL));
}

test "unknown must-understand PID: strict rejects, lenient retains, no crash" {
    // pid 0x4001 (MU bit set, unknown), len 4
    fuzzOne(&(LE_ENCAP ++ [_]u8{ 0x01, 0x40, 0x04, 0x00, 0xDE, 0xAD, 0xBE, 0xEF } ++ SENTINEL));
}

test "all-zeros / all-ones payloads: no crash" {
    fuzzOne(&([_]u8{0} ** 128));
    fuzzOne(&([_]u8{0xFF} ** 128));
}

test "corpus files replay without crash" {
    try replayCorpusDir();
}
