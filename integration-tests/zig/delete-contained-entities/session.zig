//! zig/delete-contained-entities -- session. The entity under test. Builds
//! a small tree (2 DataWriters, a plain DataReader, a
//! ContentFilteredTopic-backed DataReader, a ReadCondition attached to a
//! WaitSet) under one participant, exchanges a few samples with the peer,
//! then tears the whole tree down in one shot via
//! DomainParticipant.delete_contained_entities() instead of deleting each
//! child first -- the point of this scenario is exercising the cascade, not
//! manual teardown. See docs/design/integration-test-tier.md for the full
//! scenario spec.
//!
//! Core assertions: delete_contained_entities() returns RETCODE_OK, the
//! immediately-following delete_participant() ALSO returns RETCODE_OK (per
//! spec this only succeeds if the cascade genuinely left nothing dangling),
//! and no matched-status listener ever fires after the torn_down flag is
//! set.
//!
//! Required stdout markers: "Create topic:" x3, "Create writer for topic:"
//! x2, "Create reader for topic:" x2, "Session: torn down via
//! delete_contained_entities." Any failure path prints a line starting
//! "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const session_event_gen = @import("session_event_gen");

const SAMPLE_COUNT: i32 = 5;
const RECEIVE_TARGET: i32 = 2;
const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const RECEIVE_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

var torn_down = std.atomic.Value(bool).init(false);

