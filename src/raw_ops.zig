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
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const dcps_writer = @import("dcps/writer.zig");
const dcps_reader = @import("dcps/reader.zig");
const dcps_participant = @import("dcps/participant.zig");
const dcps_topic = @import("dcps/topic.zig");
const dcps_waitset = @import("dcps/waitset.zig");
const filter_mod = @import("dcps/filter.zig");
const zzdds_ext = @import("c_abi/extensions.zig");
const history_mod = @import("rtps/history.zig");
const time_mod = @import("util/time.zig");

const DataWriterImpl = dcps_writer.DataWriterImpl;
const DataReaderImpl = dcps_reader.DataReaderImpl;
const DomainParticipantImpl = dcps_participant.DomainParticipantImpl;
const TopicImpl = dcps_topic.TopicImpl;
const WaitSetImpl = dcps_waitset.WaitSetImpl;
const GuardConditionImpl = dcps_waitset.GuardConditionImpl;

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

// ── Participant operations ────────────────────────────────────────────────────

/// Register a TypeSupport with a DomainParticipant under `type_name`, replacing
/// any existing registration under the same name.  The pure-Zig equivalent of
/// the C ABI's `zzdds_register_type_support` (src/c_abi/typesupport.zig) --
/// that shim does this same handle-to-impl unboxing internally for C/C++/Java
/// callers; this gives Zig callers the same one-call surface instead of
/// requiring them to downcast `participant.ptr` to `*DomainParticipantImpl`
/// themselves.  Returns false if the participant is being torn down.
pub fn registerTypeSupport(
    participant: DDS.DomainParticipant,
    type_name: []const u8,
    ts: dcps_participant.TypeSupport,
) bool {
    const impl: *DomainParticipantImpl = @ptrCast(@alignCast(participant.ptr));
    return impl.registerTypeSupport(type_name, ts);
}

/// Upcast a base DDS entity handle to its zzdds-extended interface view --
/// e.g. so a writer created via the plain `DDS.Publisher.create_datawriter`
/// can reach `set_listener_ex` (`DataWriterListenerEx::on_reliable_reader_ready`,
/// the vendor extension this hello_world/shape/listener-pubsub family of
/// examples exists partly to demonstrate). A real vtable-identity check, the
/// pure-Zig equivalent of the C ABI's `DDS_DataWriter_as_zzdds_DataWriter`
/// (`src/c_abi/extensions.zig`) -- that shim does this same check internally
/// for C/C++/Java callers (Java's own `ZzddsRuntime.asZzddsDataWriter` is the
/// same idea again, one layer further out); this gives Zig callers the same
/// safe upcast instead of requiring them to blindly downcast `writer.ptr` to
/// `*DataWriterImpl` themselves. Returns `null` for a handle not issued by
/// this implementation (today, in a single-vendor-per-process reality, that
/// should never actually happen for a handle that came from this same
/// zzdds -- but the check is what makes this a real upcast rather than the
/// blind cast it replaces).
pub fn asZzddsDataWriter(writer: DDS.DataWriter) ?ZZDDS.DataWriter {
    if (writer.vtable != &DataWriterImpl.vtable) return null;
    return .{ .ptr = writer.ptr, .vtable = &zzdds_ext.writer_vtable };
}

/// See `asZzddsDataWriter` -- same shape, for `DataReader`.
pub fn asZzddsDataReader(reader: DDS.DataReader) ?ZZDDS.DataReader {
    if (reader.vtable != &DataReaderImpl.vtable) return null;
    return .{ .ptr = reader.ptr, .vtable = &zzdds_ext.reader_vtable };
}

/// See `asZzddsDataWriter` -- same shape, for `Topic` (reaches
/// `as_topic_description` and friends).
pub fn asZzddsTopic(topic: DDS.Topic) ?ZZDDS.Topic {
    if (topic.vtable != &TopicImpl.topic_vtable) return null;
    return .{ .ptr = topic.ptr, .vtable = &zzdds_ext.topic_vtable };
}

/// See `asZzddsDataWriter` -- same shape, for `DomainParticipant`.
pub fn asZzddsDomainParticipant(participant: DDS.DomainParticipant) ?ZZDDS.DomainParticipant {
    if (participant.vtable != &DomainParticipantImpl.vtable) return null;
    return .{ .ptr = participant.ptr, .vtable = &zzdds_ext.participant_vtable };
}

// ── WaitSet / GuardCondition construction ───────────────────────────────────

