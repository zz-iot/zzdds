//! Hand-written C ABI bootstrap for zzdds.
//!
//! Provides C-callable raw sample exports:
//!
//!   zzdds_write_raw               — CDR bytes → RTPS wire
//!   zzdds_take_one_raw            — RTPS wire → CDR bytes (any sample)
//!   zzdds_take_one_raw_instance   — RTPS wire → CDR bytes (take_next_instance)
//!
//! These exports are intentionally type-agnostic.  The caller is responsible for
//! CDR serialization/deserialization (use the zidl-generated shape.h helpers).
//!
const std = @import("std");

const DDS = @import("zzdds_generated").DDS;

const DataWriterImpl = @import("../dcps/writer.zig").DataWriterImpl;
const DataReaderImpl = @import("../dcps/reader.zig").DataReaderImpl;
const TopicImpl = @import("../dcps/topic.zig").TopicImpl;
const time_mod = @import("../util/time.zig");
const history_mod = @import("../rtps/history.zig");
const nil = @import("../dcps/nil.zig");
const zidl_rt = @import("zidl_rt");

// Every exported function below takes entity parameters (writer/reader/topic)
// as `*anyopaque` -- the boxed C-ABI handle matching zzdds_c.h's opaque
// pointer typedefs (DDS_DataWriter, DDS_DataReader, DDS_Topic) -- and unboxes
// via zidl_rt.unboxAs to recover the native {ptr, vtable} fat pointer before
// touching `.ptr`. Passing the native fat-pointer struct as the parameter
// type directly (as this file previously did throughout) is a real C-ABI
// layout mismatch: the struct is 16 bytes (two pointer fields) where the
// actual C caller only ever has an 8-byte opaque pointer, corrupting every
// argument after it in the call. Confirmed via a real crash from a real C
// program (not just a hypothetical) — see zzdds_register_type_support_c's
// fix in typesupport.zig for the first instance of this bug and the repro
// that found it.

// ── SampleInfo for C ─────────────────────────────────────────────────────────
// Minimal extern struct matching SH_SampleInfo in shape_configurator_zzdds.h.

pub const CSampleInfo = extern struct {
    valid_data: bool,
    instance_state: u32,
    instance_handle: DDS.InstanceHandle_t,
};

pub const CWriteKind = enum(c_int) {
    alive = 0,
    dispose = 1,
    unregister = 2,
};

pub const CLoanedSample = extern struct {
    data: ?[*]const u8,
    data_len: usize,
    owner: ?*anyopaque,
};

const LoanedRawSample = struct {
    data: []u8,
    alloc: std.mem.Allocator,
};

// ── Topic → TopicDescription conversion ──────────────────────────────────────

/// Convert a DDS_Topic to a DDS_TopicDescription with the correct vtable.
/// A direct memcpy of the {ptr, vtable} fields is WRONG because Topic and
/// TopicDescription have different vtable layouts — use the Topic vtable's
/// own as_TopicDescription slot to get the right one, then box the result via
/// its own get_c_abi_handle (which returns the cached, identity-stable
/// TopicDescription handle — TopicImpl.td_c_abi — not a fresh box per call).
///
/// This mirrors what the --zig-generate-c-api-generated
/// DDS_Topic_as_DDS_TopicDescription does internally, rather than calling
/// that generated function directly: this file (c_abi's hand-written
/// bootstrap shim) is compiled unconditionally, but --zig-generate-c-api's
/// generated exports only exist when C bindings are actually requested
/// (need_c_abi) — depending on one from the other would make this function
/// uncompilable in a Zig-only build.
pub export fn zzdds_topic_as_description(topic: *anyopaque) callconv(.c) *anyopaque {
    const t = zidl_rt.unboxAs(DDS.Topic, topic);
    const r = t.vtable.as_TopicDescription(t.ptr);
    return r.vtable.get_c_abi_handle(r.ptr);
}

// ── Raw write ────────────────────────────────────────────────────────────────

