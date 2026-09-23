//! zig/liveliness-lost -- subscriber. Talks to zzdds's native Zig API
//! directly. Direct Zig port of c/liveliness-lost/src/subscriber.c -- see
//! that file's header comment for the full scenario rationale and
//! docs/design/integration-test-tier.md for the scenario spec.
//!
//! Required stdout markers: "Create topic:" x2, "Create reader for topic:"
//! x2, "Subscriber: both writers matched.", "Subscriber: AUTOMATIC reader
//! never observed NOT_ALIVE, as expected.", "Subscriber:
//! MANUAL_BY_PARTICIPANT reader observed NOT_ALIVE at least once, as
//! expected.", "Subscriber: done." Any failure path prints a line starting
//! "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const liveliness_event_gen = @import("liveliness_event_gen");

const LEASE_DURATION_SEC: i32 = 2;
// Comfortably longer than the publisher's own ~8s write loop (16 writes *
// 500ms), so the observation window covers the whole thing.
const OBSERVE_WINDOW_NS: u64 = 12 * std.time.ns_per_s;
// 40s, not the 20s every other match-wait in this tier uses -- see
// c/liveliness-lost/src/publisher.c's matching comment.
const MATCH_TIMEOUT_NS: i64 = 40 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const ReaderState = struct {
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    alive_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    ever_not_alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onSubscriptionMatched(state: *ReaderState, dr: DDS.DataReader, status: DDS.SubscriptionMatchedStatus) void {
    _ = dr;
    state.matched_current_count.store(status.current_count, .release);
}

fn onLivelinessChanged(state: *ReaderState, dr: DDS.DataReader, status: DDS.LivelinessChangedStatus) void {
    _ = dr;
    state.alive_count.store(status.alive_count, .release);
    if (status.alive_count == 0) state.ever_not_alive.store(true, .release);
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

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var auto_state = ReaderState{};
    var manual_state = ReaderState{};

    const auto_topic = dp.create_topic("AutomaticLivelinessTopic", "LivelinessEvent", .{}, null, 0);
    if (auto_topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(AutomaticLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: AutomaticLivelinessTopic\n", .{});

    var auto_dr_qos = DDS.DataReaderQos{};
    auto_dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    auto_dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    auto_dr_qos.liveliness.kind = .AUTOMATIC_LIVELINESS_QOS;
    auto_dr_qos.liveliness.lease_duration = .{ .sec = LEASE_DURATION_SEC, .nanosec = 0 };

    const auto_topic_desc = auto_topic.vtable.as_TopicDescription(auto_topic.ptr);
    const auto_dr = subscriber.create_datareader(auto_topic_desc, auto_dr_qos, null, 0);
    if (auto_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(AutomaticLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: AutomaticLivelinessTopic\n", .{});
    const auto_dr_listener = DDS.dataReaderListener(&auto_state, .{
        .on_subscription_matched = onSubscriptionMatched,
        .on_liveliness_changed = onLivelinessChanged,
    });
    if (auto_dr.set_listener(auto_dr_listener, DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.LIVELINESS_CHANGED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener(AutomaticLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }

    const manual_topic = dp.create_topic("ManualByParticipantLivelinessTopic", "LivelinessEvent", .{}, null, 0);
    if (manual_topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(ManualByParticipantLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: ManualByParticipantLivelinessTopic\n", .{});

    var manual_dr_qos = DDS.DataReaderQos{};
    manual_dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    manual_dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    manual_dr_qos.liveliness.kind = .MANUAL_BY_PARTICIPANT_LIVELINESS_QOS;
    manual_dr_qos.liveliness.lease_duration = .{ .sec = LEASE_DURATION_SEC, .nanosec = 0 };

    const manual_topic_desc = manual_topic.vtable.as_TopicDescription(manual_topic.ptr);
    const manual_dr = subscriber.create_datareader(manual_topic_desc, manual_dr_qos, null, 0);
    if (manual_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(ManualByParticipantLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: ManualByParticipantLivelinessTopic\n", .{});
    const manual_dr_listener = DDS.dataReaderListener(&manual_state, .{
        .on_subscription_matched = onSubscriptionMatched,
        .on_liveliness_changed = onLivelinessChanged,
    });
    if (manual_dr.set_listener(manual_dr_listener, DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.LIVELINESS_CHANGED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener(ManualByParticipantLivelinessTopic) failed\n", .{});
        std.process.exit(1);
    }

    const match_deadline = monoNs(io) + MATCH_TIMEOUT_NS;
    while (auto_state.matched_current_count.load(.acquire) < 1 or manual_state.matched_current_count.load(.acquire) < 1) {
        if (monoNs(io) > match_deadline) {
            std.debug.print("FAIL: writers never matched within {d}s\n", .{@divExact(MATCH_TIMEOUT_NS, std.time.ns_per_s)});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }
    std.debug.print("Subscriber: both writers matched.\n", .{});

    sleepNs(io, OBSERVE_WINDOW_NS);

    if (auto_state.ever_not_alive.load(.acquire)) {
        std.debug.print("FAIL: AUTOMATIC reader observed NOT_ALIVE (alive_count dropped to 0) at some point, expected never\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: AUTOMATIC reader never observed NOT_ALIVE, as expected.\n", .{});

    if (!manual_state.ever_not_alive.load(.acquire)) {
        std.debug.print("FAIL: MANUAL_BY_PARTICIPANT reader never observed NOT_ALIVE despite the writer never asserting liveliness, expected at least once\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: MANUAL_BY_PARTICIPANT reader observed NOT_ALIVE at least once, as expected.\n", .{});

    std.debug.print("Subscriber: done.\n", .{});
}
