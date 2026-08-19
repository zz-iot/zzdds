//! Zig DDS shape_main — interoperability test application for OMG dds-rtps.
//!
//! Mirrors the CLI interface of srcCxx/shape_main.cxx so the Python test
//! harness (interoperability_report.py) can drive it as a pub or sub.
//!
//! This file is vendor-agnostic.  All DDS implementation details are hidden
//! behind the "dds" module, which each Zig DDS vendor supplies via their
//! build.zig.  See srcZig/dds.zig for the full interface contract.
//!
//! CDR serialization and key-hash computation are handled by the zidl-generated
//! "shape_gen" module (ShapeTypeDataWriter / ShapeTypeDataReader).  The typed
//! wrappers query the DataWriter QoS at init time to select XCDR1 vs XCDR2.
//!
//! Required stdout strings (matched by the harness via pexpect):
//!   Publisher: "Create topic:"  →  "Create writer for topic:"  →
//!              "on_publication_matched()" or "on_offered_incompatible_qos"  →
//!              "%-10s %-10s %03d %03d [%d]" (only when -w is passed)
//!   Subscriber: "Create topic:"  →  "Create reader for topic:"  →
//!               "[<number>]" in the sample line  or  "on_requested_incompatible_qos()"

const std = @import("std");
const dds = @import("dds");
const DDS = dds.DDS;
const shape_gen = @import("shape_gen");
const shape_main_options = @import("shape_main_options");

// zzdds resolves its SPDP participant-announcement period from this env var
// (see zzdds/src/config/resolve.zig); Zig's std.c doesn't expose setenv on Linux.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const std_options: std.Options = .{
    .log_level = std.meta.stringToEnum(std.log.Level, shape_main_options.log_level) orelse
        @compileError("invalid shape_main log level"),
};

// ── ShapeType color type ──────────────────────────────────────────────────────
// BoundedArray(u8, 128) as generated from string<128> in shape.idl.
const ShapeColor = @TypeOf(@as(shape_gen.ShapeType, .{}).color);

// ── Time helpers (std.time.sleep/nanoTimestamp don't exist in this Zig --
// std.Io.Clock is the portable replacement, correct on Linux/macOS/Windows
// alike, unlike the std.os.linux-specific syscalls this used to hand-roll) ──

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// ── Stdout helpers ────────────────────────────────────────────────────────────
// std.io was removed in Zig 0.16; write directly via the Linux write(2) syscall.

fn stdoutWrite(bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const rc = std.os.linux.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
        const n = @as(isize, @bitCast(rc));
        if (n <= 0) break;
        remaining = remaining[@intCast(n)..];
    }
}

fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(fmt, args) catch {};
    stdoutWrite(w.buffered());
}

// ── Signal handling ───────────────────────────────────────────────────────────

var g_all_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn handleSigint(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    g_all_done.store(true, .release);
}

// ── Options ───────────────────────────────────────────────────────────────────

const Options = struct {
    publish: bool = false,
    subscribe: bool = false,
    domain_id: u32 = 0,
    best_effort: bool = false,
    reliable: bool = false,
    history_depth: i32 = -1, // -1 = use default KEEP_LAST 1
    deadline_ms: u64 = 0,
    lifespan_ms: u64 = 0, // 0 = infinite (--lifespan)
    ownership_strength: i32 = -1, // -1 = SHARED
    topic_name: [:0]const u8 = "Square",
    color: ?[]const u8 = null,
    partition: ?[]const u8 = null,
    durability: u8 = 'v',
    data_representation: u16 = 1, // 1=XCDR1, 2=XCDR2
    print_writer_samples: bool = false,
    shapesize: i32 = 20,
    write_period_ms: u64 = 33,
    read_period_ms: u64 = 100,
    num_iterations: i64 = -1, // -1 = infinite
    num_instances: u32 = 1,
    additional_payload: u32 = 0,
    size_modulo: i32 = 0, // 0 = no cycling (--size-modulo)
    cft_expression: ?[:0]const u8 = null, // content filter expression (--cft)
    time_filter_ms: u64 = 0, // TIME_BASED_FILTER minimum_separation in ms (--time-filter)
    final_instance_state: u8 = 0, // 0=none, 'u'=unregister, 'd'=dispose (--final-instance-state)
    access_scope: u8 = 'i', // 'i'=instance (default), 't'=topic, 'g'=group (--access-scope)
    ordered_access: bool = false, // --ordered
    coherent_access: bool = false, // --coherent
    num_topics: u32 = 1, // --num-topics
    take_read: bool = false, // --take-read: use take() instead of take_next_instance()
    read_only: bool = false, // -R: use read() instead of take() (non-destructive)
    coherent_sample_count: u32 = 0, // --coherent-sample-count (0 = no coherent set gating)
    periodic_announcement_ms: u32 = 0, // --periodic-announcement (0 = use zzdds's own default)
    config_path: ?[:0]const u8 = null, // --config: zzdds.toml-style process config, installed before the factory is created
};

// ── Policy name mapping ───────────────────────────────────────────────────────

fn policyName(id: i32) []const u8 {
    return switch (id) {
        2 => "DURABILITY",
        4 => "DEADLINE",
        5 => "LATENCYBUDGET",
        6 => "OWNERSHIP",
        8 => "LIVELINESS",
        10 => "PARTITION",
        11 => "RELIABILITY",
        12 => "DESTINATIONORDER",
        23 => "DATAREPRESENTATION",
        else => "UNKNOWN",
    };
}

// ── Listener context and vtables ──────────────────────────────────────────────

const ListenerCtx = struct {
    topic_name: [:0]const u8,
    type_name: []const u8 = "ShapeType",
};

// DataWriter listener callbacks — plain Zig, no callconv(.c), status by value.

fn dwOnIncompatQos(lc: *ListenerCtx, _: DDS.DataWriter, status: DDS.OfferedIncompatibleQosStatus) void {
    stdoutPrint("on_offered_incompatible_qos() topic: '{s}'  type: '{s}' : {d} ({s})\n", .{ lc.topic_name, lc.type_name, status.last_policy_id, policyName(status.last_policy_id) });
}
fn dwOnDeadlineMissed(lc: *ListenerCtx, _: DDS.DataWriter, status: DDS.OfferedDeadlineMissedStatus) void {
    stdoutPrint("on_offered_deadline_missed() topic: '{s}'  type: '{s}' : (total = {d}, change = {d})\n", .{ lc.topic_name, lc.type_name, status.total_count, status.total_count_change });
}

