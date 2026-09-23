//! zig/cft-reconfigure -- subscriber (the entity under test). Talks to
//! zzdds's native Zig API directly. Direct Zig port of
//! c/cft-reconfigure/src/subscriber.c -- see that file's header comment for
//! the full scenario rationale and docs/design/integration-test-tier.md for
//! the scenario spec.
//!
//! Required stdout markers: "Create topic:" x2, "Create reader for topic:"
//! x2, "Create writer for topic:", "Subscriber: CFT introspection
//! (filter_expression/expression_parameters/related_topic) verified at
//! creation.", "Subscriber: ready.", "Subscriber: witnessed all 5 phase1
//! samples via unfiltered reader.", "Subscriber: filtered reader correctly
//! received zero phase1 samples (threshold=1000).", "Subscriber:
//! set_expression_parameters() reconfigured threshold to 3, read-back
//! verified.", "Subscriber: sent go-ahead signal.", "Subscriber: witnessed
//! all 10 total samples via unfiltered reader.", "Subscriber: filtered
//! reader received exactly the post-reconfigure samples {5..9}, confirming
//! live re-filtering without CFT recreation.", "Subscriber: done." Any
//! failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const cft_event_gen = @import("cft_event_gen");

const TOTAL_COUNT: i32 = 10;
const PHASE1_COUNT: i32 = 5;
const PHASE2_COUNT: i32 = 5;
// Must comfortably exceed publisher.zig's own MATCH_TIMEOUT_NS -- see
// c/cft-reconfigure/src/subscriber.c's matching comment.
const WITNESS_TIMEOUT_NS: i64 = 45 * std.time.ns_per_s;
const SETTLE_WINDOW_NS: u64 = 3 * std.time.ns_per_s;
const FINAL_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

fn freeStringSeq(seq: *DDS.StringSeq) void {
    if (seq._release) {
        if (seq._buffer) |b| {
            for (b[0..seq._length]) |s| std.heap.c_allocator.free(std.mem.span(s));
            std.heap.c_allocator.free(b[0..seq._maximum]);
        }
    }
    seq.* = .{};
}

const ReaderState = struct {
    reader: cft_event_gen.CftEventDataReader = undefined,
    received: [TOTAL_COUNT]std.atomic.Value(bool) = .{std.atomic.Value(bool).init(false)} ** TOTAL_COUNT,
    count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
};

