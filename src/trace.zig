//! Wire trace subsystem for Zenzen DDS.
//!
//! Controlled by two build options (both default false):
//!   -Dwire-trace=true   — include the trace machinery
//!   -Dguid-filter=true  — include per-GUID-prefix filtering
//!
//! When `wire_trace = false`, `Tracer` is a zero-size struct and every
//! `tracer.submit(...)` call is a comptime-eliminated noop. No overhead of any
//! kind reaches the binary.
//!
//! Usage (application side):
//!
//!   // Synchronous write to stderr:
//!   var stderr_writer = std.Io.File.stderr().writer(io, &buf);
//!   var sink = trace.SyncSink{ .writer = &stderr_writer, .format = .text };
//!   var tc   = trace.TraceConfig{ .sink = sink.sink() };
//!   factory  = try DomainParticipantFactory.init(alloc, .{ .trace = tc, ... });
//!
//!   // Async ring buffer → file:
//!   var file   = try std.Io.Dir.cwd().createFile(io, "trace.ndjson", .{});
//!   var asink  = try trace.AsyncRingSink.init(alloc, 4096, file_writer_ptr, .ndjson);
//!   try asink.startFlushThread();
//!   var tc     = trace.TraceConfig{ .sink = asink.sink() };

const std = @import("std");
const build_opts = @import("build_options");
const guid_mod = @import("rtps/guid.zig");
const sn_mod = @import("rtps/sequence_number.zig");
const sub_mod = @import("rtps/message/submessage.zig");
const time_mod = @import("util/time.zig");
const mutex_mod = @import("util/mutex.zig");
const sleepNs = time_mod.sleepNs;

pub const GuidPrefix = guid_mod.GuidPrefix;
pub const EntityId = guid_mod.EntityId;
pub const SequenceNumber = sn_mod.SequenceNumber;
pub const SequenceNumberSet = sub_mod.SequenceNumberSet;
pub const RtpsTimestamp = time_mod.RtpsTimestamp;

/// True when wire tracing is compiled in.
pub const enabled = build_opts.wire_trace;
/// True when GUID-prefix filtering is compiled in (only meaningful when enabled).
pub const filter_enabled = build_opts.guid_filter;

// ── TraceEvent ────────────────────────────────────────────────────────────────

pub const TraceEvent = union(enum) {
    // ── Send path ────────────────────────────────────────────────────────────
    send_data: DataFields,
    send_heartbeat: HeartbeatFields,
    send_acknack: AckNackFields,
    send_gap: GapFields,

    // ── Receive path — accepted ───────────────────────────────────────────────
    recv_data: DataFields,
    recv_heartbeat: HeartbeatFields,
    recv_acknack: AckNackFields,
    recv_gap: GapFields,
    recv_info_ts: InfoTsFields,
    recv_info_dst: InfoDstFields,

    // ── Receive path — discarded ──────────────────────────────────────────────
    /// Duplicate DATA (SN already received).
    recv_data_dup: DataDupFields,
    /// Stale or duplicate HEARTBEAT (count not strictly greater than last seen).
    recv_heartbeat_dup: HbDupFields,

    // ── Ring-buffer overflow marker ───────────────────────────────────────────
    /// Emitted by the flush thread when events were dropped due to ring overflow.
    skipped: struct { count: u64 },

    // ── Field structs ─────────────────────────────────────────────────────────

    pub const DataFields = struct {
        /// GUID prefix of the participant that *sent* this message.
        src_prefix: GuidPrefix,
        writer_eid: EntityId,
        reader_eid: EntityId,
        sn: SequenceNumber,
        key_hash: [16]u8 = std.mem.zeroes([16]u8),
        data_len: u32,
    };

    pub const HeartbeatFields = struct {
        src_prefix: GuidPrefix,
        writer_eid: EntityId,
        reader_eid: EntityId,
        first_sn: SequenceNumber,
        last_sn: SequenceNumber,
        count: i32,
        flags: u8,
    };

    pub const AckNackFields = struct {
        src_prefix: GuidPrefix,
        reader_eid: EntityId,
        writer_eid: EntityId,
        base_sn: SequenceNumber,
        bitmap: SequenceNumberSet,
        count: i32,
        final: bool,
    };

    pub const GapFields = struct {
        src_prefix: GuidPrefix,
        writer_eid: EntityId,
        reader_eid: EntityId,
        gap_start: SequenceNumber,
        gap_list: SequenceNumberSet,
    };

    pub const InfoTsFields = struct {
        timestamp: RtpsTimestamp,
    };

    pub const InfoDstFields = struct {
        prefix: GuidPrefix,
    };

    pub const DataDupFields = struct {
        src_prefix: GuidPrefix,
        writer_eid: EntityId,
        sn: SequenceNumber,
    };

    pub const HbDupFields = struct {
        src_prefix: GuidPrefix,
        writer_eid: EntityId,
        count: i32,
    };

    /// Extract the source GUID prefix from any event variant.
    /// Returns GuidPrefix.unknown for events with no clear source (INFO_TS, skipped).
    pub fn srcPrefix(event: TraceEvent) GuidPrefix {
        return switch (event) {
            .send_data, .recv_data => |e| e.src_prefix,
            .send_heartbeat, .recv_heartbeat => |e| e.src_prefix,
            .send_acknack, .recv_acknack => |e| e.src_prefix,
            .send_gap, .recv_gap => |e| e.src_prefix,
            .recv_data_dup => |e| e.src_prefix,
            .recv_heartbeat_dup => |e| e.src_prefix,
            .recv_info_dst => |e| e.prefix,
            .recv_info_ts, .skipped => GuidPrefix.unknown,
        };
    }
};

