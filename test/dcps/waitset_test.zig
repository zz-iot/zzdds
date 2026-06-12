//! WaitSet coverage tests.
//!
//! Covers paths not exercised by api_test.zig:
//!   - WakeupList.unregister, WakeupList.register slot-full
//!   - WaitSet infinite-timeout path (condvar.wait)
//!   - WaitSet timedWaitNs condvar-timeout path (lines 174-176)
//!   - WaitSet notified fast-path (lines 161-163)
//!   - WaitSet duplicate attach, get_conditions, detach for all three condition types
//!   - ReadConditionImpl vtable accessors and trigger
//!   - StatusConditionImpl vtable accessors (get/set_enabled_statuses, get_entity, deinit)
//!   - QueryConditionImpl init/deinit, get/set params, match, vtable accessors

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const dcps = zzdds.dcps;
const WaitSetImpl = dcps.WaitSetImpl;
const GuardConditionImpl = dcps.GuardConditionImpl;
const ReadConditionImpl = dcps.ReadConditionImpl;
const StatusConditionImpl = dcps.StatusConditionImpl;
const QueryConditionImpl = dcps.QueryConditionImpl;
const DataNotifyFn = dcps.DataNotifyFn;

const time_mod = zzdds.util.time;
const testing = std.testing;

const DURATION_ZERO: DDS.Duration_t = .{ .sec = 0, .nanosec = 0 };
const DURATION_INFINITE: DDS.Duration_t = .{
    .sec = DDS.DURATION_INFINITE_SEC,
    .nanosec = DDS.DURATION_INFINITE_NSEC,
};
// Long enough that the condvar must sleep, short enough to keep the test fast.
const DURATION_10MS: DDS.Duration_t = .{ .sec = 0, .nanosec = 10_000_000 };

// ── Stub Entity vtable ────────────────────────────────────────────────────────

var g_entity_status: DDS.StatusMask = 0;
var stub_entity_sentinel: u8 = 0;

fn entEnable(_: *anyopaque) DDS.ReturnCode_t {
    return DDS.RETCODE_OK;
}
fn entGetSC(_: *anyopaque) DDS.StatusCondition {
    unreachable;
}
fn entGetStatusChanges(_: *anyopaque) DDS.StatusMask {
    return g_entity_status;
}
fn entGetIH(_: *anyopaque) DDS.InstanceHandle_t {
    return 0;
}
fn entNoDeinit(_: *anyopaque) void {}

const stub_entity_vtable = DDS.Entity.Vtable{
    .enable = entEnable,
    .get_statuscondition = entGetSC,
    .get_status_changes = entGetStatusChanges,
    .get_instance_handle = entGetIH,
    .deinit = entNoDeinit,
};

fn stubEntity() DDS.Entity {
    return .{ .ptr = &stub_entity_sentinel, .vtable = &stub_entity_vtable };
}

fn getEntityStatus(_: *anyopaque) DDS.StatusMask {
    return g_entity_status;
}

// ── Stub DataReader for ReadCondition / QueryCondition ────────────────────────

var g_has_data: bool = false;
var g_reader_sentinel: u8 = 0;
var g_notify_fn: ?DataNotifyFn = null;

fn readerHasData(_: *anyopaque) bool {
    return g_has_data;
}
fn readerAddNotify(_: *anyopaque, n: DataNotifyFn) void {
    g_notify_fn = n;
}
fn readerRemoveNotify(_: *anyopaque, _: *anyopaque) void {
    g_notify_fn = null;
}