/// WaitSet and GuardCondition are the only two condition-family types with no
/// factory operation in dcps.idl (per OMG spec, both are app-instantiated
/// directly -- unlike StatusCondition/ReadCondition/QueryCondition, which are
/// obtained from an existing entity/reader and already have a pure-Zig path
/// via `entity.get_statuscondition()`/`reader.create_readcondition()`
/// directly on their generated interface types). This mirrors the C ABI's
/// `zzdds_create_waitset` (src/c_abi/extensions.zig) -- that shim does this
/// same construction internally for C/C++/Java callers; this gives Zig
/// callers the same one-call surface instead of requiring them to reach
/// `WaitSetImpl.init` themselves.
pub fn createWaitSet(alloc: std.mem.Allocator) !DDS.WaitSet {
    const ws = try WaitSetImpl.init(alloc);
    return ws.toDDSWaitSet();
}

/// See `createWaitSet` -- same shape, for `GuardCondition`.
pub fn createGuardCondition(alloc: std.mem.Allocator) !DDS.GuardCondition {
    const gc = try GuardConditionImpl.init(alloc);
    return gc.toDDSGuardCondition();
}

// ── QoS helpers ──────────────────────────────────────────────────────────────

/// Return true if the writer's data-representation QoS specifies XCDRv2.
/// Reads the QoS directly from DataWriterImpl without allocating.
pub fn writerUsesXcdr2(writer: DDS.DataWriter) bool {
    const impl: *DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    if (!impl.acquireQuiesce()) return false;
    defer impl.releaseQuiesce();
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
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
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
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
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
    if (!impl.acquireQuiesce()) return null;
    defer impl.releaseQuiesce();
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
    if (!impl.acquireQuiesce()) return null;
    defer impl.releaseQuiesce();
    const taken = impl.takeRaw() orelse return null;
    return .{ .data = taken.data, .info = taken.info, ._alloc = impl.alloc };
}

