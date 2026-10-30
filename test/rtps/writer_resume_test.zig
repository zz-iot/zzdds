//! A StatefulWriter whose sends would block holds the reader and resumes it
//! once the transport's output is ready
//! (docs/design/concurrency/transport-adapters.md#output-submission).
//!
//! A scripted transport reports would-block on demand and keeps the writer's
//! waiter until the test drains it; the writer runs on a manual runtime over
//! the scripted backend, so its resume runs only when the test drives it.

const std = @import("std");
const zzdds = @import("zzdds");

const rtps = zzdds.rtps;
const msg = rtps.message;
const rt = zzdds.runtime;
const transport = zzdds.transport;

const StatefulWriter = rtps.StatefulWriter;
const ReaderProxy = rtps.ReaderProxy;
const ReaderMatch = rtps.ReaderMatch;
const Guid = rtps.Guid;
const SequenceNumber = rtps.SequenceNumber;
const Locator = rtps.Locator;
const InstanceHandle = rtps.InstanceHandle;
const MessageIterator = msg.MessageIterator;
const InlineQosParam = msg.InlineQosParam;
const Transport = transport.Transport;
const IoVec = transport.IoVec;
const SendOutcome = transport.SendOutcome;
const WritableWaiter = transport.WritableWaiter;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;

const testing = std.testing;
const alloc = testing.allocator;

const ZERO_TS: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
const NIL_IH = std.mem.zeroes(InstanceHandle);
const NIL_KH = std.mem.zeroes([16]u8);
const WRITER_EID = rtps.EntityIds.sedp_builtin_publications_writer;
const READER_EID = rtps.EntityIds.sedp_builtin_publications_reader;

const PORT_A: u16 = 7100;
const PORT_B: u16 = 7200;

fn makeGuid(prefix_byte: u8) Guid {
    return .{ .prefix = .{ .bytes = @as([12]u8, @splat(prefix_byte)) }, .entity_id = READER_EID };
}

// ── Scripted transport ────────────────────────────────────────────────────────