// DataReader listener callbacks — plain Zig, no callconv(.c), status by value.

fn drOnIncompatQos(lc: *ListenerCtx, _: DDS.DataReader, status: DDS.RequestedIncompatibleQosStatus) void {
    stdoutPrint("on_requested_incompatible_qos() topic: '{s}'  type: '{s}' : {d} ({s})\n", .{ lc.topic_name, lc.type_name, status.last_policy_id, policyName(status.last_policy_id) });
}
fn drOnDeadlineMissed(lc: *ListenerCtx, _: DDS.DataReader, status: DDS.RequestedDeadlineMissedStatus) void {
    stdoutPrint("on_requested_deadline_missed() topic: '{s}'  type: '{s}' : (total = {d}, change = {d})\n", .{ lc.topic_name, lc.type_name, status.total_count, status.total_count_change });
}

// ── DataWriter QoS builder ────────────────────────────────────────────────────

fn buildWriterQos(alloc: std.mem.Allocator, pub_: DDS.Publisher, opts: *const Options) !DDS.DataWriterQos {
    var qos: DDS.DataWriterQos = undefined;
    if (pub_.get_default_datawriter_qos(&qos) != DDS.RETCODE_OK) return error.GetDefaultQosFailed;

    // -r forces RELIABLE even if -b was also passed; otherwise -b selects
    // BEST_EFFORT and everything else (including the no-flags case) is RELIABLE.
    qos.reliability.kind = if (opts.best_effort and !opts.reliable)
        .BEST_EFFORT_RELIABILITY_QOS
    else
        .RELIABLE_RELIABILITY_QOS;

    if (opts.history_depth == 0) {
        qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    } else if (opts.history_depth > 0) {
        qos.history.kind = .KEEP_LAST_HISTORY_QOS;
        qos.history.depth = opts.history_depth;
    }

    if (opts.deadline_ms > 0) {
        qos.deadline.period = .{
            .sec = @intCast(opts.deadline_ms / 1000),
            .nanosec = @intCast((opts.deadline_ms % 1000) * std.time.ns_per_ms),
        };
    }

    if (opts.lifespan_ms > 0) {
        qos.lifespan.duration = .{
            .sec = @intCast(opts.lifespan_ms / 1000),
            .nanosec = @intCast((opts.lifespan_ms % 1000) * std.time.ns_per_ms),
        };
    }

    if (opts.ownership_strength >= 0) {
        qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
        qos.ownership_strength.value = opts.ownership_strength;
    }

    qos.durability.kind = switch (opts.durability) {
        'v' => .VOLATILE_DURABILITY_QOS,
        'l' => .TRANSIENT_LOCAL_DURABILITY_QOS,
        't' => .TRANSIENT_DURABILITY_QOS,
        'p' => .PERSISTENT_DURABILITY_QOS,
        else => .VOLATILE_DURABILITY_QOS,
    };

    const repr_id: i16 = if (opts.data_representation == 2) 2 else 0;
    const repr_buf = try alloc.alloc(DDS.DataRepresentationId_t, 1);
    repr_buf[0] = repr_id;
    qos.data_representation.value = .{ ._buffer = repr_buf.ptr, ._length = 1, ._maximum = 1, ._release = true };

    return qos;
}

// ── DataReader QoS builder ────────────────────────────────────────────────────

fn buildReaderQos(alloc: std.mem.Allocator, sub: DDS.Subscriber, opts: *const Options) !DDS.DataReaderQos {
    var qos: DDS.DataReaderQos = undefined;
    if (sub.get_default_datareader_qos(&qos) != DDS.RETCODE_OK) return error.GetDefaultQosFailed;

    // -r forces RELIABLE even if -b was also passed; otherwise -b selects
    // BEST_EFFORT and everything else (including the no-flags case) is RELIABLE.
    qos.reliability.kind = if (opts.best_effort and !opts.reliable)
        .BEST_EFFORT_RELIABILITY_QOS
    else
        .RELIABLE_RELIABILITY_QOS;

    if (opts.history_depth == 0) {
        qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    } else if (opts.history_depth > 0) {
        qos.history.kind = .KEEP_LAST_HISTORY_QOS;
        qos.history.depth = opts.history_depth;
    }

    if (opts.deadline_ms > 0) {
        qos.deadline.period = .{
            .sec = @intCast(opts.deadline_ms / 1000),
            .nanosec = @intCast((opts.deadline_ms % 1000) * std.time.ns_per_ms),
        };
    }

    if (opts.ownership_strength >= 0) {
        qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    }

    qos.durability.kind = switch (opts.durability) {
        'v' => .VOLATILE_DURABILITY_QOS,
        'l' => .TRANSIENT_LOCAL_DURABILITY_QOS,
        't' => .TRANSIENT_DURABILITY_QOS,
        'p' => .PERSISTENT_DURABILITY_QOS,
        else => .VOLATILE_DURABILITY_QOS,
    };

    if (opts.time_filter_ms > 0) {
        qos.time_based_filter.minimum_separation = .{
            .sec = @intCast(opts.time_filter_ms / 1000),
            .nanosec = @intCast((opts.time_filter_ms % 1000) * std.time.ns_per_ms),
        };
    }

    const repr_id: i16 = if (opts.data_representation == 2) 2 else 0;
    const repr_buf = try alloc.alloc(DDS.DataRepresentationId_t, 1);
    repr_buf[0] = repr_id;
    qos.data_representation.value = .{ ._buffer = repr_buf.ptr, ._length = 1, ._maximum = 1, ._release = true };

    return qos;
}

// ── nil sentinel helpers ──────────────────────────────────────────────────────
// Delegated to the vendor dds module, which knows the implementation's nil
// sentinel value (each vendor may use a different non-null sentinel address).