// DataReader vtable stubs — never called during these tests.
fn drNoop1(_: *anyopaque) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop2(_: *anyopaque) DDS.StatusCondition {
    unreachable;
}
fn drNoop3(_: *anyopaque) DDS.StatusMask {
    unreachable;
}
fn drNoop4(_: *anyopaque) DDS.InstanceHandle_t {
    unreachable;
}
fn drNoop5(_: *anyopaque, _: DDS.SampleStateMask, _: DDS.ViewStateMask, _: DDS.InstanceStateMask) DDS.ReadCondition {
    unreachable;
}
fn drNoop6(_: *anyopaque, _: DDS.SampleStateMask, _: DDS.ViewStateMask, _: DDS.InstanceStateMask, _: [*:0]const u8, _: ?*const DDS.StringSeq) DDS.QueryCondition {
    unreachable;
}
fn drNoop7(_: *anyopaque, _: DDS.ReadCondition) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop8(_: *anyopaque) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop9(_: *anyopaque, _: *const DDS.DataReaderQos) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop10(_: *anyopaque, _: *DDS.DataReaderQos) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop11(_: *anyopaque, _: ?*const DDS.DataReaderListener, _: DDS.StatusMask) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop12(_: *anyopaque) DDS.DataReaderListener {
    unreachable;
}
fn drNoop13(_: *anyopaque) DDS.TopicDescription {
    unreachable;
}
fn drNoop14(_: *anyopaque) DDS.Subscriber {
    unreachable;
}
fn drNoop15(_: *anyopaque, _: *DDS.SampleRejectedStatus) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop16(_: *anyopaque, _: *DDS.LivelinessChangedStatus) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop17(_: *anyopaque, _: *DDS.RequestedDeadlineMissedStatus) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop18(_: *anyopaque, _: *DDS.RequestedIncompatibleQosStatus) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop19(_: *anyopaque, _: *DDS.SubscriptionMatchedStatus) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop20(_: *anyopaque, _: *DDS.SampleLostStatus) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop21(_: *anyopaque, _: *const DDS.Duration_t) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop22(_: *anyopaque, _: ?*DDS.InstanceHandleSeq) DDS.ReturnCode_t {
    unreachable;
}
fn drNoop23(_: *anyopaque, _: *DDS.PublicationBuiltinTopicData, _: DDS.InstanceHandle_t) DDS.ReturnCode_t {
    unreachable;
}
fn drNoDeinit(_: *anyopaque) void {}

const stub_dr_vtable = DDS.DataReader.Vtable{
    .enable = drNoop1,
    .get_statuscondition = drNoop2,
    .get_status_changes = drNoop3,
    .get_instance_handle = drNoop4,
    .create_readcondition = drNoop5,
    .create_querycondition = drNoop6,
    .delete_readcondition = drNoop7,
    .delete_contained_entities = drNoop8,
    .set_qos = drNoop9,
    .get_qos = drNoop10,
    .set_listener = drNoop11,
    .get_listener = drNoop12,
    .get_topicdescription = drNoop13,
    .get_subscriber = drNoop14,
    .get_sample_rejected_status = drNoop15,
    .get_liveliness_changed_status = drNoop16,
    .get_requested_deadline_missed_status = drNoop17,
    .get_requested_incompatible_qos_status = drNoop18,
    .get_subscription_matched_status = drNoop19,
    .get_sample_lost_status = drNoop20,
    .wait_for_historical_data = drNoop21,
    .get_matched_publications = drNoop22,
    .get_matched_publication_data = drNoop23,
    .deinit = drNoDeinit,
};

fn stubDataReader() DDS.DataReader {
    return .{ .ptr = &g_reader_sentinel, .vtable = &stub_dr_vtable };
}

