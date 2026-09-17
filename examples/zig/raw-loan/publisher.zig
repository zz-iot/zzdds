//! zig/raw-loan -- publisher.
//!
//! Raw/loaned DataWriter reference app, talking to zzdds's native Zig API
//! directly. See docs/design/raw-loan-reference-app.md at the repo root for
//! the full spec. Bypasses TypeSupport marshaling entirely: every published
//! sample goes through `loan_raw()` (borrow a buffer sized for the real CDR
//! payload) -> serialize directly into it -> `publish_loan_raw()`, instead
//! of the typed `DataWriter.write()` a normal example would use. Also
//! demonstrates the cancel path -- `loan_raw()` then `return_loan_raw()`
//! without ever publishing -- once, so the subscriber has a genuine negative
//! to assert against (that sequence number must never arrive).
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! writer for topic:", "Publisher: published (loan) sequence=", "Publisher:
//! cancelling loan for sequence=", "Publisher: done." Any failure path
//! prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const zidl_rt = @import("zidl_rt");
const loaned_ping_gen = @import("loaned_ping_gen");

const SAMPLE_COUNT: i32 = 5;
const CANCELLED_SEQ_NUM: i32 = -1;
const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

// ── Time helpers (std.Io.Clock -- portable across Linux/macOS/Windows) ──────

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// ── Listener state, shared between the network thread (callbacks) and main ──

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

// ── Raw-loan CDR helpers ─────────────────────────────────────────────────────

/// Serialize `value` into a fresh, owned buffer. The caller frees it. This
/// mirrors what the generated typed `write()` wrapper does internally
/// (`loaned_ping_gen.LoanedPingDataWriter.write`) -- zidl-rt's `CdrWriter`
/// is always `std.ArrayList`-backed (dynamic growth), so there's no way yet
/// to serialize directly into the fixed buffer `loan_raw()` hands back the
/// way C's `zidl_cdr_writer_init_fixed` can (see the spec doc's "Zig-specific
/// caveat" section) -- a real, discovered gap in zidl-rt today, not an
/// oversight in this example. The bytes still end up published via the real
/// `loan_raw`/`publish_loan_raw` ops below, just via one extra memcpy.
fn serializeToOwnedBuffer(alloc: std.mem.Allocator, xcdr2: bool, value: loaned_ping_gen.LoanedPing) !std.ArrayList(u8) {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    if (xcdr2) {
        var w = zidl_rt.CdrWriter(.xcdr2).init(&buf, alloc);
        try w.writeEncapHeaderDelimited();
        try loaned_ping_gen.LoanedPing.serialize(&w, value);
    } else {
        var w = zidl_rt.CdrWriter(.xcdr1).init(&buf, alloc);
        try w.writeEncapHeader();
        try loaned_ping_gen.LoanedPing.serialize(&w, value);
    }
    return buf;
}

/// Publish one sample via the real write-loan path: loan_raw(size) ->
/// memcpy the serialized bytes in -> publish_loan_raw. Returns an error on
/// any non-OK return code from either call.
fn publishLoaned(dw: DDS.DataWriter, alloc: std.mem.Allocator, xcdr2: bool, value: loaned_ping_gen.LoanedPing) !void {
    var buf = try serializeToOwnedBuffer(alloc, xcdr2, value);
    defer buf.deinit(alloc);

    var cdr_payload = DDS.OctetSeq{};
    if (dw.loan_raw(@intCast(buf.items.len), &cdr_payload) != DDS.RETCODE_OK) return error.LoanFailed;
    @memcpy(cdr_payload._buffer.?[0..buf.items.len], buf.items);

    var key_hash_bytes = loaned_ping_gen.LoanedPing.computeKeyHash(&value);
    const key_hash = DDS.OctetSeq{ ._buffer = &key_hash_bytes, ._length = 16, ._maximum = 16, ._release = false };

    if (dw.publish_loan_raw(&cdr_payload, &key_hash, DDS.HANDLE_NIL, .ALIVE_WRITE_KIND) != DDS.RETCODE_OK) return error.PublishFailed;
}

/// Loan a buffer, serialize a sample into it, then explicitly cancel the
/// loan instead of publishing -- the write-side analog of the read side's
/// "borrow, inspect, release without consuming" pattern. Proves
/// `return_loan_raw()` genuinely prevents the sample from ever reaching the
/// wire (the subscriber must never see `CANCELLED_SEQ_NUM`).
fn loanAndCancel(dw: DDS.DataWriter, alloc: std.mem.Allocator, xcdr2: bool, value: loaned_ping_gen.LoanedPing) !void {
    var buf = try serializeToOwnedBuffer(alloc, xcdr2, value);
    defer buf.deinit(alloc);

    var cdr_payload = DDS.OctetSeq{};
    if (dw.loan_raw(@intCast(buf.items.len), &cdr_payload) != DDS.RETCODE_OK) return error.LoanFailed;
    @memcpy(cdr_payload._buffer.?[0..buf.items.len], buf.items);

    if (dw.return_loan_raw(&cdr_payload) != DDS.RETCODE_OK) return error.ReturnLoanFailed;
}

// ── Argument parsing ─────────────────────────────────────────────────────────

fn parseDomain(process_args: std.process.Args) u32 {
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            const v = it.next() orelse continue;
            return std.fmt.parseInt(u32, v, 10) catch 0;
        }
    }
    return 0;
}

// ── main ──────────────────────────────────────────────────────────────────────

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
    if (!zzdds.registerTypeSupport(dp, "LoanedPing", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = loaned_ping_gen.LoanedPing.computeKeyHashFromCdr,
        .compute_key_hash_key_only = loaned_ping_gen.LoanedPing.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("LoanedPing", "LoanedPing", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: LoanedPing\n", .{});

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
    std.debug.print("Create writer for topic: LoanedPing\n", .{});

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

    const xcdr2 = zzdds.writerUsesXcdr2(dw);

    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!state.reader_ready.load(.acquire)) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    // ── Write-loan phase: publish SAMPLE_COUNT pings via loan_raw/publish_loan_raw ──
    var seq: i32 = 0;
    while (seq < SAMPLE_COUNT) : (seq += 1) {
        publishLoaned(dw, alloc, xcdr2, .{ .seq_num = seq }) catch {
            std.debug.print("FAIL: publishLoaned() failed at sequence={d}\n", .{seq});
            std.process.exit(1);
        };
        std.debug.print("Publisher: published (loan) sequence={d}\n", .{seq});
    }

    // ── Cancel phase: loan a buffer, then return it unpublished ──────────
    loanAndCancel(dw, alloc, xcdr2, .{ .seq_num = CANCELLED_SEQ_NUM }) catch {
        std.debug.print("FAIL: loanAndCancel() failed\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Publisher: cancelling loan for sequence={d} (never published)\n", .{CANCELLED_SEQ_NUM});

    // Wait for the subscriber to tear its reader down before exiting.
    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (!(state.ever_matched.load(.acquire) and state.matched_current_count.load(.acquire) == 0)) {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    // Every loan above was either published or explicitly cancelled -- an
    // outstanding loan would make delete_datawriter fail with
    // PRECONDITION_NOT_MET (see docs/design/raw-loan-api.md). Assert that
    // explicitly rather than letting delete_participant's cascade silently
    // absorb a nonzero return code.
    if (publisher.delete_datawriter(dw) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: delete_datawriter() did not return RETCODE_OK -- an outstanding loan leaked\n", .{});
        std.process.exit(1);
    }

    std.debug.print("Publisher: done.\n", .{});
}