// ── GuidFilter ────────────────────────────────────────────────────────────────

/// GUID prefix filter. Empty slice = accept all events (fast path: one len check).
/// Gated at the call site by `filter_enabled`; the struct is always defined so
/// `TraceConfig` has a stable layout regardless of build options.
pub const GuidFilter = struct {
    prefixes: []const GuidPrefix = &.{},

    /// Returns true if `prefix` matches any entry in the filter list,
    /// or if the list is empty (accept-all mode).
    pub fn matches(self: GuidFilter, prefix: GuidPrefix) bool {
        if (self.prefixes.len == 0) return true;
        for (self.prefixes) |p| if (p.eql(prefix)) return true;
        return false;
    }
};

// ── Output format ─────────────────────────────────────────────────────────────

pub const Format = enum {
    /// One JSON object per line, no pretty-printing. Best for file output / tooling.
    ndjson,
    /// Short human-readable lines. Best for live stderr monitoring.
    text,
};

// ── Serialization ─────────────────────────────────────────────────────────────

/// Serialize one TraceEvent to `w` in the requested format.
pub fn formatEvent(w: *std.Io.Writer, fmt: Format, event: TraceEvent) !void {
    switch (fmt) {
        .ndjson => try formatNdjson(w, event),
        .text => try formatText(w, event),
    }
}

fn writeGuidPrefix(w: *std.Io.Writer, p: GuidPrefix) !void {
    for (p.bytes) |b| try w.print("{x:0>2}", .{b});
}

fn writeEntityId(w: *std.Io.Writer, e: EntityId) !void {
    try w.print("{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        e.entity_key[0], e.entity_key[1], e.entity_key[2], e.entity_kind,
    });
}

fn writeSns(w: *std.Io.Writer, set: SequenceNumberSet) !void {
    try w.print("{{\"base\":{},\"bits\":{},\"bm\":\"", .{ set.base, set.num_bits });
    const words = (set.num_bits + 31) / 32;
    for (set.bitmap[0..words]) |word| try w.print("{x:0>8}", .{word});
    try w.writeAll("\"}");
}