/// Records the DATA and DATA_FRAG each port is sent and reports would-block
/// while full, for every port or one. Keeps the writer's waiter until
/// `drain`, as a socket that has yet to drain would.
const Outbox = struct {
    /// Sends would block: to every port, or only to `full_port`.
    full: bool = false,
    full_port: ?u16 = null,
    /// Once drained, this many DATA sends complete before it is full again.
    refill_after: ?usize = null,
    /// Sends carrying DATA of this SN would block, until `drain`.
    full_at_sn: ?SequenceNumber = null,
    /// Once, in the next DATA send, before it completes: runs `run`, as
    /// another thread can while the send runs with the writer's lock
    /// released. Then the send would block if `then_full`.
    during_send: ?struct { ctx: *anyopaque, run: *const fn (ctx: *anyopaque) anyerror!void, then_full: bool = false } = null,
    /// Per send: the port, and the SN of each DATA or DATA_FRAG in it.
    sent: std.ArrayListUnmanaged(Sent) = .empty,
    blocked: usize = 0,
    waiter: ?*WritableWaiter = null,
    cancels: usize = 0,
    notifies: bool = true,
    /// Every port's connection generation: raising it is a reconnect.
    generation: u32 = 0,

    /// `frag`: the DATA_FRAG's fragment number; 0 for DATA.
    const Sent = struct { port: u16, sn: SequenceNumber, frag: u32 = 0 };

    fn deinit(self: *Outbox) void {
        self.sent.deinit(alloc);
    }

    fn makeTransport(self: *Outbox) Transport {
        return .{ .ctx = self, .vtable = if (self.notifies) &vtable else &vtable_no_notify };
    }

    /// The output is ready: the waiter runs, as the transport would run it.
    fn drain(self: *Outbox) void {
        self.full = false;
        self.full_port = null;
        self.full_at_sn = null;
        if (self.waiter) |w| {
            self.waiter = null;
            w.on_writable(w);
        }
    }

    /// The SNs of DATA (a DATA_FRAG run counted once) sent to `port`, in order.
    fn sns(self: *const Outbox, port: u16, buf: []SequenceNumber) []SequenceNumber {
        var n: usize = 0;
        for (self.sent.items) |s| {
            if (s.port != port) continue;
            if (s.frag > 0 and n > 0 and buf[n - 1] == s.sn) continue;
            buf[n] = s.sn;
            n += 1;
        }
        return buf[0..n];
    }

    fn of(ctx: *anyopaque) *Outbox {
        return @ptrCast(@alignCast(ctx));
    }

    fn sendGather(ctx: *anyopaque, loc: *const Locator, iovecs: []const IoVec) anyerror!SendOutcome {
        const self = of(ctx);
        const port: u16 = @intCast(loc.udp_v4.port);
        var buf: [Transport.max_flattened_send]u8 = undefined;
        var len: usize = 0;
        for (iovecs) |iov| {
            @memcpy(buf[len..][0..iov.len], iov.base[0..iov.len]);
            len += iov.len;
        }
        var datas: [8]Sent = undefined;
        var n: usize = 0;
        var it = try MessageIterator.init(buf[0..len]);
        var params: [32]InlineQosParam = undefined;
        while (try it.next(&params)) |sm| switch (sm) {
            .data => |d| {
                datas[n] = .{ .port = port, .sn = d.writer_sn };
                n += 1;
            },
            .data_frag => |df| {
                datas[n] = .{ .port = port, .sn = df.writer_sn, .frag = df.fragment_starting_num };
                n += 1;
            },
            else => {},
        };
        if (n > 0) if (self.during_send) |d| {
            self.during_send = null;
            try d.run(d.ctx);
            if (d.then_full) self.full = true;
        };
        if (self.full_at_sn) |sn| for (datas[0..n]) |d| {
            if (d.sn == sn) {
                self.blocked += 1;
                return .would_block;
            }
        };
        if (self.full and (self.full_port == null or self.full_port == port)) {
            self.blocked += 1;
            return .would_block;
        }
        if (n > 0) if (self.refill_after) |*left| {
            if (left.* == 0) {
                self.full = true;
                self.refill_after = null;
                self.blocked += 1;
                return .would_block;
            }
            left.* -= 1;
        };
        try self.sent.appendSlice(alloc, datas[0..n]);
        return .completed;
    }

    fn send(ctx: *anyopaque, loc: *const Locator, data: []const u8) anyerror!void {
        const iov = [_]IoVec{.{ .base = data.ptr, .len = data.len }};
        if (try sendGather(ctx, loc, &iov) == .would_block) return error.WouldBlock;
    }

    fn notifyWritable(ctx: *anyopaque, w: *WritableWaiter) void {
        const self = of(ctx);
        if (!self.full) return w.on_writable(w);
        self.waiter = w;
    }

    fn cancelWritable(ctx: *anyopaque, w: *WritableWaiter) void {
        const self = of(ctx);
        if (self.waiter == w) self.waiter = null;
        self.cancels += 1;
    }

    fn connectionGeneration(ctx: *anyopaque, _: *const Locator) u32 {
        return of(ctx).generation;
    }

    fn canReach(_: *anyopaque, _: *const Locator) bool {
        return true;
    }
    fn listen(_: *anyopaque, _: *const Locator, _: transport.ReceiveHandler) anyerror!void {}
    fn joinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {}
    fn leaveMulticast(_: *anyopaque, _: *const Locator) void {}
    fn unlisten(_: *anyopaque, _: *const Locator, _: transport.ReceiveHandler) void {}
    fn unicastLocators(_: *anyopaque, out: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {
        out.clearRetainingCapacity();
    }
    fn setLocatorChangeHandler(_: *anyopaque, _: ?transport.LocatorChangeHandler) void {}
    fn close(_: *anyopaque) void {}

    const vtable: Transport.Vtable = .{
        .capabilities = .{},
        .can_reach = canReach,
        .send = send,
        .send_gather = sendGather,
        .notify_writable = notifyWritable,
        .cancel_writable = cancelWritable,
        .listen = listen,
        .join_multicast = joinMulticast,
        .leave_multicast = leaveMulticast,
        .unlisten = unlisten,
        .unicast_locators = unicastLocators,
        .set_locator_change_handler = setLocatorChangeHandler,
        .close = close,
        .connection_generation = connectionGeneration,
    };

    const vtable_no_notify: Transport.Vtable = blk: {
        var v = vtable;
        v.notify_writable = null;
        v.cancel_writable = null;
        break :blk v;
    };
};

// ── Fixture ───────────────────────────────────────────────────────────────────

/// A writer on a manual runtime, KEEP_ALL unless set, sending into an Outbox.
const Fixture = struct {
    outbox: Outbox = .{},
    sb: rt.ScriptedBackend,
    runtime: rt.Runtime,
    w: *StatefulWriter,

    const Options = struct {
        replay_on_match: bool = false,
        frag_size: u16 = rtps.writer_sm.DEFAULT_FRAG_SIZE,
        notifies: bool = true,
        history: rtps.history.HistoryKind = .keep_all,
        depth: u32 = 0,
    };

    fn init(self: *Fixture, opts: Options) !void {
        self.* = .{ .sb = rt.ScriptedBackend.init(1_000), .runtime = undefined, .w = undefined };
        self.outbox.notifies = opts.notifies;
        self.runtime = rt.Runtime.init(self.sb.clock(), self.sb.backend(), .{ .mode = .manual });
        self.w = try StatefulWriter.init(alloc, .{
            .prefix = .{ .bytes = @as([12]u8, @splat(0x52)) },
            .entity_id = WRITER_EID,
        }, self.outbox.makeTransport(), opts.history, opts.depth, READER_EID, opts.frag_size, opts.replay_on_match);
        self.w.attachRuntime(&self.runtime);
    }

    fn deinit(self: *Fixture) void {
        self.w.stopHeartbeat();
        self.w.deinit();
        self.runtime.releaseOwner();
        while (self.runtime.getState() != .backend_stopped) _ = self.runtime.drive(64, 0) catch break;
        self.runtime.deinit();
        self.outbox.deinit();
    }

    fn match(self: *Fixture, guid: Guid, port: u16, reliable: bool) !void {
        const rp = try ReaderProxy.init(alloc, guid, &.{Locator.udp4(.{ 127, 0, 0, 1 }, port)}, &.{}, false, reliable);
        try self.w.addMatchedReader(rp);
    }

    fn write(self: *Fixture, n: usize) !void {
        for (0..n) |_| _ = try self.w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "sample");
    }

    /// Runs what is ready now, without letting the clock reach a heartbeat.
    fn run(self: *Fixture) !void {
        while ((try self.runtime.drive(64, 0)).turns > 0) {}
    }

    /// Writes one sample during the next DATA send (Outbox.during_send).
    fn writeDuringSend(self: *Fixture, then_full: bool) void {
        self.outbox.during_send = .{ .ctx = self, .run = writeOne, .then_full = then_full };
    }

    fn writeOne(ctx: *anyopaque) anyerror!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        try self.write(1);
    }

    /// Removes reader 0xa1 and matches it again on PORT_A (Outbox.during_send).
    fn rematchA(ctx: *anyopaque) anyerror!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        self.w.removeMatchedReader(makeGuid(0xa1));
        try self.match(makeGuid(0xa1), PORT_A, false);
    }

    fn matchOf(self: *Fixture, guid: Guid) ?ReaderMatch {
        self.w.mu.lock();
        defer self.w.mu.unlock();
        for (self.w.reader_proxies.items) |rp| if (rp.guid.eql(guid)) return rp.match();
        return null;
    }

    fn held(self: *Fixture, guid: Guid) ?SequenceNumber {
        self.w.mu.lock();
        defer self.w.mu.unlock();
        for (self.w.reader_proxies.items) |rp| if (rp.guid.eql(guid)) return rp.unsent_from_sn;
        return null;
    }
};

