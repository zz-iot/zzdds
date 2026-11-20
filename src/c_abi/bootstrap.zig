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
const zidl_bindings = @import("zidl_bindings");

// Every exported function below takes entity parameters (writer/reader/topic)
// as `*anyopaque` -- the boxed C-ABI handle matching zzdds_c.h's opaque
// pointer typedefs (DDS_DataWriter, DDS_DataReader, DDS_Topic) -- and unboxes
// via zidl_bindings.unboxAs to recover the native {ptr, vtable} fat pointer before
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
/// sentinel. `zidl_bindings.unboxAs` dereferences its argument unconditionally, so
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
pub export fn zzdds_topic_as_description(topic: ?*anyopaque) callconv(.c) ?*anyopaque {
    // NULL, or a nil, is NULL, as for the generated upcast.
    const t = zidl_bindings.unboxAsView(DDS.Topic, topic orelse return null);
    const r = t.vtable.as_TopicDescription(t.ptr);
    if (r.ptr == nil.NIL_PTR) return null;
    return r.vtable.get_c_abi_handle(r.ptr);
}

// ── Instance-handle / key-hash lookup helpers ────────────────────────────────
//
// Each holds the entity's quiesce reference while it uses the entity, as
// `raw_ops` does, so a concurrent delete cannot free it part way through.

/// register_instance: the handle of the key hash's instance on `writer`,
/// registering it if it is not; 0 (HANDLE_NIL) if it cannot be.
pub export fn zzdds_register_instance_raw(
    writer: *anyopaque,
    key_hash: *const [16]u8,
) callconv(.c) DDS.InstanceHandle_t {
    const impl = writerImpl(writer) orelse return DDS.HANDLE_NIL;
    if (!impl.acquireQuiesce()) return DDS.HANDLE_NIL;
    defer impl.releaseQuiesce();
    return impl.registerInstance(key_hash.*);
}

fn writerImpl(writer: *anyopaque) ?*DataWriterImpl {
    if (isNullHandle(writer)) return null;
    const w = zidl_bindings.unboxAsView(DDS.DataWriter, writer);
    if (nil.isNil(w)) return null;
    return @ptrCast(@alignCast(w.ptr));
}

fn readerImpl(reader: *anyopaque) ?*DataReaderImpl {
    if (isNullHandle(reader)) return null;
    const r = zidl_bindings.unboxAsView(DDS.DataReader, reader);
    if (nil.isNil(r)) return null;
    return @ptrCast(@alignCast(r.ptr));
}

/// get_key_value's payload: zzdds keeps the whole first alive sample of an
/// instance, and a binding decodes the key fields from it. Copies it for the
/// instance `handle` names into `buf[0..buf_size]` and sets `*len_out` to
/// its size. Returns
/// - OK;
/// - BAD_PARAMETER for a NULL `writer` or `len_out`, a NULL `buf` with a
///   nonzero `buf_size`, or a handle that names no instance of `writer`
///   with an alive write (DDS 1.4 §2.2.2.4.2.9);
/// - ALREADY_DELETED for a deleted `writer`;
/// - NOT_ENABLED until `writer` is enabled (§2.2.2.1.1.7);
/// - PRECONDITION_NOT_MET when the payload does not fit in `buf_size`, as
///   `read` does for a sequence too short (§2.2.2.5.3.8). `*len_out` is
///   still set, so a caller can pass a NULL `buf` and 0 to learn the size
///   and call again.
pub export fn zzdds_get_key_value_writer(
    writer: *anyopaque,
    handle: DDS.InstanceHandle_t,
    buf: ?[*]u8,
    buf_size: usize,
    len_out: ?*usize,
) callconv(.c) DDS.ReturnCode_t {
    const impl = writerImpl(writer) orelse return DDS.RETCODE_BAD_PARAMETER;
    const out = keyValueOut(buf, buf_size, len_out) orelse return DDS.RETCODE_BAD_PARAMETER;
    if (!impl.acquireQuiesce()) return DDS.RETCODE_ALREADY_DELETED;
    defer impl.releaseQuiesce();
    return copyKeyValue(impl.keyValue(handle), out);
}

/// lookup_instance: the handle of the key hash's instance on `writer`, or 0
/// (HANDLE_NIL) if it was never registered or written.
pub export fn zzdds_lookup_instance_writer(
    writer: *anyopaque,
    key_hash: *const [16]u8,
) callconv(.c) DDS.InstanceHandle_t {
    const impl = writerImpl(writer) orelse return DDS.HANDLE_NIL;
    if (!impl.acquireQuiesce()) return DDS.HANDLE_NIL;
    defer impl.releaseQuiesce();
    return impl.lookupInstance(key_hash.*);
}

/// As `zzdds_get_key_value_writer`, for a reader: BAD_PARAMETER for a handle
/// that names no instance of `reader` with an alive sample (DDS 1.4
/// §2.2.2.5.3.29).
pub export fn zzdds_get_key_value_reader(
    reader: *anyopaque,
    handle: DDS.InstanceHandle_t,
    buf: ?[*]u8,
    buf_size: usize,
    len_out: ?*usize,
) callconv(.c) DDS.ReturnCode_t {
    const impl = readerImpl(reader) orelse return DDS.RETCODE_BAD_PARAMETER;
    const out = keyValueOut(buf, buf_size, len_out) orelse return DDS.RETCODE_BAD_PARAMETER;
    if (!impl.acquireQuiesce()) return DDS.RETCODE_ALREADY_DELETED;
    defer impl.releaseQuiesce();
    return copyKeyValue(impl.keyValue(handle), out);
}

const KeyValueOut = struct { buf: ?[*]u8, size: usize, len: *usize };

/// The caller's buffer and length out, or null if they are unusable. A NULL
/// buffer is only for asking the size, with `buf_size` 0.
fn keyValueOut(buf: ?[*]u8, buf_size: usize, len_out: ?*usize) ?KeyValueOut {
    const len = len_out orelse return null;
    if (buf == null and buf_size != 0) return null;
    return .{ .buf = buf, .size = buf_size, .len = len };
}

/// Copies the payload into the caller's buffer, which the caller's quiesce
/// reference keeps the payload alive for.
fn copyKeyValue(kv: error{ NotEnabled, BadParameter }![]u8, out: KeyValueOut) DDS.ReturnCode_t {
    const payload = kv catch |e| return switch (e) {
        error.NotEnabled => DDS.RETCODE_NOT_ENABLED,
        error.BadParameter => DDS.RETCODE_BAD_PARAMETER,
    };
    out.len.* = payload.len;
    if (payload.len > out.size) return DDS.RETCODE_PRECONDITION_NOT_MET;
    if (payload.len != 0) @memcpy(out.buf.?[0..payload.len], payload);
    return DDS.RETCODE_OK;
}

/// lookup_instance: the handle of the key hash's instance on `reader` if it
/// is ALIVE, or 0 (HANDLE_NIL).
pub export fn zzdds_lookup_instance_reader(
    reader: *anyopaque,
    key_hash: *const [16]u8,
) callconv(.c) DDS.InstanceHandle_t {
    const impl = readerImpl(reader) orelse return DDS.HANDLE_NIL;
    if (!impl.acquireQuiesce()) return DDS.HANDLE_NIL;
    defer impl.releaseQuiesce();
    return impl.lookupInstance(key_hash.*) orelse DDS.HANDLE_NIL;
}