fn formatNdjson(w: *std.Io.Writer, event: TraceEvent) !void {
    const tag = @tagName(event);
    try w.print("{{\"t\":\"{s}\"", .{tag});
    switch (event) {
        .send_data, .recv_data => |e| {
            try w.writeAll(",\"src\":\"");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll("\",\"writer\":\"");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll("\",\"reader\":\"");
            try writeEntityId(w, e.reader_eid);
            try w.print("\",\"sn\":{},\"len\":{}", .{ e.sn, e.data_len });
        },
        .send_heartbeat, .recv_heartbeat => |e| {
            try w.writeAll(",\"src\":\"");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll("\",\"writer\":\"");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll("\",\"reader\":\"");
            try writeEntityId(w, e.reader_eid);
            try w.print("\",\"first\":{},\"last\":{},\"count\":{},\"flags\":{}", .{
                e.first_sn, e.last_sn, e.count, e.flags,
            });
        },
        .send_acknack, .recv_acknack => |e| {
            try w.writeAll(",\"src\":\"");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll("\",\"reader\":\"");
            try writeEntityId(w, e.reader_eid);
            try w.writeAll("\",\"writer\":\"");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll(",\"sns\":");
            try writeSns(w, e.bitmap);
            try w.print(",\"count\":{},\"final\":{}", .{ e.count, e.final });
        },
        .send_gap, .recv_gap => |e| {
            try w.writeAll(",\"src\":\"");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll("\",\"writer\":\"");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll("\",\"reader\":\"");
            try writeEntityId(w, e.reader_eid);
            try w.print(",\"gap_start\":{}", .{e.gap_start});
            try w.writeAll(",\"gap_list\":");
            try writeSns(w, e.gap_list);
        },
        .recv_info_ts => |e| {
            try w.print(",\"sec\":{},\"frac\":{}", .{ e.timestamp.seconds, e.timestamp.fraction });
        },
        .recv_info_dst => |e| {
            try w.writeAll(",\"prefix\":\"");
            try writeGuidPrefix(w, e.prefix);
            try w.writeAll("\"");
        },
        .recv_data_dup => |e| {
            try w.writeAll(",\"src\":\"");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll("\",\"writer\":\"");
            try writeEntityId(w, e.writer_eid);
            try w.print("\",\"sn\":{}", .{e.sn});
        },
        .recv_heartbeat_dup => |e| {
            try w.writeAll(",\"src\":\"");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll("\",\"writer\":\"");
            try writeEntityId(w, e.writer_eid);
            try w.print("\",\"count\":{}", .{e.count});
        },
        .skipped => |e| {
            try w.print(",\"count\":{}", .{e.count});
        },
    }
    try w.writeAll("}\n");
}