const WriterSyncState = struct {
    reader_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

fn onPublicationMatchedEx(state: *WriterSyncState, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = state;
    _ = dw;
    _ = status;
    if (torn_down.load(.acquire)) {
        std.debug.print("FAIL: listener fired after delete_contained_entities\n", .{});
        std.process.exit(1);
    }
}

fn onReliableReaderReady(state: *WriterSyncState, reader_handle: DDS.InstanceHandle_t, is_ready: bool) void {
    _ = reader_handle;
    if (is_ready) state.reader_ready.store(true, .release);
}

const ReaderSyncNoop = struct {};
var reader_sync_noop = ReaderSyncNoop{};

fn onSubscriptionMatched(ctx: *ReaderSyncNoop, dr: DDS.DataReader, status: DDS.SubscriptionMatchedStatus) void {
    _ = ctx;
    _ = dr;
    _ = status;
    if (torn_down.load(.acquire)) {
        std.debug.print("FAIL: listener fired after delete_contained_entities\n", .{});
        std.process.exit(1);
    }
}

fn setWriterListenerEx(dw: DDS.DataWriter, state: *WriterSyncState) !void {
    const zdw = zzdds.asZzddsDataWriter(dw) orelse return error.AsZzddsDataWriterFailed;
    if (zdw.set_listener_ex(ZZDDS.dataWriterListenerEx(state, .{
        .on_publication_matched = onPublicationMatchedEx,
        .on_reliable_reader_ready = onReliableReaderReady,
    }), DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) return error.SetListenerExFailed;
}

fn parseDomain(process_args: std.process.Args) u32 {
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            const v = it.next() orelse continue;
            return std.fmt.parseInt(u32, v, 10) catch 0;
        }
    }
    return 0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const domain_id = parseDomain(init.minimal.args);

    var factory = zzdds.createFactory() catch {
        std.debug.print("FAIL: createFactory() failed\n", .{});
        std.process.exit(1);
    };
    defer factory.deinit();
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(domain_id, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_participant() failed on domain {d}\n", .{domain_id});
        std.process.exit(1);
    }

    var ts_alloc = alloc;
    if (!zzdds.registerTypeSupport(dp, "SessionEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = session_event_gen.SessionEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = session_event_gen.SessionEvent.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport(SessionEvent) failed\n", .{});
        std.process.exit(1);
    }

    const out1_topic = dp.create_topic("SessionOut1", "SessionEvent", .{}, null, 0);
    const out2_topic = dp.create_topic("SessionOut2", "SessionEvent", .{}, null, 0);
    const in_topic = dp.create_topic("SessionIn", "SessionEvent", .{}, null, 0);
    if (out1_topic.ptr == zzdds.dcps.NIL_PTR or out2_topic.ptr == zzdds.dcps.NIL_PTR or in_topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: SessionOut1\n", .{});
    std.debug.print("Create topic: SessionOut2\n", .{});
    std.debug.print("Create topic: SessionIn\n", .{});

    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const out1_dw = publisher.create_datawriter(out1_topic, dw_qos, null, 0);
    const out2_dw = publisher.create_datawriter(out2_topic, dw_qos, null, 0);
    if (out1_dw.ptr == zzdds.dcps.NIL_PTR or out2_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: SessionOut1\n", .{});
    std.debug.print("Create writer for topic: SessionOut2\n", .{});

    var out1_state = WriterSyncState{};
    var out2_state = WriterSyncState{};
    setWriterListenerEx(out1_dw, &out1_state) catch {
        std.debug.print("FAIL: set_listener_ex(SessionOut1) failed\n", .{});
        std.process.exit(1);
    };
    setWriterListenerEx(out2_dw, &out2_state) catch {
        std.debug.print("FAIL: set_listener_ex(SessionOut2) failed\n", .{});
        std.process.exit(1);
    };

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const in_topic_desc = dp.lookup_topicdescription("SessionIn");
    const in_dr = subscriber.create_datareader(in_topic_desc, dr_qos, null, 0);
    if (in_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(SessionIn) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: SessionIn\n", .{});

    // Exercise CFT-collateral cleanup under the cascade -- this project has
    // a real CFT bug history (see docs/decisions.md). Trivial filter: just
    // needs to exist and be attached, not to actually narrow anything.
    const cft = dp.create_contentfilteredtopic("SessionIn_cft", in_topic, "seq >= 0", null);
    if (cft.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_contentfilteredtopic() failed\n", .{});
        std.process.exit(1);
    }
    const cft_desc = cft.vtable.as_TopicDescription(cft.ptr);
    const cft_dr = subscriber.create_datareader(cft_desc, dr_qos, null, 0);
    if (cft_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(SessionIn_cft) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: SessionIn_cft\n", .{});

    const in_dr_listener = DDS.dataReaderListener(&reader_sync_noop, .{
        .on_subscription_matched = onSubscriptionMatched,
    });
    if (in_dr.vtable.set_listener(in_dr.ptr, &in_dr_listener, DDS.SUBSCRIPTION_MATCHED_STATUS) != DDS.RETCODE_OK or
        cft_dr.vtable.set_listener(cft_dr.ptr, &in_dr_listener, DDS.SUBSCRIPTION_MATCHED_STATUS) != DDS.RETCODE_OK)
    {
        std.debug.print("FAIL: set_listener (reader) failed\n", .{});
        std.process.exit(1);
    }

    const ws = zzdds.createWaitSet(alloc) catch {
        std.debug.print("FAIL: createWaitSet() failed\n", .{});
        std.process.exit(1);
    };
    const in_rc = in_dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    if (in_rc.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_readcondition() failed\n", .{});
        std.process.exit(1);
    }
    if (ws.attach_condition(in_rc.vtable.as_Condition(in_rc.ptr)) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: attach_condition() failed\n", .{});
        std.process.exit(1);
    }

    const out1_writer = session_event_gen.SessionEventDataWriter.init(out1_dw, alloc);
    const out2_writer = session_event_gen.SessionEventDataWriter.init(out2_dw, alloc);
    var in_reader = session_event_gen.SessionEventDataReader.init(in_dr, alloc);

    // Gate writes on the peer's reader actually being registered, not just
    // matched -- see docs/design/integration-test-tier.md's raw-loan/
    // coherent-sets precedent and this project's on_reliable_reader_ready
    // work: matched-count alone (SEDP discovery) does not imply the remote
    // RELIABLE reader proxy has registered this writer yet.
    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!(out1_state.reader_ready.load(.acquire) and out2_state.reader_ready.load(.acquire))) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    var seq: i32 = 0;
    while (seq < SAMPLE_COUNT) : (seq += 1) {
        out1_writer.write(.{ .seq = seq }, 0) catch {
            std.debug.print("FAIL: write() failed at seq={d}\n", .{seq});
            std.process.exit(1);
        };
        out2_writer.write(.{ .seq = seq }, 0) catch {
            std.debug.print("FAIL: write() failed at seq={d}\n", .{seq});
            std.process.exit(1);
        };
    }
    std.debug.print("Session: wrote {d} samples on SessionOut1/SessionOut2\n", .{SAMPLE_COUNT});

    var received: i32 = 0;
    const receive_deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (received < RECEIVE_TARGET) {
        if (monoNs(io) > receive_deadline) {
            std.debug.print("FAIL: session did not receive from peer within 20s (got {d})\n", .{received});
            std.process.exit(1);
        }
        var active = DDS.ConditionSeq{};
        const wr = ws.wait(&active, .{ .sec = 1, .nanosec = 0 });
        defer if (active._release) {
            if (active._buffer) |b| alloc.free(b[0..active._maximum]);
        };
        if (wr == DDS.RETCODE_TIMEOUT) continue;
        if (wr != DDS.RETCODE_OK) {
            std.debug.print("FAIL: WaitSet.wait() returned {d}\n", .{wr});
            std.process.exit(1);
        }

        var taken: std.ArrayListUnmanaged(session_event_gen.SessionEventDataReader.SampledValue) = .empty;
        defer taken.deinit(alloc);
        _ = try in_reader.take(&taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
        received += @intCast(taken.items.len);
    }
    std.debug.print("Session: received {d} samples from peer.\n", .{received});

    // The core test: tear the whole tree down in one shot instead of
    // deleting out1_dw/out2_dw/in_dr/cft_dr/cft one at a time.
    torn_down.store(true, .release);

    const rc1 = dp.delete_contained_entities();
    if (rc1 != DDS.RETCODE_OK) {
        std.debug.print("FAIL: delete_contained_entities() returned {d}, expected RETCODE_OK\n", .{rc1});
        std.process.exit(1);
    }

    const rc2 = dpf.delete_participant(dp);
    if (rc2 != DDS.RETCODE_OK) {
        std.debug.print("FAIL: delete_participant() returned {d} after delete_contained_entities -- cascade left something dangling\n", .{rc2});
        std.process.exit(1);
    }

    ws.deinit();
    std.debug.print("Session: torn down via delete_contained_entities.\n", .{});
}
