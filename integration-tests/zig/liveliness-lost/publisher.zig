//! zig/liveliness-lost -- publisher. Talks to zzdds's native Zig API
//! directly. Direct Zig port of c/liveliness-lost/src/publisher.c -- see
//! that file's header comment for the full scenario rationale and
//! docs/design/integration-test-tier.md for the scenario spec.
//!
//! Required stdout markers: "Create topic:" x2, "Create writer for topic:"
//! x2, "Publisher: both readers matched.", "Publisher: write loop done.",
//! "Publisher: AUTOMATIC writer never lost liveliness (total_count=0), as
//! expected.", "Publisher: MANUAL_BY_PARTICIPANT writer lost liveliness
//! (total_count=N) despite continuous writing, as expected.", "Publisher:
//! done." Any failure path prints a line starting "FAIL:" and exits
//! nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const liveliness_event_gen = @import("liveliness_event_gen");

const LEASE_DURATION_SEC: i32 = 2;
const WRITE_PERIOD_NS: u64 = 500 * std.time.ns_per_ms;
const WRITE_COUNT: i32 = 16; // 16 * 500ms = 8s, comfortably > 4 lease periods
// 40s, not the 20s every other match-wait in this tier uses -- see
// c/liveliness-lost/src/publisher.c's matching comment.
const MATCH_TIMEOUT_NS: i64 = 40 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const WriterState = struct {
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    liveliness_lost_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
};

fn onPublicationMatched(state: *WriterState, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
}

fn onLivelinessLost(state: *WriterState, dw: DDS.DataWriter, status: DDS.LivelinessLostStatus) void {
    _ = dw;
    _ = status;
    _ = state.liveliness_lost_count.fetchAdd(1, .acq_rel);
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
    if (!zzdds.registerTypeSupport(dp, "LivelinessEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = liveliness_event_gen.LivelinessEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = liveliness_event_gen.LivelinessEvent.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var auto_state = WriterState{};
    var manual_state = WriterState{};

    const auto_topic = dp.create_topic("AutomaticLivelinessTopic", "LivelinessEvent", .{}, null, 0);
    if (auto_topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(AutomaticLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: AutomaticLivelinessTopic\n", .{});

    var auto_dw_qos = DDS.DataWriterQos{};
    auto_dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    auto_dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    auto_dw_qos.liveliness.kind = .AUTOMATIC_LIVELINESS_QOS;
    auto_dw_qos.liveliness.lease_duration = .{ .sec = LEASE_DURATION_SEC, .nanosec = 0 };

    const auto_dw = publisher.create_datawriter(auto_topic, auto_dw_qos, null, 0);
    if (auto_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(AutomaticLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: AutomaticLivelinessTopic\n", .{});
    const auto_dw_listener = DDS.dataWriterListener(&auto_state, .{
        .on_publication_matched = onPublicationMatched,
        .on_liveliness_lost = onLivelinessLost,
    });
    if (auto_dw.set_listener(auto_dw_listener, DDS.PUBLICATION_MATCHED_STATUS | DDS.LIVELINESS_LOST_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener(AutomaticLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }

    const manual_topic = dp.create_topic("ManualByParticipantLivelinessTopic", "LivelinessEvent", .{}, null, 0);
    if (manual_topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(ManualByParticipantLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: ManualByParticipantLivelinessTopic\n", .{});

    var manual_dw_qos = DDS.DataWriterQos{};
    manual_dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    manual_dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    manual_dw_qos.liveliness.kind = .MANUAL_BY_PARTICIPANT_LIVELINESS_QOS;
    manual_dw_qos.liveliness.lease_duration = .{ .sec = LEASE_DURATION_SEC, .nanosec = 0 };

    const manual_dw = publisher.create_datawriter(manual_topic, manual_dw_qos, null, 0);
    if (manual_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(ManualByParticipantLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: ManualByParticipantLivelinessTopic\n", .{});
    const manual_dw_listener = DDS.dataWriterListener(&manual_state, .{
        .on_publication_matched = onPublicationMatched,
        .on_liveliness_lost = onLivelinessLost,
    });
    if (manual_dw.set_listener(manual_dw_listener, DDS.PUBLICATION_MATCHED_STATUS | DDS.LIVELINESS_LOST_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener(ManualByParticipantLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }

    const auto_writer = liveliness_event_gen.LivelinessEventDataWriter.init(auto_dw, alloc);
    const manual_writer = liveliness_event_gen.LivelinessEventDataWriter.init(manual_dw, alloc);

    const match_deadline = monoNs(io) + MATCH_TIMEOUT_NS;
    while (auto_state.matched_current_count.load(.acquire) < 1 or manual_state.matched_current_count.load(.acquire) < 1) {
        if (monoNs(io) > match_deadline) {
            std.debug.print("FAIL: readers never matched within {d}s\n", .{@divExact(MATCH_TIMEOUT_NS, std.time.ns_per_s)});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }
    std.debug.print("Publisher: both readers matched.\n", .{});

    // Deliberately never call assert_liveliness() anywhere in this loop --
    // that's the whole point (see c/liveliness-lost/src/publisher.c's
    // header comment).
    var i: i32 = 0;
    while (i < WRITE_COUNT) : (i += 1) {
        auto_writer.write(.{ .seq = i }, 0) catch {
            std.debug.print("FAIL: write(AUTOMATIC) failed at seq={d}\n", .{i});
            std.process.exit(1);
        };
        manual_writer.write(.{ .seq = i }, 0) catch {
            std.debug.print("FAIL: write(MANUAL_BY_PARTICIPANT) failed at seq={d}\n", .{i});
            std.process.exit(1);
        };
        sleepNs(io, WRITE_PERIOD_NS);
    }
    std.debug.print("Publisher: write loop done.\n", .{});

    var auto_status: DDS.LivelinessLostStatus = .{};
    if (auto_dw.get_liveliness_lost_status(&auto_status) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: get_liveliness_lost_status(AUTOMATIC) failed\n", .{});
        std.process.exit(1);
    }
    var manual_status: DDS.LivelinessLostStatus = .{};
    if (manual_dw.get_liveliness_lost_status(&manual_status) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: get_liveliness_lost_status(MANUAL_BY_PARTICIPANT) failed\n", .{});
        std.process.exit(1);
    }

    if (auto_state.liveliness_lost_count.load(.acquire) != 0 or auto_status.total_count != 0) {
        std.debug.print("FAIL: AUTOMATIC writer lost liveliness (listener_count={d}, status.total_count={d}), expected never\n", .{ auto_state.liveliness_lost_count.load(.acquire), auto_status.total_count });
        std.process.exit(1);
    }
    std.debug.print("Publisher: AUTOMATIC writer never lost liveliness (total_count=0), as expected.\n", .{});

    if (manual_state.liveliness_lost_count.load(.acquire) < 1 or manual_status.total_count < 1) {
        std.debug.print("FAIL: MANUAL_BY_PARTICIPANT writer never lost liveliness (listener_count={d}, status.total_count={d}) despite never asserting it, expected >=1\n", .{ manual_state.liveliness_lost_count.load(.acquire), manual_status.total_count });
        std.process.exit(1);
    }
    std.debug.print("Publisher: MANUAL_BY_PARTICIPANT writer lost liveliness (total_count={d}) despite continuous writing, as expected.\n", .{manual_status.total_count});

    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (auto_state.matched_current_count.load(.acquire) != 0 or manual_state.matched_current_count.load(.acquire) != 0) {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Publisher: done.\n", .{});
}