fn formatText(w: *std.Io.Writer, event: TraceEvent) !void {
    switch (event) {
        .send_data => |e| {
            try w.writeAll("SEND DATA  src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll(" reader=");
            try writeEntityId(w, e.reader_eid);
            try w.print(" sn={} len={}\n", .{ e.sn, e.data_len });
        },
        .recv_data => |e| {
            try w.writeAll("RECV DATA  src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll(" reader=");
            try writeEntityId(w, e.reader_eid);
            try w.print(" sn={} len={}\n", .{ e.sn, e.data_len });
        },
        .send_heartbeat => |e| {
            try w.writeAll("SEND HB    src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll(" reader=");
            try writeEntityId(w, e.reader_eid);
            try w.print(" [{},{}] count={} flags=0x{x}\n", .{
                e.first_sn, e.last_sn, e.count, e.flags,
            });
        },
        .recv_heartbeat => |e| {
            try w.writeAll("RECV HB    src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll(" reader=");
            try writeEntityId(w, e.reader_eid);
            try w.print(" [{},{}] count={} flags=0x{x}\n", .{
                e.first_sn, e.last_sn, e.count, e.flags,
            });
        },
        .send_acknack => |e| {
            try w.writeAll("SEND AN    src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" reader=");
            try writeEntityId(w, e.reader_eid);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.print(" base={} bits={} count={} final={}\n", .{
                e.base_sn, e.bitmap.num_bits, e.count, e.final,
            });
        },
        .recv_acknack => |e| {
            try w.writeAll("RECV AN    src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" reader=");
            try writeEntityId(w, e.reader_eid);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.print(" base={} bits={} count={} final={}\n", .{
                e.base_sn, e.bitmap.num_bits, e.count, e.final,
            });
        },
        .send_gap => |e| {
            try w.writeAll("SEND GAP   src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.print(" start={} base={} bits={}\n", .{
                e.gap_start, e.gap_list.base, e.gap_list.num_bits,
            });
        },
        .recv_gap => |e| {
            try w.writeAll("RECV GAP   src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.print(" start={} base={} bits={}\n", .{
                e.gap_start, e.gap_list.base, e.gap_list.num_bits,
            });
        },
        .recv_info_ts => |e| {
            try w.print("RECV INFO_TS sec={} frac={}\n", .{
                e.timestamp.seconds, e.timestamp.fraction,
            });
        },
        .recv_info_dst => |e| {
            try w.writeAll("RECV INFO_DST prefix=");
            try writeGuidPrefix(w, e.prefix);
            try w.writeAll("\n");
        },
        .recv_data_dup => |e| {
            try w.writeAll("RECV DATA(dup) src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.print(" sn={}\n", .{e.sn});
        },
        .recv_heartbeat_dup => |e| {
            try w.writeAll("RECV HB(dup) src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.print(" count={}\n", .{e.count});
        },
        .skipped => |e| {
            try w.print("--- SKIPPED {} events (ring overflow) ---\n", .{e.count});
        },
    }
}

// ── Sink vtable ───────────────────────────────────────────────────────────────

pub const Sink = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        submit: *const fn (ctx: *anyopaque, event: TraceEvent) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn submit(self: Sink, event: TraceEvent) void {
        self.vtable.submit(self.ctx, event);
    }

    pub fn deinit(self: Sink) void {
        self.vtable.deinit(self.ctx);
    }
};

// ── NoopSink ─────────────────────────────────────────────────────────────────

var noop_sentinel: usize = 0;
const noop_vtable: Sink.Vtable = .{
    .submit = &noopSubmit,
    .deinit = &noopDeinit,
};
fn noopSubmit(_: *anyopaque, _: TraceEvent) void {}
fn noopDeinit(_: *anyopaque) void {}

pub const NoopSink = struct {
    pub fn sink() Sink {
        return .{ .ctx = @ptrCast(&noop_sentinel), .vtable = &noop_vtable };
    }
};

// ── SyncSink ─────────────────────────────────────────────────────────────────

/// Serializes each event immediately to a `*std.Io.Writer`.
/// Blocks the calling thread; never drops events.
pub const SyncSink = struct {
    writer: *std.Io.Writer,
    format: Format,

    const Self = @This();

    fn submitFn(ctx: *anyopaque, event: TraceEvent) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        formatEvent(self.writer, self.format, event) catch {};
    }
    fn deinitFn(_: *anyopaque) void {}

    const vtable: Sink.Vtable = .{ .submit = &submitFn, .deinit = &deinitFn };

    pub fn sink(self: *Self) Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

// ── AsyncRingSink ─────────────────────────────────────────────────────────────

/// MPSC fixed-capacity ring buffer. Producers never block: if the ring is full,
/// the event is dropped and `dropped` is incremented atomically. An optional
/// flush thread drains the ring every 5 ms; it emits a synthetic `skipped` event
/// before the next batch when drops occurred.
pub const AsyncRingSink = struct {
    alloc: std.mem.Allocator,
    mu: mutex_mod.Mutex,
    slots: []TraceEvent,
    /// Index of the oldest item (read position).
    head: usize,
    /// Number of items currently in the ring.
    count: usize,
    dropped: std.atomic.Value(u64),
    writer: *std.Io.Writer,
    format: Format,
    thread: ?std.Thread,
    stopping: std.atomic.Value(bool),

    const Self = @This();
    const FLUSH_INTERVAL_NS: u64 = 5 * std.time.ns_per_ms;
    const DRAIN_BATCH = 64;

    pub fn init(
        alloc: std.mem.Allocator,
        capacity: usize,
        writer: *std.Io.Writer,
        format: Format,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        const slots = try alloc.alloc(TraceEvent, capacity);
        self.* = .{
            .alloc = alloc,
            .mu = .{},
            .slots = slots,
            .head = 0,
            .count = 0,
            .dropped = std.atomic.Value(u64).init(0),
            .writer = writer,
            .format = format,
            .thread = null,
            .stopping = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    /// Start the background flush thread (optional). If not called, events
    /// accumulate in the ring until `deinit` flushes them synchronously.
    pub fn startFlushThread(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, flushLoop, .{self});
    }

    pub fn deinit(self: *Self) void {
        if (self.thread) |t| {
            self.stopping.store(true, .release);
            t.join();
        }
        self.drainAll(); // final flush
        self.alloc.free(self.slots);
        self.alloc.destroy(self);
    }

    fn enqueue(self: *Self, event: TraceEvent) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.count == self.slots.len) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        const idx = (self.head + self.count) % self.slots.len;
        self.slots[idx] = event;
        self.count += 1;
    }

    /// Copy up to `buf.len` events into `buf`. Returns how many were copied.
    fn dequeueBatch(self: *Self, buf: []TraceEvent) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const n = @min(self.count, buf.len);
        for (0..n) |i| {
            buf[i] = self.slots[(self.head + i) % self.slots.len];
        }
        self.head = (self.head + n) % self.slots.len;
        self.count -= n;
        return n;
    }

    fn drainAll(self: *Self) void {
        var batch: [DRAIN_BATCH]TraceEvent = undefined;
        while (true) {
            // Emit a skipped marker before the next real batch if drops occurred.
            const dropped = self.dropped.swap(0, .acq_rel);
            if (dropped > 0) {
                formatEvent(self.writer, self.format, .{ .skipped = .{ .count = dropped } }) catch {};
            }
            const n = self.dequeueBatch(&batch);
            if (n == 0) break;
            for (batch[0..n]) |ev| {
                formatEvent(self.writer, self.format, ev) catch {};
            }
        }
    }

    fn flushLoop(self: *Self) void {
        while (!self.stopping.load(.acquire)) {
            sleepNs(FLUSH_INTERVAL_NS);
            self.drainAll();
        }
        self.drainAll();
    }

    fn submitFn(ctx: *anyopaque, event: TraceEvent) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.enqueue(event);
    }
    fn deinitFn(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    const vtable: Sink.Vtable = .{ .submit = &submitFn, .deinit = &deinitFn };

    pub fn sink(self: *Self) Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

// ── Tracer ────────────────────────────────────────────────────────────────────
// `Tracer` is the value held inside each state machine.
// When `enabled = false`, it is a zero-size struct and `submit` is a noop.

const TracerActive = struct {
    s: Sink,
    f: GuidFilter,

    pub fn submit(self: *const @This(), event: TraceEvent) void {
        if (comptime filter_enabled) {
            if (!self.f.matches(event.srcPrefix())) return;
        }
        self.s.submit(event);
    }

    pub fn noop() @This() {
        return .{ .s = NoopSink.sink(), .f = .{} };
    }
};

const TracerInert = struct {
    pub fn submit(_: *const @This(), _: TraceEvent) void {}
    pub fn noop() @This() {
        return .{};
    }
};

pub const Tracer = if (enabled) TracerActive else TracerInert;

// ── TraceConfig ───────────────────────────────────────────────────────────────
// Passed to DomainParticipantFactory at init time.

const TraceConfigActive = struct {
    sink: Sink = NoopSink.sink(),
    filter: GuidFilter = .{},

    pub fn tracer(self: @This()) Tracer {
        return .{ .s = self.sink, .f = self.filter };
    }
};

const TraceConfigInert = struct {
    pub fn tracer(_: @This()) Tracer {
        return .{};
    }
};

pub const TraceConfig = if (enabled) TraceConfigActive else TraceConfigInert;

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Convenience: an all-zero GuidPrefix and EntityId for use in tests.
const zero_prefix = GuidPrefix{ .bytes = .{0} ** 12 };
const zero_eid = EntityId{ .entity_key = .{ 0, 0, 0 }, .entity_kind = 0 };

fn testDataEvent() TraceEvent {
    return .{ .send_data = .{
        .src_prefix = zero_prefix,
        .writer_eid = zero_eid,
        .reader_eid = zero_eid,
        .sn = 42,
        .data_len = 100,
    } };
}

// ── GuidFilter tests ──────────────────────────────────────────────────────────

test "GuidFilter: empty prefixes list accepts all" {
    const f = GuidFilter{};
    try testing.expect(f.matches(zero_prefix));
    const other = GuidPrefix{ .bytes = .{1} ** 12 };
    try testing.expect(f.matches(other));
}

test "GuidFilter: non-empty list accepts matching prefix" {
    const target = GuidPrefix{ .bytes = .{0xAB} ** 12 };
    const f = GuidFilter{ .prefixes = &.{target} };
    try testing.expect(f.matches(target));
}

test "GuidFilter: non-empty list rejects non-matching prefix" {
    const target = GuidPrefix{ .bytes = .{0xAB} ** 12 };
    const other = GuidPrefix{ .bytes = .{0xCD} ** 12 };
    const f = GuidFilter{ .prefixes = &.{target} };
    try testing.expect(!f.matches(other));
}

// ── formatEvent tests ─────────────────────────────────────────────────────────

test "formatEvent text: send_data contains SEND DATA and sn" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatEvent(&w, .text, testDataEvent());
    const out = w.buffer[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "SEND DATA") != null);
    try testing.expect(std.mem.indexOf(u8, out, "sn=42") != null);
    try testing.expect(std.mem.indexOf(u8, out, "len=100") != null);
}

test "formatEvent ndjson: send_data is valid JSON with correct fields" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatEvent(&w, .ndjson, testDataEvent());
    const out = w.buffer[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\"t\":\"send_data\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"sn\":42") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"len\":100") != null);
    // Must be newline-terminated
    try testing.expectEqual(out[out.len - 1], '\n');
}

