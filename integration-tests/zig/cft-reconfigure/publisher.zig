//! zig/cft-reconfigure -- publisher. Talks to zzdds's native Zig API
//! directly. Direct Zig port of c/cft-reconfigure/src/publisher.c -- see
//! that file's header comment for the full scenario rationale and
//! docs/design/integration-test-tier.md for the scenario spec.
//!
//! Required stdout markers: "Create topic:" x2, "Create writer for
//! topic:", "Publisher: wrote phase1 seq=", "Publisher: received go-ahead
//! signal.", "Publisher: wrote phase2 seq=", "Publisher: done." Any
//! failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const cft_event_gen = @import("cft_event_gen");

const PHASE1_COUNT: i32 = 5;
const PHASE2_COUNT: i32 = 5;
// 40s, not the 20s every other match-wait in this tier uses -- see
// c/cft-reconfigure/src/publisher.c's matching comment.
const MATCH_TIMEOUT_NS: i64 = 40 * std.time.ns_per_s;
const GO_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const PubState = struct {
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
};

fn onPublicationMatched(state: *PubState, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
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

    const publisher = dp.create_publisher(.{}, null, 0);
    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR or subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher()/create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const dw = publisher.create_datawriter(topic, dw_qos, null, 0);
    if (dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: CftEvent\n", .{});

    var state = PubState{};
    const dw_listener = DDS.dataWriterListener(&state, .{
        .on_publication_matched = onPublicationMatched,
    });
    if (dw.set_listener(dw_listener, DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const go_desc = go_topic.vtable.as_TopicDescription(go_topic.ptr);
    const go_dr = subscriber.create_datareader(go_desc, dr_qos, null, 0);
    if (go_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(GoTopic) failed\n", .{});
        std.process.exit(1);
    }

    const writer = cft_event_gen.CftEventDataWriter.init(dw, alloc);
    const go_reader = cft_event_gen.CftEventDataReader.init(go_dr, alloc);

    // -- Wait for both of the subscriber's readers (witness + filtered) to
    // match before writing anything, so phase1 is guaranteed to actually
    // reach both. --
    const match_deadline = monoNs(io) + MATCH_TIMEOUT_NS;
    while (state.matched_current_count.load(.acquire) < 2) {
        if (monoNs(io) > match_deadline) {
            std.debug.print("FAIL: fewer than 2 readers matched within {d}s (got {d})\n", .{ @divExact(MATCH_TIMEOUT_NS, std.time.ns_per_s), state.matched_current_count.load(.acquire) });
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    // -- Phase 1: written while the CFT's threshold excludes all of it. --
    var seq: i32 = 0;
    while (seq < PHASE1_COUNT) : (seq += 1) {
        writer.write(.{ .seq = seq }, 0) catch {
            std.debug.print("FAIL: write(phase1) failed at seq={d}\n", .{seq});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote phase1 seq={d}\n", .{seq});
    }

    // -- Wait for the subscriber's go-ahead: it has confirmed phase1 was
    // filtered out and reconfigured the CFT's parameters in place. --
    var got_go = false;
    const go_deadline = monoNs(io) + GO_TIMEOUT_NS;
    while (!got_go) {
        if (monoNs(io) > go_deadline) {
            std.debug.print("FAIL: go-ahead signal never arrived within 20s\n", .{});
            std.process.exit(1);
        }
        var value: cft_event_gen.CftEvent = .{};
        var info: DDS.SampleInfo = .{};
        const got = go_reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample(GoTopic) CDR error\n", .{});
            std.process.exit(1);
        };
        if (got and info.valid_data) {
            got_go = true;
            break;
        }
        sleepNs(io, POLL_PERIOD_NS);
    }
    std.debug.print("Publisher: received go-ahead signal.\n", .{});

    // -- Phase 2: written after the reconfigure, on the same DataWriter. --
    while (seq < PHASE1_COUNT + PHASE2_COUNT) : (seq += 1) {
        writer.write(.{ .seq = seq }, 0) catch {
            std.debug.print("FAIL: write(phase2) failed at seq={d}\n", .{seq});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote phase2 seq={d}\n", .{seq});
    }

    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (state.matched_current_count.load(.acquire) != 0) {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Publisher: done.\n", .{});
}