/// Write a pre-serialized CDR payload (including 4-byte encap header).
/// `key_hash` is the 16-byte MD5 key hash computed by `ShapeType_compute_key_hash`.
/// `handle`: pass DDS.HANDLE_NIL to derive the instance automatically from
/// `key_hash`, or a handle previously returned by zzdds_register_instance_raw
/// (or this same write function) for that key -- any other value is a caller
/// error (DDS spec: write() with a handle that doesn't correspond to the
/// data's key returns BAD_PARAMETER).
pub export fn zzdds_write_raw(
    writer: *anyopaque,
    key_hash: *const [16]u8,
    handle: DDS.InstanceHandle_t,
    data: [*]const u8,
    data_len: usize,
) callconv(.c) DDS.ReturnCode_t {
    return zzdds_write_raw_kind(writer, .alive, key_hash, handle, data, data_len);
}

pub export fn zzdds_write_raw_kind(
    writer: *anyopaque,
    kind: CWriteKind,
    key_hash: *const [16]u8,
    handle: DDS.InstanceHandle_t,
    data: [*]const u8,
    data_len: usize,
) callconv(.c) DDS.ReturnCode_t {
    const w = zidl_rt.unboxAs(DDS.DataWriter, writer);
    if (nil.isNil(w)) return 1;
    const impl: *DataWriterImpl = @ptrCast(@alignCast(w.ptr));
    const change_kind: history_mod.ChangeKind = switch (kind) {
        .alive => .alive,
        .dispose => .not_alive_disposed,
        .unregister => if (impl.qos.writer_data_lifecycle.autodispose_unregistered_instances)
            .not_alive_disposed
        else
            .not_alive_unregistered,
    };
    if (handle != DDS.HANDLE_NIL and handle != DataWriterImpl.registerInstanceRaw(key_hash.*)) {
        return DDS.RETCODE_BAD_PARAMETER;
    }
    // instance_handle here is the internal per-instance grouping key used by
    // History's KEEP_LAST trimming (trimForKeepLast) -- it must be the
    // sample's actual key hash, not a NIL placeholder, or KEEP_LAST collapses
    // every instance into one shared bucket instead of trimming per-instance.
    _ = impl.writeRaw(
        change_kind,
        time_mod.RtpsTimestamp.now(),
        key_hash.*,
        key_hash.*,
        data[0..data_len],
    ) catch return 1;
    return 0;
}

// ── Raw take ─────────────────────────────────────────────────────────────────

/// Take the next available sample regardless of instance.
/// Copies the CDR payload into `cdr_buf[0..buf_size]`; sets `*cdr_len_out` to actual length.
/// Returns 1 on success, 0 if queue empty, -1 on buffer-too-small error.
///
/// NOTE: the sample is dequeued before the size check.  On -1, the sample is
/// discarded; `cdr_len_out` reports the required size for diagnostic purposes.
/// Pass a buffer of at least 65536 bytes to avoid data loss.
pub export fn zzdds_take_one_raw(
    reader: *anyopaque,
    cdr_buf: [*]u8,
    buf_size: usize,
    cdr_len_out: *usize,
    info_out: *CSampleInfo,
) callconv(.c) c_int {
    const r = zidl_rt.unboxAs(DDS.DataReader, reader);
    if (nil.isNil(r)) return -2;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(r.ptr));
    const s = impl.takeRaw() orelse return 0;
    defer impl.alloc.free(s.data);
    cdr_len_out.* = s.data.len;
    if (s.data.len > buf_size) return -1;
    @memcpy(cdr_buf[0..s.data.len], s.data);
    info_out.* = .{
        .valid_data = s.info.valid_data,
        .instance_state = s.info.instance_state,
        .instance_handle = s.info.instance_handle,
    };
    return 1;
}

