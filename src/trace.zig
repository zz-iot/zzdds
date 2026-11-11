//! Wire trace subsystem for Zenzen DDS.
//!
//! Compiled in by `-Dwire-trace=true` (default false). Without it, `Tracer`
//! is a zero-size struct and every `tracer.submit(...)` call is a
//! comptime-eliminated noop: no overhead of any kind reaches the binary.
//!
//! What is traced, and where it goes, is each participant's configuration
//! (`[trace]` in zzdds.toml, or `zzdds::TraceConfig`): the sink (none,
//! stderr, stdout or a file), the scope (discovery's built-in endpoints,
//! the user's endpoints, or both), the format, and a participant filter.
//! See `tracersFor`. A build without `-Dwire-trace` validates that
//! configuration and ignores it, warning once when a sink is set.
//!
//! A Zig application can instead give the factory its own `Sink` (an
//! in-memory one for a test, say, or an `AsyncRingSink`), which replaces
//! the configured sink while the scope and filter still apply:
//!
//!   var asink = try trace.AsyncRingSink.init(alloc, 4096, file_writer_ptr, .ndjson);
//!   try asink.startFlushThread();   // or call asink.flush() from your own loop
//!   factory.setTraceSink(asink.sink());

const std = @import("std");
const build_opts = @import("build_options");
const schema = @import("config/schema.zig");
const log = @import("log.zig");
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
        /// GUID prefix of the participant the message was sent to, where
        /// known (not for a multicast or locator-addressed send).
        dst_prefix: GuidPrefix = GuidPrefix.unknown,
    };

    pub const HeartbeatFields = struct {
        src_prefix: GuidPrefix,
        writer_eid: EntityId,
        reader_eid: EntityId,
        first_sn: SequenceNumber,
        last_sn: SequenceNumber,
        count: i32,
        flags: u8,
        dst_prefix: GuidPrefix = GuidPrefix.unknown,
    };

    pub const AckNackFields = struct {
        src_prefix: GuidPrefix,
        reader_eid: EntityId,
        writer_eid: EntityId,
        base_sn: SequenceNumber,
        bitmap: SequenceNumberSet,
        count: i32,
        final: bool,
        dst_prefix: GuidPrefix = GuidPrefix.unknown,
    };

    pub const GapFields = struct {
        src_prefix: GuidPrefix,
        writer_eid: EntityId,
        reader_eid: EntityId,
        gap_start: SequenceNumber,
        gap_list: SequenceNumberSet,
        dst_prefix: GuidPrefix = GuidPrefix.unknown,
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
        dst_prefix: GuidPrefix = GuidPrefix.unknown,
    };

    pub const HbDupFields = struct {
        src_prefix: GuidPrefix,
        writer_eid: EntityId,
        count: i32,
        dst_prefix: GuidPrefix = GuidPrefix.unknown,
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

    /// The participants `event` involves: the one that sent the message and
    /// the one it was sent to. `GuidPrefix.unknown` for either one not
    /// known.
    pub fn participants(event: TraceEvent) [2]GuidPrefix {
        return switch (event) {
            inline .send_data,
            .recv_data,
            .send_heartbeat,
            .recv_heartbeat,
            .send_acknack,
            .recv_acknack,
            .send_gap,
            .recv_gap,
            .recv_data_dup,
            .recv_heartbeat_dup,
            => |e| .{ e.src_prefix, e.dst_prefix },
            .recv_info_dst => |e| .{ GuidPrefix.unknown, e.prefix },
            .recv_info_ts, .skipped => .{ GuidPrefix.unknown, GuidPrefix.unknown },
        };
    }
};

// ── GuidFilter ────────────────────────────────────────────────────────────────

pub const FilterMode = enum {
    /// Every event except those involving a listed participant.
    exclude,
    /// Only events involving a listed participant.
    include,
};