fn makeRC(a: std.mem.Allocator) !*ReadConditionImpl {
    return ReadConditionImpl.init(
        a,
        stubDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
}

// ── WakeupList: unregister and slot-full paths ────────────────────────────────

test "WakeupList: unregister removes the handler" {
    const a = testing.allocator;

    const gc = try GuardConditionImpl.init(a);
    defer gc.deinit();

    const ws1 = try WaitSetImpl.init(a);
    defer ws1.deinit();
    const ws2 = try WaitSetImpl.init(a);
    defer ws2.deinit();

    const dws1 = ws1.toDDSWaitSet();
    const dws2 = ws2.toDDSWaitSet();
    const cond = gc.toCondition();

    _ = dws1.attach_condition(cond);
    _ = dws2.attach_condition(cond);

    // Detach ws1 — exercises WakeupList.unregister
    _ = dws1.detach_condition(cond);

    // Only ws2 should receive the notification; ws1 must not see it.
    _ = gc.toDDSGuardCondition().set_trigger_value(true);

    var active: DDS.ConditionSeq = .{};
    defer if (active._release) {
        if (active._buffer) |_b| a.free(_b[0..active._length]);
    };
    const rc = dws2.wait(&active, DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(usize, 1), active._length);
}

test "WakeupList: register returns false when all slots are full" {
    const a = testing.allocator;

    const gc = try GuardConditionImpl.init(a);
    defer gc.deinit();

    // Fill all 4 WAKEUP_SLOTS by attaching 4 WaitSets.
    var waitsets: [5]*WaitSetImpl = undefined;
    for (&waitsets) |*ws| ws.* = try WaitSetImpl.init(a);
    defer for (waitsets) |ws| ws.deinit();

    const cond = gc.toCondition();
    for (waitsets[0..4]) |ws| _ = ws.toDDSWaitSet().attach_condition(cond);

    // 5th attach: all slots full — register returns false, attach still succeeds
    // (condition is recorded but push notification is silently dropped).
    const rc5 = waitsets[4].toDDSWaitSet().attach_condition(cond);
    try testing.expectEqual(DDS.RETCODE_OK, rc5);
}

// ── WaitSet: infinite-timeout wait (condvar.wait path) ───────────────────────

test "WaitSet: infinite-timeout wait woken by GuardCondition from thread" {
    const a = testing.allocator;

    const gc = try GuardConditionImpl.init(a);
    defer gc.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();

    const dws = ws.toDDSWaitSet();
    _ = dws.attach_condition(gc.toCondition());

    const dds_gc = gc.toDDSGuardCondition();
    const Trigger = struct {
        fn run(cond: DDS.GuardCondition) void {
            time_mod.sleepNs(20 * std.time.ns_per_ms);
            _ = cond.set_trigger_value(true);
        }
    };
    const thr = try std.Thread.spawn(.{}, Trigger.run, .{dds_gc});
    defer thr.join();

    var active: DDS.ConditionSeq = .{};
    defer if (active._release) {
        if (active._buffer) |_b| a.free(_b[0..active._length]);
    };
    const rc = dws.wait(&active, DURATION_INFINITE);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(usize, 1), active._length);
}

// ── WaitSet: condvar timedWaitNs timeout path (lines 174-176) ────────────────

test "WaitSet: timedWait expires inside condvar (not before entering it)" {
    const a = testing.allocator;

    const gc = try GuardConditionImpl.init(a);
    defer gc.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();

    _ = ws.toDDSWaitSet().attach_condition(gc.toCondition());

    var active: DDS.ConditionSeq = .{};
    defer if (active._release) {
        if (active._buffer) |_b| a.free(_b[0..active._length]);
    };
    // 10ms timeout: condition never triggered, so condvar sleeps through the
    // deadline, exercising the timedWaitNs error-catch block.
    const rc = ws.toDDSWaitSet().wait(&active, DURATION_10MS);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc);
    try testing.expectEqual(@as(usize, 0), active._length);
}

// ── WaitSet: notified fast-path (lines 161-163) ──────────────────────────────

test "WaitSet: pre-set notified flag is consumed without sleeping" {
    const a = testing.allocator;

    const gc = try GuardConditionImpl.init(a);
    defer gc.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();

    _ = ws.toDDSWaitSet().attach_condition(gc.toCondition());

    // Force notified=true so the first cv_mu check hits the fast path.
    ws.notified = true;

    var active: DDS.ConditionSeq = .{};
    defer if (active._release) {
        if (active._buffer) |_b| a.free(_b[0..active._length]);
    };
    // GC trigger is false; after the fast path reloops, the deadline (=now) is
    // reached and TIMEOUT is returned.
    const rc = ws.toDDSWaitSet().wait(&active, DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, rc);
}

// ── WaitSet: duplicate attach ─────────────────────────────────────────────────

test "WaitSet: attaching the same condition twice is idempotent" {
    const a = testing.allocator;

    const gc = try GuardConditionImpl.init(a);
    defer gc.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();

    const dws = ws.toDDSWaitSet();
    const cond = gc.toCondition();
    _ = dws.attach_condition(cond);
    _ = dws.attach_condition(cond); // duplicate

    var conditions: DDS.ConditionSeq = .{};
    defer if (conditions._release) {
        if (conditions._buffer) |_b| a.free(_b[0..conditions._length]);
    };
    _ = dws.get_conditions(&conditions);
    // Only one entry despite two attach calls.
    try testing.expectEqual(@as(usize, 1), conditions._length);
}

