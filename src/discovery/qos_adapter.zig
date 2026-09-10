//! Adapter: typed DDS QoS (`DDS.DataWriterQos` / `DDS.DataReaderQos` +
//! `DDS.PresentationQosPolicy`) → the RTPS discovery wire structs generated
//! from `idl/rtps_discovery.idl`.
//!
//! This replaces `participant.zig`'s old `writerQosSnapshot` / `readerQosSnapshot`
//! (which produced the deleted `disc.QosSnapshot`). Every conditional-emission
//! decision the hand-rolled `sedp.zig` encoders made is reproduced here as an
//! `@optional` member set to `null` (skipped by `serializePlCdr`) vs. present.
//!
//! Duration conversion: DDS `Duration_t{sec,nanosec}` → RTPS `Duration_t
//! {seconds,fraction}` via `util/time.zig`'s `RtpsDuration.fromDuration`.
//!
//! What the adapter does NOT fill (the caller does, in `sedp.zig`):
//!   * `writerGuid` / `readerGuid`, `topicName`, `typeName`
//!   * `groupGuid` (GROUP-scope publisher only)
//!   * `partition` (from the Publisher/Subscriber PARTITION names)
//!   * `unknown_params` (PID_TYPE_INFORMATION blob, writer only)

const std = @import("std");
const build_opts = @import("build_options");
const time_mod = @import("../util/time.zig");
const wire = @import("zzdds_disc_generated");

const DDS = @import("zzdds_generated").DDS;

const Duration = time_mod.Duration;
const RtpsDuration = time_mod.RtpsDuration;

const DDS_INF_SEC: i32 = 0x7fff_ffff;
const DDS_INF_NS: u32 = 0xffff_ffff;

/// DDS `Duration_t` → RTPS wire `Duration_t`.
fn rtpsDur(sec: i32, nanosec: u32) wire.Duration_t {
    const rd = RtpsDuration.fromDuration(.{ .sec = sec, .nanosec = nanosec });
    return .{ .seconds = rd.seconds, .fraction = rd.fraction };
}

/// A DDS duration is "unset" when it is `{0,0}` (codegen default, meaning the
/// policy was never set) or the explicit INFINITE sentinel. The hand encoders
/// omitted DEADLINE / LATENCY_BUDGET / LIFESPAN / (default) LIVELINESS in that
/// case. Mirrors `writerQosSnapshot`'s `*_zero_*` normalisation.
fn durUnset(sec: i32, nanosec: u32) bool {
    if (sec == 0 and nanosec == 0) return true;
    if (sec == DDS_INF_SEC and nanosec == DDS_INF_NS) return true;
    return false;
}

/// Map an XTypes `DataRepresentationId_t` sequence to the single i16 the wire
/// carries: `2` (XCDR2) or `0` (XCDR1). Ported verbatim from
/// `participant.zig`'s `reprFromQos` + the hand encoder's `if (== 2) 2 else 0`.
///   - writer, empty list  → XCDR2 acceptance (2)
///   - reader, empty list  → XCDR2 acceptance (2)
///   - explicit list with a `2` entry → 2, else → 0 (XCDR1-only list)
fn reprI16(ids: []const i16) i16 {
    if (ids.len == 0) return 2;
    for (ids) |id| {
        if (id == 2) return 2;
    }
    return 0;
}

fn idsOf(policy: DDS.DataRepresentationQosPolicy) []const i16 {
    if (policy.value._buffer) |b| return b[0..policy.value._length];
    return &.{};
}

fn userDataOf(policy: DDS.UserDataQosPolicy) []const u8 {
    if (policy.value._buffer) |b| return b[0..policy.value._length];
    return &.{};
}

/// Static 1-element `sequence<short>` backings for `dataRepresentation` (the
/// member is always emitted; the adapter output borrows one of these).
var REPR_XCDR1 = [_]i16{0};
var REPR_XCDR2 = [_]i16{2};

/// The generated inline sequence structs for `dataRepresentation` / `userData`
/// are structurally identical on `DiscoveredWriterData` and
/// `DiscoveredReaderData` but nominally distinct, so pass the target type.
fn reprSeq(comptime FT: type, xcdr2: bool) FT {
    return .{
        ._maximum = 1,
        ._length = 1,
        ._buffer = if (xcdr2) &REPR_XCDR2 else &REPR_XCDR1,
        ._release = false,
    };
}

fn octetSeq(comptime FT: type, bytes: []const u8) FT {
    return .{
        ._maximum = @intCast(bytes.len),
        ._length = @intCast(bytes.len),
        ._buffer = @constCast(bytes.ptr),
        ._release = false,
    };
}

fn presentationWire(p: DDS.PresentationQosPolicy) ?wire.PresentationWire {
    const scope: u32 = @intCast(@intFromEnum(p.access_scope));
    if (scope == 0 and !p.coherent_access and !p.ordered_access) return null;
    return .{
        .access_scope = scope,
        .coherent_access = p.coherent_access,
        .ordered_access = p.ordered_access,
    };
}

