//! zig/sample-rejected-lost -- publisher.
//!
//! Three DataWriters under one Publisher, written in this specific order:
//! LostTopic (RELIABLE, KEEP_LAST depth=1, TRANSIENT_LOCAL) gets 5
//! back-to-back writes FIRST, before any reader can possibly be matched to
//! it -- the subscriber deliberately defers creating that reader until
//! after the Sync signal below, so these writes are written and evicted
//! with zero chance of ever being acked (a genuinely, deterministically
//! un-recoverable loss for SNs 1-4, not a race against real-time ack
//! latency -- an earlier version of this scenario tried racing fast writes
//! against an already-matched reader and nothing was ever lost, because
//! localhost round-trips are fast enough that each sample got acked before
//! the next write evicted it). Then RejectedTopic (RELIABLE, KEEP_ALL, no
//! resource limits of its own -- the *reader's* tight resource_limits is
//! what causes rejection) gets 5 back-to-back writes against an
//! already-matched reader. SyncTopic gets one write *after* everything
//! above is done, purely so the subscriber knows it's safe to create the
//! LostTopic reader and check final status without racing the publisher's
//! own writes. See docs/design/integration-test-tier.md for the full
//! scenario spec.
//!
//! Required stdout markers: "Create topic:" x3, "Create writer for topic:"
//! x3, "Publisher: wrote 5 samples on LostTopic...", "Publisher: wrote 5
//! samples on RejectedTopic...", "Publisher: sync sent.", "Publisher: done."
//! Any failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const status_event_gen = @import("status_event_gen");

