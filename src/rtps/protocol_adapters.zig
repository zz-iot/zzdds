//! ProtocolWriter / ProtocolReader adapters.
//!
//! Bridge the RTPS StatefulWriter/StatefulReader to the ProtocolWriter/Reader
//! vtable interfaces that the DCPS layer uses.  Each adapter is heap-allocated
//! and owns its RTPS state machine.
//!
//! Lifecycle:
//!   - `RtpsProtocolWriter.init(alloc, guid, transport, cache_depth, peer_reader_eid)`
//!     creates a StatefulWriter and wraps it.
//!   - `RtpsProtocolReader.init(alloc, guid, transport, cache_kind, cache_depth, reliable)`
//!     creates a StatefulReader and wraps it.
//!   - `deinit()` via the vtable frees both the state machine and the adapter.

const std = @import("std");
const protocol = @import("../protocol/interface.zig");
const writer_sm = @import("writer_sm.zig");
const reader_sm = @import("reader_sm.zig");
const history_mod = @import("history.zig");
const guid_mod = @import("guid.zig");
const trace_mod = @import("../trace.zig");
const submsg_mod = @import("message/submessage.zig");

pub const StatefulWriter = writer_sm.StatefulWriter;
pub const StatefulReader = reader_sm.StatefulReader;
pub const ReaderProxy = writer_sm.ReaderProxy;
pub const WriterProxy = reader_sm.WriterProxy;
pub const Guid = guid_mod.Guid;
pub const EntityId = guid_mod.EntityId;
pub const HistoryKind = history_mod.HistoryKind;
pub const ProtocolWriter = protocol.ProtocolWriter;
pub const ProtocolReader = protocol.ProtocolReader;
pub const MatchedReaderInfo = protocol.MatchedReaderInfo;
pub const MatchedWriterInfo = protocol.MatchedWriterInfo;

// ── RtpsProtocolWriter ────────────────────────────────────────────────────────