fn livelinessWire(kind_ord: u32, lease_sec: i32, lease_ns: u32) ?wire.LivelinessWire {
    // {0,0} means "unset" → treat as INFINITE (matches writerQosSnapshot).
    const inf = lease_sec == 0 and lease_ns == 0;
    const s = if (inf) DDS_INF_SEC else lease_sec;
    const n = if (inf) DDS_INF_NS else lease_ns;
    // Hand encoder's `writeLivelinessPid`: omit only AUTOMATIC + INFINITE.
    if (kind_ord == 0 and s == DDS_INF_SEC and n == DDS_INF_NS) return null;
    return .{ .kind = kind_ord, .lease_duration = rtpsDur(s, n) };
}

/// `DDS.DataWriterQos` (+ its Publisher's PRESENTATION) → the QoS-derived
/// members of `DiscoveredWriterData`. Borrows `qos.user_data`'s buffer and a
/// static `dataRepresentation` backing; the returned struct is valid for as
/// long as `qos` is.
pub fn writerDiscoveredData(
    qos: DDS.DataWriterQos,
    presentation: DDS.PresentationQosPolicy,
) wire.DiscoveredWriterData {
    const reliable = qos.reliability.kind == .RELIABLE_RELIABILITY_QOS;
    const ud = userDataOf(qos.user_data);
    const keep_all = qos.history.kind == .KEEP_ALL_HISTORY_QOS;

    const repr_xcdr2 = if (comptime build_opts.xtypes)
        reprI16(idsOf(qos.data_representation)) == 2
    else
        false; // non-XTypes writer advertised XCDR1

    return .{
        .reliability = .{
            .kind = if (reliable) 2 else 1,
            .max_blocking_time = .{ .seconds = 0, .fraction = 0 },
        },
        .durabilityKind = @intFromEnum(qos.durability.kind),
        .userData = if (ud.len > 0) octetSeq(@FieldType(wire.DiscoveredWriterData, "userData"), ud) else .{},
        .presentation = presentationWire(presentation),
        .deadline = if (durUnset(qos.deadline.period.sec, qos.deadline.period.nanosec))
            null
        else
            rtpsDur(qos.deadline.period.sec, qos.deadline.period.nanosec),
        .liveliness = livelinessWire(
            @intFromEnum(qos.liveliness.kind),
            qos.liveliness.lease_duration.sec,
            qos.liveliness.lease_duration.nanosec,
        ),
        .ownershipKind = @intFromEnum(qos.ownership.kind),
        .ownershipStrength = if (qos.ownership.kind == .EXCLUSIVE_OWNERSHIP_QOS)
            qos.ownership_strength.value
        else
            null,
        .destinationOrder = @intFromEnum(qos.destination_order.kind),
        .history = .{
            .kind = if (keep_all) 1 else 0,
            // KEEP_LAST depth must be >= 1; codegen default 0 → clamp.
            .depth = if (!keep_all and qos.history.depth < 1) 1 else qos.history.depth,
        },
        .lifespan = if (durUnset(qos.lifespan.duration.sec, qos.lifespan.duration.nanosec))
            null
        else
            rtpsDur(qos.lifespan.duration.sec, qos.lifespan.duration.nanosec),
        .dataRepresentation = reprSeq(@FieldType(wire.DiscoveredWriterData, "dataRepresentation"), repr_xcdr2),
    };
}

/// `DDS.DataReaderQos` (+ its Subscriber's PRESENTATION) → the QoS-derived
/// members of `DiscoveredReaderData`.
pub fn readerDiscoveredData(
    qos: DDS.DataReaderQos,
    presentation: DDS.PresentationQosPolicy,
) wire.DiscoveredReaderData {
    const reliable = qos.reliability.kind == .RELIABLE_RELIABILITY_QOS;
    const ud = userDataOf(qos.user_data);

    // Reader default (empty list, XTypes on) advertises XCDR2 acceptance so
    // XCDR2-only writers (OpenDDS) match; non-XTypes also advertises 2.
    const repr_xcdr2 = if (comptime build_opts.xtypes)
        reprI16(idsOf(qos.data_representation)) == 2
    else
        true;

    return .{
        .reliability = .{
            .kind = if (reliable) 2 else 1,
            .max_blocking_time = .{ .seconds = 0, .fraction = 0 },
        },
        .durabilityKind = @intFromEnum(qos.durability.kind),
        .ownershipKind = @intFromEnum(qos.ownership.kind),
        // MATCH ONLY: `encodeReaderData` nulls this before serialize so the
        // reader wire is unchanged (readers historically never emit it).
        .destinationOrder = @intFromEnum(qos.destination_order.kind),
        .userData = if (ud.len > 0) octetSeq(@FieldType(wire.DiscoveredReaderData, "userData"), ud) else .{},
        .presentation = presentationWire(presentation),
        .deadline = if (durUnset(qos.deadline.period.sec, qos.deadline.period.nanosec))
            null
        else
            rtpsDur(qos.deadline.period.sec, qos.deadline.period.nanosec),
        .liveliness = livelinessWire(
            @intFromEnum(qos.liveliness.kind),
            qos.liveliness.lease_duration.sec,
            qos.liveliness.lease_duration.nanosec,
        ),
        .dataRepresentation = reprSeq(@FieldType(wire.DiscoveredReaderData, "dataRepresentation"), repr_xcdr2),
    };
}