test "formatEvent ndjson: skipped event" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatEvent(&w, .ndjson, .{ .skipped = .{ .count = 7 } });
    const out = w.buffer[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\"t\":\"skipped\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":7") != null);
}

// ── SyncSink tests ────────────────────────────────────────────────────────────

test "SyncSink: submit writes formatted event to writer" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ss = SyncSink{ .writer = &w, .format = .text };
    ss.sink().submit(testDataEvent());
    const out = w.buffer[0..w.end];
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.indexOf(u8, out, "SEND DATA") != null);
}

// ── AsyncRingSink tests ───────────────────────────────────────────────────────

test "AsyncRingSink: events flushed synchronously on deinit (no flush thread)" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ring = try AsyncRingSink.init(testing.allocator, 8, &w, .text);
    // Do NOT start flush thread — deinit() must flush synchronously.
    ring.sink().submit(testDataEvent());
    ring.sink().submit(testDataEvent());
    ring.deinit();
    const out = w.buffer[0..w.end];
    // Two SEND DATA lines must appear.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "SEND DATA") != null) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "AsyncRingSink: dropped counter increments when ring is full" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // capacity = 2; enqueue 4 events → 2 dropped
    const ring = try AsyncRingSink.init(testing.allocator, 2, &w, .ndjson);
    ring.sink().submit(testDataEvent());
    ring.sink().submit(testDataEvent());
    ring.sink().submit(testDataEvent()); // dropped
    ring.sink().submit(testDataEvent()); // dropped
    try testing.expectEqual(@as(u64, 2), ring.dropped.load(.monotonic));
    ring.deinit(); // flushes remaining 2 events + emits skipped{count:2}
    const out = w.buffer[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, "\"t\":\"skipped\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":2") != null);
}