fn isNilTopic(t: DDS.Topic) bool {
    return dds.isNilTopic(t);
}
fn isNilPub(p: DDS.Publisher) bool {
    return dds.isNilPub(p);
}
fn isNilSub(s: DDS.Subscriber) bool {
    return dds.isNilSub(s);
}
fn isNilDw(dw: DDS.DataWriter) bool {
    return dds.isNilDw(dw);
}
fn isNilDr(dr: DDS.DataReader) bool {
    return dds.isNilDr(dr);
}
fn isNilCft(cft: DDS.ContentFilteredTopic) bool {
    return dds.isNilCft(cft);
}

// ── Multi-topic helpers ───────────────────────────────────────────────────────

const MAX_TOPICS = 16;

// Holds the extra topics (index 1..num_topics-1) created alongside the base topic.
// The base topic (index 0) is owned by main() and its name is opts.topic_name.
const ExtraTopics = struct {
    topics: [MAX_TOPICS]DDS.Topic = undefined,
    names: [MAX_TOPICS][:0]u8 = undefined,
    count: u32 = 0,

    fn deinitNames(self: *ExtraTopics, alloc: std.mem.Allocator) void {
        for (0..self.count) |i| alloc.free(self.names[i]);
    }

    fn topicAt(self: *const ExtraTopics, base: DDS.Topic, i: u32) DDS.Topic {
        return if (i == 0) base else self.topics[i - 1];
    }

    fn nameAt(self: *const ExtraTopics, base_name: [:0]const u8, i: u32) [:0]const u8 {
        return if (i == 0) base_name else self.names[i - 1];
    }
};

fn createExtraTopics(
    alloc: std.mem.Allocator,
    dp: DDS.DomainParticipant,
    opts: *const Options,
) !ExtraTopics {
    var et = ExtraTopics{};
    et.count = opts.num_topics - 1;
    for (0..et.count) |i| {
        et.names[i] = try std.fmt.allocPrintSentinel(alloc, "{s}{d}", .{ opts.topic_name, i + 1 }, 0);
        stdoutPrint("Create topic: {s}\n", .{et.names[i]});
        et.topics[i] = dp.create_topic(et.names[i], "ShapeType", .{}, null, 0);
        if (isNilTopic(et.topics[i])) {
            // Free names allocated so far then signal failure
            for (0..i + 1) |j| alloc.free(et.names[j]);
            et.count = 0;
            return error.TopicFailed;
        }
    }
    return et;
}

// ── Publisher ─────────────────────────────────────────────────────────────────