fn expectSns(expected: []const SequenceNumber, outbox: *const Outbox, port: u16) !void {
    var buf: [256]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, expected, outbox.sns(port, &buf));
}

fn range(comptime first: SequenceNumber, comptime last: SequenceNumber) [last - first + 1]SequenceNumber {
    var out: [last - first + 1]SequenceNumber = undefined;
    for (&out, first..) |*v, sn| v.* = @intCast(sn);
    return out;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "a reader whose DATA would block is held, sent nothing live meanwhile, then sent every sample in order" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    f.outbox.full = true;
    try f.write(5);
    // Only the first send was tried: the rest waited behind it.
    try testing.expectEqual(@as(usize, 1), f.outbox.blocked);
    try testing.expectEqual(@as(?SequenceNumber, 1), f.held(a));
    try testing.expect(f.outbox.waiter != null);
    try f.run();
    try expectSns(&.{}, &f.outbox, PORT_A);

    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 5), &f.outbox, PORT_A);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));

    // No longer held: live data goes out at once again.
    try f.write(1);
    try expectSns(&range(1, 6), &f.outbox, PORT_A);
}

test "a held reader does not hold up another reader" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    const b = makeGuid(0xb1);
    try f.match(a, PORT_A, false);
    try f.match(b, PORT_B, false);

    f.outbox.full = true;
    f.outbox.full_port = PORT_A;
    try f.write(3);
    try expectSns(&range(1, 3), &f.outbox, PORT_B);
    try expectSns(&.{}, &f.outbox, PORT_A);

    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 3), &f.outbox, PORT_A);
    try expectSns(&range(1, 3), &f.outbox, PORT_B);
}

