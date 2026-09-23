//! zig/ignore-entities -- bystander. A deliberately throwaway third
//! participant, used only to demonstrate ignore_participant()'s
//! participant-wide scope: unlike the other three ignore_*() operations
//! (which target one specific topic/publication/subscription and share
//! `peer`'s otherwise-normal participant for their control-topic sanity
//! check), ignoring a participant would blackhole EVERYTHING from that
//! participant -- so it needs its own dedicated, single-purpose
//! participant to ignore, distinct from `peer`. See
//! docs/design/integration-test-tier.md for the full scenario spec.
//!
//! Deliberately delays creating its writer (PRE_WRITER_DELAY_NS) after its
//! participant exists -- a wide, comfortable window (same convention as
//! enable-defer's PRE_ENABLE_DELAY) for the ignorer to discover and ignore
//! this participant before the writer's SEDP announcement can ever reach
//! it.
//!
//! IMPORTANT: this process's own match-count is NOT expected to be zero,
//! and this file does not assert that it is. ignore_participant() is
//! called on the *ignorer's* participant only -- exactly like
//! ignore_topic()/ignore_publication()/ignore_subscription(), it is a
//! strictly one-sided, local filter (see ignorer.zig's header comment for
//! the full explanation). This process has no idea it has been ignored, so
//! its own SEDP discovery of the ignorer's ParticipantIgnoredTopic reader
//! proceeds completely normally and this writer legitimately reports
//! itself matched. The real, meaningful assertion -- that the ignorer's
//! own reader never actually receives any of this writer's samples -- is
//! checked entirely from ignorer.zig's side, which is the only side with
//! anything to verify. This process's job is just to exist, delay, write,
//! and exit cleanly; a hang here would be the wrong failure mode.
//!
//! Required stdout markers: "Bystander: ready.", "Bystander: created writer
//! for ParticipantIgnoredTopic.", "Bystander: done." Any failure path
//! prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ignore_event_gen = @import("ignore_event_gen");

const SAMPLE_COUNT: i32 = 5;
const PRE_WRITER_DELAY_NS: u64 = 4 * std.time.ns_per_s;
const POST_WRITE_SETTLE_NS: u64 = 6 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

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
    std.debug.print("Bystander: ready.\n", .{});

    // Deliberate wall-clock window -- not a race-avoidance hack. Gives the
    // ignorer a comfortable, unambiguous stretch of real time to discover
    // and ignore this participant before the writer below ever announces.
    sleepNs(io, PRE_WRITER_DELAY_NS);

    var ts_alloc = alloc;
    if (!zzdds.registerTypeSupport(dp, "IgnoreEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = ignore_event_gen.IgnoreEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = ignore_event_gen.IgnoreEvent.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("ParticipantIgnoredTopic", "IgnoreEvent", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }

    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dw = publisher.create_datawriter(topic, dw_qos, null, 0);
    if (dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Bystander: created writer for ParticipantIgnoredTopic.\n", .{});

    const writer = ignore_event_gen.IgnoreEventDataWriter.init(dw, alloc);
    var seq: i32 = 0;
    while (seq < SAMPLE_COUNT) : (seq += 1) {
        writer.write(.{ .seq = seq }, 0) catch {};
    }

    // No match-count assertion here -- see this file's header comment.
    // Just gives ignorer.zig's own settle window (which this overlaps) a
    // comfortable stretch of real time before this process exits and tears
    // its participant down.
    sleepNs(io, POST_WRITE_SETTLE_NS);

    std.debug.print("Bystander: done.\n", .{});
}