fn runPublisher(
    io: std.Io,
    alloc: std.mem.Allocator,
    dp: DDS.DomainParticipant,
    base_topic: DDS.Topic,
    opts: *const Options,
) !void {
    const base_color = opts.color orelse "BLUE";
    const n = opts.num_topics;

    var et = try createExtraTopics(alloc, dp, opts);
    defer et.deinitNames(alloc);

    const pub_presentation = DDS.PresentationQosPolicy{
        .access_scope = switch (opts.access_scope) {
            't' => .TOPIC_PRESENTATION_QOS,
            'g' => .GROUP_PRESENTATION_QOS,
            else => .INSTANCE_PRESENTATION_QOS,
        },
        .coherent_access = opts.coherent_access,
        .ordered_access = opts.ordered_access,
    };
    // Partition names must be [*:0]const u8 in StringSeq (C PSM layout).
    // argv strings are always null-terminated so the ptrCast is safe.
    var pub_partition_cstrs: [1][*:0]const u8 = .{
        if (opts.partition) |p| @as([*:0]const u8, @ptrCast(p.ptr)) else "",
    };
    const pub_partition_seq = DDS.StringSeq{ ._buffer = @ptrCast(&pub_partition_cstrs), ._length = 1, ._maximum = 1, ._release = false };
    const pub_qos: DDS.PublisherQos = if (opts.partition) |_| .{
        .presentation = pub_presentation,
        .partition = .{ .name = pub_partition_seq },
    } else .{ .presentation = pub_presentation };
    const pub_ = dp.create_publisher(pub_qos, null, 0);
    if (isNilPub(pub_)) return error.PublisherFailed;

    var dw_qos = try buildWriterQos(alloc, pub_, opts);
    defer dw_qos.deinit(alloc);

    // One ListenerCtx, raw DataWriter handle, and typed DataWriter per topic.
    var lctxs: [MAX_TOPICS]ListenerCtx = undefined;
    var dw_handles: [MAX_TOPICS]DDS.DataWriter = undefined;
    var typed_writers: [MAX_TOPICS]shape_gen.ShapeTypeDataWriter = undefined;
    const listener_mask: DDS.StatusMask =
        DDS.OFFERED_INCOMPATIBLE_QOS_STATUS | DDS.OFFERED_DEADLINE_MISSED_STATUS;

    for (0..n) |i| {
        const tn = et.nameAt(opts.topic_name, @intCast(i));
        lctxs[i] = .{ .topic_name = tn };
        const dw_listener = DDS.dataWriterListener(&lctxs[i], .{
            .on_offered_deadline_missed = dwOnDeadlineMissed,
            .on_offered_incompatible_qos = dwOnIncompatQos,
        });
        const t = et.topicAt(base_topic, @intCast(i));
        dw_handles[i] = pub_.create_datawriter(t, dw_qos, dw_listener, listener_mask);
        if (isNilDw(dw_handles[i])) return error.DataWriterFailed;
        typed_writers[i] = shape_gen.ShapeTypeDataWriter.init(dw_handles[i], alloc);
        stdoutPrint("Create writer for topic: {s} color: {s}\n", .{ tn, base_color });
    }

    // Build the shape value reused across write iterations.
    var shape = shape_gen.ShapeType{
        .x = 0,
        .y = 0,
        .shapesize = if (opts.shapesize == 0) 1 else opts.shapesize,
    };
    shape.color = ShapeColor.fromSlice(base_color) catch .{};
    defer shape.deinit(alloc);

    if (opts.additional_payload > 0) {
        const payload_buf = try alloc.alloc(u8, opts.additional_payload);
        @memset(payload_buf[0 .. opts.additional_payload - 1], 0);
        payload_buf[opts.additional_payload - 1] = 255;
        shape.additional_payload_size = .{
            ._buffer = payload_buf.ptr,
            ._length = @intCast(opts.additional_payload),
            ._maximum = @intCast(opts.additional_payload),
            ._release = true,
        };
    }

    var rng = std.Random.DefaultPrng.init(@intCast(monoNs(io)));
    const rand = rng.random();

    const match_deadline = monoNs(io) + 10 * std.time.ns_per_s;
    var printed_matched = false;

    // Coherent set gating: each outer write-loop iteration is one whole coherent
    // window (begin_coherent_changes -> `sc` consecutive samples per instance ->
    // end_coherent_changes). When coherent_access is enabled but no explicit count
    // is given (sc=0), default to 1 so that PID_COHERENT_SET is still emitted for
    // single-sample sets (required by Connext).
    const sc: u32 = if (opts.coherent_sample_count > 0) opts.coherent_sample_count else 1;
    const use_coherent_gating = opts.coherent_access or opts.ordered_access;

    var iteration: i64 = 0;
    while (!g_all_done.load(.acquire)) {
        if (opts.num_iterations >= 0 and iteration >= opts.num_iterations) break;

        if (!printed_matched) {
            var pm_status: DDS.PublicationMatchedStatus = .{};
            _ = dw_handles[0].get_publication_matched_status(&pm_status);
            if (pm_status.current_count > 0) {
                stdoutPrint(
                    "on_publication_matched() topic: '{s}'  type: 'ShapeType' : matched readers {d} (change = 1)\n",
                    .{ lctxs[0].topic_name, pm_status.current_count },
                );
                printed_matched = true;
            } else if (monoNs(io) > match_deadline) {
                return; // READER_NOT_MATCHED
            }
        }

        // For coherent publishers, hold off writing until a reader has matched.
        // Connext's GROUP coherent subscriber requires the group sequence to
        // start from 1; writing before match would advance the GSN so the
        // subscriber joins mid-stream and never receives a complete set.
        if (use_coherent_gating and !printed_matched) {
            sleepNs(io, opts.write_period_ms * std.time.ns_per_ms);
            continue;
        }

        // DEADLINE QoS is enforced automatically by zzdds's own background
        // timer (DomainParticipantImpl.checkTimers(), driven by a per-
        // participant thread) -- no manual elapsed-time tracking needed here
        // anymore; on_offered_deadline_missed() fires on its own.

        if (use_coherent_gating) {
            // Write a whole coherent window (all topics x instances x `sc` samples)
            // in one begin/end pass, `sc` samples per instance consecutively, so the
            // wire order groups by instance instead of interleaving (round-robin
            // order can never satisfy the interop suite's consecutive-same-instance
            // check, independent of anything the reader side does).
            _ = pub_.vtable.begin_coherent_changes(pub_.ptr);

            for (0..n) |ti| {
                for (0..opts.num_instances) |inst| {
                    const inst_color = try instanceColor(alloc, base_color, inst);
                    defer if (inst > 0) alloc.free(inst_color);
                    shape.color = ShapeColor.fromSlice(inst_color) catch .{};
                    for (0..sc) |_| {
                        shape.x = @rem(@as(i32, rand.int(u16)), 320);
                        shape.y = @rem(@as(i32, rand.int(u16)), 240);
                        try typed_writers[ti].write(shape, 0);
                        if (opts.print_writer_samples) {
                            stdoutPrint("{s:<10} {s:<10} {d:0>3} {d:0>3} [{d}]\n", .{ lctxs[ti].topic_name, inst_color, @as(u32, @intCast(shape.x)), @as(u32, @intCast(shape.y)), shape.shapesize });
                        }
                        if (opts.shapesize == 0) {
                            shape.shapesize += 1;
                            if (opts.size_modulo > 0 and shape.shapesize > opts.size_modulo)
                                shape.shapesize = 1;
                        }
                    }
                }
            }

            _ = pub_.vtable.end_coherent_changes(pub_.ptr);
        } else {
            shape.x = @rem(@as(i32, rand.int(u16)), 320);
            shape.y = @rem(@as(i32, rand.int(u16)), 240);

            for (0..n) |ti| {
                for (0..opts.num_instances) |inst| {
                    const inst_color = try instanceColor(alloc, base_color, inst);
                    defer if (inst > 0) alloc.free(inst_color);
                    shape.color = ShapeColor.fromSlice(inst_color) catch .{};
                    try typed_writers[ti].write(shape, 0);
                    if (opts.print_writer_samples) {
                        stdoutPrint("{s:<10} {s:<10} {d:0>3} {d:0>3} [{d}]\n", .{ lctxs[ti].topic_name, inst_color, @as(u32, @intCast(shape.x)), @as(u32, @intCast(shape.y)), shape.shapesize });
                    }
                }
            }

            if (opts.shapesize == 0) {
                shape.shapesize += 1;
                if (opts.size_modulo > 0 and shape.shapesize > opts.size_modulo)
                    shape.shapesize = 1;
            }
        }

        iteration += 1;
        sleepNs(io, opts.write_period_ms * std.time.ns_per_ms);
    }

    // Unregister/dispose all instances across all topics on finite run.
    if (opts.num_iterations >= 0) {
        const do_dispose = opts.final_instance_state == 'd';
        for (0..n) |ti| {
            for (0..opts.num_instances) |inst| {
                const inst_color = try instanceColor(alloc, base_color, inst);
                defer if (inst > 0) alloc.free(inst_color);
                const key = shape_gen.ShapeType{ .color = ShapeColor.fromSlice(inst_color) catch .{} };
                if (do_dispose) {
                    typed_writers[ti].dispose(key, 0) catch |err| {
                        stdoutPrint("FAIL: dispose() failed: {s}\n", .{@errorName(err)});
                        std.process.exit(1);
                    };
                } else {
                    typed_writers[ti].unregister_instance(key, 0) catch |err| {
                        stdoutPrint("FAIL: unregister_instance() failed: {s}\n", .{@errorName(err)});
                        std.process.exit(1);
                    };
                }
            }
        }
        // Wait until all reliable readers have ACKed the NOT_ALIVE changes,
        // or up to 5 s, to avoid exiting before RELIABLE transport has
        // delivered the unregister/dispose changes to matched readers.
        const ack_timeout = DDS.Duration_t{ .sec = 5, .nanosec = 0 };
        for (0..n) |ti| {
            _ = dds.writerWaitForAck(typed_writers[ti].dataWriter(), ack_timeout);
        }
    }
}