// ── Helpers for remaining event types ────────────────────────────────────────

const zero_sns = SequenceNumberSet{ .base = 1, .num_bits = 32, .bitmap = [8]u32{ 0x80000000, 0, 0, 0, 0, 0, 0, 0 } };

fn testRecvDataEvent() TraceEvent {
    return .{ .recv_data = .{ .src_prefix = zero_prefix, .writer_eid = zero_eid, .reader_eid = zero_eid, .sn = 7, .data_len = 8 } };
}
fn testSendHbEvent() TraceEvent {
    return .{ .send_heartbeat = .{ .src_prefix = zero_prefix, .writer_eid = zero_eid, .reader_eid = zero_eid, .first_sn = 1, .last_sn = 5, .count = 2, .flags = 0x02 } };
}
fn testRecvHbEvent() TraceEvent {
    return .{ .recv_heartbeat = .{ .src_prefix = zero_prefix, .writer_eid = zero_eid, .reader_eid = zero_eid, .first_sn = 1, .last_sn = 5, .count = 2, .flags = 0x02 } };
}
fn testSendAnEvent() TraceEvent {
    return .{ .send_acknack = .{ .src_prefix = zero_prefix, .reader_eid = zero_eid, .writer_eid = zero_eid, .base_sn = 1, .bitmap = zero_sns, .count = 1, .final = true } };
}
fn testRecvAnEvent() TraceEvent {
    return .{ .recv_acknack = .{ .src_prefix = zero_prefix, .reader_eid = zero_eid, .writer_eid = zero_eid, .base_sn = 1, .bitmap = zero_sns, .count = 1, .final = false } };
}
fn testSendGapEvent() TraceEvent {
    return .{ .send_gap = .{ .src_prefix = zero_prefix, .writer_eid = zero_eid, .reader_eid = zero_eid, .gap_start = 3, .gap_list = zero_sns } };
}
fn testRecvGapEvent() TraceEvent {
    return .{ .recv_gap = .{ .src_prefix = zero_prefix, .writer_eid = zero_eid, .reader_eid = zero_eid, .gap_start = 3, .gap_list = zero_sns } };
}
fn testInfoTsEvent() TraceEvent {
    return .{ .recv_info_ts = .{ .timestamp = .{ .seconds = 100, .fraction = 200 } } };
}
fn testInfoDstEvent() TraceEvent {
    return .{ .recv_info_dst = .{ .prefix = zero_prefix } };
}
fn testDataDupEvent() TraceEvent {
    return .{ .recv_data_dup = .{ .src_prefix = zero_prefix, .writer_eid = zero_eid, .sn = 10 } };
}
fn testHbDupEvent() TraceEvent {
    return .{ .recv_heartbeat_dup = .{ .src_prefix = zero_prefix, .writer_eid = zero_eid, .count = 3 } };
}