/// Selects events by the participants they involve (`TraceEvent.participants`):
/// the sender, or the participant the message was sent to. The default, an
/// empty exclude list, accepts everything.
pub const GuidFilter = struct {
    mode: FilterMode = .exclude,
    /// GUID prefixes.
    prefixes: []const [12]u8 = &.{},

    pub fn accepts(self: GuidFilter, event: TraceEvent) bool {
        if (self.prefixes.len == 0) return self.mode == .exclude;
        const involved = event.participants();
        const listed = for (self.prefixes) |p| {
            if (std.mem.eql(u8, &p, &involved[0].bytes) or std.mem.eql(u8, &p, &involved[1].bytes)) break true;
        } else false;
        return listed == (self.mode == .include);
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

/// `,"dst":"<prefix>"` when the event's destination participant is known.
fn writeNdjsonDst(w: *std.Io.Writer, dst: GuidPrefix) !void {
    if (dst.eql(GuidPrefix.unknown)) return;
    try w.writeAll(",\"dst\":\"");
    try writeGuidPrefix(w, dst);
    try w.writeAll("\"");
}

/// ` dst=<prefix>` when the event's destination participant is known.
fn writeTextDst(w: *std.Io.Writer, dst: GuidPrefix) !void {
    if (dst.eql(GuidPrefix.unknown)) return;
    try w.writeAll(" dst=");
    try writeGuidPrefix(w, dst);
}

fn formatNdjson(w: *std.Io.Writer, event: TraceEvent) !void {
    const tag = @tagName(event);
    try w.print("{{\"t\":\"{s}\"", .{tag});
    try writeNdjsonDst(w, event.participants()[1]);
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
            try w.writeAll("\",\"sns\":");
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
            try w.print("\",\"gap_start\":{}", .{e.gap_start});
            try w.writeAll(",\"gap_list\":");
            try writeSns(w, e.gap_list);
        },
        .recv_info_ts => |e| {
            try w.print(",\"sec\":{},\"frac\":{}", .{ e.timestamp.seconds, e.timestamp.fraction });
        },
        .recv_info_dst => {},
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
    try formatTextBody(w, event);
    if (event != .recv_info_dst) try writeTextDst(w, event.participants()[1]);
    try w.writeAll("\n");
}

fn formatTextBody(w: *std.Io.Writer, event: TraceEvent) !void {
    switch (event) {
        .send_data => |e| {
            try w.writeAll("SEND DATA  src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll(" reader=");
            try writeEntityId(w, e.reader_eid);
            try w.print(" sn={} len={}", .{ e.sn, e.data_len });
        },
        .recv_data => |e| {
            try w.writeAll("RECV DATA  src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll(" reader=");
            try writeEntityId(w, e.reader_eid);
            try w.print(" sn={} len={}", .{ e.sn, e.data_len });
        },
        .send_heartbeat => |e| {
            try w.writeAll("SEND HB    src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.writeAll(" reader=");
            try writeEntityId(w, e.reader_eid);
            try w.print(" [{},{}] count={} flags=0x{x}", .{
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
            try w.print(" [{},{}] count={} flags=0x{x}", .{
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
            try w.print(" base={} bits={} count={} final={}", .{
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
            try w.print(" base={} bits={} count={} final={}", .{
                e.base_sn, e.bitmap.num_bits, e.count, e.final,
            });
        },
        .send_gap => |e| {
            try w.writeAll("SEND GAP   src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.print(" start={} base={} bits={}", .{
                e.gap_start, e.gap_list.base, e.gap_list.num_bits,
            });
        },
        .recv_gap => |e| {
            try w.writeAll("RECV GAP   src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.print(" start={} base={} bits={}", .{
                e.gap_start, e.gap_list.base, e.gap_list.num_bits,
            });
        },
        .recv_info_ts => |e| {
            try w.print("RECV INFO_TS sec={} frac={}", .{
                e.timestamp.seconds, e.timestamp.fraction,
            });
        },
        .recv_info_dst => |e| {
            try w.writeAll("RECV INFO_DST prefix=");
            try writeGuidPrefix(w, e.prefix);
        },
        .recv_data_dup => |e| {
            try w.writeAll("RECV DATA(dup) src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.print(" sn={}", .{e.sn});
        },
        .recv_heartbeat_dup => |e| {
            try w.writeAll("RECV HB(dup) src=");
            try writeGuidPrefix(w, e.src_prefix);
            try w.writeAll(" writer=");
            try writeEntityId(w, e.writer_eid);
            try w.print(" count={}", .{e.count});
        },
        .skipped => |e| {
            try w.print("--- SKIPPED {} events (ring overflow) ---", .{e.count});
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

/// Serializes each event immediately to a `*std.Io.Writer`, one at a time
/// (events come from many threads), and flushes it. Blocks the calling
/// thread; never drops events.
pub const SyncSink = struct {
    writer: *std.Io.Writer,
    format: Format,
    mu: mutex_mod.Mutex = .{},

    const Self = @This();

    fn submitFn(ctx: *anyopaque, event: TraceEvent) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        formatEvent(self.writer, self.format, event) catch {};
        self.writer.flush() catch {};
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
    /// Serializes drains, so that `flush` and the flush thread never write
    /// to `writer` at once.
    drain_mu: mutex_mod.Mutex = .{},

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
    /// accumulate in the ring until `flush` or `deinit` writes them.
    pub fn startFlushThread(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, flushLoop, .{self});
    }

    pub fn deinit(self: *Self) void {
        if (self.thread) |t| {
            self.stopping.store(true, .release);
            t.join();
        }
        self.drainAll(); // final flush
        self.drain_mu.deinit();
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

    /// Writes the events queued now to the writer, on the caller's thread,
    /// for an application that drains the ring from its own loop instead of
    /// a flush thread. Safe alongside the flush thread. Flushing the
    /// writer's own buffer is the caller's.
    pub fn flush(self: *Self) void {
        self.drainAll();
    }

    fn drainAll(self: *Self) void {
        self.drain_mu.lock();
        defer self.drain_mu.unlock();
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
        if (!self.f.accepts(event)) return;
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

// ── Configured tracers ────────────────────────────────────────────────────────

/// A participant's tracers: one for discovery's built-in endpoints (SPDP,
/// SEDP and WLP), one for its user DataWriters and DataReaders.
pub const Tracers = struct {
    discovery: Tracer = Tracer.noop(),
    user: Tracer = Tracer.noop(),
};

/// The tracers for a participant configured with `cfg`: its sink, or
/// `override` in place of it, for the endpoints its scope covers, through
/// its filter. A sink that cannot be opened is reported and traces nothing.
/// Without `-Dwire-trace` both trace nothing, and a configured sink is
/// reported once per process. `cfg` must outlive the tracers (its filter
/// list is borrowed).
pub fn tracersFor(cfg: *const schema.TraceConfig, override: ?Sink) Tracers {
    if (comptime !enabled) {
        if (cfg.sink != .none and !warned_not_built.swap(true, .monotonic))
            log.dcps.warn("trace: a trace sink is configured, but this zzdds was built without -Dwire-trace; nothing is traced", .{});
        return .{};
    }
    const sink = override orelse configuredSink(cfg.sink, cfg.format) orelse return .{};
    const tracer: Tracer = .{ .s = sink, .f = .{
        .mode = switch (cfg.filter_mode) {
            .exclude => .exclude,
            .include => .include,
        },
        .prefixes = cfg.filter_participants,
    } };
    return .{
        .discovery = if (cfg.scope == .user) Tracer.noop() else tracer,
        .user = if (cfg.scope == .discovery) Tracer.noop() else tracer,
    };
}

var warned_not_built = std.atomic.Value(bool).init(false);

/// A configured sink, opened once per process: participants that name the
/// same stream or file share it, however they spell the file's path, and it
/// stays open until the process exits, flushing every event, so a crash or
/// `exit` loses none. The format is the first opener's. Null for `.none`,
/// or after reporting a failure to open.
fn configuredSink(target: schema.TraceSink, format: schema.TraceFormat) ?Sink {
    if (target == .none) return null;
    registry_mu.lock();
    defer registry_mu.unlock();
    var it = registry_head;
    while (it) |s| : (it = s.next) if (s.target.eql(target)) return s.sink();
    const s = StreamSink.open(target, switch (format) {
        .text => .text,
        .ndjson => .ndjson,
    }) catch |err| switch (err) {
        error.AlreadyOpen => return already_open.?.sink(),
        else => {
            switch (target) {
                .file => |path| log.dcps.warn("trace: cannot open trace file '{s}': {s}; nothing is traced", .{ path, @errorName(err) }),
                else => log.dcps.warn("trace: cannot open the trace stream: {s}; nothing is traced", .{@errorName(err)}),
            }
            return null;
        },
    };
    s.next = registry_head;
    registry_head = s;
    return s.sink();
}

var registry_mu: mutex_mod.Mutex = .{};
var registry_head: ?*StreamSink = null;
/// Set with `error.AlreadyOpen` from `StreamSink.open`, under `registry_mu`.
var already_open: ?*StreamSink = null;

/// A sink on stderr, stdout or a file, from configuration. Never freed:
/// see `configuredSink`. Stderr writes hold the process's stderr lock, so
/// they do not interleave with log output.
const StreamSink = struct {
    target: Target,
    format: Format,
    mu: mutex_mod.Mutex = .{},
    file: std.Io.File,
    /// A file sink's canonical path, which another spelling of its path
    /// resolves to. Null where the platform cannot resolve one.
    real_path: ?[]const u8 = null,
    file_writer: std.Io.File.Writer = undefined,
    buf: [4096]u8 = undefined,
    next: ?*StreamSink = null,

    const Target = union(enum) {
        stderr,
        stdout,
        file: []const u8,

        fn eql(self: Target, other: schema.TraceSink) bool {
            return switch (self) {
                .stderr => other == .stderr,
                .stdout => other == .stdout,
                .file => |path| other == .file and std.mem.eql(u8, path, other.file),
            };
        }
    };

    /// The process-lifetime allocations behind configured sinks.
    const alloc = std.heap.page_allocator;

    fn open(target: schema.TraceSink, format: Format) !*StreamSink {
        const io = std.Io.Threaded.global_single_threaded.io();
        const self = try alloc.create(StreamSink);
        errdefer alloc.destroy(self);
        self.* = switch (target) {
            .none => unreachable,
            .stderr => .{ .target = .stderr, .format = format, .file = std.Io.File.stderr() },
            .stdout => .{ .target = .stdout, .format = format, .file = std.Io.File.stdout() },
            .file => |path| blk: {
                // Opened without truncating, so another spelling of a path
                // already open (`./trace.txt`, a different case on Windows, a
                // symbolic link) is found before its trace is erased. The
                // canonical path names one file across every mounted
                // filesystem, which an inode number alone does not.
                const flags: std.Io.Dir.CreateFileOptions = .{ .truncate = false };
                const file = if (std.fs.path.isAbsolute(path))
                    try std.Io.Dir.createFileAbsolute(io, path, flags)
                else
                    try std.Io.Dir.cwd().createFile(io, path, flags);
                errdefer file.close(io);
                const real_path = try canonicalPath(io, file);
                errdefer if (real_path) |p| alloc.free(p);
                if (real_path) |p| {
                    var it = registry_head;
                    while (it) |s| : (it = s.next) {
                        const other = s.real_path orelse continue;
                        if (std.mem.eql(u8, other, p)) {
                            already_open = s;
                            return error.AlreadyOpen;
                        }
                    }
                }
                try file.setLength(io, 0);
                const owned = try alloc.dupe(u8, path);
                break :blk .{ .target = .{ .file = owned }, .format = format, .file = file, .real_path = real_path };
            },
        };
        self.file_writer = self.file.writerStreaming(io, &self.buf);
        return self;
    }

    /// The open file's canonical path, or null where the platform cannot
    /// resolve one, so only the path's exact spelling is shared.
    fn canonicalPath(io: std.Io, file: std.Io.File) !?[]const u8 {
        const buf = try alloc.alloc(u8, std.fs.max_path_bytes);
        defer alloc.free(buf);
        const len = file.realPath(io, buf) catch |err| switch (err) {
            error.OperationUnsupported => return null,
            else => {
                log.dcps.warn("trace: cannot resolve the trace file's path: {s}; only its exact spelling shares it", .{@errorName(err)});
                return null;
            },
        };
        return try alloc.dupe(u8, buf[0..len]);
    }

    fn submitFn(ctx: *anyopaque, event: TraceEvent) void {
        const self: *StreamSink = @ptrCast(@alignCast(ctx));
        if (self.target == .stderr) {
            var buf: [512]u8 = undefined;
            const locked = std.debug.lockStderr(&buf);
            defer std.debug.unlockStderr();
            const w = &locked.file_writer.interface;
            formatEvent(w, self.format, event) catch {};
            w.flush() catch {};
            return;
        }
        self.mu.lock();
        defer self.mu.unlock();
        formatEvent(&self.file_writer.interface, self.format, event) catch {};
        self.file_writer.interface.flush() catch {};
    }
    fn deinitFn(_: *anyopaque) void {}

    const vtable: Sink.Vtable = .{ .submit = &submitFn, .deinit = &deinitFn };

    fn sink(self: *StreamSink) Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Convenience: an all-zero GuidPrefix and EntityId for use in tests.
const zero_prefix = GuidPrefix{ .bytes = @splat(0) };
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

fn eventBetween(src: GuidPrefix, dst: GuidPrefix) TraceEvent {
    return .{ .send_heartbeat = .{
        .src_prefix = src,
        .writer_eid = zero_eid,
        .reader_eid = zero_eid,
        .first_sn = 1,
        .last_sn = 1,
        .count = 1,
        .flags = 0,
        .dst_prefix = dst,
    } };
}

test "GuidFilter: the default, an empty exclude list, accepts everything" {
    const f = GuidFilter{};
    try testing.expect(f.accepts(testDataEvent()));
    try testing.expect(f.accepts(testInfoTsEvent()));
}

test "GuidFilter: an empty include list accepts nothing" {
    const f = GuidFilter{ .mode = .include };
    try testing.expect(!f.accepts(testDataEvent()));
}

test "GuidFilter: include matches the sender or the destination" {
    const a = GuidPrefix{ .bytes = @splat(0xA1) };
    const b = GuidPrefix{ .bytes = @splat(0xB2) };
    const c = GuidPrefix{ .bytes = @splat(0xC3) };
    const f = GuidFilter{ .mode = .include, .prefixes = &.{b.bytes} };
    try testing.expect(f.accepts(eventBetween(a, b)));
    try testing.expect(f.accepts(eventBetween(b, a)));
    try testing.expect(!f.accepts(eventBetween(a, c)));
    // An event with no known participant involves none listed.
    try testing.expect(!f.accepts(testInfoTsEvent()));
}

test "GuidFilter: exclude drops events to or from a listed participant" {
    const a = GuidPrefix{ .bytes = @splat(0xA1) };
    const b = GuidPrefix{ .bytes = @splat(0xB2) };
    const c = GuidPrefix{ .bytes = @splat(0xC3) };
    const f = GuidFilter{ .mode = .exclude, .prefixes = &.{b.bytes} };
    try testing.expect(!f.accepts(eventBetween(a, b)));
    try testing.expect(!f.accepts(eventBetween(b, c)));
    try testing.expect(f.accepts(eventBetween(a, c)));
    try testing.expect(f.accepts(testInfoTsEvent()));
}

test "TracerActive: the filter decides what reaches the sink" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ss = SyncSink{ .writer = &w, .format = .text };
    const a = GuidPrefix{ .bytes = @splat(0xA1) };
    const b = GuidPrefix{ .bytes = @splat(0xB2) };
    const tc = TracerActive{ .s = ss.sink(), .f = .{ .mode = .include, .prefixes = &.{b.bytes} } };
    tc.submit(eventBetween(a, a));
    try testing.expectEqual(@as(usize, 0), w.end);
    tc.submit(eventBetween(a, b));
    try testing.expect(std.mem.indexOf(u8, w.buffer[0..w.end], "SEND HB") != null);
}

test "formatEvent: a known destination is printed, an unknown one is not" {
    const a = GuidPrefix{ .bytes = @splat(0xA1) };
    const b = GuidPrefix{ .bytes = @splat(0xB2) };
    try checkFmt(.text, eventBetween(a, b), " dst=b2b2b2b2b2b2b2b2b2b2b2b2");
    try checkFmt(.ndjson, eventBetween(a, b), "\"dst\":\"b2b2b2b2b2b2b2b2b2b2b2b2\"");
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatEvent(&w, .text, eventBetween(a, GuidPrefix.unknown));
    try testing.expect(std.mem.indexOf(u8, w.buffer[0..w.end], "dst=") == null);
}

test "formatEvent ndjson: every event type is one valid JSON object" {
    const p = GuidPrefix{ .bytes = @splat(0xAB) };
    const events = [_]TraceEvent{
        testDataEvent(),    testRecvDataEvent(),             testSendHbEvent(),  testRecvHbEvent(),
        testSendAnEvent(),  testRecvAnEvent(),               testSendGapEvent(), testRecvGapEvent(),
        testInfoTsEvent(),  testInfoDstEvent(),              testDataDupEvent(), testHbDupEvent(),
        eventBetween(p, p), .{ .skipped = .{ .count = 2 } },
    };
    for (events) |ev| {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try formatEvent(&w, .ndjson, ev);
        const line = w.buffer[0..w.end];
        try testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line[0 .. line.len - 1], .{});
        parsed.deinit();
    }
}

test "tracersFor: the scope picks which tracers trace, and an override replaces the sink" {
    if (comptime !enabled) return error.SkipZigTest;
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ss = SyncSink{ .writer = &w, .format = .text };
    for ([_]schema.TraceScope{ .all, .discovery, .user }) |scope| {
        w.end = 0;
        const cfg = schema.TraceConfig{ .scope = scope };
        const t = tracersFor(&cfg, ss.sink());
        t.discovery.submit(testDataEvent());
        const after_discovery = w.end;
        t.user.submit(testDataEvent());
        try testing.expectEqual(scope != .user, after_discovery > 0);
        try testing.expectEqual(scope != .discovery, w.end > after_discovery);
    }
}

test "tracersFor: no sink and no override traces nothing" {
    const cfg = schema.TraceConfig{};
    const t = tracersFor(&cfg, null);
    t.discovery.submit(testDataEvent());
    t.user.submit(testDataEvent());
}

test "tracersFor: a configured file sink is opened once and shared" {
    if (comptime !enabled) return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "zzdds_trace_sink_test.txt";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const cfg = schema.TraceConfig{ .sink = .{ .file = path } };
    const first = tracersFor(&cfg, null);
    // A sink that failed to open would leave the no-op sink, which every
    // tracer shares.
    try testing.expect(first.user.s.vtable != &noop_vtable);
    const second = tracersFor(&cfg, null);
    try testing.expectEqual(first.user.s.ctx, second.user.s.ctx);
    // Another spelling of the same path shares the sink rather than
    // truncating the file under it.
    const dotted = schema.TraceConfig{ .sink = .{ .file = "./" ++ path } };
    first.user.submit(testRecvDataEvent());
    const third = tracersFor(&dotted, null);
    try testing.expectEqual(first.user.s.ctx, third.user.s.ctx);
    first.user.submit(testDataEvent());
    second.discovery.submit(testSendHbEvent());
    const written = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(4096));
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "RECV DATA") != null);
    try testing.expect(std.mem.indexOf(u8, written, "SEND DATA") != null);
    try testing.expect(std.mem.indexOf(u8, written, "SEND HB") != null);
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

test "AsyncRingSink: flush writes what is queued on the caller's thread, with no flush thread" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ring = try AsyncRingSink.init(testing.allocator, 2, &w, .ndjson);
    defer ring.deinit();
    ring.sink().submit(testDataEvent());
    try testing.expectEqual(@as(usize, 0), w.end);
    ring.flush();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffer[0..w.end], "\"t\":\"send_data\""));

    // Past capacity between flushes: the next flush reports the drops first.
    for (0..3) |_| ring.sink().submit(testDataEvent());
    ring.flush();
    const out = w.buffer[0..w.end];
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\"t\":\"send_data\""));
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":1") != null);
    const skipped = std.mem.indexOf(u8, out, "\"t\":\"skipped\"").?;
    try testing.expect(skipped < std.mem.lastIndexOf(u8, out, "\"t\":\"send_data\"").?);

    // Nothing queued: nothing written.
    const end = w.end;
    ring.flush();
    try testing.expectEqual(end, w.end);
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
    const p = GuidPrefix{ .bytes = @splat(0xAB) };
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