// ── WaitSet: get_conditions ───────────────────────────────────────────────────

test "WaitSet: get_conditions returns all attached conditions" {
    const a = testing.allocator;

    const gc1 = try GuardConditionImpl.init(a);
    defer gc1.deinit();
    const gc2 = try GuardConditionImpl.init(a);
    defer gc2.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();

    const dws = ws.toDDSWaitSet();
    _ = dws.attach_condition(gc1.toCondition());
    _ = dws.attach_condition(gc2.toCondition());

    var conditions: DDS.ConditionSeq = .{};
    defer if (conditions._release) {
        if (conditions._buffer) |_b| a.free(_b[0..conditions._length]);
    };
    const rc = dws.get_conditions(&conditions);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(usize, 2), conditions._length);
}

// ── WaitSet: attach / detach for ReadCondition ────────────────────────────────

test "WaitSet: attach and detach ReadCondition" {
    const a = testing.allocator;
    g_has_data = false;
    g_notify_fn = null;

    const rc_impl = try makeRC(a);
    defer rc_impl.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();

    const dws = ws.toDDSWaitSet();
    const cond = rc_impl.toCondition();

    _ = dws.attach_condition(cond);
    try testing.expect(g_notify_fn != null); // add_notify_fn was called

    _ = dws.detach_condition(cond);
    try testing.expect(g_notify_fn == null); // remove_notify_fn was called
}

test "WaitSet: ReadCondition triggers when has_data returns true" {
    const a = testing.allocator;
    g_has_data = true;
    defer {
        g_has_data = false;
    }

    const rc_impl = try makeRC(a);
    defer rc_impl.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();

    _ = ws.toDDSWaitSet().attach_condition(rc_impl.toCondition());

    var active: DDS.ConditionSeq = .{};
    defer if (active._release) {
        if (active._buffer) |_b| a.free(_b[0..active._length]);
    };
    const rc = ws.toDDSWaitSet().wait(&active, DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(usize, 1), active._length);
}

// ── WaitSet: attach / detach for StatusCondition ──────────────────────────────

test "WaitSet: attach and detach StatusCondition" {
    const a = testing.allocator;
    g_entity_status = 0;

    const sc = try StatusConditionImpl.init(a, stubEntity(), getEntityStatus);
    defer sc.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();

    const dws = ws.toDDSWaitSet();
    const cond = sc.toCondition();
    _ = dws.attach_condition(cond);
    _ = dws.detach_condition(cond);

    // After detach, get_conditions should be empty.
    var conditions: DDS.ConditionSeq = .{};
    defer if (conditions._release) {
        if (conditions._buffer) |_b| a.free(_b[0..conditions._length]);
    };
    _ = dws.get_conditions(&conditions);
    try testing.expectEqual(@as(usize, 0), conditions._length);
}

// ── WaitSet: detach not-found returns PRECONDITION_NOT_MET ───────────────────

test "WaitSet: detaching a condition not in the set returns PRECONDITION_NOT_MET" {
    const a = testing.allocator;

    const gc = try GuardConditionImpl.init(a);
    defer gc.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();

    const rc = ws.toDDSWaitSet().detach_condition(gc.toCondition());
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, rc);
}

// ── ReadConditionImpl vtable accessors ────────────────────────────────────────

test "ReadConditionImpl: vtable accessors return constructed values" {
    const a = testing.allocator;
    g_has_data = false;

    const rc = try ReadConditionImpl.init(
        a,
        stubDataReader(),
        DDS.READ_SAMPLE_STATE,
        DDS.NEW_VIEW_STATE,
        DDS.ALIVE_INSTANCE_STATE,
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
    defer rc.deinit();

    const dds_rc = rc.toDDSReadCondition();

    try testing.expectEqual(false, dds_rc.get_trigger_value());
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, dds_rc.get_sample_state_mask());
    try testing.expectEqual(DDS.NEW_VIEW_STATE, dds_rc.get_view_state_mask());
    try testing.expectEqual(DDS.ALIVE_INSTANCE_STATE, dds_rc.get_instance_state_mask());
    try testing.expectEqual(
        @intFromPtr(stubDataReader().ptr),
        @intFromPtr(dds_rc.get_datareader().ptr),
    );
}