fn checkFmt(fmt: Format, event: TraceEvent, needle: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatEvent(&w, fmt, event);
    const out = w.buffer[0..w.end];
    try testing.expect(std.mem.indexOf(u8, out, needle) != null);
}

// ── TraceEvent.srcPrefix ──────────────────────────────────────────────────────

test "TraceEvent.srcPrefix: all variants" {
    const p = GuidPrefix{ .bytes = .{0xAB} ** 12 };
    const mk_data = TraceEvent{ .recv_data = .{ .src_prefix = p, .writer_eid = zero_eid, .reader_eid = zero_eid, .sn = 1, .data_len = 0 } };
    try testing.expect(mk_data.srcPrefix().eql(p));
    const mk_hb = TraceEvent{ .send_heartbeat = .{ .src_prefix = p, .writer_eid = zero_eid, .reader_eid = zero_eid, .first_sn = 1, .last_sn = 1, .count = 1, .flags = 0 } };
    try testing.expect(mk_hb.srcPrefix().eql(p));
    const mk_an = TraceEvent{ .recv_acknack = .{ .src_prefix = p, .reader_eid = zero_eid, .writer_eid = zero_eid, .base_sn = 1, .bitmap = zero_sns, .count = 1, .final = false } };
    try testing.expect(mk_an.srcPrefix().eql(p));
    const mk_gap = TraceEvent{ .send_gap = .{ .src_prefix = p, .writer_eid = zero_eid, .reader_eid = zero_eid, .gap_start = 1, .gap_list = zero_sns } };
    try testing.expect(mk_gap.srcPrefix().eql(p));
    const mk_dup = TraceEvent{ .recv_data_dup = .{ .src_prefix = p, .writer_eid = zero_eid, .sn = 1 } };
    try testing.expect(mk_dup.srcPrefix().eql(p));
    const mk_hbdup = TraceEvent{ .recv_heartbeat_dup = .{ .src_prefix = p, .writer_eid = zero_eid, .count = 1 } };
    try testing.expect(mk_hbdup.srcPrefix().eql(p));
    const mk_dst = TraceEvent{ .recv_info_dst = .{ .prefix = p } };
    try testing.expect(mk_dst.srcPrefix().eql(p));
    try testing.expect(testInfoTsEvent().srcPrefix().eql(GuidPrefix.unknown));
    try testing.expect((TraceEvent{ .skipped = .{ .count = 1 } }).srcPrefix().eql(GuidPrefix.unknown));
}

// ── formatEvent: remaining event types ───────────────────────────────────────

test "formatEvent: recv_data both formats" {
    try checkFmt(.text, testRecvDataEvent(), "RECV DATA");
    try checkFmt(.ndjson, testRecvDataEvent(), "\"t\":\"recv_data\"");
}

