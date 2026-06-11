//! Hand-written C ABI bootstrap for zzdds.
//!
//! Provides three groups of C-callable exports:
//!
//!   1. Participant lifecycle (UDP transport + SPDP/SEDP discovery):
//!        zzdds_create_participant_udp  — create factory + participant in one call
//!        zzdds_destroy_participant     — tear down participant + factory + transport
//!
//!   2. Generic raw write/take:
//!        zzdds_write_raw               — CDR bytes → RTPS wire
//!        zzdds_take_one_raw            — RTPS wire → CDR bytes (any sample)
//!        zzdds_take_one_raw_instance   — RTPS wire → CDR bytes (take_next_instance)
//!
//! These exports are intentionally type-agnostic.  The caller is responsible for
//! CDR serialization/deserialization (use the zidl-generated shape.h helpers).
//!
//! Usage from C (shape_configurator_zzdds.h wires these up):
//!
//!   DDS_DomainParticipant dp = zzdds_create_participant_udp(0, &listener);
//!   zzdds_write_raw(writer, key_hash, cdr_buf, cdr_len);
//!   int n = zzdds_take_one_raw_instance(reader, prev_ih, buf, sizeof(buf), &len, &info);
//!   zzdds_destroy_participant(dp);

const std = @import("std");

const DDS = @import("zzdds_generated").DDS;

const UdpTransport = @import("../transport/udp.zig").UdpTransport;
const SpdpSedpDiscovery = @import("../discovery/combined.zig").SpdpSedpDiscovery;
const DomainParticipantFactoryImpl = @import("../dcps/factory.zig").DomainParticipantFactoryImpl;
const DataWriterImpl = @import("../dcps/writer.zig").DataWriterImpl;
const DataReaderImpl = @import("../dcps/reader.zig").DataReaderImpl;
const TopicImpl = @import("../dcps/topic.zig").TopicImpl;
const noop_security = @import("../security/noop.zig").noop_security_plugins;
const time_mod = @import("../util/time.zig");
const history_mod = @import("../rtps/history.zig");
const nil = @import("../dcps/nil.zig");
const Mutex = @import("../util/mutex.zig").Mutex;

// `DDS.DomainParticipantListener` IS the C callback struct (generated from dcps.idl).
// The C header `DDS_DomainParticipantListener` must match its layout exactly.

// ── Dead code removed: CDPListener, CDPAdapter ───────────────────────────────
// Previously, a CDPAdapter translated a C callback struct into a fat-pointer
// DomainParticipantListener.  With C-ABI primary, DDS.DomainParticipantListener
// IS the C callback struct — no adapter needed.

// ── Participant registry ─────────────────────────────────────────────────────
// Maps DomainParticipantImpl* → the factory/transport/discovery that owns it.

const Entry = struct {
    dp_ptr: *anyopaque,
    factory: *DomainParticipantFactoryImpl,
    disc: *SpdpSedpDiscovery,
    udp: *UdpTransport,
    alloc: std.mem.Allocator,
};

const MAX_ENTRIES = 16;
var g_entries: [MAX_ENTRIES]?Entry = [_]?Entry{null} ** MAX_ENTRIES;
var g_mu: Mutex = .{};

fn register(e: Entry) bool {
    g_mu.lock();
    defer g_mu.unlock();
    for (&g_entries) |*slot| {
        if (slot.* == null) {
            slot.* = e;
            return true;
        }
    }
    return false;
}

fn unregister(dp_ptr: *anyopaque) ?Entry {
    g_mu.lock();
    defer g_mu.unlock();
    for (&g_entries) |*slot| {
        if (slot.*) |e| {
            if (e.dp_ptr == dp_ptr) {
                slot.* = null;
                return e;
            }
        }
    }
    return null;
}

// ── SampleInfo for C ─────────────────────────────────────────────────────────
// Minimal extern struct matching SH_SampleInfo in shape_configurator_zzdds.h.

pub const CSampleInfo = extern struct {
    valid_data: bool,
    instance_state: u32,
    instance_handle: i32,
};

// ── Participant lifecycle ─────────────────────────────────────────────────────

/// Create a DomainParticipant backed by UDP transport + SPDP/SEDP discovery.
/// `c_listener` may be null (noop listener is used).
/// Returns a null fat-pointer participant on failure.
pub export fn zzdds_create_participant_udp(
    domain_id: u32,
    c_listener: ?*const DDS.DomainParticipantListener,
) callconv(.c) DDS.DomainParticipant {
    return zzdds_create_participant_udp_impl(domain_id, c_listener) catch |err| {
        std.log.err("zzdds_create_participant_udp: {}", .{err});
        return std.mem.zeroes(DDS.DomainParticipant);
    };
}