pub export fn zzdds_take_loaned_raw(
    reader: *anyopaque,
    loan_out: *CLoanedSample,
    info_out: *CSampleInfo,
) callconv(.c) c_int {
    const r = zidl_rt.unboxAs(DDS.DataReader, reader);
    if (nil.isNil(r)) return -2;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(r.ptr));
    const s = impl.takeRaw() orelse return 0;
    const owner = std.heap.c_allocator.create(LoanedRawSample) catch {
        std.log.err("zzdds_take_loaned_raw: sample permanently lost — OOM allocating loan handle", .{});
        impl.alloc.free(s.data);
        return -1;
    };
    owner.* = .{ .data = s.data, .alloc = impl.alloc };
    loan_out.* = .{
        .data = s.data.ptr,
        .data_len = s.data.len,
        .owner = owner,
    };
    info_out.* = .{
        .valid_data = s.info.valid_data,
        .instance_state = s.info.instance_state,
        .instance_handle = s.info.instance_handle,
    };
    return 1;
}

pub export fn zzdds_return_loaned_raw(
    reader: *anyopaque,
    loan: *CLoanedSample,
) callconv(.c) void {
    _ = reader;
    const opaque_owner = loan.owner orelse return;
    const owner: *LoanedRawSample = @ptrCast(@alignCast(opaque_owner));
    owner.alloc.free(owner.data);
    std.heap.c_allocator.destroy(owner);
    loan.* = .{
        .data = null,
        .data_len = 0,
        .owner = null,
    };
}

/// take_next_instance semantics: take one sample from the instance with the
/// smallest handle strictly greater than `prev_instance_handle`.
/// Pass 0 (HANDLE_NIL) to start iteration from the minimum-handle instance.
/// Returns 1 on success, 0 if no qualifying sample, -1 on buffer-too-small error.
///
/// NOTE: the sample is dequeued before the size check.  On -1, the sample is
/// discarded; `cdr_len_out` reports the required size for diagnostic purposes.
/// Pass a buffer of at least 65536 bytes to avoid data loss.
pub export fn zzdds_take_one_raw_instance(
    reader: *anyopaque,
    prev_instance_handle: DDS.InstanceHandle_t,
    cdr_buf: [*]u8,
    buf_size: usize,
    cdr_len_out: *usize,
    info_out: *CSampleInfo,
) callconv(.c) c_int {
    const r = zidl_rt.unboxAs(DDS.DataReader, reader);
    if (nil.isNil(r)) return -2;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(r.ptr));
    const s = impl.takeNextInstanceRaw(prev_instance_handle) orelse return 0;
    defer impl.alloc.free(s.data);
    cdr_len_out.* = s.data.len;
    if (s.data.len > buf_size) return -1;
    @memcpy(cdr_buf[0..s.data.len], s.data);
    info_out.* = .{
        .valid_data = s.info.valid_data,
        .instance_state = s.info.instance_state,
        .instance_handle = s.info.instance_handle,
    };
    return 1;
}

// ── New writer operations ────────────────────────────────────────────────────

/// Return the DDS instance handle for a key hash without writing.
/// Always succeeds (deterministic hash mapping).
pub export fn zzdds_register_instance_raw(
    writer: *anyopaque,
    key_hash: *const [16]u8,
) callconv(.c) DDS.InstanceHandle_t {
    _ = writer;
    return DataWriterImpl.registerInstanceRaw(key_hash.*);
}

/// Write with an explicit source timestamp. `handle`: see zzdds_write_raw_kind.
pub export fn zzdds_write_raw_w_timestamp(
    writer: *anyopaque,
    kind: CWriteKind,
    key_hash: *const [16]u8,
    handle: DDS.InstanceHandle_t,
    data: [*]const u8,
    data_len: usize,
    ts: DDS.Time_t,
) callconv(.c) DDS.ReturnCode_t {
    const w = zidl_rt.unboxAs(DDS.DataWriter, writer);
    if (nil.isNil(w)) return 1;
    const impl: *DataWriterImpl = @ptrCast(@alignCast(w.ptr));
    const change_kind: history_mod.ChangeKind = switch (kind) {
        .alive => .alive,
        .dispose => .not_alive_disposed,
        .unregister => if (impl.qos.writer_data_lifecycle.autodispose_unregistered_instances)
            .not_alive_disposed
        else
            .not_alive_unregistered,
    };
    if (handle != DDS.HANDLE_NIL and handle != DataWriterImpl.registerInstanceRaw(key_hash.*)) {
        return DDS.RETCODE_BAD_PARAMETER;
    }
    const t = time_mod.Time{ .sec = ts.sec, .nanosec = ts.nanosec };
    const rtps_ts = time_mod.RtpsTimestamp.fromTime(t);
    _ = impl.writeRaw(change_kind, rtps_ts, key_hash.*, key_hash.*, data[0..data_len]) catch return 1;
    return 0;
}