test "formatEvent: send_heartbeat and recv_heartbeat" {
    try checkFmt(.text, testSendHbEvent(), "SEND HB");
    try checkFmt(.ndjson, testSendHbEvent(), "\"t\":\"send_heartbeat\"");
    try checkFmt(.text, testRecvHbEvent(), "RECV HB");
    try checkFmt(.ndjson, testRecvHbEvent(), "\"t\":\"recv_heartbeat\"");
}

test "formatEvent: send_acknack and recv_acknack" {
    try checkFmt(.text, testSendAnEvent(), "SEND AN");
    try checkFmt(.ndjson, testSendAnEvent(), "\"t\":\"send_acknack\"");
    try checkFmt(.text, testRecvAnEvent(), "RECV AN");
    try checkFmt(.ndjson, testRecvAnEvent(), "\"t\":\"recv_acknack\"");
}

test "formatEvent: send_gap and recv_gap" {
    try checkFmt(.text, testSendGapEvent(), "SEND GAP");
    try checkFmt(.ndjson, testSendGapEvent(), "\"t\":\"send_gap\"");
    try checkFmt(.text, testRecvGapEvent(), "RECV GAP");
    try checkFmt(.ndjson, testRecvGapEvent(), "\"t\":\"recv_gap\"");
}

test "formatEvent: recv_info_ts both formats" {
    try checkFmt(.text, testInfoTsEvent(), "INFO_TS");
    try checkFmt(.ndjson, testInfoTsEvent(), "\"t\":\"recv_info_ts\"");
}

test "formatEvent: recv_info_dst both formats" {
    try checkFmt(.text, testInfoDstEvent(), "INFO_DST");
    try checkFmt(.ndjson, testInfoDstEvent(), "\"t\":\"recv_info_dst\"");
}

test "formatEvent: recv_data_dup both formats" {
    try checkFmt(.text, testDataDupEvent(), "DATA(dup)");
    try checkFmt(.ndjson, testDataDupEvent(), "\"t\":\"recv_data_dup\"");
}

test "formatEvent: recv_heartbeat_dup both formats" {
    try checkFmt(.text, testHbDupEvent(), "HB(dup)");
    try checkFmt(.ndjson, testHbDupEvent(), "\"t\":\"recv_heartbeat_dup\"");
}

test "formatEvent: skipped text format" {
    try checkFmt(.text, .{ .skipped = .{ .count = 3 } }, "SKIPPED");
}

// ── NoopSink ──────────────────────────────────────────────────────────────────

test "NoopSink: submit and deinit are no-ops" {
    const s = NoopSink.sink();
    s.submit(testDataEvent());
    s.deinit(); // covers Sink.deinit forwarding and noopDeinit
}

// ── SyncSink.deinit ───────────────────────────────────────────────────────────

test "SyncSink: deinit is a no-op" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ss = SyncSink{ .writer = &w, .format = .text };
    ss.sink().deinit(); // covers deinitFn
}

// ── AsyncRingSink via vtable deinit ───────────────────────────────────────────

test "AsyncRingSink: deinit via vtable sink" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ring = try AsyncRingSink.init(testing.allocator, 4, &w, .text);
    ring.sink().submit(testDataEvent());
    ring.sink().deinit(); // vtable path → deinitFn → ring.deinit()
}

// ── AsyncRingSink flush thread ────────────────────────────────────────────────

test "AsyncRingSink: flush thread drains events" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ring = try AsyncRingSink.init(testing.allocator, 16, &w, .text);
    try ring.startFlushThread();
    ring.sink().submit(testDataEvent());
    // Wait for the flush thread's 5 ms sleep + drain cycle.
    sleepNs(12 * std.time.ns_per_ms);
    ring.deinit();
    const out = w.buffer[0..w.end];
    try testing.expect(out.len > 0);
}

// ── TracerActive ──────────────────────────────────────────────────────────────

test "TracerActive.noop: submit is a no-op" {
    var tc = TracerActive.noop();
    tc.submit(testDataEvent()); // noop sink; must not crash
}

test "TracerActive: submit forwards event to sink" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ss = SyncSink{ .writer = &w, .format = .text };
    const tc = TracerActive{ .s = ss.sink(), .f = .{} };
    tc.submit(testDataEvent());
    try testing.expect(std.mem.indexOf(u8, w.buffer[0..w.end], "SEND DATA") != null);
}
