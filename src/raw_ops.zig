//! Module-level public API for raw DDS operations.
//!
//! This is the surface that zidl-generated typed wrappers call into via
//!   const _zzdds = @import("zzdds");
//!
//! Functions here translate between DDS entity handles (vtable pointers) and
//! the concrete DataWriterImpl / DataReaderImpl structs, then delegate to the
//! impl methods.

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const dcps_writer = @import("dcps/writer.zig");
const dcps_reader = @import("dcps/reader.zig");
const history_mod = @import("rtps/history.zig");
const time_mod = @import("util/time.zig");

const DataWriterImpl = dcps_writer.DataWriterImpl;
const DataReaderImpl = dcps_reader.DataReaderImpl;

/// Write kind for module-level write operations.
pub const WriteKind = enum { alive, dispose, unregister };

/// A raw sample taken from a DataReader.  Caller must call deinit() when done.
pub const OwnedRawSample = struct {
    data: []u8,
    info: DDS.SampleInfo,
    _alloc: std.mem.Allocator,

    pub fn deinit(self: @This()) void {
        self._alloc.free(self.data);
    }
};

fn toChangeKind(kind: WriteKind, impl: *DataWriterImpl) history_mod.ChangeKind {
    return switch (kind) {
        .alive => .alive,
        .dispose => .not_alive_disposed,
        .unregister => if (impl.qos.writer_data_lifecycle.autodispose_unregistered_instances)
            .not_alive_disposed
        else
            .not_alive_unregistered,
    };
}

// ── QoS helpers ──────────────────────────────────────────────────────────────

/// Return true if the writer's data-representation QoS specifies XCDRv2.
/// Reads the QoS directly from DataWriterImpl without allocating.
pub fn writerUsesXcdr2(writer: DDS.DataWriter) bool {
    const impl: *DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    const rep = impl.qos.data_representation.value;
    if (rep._length == 0) return false;
    const buf = rep._buffer orelse return false;
    return buf[0] == DDS.XCDR2_DATA_REPRESENTATION;
}

// ── Writer operations ─────────────────────────────────────────────────────────

/// Write a pre-serialized CDR payload using the current time as source timestamp.
pub fn writeRaw(
    writer: DDS.DataWriter,
    kind: WriteKind,
    key_hash: [16]u8,
    data: []const u8,
) !void {
    const impl: *DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    const ck = toChangeKind(kind, impl);
    _ = try impl.writeRaw(ck, time_mod.RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, key_hash, data);
}

/// Write a pre-serialized CDR payload with an explicit source timestamp.
pub fn writeRawWithTimestamp(
    writer: DDS.DataWriter,
    kind: WriteKind,
    key_hash: [16]u8,
    data: []const u8,
    ts: DDS.Time_t,
) !void {
    const impl: *DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    const ck = toChangeKind(kind, impl);
    const t = time_mod.Time{ .sec = ts.sec, .nanosec = ts.nanosec };
    const rtps_ts = time_mod.RtpsTimestamp.fromTime(t);
    _ = try impl.writeRaw(ck, rtps_ts, history_mod.INSTANCE_HANDLE_NIL, key_hash, data);
}

/// Compute a stable instance handle for a given key hash without writing.
pub fn registerInstanceRaw(
    key_hash: [16]u8,
) DDS.InstanceHandle_t {
    return DataWriterImpl.registerInstanceRaw(key_hash);
}

/// Return the stored CDR payload for the given instance handle, or null if
/// no alive write has been made for this instance.
/// The slice is valid until the next write to the writer or writer deinit.
pub fn getKeyValueRawWriter(
    writer: DDS.DataWriter,
    handle: DDS.InstanceHandle_t,
) ?[]u8 {
    const impl: *DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    return impl.getKeyValueRaw(handle);
}

/// Look up the instance handle for a key hash.  Always succeeds (deterministic
/// hash → handle mapping); returns the handle whether or not any alive write
/// has been made.
pub fn lookupInstanceWriter(key_hash: [16]u8) DDS.InstanceHandle_t {
    return DataWriterImpl.registerInstanceRaw(key_hash);
}

// ── Reader operations ─────────────────────────────────────────────────────────

/// Pop the next pending sample from the reader, or return null if empty.
/// Caller owns the returned OwnedRawSample and must call deinit().
pub fn takeRaw(reader: DDS.DataReader) ?OwnedRawSample {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    const taken = impl.takeRaw() orelse return null;
    return .{ .data = taken.data, .info = taken.info, ._alloc = impl.alloc };
}

