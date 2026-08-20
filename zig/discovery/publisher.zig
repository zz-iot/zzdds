//! zig/discovery -- publisher.
//!
//! After creating its topic, calls `DomainParticipant.get_discovered_topics`/
//! `get_discovered_topic_data` -- these succeed immediately, even before any
//! remote peer appears, because a participant registers its own
//! locally-created topics into its discovered-topics table right away (see
//! zzdds's `src/dcps/participant.zig`, `vtCreateTopic`'s comment). Once a
//! reliable reader is ready (proving cross-process match happened), calls
//! `DataWriter.get_matched_subscriptions`/`get_matched_subscription_data` to
//! look up the matched subscriber's own topic/type name. Then runs the same
//! minimal reliable write loop (3 samples) as hello_world/participant-config,
//! to prove the participant/writer still work normally.
//!
//! `topic_data`/`subscription_data`'s string fields are *borrowed* slices
//! owned by zzdds internally (valid for the entity's lifetime) -- unlike
//! participant-config's `DomainParticipantConfig` round-trip, nothing here
//! is caller-owned, so nothing is `.deinit()`'d.
//!
//! Required stdout markers: "Create topic:", "Create writer for topic:",
//! "Discovery OK (participant):", "on_reliable_reader_ready",
//! "Discovery OK (writer):", "Publisher: wrote count=", "Publisher: done."
//! Any failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const ping_gen = @import("discovery_ping_gen");

const SAMPLE_COUNT: i32 = 3;
const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

const TOPIC_NAME = "DiscoveryPing";
const TYPE_NAME = "DiscoveryPing";

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const State = struct {
    reader_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    ever_matched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onReliableReaderReady(state: *State, reader_handle: DDS.InstanceHandle_t, is_ready: bool) void {
    _ = reader_handle;
    if (is_ready) state.reader_ready.store(true, .release);
    std.debug.print("on_reliable_reader_ready() is_ready={}\n", .{is_ready});
}

fn onPublicationMatched(state: *State, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
    if (status.current_count > 0) state.ever_matched.store(true, .release);
    std.debug.print("on_publication_matched() current_count={d}\n", .{status.current_count});
}

const Options = struct {
    domain_id: u32 = 0,
};

fn parseArgs(process_args: std.process.Args) Options {
    var opts = Options{};
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            const v = it.next() orelse continue;
            opts.domain_id = std.fmt.parseInt(u32, v, 10) catch 0;
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const opts = parseArgs(init.minimal.args);

    var factory = zzdds.createFactory() catch {
        std.debug.print("FAIL: createFactory() failed\n", .{});
        std.process.exit(1);
    };
    defer factory.deinit();

    const dpf = factory.toDDSFactory();
    const dp = dpf.create_participant(opts.domain_id, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_participant() failed on domain {d}\n", .{opts.domain_id});
        std.process.exit(1);
    }
    defer _ = dpf.delete_participant(dp);

    var ts_alloc = alloc;
    if (!zzdds.registerTypeSupport(dp, TOPIC_NAME, .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = ping_gen.DiscoveryPing.computeKeyHashFromCdr,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic(TOPIC_NAME, TYPE_NAME, .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: {s}\n", .{TOPIC_NAME});

    // Participant-level discovery: a freshly-created local topic is
    // immediately visible, no cross-process wait needed.
    {
        var handles: DDS.InstanceHandleSeq = .{};
        if (dp.get_discovered_topics(&handles) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: get_discovered_topics() failed\n", .{});
            std.process.exit(1);
        }
        var found = false;
        var topic_data: DDS.TopicBuiltinTopicData = .{};
        for (handles._buffer.?[0..handles._length]) |h| {
            if (dp.get_discovered_topic_data(&topic_data, h) != DDS.RETCODE_OK) continue;
            if (std.mem.eql(u8, topic_data.name, TOPIC_NAME)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("FAIL: get_discovered_topic_data() never returned '{s}'\n", .{TOPIC_NAME});
            std.process.exit(1);
        }
        if (!std.mem.eql(u8, topic_data.type_name, TYPE_NAME)) {
            std.debug.print("FAIL: discovered topic type_name mismatch: expected '{s}', got '{s}'\n", .{ TYPE_NAME, topic_data.type_name });
            std.process.exit(1);
        }
        std.debug.print("Discovery OK (participant): topic.name='{s}' topic.type_name='{s}'\n", .{ topic_data.name, topic_data.type_name });
    }

    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
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
    std.debug.print("Create writer for topic: {s}\n", .{TOPIC_NAME});

    var state = State{};
    const zdw = zzdds.asZzddsDataWriter(dw) orelse {
        std.debug.print("FAIL: asZzddsDataWriter() failed\n", .{});
        std.process.exit(1);
    };
    if (zdw.set_listener_ex(ZZDDS.dataWriterListenerEx(&state, .{
        .on_publication_matched = onPublicationMatched,
        .on_reliable_reader_ready = onReliableReaderReady,
    }), DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener_ex failed\n", .{});
        std.process.exit(1);
    }

    const writer = ping_gen.DiscoveryPingDataWriter.init(dw, alloc);

    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!state.reader_ready.load(.acquire)) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    // Writer-level discovery: the remote subscriber has definitely matched
    // by now (on_reliable_reader_ready only fires once it has).
    {
        var handles: DDS.InstanceHandleSeq = .{};
        if (dw.get_matched_subscriptions(&handles) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: get_matched_subscriptions() failed\n", .{});
            std.process.exit(1);
        }
        if (handles._length == 0) {
            std.debug.print("FAIL: get_matched_subscriptions() returned no matches\n", .{});
            std.process.exit(1);
        }
        var sub_data: DDS.SubscriptionBuiltinTopicData = .{};
        if (dw.get_matched_subscription_data(&sub_data, handles._buffer.?[0]) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: get_matched_subscription_data() failed\n", .{});
            std.process.exit(1);
        }
        if (!std.mem.eql(u8, sub_data.topic_name, TOPIC_NAME) or !std.mem.eql(u8, sub_data.type_name, TYPE_NAME)) {
            std.debug.print("FAIL: matched subscription topic_name/type_name mismatch: got '{s}'/'{s}'\n", .{ sub_data.topic_name, sub_data.type_name });
            std.process.exit(1);
        }
        std.debug.print("Discovery OK (writer): matched_subscription.topic_name='{s}' type_name='{s}'\n", .{ sub_data.topic_name, sub_data.type_name });
    }

    var i: i32 = 0;
    while (i < SAMPLE_COUNT) : (i += 1) {
        writer.write(.{ .count = i }, 0) catch {
            std.debug.print("FAIL: write() failed at count={d}\n", .{i});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote count={d}\n", .{i});
    }

    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (!(state.ever_matched.load(.acquire) and state.matched_current_count.load(.acquire) == 0)) {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Publisher: done.\n", .{});
}
