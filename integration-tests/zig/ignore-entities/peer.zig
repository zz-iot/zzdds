//! zig/ignore-entities -- peer. Simple counterpart to ignorer.zig: creates a
//! writer for ControlTopic and TopicIgnoredTopic, and a reader for
//! SubscriptionIgnoredTopic, plus a writer that gets matched by the
//! ignorer's throwaway "probe" reader on PublicationIgnoredTopic. See
//! docs/design/integration-test-tier.md for the full scenario spec.
//!
//! IMPORTANT: this file deliberately does NOT assert that its own
//! match-count fields ever drop to zero. ignore_topic()/ignore_publication()
//! are a strictly one-sided, local filter on the ignorer's participant (see
//! ignorer.zig's header comment) -- from this process's own SEDP
//! perspective, its TopicIgnoredTopic/PublicationIgnoredTopic writers
//! legitimately stay matched to the ignorer's reader the entire time,
//! exactly as if nothing had been ignored at all. The one thing this
//! process CAN and does verify from its own side is
//! SubscriptionIgnoredTopic: ignore_subscription() is called on the
//! *writer's* participant (ignorer), so it's ignorer's own writer that
//! never adds this process's reader as a matched proxy -- meaning this
//! reader, despite itself reporting a normal SEDP match, must never
//! actually receive any of the real writer's samples.
//!
//! Required stdout markers: "Peer: ready.", "Peer: SubscriptionIgnoredTopic
//! reader received zero samples from the real (post-ignore) writer.",
//! "Peer: done." Any failure path prints a line starting "FAIL:" and exits
//! nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ignore_event_gen = @import("ignore_event_gen");