test "a resume whose send would block again keeps the reader held and waits again" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    f.outbox.full = true;
    try f.write(4);
    f.outbox.refill_after = 2;
    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 2), &f.outbox, PORT_A);
    try testing.expectEqual(@as(?SequenceNumber, 3), f.held(a));
    try testing.expect(f.outbox.waiter != null);

    // Written while held: it waits behind 3 and 4.
    try f.write(1);
    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 5), &f.outbox, PORT_A);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));
}

test "a long backlog is resumed over several turns, in order" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    f.outbox.full = true;
    try f.write(150);
    f.outbox.drain();
    _ = try f.runtime.drive(1, 0);
    var buf: [256]SequenceNumber = undefined;
    const first_turn = f.outbox.sns(PORT_A, &buf).len;
    try testing.expect(first_turn > 0 and first_turn < 150);
    try f.run();
    try expectSns(&range(1, 150), &f.outbox, PORT_A);
}

test "a RELIABLE VOLATILE writer keeps the changes a held best-effort reader has yet to be sent" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    // Acknowledged changes are dropped, and with no reliable reader every
    // change is acknowledged once sent.
    f.w.drop_acked = true;
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    try f.write(2);
    try testing.expectEqual(@as(usize, 0), f.w.cache.len());
    f.outbox.full = true;
    try f.write(3);
    try testing.expectEqual(@as(usize, 3), f.w.cache.len());

    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 5), &f.outbox, PORT_A);
    try testing.expectEqual(@as(usize, 0), f.w.cache.len());
}

test "a fragmented sample's resume carries on from the fragment that would block, though output drains a fragment at a time" {
    var f: Fixture = undefined;
    try f.init(.{ .frag_size = 64 });
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    f.outbox.full = true;
    _ = try f.w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, &(@as([200]u8, @splat(7))));
    try testing.expectEqual(@as(?SequenceNumber, 1), f.held(a));
    // Each time output is ready it takes one fragment of four. Sent again
    // from the start each time, the sample would never be sent whole.
    for (0..4) |_| {
        f.outbox.refill_after = 1;
        f.outbox.drain();
        try f.run();
    }
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));
    var frags: [8]u32 = undefined;
    var n: usize = 0;
    for (f.outbox.sent.items) |sent| if (sent.sn == 1) {
        frags[n] = sent.frag;
        n += 1;
    };
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, frags[0..n]);
}

test "a write while another write's send is under way does not overtake it, and keeps its change if that send would block" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    // Acknowledged changes are dropped, and with no reliable reader every
    // change is acknowledged once sent.
    f.w.drop_acked = true;
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    // SN 2 is written while SN 1's send runs, which then would block.
    f.writeDuringSend(true);
    try f.write(1);
    try testing.expectEqual(@as(?SequenceNumber, 1), f.held(a));
    try expectSns(&.{}, &f.outbox, PORT_A);
    try testing.expectEqual(@as(usize, 2), f.w.cache.len());

    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 2), &f.outbox, PORT_A);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));
}

test "a write while another write's send is under way is sent after it once that send completes" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    f.writeDuringSend(false);
    try f.write(1);
    try expectSns(&.{1}, &f.outbox, PORT_A);
    try f.run();
    try expectSns(&range(1, 2), &f.outbox, PORT_A);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));
}

