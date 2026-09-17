//! zig/raw-loan -- subscriber.
//!
//! Raw/loaned DataReader reference app, talking to zzdds's native Zig API
//! directly. See docs/design/raw-loan-reference-app.md at the repo root for
//! the full spec. Bypasses TypeSupport marshaling entirely: every sample is
//! read via `take_raw()` in loan mode (`cdr_payloads._maximum == 0` on
//! entry -- the returned bytes borrow directly from reader history, no
//! copy) -> deserialize straight out of the borrowed bytes ->
//! `return_loan_raw()`, instead of the typed `DataReader.take()` a normal
//! example would use. Strict ordering check doubles as the assertion that
//! the publisher's cancelled sample (see publisher.zig) never arrives: any
//! out-of-order sequence number, including the cancelled one, is a hard
//! failure.
//!
//! Required stdout markers (see the spec doc): "Create topic:", "Create
//! reader for topic:", "Subscriber: received (loan) sequence=",
//! "Subscriber: received all N samples in order." Any failure path prints
//! a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const zidl_rt = @import("zidl_rt");
const loaned_ping_gen = @import("loaned_ping_gen");

const SAMPLE_COUNT: i32 = 5;
const RECEIVE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

// ── Time helpers (std.Io.Clock -- portable across Linux/macOS/Windows) ──────

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// ── Listener state and callback ──────────────────────────────────────────────

const State = struct {
    expected_next: i32 = 0,
    all_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,
};

fn onDataAvailable(state: *State, dr: DDS.DataReader) void {
    while (true) {
        // Zero-initialized cdr_payloads has _maximum == 0 -- the spec's own
        // inout-collection convention for "loan rather than copy" (see
        // dcps.idl's take_raw doc comment). key_hashes/sample_infos are
        // always plain copies regardless of mode.
        var payloads = DDS.OctetSeqSeq{};
        var hashes = DDS.OctetSeq{};
        var infos = DDS.SampleInfoSeq{};
        const rc = dr.take_raw(&payloads, &hashes, &infos, DDS.HANDLE_NIL, zzdds.dcps.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 1);
        if (rc != DDS.RETCODE_OK) {
            std.debug.print("FAIL: take_raw() returned {d}\n", .{rc});
            std.process.exit(1);
        }
        // take_raw's own return code is RETCODE_OK even when nothing is
        // available -- check payloads._length for "did we actually get one",
        // not rc.
        if (payloads._length == 0) break;

        const desc = payloads._buffer.?[0];
        const info = infos._buffer.?[0];
        if (info.valid_data) {
            var reader = zidl_rt.CdrReader.init(desc._buffer.?[0..desc._length]) catch {
                std.debug.print("FAIL: CdrReader.init() on loaned payload failed\n", .{});
                std.process.exit(1);
            };
            var value: loaned_ping_gen.LoanedPing = .{};
            loaned_ping_gen.LoanedPing.deserializeInto(&value, &reader, state.alloc) catch {
                std.debug.print("FAIL: LoanedPing.deserializeInto() on loaned payload failed\n", .{});
                std.process.exit(1);
            };

            // Called from zzdds's own network thread; expected_next is only
            // ever touched here (single dispatch thread per reader), so no
            // lock is needed for it -- only all_received needs to be atomic,
            // since main() polls it from a different thread.
            if (value.seq_num != state.expected_next) {
                std.debug.print("FAIL: expected sequence={d} but got sequence={d}\n", .{ state.expected_next, value.seq_num });
                std.process.exit(1);
            }
            std.debug.print("Subscriber: received (loan) sequence={d}\n", .{value.seq_num});
            state.expected_next += 1;
            if (state.expected_next == SAMPLE_COUNT) {
                state.all_received.store(true, .release);
            }
        }

        if (dr.return_loan_raw(&payloads, &hashes, &infos) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: return_loan_raw() failed\n", .{});
            std.process.exit(1);
        }
    }
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

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    var state = State{ .alloc = alloc };
    const dr_listener = DDS.dataReaderListener(&state, .{
        .on_data_available = onDataAvailable,
    });

    const topic_desc = dp.lookup_topicdescription("LoanedPing");
    const dr = subscriber.create_datareader(topic_desc, dr_qos, dr_listener, DDS.DATA_AVAILABLE_STATUS);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: LoanedPing\n", .{});

    std.debug.print("Subscriber: waiting for {d} samples...\n", .{SAMPLE_COUNT});
    const deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (!state.all_received.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: only received {d}/{d} samples within 30s\n", .{ state.expected_next, SAMPLE_COUNT });
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    // Tear the reader down immediately -- the publisher is blocked waiting
    // for our matched-reader count to drop back to zero.
    _ = subscriber.delete_datareader(dr);

    std.debug.print("Subscriber: received all {d} samples in order.\n", .{SAMPLE_COUNT});
}
