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
const PublisherImpl = @import("dcps/publisher.zig").PublisherImpl;
const SubscriberImpl = @import("dcps/subscriber.zig").SubscriberImpl;
const ContentFilteredTopicImpl = @import("dcps/topic.zig").ContentFilteredTopicImpl;
const WaitSetImpl = dcps_waitset.WaitSetImpl;
const GuardConditionImpl = dcps_waitset.GuardConditionImpl;

/// Write kind for module-level write operations.
pub const WriteKind = enum { alive, dispose, unregister };

/// A raw sample taken or read from a DataReader: a loan of the reader's own
/// sample, which `deinit` ends. `data` is valid until then, and while one is
/// out its reader cannot be deleted. A caller that could not decode it sets
/// `failed` first: `deinit` then hands it to the reader's
/// `set_keep_undecodable` policy, as `return_loan_raw_failed` does
/// (docs/design/concurrency/operation-effects.md#two-step-take).
pub const OwnedRawSample = struct {
    data: []u8,
    info: DDS.SampleInfo,
    failed: bool = false,
    _reader: *DataReaderImpl,
    _pc: *dcps_reader.PendingChange,
    _taken: bool,

    pub fn deinit(self: *const @This()) void {
        self._reader.endLoanedSample(self._pc, self._taken, self.failed);
    }
};

/// What a native raw take or read selects.
const LoanSelection = union(enum) {
    samples: struct {
        ss: DDS.SampleStateMask = DDS.ANY_SAMPLE_STATE,
        vs: DDS.ViewStateMask = DDS.ANY_VIEW_STATE,
        is: DDS.InstanceStateMask = DDS.ANY_INSTANCE_STATE,
        ih: ?DDS.InstanceHandle_t = null,
        qc: ?*const dcps_waitset.QueryConditionImpl = null,
    },
    next_instance: struct {
        prev: DDS.InstanceHandle_t,
        ss: DDS.SampleStateMask = DDS.ANY_SAMPLE_STATE,
        vs: DDS.ViewStateMask = DDS.ANY_VIEW_STATE,
        is: DDS.InstanceStateMask = DDS.ANY_INSTANCE_STATE,
        qc: ?*const dcps_waitset.QueryConditionImpl = null,
    },
};

/// Takes (`taken`) or reads up to `max` samples on loan into `out`, each an
/// `OwnedRawSample` that keeps its reader alive until it ends. `out` grows
/// with `caller_alloc` before anything is selected, so running out of memory
/// changes nothing.
fn loanInto(
    impl: *DataReaderImpl,
    taken: bool,
    sel: LoanSelection,
    max: i32,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    caller_alloc: std.mem.Allocator,
) !void {
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
    if (!impl.acquireProto()) return error.AlreadyDeleted;
    defer impl.proto_reader.quiesceRelease();
    const Prep = struct {
        out: *std.ArrayListUnmanaged(OwnedRawSample),
        alloc: std.mem.Allocator,
        fn prepare(ctx: *anyopaque, n: usize) error{OutOfMemory}!void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            try p.out.ensureUnusedCapacity(p.alloc, n);
        }
    };
    var prep: Prep = .{ .out = out, .alloc = caller_alloc };
    const prepare: dcps_reader.PrepareOutput = .{ .ctx = &prep, .prepare = Prep.prepare };
    const pcs = switch (sel) {
        .samples => |f| if (taken)
            try impl.takeSamplesForLoanPrepared(f.ss, f.vs, f.is, max, f.ih, f.qc, prepare)
        else
            try impl.pinSamplesForLoanPrepared(f.ss, f.vs, f.is, max, f.ih, f.qc, prepare),
        .next_instance => |f| if (taken)
            try impl.takeNextInstanceForLoanPrepared(f.prev, f.ss, f.vs, f.is, max, f.qc, prepare)
        else
            try impl.pinNextInstanceForLoanPrepared(f.prev, f.ss, f.vs, f.is, max, f.qc, prepare),
    };
    defer impl.alloc.free(pcs);
    for (pcs) |pc| {
        // Each sample holds the reader, until its `deinit`: retained from
        // this call's own ref, so even a deletion begun meanwhile (which
        // the sample's loan then defers) cannot refuse it.
        impl.retainQuiesce();
        out.appendAssumeCapacity(.{ .data = pc.data, .info = pc.info, ._reader = impl, ._pc = pc, ._taken = taken });
    }
}

/// One sample on loan, or null if none (or out of memory).
fn loanOne(reader: DDS.DataReader, taken: bool, sel: LoanSelection) ?OwnedRawSample {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    var buf: [1]OwnedRawSample = undefined;
    var out: std.ArrayListUnmanaged(OwnedRawSample) = .initBuffer(&buf);
    // `out` has room for the one sample: it never allocates.
    loanInto(impl, taken, sel, 1, &out, impl.alloc) catch return null;
    return if (out.items.len == 1) out.items[0] else null;
}

