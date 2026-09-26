//! zig/ignore-entities -- ignorer. The entity under test: exercises all four
//! DomainParticipant ignore_*() operations and proves each one's specific
//! discovery-gating scope. See docs/design/integration-test-tier.md for the
//! full scenario spec.
//!
//! IMPORTANT, and the reason this scenario's assertions live entirely on
//! THIS side of the wire: ignore_topic()/ignore_publication()/
//! ignore_subscription() are a strictly one-sided, LOCAL filter (DDS spec
//! wording: "locally ignore"). They change only what THIS participant's own
//! onWriterDiscovered/onReaderDiscovered decide counts as a match --
//! `peer`'s own writers/readers have no idea they've been ignored and
//! legitimately keep reporting themselves matched from their own side (see
//! peer.zig, which deliberately does NOT assert its own match-count drops
//! to zero, only that it never observes any *data* flow to/from the ignored
//! entity). What these three operations guarantee, and all that this file
//! checks, is that data never actually reaches (or, for
//! ignore_subscription(), leaves) THIS participant's own reader/writer.
//! ignore_participant() is no exception to the one-sidedness either, despite
//! tearing down more (the underlying SEDP proxy exchange with that prefix,
//! not just this participant's own DCPS-level match bookkeeping):
//! bystander.zig has no idea it's been ignored and legitimately observes
//! itself matched from its own side too, exactly like the other three --
//! see bystander.zig's own header comment.
//!
//! - ignore_topic(): resolved from this participant's OWN local topic
//!   instance handle -- no discovery needed -- called before `peer`'s
//!   writer for that topic can possibly exist, so the block is
//!   unconditional from the very first SEDP announcement onward.
//! - ignore_participant(): `bystander` deliberately delays creating its
//!   writer, giving this process a wide, comfortable window to discover
//!   (via get_discovered_participants()) and ignore its participant handle
//!   before that writer's SEDP announcement can ever reach us. Critically,
//!   the harness does not start `peer` until this step has completed and
//!   printed "ignore_participant() applied to bystander." --
//!   get_discovered_participants() makes no ordering promise across
//!   multiple simultaneously-discovered participants, so if `peer` were
//!   already running, handles[0] could just as easily be *peer's* handle,
//!   silently ignoring the wrong participant for the rest of the run
//!   (found the hard way: an earlier version of this harness started
//!   `peer` and `bystander` together, and intermittently ignored `peer`
//!   instead -- see docs/roadmap.md).
//! - ignore_publication()/ignore_subscription(): these target a SPECIFIC
//!   remote entity's handle, which can only be learned by discovering it
//!   first -- so each uses a throwaway "probe" reader/writer purely to
//!   learn `peer`'s counterpart handle via get_matched_publications()/
//!   get_matched_subscriptions(), ignores it, deletes the probe, then
//!   creates the real entity under test and confirms it never matches (and,
//!   for ignore_publication(), never receives any of peer's continuously-
//!   written samples).
//!
//! Required stdout markers: "Ignorer: ready for bystander.", "Ignorer:
//! ignore_participant() applied to bystander.", "Ignorer:
//! ignore_publication() applied via probe.", "Ignorer:
//! ignore_subscription() applied via probe.", "Ignorer: all ignore checks
//! passed.", "Ignorer: done." Any failure path prints a line starting
//! "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ignore_event_gen = @import("ignore_event_gen");

