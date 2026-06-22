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
const msg_builder = @import("message/builder.zig");

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
        .wait_all_acked = vtWaitAllAcked,
        .cache_len = vtCacheLen,
        .begin_coherent_set = vtBeginCoherentSet,
        .coherent_window_count = vtCoherentWindowCount,
        .end_coherent_set = vtEndCoherentSet,
        .take_eoc_proxy_infos = vtTakeEOCProxyInfos,
        .send_combined_eoc_data = vtSendCombinedEOCData,
        .flush_group_eoc_hb_only = vtFlushGroupEOCHBOnly,
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

    fn vtWaitAllAcked(ctx: *anyopaque, target_sn: history_mod.SequenceNumber, deadline_ns: ?i64) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.writer.waitAllAcked(target_sn, deadline_ns);
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

    fn vtBeginCoherentSet(ctx: *anyopaque, is_coherent_window: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.beginCoherentSet(is_coherent_window);
    }

    fn vtCoherentWindowCount(ctx: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.writer.coherentWindowPendingCount();
    }

    fn vtEndCoherentSet(ctx: *anyopaque, mode: protocol.CoherentFlushMode, resuspend: bool, publisher_gsn: ?*i64, global_last_gsn: i64, defer_eoc: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.endCoherentSet(mode, resuspend, publisher_gsn, global_last_gsn, defer_eoc);
    }

    fn vtTakeEOCProxyInfos(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(protocol.EOCProxyInfo),
    ) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.mu.lock();
        defer self.writer.mu.unlock();
        const eoc_sn = self.writer.pending_eoc_sn orelse return;
        // Do NOT clear pending_eoc_sn here — keep it set so the background HB
        // thread cannot send a premature GAP before the EOC DATA is delivered.
        // flushGroupEOCHBOnly() will read and clear it after the combined send.
        for (self.writer.reader_proxies.items) |*rp| {
            if (rp.suppress_live_data) continue;
            for (rp.effectiveLocators()) |loc| {
                try out.append(alloc, .{
                    .locator = loc,
                    .reader_guid = rp.guid,
                    .writer_guid = self.writer.guid,
                    .eoc_sn = eoc_sn,
                });
            }
        }
    }

    fn vtSendCombinedEOCData(
        ctx: *anyopaque,
        infos: [*]const protocol.EOCProxyInfo,
        count: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const infos_slice = infos[0..count];
        if (infos_slice.len == 0) return;

        self.writer.mu.lock();
        defer self.writer.mu.unlock();

        var scratch: [msg_builder.SCRATCH_SIZE]u8 = undefined;

        // Group by (locator, destination participant prefix). O(n²) is fine for
        // small n (typically writer_count × reader_proxy_count ≤ ~10).
        // No cap: check whether this (locator, prefix) pair was already sent
        // in a prior iteration rather than tracking via a fixed-size bitset.
        for (infos_slice, 0..) |entry0, i| {
            // Skip if a previous group already covered this (locator, prefix).
            var handled = false;
            for (infos_slice[0..i]) |prev| {
                if (prev.locator.eql(entry0.locator) and
                    prev.reader_guid.prefix.eql(entry0.reader_guid.prefix))
                {
                    handled = true;
                    break;
                }
            }
            if (handled) continue;
            var b = msg_builder.MessageBuilder.init(&scratch, self.writer.guid.prefix);
            b.addInfoDst(entry0.reader_guid.prefix);
            for (infos_slice) |entry| {
                if (!entry.locator.eql(entry0.locator)) continue;
                if (!entry.reader_guid.prefix.eql(entry0.reader_guid.prefix)) continue;
                b.addData(.{
                    .reader_entity_id = entry.reader_guid.entity_id,
                    .writer_entity_id = entry.writer_guid.entity_id,
                    .writer_sn = entry.eoc_sn,
                    .no_payload = true,
                }, &.{});
            }
            writer_sm.sendIovecs(self.writer.transport, &entry0.locator, b.iovecs()) catch {};
        }
    }

    fn vtFlushGroupEOCHBOnly(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer.flushGroupEOCHBOnly();
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
        .historical_delivered = vtHistoricalDelivered,
        .deinit = vtDeinit,
    };

    fn vtSetDataCallback(ctx: *anyopaque, cb: protocol.DataCallback) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.reader.setCallback(.{
            .ctx = cb.ctx,
            .on_data = cb.on_data,
            .on_sample_lost = cb.on_sample_lost,
            .on_heartbeat = cb.on_heartbeat,
            .on_eoc = cb.on_eoc,
        });
    }

    fn vtSetWriterMatchCallback(ctx: *anyopaque, cb: protocol.WriterMatchCallback) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.writer_match_cb = cb;
    }

    fn vtAddMatchedWriter(ctx: *anyopaque, info: *const MatchedWriterInfo) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var proxy = try WriterProxy.init(
            self.alloc,
            info.guid,
            info.unicast_locators,
            info.multicast_locators,
            info.reliability == .reliable,
        );
        // Mark the proxy as awaiting history delivery when the remote writer offers
        // TRANSIENT_LOCAL (or stronger) history with RELIABLE reliability.
        proxy.history_established = !info.history_expected;
        try self.reader.addMatchedWriter(proxy);
        // Fire on_writer_alive after addMatchedWriter succeeds so DCPS never sees
        // a liveliness signal for a GUID that failed to be inserted as a proxy.
        // A matched writer is alive by definition (it just sent SEDP announcements).
        if (self.writer_match_cb) |cb| {
            if (cb.on_writer_alive) |f| f(cb.ctx, info.guid);
            cb.on_writer_matched(cb.ctx, info);
        }
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
        coherent_set_sn: ?history_mod.SequenceNumber,
        group_seq_num: ?history_mod.SequenceNumber,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const change = history_mod.CacheChange{
            .kind = kind,
            .writer_guid = writer_guid,
            .sequence_number = sn,
            .source_timestamp = source_timestamp,
            .instance_handle = history_mod.INSTANCE_HANDLE_NIL,
            .key_hash = key_hash,
            .data = serialized_payload,
            .coherent_set_sn = coherent_set_sn,
            .group_seq_num = group_seq_num,
        };
        // Signal liveliness only for writers already matched; unmatched writers are
        // handled by StatefulReader.handleData (buffered for reliable readers so the
        // SEDP race — data arriving before the writer proxy is established — is recovered).
        if (self.reader.isWriterMatched(writer_guid)) {
            if (self.writer_match_cb) |cb| {
                if (cb.on_writer_alive) |f| f(cb.ctx, writer_guid);
            }
        }
        // handleData stores a copy; unmatched reliable-reader data is buffered for replay.
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
        // A heartbeat proves the writer is alive, but only signal DCPS if the
        // writer is already matched — unmatched senders should not inject liveliness.
        if (self.reader.isWriterMatched(writer_guid)) {
            if (self.writer_match_cb) |cb| {
                if (cb.on_writer_alive) |f| f(cb.ctx, writer_guid);
            }
        }
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

    fn vtHistoricalDelivered(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.reader.historicalDelivered();
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};
