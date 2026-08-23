//! Hand-written C ABI bootstrap for zzdds.
//!
//! The raw sample read/write/loan family that used to live here
//! (zzdds_write_raw, zzdds_take_one_raw, zzdds_take_n_raw,
//! zzdds_take_loaned_raw, etc.) has been superseded by real dcps.idl
//! operations (DDS.DataWriter.write_raw/loan_raw/publish_loan_raw,
//! DDS.DataReader.take_raw/read_raw/take_next_instance_raw/
//! read_next_instance_raw/return_loan_raw), generated uniformly across all
//! four zidl backends instead of hand-authored per binding -- see
//! zzdds/docs/design/raw-loan-api.md. What remains here is the handful of
//! small C-ABI helpers with no IDL-op equivalent: entity-view conversion and
//! the key-hash/instance-handle lookup helpers used by generated typed
//! wrappers.
//!
const std = @import("std");

const DDS = @import("zzdds_generated").DDS;

const DataWriterImpl = @import("../dcps/writer.zig").DataWriterImpl;
const DataReaderImpl = @import("../dcps/reader.zig").DataReaderImpl;
const TopicImpl = @import("../dcps/topic.zig").TopicImpl;
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
// program (not just a hypothetical) — see zzdds_register_type_support's
// fix in typesupport.zig for the first instance of this bug and the repro
// that found it.

/// True if a raw C-ABI handle is a literal NULL pointer -- distinct from
/// `nil.isNil`, which checks an *already-unboxed* entity's `.ptr == NIL_PTR`
/// sentinel. `zidl_rt.unboxAs` dereferences its argument unconditionally, so
/// a literal NULL passed by a C caller (a normal, expected "no object" value
/// in C, not UB) must be caught here, before unboxing, not after -- every
/// call site below checks this first.
fn isNullHandle(handle: *anyopaque) bool {
    return @intFromPtr(handle) == 0;
}

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
    if (isNullHandle(topic)) return nil.nil_topic_description.vtable.get_c_abi_handle(nil.nil_topic_description.ptr);
    const t = zidl_rt.unboxAsView(DDS.Topic, topic);
    const r = t.vtable.as_TopicDescription(t.ptr);
    return r.vtable.get_c_abi_handle(r.ptr);
}

// ── Instance-handle / key-hash lookup helpers ────────────────────────────────

/// Return the DDS instance handle for a key hash without writing.
/// Always succeeds (deterministic hash mapping).
pub export fn zzdds_register_instance_raw(
    writer: *anyopaque,
    key_hash: *const [16]u8,
) callconv(.c) DDS.InstanceHandle_t {
    _ = writer;
    return DataWriterImpl.registerInstanceRaw(key_hash.*);
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
    if (isNullHandle(writer)) return -1;
    const w = zidl_rt.unboxAsView(DDS.DataWriter, writer);
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

/// Copy the stored CDR payload for `handle` into `buf[0..buf_size]`.
/// Returns 0 on success, -1 if handle unknown, -2 if buffer too small.
pub export fn zzdds_get_key_value_reader(
    reader: *anyopaque,
    handle: DDS.InstanceHandle_t,
    buf: [*]u8,
    buf_size: usize,
    len_out: *usize,
) callconv(.c) c_int {
    if (isNullHandle(reader)) return -1;
    const r = zidl_rt.unboxAsView(DDS.DataReader, reader);
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
    if (isNullHandle(reader)) return 0;
    const r = zidl_rt.unboxAsView(DDS.DataReader, reader);
    if (nil.isNil(r)) return 0;
    const impl: *DataReaderImpl = @ptrCast(@alignCast(r.ptr));
    // Compute handle from key hash and check if it's known alive.
    const handle = DataWriterImpl.registerInstanceRaw(key_hash.*);
    return if (impl.lookupInstance(handle)) handle else 0;
}