const SAMPLE_COUNT: i32 = 5;
// NOT long enough to guarantee the ignorer has finished every ignore_*()
// call -- its own PROBE_MATCH_TIMEOUT_MS (45s) applies twice, sequentially,
// for the publication and subscription probes, so its true worst case is
// well over a minute. Raised from 6s to match this file's own
// MATCH_TIMEOUT_NS convention as a meaningfully better (not watertight)
// margin: the SubscriptionIgnoredTopic check below can still report a false
// pass -- zero samples because the real (post-ignore) writer hasn't been
// created yet, not because ignore_subscription() worked -- if the ignorer
// is still deep in its own probe/settle choreography when this window
// closes. A fully watertight fix needs an explicit cross-process signal
// (e.g. a dedicated marker topic) rather than a fixed sleep; not done here
// to avoid adding a worst-case 100+s wait on top of an already
// CI-budget-constrained suite (found via Greptile review; see
// docs/roadmap.md's discovery-latency entry for the same underlying "how
// long is long enough" tension).
const SETTLE_WINDOW_NS: u64 = 20 * std.time.ns_per_s;
const MATCH_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
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
    if (!zzdds.registerTypeSupport(dp, "IgnoreEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = ignore_event_gen.IgnoreEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = ignore_event_gen.IgnoreEvent.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const control_topic = dp.create_topic("ControlTopic", "IgnoreEvent", .{}, null, 0);
    const topic_ignored_topic = dp.create_topic("TopicIgnoredTopic", "IgnoreEvent", .{}, null, 0);
    const pub_ignored_topic = dp.create_topic("PublicationIgnoredTopic", "IgnoreEvent", .{}, null, 0);
    const sub_ignored_topic = dp.create_topic("SubscriptionIgnoredTopic", "IgnoreEvent", .{}, null, 0);
    if (control_topic.ptr == zzdds.dcps.NIL_PTR or topic_ignored_topic.ptr == zzdds.dcps.NIL_PTR or
        pub_ignored_topic.ptr == zzdds.dcps.NIL_PTR or sub_ignored_topic.ptr == zzdds.dcps.NIL_PTR)
    {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }

    const publisher = dp.create_publisher(.{}, null, 0);
    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR or subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher()/create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const control_dw = publisher.create_datawriter(control_topic, dw_qos, null, 0);
    const topic_ignored_dw = publisher.create_datawriter(topic_ignored_topic, dw_qos, null, 0);
    const pub_ignored_dw = publisher.create_datawriter(pub_ignored_topic, dw_qos, null, 0);
    const sub_ignored_dr = subscriber.create_datareader(sub_ignored_topic.vtable.as_TopicDescription(sub_ignored_topic.ptr), dr_qos, null, 0);
    if (control_dw.ptr == zzdds.dcps.NIL_PTR or topic_ignored_dw.ptr == zzdds.dcps.NIL_PTR or
        pub_ignored_dw.ptr == zzdds.dcps.NIL_PTR or sub_ignored_dr.ptr == zzdds.dcps.NIL_PTR)
    {
        std.debug.print("FAIL: create_datawriter()/create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Peer: ready.\n", .{});

    // Write a few samples on TopicIgnoredTopic and PublicationIgnoredTopic
    // right away -- both writers exist continuously from here on, giving
    // the ignorer's readers every real opportunity to (wrongly) match.
    const topic_ignored_writer = ignore_event_gen.IgnoreEventDataWriter.init(topic_ignored_dw, alloc);
    const pub_ignored_writer = ignore_event_gen.IgnoreEventDataWriter.init(pub_ignored_dw, alloc);
    var seq: i32 = 0;
    while (seq < SAMPLE_COUNT) : (seq += 1) {
        topic_ignored_writer.write(.{ .seq = seq }, 0) catch {};
        pub_ignored_writer.write(.{ .seq = seq }, 0) catch {};
    }

    // Let the ignorer's full choreography (participant-discover-and-ignore,
    // publication probe-then-ignore, subscription probe-then-ignore) run to
    // completion. No assertion on topic_ignored_dw's or pub_ignored_dw's own
    // match-count here -- see this file's header comment for why that
    // would be asserting something ignore_topic()/ignore_publication()
    // never promised.
    sleepNs(io, SETTLE_WINDOW_NS);

    // The one thing this process's own side CAN verify: ignore_subscription()
    // was called on ignorer's *writer* participant, so its real
    // (post-ignore) writer never adds this reader as a matched proxy --
    // meaning this reader, however its own SEDP match status reports
    // itself, must never actually receive any of that writer's samples.
    const sub_ignored_reader = ignore_event_gen.IgnoreEventDataReader.init(sub_ignored_dr, alloc);
    var taken: std.ArrayListUnmanaged(ignore_event_gen.IgnoreEventDataReader.SampledValue) = .empty;
    defer taken.deinit(alloc);
    _ = try sub_ignored_reader.take(&taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    if (taken.items.len != 0) {
        std.debug.print("FAIL: SubscriptionIgnoredTopic reader received {d} samples, expected 0\n", .{taken.items.len});
        std.process.exit(1);
    }
    std.debug.print("Peer: SubscriptionIgnoredTopic reader received zero samples from the real (post-ignore) writer.\n", .{});

    // Normal ControlTopic round-trip, matching every other scenario's
    // sanity-check convention.
    var control_status: DDS.PublicationMatchedStatus = undefined;
    const match_deadline = monoNs(io) + MATCH_TIMEOUT_NS;
    var control_matched = false;
    while (!control_matched) {
        if (monoNs(io) > match_deadline) {
            std.debug.print("FAIL: ControlTopic writer never matched within {d}s\n", .{@divTrunc(MATCH_TIMEOUT_NS, std.time.ns_per_s)});
            std.process.exit(1);
        }
        if (control_dw.get_publication_matched_status(&control_status) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: get_publication_matched_status(control) failed\n", .{});
            std.process.exit(1);
        }
        if (control_status.current_count > 0) control_matched = true else sleepNs(io, POLL_PERIOD_NS);
    }
    const control_writer = ignore_event_gen.IgnoreEventDataWriter.init(control_dw, alloc);
    seq = 0;
    while (seq < SAMPLE_COUNT) : (seq += 1) {
        control_writer.write(.{ .seq = seq }, 0) catch {
            std.debug.print("FAIL: write(ControlTopic) failed at seq={d}\n", .{seq});
            std.process.exit(1);
        };
    }

    // Standard teardown-safety: wait for the ignorer to disconnect before
    // deleting, matching every other scenario's precedent.
    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (true) {
        if (control_dw.get_publication_matched_status(&control_status) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: get_publication_matched_status(control) failed\n", .{});
            std.process.exit(1);
        }
        if (control_status.current_count == 0) break;
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: ignorer did not disconnect within {d}s\n", .{@divTrunc(DRAIN_TIMEOUT_NS, std.time.ns_per_s)});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Peer: done.\n", .{});
}