/// Copy the stored CDR payload for `handle` into `buf[0..buf_size]`.
/// Sets `*len_out` to the actual payload size.
/// Returns 0 on success, -1 if handle unknown, -2 if buffer too small.
pub export fn zzdds_get_key_value_writer(
    writer: *anyopaque,
    handle: DDS.InstanceHandle_t,
    buf: [*]u8,
    buf_size: usize,
    len_out: *usize,
) callconv(.c) c_int {
    const w = zidl_rt.unboxAs(DDS.DataWriter, writer);
    if (nil.isNil(w)) return -1;
    const impl: *DataWriterImpl = @ptrCast(@alignCast(w.ptr));
    const kv = impl.getKeyValueRaw(handle) orelse return -1;
    len_out.* = kv.len;
    if (kv.len > buf_size) return -2;
    @memcpy(buf[0..kv.len], kv);
    return 0;
}

/// Look up the instance handle for a key hash (always deterministic).
pub export fn zzdds_lookup_instance_writer(
    writer: *anyopaque,
    key_hash: *const [16]u8,
) callconv(.c) DDS.InstanceHandle_t {
    _ = writer;
    return DataWriterImpl.registerInstanceRaw(key_hash.*);
}

// ── New reader operations ─────────────────────────────────────────────────────

/// read_next_sample: non-destructively return one sample (marks it READ).
/// Returns 1 on success, 0 if queue empty, -1 on buffer-too-small.
pub export fn zzdds_read_one_raw(
    reader: *anyopaque,
    cdr_buf: [*]u8,
    buf_size: usize,
    cdr_len_out: *usize,
    info_out: *CSampleInfo,
) callconv(.c) c_int {
    const r = zidl_rt.unboxAs(DDS.DataReader, reader);
    if (nil.isNil(r)) return -2;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(r.ptr));
    var tmp: std.ArrayListUnmanaged(@import("../dcps/reader.zig").TakenSample) = .empty;
    defer {
        for (tmp.items) |s| impl.alloc.free(s.data);
        tmp.deinit(impl.alloc);
    }
    impl.readRaw(
        &tmp,
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        1,
        null,
        null,
    ) catch return -2;
    if (tmp.items.len == 0) return 0;
    const s = tmp.items[0];
    cdr_len_out.* = s.data.len;
    if (s.data.len > buf_size) return -1;
    @memcpy(cdr_buf[0..s.data.len], s.data);
    info_out.* = .{
        .valid_data = s.info.valid_data,
        .instance_state = s.info.instance_state,
        .instance_handle = s.info.instance_handle,
    };
    return 1;
}

/// read_next_instance: non-destructively return one sample for the next instance.
/// Returns 1 on success, 0 if no qualifying sample, -1 on buffer-too-small.
pub export fn zzdds_read_one_raw_instance(
    reader: *anyopaque,
    prev_instance_handle: DDS.InstanceHandle_t,
    cdr_buf: [*]u8,
    buf_size: usize,
    cdr_len_out: *usize,
    info_out: *CSampleInfo,
) callconv(.c) c_int {
    const r = zidl_rt.unboxAs(DDS.DataReader, reader);
    if (nil.isNil(r)) return -2;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(r.ptr));
    const s = impl.readNextInstanceRaw(prev_instance_handle) orelse return 0;
    defer impl.alloc.free(s.data);
    cdr_len_out.* = s.data.len;
    if (s.data.len > buf_size) return -1;
    @memcpy(cdr_buf[0..s.data.len], s.data);
    info_out.* = .{
        .valid_data = s.info.valid_data,
        .instance_state = s.info.instance_state,
        .instance_handle = s.info.instance_handle,
    };
    return 1;
}