/// Non-destructively return the next pending sample, or null if empty.
/// The sample's sample_state is updated to READ.
/// Caller owns the returned OwnedRawSample and must call deinit().
pub fn readNextSampleRaw(reader: DDS.DataReader) ?OwnedRawSample {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    // readRaw with ANY masks, limit 1, and no instance filter.
    var out: std.ArrayListUnmanaged(dcps_reader.TakenSample) = .empty;
    defer {
        for (out.items) |s| impl.alloc.free(s.data);
        out.deinit(impl.alloc);
    }
    impl.readRaw(
        &out,
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        1,
        null,
        null,
    ) catch return null;
    if (out.items.len == 0) return null;
    const s = out.items[0];
    out.items.len = 0; // prevent deinit from double-freeing
    return .{ .data = s.data, .info = s.info, ._alloc = impl.alloc };
}

/// Pop the next sample for the "next" instance after `prev` (HANDLE_NIL = first).
/// Caller owns the returned OwnedRawSample and must call deinit().
pub fn takeNextInstanceRaw(
    reader: DDS.DataReader,
    prev: DDS.InstanceHandle_t,
) ?OwnedRawSample {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    const taken = impl.takeNextInstanceRaw(prev) orelse return null;
    return .{ .data = taken.data, .info = taken.info, ._alloc = impl.alloc };
}

/// Non-destructively return the next sample for the "next" instance after `prev`.
/// The sample's sample_state is updated to READ.
/// Caller owns the returned OwnedRawSample and must call deinit().
pub fn readNextInstanceRaw(
    reader: DDS.DataReader,
    prev: DDS.InstanceHandle_t,
) ?OwnedRawSample {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    const taken = impl.readNextInstanceRaw(prev) orelse return null;
    return .{ .data = taken.data, .info = taken.info, ._alloc = impl.alloc };
}

/// Batch take: remove and return samples matching the given masks.
/// Appends to `out`; caller owns all appended OwnedRawSample values.
/// Pass max < 0 for no limit.
pub fn takeFilteredRaw(
    reader: DDS.DataReader,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    ss: DDS.SampleStateMask,
    vs: DDS.ViewStateMask,
    is: DDS.InstanceStateMask,
    maybe_ih: ?DDS.InstanceHandle_t,
    caller_alloc: std.mem.Allocator,
) !void {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    var tmp: std.ArrayListUnmanaged(dcps_reader.TakenSample) = .empty;
    defer {
        for (tmp.items) |s| impl.alloc.free(s.data);
        tmp.deinit(impl.alloc);
    }
    try impl.takeFiltered(&tmp, ss, vs, is, max, maybe_ih, null);
    // `out`'s backing storage must grow with `caller_alloc` (whatever the caller
    // will later use to deinit it) — not `impl.alloc`, which is this reader's own
    // internal allocator and is generally a different instance from the caller's.
    // Each item's `.data` buffer legitimately stays impl.alloc-owned via its own
    // `._alloc` field; only the container's growth allocator needs to match here.
    try out.ensureUnusedCapacity(caller_alloc, tmp.items.len);
    for (tmp.items) |s| {
        out.appendAssumeCapacity(.{ .data = s.data, .info = s.info, ._alloc = impl.alloc });
    }
    tmp.items.len = 0; // transferred ownership; prevent deinit double-free
}

/// Batch read: non-destructively return samples matching the given masks.
/// Appends to `out`; caller owns all appended OwnedRawSample values.
/// Pass max < 0 for no limit.
pub fn readFilteredRaw(
    reader: DDS.DataReader,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    ss: DDS.SampleStateMask,
    vs: DDS.ViewStateMask,
    is: DDS.InstanceStateMask,
    maybe_ih: ?DDS.InstanceHandle_t,
    caller_alloc: std.mem.Allocator,
) !void {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    var tmp: std.ArrayListUnmanaged(dcps_reader.TakenSample) = .empty;
    defer {
        for (tmp.items) |s| impl.alloc.free(s.data);
        tmp.deinit(impl.alloc);
    }
    try impl.readRaw(&tmp, ss, vs, is, max, maybe_ih, null);
    // See takeFilteredRaw: `out` must grow with the caller's allocator, not
    // impl.alloc, since the caller (not this reader) owns and will deinit `out`.
    try out.ensureUnusedCapacity(caller_alloc, tmp.items.len);
    for (tmp.items) |s| {
        out.appendAssumeCapacity(.{ .data = s.data, .info = s.info, ._alloc = impl.alloc });
    }
    tmp.items.len = 0;
}

/// Return the stored CDR payload for the given instance handle, or null if
/// no alive sample has arrived for this instance.
/// The slice is valid until the next write to this reader or reader deinit.
pub fn getKeyValueRawReader(
    reader: DDS.DataReader,
    handle: DDS.InstanceHandle_t,
) ?[]u8 {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    return impl.getKeyValueRaw(handle);
}

/// Return the instance handle for `handle` if it is a known ALIVE instance,
/// or HANDLE_NIL (0) otherwise.
pub fn lookupInstanceReader(
    reader: DDS.DataReader,
    handle: DDS.InstanceHandle_t,
) ?DDS.InstanceHandle_t {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    return if (impl.lookupInstance(handle)) handle else null;
}