test "a resume leaves a reader alone while a live send to it is under way" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    const b = makeGuid(0xb1);
    try f.match(a, PORT_A, false);
    try f.match(b, PORT_B, false);
    // `b` is held from SN 1, waiting for output.
    f.outbox.full = true;
    f.outbox.full_port = PORT_B;
    try f.write(1);
    try testing.expectEqual(@as(?SequenceNumber, 1), f.held(b));

    // While SN 2 is being sent to `a`: SN 3 is written, which waits for that
    // send, and output becomes ready, so the writer resumes.
    const During = struct {
        fn run(ctx: *anyopaque) anyerror!void {
            const fx: *Fixture = @ptrCast(@alignCast(ctx));
            try fx.write(1);
            fx.outbox.drain();
            try fx.run();
        }
    };
    f.outbox.during_send = .{ .ctx = &f, .run = During.run };
    try f.write(1);
    try f.run();
    try expectSns(&range(1, 3), &f.outbox, PORT_A);
    try expectSns(&range(1, 3), &f.outbox, PORT_B);
}

test "an end marker whose send would block holds the reader, which is sent it once output is ready" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    f.outbox.full_at_sn = 3;
    f.w.beginCoherentSet(true);
    try f.write(2);
    f.w.endCoherentSet(.coherent_only, false, null, null, false);
    try expectSns(&range(1, 2), &f.outbox, PORT_A);
    try testing.expectEqual(@as(?SequenceNumber, 3), f.held(a));

    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 3), &f.outbox, PORT_A);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));
}

test "a reader the publisher's combined end-marker send could not reach is held, and sent the marker once output is ready" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    const b = makeGuid(0xb1);
    try f.match(a, PORT_A, false);
    try f.match(b, PORT_B, false);

    // The marker (SN 2) is the publisher's to send; its send reached `b`
    // but would have blocked for `a`.
    f.w.beginCoherentSet(true);
    try f.write(1);
    f.w.endCoherentSet(.coherent_only, false, null, null, true);
    try testing.expectEqual(@as(?SequenceNumber, 2), f.w.pending_eoc_sn);
    f.outbox.full_port = PORT_A;
    f.outbox.full = true;
    f.w.flushGroupEOCHBOnly(&.{f.matchOf(a).?});
    try testing.expectEqual(@as(?SequenceNumber, 2), f.held(a));
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(b));

    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 2), &f.outbox, PORT_A);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));
}

test "a send that ends after its reader was matched again leaves the new match alone" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    // While SN 1 goes out, `a` is removed and matched again; then the send
    // would block. That held up the old match, not the new one, which
    // matched after SN 1 and is sent only what follows.
    f.outbox.during_send = .{ .ctx = &f, .run = Fixture.rematchA, .then_full = true };
    try f.write(1);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));

    f.outbox.drain();
    try f.run();
    try f.write(1);
    try expectSns(&.{2}, &f.outbox, PORT_A);
}

test "a history replay that ends after its reader was matched again leaves the new match alone" {
    var f: Fixture = undefined;
    try f.init(.{ .replay_on_match = true });
    defer f.deinit();
    try f.write(3);
    const a = makeGuid(0xa1);

    // While the replay sends SN 1, `a` is removed and matched again, and
    // the new match's own replay sends it 1 to 3; then the first replay's
    // send would block. The new match has its history: it is not held.
    f.outbox.during_send = .{ .ctx = &f, .run = Fixture.rematchA, .then_full = true };
    try f.match(a, PORT_A, false);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));

    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 3), &f.outbox, PORT_A);
}

test "a reader matched again before the combined end-marker flush is not held for its old match" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    f.w.beginCoherentSet(true);
    try f.write(1);
    f.w.endCoherentSet(.coherent_only, false, null, null, true);
    // The combined send could not reach `a`, which is then matched again.
    const old = f.matchOf(a).?;
    try Fixture.rematchA(&f);
    f.outbox.full = true;
    f.w.flushGroupEOCHBOnly(&.{old});
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));
}

test "a best-effort history replay whose send would block is finished by the resume, ahead of live data" {
    var f: Fixture = undefined;
    try f.init(.{ .replay_on_match = true });
    defer f.deinit();
    try f.write(3);
    const a = makeGuid(0xa1);
    f.outbox.full = true;
    try f.match(a, PORT_A, false);
    try testing.expectEqual(@as(?SequenceNumber, 1), f.held(a));

    try f.write(1);
    try expectSns(&.{}, &f.outbox, PORT_A);
    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 4), &f.outbox, PORT_A);
}