// ── Subscriber ────────────────────────────────────────────────────────────────

fn runSubscriber(
    io: std.Io,
    alloc: std.mem.Allocator,
    dp: DDS.DomainParticipant,
    base_topic: DDS.Topic,
    opts: *const Options,
) !void {
    const n = opts.num_topics;

    var et = try createExtraTopics(alloc, dp, opts);
    defer et.deinitNames(alloc);

    // Content-filtered topic for topic[0] only (when --cft or -c COLOR is specified).
    var synth_cft_buf: [65]u8 = undefined;
    const effective_cft_expr: ?[:0]const u8 = if (opts.cft_expression) |e|
        e
    else if (opts.color) |c|
        std.fmt.bufPrintZ(&synth_cft_buf, "color = '{s}'", .{c}) catch null
    else
        null;

    const cft: ?DDS.ContentFilteredTopic = blk: {
        const expr = effective_cft_expr orelse break :blk null;
        const base_name = et.nameAt(opts.topic_name, 0);
        const cft_name = try std.fmt.allocPrintSentinel(alloc, "{s}_cft", .{base_name}, 0);
        defer alloc.free(cft_name);
        const c = dp.create_contentfilteredtopic(cft_name, base_topic, expr, null);
        if (isNilCft(c)) return error.ContentFilteredTopicFailed;
        break :blk c;
    };
    defer {
        if (cft) |c| _ = dp.delete_contentfilteredtopic(c);
    }

    const sub_presentation = DDS.PresentationQosPolicy{
        .access_scope = switch (opts.access_scope) {
            't' => .TOPIC_PRESENTATION_QOS,
            'g' => .GROUP_PRESENTATION_QOS,
            else => .INSTANCE_PRESENTATION_QOS,
        },
        .coherent_access = opts.coherent_access,
        .ordered_access = opts.ordered_access,
    };
    var sub_partition_cstrs: [1][*:0]const u8 = .{
        if (opts.partition) |p| @as([*:0]const u8, @ptrCast(p.ptr)) else "",
    };
    const sub_partition_seq = DDS.StringSeq{ ._buffer = @ptrCast(&sub_partition_cstrs), ._length = 1, ._maximum = 1, ._release = false };
    const sub_qos: DDS.SubscriberQos = if (opts.partition) |_| .{
        .presentation = sub_presentation,
        .partition = .{ .name = sub_partition_seq },
    } else .{ .presentation = sub_presentation };
    const sub = dp.create_subscriber(sub_qos, null, 0);
    if (isNilSub(sub)) return error.SubscriberFailed;

    var dr_qos = try buildReaderQos(alloc, sub, opts);
    defer dr_qos.deinit(alloc);

    // One ListenerCtx, raw DataReader handle, and typed DataReader per topic.
    var lctxs: [MAX_TOPICS]ListenerCtx = undefined;
    var dr_handles: [MAX_TOPICS]DDS.DataReader = undefined;
    var typed_readers: [MAX_TOPICS]shape_gen.ShapeTypeDataReader = undefined;
    const listener_mask: DDS.StatusMask =
        DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS | DDS.REQUESTED_DEADLINE_MISSED_STATUS;

    for (0..n) |i| {
        const tn = et.nameAt(opts.topic_name, @intCast(i));
        lctxs[i] = .{ .topic_name = tn };
        const dr_listener = DDS.dataReaderListener(&lctxs[i], .{
            .on_requested_deadline_missed = drOnDeadlineMissed,
            .on_requested_incompatible_qos = drOnIncompatQos,
        });

        const topic_desc: DDS.TopicDescription = if (i == 0 and cft != null)
            cft.?.vtable.as_TopicDescription(cft.?.ptr)
        else
            dp.lookup_topicdescription(tn);

        stdoutPrint("Create reader for topic: {s}\n", .{tn});
        dr_handles[i] = sub.create_datareader(topic_desc, dr_qos, dr_listener, listener_mask);
        if (isNilDr(dr_handles[i])) return error.DataReaderFailed;
        typed_readers[i] = shape_gen.ShapeTypeDataReader.init(dr_handles[i], alloc);
    }

    const use_access = opts.coherent_access or opts.ordered_access;

    // Maps instance_handle → color for recovering key identity from NOT_ALIVE samples
    // that arrive without a serialized key payload (e.g. Connext D=0,K=0 with PID_KEY_HASH only).
    var ih_to_color = std.AutoHashMap(i32, ShapeColor).init(alloc);
    defer ih_to_color.deinit();

    var iteration: i64 = 0;
    while (!g_all_done.load(.acquire)) {
        if (opts.num_iterations >= 0 and iteration >= opts.num_iterations) break;

        // Begin access window for GROUP/TOPIC_PRESENTATION coherent or ordered access.
        if (use_access) {
            if (opts.coherent_access)
                stdoutPrint("Reading coherent sets, iteration {d}\n", .{iteration});
            if (opts.ordered_access)
                stdoutPrint("Reading with ordered access, iteration {d}\n", .{iteration});
            _ = sub.vtable.begin_access(sub.ptr);
        }

        for (0..n) |ti| {
            const tn = lctxs[ti].topic_name;

            // -R (non-destructive read): read_next_sample()/read_next_instance() can't
            // be used in a drain-to-empty loop the way take can, since they match
            // ANY_SAMPLE_STATE and never remove anything — the loop below would spin
            // forever. Instead, bulk-fetch every NOT_READ sample once per topic per
            // outer iteration (which flips them to READ so they won't re-match), then
            // hand them out one at a time from this buffer. --take-read still picks
            // FIFO vs grouped-by-instance ordering, applied here via the sort.
            var read_buf: std.ArrayListUnmanaged(shape_gen.ShapeTypeDataReader.SampledValue) = .empty;
            defer {
                for (read_buf.items) |*sv| sv.deinit(alloc);
                read_buf.deinit(alloc);
            }
            var read_idx: usize = 0;
            if (opts.read_only) {
                _ = typed_readers[ti].read(&read_buf, -1, DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE) catch false;
                if (!opts.take_read) {
                    std.mem.sort(shape_gen.ShapeTypeDataReader.SampledValue, read_buf.items, {}, struct {
                        fn lessThan(_: void, a: shape_gen.ShapeTypeDataReader.SampledValue, b: shape_gen.ShapeTypeDataReader.SampledValue) bool {
                            return a.info.instance_handle < b.info.instance_handle;
                        }
                    }.lessThan);
                }
            }

            while (true) {
                var value: shape_gen.ShapeType = .{};
                var info: DDS.SampleInfo = .{};
                var got: bool = false;

                if (opts.read_only) {
                    if (read_idx >= read_buf.items.len) break;
                    value = read_buf.items[read_idx].value;
                    info = read_buf.items[read_idx].info;
                    read_buf.items[read_idx].value = .{}; // ownership moved to `value`; leave a safe no-op for the outer defer
                    read_idx += 1;
                    got = true;
                } else {
                    // --take-read: take() [take_next_sample, FIFO delivery order] vs the
                    // default take_next_instance() [samples grouped consecutively by
                    // instance]. Passing HANDLE_NIL (0) every call — rather than advancing
                    // to the last-seen instance handle — makes take_next_instance() drain
                    // each instance fully before moving to the next, since it always
                    // retargets the smallest pending instance handle above the threshold.
                    got = (if (opts.take_read)
                        typed_readers[ti].take_next_sample(&value, &info)
                    else
                        typed_readers[ti].take_next_instance(&value, &info, 0)) catch {
                        // CDR error (e.g. Connext key-only payload with no data body).
                        // sample_info was populated before the failure; handle NOT_ALIVE
                        // state using the deserialized key or the instance handle cache.
                        if (info.instance_state == DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE or
                            info.instance_state == DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE)
                        {
                            var key_color: ShapeColor = value.color;
                            if (key_color.slice().len == 0) {
                                if (ih_to_color.get(info.instance_handle)) |cached| key_color = cached;
                            }
                            const state_str = if (info.instance_state == DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE)
                                "NOT_ALIVE_DISPOSED_INSTANCE_STATE"
                            else
                                "NOT_ALIVE_NO_WRITERS_INSTANCE_STATE";
                            stdoutPrint("{s:<10} {s:<10} {s}\n", .{ tn, key_color.slice(), state_str });
                        }
                        value.deinit(alloc);
                        continue;
                    };
                    if (!got) break;
                }
                defer value.deinit(alloc);

                if (info.instance_state == DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE or
                    info.instance_state == DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE)
                {
                    var key_color: ShapeColor = value.color;
                    if (key_color.slice().len == 0) {
                        if (ih_to_color.get(info.instance_handle)) |cached| key_color = cached;
                    }
                    const state_str = if (info.instance_state == DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE)
                        "NOT_ALIVE_DISPOSED_INSTANCE_STATE"
                    else
                        "NOT_ALIVE_NO_WRITERS_INSTANCE_STATE";
                    stdoutPrint("{s:<10} {s:<10} {s}\n", .{ tn, key_color.slice(), state_str });
                    continue;
                }

                // Content assertions: a key (color) must never change across
                // samples of the same instance handle, and the writer only
                // ever emits x/y in [0,320)/[0,240) with shapesize >= 1 --
                // hard-fail if either invariant is violated.
                if (ih_to_color.get(info.instance_handle)) |cached| {
                    if (!std.mem.eql(u8, cached.slice(), value.color.slice())) {
                        stdoutPrint("FAIL: instance {d} color changed from '{s}' to '{s}'\n", .{ info.instance_handle, cached.slice(), value.color.slice() });
                        std.process.exit(1);
                    }
                }
                if (value.x < 0 or value.x >= 320 or value.y < 0 or value.y >= 240 or value.shapesize < 1) {
                    stdoutPrint("FAIL: sample out of bounds: x={d} y={d} shapesize={d}\n", .{ value.x, value.y, value.shapesize });
                    std.process.exit(1);
                }
                ih_to_color.put(info.instance_handle, value.color) catch {};

                // No app-side CFT re-check needed here anymore: zzdds's own
                // reader-side cft_filter (see reader.zig) already dropped any
                // non-matching sample before this loop ever saw it, now that
                // registerTypeSupport above sets get_field.

                const extra_len = value.additional_payload_size._length;
                const last_byte: ?u8 = if (extra_len > 0 and value.additional_payload_size._buffer != null)
                    value.additional_payload_size._buffer.?[extra_len - 1]
                else
                    null;

                if (last_byte) |lb| {
                    stdoutPrint("{s:<10} {s:<10} {d:0>3} {d:0>3} [{d}] {{{d}}}\n", .{ tn, value.color.slice(), @as(u32, @intCast(value.x)), @as(u32, @intCast(value.y)), value.shapesize, lb });
                } else {
                    stdoutPrint("{s:<10} {s:<10} {d:0>3} {d:0>3} [{d}]\n", .{ tn, value.color.slice(), @as(u32, @intCast(value.x)), @as(u32, @intCast(value.y)), value.shapesize });
                }
            }
        }

        if (use_access) _ = sub.vtable.end_access(sub.ptr);

        // DEADLINE QoS is enforced automatically by zzdds's own background
        // timer (DomainParticipantImpl.checkTimers(), driven by a per-
        // participant thread) -- no manual elapsed-time tracking needed here
        // anymore; on_requested_deadline_missed() fires on its own.

        iteration += 1;
        sleepNs(io, opts.read_period_ms * std.time.ns_per_ms);
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

// Returns color for instance index: inst=0 → base_color, inst>0 → "{base_color}{inst}".
// Caller must free the returned slice when inst > 0.
fn instanceColor(alloc: std.mem.Allocator, base: []const u8, inst: usize) ![]const u8 {
    if (inst == 0) return base;
    return std.fmt.allocPrint(alloc, "{s}{d}", .{ base, inst });
}

// ── Argument parsing ──────────────────────────────────────────────────────────

fn parseArgs(process_args: std.process.Args) !Options {
    var opts = Options{};
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // program name

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-P")) {
            opts.publish = true;
        } else if (std.mem.eql(u8, arg, "-S")) {
            opts.subscribe = true;
        } else if (std.mem.eql(u8, arg, "-b")) {
            opts.best_effort = true;
        } else if (std.mem.eql(u8, arg, "-r")) {
            opts.reliable = true;
        } else if (std.mem.eql(u8, arg, "-w")) {
            opts.print_writer_samples = true;
        } else if (std.mem.eql(u8, arg, "-R")) {
            opts.read_only = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            const v = it.next() orelse return error.MissingValue;
            opts.domain_id = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "-k")) {
            const v = it.next() orelse return error.MissingValue;
            opts.history_depth = try std.fmt.parseInt(i32, v, 10);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--deadline")) {
            const v = it.next() orelse return error.MissingValue;
            opts.deadline_ms = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "-s")) {
            const v = it.next() orelse return error.MissingValue;
            opts.ownership_strength = try std.fmt.parseInt(i32, v, 10);
        } else if (std.mem.eql(u8, arg, "-t")) {
            const v = it.next() orelse return error.MissingValue;
            opts.topic_name = v;
        } else if (std.mem.eql(u8, arg, "-c")) {
            const v = it.next() orelse return error.MissingValue;
            opts.color = v;
        } else if (std.mem.eql(u8, arg, "-p")) {
            const v = it.next() orelse return error.MissingValue;
            opts.partition = v;
        } else if (std.mem.eql(u8, arg, "-D")) {
            const v = it.next() orelse return error.MissingValue;
            opts.durability = if (v.len > 0) v[0] else 'v';
        } else if (std.mem.eql(u8, arg, "-x")) {
            const v = it.next() orelse return error.MissingValue;
            opts.data_representation = std.fmt.parseInt(u16, v, 10) catch 1;
        } else if (std.mem.eql(u8, arg, "-z")) {
            const v = it.next() orelse return error.MissingValue;
            opts.shapesize = std.fmt.parseInt(i32, v, 10) catch 20;
        } else if (std.mem.eql(u8, arg, "-n") or
            std.mem.eql(u8, arg, "--num-instances"))
        {
            const v = it.next() orelse return error.MissingValue;
            opts.num_instances = std.fmt.parseInt(u32, v, 10) catch 1;
        } else if (std.mem.eql(u8, arg, "--write-period")) {
            const v = it.next() orelse return error.MissingValue;
            opts.write_period_ms = std.fmt.parseInt(u64, v, 10) catch 33;
        } else if (std.mem.eql(u8, arg, "--read-period")) {
            const v = it.next() orelse return error.MissingValue;
            opts.read_period_ms = std.fmt.parseInt(u64, v, 10) catch 100;
        } else if (std.mem.eql(u8, arg, "--num-iterations") or
            std.mem.eql(u8, arg, "-i"))
        {
            const v = it.next() orelse return error.MissingValue;
            opts.num_iterations = std.fmt.parseInt(i64, v, 10) catch -1;
        } else if (std.mem.eql(u8, arg, "--additional-payload") or
            std.mem.eql(u8, arg, "--additional-payload-size"))
        {
            const v = it.next() orelse return error.MissingValue;
            opts.additional_payload = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--size-modulo")) {
            const v = it.next() orelse return error.MissingValue;
            opts.size_modulo = std.fmt.parseInt(i32, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--cft")) {
            opts.cft_expression = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--time-filter")) {
            const v = it.next() orelse return error.MissingValue;
            opts.time_filter_ms = std.fmt.parseInt(u64, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--lifespan")) {
            const v = it.next() orelse return error.MissingValue;
            opts.lifespan_ms = std.fmt.parseInt(u64, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--final-instance-state")) {
            const v = it.next() orelse return error.MissingValue;
            opts.final_instance_state = if (v.len > 0) v[0] else 0;
        } else if (std.mem.eql(u8, arg, "--access-scope")) {
            const v = it.next() orelse return error.MissingValue;
            opts.access_scope = if (v.len > 0) v[0] else 'i';
        } else if (std.mem.eql(u8, arg, "--ordered")) {
            opts.ordered_access = true;
        } else if (std.mem.eql(u8, arg, "--coherent")) {
            opts.coherent_access = true;
        } else if (std.mem.eql(u8, arg, "--num-topics")) {
            const v = it.next() orelse return error.MissingValue;
            opts.num_topics = std.fmt.parseInt(u32, v, 10) catch 1;
        } else if (std.mem.eql(u8, arg, "--take-read")) {
            opts.take_read = true;
        } else if (std.mem.eql(u8, arg, "--coherent-sample-count")) {
            const v = it.next() orelse return error.MissingValue;
            opts.coherent_sample_count = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--periodic-announcement")) {
            const v = it.next() orelse return error.MissingValue;
            opts.periodic_announcement_ms = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--config")) {
            opts.config_path = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--publisher-matches") or
            std.mem.eql(u8, arg, "--subscriber-matches"))
        {
            // consume argument value and ignore — unimplemented options; no reference
            // implementation elsewhere in this repo defines their semantics and no
            // interop test exercises them.
            _ = it.next();
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            stdoutWrite(
                \\Usage: shape_main -P|-S [options]
                \\
                \\Mode (required):
                \\  -P                  Publisher
                \\  -S                  Subscriber
                \\
                \\QoS:
                \\  -b                  BEST_EFFORT reliability (default: RELIABLE)
                \\  -r                  RELIABLE reliability (explicit)
                \\  -k <depth>          History depth; 0 = KEEP_ALL (default: KEEP_LAST 1)
                \\  -D v|l|t|p          Durability: volatile, transient-local, transient, persistent
                \\  -f, --deadline <ms> Deadline period in milliseconds
                \\  --lifespan <ms>     Sample lifespan in milliseconds (writer only; 0 = infinite)
                \\  -s <strength>       Ownership strength (enables EXCLUSIVE ownership)
                \\  -x 1|2              Data representation: 1=XCDR1 (default), 2=XCDR2
                \\  -p <name>           Partition name
                \\
                \\Topic / data:
                \\  -t <name>           Topic name (default: Square)
                \\  -c <color>          Color / key value (default: BLUE)
                \\  -z <size>           Shape size; 0 = auto-increment each sample (default: 20)
                \\  -n <count>          Number of instances to publish (default: 1)
                \\  --num-topics <n>    Number of topics (Square, Square1, Square2, ...) (default: 1)
                \\  --additional-payload <bytes>  Extra zero bytes appended to each sample
                \\  --size-modulo <n>   Cycle shapesize 1..n when -z 0 is active
                \\  --cft <expr>        Content filter expression (subscriber only)
                \\
                \\Timing / iterations:
                \\  -i, --num-iterations <n>   Stop after n samples (-1 = infinite, default)
                \\  --write-period <ms>         Publish interval in ms (default: 33)
                \\  --read-period <ms>          Read poll interval in ms (default: 100)
                \\
                \\Presentation / coherent:
                \\  --access-scope i|t|g        Presentation access scope (default: i)
                \\  --ordered                   Enable ordered access
                \\  --coherent                  Enable coherent access
                \\  --coherent-sample-count <n> Samples per coherent set (0 = no gating)
                \\  --take-read                 Use take() instead of take_next_instance()
                \\  -R                          Use read() instead of take() (non-destructive)
                \\
                \\Other:
                \\  -d <id>             Domain ID (default: 0)
                \\  -w                  Print each sample on the writer side
                \\  --periodic-announcement <ms>  SPDP participant re-announcement period
                \\                                (0 = use zzdds's own default)
                \\  --config <path>     Load a zzdds.toml-style config file as the process-wide
                \\                      default participant config before creating the factory
                \\                      (see zzdds-examples/config/ for example scenarios)
                \\  -h, --help          Show this help and exit
                \\
                \\Environment variables:
                \\  SHAPE_STARTUP_DELAY_MS=<ms>   Sleep before creating the DDS participant.
                \\
            );
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "--") or std.mem.startsWith(u8, arg, "-")) {
            std.log.warn("unrecognised option: {s}", .{arg});
        }
    }

    // Publisher default color
    if (opts.publish and opts.color == null) {
        opts.color = "BLUE";
    }

    return opts;
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    if (std.c.getenv("SHAPE_STARTUP_DELAY_MS")) |v| {
        const ms = std.fmt.parseInt(u64, std.mem.span(v), 10) catch 0;
        if (ms > 0) sleepNs(io, ms * std.time.ns_per_ms);
    }

    const opts = parseArgs(init.minimal.args) catch |err| {
        std.log.err("argument error: {}", .{err});
        std.process.exit(1);
    };

    if (!opts.publish and !opts.subscribe) {
        std.log.err("specify -P (publish) or -S (subscribe)", .{});
        std.process.exit(1);
    }

    if (opts.num_topics < 1 or opts.num_topics > MAX_TOPICS) {
        std.log.err("--num-topics must be between 1 and {d} (got {d})", .{ MAX_TOPICS, opts.num_topics });
        std.process.exit(1);
    }

    if (opts.periodic_announcement_ms > 0) {
        var buf: [16]u8 = undefined;
        const val = std.fmt.bufPrintZ(&buf, "{d}", .{opts.periodic_announcement_ms}) catch unreachable;
        _ = setenv("ZZDDS_PARTICIPANT_ANNOUNCEMENT_PERIOD_MS", val, 1);
    }

    // Must run before the first factory is created in this process (i.e.
    // before dds.createParticipant() below) -- see dds_impl.zig's
    // configureFromFile doc comment. Deliberately std.heap.c_allocator, not
    // `alloc` (this program's own DebugAllocator): the resolved config
    // becomes a process-wide singleton with no matching "destroy" call --
    // by design, it's meant to outlive this run's own alloc/dealloc
    // discipline (same allocator zzdds's own ambient/lazy fallback path
    // already uses for the same reason) -- routing it through `alloc`
    // instead would report as a leak at gpa.deinit() below, even though
    // nothing was actually lost.
    if (opts.config_path) |path| {
        dds.configureFromFile(std.heap.c_allocator, path) catch |err| {
            std.log.err("failed to load config file '{s}': {}", .{ path, err });
            std.process.exit(1);
        };
    }

    const participant = dds.createParticipant(alloc, opts.domain_id) catch |err| {
        std.log.err("failed to create participant on domain {d}: {}", .{ opts.domain_id, err });
        std.process.exit(1);
    };
    defer dds.destroyParticipant(participant);
    const dp = participant.toDDS();

    // computeKeyHashFromCdr/getFieldFromCdr's ctx is a *const std.mem.Allocator
    // (zidl's Zig backend keeps the rest of the runtime's explicit-allocator
    // idiom rather than the C backend's global-allocator-override equivalent)
    // -- used for any variable-length fields either needs to allocate.
    // Setting get_field here is what makes zzdds's own reader-side cft_filter
    // (see reader.zig) activate automatically for ContentFilteredTopic-backed
    // readers -- no app-side re-check needed (contrast with this file's
    // history: it used to hand-call dds.cftMatchSample per received sample
    // because nothing ever set get_field; see zzdds's docs/roadmap.md).
    var ts_alloc = alloc;
    if (!dds.registerTypeSupport(dp, "ShapeType", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = shape_gen.ShapeType.computeKeyHashFromCdr,
        .get_field = shape_gen.ShapeType.getFieldFromCdr,
    })) {
        std.log.err("registerTypeSupport() failed", .{});
        std.process.exit(1);
    }

    // Create the base topic (index 0). Additional topics are created inside run functions.
    const base_topic = dp.create_topic(
        opts.topic_name,
        "ShapeType",
        .{},
        null,
        0,
    );
    if (isNilTopic(base_topic)) {
        std.log.err("failed to create topic '{s}'", .{opts.topic_name});
        std.process.exit(1);
    }

    stdoutPrint("Create topic: {s}\n", .{opts.topic_name});

    if (opts.publish) {
        runPublisher(io, alloc, dp, base_topic, &opts) catch |err| {
            std.log.err("publisher error: {}", .{err});
            std.process.exit(1);
        };
    } else {
        runSubscriber(io, alloc, dp, base_topic, &opts) catch |err| {
            std.log.err("subscriber error: {}", .{err});
            std.process.exit(1);
        };
    }
}