/// ProtocolWriter backed by a StatefulWriter.
pub const RtpsProtocolWriter = struct {
    alloc: std.mem.Allocator,
    writer: *StatefulWriter,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        guid: Guid,
        transport: writer_sm.Transport,
        cache_kind: HistoryKind,
        cache_depth: u32,
        peer_reader_eid: EntityId,
        frag_size: u16,
        replay_on_match: bool,
    ) !*Self {
        const w = try StatefulWriter.init(alloc, guid, transport, cache_kind, cache_depth, peer_reader_eid, frag_size, replay_on_match);
        errdefer w.deinit();
        const self = try alloc.create(Self);
        self.* = .{ .alloc = alloc, .writer = w };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.writer.deinit();
        self.alloc.destroy(self);
    }

    pub fn setTracer(self: *Self, t: trace_mod.Tracer) void {
        self.writer.setTracer(t);
    }

    pub fn toProtocolWriter(self: *Self) ProtocolWriter {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = ProtocolWriter.Vtable{
        .write = vtWrite,
        .add_matched_reader = vtAddMatchedReader,
        .remove_matched_reader = vtRemoveMatchedReader,
        .matched_reader_count = vtMatchedReaderCount,
        .list_matched_readers = vtListMatchedReaders,
        .handle_ack_nack = vtHandleAckNack,
        .handle_nack_frag = vtHandleNackFrag,
        .all_acked = vtAllAcked,
        .cache_len = vtCacheLen,
        .deinit = vtDeinit,
    };

    fn vtWrite(
        ctx: *anyopaque,
        kind: history_mod.ChangeKind,
        source_timestamp: history_mod.RtpsTimestamp,
        instance_handle: history_mod.InstanceHandle,
        key_hash: [16]u8,
        data: []const u8,
    ) anyerror!history_mod.SequenceNumber {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.writer.write(kind, source_timestamp, instance_handle, key_hash, data);
    }

    fn vtAddMatchedReader(ctx: *anyopaque, info: *const MatchedReaderInfo) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const proxy = try ReaderProxy.init(
            self.alloc,
            info.guid,
            info.unicast_locators,
            info.multicast_locators,
            info.expects_inline_qos,
            info.reliability == .reliable,
        );
        try self.writer.addMatchedReader(proxy);
    }

    fn vtAllAcked(ctx: *anyopaque, target_sn: history_mod.SequenceNumber) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.writer.allProxiesAcked(target_sn);
    }

    fn vtRemoveMatchedReader(ctx: *anyopaque, guid: Guid) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.removeMatchedReader(guid);
    }

    fn vtMatchedReaderCount(ctx: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.mu.lock();
        defer self.writer.mu.unlock();
        return self.writer.reader_proxies.items.len;
    }

    fn vtListMatchedReaders(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(Guid),
    ) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.mu.lock();
        defer self.writer.mu.unlock();
        for (self.writer.reader_proxies.items) |*rp| {
            try out.append(alloc, rp.guid);
        }
    }

    fn vtHandleAckNack(
        ctx: *anyopaque,
        reader_guid: Guid,
        highest_sn: history_mod.SequenceNumber,
        nack_set: submsg_mod.SequenceNumberSet,
        count: i32,
        is_final: bool,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.handleAckNack(reader_guid, highest_sn, nack_set, count, is_final);
    }

    fn vtHandleNackFrag(
        ctx: *anyopaque,
        reader_guid: Guid,
        writer_sn: history_mod.SequenceNumber,
        frag_set: submsg_mod.FragmentNumberSet,
        count: i32,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.handleNackFrag(reader_guid, writer_sn, frag_set, count);
    }

    fn vtCacheLen(ctx: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.mu.lock();
        defer self.writer.mu.unlock();
        return self.writer.cache.len();
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

// ── RtpsProtocolReader ────────────────────────────────────────────────────────

/// ProtocolReader backed by a StatefulReader.
pub const RtpsProtocolReader = struct {
    alloc: std.mem.Allocator,
    reader: *StatefulReader,
    writer_match_cb: ?protocol.WriterMatchCallback = null,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        guid: Guid,
        transport: reader_sm.Transport,
        cache_kind: HistoryKind,
        cache_depth: u32,
        reliable: bool,
    ) !*Self {
        const r = try StatefulReader.init(alloc, guid, transport, cache_kind, cache_depth, reliable);
        errdefer r.deinit();
        const self = try alloc.create(Self);
        self.* = .{ .alloc = alloc, .reader = r };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.reader.deinit();
        self.alloc.destroy(self);
    }

    pub fn setTracer(self: *Self, t: trace_mod.Tracer) void {
        self.reader.setTracer(t);
    }

    pub fn toProtocolReader(self: *Self) ProtocolReader {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = ProtocolReader.Vtable{
        .set_data_callback = vtSetDataCallback,
        .set_writer_match_callback = vtSetWriterMatchCallback,
        .add_matched_writer = vtAddMatchedWriter,
        .remove_matched_writer = vtRemoveMatchedWriter,
        .matched_writer_count = vtMatchedWriterCount,
        .list_matched_writers = vtListMatchedWriters,
        .handle_incoming_change = vtHandleIncomingChange,
        .handle_heartbeat = vtHandleHeartbeat,
        .handle_data_frag = vtHandleDataFrag,
        .handle_heartbeat_frag = vtHandleHeartbeatFrag,
        .handle_gap = vtHandleGap,
        .deinit = vtDeinit,
    };

    fn vtSetDataCallback(ctx: *anyopaque, cb: protocol.DataCallback) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reader.setCallback(.{
            .ctx = cb.ctx,
            .on_data = cb.on_data,
        });
    }

    fn vtSetWriterMatchCallback(ctx: *anyopaque, cb: protocol.WriterMatchCallback) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer_match_cb = cb;
    }

    fn vtAddMatchedWriter(ctx: *anyopaque, info: *const MatchedWriterInfo) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const proxy = try WriterProxy.init(
            self.alloc,
            info.guid,
            info.unicast_locators,
            info.multicast_locators,
            info.reliability == .reliable,
        );
        try self.reader.addMatchedWriter(proxy);
        if (self.writer_match_cb) |cb| cb.on_writer_matched(cb.ctx, info);
    }

    fn vtRemoveMatchedWriter(ctx: *anyopaque, guid: Guid) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reader.removeMatchedWriter(guid);
        if (self.writer_match_cb) |cb| cb.on_writer_unmatched(cb.ctx, guid);
    }

    fn vtMatchedWriterCount(ctx: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reader.mu.lock();
        defer self.reader.mu.unlock();
        return self.reader.writer_proxies.items.len;
    }

    fn vtListMatchedWriters(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(Guid),
    ) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reader.mu.lock();
        defer self.reader.mu.unlock();
        for (self.reader.writer_proxies.items) |*wp| {
            try out.append(alloc, wp.guid);
        }
    }

    /// Deliver a DATA submessage from the RTPS message dispatcher.
    /// `serialized_payload` is borrowed — the cache makes its own copy.
    fn vtHandleIncomingChange(
        ctx: *anyopaque,
        writer_guid: Guid,
        sn: history_mod.SequenceNumber,
        source_timestamp: history_mod.RtpsTimestamp,
        key_hash: [16]u8,
        serialized_payload: []const u8,
        kind: history_mod.ChangeKind,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.reader.isWriterMatched(writer_guid)) return;
        const change = history_mod.CacheChange{
            .kind = kind,
            .writer_guid = writer_guid,
            .sequence_number = sn,
            .source_timestamp = source_timestamp,
            .instance_handle = history_mod.INSTANCE_HANDLE_NIL,
            .key_hash = key_hash,
            .data = serialized_payload,
        };
        // handleData stores a copy in the cache; on error just drop.
        self.reader.handleData(writer_guid, change) catch {};
    }

    fn vtHandleHeartbeat(
        ctx: *anyopaque,
        writer_guid: Guid,
        first_sn: history_mod.SequenceNumber,
        last_sn: history_mod.SequenceNumber,
        count: i32,
        final: bool,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reader.handleHeartbeat(writer_guid, first_sn, last_sn, count, final);
    }

    fn vtHandleDataFrag(
        ctx: *anyopaque,
        writer_guid: Guid,
        df: submsg_mod.DataFragSubmessage,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reader.handleDataFrag(writer_guid, df) catch {};
    }

    fn vtHandleHeartbeatFrag(
        ctx: *anyopaque,
        writer_guid: Guid,
        writer_sn: history_mod.SequenceNumber,
        last_frag_num: u32,
        count: i32,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reader.handleHeartbeatFrag(writer_guid, writer_sn, last_frag_num, count);
    }

    fn vtHandleGap(
        ctx: *anyopaque,
        writer_guid: Guid,
        gap_start: history_mod.SequenceNumber,
        gap_list: submsg_mod.SequenceNumberSet,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reader.handleGap(writer_guid, gap_start, gap_list);
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};