test "a reconnect's history replay whose send would block is finished by the resume, ahead of live data" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);
    try f.write(3);

    // The reader's connection is new, and its sends would block (as while
    // a dial is in progress): the history goes out once output is ready.
    f.outbox.generation = 1;
    f.outbox.full = true;
    f.w.checkConnectionGenerations();
    try testing.expectEqual(@as(?SequenceNumber, 1), f.held(a));

    try f.write(1);
    f.outbox.drain();
    try f.run();
    try expectSns(&.{ 1, 2, 3, 1, 2, 3, 4 }, &f.outbox, PORT_A);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));
}

test "a coherent set's end marker reaches a held reader after the set" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    // Held by SN 1; the set {2, 3} is written meanwhile.
    f.outbox.full = true;
    try f.write(1);
    f.w.beginCoherentSet(true);
    try f.write(2);
    // The socket can take output again, but the reader is held until its
    // resume runs: the set's samples and its marker (SN 4) wait for it.
    f.outbox.full = false;
    f.w.endCoherentSet(.coherent_only, false, null, null, false);
    try expectSns(&.{}, &f.outbox, PORT_A);
    f.outbox.full = true;
    f.outbox.drain();
    try f.run();
    try expectSns(&range(1, 4), &f.outbox, PORT_A);
}

test "an end marker a held reader is still to be sent stays, though its set has left the history" {
    var f: Fixture = undefined;
    try f.init(.{ .history = .keep_last, .depth = 1 });
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    // {1} + marker 2 is held when its end sends 1; then {3} + marker 4:
    // writing 3 evicts 1, so the first set has left the history when the
    // second ends.
    f.outbox.full = true;
    f.w.beginCoherentSet(true);
    try f.write(1);
    f.w.endCoherentSet(.coherent_only, false, null, null, false);
    try testing.expectEqual(@as(?SequenceNumber, 1), f.held(a));
    f.w.beginCoherentSet(true);
    try f.write(1);
    f.w.endCoherentSet(.coherent_only, false, null, null, false);
    f.outbox.drain();
    try f.run();
    try expectSns(&.{ 2, 3, 4 }, &f.outbox, PORT_A);
}

test "an end marker a history replay is sending stays, though another write retires its set meanwhile" {
    var f: Fixture = undefined;
    try f.init(.{ .replay_on_match = true, .history = .keep_last, .depth = 1 });
    defer f.deinit();
    // {1} + marker 2, before any reader.
    f.w.beginCoherentSet(true);
    try f.write(1);
    f.w.endCoherentSet(.coherent_only, false, null, null, false);

    // While the replay sends 1 and the marker: {3} + marker 4 is written,
    // which evicts 1, so the first set has left the history; then the
    // replay's send would block.
    const During = struct {
        fn run(ctx: *anyopaque) anyerror!void {
            const fx: *Fixture = @ptrCast(@alignCast(ctx));
            fx.w.beginCoherentSet(true);
            try fx.write(1);
            fx.w.endCoherentSet(.coherent_only, false, null, null, false);
        }
    };
    f.outbox.during_send = .{ .ctx = &f, .run = During.run, .then_full = true };
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);
    try testing.expectEqual(@as(?SequenceNumber, 1), f.held(a));

    f.outbox.drain();
    try f.run();
    try expectSns(&.{ 2, 3, 4 }, &f.outbox, PORT_A);
}

test "stopping the writer cancels its wait for output" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);
    f.outbox.full = true;
    try f.write(1);
    try testing.expect(f.outbox.waiter != null);

    f.w.stopHeartbeat();
    try testing.expect(f.outbox.waiter == null);
    try testing.expectEqual(@as(usize, 1), f.outbox.cancels);
}

test "without writability from the transport, a send that would block is lost and the reader is not held" {
    var f: Fixture = undefined;
    try f.init(.{ .notifies = false });
    defer f.deinit();
    const a = makeGuid(0xa1);
    try f.match(a, PORT_A, false);

    f.outbox.full = true;
    try f.write(2);
    try testing.expectEqual(@as(usize, 2), f.outbox.blocked);
    try testing.expectEqual(@as(?SequenceNumber, null), f.held(a));
    f.outbox.full = false;
    try f.write(1);
    try f.run();
    try expectSns(&.{3}, &f.outbox, PORT_A);
}