/// C representation of a batch of raw samples.
/// Allocated by zzdds_take_n_raw / zzdds_read_n_raw; freed by zzdds_return_raw_samples.
pub const CRawSample = extern struct {
    data: ?[*]u8,
    data_len: usize,
    info: CSampleInfo,
};

pub const CRawSampleArray = extern struct {
    samples: ?[*]CRawSample,
    count: usize,
    _alloc_capacity: usize, // internal; do not modify
};

fn nRawImpl(
    reader: *anyopaque,
    ss: DDS.SampleStateMask,
    vs: DDS.ViewStateMask,
    is: DDS.InstanceStateMask,
    max: c_int,
    out: *CRawSampleArray,
    destructive: bool,
) c_int {
    out.* = .{ .samples = null, .count = 0, ._alloc_capacity = 0 };
    const r = zidl_rt.unboxAs(DDS.DataReader, reader);
    if (nil.isNil(r)) return -1;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(r.ptr));
    const alloc = std.heap.c_allocator;

    // For bounded destructive takes, pre-allocate the output struct array BEFORE
    // removing samples from the queue.  Without this, an OOM at the alloc step
    // would silently discard already-taken data with no way to recover it.
    // For unbounded destructive takes (max <= 0), peek the count via readRaw
    // first to enable the same pre-allocation guarantee.  As a consequence,
    // samples that arrive between the peek and the take are NOT included in
    // this call; they remain in the queue and will be returned by the next call.
    // _alloc_capacity may exceed count; zzdds_return_raw_samples uses it for the
    // free, so over-allocating is safe.
    var unbounded_take_max: c_int = 0;
    if (destructive and max <= 0) {
        var peek: std.ArrayListUnmanaged(@import("../dcps/reader.zig").TakenSample) = .empty;
        defer {
            for (peek.items) |s| impl.alloc.free(s.data);
            peek.deinit(impl.alloc);
        }
        impl.readRaw(&peek, ss, vs, is, -1, null, null) catch return -1;
        if (peek.items.len == 0) {
            out.* = .{ .samples = null, .count = 0, ._alloc_capacity = 0 };
            return 0;
        }
        if (peek.items.len > std.math.maxInt(c_int)) return -1;
        unbounded_take_max = @intCast(peek.items.len);
    }

    // pre_capacity may exceed the number of samples actually taken: concurrent
    // removal between the readRaw peek and takeFiltered can reduce the result
    // below unbounded_take_max.  Entries pre_arr[count.._alloc_capacity-1] are
    // uninitialized; callers must iterate `count` for individual frees and use
    // `_alloc_capacity` only for the array-level free.
    const pre_capacity: usize =
        if (destructive and max > 0) @intCast(max) else if (destructive) @intCast(unbounded_take_max) else 0;
    const pre_arr: []CRawSample = if (pre_capacity > 0)
        alloc.alloc(CRawSample, pre_capacity) catch return -1
    else
        &.{};

    var tmp: std.ArrayListUnmanaged(@import("../dcps/reader.zig").TakenSample) = .empty;
    defer {
        for (tmp.items) |s| impl.alloc.free(s.data);
        tmp.deinit(impl.alloc);
    }
    if (destructive) {
        const take_max = if (max <= 0) unbounded_take_max else max;
        impl.takeFiltered(&tmp, ss, vs, is, take_max, null, null) catch {
            if (pre_arr.len > 0) alloc.free(pre_arr);
            return -1;
        };
    } else {
        impl.readRaw(&tmp, ss, vs, is, max, null, null) catch return -1;
    }
    if (tmp.items.len == 0) {
        if (pre_arr.len > 0) alloc.free(pre_arr);
        out.* = .{ .samples = null, .count = 0, ._alloc_capacity = 0 };
        return 0;
    }
    // Use the pre-allocated array for all destructive takes; otherwise alloc now
    // (samples remain in queue on non-destructive failure, so this is safe).
    const arr: []CRawSample = if (pre_arr.len > 0)
        pre_arr
    else
        alloc.alloc(CRawSample, tmp.items.len) catch return -1;
    for (tmp.items, 0..) |s, i| {
        const copy = alloc.dupe(u8, s.data) catch {
            if (destructive)
                std.log.err("zzdds_take_n_raw: OOM copying sample {d}/{d} — all {d} taken samples permanently lost", .{ i, tmp.items.len, tmp.items.len })
            else
                std.log.err("zzdds_read_n_raw: OOM copying sample {d}/{d} — samples remain in queue, caller may retry", .{ i, tmp.items.len });
            for (arr[0..i]) |prev| alloc.free(prev.data.?[0..prev.data_len]);
            alloc.free(arr);
            return -1;
        };
        arr[i] = .{
            .data = copy.ptr,
            .data_len = copy.len,
            .info = .{
                .valid_data = s.info.valid_data,
                .instance_state = s.info.instance_state,
                .instance_handle = s.info.instance_handle,
            },
        };
    }
    out.* = .{ .samples = arr.ptr, .count = tmp.items.len, ._alloc_capacity = arr.len };
    return @intCast(tmp.items.len);
}