fn toChangeKind(kind: WriteKind, impl: *DataWriterImpl) history_mod.ChangeKind {
    return switch (kind) {
        .alive => .alive,
        .dispose => .not_alive_disposed,
        .unregister => if (impl.autodispose.load(.monotonic))
            .not_alive_disposed_unregistered
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
/// themselves. Consumes the supplied context on both success and failure.
/// Returns false on allocation failure or if a pinned library owns the name.
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

/// See `asZzddsDataWriter` -- same shape, for `Publisher` (reaches
/// `create_datawriter_ex`).
pub fn asZzddsPublisher(publisher: DDS.Publisher) ?ZZDDS.Publisher {
    if (publisher.vtable != &PublisherImpl.vtable) return null;
    return .{ .ptr = publisher.ptr, .vtable = &zzdds_ext.publisher_vtable };
}

/// See `asZzddsDataWriter` -- same shape, for `Subscriber` (reaches
/// `create_datareader_ex`).
pub fn asZzddsSubscriber(subscriber: DDS.Subscriber) ?ZZDDS.Subscriber {
    if (subscriber.vtable != &SubscriberImpl.vtable) return null;
    return .{ .ptr = subscriber.ptr, .vtable = &zzdds_ext.subscriber_vtable };
}

/// See `asZzddsDataWriter` -- same shape, for `ContentFilteredTopic` (reaches
/// `set_filter_expression`).
pub fn asZzddsContentFilteredTopic(cft: DDS.ContentFilteredTopic) ?ZZDDS.ContentFilteredTopic {
    if (cft.vtable != &ContentFilteredTopicImpl.cft_vtable) return null;
    return .{ .ptr = cft.ptr, .vtable = &zzdds_ext.cft_vtable };
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
/// directly on their generated interface types). The Zig counterpart of the
/// generated `DDS_WaitSet_create` (constructed by src/c_abi/extensions.zig's
/// `waitSetCtor`), giving Zig callers the same one-call surface instead of
/// requiring them to reach `WaitSetImpl.init` themselves.
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
    _ = try impl.writeRaw(ck, time_mod.RtpsTimestamp.now(), key_hash, data);
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
    _ = try impl.writeRaw(ck, rtps_ts, key_hash, data);
}

/// register_instance: the handle of the key hash's instance on this writer,
/// registering it if it is not; HANDLE_NIL if it cannot be. `key_cdr`, the
/// instance's key-only CDR with its encapsulation header, is its key for
/// get_key_value if it has none yet; empty if the caller has none.
pub fn registerInstanceRaw(writer: DDS.DataWriter, key_hash: [16]u8, key_cdr: []const u8) DDS.InstanceHandle_t {
    const impl: *DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    if (!impl.acquireQuiesce()) return DDS.HANDLE_NIL;
    defer impl.releaseQuiesce();
    return impl.registerInstance(key_hash, key_cdr);
}

/// Why get_key_value failed, named for its DDS return code: the writer or
/// reader is deleted, not yet enabled (DDS 1.4 §2.2.2.1.1.7), or the handle
/// names no instance of it with a key (§2.2.2.4.2.9, §2.2.2.5.3.29); or there
/// is no memory for the copy.
pub const GetKeyValueError = error{ AlreadyDeleted, NotEnabled, BadParameter, OutOfMemory };

/// The key an instance keeps for get_key_value: key-only CDR, or a complete
/// sample when the type has no key projection (`key_value.KeyValue`).
pub const KeyValue = @import("dcps/key_value.zig").KeyValue;

/// get_key_value: a copy, from `allocator`, of the key the instance `handle`
/// names keeps, which a binding decodes the key fields from. Copied while
/// the writer is held, so a concurrent delete cannot free it under the
/// caller; the caller frees its `payload`.
pub fn getKeyValueWriter(writer: DDS.DataWriter, handle: DDS.InstanceHandle_t, allocator: std.mem.Allocator) GetKeyValueError!KeyValue {
    const impl: *DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
    return copyKeyValue(impl, handle, allocator);
}

/// The key `impl` (a writer or reader) keeps for the instance `handle`
/// names, copied into memory from `allocator`: sized first, then copied
/// under the endpoint's lock, as the instance may be reclaimed. A key is
/// never replaced, so it is the same size both times; BadParameter if the
/// instance is reclaimed in between.
fn copyKeyValue(impl: anytype, handle: DDS.InstanceHandle_t, allocator: std.mem.Allocator) GetKeyValueError!KeyValue {
    const size = try impl.keyValue(handle, &.{});
    const payload = try allocator.alloc(u8, size.len);
    errdefer allocator.free(payload);
    const copy = try impl.keyValue(handle, payload);
    if (!copy.copied or copy.len != payload.len) return error.BadParameter;
    return .{ .payload = payload, .key_only = copy.key_only };
}

/// lookup_instance: the handle of the key hash's instance on this writer, or
/// HANDLE_NIL if it is not registered: never registered or written, or
/// unregistered since.
pub fn lookupInstanceWriter(writer: DDS.DataWriter, key_hash: [16]u8) DDS.InstanceHandle_t {
    const impl: *DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    if (!impl.acquireQuiesce()) return DDS.HANDLE_NIL;
    defer impl.releaseQuiesce();
    return impl.lookupInstance(key_hash);
}

// ── Reader operations ─────────────────────────────────────────────────────────

/// Takes the next pending sample on loan, or null if none.
/// The caller must `deinit` the returned sample.
pub fn takeRaw(reader: DDS.DataReader) ?OwnedRawSample {
    return loanOne(reader, true, .{ .samples = .{} });
}

/// Non-destructively returns the next pending sample on loan, or null if
/// none. The sample's sample_state is updated to READ.
/// The caller must `deinit` the returned sample.
pub fn readNextSampleRaw(reader: DDS.DataReader) ?OwnedRawSample {
    return loanOne(reader, false, .{ .samples = .{} });
}

/// Takes the next sample of the "next" instance after `prev` (HANDLE_NIL =
/// first) on loan. The caller must `deinit` the returned sample.
pub fn takeNextInstanceRaw(
    reader: DDS.DataReader,
    prev: DDS.InstanceHandle_t,
) ?OwnedRawSample {
    return loanOne(reader, true, .{ .next_instance = .{ .prev = prev } });
}

/// Non-destructively returns the next sample of the "next" instance after
/// `prev` on loan. The sample's sample_state is updated to READ.
/// The caller must `deinit` the returned sample.
pub fn readNextInstanceRaw(
    reader: DDS.DataReader,
    prev: DDS.InstanceHandle_t,
) ?OwnedRawSample {
    return loanOne(reader, false, .{ .next_instance = .{ .prev = prev } });
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
    try loanInto(impl, true, .{ .samples = .{ .ss = ss, .vs = vs, .is = is, .ih = maybe_ih } }, max, out, caller_alloc);
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
    const qc_impl: *const dcps_waitset.QueryConditionImpl = @ptrCast(@alignCast(qc.ptr));
    try loanInto(impl, true, .{ .samples = .{
        .ss = qc_impl.rc.sample_state_mask,
        .vs = qc_impl.rc.view_state_mask,
        .is = qc_impl.rc.instance_state_mask,
        .qc = qc_impl,
    } }, max, out, caller_alloc);
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
    const rc_impl: *const dcps_waitset.ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
    try loanInto(impl, true, .{ .samples = .{
        .ss = rc_impl.sample_state_mask,
        .vs = rc_impl.view_state_mask,
        .is = rc_impl.instance_state_mask,
        .qc = rc_impl.owner_qc,
    } }, max, out, caller_alloc);
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
    const rc_impl: *const dcps_waitset.ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
    try loanInto(impl, false, .{ .samples = .{
        .ss = rc_impl.sample_state_mask,
        .vs = rc_impl.view_state_mask,
        .is = rc_impl.instance_state_mask,
        .qc = rc_impl.owner_qc,
    } }, max, out, caller_alloc);
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
    const rc_impl: *const dcps_waitset.ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
    try loanInto(impl, true, .{ .next_instance = .{
        .prev = prev,
        .ss = rc_impl.sample_state_mask,
        .vs = rc_impl.view_state_mask,
        .is = rc_impl.instance_state_mask,
        .qc = rc_impl.owner_qc,
    } }, max, out, caller_alloc);
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
    const rc_impl: *const dcps_waitset.ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
    try loanInto(impl, false, .{ .next_instance = .{
        .prev = prev,
        .ss = rc_impl.sample_state_mask,
        .vs = rc_impl.view_state_mask,
        .is = rc_impl.instance_state_mask,
        .qc = rc_impl.owner_qc,
    } }, max, out, caller_alloc);
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
    try loanInto(impl, false, .{ .samples = .{ .ss = ss, .vs = vs, .is = is, .ih = maybe_ih } }, max, out, caller_alloc);
}

/// get_key_value: as `getKeyValueWriter`, for the instance `handle` names
/// on `reader`.
pub fn getKeyValueReader(reader: DDS.DataReader, handle: DDS.InstanceHandle_t, allocator: std.mem.Allocator) GetKeyValueError!KeyValue {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    if (!impl.acquireQuiesce()) return error.AlreadyDeleted;
    defer impl.releaseQuiesce();
    return copyKeyValue(impl, handle, allocator);
}

/// lookup_instance: the handle of the key hash's instance on this reader if
/// it is ALIVE, or null.
pub fn lookupInstanceReader(reader: DDS.DataReader, key_hash: [16]u8) ?DDS.InstanceHandle_t {
    const impl: *DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    if (!impl.acquireQuiesce()) return null;
    defer impl.releaseQuiesce();
    return impl.lookupInstance(key_hash);
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
