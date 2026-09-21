//! zig/delete-contained-entities -- peer. Simple counterpart to
//! session.zig: writes to SessionIn, reads from SessionOut1/SessionOut2,
//! exchanges a few samples, then waits for a clean disconnect once the
//! session tears itself down via delete_contained_entities() --
//! matched-current-count must reach zero on every entity matched with the
//! session, without hanging or erroring. See
//! docs/design/integration-test-tier.md for the full scenario spec.
//!
//! Required stdout markers: "Create topic:" x3, "Create writer for topic:",
//! "Create reader for topic:" x2, "Peer: session disconnected cleanly."
//! Any failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const session_event_gen = @import("session_event_gen");

const SAMPLE_COUNT: i32 = 5;
const RECEIVE_TARGET: i32 = 2;
const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const RECEIVE_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const DISCONNECT_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

const MatchState = struct {
    ever_matched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    reader_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

fn onPublicationMatchedEx(state: *MatchState, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
    if (status.current_count > 0) state.ever_matched.store(true, .release);
}

fn onReliableReaderReady(state: *MatchState, reader_handle: DDS.InstanceHandle_t, is_ready: bool) void {
    _ = reader_handle;
    if (is_ready) state.reader_ready.store(true, .release);
}

fn onSubscriptionMatched(state: *MatchState, dr: DDS.DataReader, status: DDS.SubscriptionMatchedStatus) void {
    _ = dr;
    state.matched_current_count.store(status.current_count, .release);
    if (status.current_count > 0) state.ever_matched.store(true, .release);
}

fn setWriterListenerEx(dw: DDS.DataWriter, state: *MatchState) !void {
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
    defer _ = dpf.delete_participant(dp);

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
    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR or subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher/create_subscriber failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const in_dw = publisher.create_datawriter(in_topic, dw_qos, null, 0);
    if (in_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(SessionIn) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: SessionIn\n", .{});

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const out1_topic_desc = dp.lookup_topicdescription("SessionOut1");
    const out2_topic_desc = dp.lookup_topicdescription("SessionOut2");
    const out1_dr = subscriber.create_datareader(out1_topic_desc, dr_qos, null, 0);
    const out2_dr = subscriber.create_datareader(out2_topic_desc, dr_qos, null, 0);
    if (out1_dr.ptr == zzdds.dcps.NIL_PTR or out2_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: SessionOut1\n", .{});
    std.debug.print("Create reader for topic: SessionOut2\n", .{});

    var writer_state = MatchState{};
    var out1_state = MatchState{};
    var out2_state = MatchState{};

    setWriterListenerEx(in_dw, &writer_state) catch {
        std.debug.print("FAIL: set_listener_ex(SessionIn) failed\n", .{});
        std.process.exit(1);
    };

    const out1_listener = DDS.dataReaderListener(&out1_state, .{ .on_subscription_matched = onSubscriptionMatched });
    const out2_listener = DDS.dataReaderListener(&out2_state, .{ .on_subscription_matched = onSubscriptionMatched });
    if (out1_dr.vtable.set_listener(out1_dr.ptr, &out1_listener, DDS.SUBSCRIPTION_MATCHED_STATUS) != DDS.RETCODE_OK or
        out2_dr.vtable.set_listener(out2_dr.ptr, &out2_listener, DDS.SUBSCRIPTION_MATCHED_STATUS) != DDS.RETCODE_OK)
    {
        std.debug.print("FAIL: set_listener (reader) failed\n", .{});
        std.process.exit(1);
    }

    const in_writer = session_event_gen.SessionEventDataWriter.init(in_dw, alloc);
    var out1_reader = session_event_gen.SessionEventDataReader.init(out1_dr, alloc);
    var out2_reader = session_event_gen.SessionEventDataReader.init(out2_dr, alloc);

    // Gate on the session's reader actually being registered, not just
    // matched -- see session.zig's matching comment for why.
    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!writer_state.reader_ready.load(.acquire)) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    var seq: i32 = 0;
    while (seq < SAMPLE_COUNT) : (seq += 1) {
        in_writer.write(.{ .seq = seq }, 0) catch {
            std.debug.print("FAIL: write() failed at seq={d}\n", .{seq});
            std.process.exit(1);
        };
    }
    std.debug.print("Peer: wrote {d} samples on SessionIn\n", .{SAMPLE_COUNT});

    var received1: i32 = 0;
    var received2: i32 = 0;
    const receive_deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (received1 < RECEIVE_TARGET or received2 < RECEIVE_TARGET) {
        if (monoNs(io) > receive_deadline) {
            std.debug.print("FAIL: peer did not receive from session within 20s (out1={d} out2={d})\n", .{ received1, received2 });
            std.process.exit(1);
        }
        var taken1: std.ArrayListUnmanaged(session_event_gen.SessionEventDataReader.SampledValue) = .empty;
        defer taken1.deinit(alloc);
        _ = try out1_reader.take(&taken1, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
        received1 += @intCast(taken1.items.len);

        var taken2: std.ArrayListUnmanaged(session_event_gen.SessionEventDataReader.SampledValue) = .empty;
        defer taken2.deinit(alloc);
        _ = try out2_reader.take(&taken2, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
        received2 += @intCast(taken2.items.len);

        if (received1 < RECEIVE_TARGET or received2 < RECEIVE_TARGET) sleepNs(io, POLL_PERIOD_NS);
    }
    std.debug.print("Peer: received from session (out1={d} out2={d}).\n", .{ received1, received2 });

    const disconnect_deadline = monoNs(io) + DISCONNECT_TIMEOUT_NS;
    while (!(writer_state.ever_matched.load(.acquire) and writer_state.matched_current_count.load(.acquire) == 0 and
        out1_state.ever_matched.load(.acquire) and out1_state.matched_current_count.load(.acquire) == 0 and
        out2_state.ever_matched.load(.acquire) and out2_state.matched_current_count.load(.acquire) == 0))
    {
        if (monoNs(io) > disconnect_deadline) {
            std.debug.print("FAIL: peer never saw a clean disconnect within 30s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Peer: session disconnected cleanly.\n", .{});
    _ = dp.delete_contained_entities();
}