const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const WriterSyncState = struct {
    reader_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    ever_matched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onReliableReaderReady(state: *WriterSyncState, reader_handle: DDS.InstanceHandle_t, is_ready: bool) void {
    _ = reader_handle;
    if (is_ready) state.reader_ready.store(true, .release);
}

fn onPublicationMatched(state: *WriterSyncState, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
    if (status.current_count > 0) state.ever_matched.store(true, .release);
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

fn setWriterListener(dw: DDS.DataWriter, state: *WriterSyncState) !void {
    const zdw = zzdds.asZzddsDataWriter(dw) orelse return error.AsZzddsDataWriterFailed;
    if (zdw.set_listener_ex(ZZDDS.dataWriterListenerEx(state, .{
        .on_publication_matched = onPublicationMatched,
        .on_reliable_reader_ready = onReliableReaderReady,
    }), DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) return error.SetListenerExFailed;
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
    var topic_descs: [3]DDS.Topic = undefined;
    for (topics, 0..) |name, i| {
        const t = dp.create_topic(name, "StatusEvent", .{}, null, 0);
        if (t.ptr == zzdds.dcps.NIL_PTR) {
            std.debug.print("FAIL: create_topic({s}) failed\n", .{name});
            std.process.exit(1);
        }
        std.debug.print("Create topic: {s}\n", .{name});
        topic_descs[i] = t;
    }

    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    // LostTopic FIRST, deliberately before any reader can possibly be
    // matched: the subscriber defers creating its LostTopic reader until
    // after the Sync signal below, specifically so these 5 writes (KEEP_LAST
    // depth=1) are written and evicted with zero chance of ever being acked
    // -- a genuinely, deterministically un-recoverable loss, not a race
    // against real-time ack latency (which turned out on localhost to
    // always win: an empirical first attempt at this scenario wrote+evicted
    // fast against an ALREADY-matched reader and nothing was ever lost,
    // because each sample got acked before the next write evicted it -- see
    // docs/design/integration-test-tier.md's scenario notes).
    var lost_qos = DDS.DataWriterQos{};
    lost_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    lost_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    lost_qos.history.depth = 1;
    // TRANSIENT_LOCAL so the late-joining reader can still receive whatever
    // remains in the writer's cache (the seq=4 sample) -- VOLATILE (the
    // default) would make it miss ALL 5 samples, not just the 4 evicted
    // ones, since VOLATILE's contract is "matched before write time or
    // nothing," independent of what the writer still happens to have
    // cached. Eviction (and therefore loss of seq 0-3) still happens
    // regardless of durability -- TRANSIENT_LOCAL only governs whether a
    // late joiner can reach what's currently cached, not whether KEEP_LAST
    // still evicts.
    lost_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const lost_dw = publisher.create_datawriter(topic_descs[1], lost_qos, null, 0);
    if (lost_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(LostTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: LostTopic\n", .{});

    {
        const lost_writer = status_event_gen.StatusEventDataWriter.init(lost_dw, alloc);
        var seq: i32 = 0;
        while (seq < 5) : (seq += 1) {
            lost_writer.write(.{ .seq = seq }, 0) catch {
                std.debug.print("FAIL: LostTopic write() failed at seq={d}\n", .{seq});
                std.process.exit(1);
            };
        }
    }
    std.debug.print("Publisher: wrote 5 samples on LostTopic (KEEP_LAST depth=1, no reader matched yet).\n", .{});

    var rejected_qos = DDS.DataWriterQos{};
    rejected_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    rejected_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const rejected_dw = publisher.create_datawriter(topic_descs[0], rejected_qos, null, 0);
    if (rejected_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(RejectedTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: RejectedTopic\n", .{});

    var sync_qos = DDS.DataWriterQos{};
    sync_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const sync_dw = publisher.create_datawriter(topic_descs[2], sync_qos, null, 0);
    if (sync_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(SyncTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: SyncTopic\n", .{});

    var rejected_state = WriterSyncState{};
    var sync_state = WriterSyncState{};
    var lost_state = WriterSyncState{};
    setWriterListener(rejected_dw, &rejected_state) catch {
        std.debug.print("FAIL: set_listener_ex(RejectedTopic) failed\n", .{});
        std.process.exit(1);
    };
    setWriterListener(sync_dw, &sync_state) catch {
        std.debug.print("FAIL: set_listener_ex(SyncTopic) failed\n", .{});
        std.process.exit(1);
    };
    // Only used for the final drain-wait below -- LostTopic's reader isn't
    // created until well after this writer already exists, so there's
    // nothing to gate the first write on here.
    setWriterListener(lost_dw, &lost_state) catch {
        std.debug.print("FAIL: set_listener_ex(LostTopic) failed\n", .{});
        std.process.exit(1);
    };

    // Only Rejected/Sync need to wait for their reader -- the subscriber
    // creates those two immediately at startup. LostTopic's reader isn't
    // created until the subscriber gets the Sync sample below, by design.
    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!(rejected_state.reader_ready.load(.acquire) and sync_state.reader_ready.load(.acquire))) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    const rejected_writer = status_event_gen.StatusEventDataWriter.init(rejected_dw, alloc);
    const sync_writer = status_event_gen.StatusEventDataWriter.init(sync_dw, alloc);

    // The subscriber deliberately does not drain RejectedTopic until it has
    // confirmed rejection happened, so no reader-side consumption race is
    // possible here regardless of exact write timing.
    var seq: i32 = 0;
    while (seq < 5) : (seq += 1) {
        rejected_writer.write(.{ .seq = seq }, 0) catch {
            std.debug.print("FAIL: RejectedTopic write() failed at seq={d}\n", .{seq});
            std.process.exit(1);
        };
    }
    std.debug.print("Publisher: wrote 5 samples on RejectedTopic (up to 2 expected rejected).\n", .{});

    sync_writer.write(.{ .seq = 0 }, 0) catch {
        std.debug.print("FAIL: SyncTopic write() failed\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Publisher: sync sent.\n", .{});
    std.debug.print("Publisher: done.\n", .{});

    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (!(rejected_state.ever_matched.load(.acquire) and rejected_state.matched_current_count.load(.acquire) == 0 and
        lost_state.ever_matched.load(.acquire) and lost_state.matched_current_count.load(.acquire) == 0 and
        sync_state.ever_matched.load(.acquire) and sync_state.matched_current_count.load(.acquire) == 0))
    {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    if (publisher.delete_datawriter(rejected_dw) != DDS.RETCODE_OK or
        publisher.delete_datawriter(lost_dw) != DDS.RETCODE_OK or
        publisher.delete_datawriter(sync_dw) != DDS.RETCODE_OK)
    {
        std.debug.print("FAIL: delete_datawriter() did not return RETCODE_OK\n", .{});
        std.process.exit(1);
    }
}