test "ReadConditionImpl: get_trigger_value reflects has_data_fn" {
    const a = testing.allocator;
    g_has_data = false;

    const rc = try makeRC(a);
    const dds_rc = rc.toDDSReadCondition();
    try testing.expectEqual(false, dds_rc.get_trigger_value());

    g_has_data = true;
    try testing.expectEqual(true, dds_rc.get_trigger_value());

    g_has_data = false;
    dds_rc.deinit(); // exercises vtDeinit via DDS.ReadCondition interface
}

// ── StatusConditionImpl vtable accessors ──────────────────────────────────────

test "StatusConditionImpl: default enabled mask is STATUS_MASK_ANY" {
    const a = testing.allocator;
    g_entity_status = 0;

    const sc = try StatusConditionImpl.init(a, stubEntity(), getEntityStatus);
    defer sc.deinit();

    const dds_sc = sc.toDDSStatusCondition();
    try testing.expectEqual(@as(DDS.StatusMask, 0x7FFF), dds_sc.get_enabled_statuses());
}

test "StatusConditionImpl: set_enabled_statuses narrows the trigger mask" {
    const a = testing.allocator;
    g_entity_status = 0x0001;

    const sc = try StatusConditionImpl.init(a, stubEntity(), getEntityStatus);
    defer sc.deinit();

    const dds_sc = sc.toDDSStatusCondition();

    // Default mask is 0x7FFF; entity_status bit 0x0001 is set → triggered.
    try testing.expectEqual(true, dds_sc.get_trigger_value());

    // Narrow to a mask that excludes bit 0x0001 → no longer triggered.
    _ = dds_sc.set_enabled_statuses(0x0002);
    try testing.expectEqual(@as(DDS.StatusMask, 0x0002), dds_sc.get_enabled_statuses());
    try testing.expectEqual(false, dds_sc.get_trigger_value());
}

test "StatusConditionImpl: get_entity returns the bound entity" {
    const a = testing.allocator;
    g_entity_status = 0;

    const sc = try StatusConditionImpl.init(a, stubEntity(), getEntityStatus);
    defer sc.deinit();

    const entity = sc.toDDSStatusCondition().get_entity();
    try testing.expectEqual(@intFromPtr(stubEntity().ptr), @intFromPtr(entity.ptr));
}

test "StatusConditionImpl: deinit via DDS.StatusCondition vtable" {
    const a = testing.allocator;
    g_entity_status = 0;

    const sc = try StatusConditionImpl.init(a, stubEntity(), getEntityStatus);
    sc.toDDSStatusCondition().deinit(); // exercises vtDeinit
    // No crash = pass (memory freed via allocator).
}

// ── QueryConditionImpl: init / deinit / accessors ────────────────────────────