/// Batch take: remove up to `max` samples matching the given state masks.
/// Populates `out`; caller must call zzdds_return_raw_samples when done.
/// Returns sample count on success, 0 if empty, -1 on error.
pub export fn zzdds_take_n_raw(
    reader: *anyopaque,
    ss: DDS.SampleStateMask,
    vs: DDS.ViewStateMask,
    is: DDS.InstanceStateMask,
    max: c_int,
    out: *CRawSampleArray,
) callconv(.c) c_int {
    return nRawImpl(reader, ss, vs, is, max, out, true);
}

/// Batch read: non-destructively return up to `max` samples matching the masks.
/// Populates `out`; caller must call zzdds_return_raw_samples when done.
/// Returns sample count on success, 0 if empty, -1 on error.
pub export fn zzdds_read_n_raw(
    reader: *anyopaque,
    ss: DDS.SampleStateMask,
    vs: DDS.ViewStateMask,
    is: DDS.InstanceStateMask,
    max: c_int,
    out: *CRawSampleArray,
) callconv(.c) c_int {
    return nRawImpl(reader, ss, vs, is, max, out, false);
}

/// Free a CRawSampleArray returned by zzdds_take_n_raw or zzdds_read_n_raw.
pub export fn zzdds_return_raw_samples(
    reader: *anyopaque,
    arr: *CRawSampleArray,
) callconv(.c) void {
    _ = reader;
    if (arr.samples) |samples| {
        const alloc = std.heap.c_allocator;
        for (samples[0..arr.count]) |s| {
            if (s.data) |d| alloc.free(d[0..s.data_len]);
        }
        alloc.free(samples[0..arr._alloc_capacity]);
    }
    arr.* = .{ .samples = null, .count = 0, ._alloc_capacity = 0 };
}

/// Copy the stored CDR payload for `handle` into `buf[0..buf_size]`.
/// Returns 0 on success, -1 if handle unknown, -2 if buffer too small.
pub export fn zzdds_get_key_value_reader(
    reader: *anyopaque,
    handle: DDS.InstanceHandle_t,
    buf: [*]u8,
    buf_size: usize,
    len_out: *usize,
) callconv(.c) c_int {
    const r = zidl_rt.unboxAs(DDS.DataReader, reader);
    if (nil.isNil(r)) return -1;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(r.ptr));
    const kv = impl.getKeyValueRaw(handle) orelse return -1;
    len_out.* = kv.len;
    if (kv.len > buf_size) return -2;
    @memcpy(buf[0..kv.len], kv);
    return 0;
}

/// Return the instance handle for a key hash if the instance is known to this reader.
/// Returns the handle if ALIVE, 0 (HANDLE_NIL) if unknown or not alive.
pub export fn zzdds_lookup_instance_reader(
    reader: *anyopaque,
    key_hash: *const [16]u8,
) callconv(.c) DDS.InstanceHandle_t {
    const r = zidl_rt.unboxAs(DDS.DataReader, reader);
    if (nil.isNil(r)) return 0;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(r.ptr));
    // Compute handle from key hash and check if it's known alive.
    const handle = DataWriterImpl.registerInstanceRaw(key_hash.*);
    return if (impl.lookupInstance(handle)) handle else 0;
}