const SAMPLE_COUNT: i32 = 5;
const DISCOVER_BYSTANDER_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
// 45s, not the 20s every other match-wait in this tier uses -- this
// scenario's probe-match steps showed intermittent delays under this
// suite's own CI/dev sandbox load that 20s didn't reliably clear; see
// docs/roadmap.md.
const PROBE_MATCH_TIMEOUT_NS: i64 = 45 * std.time.ns_per_s;
const SETTLE_WINDOW_NS: u64 = 3 * std.time.ns_per_s;
const MATCH_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const RECEIVE_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// zzdds.createFactory() (unlike createFactoryWithAllocator()) routes every
// internal allocation -- including a filled-in DDS.InstanceHandleSeq's
// _buffer -- through std.heap.c_allocator, not whatever allocator this app
// happens to be using locally (see factory.zig's createFactoryWithAllocator
// doc comment). Freeing with the wrong allocator here corrupted the
// DebugAllocator's heap and crashed on the very first call -- must free
// with c_allocator to match, regardless of what `alloc` is passed elsewhere
// in this file.
fn freeHandles(handles: *DDS.InstanceHandleSeq) void {
    if (handles._release) {
        if (handles._buffer) |b| std.heap.c_allocator.free(b[0..handles._length]);
    }
    handles.* = .{};
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
    const participant_ignored_topic = dp.create_topic("ParticipantIgnoredTopic", "IgnoreEvent", .{}, null, 0);
    if (control_topic.ptr == zzdds.dcps.NIL_PTR or topic_ignored_topic.ptr == zzdds.dcps.NIL_PTR or
        pub_ignored_topic.ptr == zzdds.dcps.NIL_PTR or sub_ignored_topic.ptr == zzdds.dcps.NIL_PTR or
        participant_ignored_topic.ptr == zzdds.dcps.NIL_PTR)
    {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }

    // ── ignore_topic(): local knowledge only, no peer needed yet. ──────────
    const topic_ignored_handle = topic_ignored_topic.vtable.get_instance_handle(topic_ignored_topic.ptr);
    const topic_ignore_rc = dp.ignore_topic(topic_ignored_handle);
    if (topic_ignore_rc != DDS.RETCODE_OK) {
        std.debug.print("FAIL: ignore_topic() returned {d}\n", .{topic_ignore_rc});
        std.process.exit(1);
    }
    std.debug.print("Ignorer: ignore_topic() applied to TopicIgnoredTopic.\n", .{});

    const subscriber = dp.create_subscriber(.{}, null, 0);
    const publisher = dp.create_publisher(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR or publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber()/create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    // Reader created immediately after ignoring -- the writer it must never
    // match (peer's) doesn't exist yet at this point.
    const topic_ignored_dr = subscriber.create_datareader(topic_ignored_topic.vtable.as_TopicDescription(topic_ignored_topic.ptr), dr_qos, null, 0);
    // Harmless to create now, before ignore_participant() below -- the
    // participant-level guard blocks at first discovery regardless of when
    // this reader was created (see this file's header comment).
    const participant_ignored_dr = subscriber.create_datareader(participant_ignored_topic.vtable.as_TopicDescription(participant_ignored_topic.ptr), dr_qos, null, 0);
    const control_dr = subscriber.create_datareader(control_topic.vtable.as_TopicDescription(control_topic.ptr), dr_qos, null, 0);
    if (topic_ignored_dr.ptr == zzdds.dcps.NIL_PTR or participant_ignored_dr.ptr == zzdds.dcps.NIL_PTR or control_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }

    std.debug.print("Ignorer: ready for bystander.\n", .{});

    // ── ignore_participant(): discover bystander's participant, ignore it
    // well within its own deliberate pre-writer delay. ─────────────────────
    var found_bystander = false;
    const bystander_deadline = monoNs(io) + DISCOVER_BYSTANDER_TIMEOUT_NS;
    while (!found_bystander) {
        if (monoNs(io) > bystander_deadline) {
            std.debug.print("FAIL: bystander's participant never appeared within {d}s\n", .{@divTrunc(DISCOVER_BYSTANDER_TIMEOUT_NS, std.time.ns_per_s)});
            std.process.exit(1);
        }
        var handles = DDS.InstanceHandleSeq{};
        defer freeHandles(&handles);
        _ = dp.get_discovered_participants(&handles);
        if (handles._length > 0) {
            const rc = dp.ignore_participant(handles._buffer.?[0]);
            if (rc != DDS.RETCODE_OK) {
                std.debug.print("FAIL: ignore_participant() returned {d}\n", .{rc});
                std.process.exit(1);
            }
            found_bystander = true;
        } else {
            sleepNs(io, POLL_PERIOD_NS);
        }
    }
    std.debug.print("Ignorer: ignore_participant() applied to bystander.\n", .{});

    // ── ignore_publication(): probe, learn peer's writer handle, ignore,
    // then prove a freshly-created reader never matches it. ────────────────
    {
        const probe_dr = subscriber.create_datareader(pub_ignored_topic.vtable.as_TopicDescription(pub_ignored_topic.ptr), dr_qos, null, 0);
        if (probe_dr.ptr == zzdds.dcps.NIL_PTR) {
            std.debug.print("FAIL: create_datareader(probe, PublicationIgnoredTopic) failed\n", .{});
            std.process.exit(1);
        }
        var status: DDS.SubscriptionMatchedStatus = undefined;
        const deadline = monoNs(io) + PROBE_MATCH_TIMEOUT_NS;
        var matched = false;
        while (!matched) {
            if (monoNs(io) > deadline) {
                std.debug.print("FAIL: probe reader never matched peer's PublicationIgnoredTopic writer within {d}s\n", .{@divTrunc(PROBE_MATCH_TIMEOUT_NS, std.time.ns_per_s)});
                std.process.exit(1);
            }
            if (probe_dr.get_subscription_matched_status(&status) != DDS.RETCODE_OK) {
                std.debug.print("FAIL: get_subscription_matched_status(probe) failed\n", .{});
                std.process.exit(1);
            }
            if (status.current_count > 0) matched = true else sleepNs(io, POLL_PERIOD_NS);
        }

        var pub_handles = DDS.InstanceHandleSeq{};
        defer freeHandles(&pub_handles);
        if (probe_dr.get_matched_publications(&pub_handles) != DDS.RETCODE_OK or pub_handles._length == 0) {
            std.debug.print("FAIL: get_matched_publications(probe) returned no handles\n", .{});
            std.process.exit(1);
        }
        const writer_handle = pub_handles._buffer.?[0];
        if (dp.ignore_publication(writer_handle) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: ignore_publication() failed\n", .{});
            std.process.exit(1);
        }
        _ = subscriber.delete_datareader(probe_dr);
        std.debug.print("Ignorer: ignore_publication() applied via probe.\n", .{});
    }
    const pub_ignored_dr = subscriber.create_datareader(pub_ignored_topic.vtable.as_TopicDescription(pub_ignored_topic.ptr), dr_qos, null, 0);
    if (pub_ignored_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(real, PublicationIgnoredTopic) failed\n", .{});
        std.process.exit(1);
    }

    // ── ignore_subscription(): probe, learn peer's reader handle, ignore,
    // then prove a freshly-created writer never matches it. ────────────────
    {
        const probe_dw = publisher.create_datawriter(sub_ignored_topic, dw_qos, null, 0);
        if (probe_dw.ptr == zzdds.dcps.NIL_PTR) {
            std.debug.print("FAIL: create_datawriter(probe, SubscriptionIgnoredTopic) failed\n", .{});
            std.process.exit(1);
        }
        var status: DDS.PublicationMatchedStatus = undefined;
        const deadline = monoNs(io) + PROBE_MATCH_TIMEOUT_NS;
        var matched = false;
        while (!matched) {
            if (monoNs(io) > deadline) {
                std.debug.print("FAIL: probe writer never matched peer's SubscriptionIgnoredTopic reader within {d}s\n", .{@divTrunc(PROBE_MATCH_TIMEOUT_NS, std.time.ns_per_s)});
                std.process.exit(1);
            }
            if (probe_dw.get_publication_matched_status(&status) != DDS.RETCODE_OK) {
                std.debug.print("FAIL: get_publication_matched_status(probe) failed\n", .{});
                std.process.exit(1);
            }
            if (status.current_count > 0) matched = true else sleepNs(io, POLL_PERIOD_NS);
        }

        var sub_handles = DDS.InstanceHandleSeq{};
        defer freeHandles(&sub_handles);
        if (probe_dw.get_matched_subscriptions(&sub_handles) != DDS.RETCODE_OK or sub_handles._length == 0) {
            std.debug.print("FAIL: get_matched_subscriptions(probe) returned no handles\n", .{});
            std.process.exit(1);
        }
        const reader_handle = sub_handles._buffer.?[0];
        if (dp.ignore_subscription(reader_handle) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: ignore_subscription() failed\n", .{});
            std.process.exit(1);
        }
        _ = publisher.delete_datawriter(probe_dw);
        std.debug.print("Ignorer: ignore_subscription() applied via probe.\n", .{});
    }
    const sub_ignored_dw = publisher.create_datawriter(sub_ignored_topic, dw_qos, null, 0);
    if (sub_ignored_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(real, SubscriptionIgnoredTopic) failed\n", .{});
        std.process.exit(1);
    }
    const sub_ignored_writer = ignore_event_gen.IgnoreEventDataWriter.init(sub_ignored_dw, alloc);
    var seq: i32 = 0;
    while (seq < SAMPLE_COUNT) : (seq += 1) {
        sub_ignored_writer.write(.{ .seq = seq }, 0) catch {
            std.debug.print("FAIL: write(SubscriptionIgnoredTopic) failed at seq={d}\n", .{seq});
            std.process.exit(1);
        };
    }

    // Let everything settle: bystander's writer (created after its own
    // delay) gets a real chance to try (and fail) to announce; the
    // already-existing TopicIgnoredTopic writer gets a real chance to try
    // (and fail) to match the reader created above.
    sleepNs(io, SETTLE_WINDOW_NS);

    var topic_status: DDS.SubscriptionMatchedStatus = undefined;
    if (topic_ignored_dr.get_subscription_matched_status(&topic_status) != DDS.RETCODE_OK or topic_status.current_count != 0) {
        std.debug.print("FAIL: TopicIgnoredTopic reader matched despite ignore_topic() (current_count={d})\n", .{topic_status.current_count});
        std.process.exit(1);
    }
    var participant_status: DDS.SubscriptionMatchedStatus = undefined;
    if (participant_ignored_dr.get_subscription_matched_status(&participant_status) != DDS.RETCODE_OK or participant_status.current_count != 0) {
        std.debug.print("FAIL: ParticipantIgnoredTopic reader matched despite ignore_participant() (current_count={d})\n", .{participant_status.current_count});
        std.process.exit(1);
    }
    var pub_status: DDS.SubscriptionMatchedStatus = undefined;
    if (pub_ignored_dr.get_subscription_matched_status(&pub_status) != DDS.RETCODE_OK or pub_status.current_count != 0) {
        std.debug.print("FAIL: PublicationIgnoredTopic reader matched despite ignore_publication() (current_count={d})\n", .{pub_status.current_count});
        std.process.exit(1);
    }

    // Confirm the real guarantee, not just the match-count field: peer's
    // writers for TopicIgnoredTopic and PublicationIgnoredTopic have been
    // writing continuously this whole time (see peer.zig) and -- since
    // ignore_topic()/ignore_publication() are a strictly one-sided, local
    // filter (see this file's header comment) -- legitimately still
    // consider *themselves* matched from their own side. What must never
    // happen is this reader's own take() ever surfacing one of their
    // samples.
    const topic_ignored_reader = ignore_event_gen.IgnoreEventDataReader.init(topic_ignored_dr, alloc);
    var topic_taken: std.ArrayListUnmanaged(ignore_event_gen.IgnoreEventDataReader.SampledValue) = .empty;
    defer topic_taken.deinit(alloc);
    _ = try topic_ignored_reader.take(&topic_taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    if (topic_taken.items.len != 0) {
        std.debug.print("FAIL: TopicIgnoredTopic reader received {d} samples, expected 0\n", .{topic_taken.items.len});
        std.process.exit(1);
    }
    const pub_ignored_reader = ignore_event_gen.IgnoreEventDataReader.init(pub_ignored_dr, alloc);
    var pub_taken: std.ArrayListUnmanaged(ignore_event_gen.IgnoreEventDataReader.SampledValue) = .empty;
    defer pub_taken.deinit(alloc);
    _ = try pub_ignored_reader.take(&pub_taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    if (pub_taken.items.len != 0) {
        std.debug.print("FAIL: PublicationIgnoredTopic reader received {d} samples, expected 0\n", .{pub_taken.items.len});
        std.process.exit(1);
    }
    std.debug.print("Ignorer: all ignore checks passed.\n", .{});

    // ── Control: prove the apparatus itself works -- an unignored reader
    // must match and receive normally. ──────────────────────────────────────
    var control_status: DDS.SubscriptionMatchedStatus = undefined;
    const match_deadline = monoNs(io) + MATCH_TIMEOUT_NS;
    var control_matched = false;
    while (!control_matched) {
        if (monoNs(io) > match_deadline) {
            std.debug.print("FAIL: ControlTopic reader never matched within {d}s\n", .{@divTrunc(MATCH_TIMEOUT_NS, std.time.ns_per_s)});
            std.process.exit(1);
        }
        if (control_dr.get_subscription_matched_status(&control_status) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: get_subscription_matched_status(control) failed\n", .{});
            std.process.exit(1);
        }
        if (control_status.current_count > 0) control_matched = true else sleepNs(io, POLL_PERIOD_NS);
    }

    const control_reader = ignore_event_gen.IgnoreEventDataReader.init(control_dr, alloc);
    var received: i32 = 0;
    var last_seq: i32 = -1;
    const receive_deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (received < SAMPLE_COUNT) {
        if (monoNs(io) > receive_deadline) {
            std.debug.print("FAIL: ControlTopic did not receive all {d} samples within {d}s (got {d})\n", .{ SAMPLE_COUNT, @divTrunc(RECEIVE_TIMEOUT_NS, std.time.ns_per_s), received });
            std.process.exit(1);
        }
        var taken: std.ArrayListUnmanaged(ignore_event_gen.IgnoreEventDataReader.SampledValue) = .empty;
        defer taken.deinit(alloc);
        _ = try control_reader.take(&taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
        for (taken.items) |sv| {
            if (sv.value.seq != last_seq + 1) {
                std.debug.print("FAIL: ControlTopic out-of-order sample, expected seq={d} got seq={d}\n", .{ last_seq + 1, sv.value.seq });
                std.process.exit(1);
            }
            last_seq = sv.value.seq;
            received += 1;
        }
        if (received < SAMPLE_COUNT) sleepNs(io, POLL_PERIOD_NS);
    }
    std.debug.print("Ignorer: ControlTopic received all {d} samples.\n", .{SAMPLE_COUNT});

    // Standard teardown-safety: waiting for peer's ControlTopic writer to
    // observe us disconnect isn't this side's job -- peer waits on its own
    // matched-count-to-zero after we delete_participant() (see peer.zig).
    std.debug.print("Ignorer: done.\n", .{});
}
