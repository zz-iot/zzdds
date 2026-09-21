//! zig/sample-rejected-lost -- subscriber.
//!
//! Three DataReaders: RejectedTopic (RELIABLE, KEEP_ALL, tight
//! resource_limits = {max_samples: 3, max_instances: 1,
//! max_samples_per_instance: 3}), created immediately at startup and
//! deliberately never drained until AFTER confirming rejection happened, so
//! the publisher's 5 back-to-back writes overflow it; SyncTopic, also
//! created immediately, polled first and used purely as a "publisher is
//! done writing" gate; LostTopic (RELIABLE, KEEP_LAST depth=1,
//! TRANSIENT_LOCAL), whose reader is deliberately created only AFTER the
//! Sync signal -- by construction the publisher already wrote+evicted its 5
//! LostTopic samples before this reader could possibly match, making the
//! loss a genuine, deterministic late-join gap rather than a real-time
//! race; TRANSIENT_LOCAL lets the still-cached last sample (seq=4) reach
//! this late-joining reader while the 4 evicted ones remain genuinely lost.
//! See docs/design/integration-test-tier.md for the full scenario spec.
//!
//! Required stdout markers: "Create topic:" x3, "Create reader for topic:"
//! x3, "Subscriber: sample_rejected confirmed (count=N, buffered=M).",
//! "Subscriber: sample_lost confirmed (count=N, last seq=N).", "Subscriber:
//! SAMPLE_REJECTED/SAMPLE_LOST both verified." Any failure path prints a
//! line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const status_event_gen = @import("status_event_gen");