fn onDataAvailable(state: *ReaderState, dr: DDS.DataReader) void {
    _ = dr;
    while (true) {
        var value: cft_event_gen.CftEvent = .{};
        var info: DDS.SampleInfo = .{};
        const got = state.reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample() CDR error\n", .{});
            std.process.exit(1);
        };
        if (!got) break;
        if (!info.valid_data) continue;
        if (value.seq < 0 or value.seq >= TOTAL_COUNT) {
            std.debug.print("FAIL: unexpected seq={d}\n", .{value.seq});
            std.process.exit(1);
        }
        const idx: usize = @intCast(value.seq);
        if (!state.received[idx].load(.acquire)) {
            state.received[idx].store(true, .release);
            _ = state.count.fetchAdd(1, .acq_rel);
        }
    }
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
    if (!zzdds.registerTypeSupport(dp, "CftEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = cft_event_gen.CftEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = cft_event_gen.CftEvent.computeKeyHashFromCdrKeyOnly,
        // Needed for ContentFilteredTopic expression evaluation at delivery
        // time -- without this, the CFT reader silently receives everything
        // unfiltered (the generated C-ABI TypeSupport_register() wires this
        // in automatically; the raw Zig-native registerTypeSupport() call
        // does not, so it must be passed explicitly here).
        .get_field = cft_event_gen.CftEvent.getFieldFromCdr,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("CftEvent", "CftEvent", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: CftEvent\n", .{});

    const go_topic = dp.create_topic("GoTopic", "CftEvent", .{}, null, 0);
    if (go_topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(GoTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: GoTopic\n", .{});

    const subscriber = dp.create_subscriber(.{}, null, 0);
    const publisher = dp.create_publisher(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR or publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber()/create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    // -- Witness reader: plain, unfiltered, proves end-to-end wire delivery
    // independent of the filtered reader's own behavior. --
    const witness_desc = topic.vtable.as_TopicDescription(topic.ptr);
    const witness_dr = subscriber.create_datareader(witness_desc, dr_qos, null, 0);
    if (witness_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(witness) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: CftEvent (witness)\n", .{});

    // -- ContentFilteredTopic: initial threshold (1000) unreachable by
    // phase1's seq range (0..4), so every phase1 sample must be filtered
    // out. --
    var initial_param_bufs: [1][*:0]const u8 = .{"1000"};
    var initial_params = DDS.StringSeq{ ._buffer = &initial_param_bufs, ._length = 1, ._maximum = 1, ._release = false };
    const cft = dp.create_contentfilteredtopic("CftEvent_Filtered", topic, "seq >= %0", &initial_params);
    if (cft.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_contentfilteredtopic() failed\n", .{});
        std.process.exit(1);
    }

    // -- CFT introspection, verified right at creation -- the exact
    // surface the API audit flags as "set once at creation, never read
    // back". --
    const filter_expr = cft.get_filter_expression();
    if (!std.mem.eql(u8, filter_expr, "seq >= %0")) {
        std.debug.print("FAIL: get_filter_expression() returned \"{s}\", expected \"seq >= %0\"\n", .{filter_expr});
        std.process.exit(1);
    }
    var readback_params: DDS.StringSeq = .{};
    defer freeStringSeq(&readback_params);
    if (cft.get_expression_parameters(&readback_params) != DDS.RETCODE_OK or readback_params._length != 1 or !std.mem.eql(u8, std.mem.span(readback_params._buffer.?[0]), "1000")) {
        std.debug.print("FAIL: get_expression_parameters() at creation did not return [\"1000\"]\n", .{});
        std.process.exit(1);
    }
    const related = cft.get_related_topic();
    if (related.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: get_related_topic() returned nil\n", .{});
        std.process.exit(1);
    }
    const related_name = related.get_name();
    if (!std.mem.eql(u8, related_name, "CftEvent")) {
        std.debug.print("FAIL: get_related_topic() did not return the CftEvent topic (got \"{s}\")\n", .{related_name});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: CFT introspection (filter_expression/expression_parameters/related_topic) verified at creation.\n", .{});

    const cft_desc = cft.vtable.as_TopicDescription(cft.ptr);
    const filtered_dr = subscriber.create_datareader(cft_desc, dr_qos, null, 0);
    if (filtered_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(filtered) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: CftEvent_Filtered\n", .{});

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const go_dw = publisher.create_datawriter(go_topic, dw_qos, null, 0);
    if (go_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(GoTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: GoTopic\n", .{});

    var witness_state = ReaderState{};
    var filtered_state = ReaderState{};
    witness_state.reader = cft_event_gen.CftEventDataReader.init(witness_dr, alloc);
    filtered_state.reader = cft_event_gen.CftEventDataReader.init(filtered_dr, alloc);

    const witness_listener = DDS.dataReaderListener(&witness_state, .{ .on_data_available = onDataAvailable });
    const filtered_listener = DDS.dataReaderListener(&filtered_state, .{ .on_data_available = onDataAvailable });
    if (witness_dr.set_listener(witness_listener, DDS.DATA_AVAILABLE_STATUS) != DDS.RETCODE_OK or
        filtered_dr.set_listener(filtered_listener, DDS.DATA_AVAILABLE_STATUS) != DDS.RETCODE_OK)
    {
        std.debug.print("FAIL: set_listener() failed\n", .{});
        std.process.exit(1);
    }

    const go_writer = cft_event_gen.CftEventDataWriter.init(go_dw, alloc);

    std.debug.print("Subscriber: ready.\n", .{});

    // -- Phase 1: wait for the witness reader to see all 5, proving they
    // really were sent and really did arrive over the wire. --
    const witness_deadline = monoNs(io) + WITNESS_TIMEOUT_NS;
    while (witness_state.count.load(.acquire) < PHASE1_COUNT) {
        if (monoNs(io) > witness_deadline) {
            std.debug.print("FAIL: witness reader only saw {d}/{d} phase1 samples within {d}s\n", .{ witness_state.count.load(.acquire), PHASE1_COUNT, @divExact(WITNESS_TIMEOUT_NS, std.time.ns_per_s) });
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }
    std.debug.print("Subscriber: witnessed all {d} phase1 samples via unfiltered reader.\n", .{PHASE1_COUNT});

    // -- Settle window, then confirm the filtered reader received none of
    // phase1 (threshold=1000 excludes seq 0..4 entirely). --
    sleepNs(io, SETTLE_WINDOW_NS);
    const filtered_after_phase1 = filtered_state.count.load(.acquire);
    if (filtered_after_phase1 != 0) {
        std.debug.print("FAIL: filtered reader received {d} phase1 samples despite threshold=1000\n", .{filtered_after_phase1});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: filtered reader correctly received zero phase1 samples (threshold=1000).\n", .{});

    // -- Reconfigure the live CFT in place -- no recreation of the CFT or
    // its DataReader. --
    var new_param_bufs: [1][*:0]const u8 = .{"3"};
    var new_params = DDS.StringSeq{ ._buffer = &new_param_bufs, ._length = 1, ._maximum = 1, ._release = false };
    if (cft.set_expression_parameters(&new_params) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_expression_parameters() failed\n", .{});
        std.process.exit(1);
    }
    var readback2: DDS.StringSeq = .{};
    defer freeStringSeq(&readback2);
    if (cft.get_expression_parameters(&readback2) != DDS.RETCODE_OK or readback2._length != 1 or !std.mem.eql(u8, std.mem.span(readback2._buffer.?[0]), "3")) {
        std.debug.print("FAIL: get_expression_parameters() after reconfigure did not return [\"3\"]\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: set_expression_parameters() reconfigured threshold to 3, read-back verified.\n", .{});

    go_writer.write(.{ .seq = 0 }, 0) catch {
        std.debug.print("FAIL: write(GoTopic) failed\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Subscriber: sent go-ahead signal.\n", .{});

    // -- Phase 2: wait for the witness reader to see all 10 total. --
    const final_deadline = monoNs(io) + FINAL_TIMEOUT_NS;
    while (witness_state.count.load(.acquire) < TOTAL_COUNT) {
        if (monoNs(io) > final_deadline) {
            std.debug.print("FAIL: witness reader only saw {d}/{d} total samples within 20s\n", .{ witness_state.count.load(.acquire), TOTAL_COUNT });
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }
    std.debug.print("Subscriber: witnessed all {d} total samples via unfiltered reader.\n", .{TOTAL_COUNT});

    // The witness and filtered readers are separate DataReaders with independent
    // delivery/dispatch, so the witness reader reaching TOTAL_COUNT does not
    // guarantee the filtered reader's own listener has finished processing its
    // (fewer) samples yet. Wait for the filtered reader's own count before
    // asserting its exact contents below, or a correct implementation can fail
    // this nondeterministically (found via Greptile review).
    const filtered_deadline = monoNs(io) + FINAL_TIMEOUT_NS;
    while (filtered_state.count.load(.acquire) < PHASE2_COUNT) {
        if (monoNs(io) > filtered_deadline) {
            std.debug.print("FAIL: filtered reader only saw {d}/{d} phase2 samples within {d}s\n", .{ filtered_state.count.load(.acquire), PHASE2_COUNT, @divExact(FINAL_TIMEOUT_NS, std.time.ns_per_s) });
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    // -- The core assertion: the filtered reader must have received
    // *exactly* {5,6,7,8,9} -- phase2 correctly re-filtered against the new
    // threshold (proving live reconfiguration works), and phase1's seq=3
    // and seq=4 (both >= the *new* threshold of 3) never retroactively
    // appear (proving already-dropped samples are gone for good, not
    // replayed against the new parameter). --
    var seq: i32 = 0;
    while (seq < PHASE1_COUNT) : (seq += 1) {
        if (filtered_state.received[@intCast(seq)].load(.acquire)) {
            std.debug.print("FAIL: filtered reader retroactively received phase1 seq={d} after reconfigure\n", .{seq});
            std.process.exit(1);
        }
    }
    while (seq < TOTAL_COUNT) : (seq += 1) {
        if (!filtered_state.received[@intCast(seq)].load(.acquire)) {
            std.debug.print("FAIL: filtered reader never received phase2 seq={d} despite threshold=3\n", .{seq});
            std.process.exit(1);
        }
    }
    if (filtered_state.count.load(.acquire) != PHASE2_COUNT) {
        std.debug.print("FAIL: filtered reader received {d} samples total, expected exactly {d}\n", .{ filtered_state.count.load(.acquire), PHASE2_COUNT });
        std.process.exit(1);
    }
    std.debug.print("Subscriber: filtered reader received exactly the post-reconfigure samples {{5..9}}, confirming live re-filtering without CFT recreation.\n", .{});

    std.debug.print("Subscriber: done.\n", .{});
}