test "QueryConditionImpl: empty expression init and deinit" {
    const a = testing.allocator;
    g_has_data = false;

    const qc = try QueryConditionImpl.init(
        a,
        stubDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        "",
        DDS.StringSeq{},
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
    qc.deinit();
}

test "QueryConditionImpl: vtable accessors return constructed values" {
    const a = testing.allocator;
    g_has_data = false;

    const qc = try QueryConditionImpl.init(
        a,
        stubDataReader(),
        DDS.READ_SAMPLE_STATE,
        DDS.NEW_VIEW_STATE,
        DDS.ALIVE_INSTANCE_STATE,
        "x = 1",
        DDS.StringSeq{},
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
    defer qc.deinit();

    const dds_qc = qc.toDDSQueryCondition();

    try testing.expectEqual(false, dds_qc.get_trigger_value());
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, dds_qc.get_sample_state_mask());
    try testing.expectEqual(DDS.NEW_VIEW_STATE, dds_qc.get_view_state_mask());
    try testing.expectEqual(DDS.ALIVE_INSTANCE_STATE, dds_qc.get_instance_state_mask());
    try testing.expectEqual(
        @intFromPtr(stubDataReader().ptr),
        @intFromPtr(dds_qc.get_datareader().ptr),
    );
    try testing.expectEqualStrings("x = 1", dds_qc.get_query_expression());
}

test "QueryConditionImpl: get_trigger_value reflects has_data_fn" {
    const a = testing.allocator;
    g_has_data = false;

    const qc = try QueryConditionImpl.init(
        a,
        stubDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        "",
        DDS.StringSeq{},
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
    defer qc.deinit();

    const dds_qc = qc.toDDSQueryCondition();
    try testing.expectEqual(false, dds_qc.get_trigger_value());
    g_has_data = true;
    defer {
        g_has_data = false;
    }
    try testing.expectEqual(true, dds_qc.get_trigger_value());
}

test "QueryConditionImpl: get_query_parameters and set_query_parameters" {
    const a = testing.allocator;
    g_has_data = false;

    var init_strs: [2][*:0]const u8 = .{ "hello", "world" };
    const initial_params = DDS.StringSeq{ ._buffer = @ptrCast(&init_strs), ._length = 2, ._maximum = 2, ._release = false };

    const qc = try QueryConditionImpl.init(
        a,
        stubDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        "",
        initial_params,
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
    defer qc.deinit();

    const dds_qc = qc.toDDSQueryCondition();

    const freeStringSeq = struct {
        fn f(seq: DDS.StringSeq, alloc: std.mem.Allocator) void {
            if (!seq._release) return;
            if (seq._buffer) |b| {
                for (b[0..seq._length]) |p| {
                    const s = std.mem.span(p);
                    alloc.free(s.ptr[0 .. s.len + 1]);
                }
                alloc.free(b[0..seq._length]);
            }
        }
    }.f;

    // get_query_parameters returns owned duped strings (dupeZ: len+1 bytes each).
    var out1 = DDS.StringSeq{};
    const rc_get = dds_qc.get_query_parameters(&out1);
    defer freeStringSeq(out1, a);
    try testing.expectEqual(DDS.RETCODE_OK, rc_get);
    try testing.expectEqual(@as(u32, 2), out1._length);
    try testing.expectEqualStrings("hello", std.mem.span(out1._buffer.?[0]));
    try testing.expectEqualStrings("world", std.mem.span(out1._buffer.?[1]));

    // Replace parameters.
    var new_strs: [1][*:0]const u8 = .{"foo"};
    const new_params = DDS.StringSeq{ ._buffer = @ptrCast(&new_strs), ._length = 1, ._maximum = 1, ._release = false };
    const rc_set = dds_qc.set_query_parameters(&new_params);
    try testing.expectEqual(DDS.RETCODE_OK, rc_set);

    var out2 = DDS.StringSeq{};
    _ = dds_qc.get_query_parameters(&out2);
    defer freeStringSeq(out2, a);
    try testing.expectEqual(@as(u32, 1), out2._length);
    try testing.expectEqualStrings("foo", std.mem.span(out2._buffer.?[0]));
}

test "QueryConditionImpl: toCondition delegates to embedded ReadConditionImpl" {
    const a = testing.allocator;
    g_has_data = false;

    const qc = try QueryConditionImpl.init(
        a,
        stubDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        "",
        DDS.StringSeq{},
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
    defer qc.deinit();

    // toCondition returns the ReadConditionImpl's condition interface.
    const cond = qc.toCondition();
    try testing.expectEqual(false, cond.get_trigger_value());
}

test "QueryConditionImpl: deinit via DDS.QueryCondition vtable" {
    const a = testing.allocator;
    g_has_data = false;

    const qc = try QueryConditionImpl.init(
        a,
        stubDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        "y > 0",
        DDS.StringSeq{},
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
    qc.toDDSQueryCondition().deinit(); // exercises vtDeinit
}

test "QueryConditionImpl: matchSample with simple field expression" {
    const a = testing.allocator;
    g_has_data = false;

    const qc = try QueryConditionImpl.init(
        a,
        stubDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        "x = 'hello'",
        DDS.StringSeq{},
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
    defer qc.deinit();

    const GetField = struct {
        fn get(payload: []const u8, field: []const u8) ?zzdds.dcps.filter.FilterValue {
            _ = payload;
            if (std.mem.eql(u8, field, "x"))
                return .{ .string = "hello" };
            return null;
        }
    };

    try testing.expect(qc.matchSample("ignored", GetField.get));
}

// ── Prior-buffer-free paths ───────────────────────────────────────────────────

test "WaitSet: get_conditions frees prior _release buffer on second call" {
    // Exercises the if (seq._release) free block in vtGetConditions.
    const a = testing.allocator;

    const gc1 = try GuardConditionImpl.init(a);
    defer gc1.deinit();
    const gc2 = try GuardConditionImpl.init(a);
    defer gc2.deinit();
    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();
    const dws = ws.toDDSWaitSet();
    _ = dws.attach_condition(gc1.toCondition());
    _ = dws.attach_condition(gc2.toCondition());

    // First call — allocates a buffer and sets _release=true.
    var seq: DDS.ConditionSeq = .{};
    _ = dws.get_conditions(&seq);
    try testing.expect(seq._release);
    try testing.expectEqual(@as(u32, 2), seq._length);

    // Second call with the same output var — vtGetConditions must free the
    // first buffer before allocating a new one (leak detector catches if not).
    _ = dws.get_conditions(&seq);
    try testing.expectEqual(@as(u32, 2), seq._length);

    // Clean up the second buffer.
    if (seq._buffer) |b| a.free(b[0..seq._maximum]);
}

test "WaitSet: vtWait with two pre-triggered conditions returns both" {
    // Exercises the grow-by-one loop in vtWait for n > 1.
    const a = testing.allocator;

    const gc1 = try GuardConditionImpl.init(a);
    defer gc1.deinit();
    const gc2 = try GuardConditionImpl.init(a);
    defer gc2.deinit();
    _ = gc1.toDDSGuardCondition().set_trigger_value(true);
    _ = gc2.toDDSGuardCondition().set_trigger_value(true);

    const ws = try WaitSetImpl.init(a);
    defer ws.deinit();
    _ = ws.toDDSWaitSet().attach_condition(gc1.toCondition());
    _ = ws.toDDSWaitSet().attach_condition(gc2.toCondition());

    var active: DDS.ConditionSeq = .{};
    defer if (active._release) {
        if (active._buffer) |b| a.free(b[0..active._maximum]);
    };
    const rc = ws.toDDSWaitSet().wait(&active, DURATION_ZERO);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(u32, 2), active._length);
}

test "QueryConditionImpl: get_query_parameters frees prior _release buffer on second call" {
    // Exercises the if (seq._release) free block in vtGetParams.
    const a = testing.allocator;
    g_has_data = false;

    var init_strs: [1][*:0]const u8 = .{"alpha"};
    const init_seq = DDS.StringSeq{ ._buffer = @ptrCast(&init_strs), ._length = 1, ._maximum = 1, ._release = false };

    const qc = try QueryConditionImpl.init(
        a,
        stubDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        "",
        init_seq,
        readerHasData,
        &g_reader_sentinel,
        readerAddNotify,
        readerRemoveNotify,
    );
    defer qc.deinit();
    const dds_qc = qc.toDDSQueryCondition();

    const freeStringSeq = struct {
        fn f(seq: DDS.StringSeq, alloc: std.mem.Allocator) void {
            if (!seq._release) return;
            if (seq._buffer) |b| {
                for (b[0..seq._length]) |p| alloc.free(std.mem.span(p).ptr[0 .. std.mem.span(p).len + 1]);
                alloc.free(b[0..seq._maximum]);
            }
        }
    }.f;

    // First call — allocates owned strings, sets _release=true.
    var out: DDS.StringSeq = .{};
    _ = dds_qc.get_query_parameters(&out);
    try testing.expect(out._release);

    // Second call with the same output var — vtGetParams must free the first
    // buffer before allocating the second (leak detector catches if not).
    _ = dds_qc.get_query_parameters(&out);
    try testing.expectEqual(@as(u32, 1), out._length);

    defer freeStringSeq(out, a);
}