fn zzdds_create_participant_udp_impl(
    domain_id: u32,
    c_listener: ?*const DDS.DomainParticipantListener,
) !DDS.DomainParticipant {
    const alloc = std.heap.c_allocator;

    const udp = try UdpTransport.init(alloc, .{}, domain_id, null);
    errdefer udp.deinit();

    const disc = try SpdpSedpDiscovery.init(alloc, udp.transport(), domain_id, 3_000);
    errdefer disc.deinit();

    const factory = try DomainParticipantFactoryImpl.init(
        alloc,
        udp.transport(),
        disc.toDiscovery(),
        noop_security,
        .spec_random,
        .{},
    );
    errdefer factory.deinit();

    const dpf = factory.toDDSFactory();
    // Call vtable slot directly: bootstrap deals with C-ABI types (?*const T).
    const default_qos = DDS.DomainParticipantQos{};
    const dp = dpf.vtable.create_participant(dpf.ptr, domain_id, &default_qos, c_listener, 0);
    if (nil.isNil(dp)) return error.ParticipantFailed;

    if (!register(.{
        .dp_ptr = @ptrCast(dp.ptr),
        .factory = factory,
        .disc = disc,
        .udp = udp,
        .alloc = alloc,
    })) return error.RegistryFull;

    return dp;
}

/// Tear down a participant created by zzdds_create_participant_udp.
pub export fn zzdds_destroy_participant(dp: DDS.DomainParticipant) callconv(.c) void {
    if (nil.isNil(dp)) return;
    const e = unregister(@ptrCast(dp.ptr)) orelse return;
    const dpf = e.factory.toDDSFactory();
    _ = dpf.delete_participant(dp);
    e.factory.deinit();
    e.disc.deinit();
    e.udp.deinit();
}

// ── Topic → TopicDescription conversion ──────────────────────────────────────

/// Convert a DDS_Topic to a DDS_TopicDescription with the correct vtable.
/// A direct memcpy of the {ptr, vtable} fields is WRONG because Topic and
/// TopicDescription have different vtable layouts.  This function casts the
/// Topic's impl pointer to the TopicDescription interface using the dedicated
/// TopicImpl.toTopicDescription() method.
pub export fn zzdds_topic_as_description(topic: DDS.Topic) callconv(.c) DDS.TopicDescription {
    const impl: *TopicImpl = @ptrCast(@alignCast(topic.ptr));
    return impl.toTopicDescription();
}

// ── Raw write ────────────────────────────────────────────────────────────────

/// Write a pre-serialized CDR payload (including 4-byte encap header).
/// `key_hash` is the 16-byte MD5 key hash computed by `ShapeType_compute_key_hash`.
pub export fn zzdds_write_raw(
    writer: DDS.DataWriter,
    key_hash: *const [16]u8,
    data: [*]const u8,
    data_len: usize,
) callconv(.c) DDS.ReturnCode_t {
    const impl: *DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    _ = impl.writeRaw(
        .alive,
        time_mod.RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        key_hash.*,
        data[0..data_len],
    ) catch return 1;
    return 0;
}

// ── Raw take ─────────────────────────────────────────────────────────────────

/// Take the next available sample regardless of instance.
/// Copies the CDR payload into `cdr_buf[0..buf_size]`; sets `*cdr_len_out` to actual length.
/// Returns 1 on success, 0 if queue empty, -1 on buffer-too-small error.
pub export fn zzdds_take_one_raw(
    reader: DDS.DataReader,
    cdr_buf: [*]u8,
    buf_size: usize,
    cdr_len_out: *usize,
    info_out: *CSampleInfo,
) callconv(.c) c_int {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    const s = impl.takeRaw() orelse return 0;
    defer impl.alloc.free(s.data);
    if (s.data.len > buf_size) return -1;
    cdr_len_out.* = s.data.len;
    @memcpy(cdr_buf[0..s.data.len], s.data);
    info_out.* = .{
        .valid_data = s.info.valid_data,
        .instance_state = s.info.instance_state,
        .instance_handle = s.info.instance_handle,
    };
    return 1;
}

/// take_next_instance semantics: take one sample from the "next" instance after
/// `prev_instance_handle` (0 means any instance).
/// Returns 1 on success, 0 if no qualifying sample, -1 on error.
pub export fn zzdds_take_one_raw_instance(
    reader: DDS.DataReader,
    prev_instance_handle: DDS.InstanceHandle_t,
    cdr_buf: [*]u8,
    buf_size: usize,
    cdr_len_out: *usize,
    info_out: *CSampleInfo,
) callconv(.c) c_int {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    const s = impl.takeNextInstanceRaw(prev_instance_handle) orelse return 0;
    defer impl.alloc.free(s.data);
    if (s.data.len > buf_size) return -1;
    cdr_len_out.* = s.data.len;
    @memcpy(cdr_buf[0..s.data.len], s.data);
    info_out.* = .{
        .valid_data = s.info.valid_data,
        .instance_state = s.info.instance_state,
        .instance_handle = s.info.instance_handle,
    };
    return 1;
}
