//! Handle registry study (docs/design/handle-registries.md): the cost of
//! reaching an instance's state from its 16-byte RTPS key hash, today (a
//! 31-bit FNV-1a fold, then maps keyed by that handle) against two registry
//! shapes from std. Also counts the fold's collisions.
//!
//!   zig run -OReleaseFast docs/design/probes/handle_registry_bench.zig
//!
//! Key shapes: `int_key` is a key that fits in 16 bytes, whose RTPS key hash
//! is the big-endian key zero-padded (RTPS 2.5 §9.6.4.8); `md5` is a longer
//! key, whose key hash is an MD5 digest (random bytes here).
const std = @import("std");
const builtin = @import("builtin");

const Key = [16]u8;
const Entry = struct { instance_state: u32 = 1, disposed: i32 = 0, no_writers: i32 = 0, key_cdr: ?[]u8 = null };

fn nowNs() i64 {
    if (comptime builtin.os.tag == .windows) {
        const ntdll = std.os.windows.ntdll;
        var freq: i64 = undefined;
        _ = ntdll.RtlQueryPerformanceFrequency(&freq);
        var count: i64 = undefined;
        _ = ntdll.RtlQueryPerformanceCounter(&count);
        return @divTrunc(count, freq) * std.time.ns_per_s + @divTrunc(@mod(count, freq) * std.time.ns_per_s, freq);
    }
    // Linux without libc (`zig run` links none); elsewhere libc's.
    const c = if (builtin.os.tag == .linux) std.os.linux else std.c;
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

fn nsPer(t0: i64, ops: usize) f64 {
    return @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(ops));
}

/// `keyHashToHandle` (src/dcps/writer.zig) as of 2026-11-18.
fn fold(k: Key) i32 {
    var h: u32 = 2166136261;
    for (k) |b| {
        h ^= b;
        h *%= 16777619;
    }
    const v: i32 = @intCast(h & 0x7FFF_FFFF);
    return if (v == 0) 1 else v;
}

const Shape = enum { int_key, md5 };
var sink: u64 = 0;

fn run(alloc: std.mem.Allocator, n: usize, shape: Shape, rng: std.Random) !void {
    const keys = try alloc.alloc(Key, n);
    defer alloc.free(keys);
    for (keys, 0..) |*k, i| {
        k.* = std.mem.zeroes(Key);
        switch (shape) {
            .int_key => std.mem.writeInt(u32, k[0..4], @intCast(i), .big),
            .md5 => rng.bytes(k),
        }
    }
    const lookups: usize = 2_000_000;
    const q = try alloc.alloc(u32, lookups);
    defer alloc.free(q);
    for (q) |*x| x.* = rng.uintLessThan(u32, @intCast(n));

    var folded: std.AutoHashMapUnmanaged(i32, void) = .empty;
    defer folded.deinit(alloc);
    var collisions: usize = 0;
    for (keys) |k| {
        if ((try folded.getOrPut(alloc, fold(k))).found_existing) collisions += 1;
    }

    // Today: fold, then one map keyed by handle (`seen_instances`), or three
    // (with `tbf_map` and `owner_map`, for TIME_BASED_FILTER and EXCLUSIVE).
    var m1: std.AutoHashMapUnmanaged(i32, Entry) = .empty;
    var m2: std.AutoHashMapUnmanaged(i32, i64) = .empty;
    var m3: std.AutoHashMapUnmanaged(i32, [16]u8) = .empty;
    defer m1.deinit(alloc);
    defer m2.deinit(alloc);
    defer m3.deinit(alloc);
    for (keys) |k| {
        try m1.put(alloc, fold(k), .{});
        try m2.put(alloc, fold(k), 0);
        try m3.put(alloc, fold(k), k);
    }
    var t0 = nowNs();
    for (q) |i| sink +%= m1.getPtr(fold(keys[i])).?.instance_state;
    const today1 = nsPer(t0, lookups);
    t0 = nowNs();
    for (q) |i| {
        const h = fold(keys[i]);
        sink +%= m1.getPtr(h).?.instance_state;
        sink +%= @intCast(m2.get(h).? + 1);
        sink +%= m3.get(h).?[0];
    }
    const today3 = nsPer(t0, lookups);

    // Registry: key -> slot index, and a dense slot array holding the
    // instance's state; a handle names its slot directly.
    const Slot = struct { key: Key, generation: u16, entry: Entry, tbf_ns: i64, owner: [16]u8 };
    var index: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    defer index.deinit(alloc);
    var slots: std.ArrayListUnmanaged(Slot) = .empty;
    defer slots.deinit(alloc);
    for (keys) |k| {
        try index.put(alloc, k, @intCast(slots.items.len));
        try slots.append(alloc, .{ .key = k, .generation = 0, .entry = .{}, .tbf_ns = 0, .owner = k });
    }
    t0 = nowNs();
    for (q) |i| {
        const s = &slots.items[index.get(keys[i]).?];
        sink +%= s.entry.instance_state;
        sink +%= @intCast(s.tbf_ns + 1);
        sink +%= s.owner[0];
    }
    const reg = nsPer(t0, lookups);
    t0 = nowNs();
    for (q) |i| sink +%= slots.items[i].entry.instance_state;
    const reg_by_handle = nsPer(t0, lookups);

    // AutoArrayHashMap: its entry index could be the handle (until removal).
    var am: std.AutoArrayHashMapUnmanaged(Key, Entry) = .empty;
    defer am.deinit(alloc);
    for (keys) |k| try am.put(alloc, k, .{});
    t0 = nowNs();
    for (q) |i| sink +%= am.values()[am.getIndex(keys[i]).?].instance_state;
    const arraymap = nsPer(t0, lookups);

    std.debug.print("{s:>7} {d:>9} {d:>10} | {d:>7.1} {d:>7.1} | {d:>7.1} {d:>7.1} | {d:>7.1}\n", .{
        @tagName(shape), n, collisions, today1, today3, reg, reg_by_handle, arraymap,
    });
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    std.debug.print("ns per lookup; 'x3' also reads the TIME_BASED_FILTER and owner state\n", .{});
    std.debug.print("{s:>7} {s:>9} {s:>10} | {s:>7} {s:>7} | {s:>7} {s:>7} | {s:>7}\n", .{
        "shape", "instances", "collisions", "today", "x3", "registry", "by hndl", "arraymap",
    });
    for ([_]usize{ 1_000, 10_000, 100_000, 1_000_000 }) |n| {
        try run(alloc, n, .int_key, prng.random());
        try run(alloc, n, .md5, prng.random());
    }
    if (sink == 0) std.debug.print("(sink)\n", .{});
}