/// Non-destructively return the next pending sample, or null if empty.
/// The sample's sample_state is updated to READ.
/// Caller owns the returned OwnedRawSample and must call deinit().
pub fn readNextSampleRaw(reader: DDS.DataReader) ?OwnedRawSample {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    if (!impl.acquireQuiesce()) return null;
    defer impl.releaseQuiesce();
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
    if (!impl.acquireQuiesce()) return null;
    defer impl.releaseQuiesce();
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
    if (!impl.acquireQuiesce()) return null;
    defer impl.releaseQuiesce();
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
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
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

/// Batch take restricted to a QueryCondition: state masks come from the
/// condition itself, and only samples whose fields pass its query expression
/// are returned. The Zig-native raw path to what the OMG spec calls
/// `take_w_condition` (`dcps.idl` notes this operation as not yet
/// implemented at the `DDS.DataReader` interface level — `DataReaderImpl`
/// already supports it internally via `takeFiltered`'s `maybe_qc` parameter;
/// this is simply the first public entry point to it). Requires the reader's
/// TypeSupport to have a `get_field_from_cdr` callback registered — see
/// `create_querycondition`'s own precondition (a non-empty query expression
/// with no `get_field_fn` returns NIL, never gets this far).
pub fn takeWithQueryConditionRaw(
    reader: DDS.DataReader,
    qc: DDS.QueryCondition,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    caller_alloc: std.mem.Allocator,
) !void {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
    const qc_impl: *const dcps_waitset.QueryConditionImpl = @ptrCast(@alignCast(qc.ptr));
    var tmp: std.ArrayListUnmanaged(dcps_reader.TakenSample) = .empty;
    defer {
        for (tmp.items) |s| impl.alloc.free(s.data);
        tmp.deinit(impl.alloc);
    }
    try impl.takeFiltered(
        &tmp,
        qc_impl.rc.sample_state_mask,
        qc_impl.rc.view_state_mask,
        qc_impl.rc.instance_state_mask,
        max,
        null,
        qc_impl,
    );
    try out.ensureUnusedCapacity(caller_alloc, tmp.items.len);
    for (tmp.items) |s| {
        out.appendAssumeCapacity(.{ .data = s.data, .info = s.info, ._alloc = impl.alloc });
    }
    tmp.items.len = 0;
}

/// Batch take restricted to an arbitrary ReadCondition -- which may itself be
/// a QueryCondition upcast via `as_ReadCondition()` (see
/// `ReadConditionImpl.owner_qc`, which tells us so and carries the query
/// filter to apply if it is). State masks come from the condition itself.
/// The Zig-native raw path to what the OMG spec calls `take_w_condition`
/// (`dcps.idl`'s `DataReader` interface comment names the full generated-
/// operation set this belongs to). More general than `takeWithQueryConditionRaw`
/// above (which requires a `DDS.QueryCondition`-typed parameter specifically);
/// kept alongside it rather than replacing it, since that one still has a
/// caller.
pub fn takeWithReadConditionRaw(
    reader: DDS.DataReader,
    cond: DDS.ReadCondition,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    caller_alloc: std.mem.Allocator,
) !void {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
    const rc_impl: *const dcps_waitset.ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
    var tmp: std.ArrayListUnmanaged(dcps_reader.TakenSample) = .empty;
    defer {
        for (tmp.items) |s| impl.alloc.free(s.data);
        tmp.deinit(impl.alloc);
    }
    try impl.takeFiltered(
        &tmp,
        rc_impl.sample_state_mask,
        rc_impl.view_state_mask,
        rc_impl.instance_state_mask,
        max,
        null,
        rc_impl.owner_qc,
    );
    try out.ensureUnusedCapacity(caller_alloc, tmp.items.len);
    for (tmp.items) |s| {
        out.appendAssumeCapacity(.{ .data = s.data, .info = s.info, ._alloc = impl.alloc });
    }
    tmp.items.len = 0;
}

/// Non-destructive analog of `takeWithReadConditionRaw` -- the raw path to
/// what the OMG spec calls `read_w_condition`.
pub fn readWithReadConditionRaw(
    reader: DDS.DataReader,
    cond: DDS.ReadCondition,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    caller_alloc: std.mem.Allocator,
) !void {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
    const rc_impl: *const dcps_waitset.ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
    var tmp: std.ArrayListUnmanaged(dcps_reader.TakenSample) = .empty;
    defer {
        for (tmp.items) |s| impl.alloc.free(s.data);
        tmp.deinit(impl.alloc);
    }
    try impl.readRaw(
        &tmp,
        rc_impl.sample_state_mask,
        rc_impl.view_state_mask,
        rc_impl.instance_state_mask,
        max,
        null,
        rc_impl.owner_qc,
    );
    try out.ensureUnusedCapacity(caller_alloc, tmp.items.len);
    for (tmp.items) |s| {
        out.appendAssumeCapacity(.{ .data = s.data, .info = s.info, ._alloc = impl.alloc });
    }
    tmp.items.len = 0;
}

/// Batch take restricted to an arbitrary ReadCondition AND scoped to the
/// "next instance" after `prev` -- the raw path to what the OMG spec calls
/// `take_next_instance_w_condition`. See
/// `DataReaderImpl.takeNextInstanceFiltered`'s doc comment for the
/// instance-selection semantics (the target instance must itself have a
/// matching sample, not just any sample).
pub fn takeNextInstanceWithReadConditionRaw(
    reader: DDS.DataReader,
    cond: DDS.ReadCondition,
    prev: DDS.InstanceHandle_t,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    caller_alloc: std.mem.Allocator,
) !void {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
    const rc_impl: *const dcps_waitset.ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
    var tmp: std.ArrayListUnmanaged(dcps_reader.TakenSample) = .empty;
    defer {
        for (tmp.items) |s| impl.alloc.free(s.data);
        tmp.deinit(impl.alloc);
    }
    try impl.takeNextInstanceFiltered(
        &tmp,
        prev,
        rc_impl.sample_state_mask,
        rc_impl.view_state_mask,
        rc_impl.instance_state_mask,
        max,
        rc_impl.owner_qc,
    );
    try out.ensureUnusedCapacity(caller_alloc, tmp.items.len);
    for (tmp.items) |s| {
        out.appendAssumeCapacity(.{ .data = s.data, .info = s.info, ._alloc = impl.alloc });
    }
    tmp.items.len = 0;
}

/// Non-destructive analog of `takeNextInstanceWithReadConditionRaw` -- the raw
/// path to what the OMG spec calls `read_next_instance_w_condition`.
pub fn readNextInstanceWithReadConditionRaw(
    reader: DDS.DataReader,
    cond: DDS.ReadCondition,
    prev: DDS.InstanceHandle_t,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    caller_alloc: std.mem.Allocator,
) !void {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
    const rc_impl: *const dcps_waitset.ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
    var tmp: std.ArrayListUnmanaged(dcps_reader.TakenSample) = .empty;
    defer {
        for (tmp.items) |s| impl.alloc.free(s.data);
        tmp.deinit(impl.alloc);
    }
    try impl.readNextInstanceFiltered(
        &tmp,
        prev,
        rc_impl.sample_state_mask,
        rc_impl.view_state_mask,
        rc_impl.instance_state_mask,
        max,
        rc_impl.owner_qc,
    );
    try out.ensureUnusedCapacity(caller_alloc, tmp.items.len);
    for (tmp.items) |s| {
        out.appendAssumeCapacity(.{ .data = s.data, .info = s.info, ._alloc = impl.alloc });
    }
    tmp.items.len = 0;
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
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
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
    if (!impl.acquireQuiesce()) return null;
    defer impl.releaseQuiesce();
    return impl.getKeyValueRaw(handle);
}

/// Return the instance handle for `handle` if it is a known ALIVE instance,
/// or HANDLE_NIL (0) otherwise.
pub fn lookupInstanceReader(
    reader: DDS.DataReader,
    handle: DDS.InstanceHandle_t,
) ?DDS.InstanceHandle_t {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    if (!impl.acquireQuiesce()) return null;
    defer impl.releaseQuiesce();
    return if (impl.lookupInstance(handle)) handle else null;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const intraprocess = @import("delivery/intraprocess.zig");
const noop_security = @import("security/noop.zig").noop_security_plugins;
const DomainParticipantFactoryImpl = @import("dcps/factory.zig").DomainParticipantFactoryImpl;

const TestFixture = struct {
    delivery: intraprocess.IntraProcessDelivery,
    t: *intraprocess.MemoryTransport,
    d: *intraprocess.DirectDiscovery,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,

    fn init(alloc: std.mem.Allocator) !TestFixture {
        var delivery = try intraprocess.IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        const factory = try DomainParticipantFactoryImpl.init(
            alloc,
            t.transport(),
            d.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory.deinit();
        const dp = factory.toDDSFactory().create_participant(0, .{}, null, 0);
        return .{ .delivery = delivery, .t = t, .d = d, .factory = factory, .dp = dp };
    }

    fn deinit(self: *TestFixture) void {
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        self.factory.deinit();
        self.d.deinit();
        self.t.deinit();
        self.delivery.deinit();
    }
};

test "asZzddsDomainParticipant/Topic/DataWriter/DataReader: real vtable-checked upcast" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    const zdp = asZzddsDomainParticipant(fx.dp) orelse return error.TestUnexpectedResult;
    try testing.expect(zdp.ptr == fx.dp.ptr);

    const topic = fx.dp.create_topic("T", "T", .{}, null, 0);
    const ztopic = asZzddsTopic(topic) orelse return error.TestUnexpectedResult;
    try testing.expect(ztopic.ptr == topic.ptr);

    const pub_ = fx.dp.create_publisher(.{}, null, 0);
    const dw = pub_.create_datawriter(topic, .{}, null, 0);
    const zdw = asZzddsDataWriter(dw) orelse return error.TestUnexpectedResult;
    try testing.expect(zdw.ptr == dw.ptr);
    // set_listener_ex is the whole point of this upcast -- confirm it's
    // actually callable on the returned interface value, not just that the
    // upcast itself succeeded.
    try testing.expectEqual(DDS.RETCODE_OK, zdw.set_listener_ex(null, 0));

    const sub_ = fx.dp.create_subscriber(.{}, null, 0);
    const topic_desc = fx.dp.lookup_topicdescription("T");
    const dr = sub_.create_datareader(topic_desc, .{}, null, 0);
    const zdr = asZzddsDataReader(dr) orelse return error.TestUnexpectedResult;
    try testing.expect(zdr.ptr == dr.ptr);
}

test "asZzddsDataWriter: null for a handle not issued by this implementation" {
    // The nil sentinel's vtable doesn't match DataWriterImpl.vtable -- the
    // simplest available handle whose vtable is known *not* to match,
    // without a second DDS implementation in-repo to construct a genuinely
    // foreign one.
    const nil = @import("dcps/nil.zig");
    try testing.expect(asZzddsDataWriter(nil.nil_datawriter) == null);
}

// Phase 0 of "make CFT filtering spec-compliant across all bindings": proves
// that wiring a real TypeSupport.get_field (no codegen involved -- this is a
// hand-written closure over an intentionally trivial one-byte "payload") is
// enough, on its own, for subscriber.zig/reader.zig's EXISTING cft_filter
// machinery to activate and actually filter -- before any backend generates
// a real get_field_from_cdr. If this test passes, the remaining phases are
// purely "teach each backend to generate the callback", not "fix the runtime".
//
// Writer and reader deliberately live on SEPARATE participants (own
// transport/discovery each, sharing one IntraProcessDelivery to route
// between them) -- a single participant's own reader does not receive its
// own writer's data in this harness (confirmed: an earlier same-participant
// version of this test never delivered anything at all). Mirrors
// test/dcps/qos_runtime_test.zig's `Fixture`.
test "TypeSupport.get_field wires cft_filter automatically: reader delivers only matching samples" {
    const nil = @import("dcps/nil.zig");
    const alloc = testing.allocator;

    var delivery = try intraprocess.IntraProcessDelivery.init(alloc);
    defer delivery.deinit();

    const t_w = try delivery.newTransport();
    defer t_w.deinit();
    const d_w = try delivery.newDiscovery();
    defer d_w.deinit();
    const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
    defer factory_w.deinit();
    const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = factory_w.toDDSFactory().delete_participant(dp_w);

    const t_r = try delivery.newTransport();
    defer t_r.deinit();
    const d_r = try delivery.newDiscovery();
    defer d_r.deinit();
    const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
    defer factory_r.deinit();
    const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = factory_r.toDDSFactory().delete_participant(dp_r);

    const GetField = struct {
        // Trivial fake wire format for this test only: byte 0 = "x" (int),
        // byte 1 = "color"'s length, bytes 2.. = "color"'s bytes. Real
        // backends generate a real CDR parse; get_field's contract doesn't
        // care how payload is structured -- deliberately exercises the
        // string/scratch path too (not just an int field), since that's the
        // actual shape zzdds-examples' `--cft "color = 'RED'"` needs and the
        // dangling-pointer hazard `scratch` exists to avoid only applies to
        // strings.
        fn get(_: *anyopaque, payload: []const u8, field: []const u8, scratch: []u8) ?filter_mod.FilterValue {
            if (std.mem.eql(u8, field, "x")) {
                if (payload.len > 0) return .{ .int = payload[0] };
                return null;
            }
            if (std.mem.eql(u8, field, "color")) {
                if (payload.len < 2) return null;
                const len = payload[1];
                if (payload.len < 2 + @as(usize, len) or len > scratch.len) return null;
                @memcpy(scratch[0..len], payload[2 .. 2 + len]);
                return .{ .string = scratch[0..len] };
            }
            return null;
        }
        fn keyHash(_: *anyopaque, _: []const u8) [16]u8 {
            return std.mem.zeroes([16]u8);
        }
    };

    // Only the READER's participant needs a get_field registration --
    // subGetFieldFn looks it up per-participant, and CFT filtering happens
    // on the receiving side.
    const dp_r_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp_r.ptr));
    try testing.expect(dp_r_impl.registerTypeSupport("CftAutoT", .{
        .ctx = undefined,
        .compute_key_hash = GetField.keyHash,
        .get_field = GetField.get,
    }));

    const topic_w = dp_w.create_topic("CftAutoT", "CftAutoT", .{}, null, 0);
    const topic_r = dp_r.create_topic("CftAutoT", "CftAutoT", .{}, null, 0);
    const cft = dp_r.create_contentfilteredtopic("CftAutoT_cft", topic_r, "x = 5 AND color = 'RED'", null);
    try testing.expect(!nil.isNil(cft));
    defer _ = dp_r.delete_contentfilteredtopic(cft);

    const pub_ = dp_w.create_publisher(.{}, null, 0);
    const dw = pub_.create_datawriter(topic_w, .{}, null, 0);
    const sub_ = dp_r.create_subscriber(.{}, null, 0);
    const dr = sub_.create_datareader(cft.vtable.as_TopicDescription(cft.ptr), .{}, null, 0);

    const zero_key = std.mem.zeroes([16]u8);
    const matching = [_]u8{ 5, 3, 'R', 'E', 'D' }; // x=5, color="RED" -- matches
    const wrong_x = [_]u8{ 6, 3, 'R', 'E', 'D' }; // x=6 -- fails the int comparison
    const wrong_color = [_]u8{ 5, 3, 'B', 'L', 'U' }; // color="BLU" -- fails the string comparison
    try writeRaw(dw, .alive, zero_key, &matching);
    try writeRaw(dw, .alive, zero_key, &wrong_x);
    try writeRaw(dw, .alive, zero_key, &wrong_color);

    // The app never re-checks the filter itself here -- if cft_filter wasn't
    // wired up, all three samples would come through.
    const first = takeRaw(dr) orelse return error.TestUnexpectedResult;
    defer first.deinit();
    try testing.expectEqualSlices(u8, &matching, first.data);

    try testing.expect(takeRaw(dr) == null);
}