const SYNC_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const STATUS_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
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
    if (!zzdds.registerTypeSupport(dp, "StatusEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = status_event_gen.StatusEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = status_event_gen.StatusEvent.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport(StatusEvent) failed\n", .{});
        std.process.exit(1);
    }

    const topics = [_][:0]const u8{ "RejectedTopic", "LostTopic", "SyncTopic" };
    var topic_descs: [3]DDS.TopicDescription = undefined;
    for (topics, 0..) |name, i| {
        const t = dp.create_topic(name, "StatusEvent", .{}, null, 0);
        if (t.ptr == zzdds.dcps.NIL_PTR) {
            std.debug.print("FAIL: create_topic({s}) failed\n", .{name});
            std.process.exit(1);
        }
        std.debug.print("Create topic: {s}\n", .{name});
        topic_descs[i] = dp.lookup_topicdescription(name);
    }

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var rejected_qos = DDS.DataReaderQos{};
    rejected_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    rejected_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    rejected_qos.resource_limits = .{ .max_samples = 3, .max_instances = 1, .max_samples_per_instance = 3 };
    const rejected_dr = subscriber.create_datareader(topic_descs[0], rejected_qos, null, 0);
    if (rejected_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(RejectedTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: RejectedTopic\n", .{});

    var sync_qos = DDS.DataReaderQos{};
    sync_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const sync_dr = subscriber.create_datareader(topic_descs[2], sync_qos, null, 0);
    if (sync_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(SyncTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: SyncTopic\n", .{});

    const sync_reader = status_event_gen.StatusEventDataReader.init(sync_dr, alloc);
    const rejected_reader = status_event_gen.StatusEventDataReader.init(rejected_dr, alloc);

    // Gate: don't create the LostTopic reader, or check RejectedTopic's
    // final status, until the publisher has genuinely finished writing
    // everything (it writes Sync last). LostTopic's reader is deliberately
    // created only from here on -- by construction, the publisher already
    // wrote+evicted its 5 LostTopic samples (see publisher.zig) before this
    // reader ever existed to match, so the loss below is a real, guaranteed
    // one, not a race against real-time ack latency.
    {
        const deadline = monoNs(io) + SYNC_TIMEOUT_NS;
        var got_sync = false;
        while (!got_sync) {
            if (monoNs(io) > deadline) {
                std.debug.print("FAIL: sync sample never arrived within 20s\n", .{});
                std.process.exit(1);
            }
            var taken: std.ArrayListUnmanaged(status_event_gen.StatusEventDataReader.SampledValue) = .empty;
            defer taken.deinit(alloc);
            _ = try sync_reader.take(&taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
            if (taken.items.len > 0) got_sync = true else sleepNs(io, POLL_PERIOD_NS);
        }
    }

    var lost_qos = DDS.DataReaderQos{};
    lost_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    lost_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    lost_qos.history.depth = 1;
    lost_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const lost_dr = subscriber.create_datareader(topic_descs[1], lost_qos, null, 0);
    if (lost_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(LostTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: LostTopic\n", .{});
    const lost_reader = status_event_gen.StatusEventDataReader.init(lost_dr, alloc);

    // RejectedTopic: deliberately never drained until now. Confirm rejection
    // happened, then take whatever made it through.
    var rejected_status: DDS.SampleRejectedStatus = undefined;
    {
        const deadline = monoNs(io) + STATUS_TIMEOUT_NS;
        while (true) {
            if (rejected_dr.get_sample_rejected_status(&rejected_status) != DDS.RETCODE_OK) {
                std.debug.print("FAIL: get_sample_rejected_status() failed\n", .{});
                std.process.exit(1);
            }
            if (rejected_status.total_count > 0) break;
            if (monoNs(io) > deadline) {
                std.debug.print("FAIL: no sample ever rejected on RejectedTopic within 20s\n", .{});
                std.process.exit(1);
            }
            sleepNs(io, POLL_PERIOD_NS);
        }
    }
    var rejected_taken: std.ArrayListUnmanaged(status_event_gen.StatusEventDataReader.SampledValue) = .empty;
    defer rejected_taken.deinit(alloc);
    _ = try rejected_reader.take(&rejected_taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    // Count-conservation invariant, not a hardcoded exact split: every
    // written sample is either rejected or successfully buffered -- more
    // robust than pinning to one specific implementation-internal number
    // (see docs/decisions.md's dds-rtps CoherentSets flake history for why
    // this project avoids asserting exact counts where a property suffices).
    const rejected_total: i32 = rejected_status.total_count + @as(i32, @intCast(rejected_taken.items.len));
    if (rejected_total != 5) {
        std.debug.print("FAIL: RejectedTopic count mismatch -- rejected={d} buffered={d} total={d}, expected 5\n", .{ rejected_status.total_count, rejected_taken.items.len, rejected_total });
        std.process.exit(1);
    }
    if (rejected_taken.items.len == 0) {
        std.debug.print("FAIL: RejectedTopic: nothing was ever successfully buffered (rejected everything)\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: sample_rejected confirmed (count={d}, buffered={d}).\n", .{ rejected_status.total_count, rejected_taken.items.len });

    // LostTopic: confirm loss happened, then take whatever remains and
    // confirm the writer's LAST value survived -- proving data that *does*
    // make it through is still delivered correctly, not just that loss was
    // reported.
    var lost_status: DDS.SampleLostStatus = undefined;
    {
        const deadline = monoNs(io) + STATUS_TIMEOUT_NS;
        while (true) {
            if (lost_dr.get_sample_lost_status(&lost_status) != DDS.RETCODE_OK) {
                std.debug.print("FAIL: get_sample_lost_status() failed\n", .{});
                std.process.exit(1);
            }
            if (lost_status.total_count > 0) break;
            if (monoNs(io) > deadline) {
                std.debug.print("FAIL: no sample ever lost on LostTopic within 20s\n", .{});
                std.process.exit(1);
            }
            sleepNs(io, POLL_PERIOD_NS);
        }
    }
    var lost_taken: std.ArrayListUnmanaged(status_event_gen.StatusEventDataReader.SampledValue) = .empty;
    defer lost_taken.deinit(alloc);
    _ = try lost_reader.take(&lost_taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    var max_seq: i32 = -1;
    for (lost_taken.items) |sv| {
        if (sv.value.seq > max_seq) max_seq = sv.value.seq;
    }
    if (max_seq != 4) {
        std.debug.print("FAIL: LostTopic did not deliver the writer's last sample (seq=4) -- last seen={d}\n", .{max_seq});
        std.process.exit(1);
    }
    std.debug.print("Subscriber: sample_lost confirmed (count={d}, last seq={d}).\n", .{ lost_status.total_count, max_seq });

    std.debug.print("Subscriber: SAMPLE_REJECTED/SAMPLE_LOST both verified.\n", .{});

    _ = subscriber.delete_datareader(rejected_dr);
    _ = subscriber.delete_datareader(lost_dr);
    _ = subscriber.delete_datareader(sync_dr);
}