// Same GetField-registration shape as the CFT test above, but exercising
// takeWithQueryConditionRaw on a plain (non-filtered) topic's QueryCondition
// instead of a ContentFilteredTopic -- proves the reader-side
// take_w_condition path applies the query independently of CFT.
test "takeWithQueryConditionRaw: only samples matching the QueryCondition's expression are returned" {
    const alloc = testing.allocator;

    var delivery = try intraprocess.IntraProcessDelivery.init(alloc);
    defer delivery.deinit();

    const t_w = try delivery.newTransport();
    defer t_w.deinit();
    const d_w = try delivery.newDiscovery();
    defer d_w.deinit();
    const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
    defer factory_w.deinit();
    const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = factory_w.toDDSFactory().delete_participant(dp_w);

    const t_r = try delivery.newTransport();
    defer t_r.deinit();
    const d_r = try delivery.newDiscovery();
    defer d_r.deinit();
    const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
    defer factory_r.deinit();
    const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = factory_r.toDDSFactory().delete_participant(dp_r);

    const GetField = struct {
        // payload byte 0 = "x" (int); get_field's contract doesn't care
        // about a real CDR parse, matching the CFT test's own convention.
        fn get(_: *anyopaque, payload: []const u8, field: []const u8, _: []u8) ?filter_mod.FilterValue {
            if (std.mem.eql(u8, field, "x")) {
                if (payload.len > 0) return .{ .int = payload[0] };
                return null;
            }
            return null;
        }
        fn keyHash(_: *anyopaque, _: []const u8) [16]u8 {
            return std.mem.zeroes([16]u8);
        }
    };

    const dp_r_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp_r.ptr));
    try testing.expect(dp_r_impl.registerTypeSupport("QueryCondT", .{
        .ctx = undefined,
        .compute_key_hash = GetField.keyHash,
        .get_field = GetField.get,
    }));

    const topic_w = dp_w.create_topic("QueryCondT", "QueryCondT", .{}, null, 0);
    const topic_r = dp_r.create_topic("QueryCondT", "QueryCondT", .{}, null, 0);

    // KEEP_ALL on both sides -- every write below shares the same zero key
    // (single instance), and the default KEEP_LAST depth=1 would otherwise
    // evict an unread sample the moment the next one for the same instance
    // arrives, before this test ever gets to take_w_condition.
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const pub_ = dp_w.create_publisher(.{}, null, 0);
    const dw = pub_.create_datawriter(topic_w, dw_qos, null, 0);
    const sub_ = dp_r.create_subscriber(.{}, null, 0);
    const topic_desc_r = topic_r.vtable.as_TopicDescription(topic_r.ptr);
    const dr = sub_.create_datareader(topic_desc_r, dr_qos, null, 0);

    const qc = dr.create_querycondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, "x = 5", null);
    try testing.expect(qc.ptr != @import("dcps/nil.zig").NIL_PTR);
    defer _ = dr.delete_readcondition(qc.vtable.as_ReadCondition(qc.ptr));

    const zero_key = std.mem.zeroes([16]u8);
    try writeRaw(dw, .alive, zero_key, &[_]u8{5}); // x=5 -- matches
    try writeRaw(dw, .alive, zero_key, &[_]u8{6}); // x=6 -- doesn't match

    // Plain takeRaw sees both -- the query only applies through the
    // condition-restricted path, not automatically at delivery time (that's
    // ContentFilteredTopic's job, a separate mechanism covered above).
    var all = std.ArrayListUnmanaged(OwnedRawSample).empty;
    defer {
        for (all.items) |s| s.deinit();
        all.deinit(alloc);
    }
    try takeFilteredRaw(dr, &all, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, null, alloc);
    try testing.expectEqual(@as(usize, 2), all.items.len);

    try writeRaw(dw, .alive, zero_key, &[_]u8{5});
    try writeRaw(dw, .alive, zero_key, &[_]u8{6});

    var filtered = std.ArrayListUnmanaged(OwnedRawSample).empty;
    defer {
        for (filtered.items) |s| s.deinit();
        filtered.deinit(alloc);
    }
    try takeWithQueryConditionRaw(dr, qc, &filtered, -1, alloc);
    try testing.expectEqual(@as(usize, 1), filtered.items.len);
    try testing.expectEqualSlices(u8, &[_]u8{5}, filtered.items[0].data);
}
