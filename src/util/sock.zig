//! Socket primitives shared by the readiness backend and the UDP and TCP
//! transports: opening and closing sockets, nonblocking mode, readiness
//! polling, buffer sizes and the error of the socket call that just failed. BSD sockets on
//! POSIX; Winsock on Windows, where `std.posix` has no poll and Winsock
//! reports errors through `WSAGetLastError` rather than errno.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const log = @import("../log.zig");

const is_windows = builtin.os.tag == .windows;

pub const ws = if (is_windows) struct {
    const WSADATA = [408]u8; // ≤ 408 bytes on every Windows target; storage only
    extern "ws2_32" fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) c_int;
    pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: posix.socket_t) callconv(.winapi) c_int;
    extern "ws2_32" fn ioctlsocket(s: posix.socket_t, cmd: c_long, argp: *c_ulong) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAPoll(fds: [*]PollFd, n: c_ulong, timeout: c_int) callconv(.winapi) c_int;

    pub const WSABUF = extern struct { len: c_ulong, buf: [*]const u8 };
    pub extern "ws2_32" fn WSASendTo(
        s: posix.socket_t,
        buffers: [*]const WSABUF,
        count: u32,
        sent: *u32,
        flags: u32,
        to: *const posix.sockaddr,
        to_len: c_int,
        overlapped: ?*anyopaque,
        completion: ?*anyopaque,
    ) callconv(.winapi) c_int;
    pub extern "ws2_32" fn WSASend(
        s: posix.socket_t,
        buffers: [*]const WSABUF,
        count: u32,
        sent: *u32,
        flags: u32,
        overlapped: ?*anyopaque,
        completion: ?*anyopaque,
    ) callconv(.winapi) c_int;

    const FIONBIO: c_long = @bitCast(@as(u32, 0x8004667E));

    pub const WSAEINTR = 10004;
    pub const WSAEWOULDBLOCK = 10035;
    pub const WSAEINPROGRESS = 10036;
    pub const WSAECONNABORTED = 10053;
    pub const WSAECONNRESET = 10054;

    var started: std.atomic.Value(bool) = .init(false);
    var data: WSADATA = undefined;
} else struct {};

/// Not a socket: what `open` never returns.
pub const invalid: posix.socket_t = if (is_windows)
    @ptrFromInt(std.math.maxInt(usize)) // INVALID_SOCKET
else
    -1;

/// Winsock needs WSAStartup before any socket call. Idempotent; a race calls
/// it twice, which Winsock counts and allows.
pub fn startup() void {
    if (comptime !is_windows) return;
    if (ws.started.load(.acquire)) return;
    _ = ws.WSAStartup(0x0202, &ws.data);
    ws.started.store(true, .release);
}

pub fn open(family: u32, sock_type: u32) error{SocketCreateFailed}!posix.socket_t {
    startup();
    const fd = c.socket(@intCast(family), @intCast(sock_type), 0);
    if (fd < 0) return error.SocketCreateFailed;
    return handle(fd);
}

/// The socket a successful `socket` or `accept` returned.
pub fn handle(rc: c_int) posix.socket_t {
    if (comptime is_windows) return @ptrFromInt(@as(usize, @intCast(rc)));
    return @intCast(rc);
}

pub fn close(fd: posix.socket_t) void {
    if (comptime is_windows) {
        // Not a CRT descriptor: the CRT's close() would raise its
        // invalid-parameter handler, which can end the process.
        _ = ws.closesocket(fd);
    } else {
        _ = c.close(fd);
    }
}

/// Every call on `fd` returns at once from now on: one that would block
/// fails with `Error.would_block`.
pub fn setNonblocking(fd: posix.socket_t) error{SocketSetupFailed}!void {
    if (comptime is_windows) {
        var on: c_ulong = 1;
        if (ws.ioctlsocket(fd, ws.FIONBIO, &on) != 0) return error.SocketSetupFailed;
        return;
    }
    const fl = c.fcntl(fd, c.F.GETFL);
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    if (fl < 0 or c.fcntl(fd, c.F.SETFL, fl | nonblock) < 0) return error.SocketSetupFailed;
}

pub const Error = enum {
    would_block,
    interrupted,
    /// A nonblocking connect under way.
    in_progress,
    /// UDP: an ICMP report of an earlier send. TCP: the peer reset.
    connection_reset,
    /// A connection `accept` found was aborted before it was taken.
    connection_aborted,
    other,
};

/// The error of the socket call that just failed on this thread.
pub fn lastError() Error {
    if (comptime is_windows) return switch (ws.WSAGetLastError()) {
        // Also what a nonblocking connect reports while under way.
        ws.WSAEWOULDBLOCK => .would_block,
        ws.WSAEINTR => .interrupted,
        ws.WSAEINPROGRESS => .in_progress,
        ws.WSAECONNRESET => .connection_reset,
        ws.WSAECONNABORTED => .connection_aborted,
        else => .other,
    };
    return switch (posix.errno(@as(c_int, -1))) {
        .AGAIN => .would_block,
        .INTR => .interrupted,
        .INPROGRESS => .in_progress,
        .CONNRESET => .connection_reset,
        .CONNABORTED => .connection_aborted,
        else => .other,
    };
}

/// The OS's own code for the socket call that just failed on this thread, for
/// reporting an error `lastError` has no name for.
pub fn lastErrorCode() i32 {
    if (comptime is_windows) return ws.WSAGetLastError();
    return @backingInt(posix.errno(@as(c_int, -1)));
}

/// Whether a nonblocking connect that failed with `err` is under way.
pub fn connectPending(err: Error) bool {
    return err == .in_progress or (is_windows and err == .would_block);
}

/// One socket to poll: `posix.pollfd`, or Winsock's WSAPOLLFD.
pub const PollFd = if (is_windows) extern struct {
    fd: usize, // SOCKET
    events: i16,
    revents: i16,
} else posix.pollfd;

/// Poll events. Winsock rejects POLLPRI, so IN is only normal and band data.
pub const POLL = if (is_windows) struct {
    pub const IN: i16 = 0x0300; // POLLRDNORM | POLLRDBAND
    pub const OUT: i16 = 0x0010; // POLLWRNORM
    pub const ERR: i16 = 0x0001;
    pub const HUP: i16 = 0x0002;
    pub const NVAL: i16 = 0x0004;
} else struct {
    pub const IN: i16 = posix.POLL.IN;
    pub const OUT: i16 = posix.POLL.OUT;
    pub const ERR: i16 = posix.POLL.ERR;
    pub const HUP: i16 = posix.POLL.HUP;
    pub const NVAL: i16 = posix.POLL.NVAL;
};

/// `PollFd.fd` for `fd`.
pub fn pollHandle(fd: posix.socket_t) @FieldType(PollFd, "fd") {
    return if (comptime is_windows) @intFromPtr(fd) else fd;
}

/// A `PollFd.fd` marking a slot no socket holds. Not for `poll`: POSIX
/// skips it, but WSAPoll reports it POLLNVAL.
pub const no_poll_handle: @FieldType(PollFd, "fd") = if (is_windows) std.math.maxInt(usize) else -1;

/// Waits up to `timeout_ms` (-1: without limit) for an event on one of
/// `fds`, and returns how many have one. A failed poll reports none.
pub fn poll(fds: []PollFd, timeout_ms: i32) usize {
    if (comptime is_windows) {
        const n = ws.WSAPoll(fds.ptr, @intCast(fds.len), timeout_ms);
        return if (n > 0) @intCast(n) else 0;
    }
    return posix.poll(fds, timeout_ms) catch 0;
}

pub const Buffer = enum {
    receive,
    send,

    fn option(self: Buffer) u32 {
        return switch (self) {
            .receive => posix.SO.RCVBUF,
            .send => posix.SO.SNDBUF,
        };
    }
};

/// The size the OS reports for `fd`'s `buffer`, null when it reports none.
/// Linux reports twice the size it was given, counting its bookkeeping.
pub fn bufferSize(fd: posix.socket_t, buffer: Buffer) ?u32 {
    var v: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, posix.SOL.SOCKET, buffer.option(), @ptrCast(&v), &len) != 0) return null;
    return if (v < 0) null else @intCast(v);
}

const BufferOption = struct {
    fd: posix.socket_t,
    buffer: Buffer,

    fn set(self: BufferOption, size: u32) bool {
        const v: c_int = @intCast(@min(size, std.math.maxInt(c_int)));
        return c.setsockopt(self.fd, posix.SOL.SOCKET, self.buffer.option(), @ptrCast(&v), @sizeOf(c_int)) == 0;
    }
};

/// Asks for a `buffer` of `requested` bytes on `fd`; 0 leaves the OS's
/// default. Some OSes refuse a size past their limit, macOS and the BSDs
/// among them, where Linux and Windows cap it instead: see negotiateSize.
/// Logs, at debug, what was asked for and what the OS then reports. `what`
/// names the socket in that log.
pub fn requestBufferSize(fd: posix.socket_t, buffer: Buffer, requested: u32, what: []const u8) void {
    if (requested == 0) return;
    const opt: BufferOption = .{ .fd = fd, .buffer = buffer };
    const accepted = negotiateSize(opt, BufferOption.set, requested, bufferSize(fd, buffer) orelse 0);
    log.transport.debug("{s}: {t} buffer of {d} bytes requested, {?d} accepted, {?d} reported", .{
        what, buffer, requested, accepted, bufferSize(fd, buffer),
    });
}

/// The size `accepts` takes: `requested`, or, each time it refuses, half
/// as much, while that still exceeds `current`. Null when it takes none.
fn negotiateSize(ctx: anytype, comptime accepts: fn (@TypeOf(ctx), u32) bool, requested: u32, current: u32) ?u32 {
    var size = requested;
    while (!accepts(ctx, size)) {
        size /= 2;
        if (size == 0 or size <= current) return null;
    }
    return size;
}

test "a refused size is asked for again at half, while that exceeds the current one" {
    const Os = struct {
        limit: u32,
        asked: u32 = 0,
        fn accepts(self: *@This(), size: u32) bool {
            self.asked += 1;
            return size <= self.limit;
        }
    };
    var os: Os = .{ .limit = 100_000 };
    try std.testing.expectEqual(@as(?u32, 62_500), negotiateSize(&os, Os.accepts, 1_000_000, 0));
    try std.testing.expectEqual(@as(u32, 5), os.asked);

    os = .{ .limit = 100_000 };
    try std.testing.expectEqual(@as(?u32, null), negotiateSize(&os, Os.accepts, 1_000_000, 200_000));
    try std.testing.expectEqual(@as(u32, 3), os.asked);

    os = .{ .limit = 0 };
    try std.testing.expectEqual(@as(?u32, null), negotiateSize(&os, Os.accepts, 3, 0));
}

test "a requested buffer size is applied, and 0 keeps the default" {
    const fd = try open(posix.AF.INET, posix.SOCK.DGRAM);
    defer close(fd);
    const default = bufferSize(fd, .send).?;
    requestBufferSize(fd, .send, 0, "test");
    try std.testing.expectEqual(default, bufferSize(fd, .send).?);
    // Small enough for every OS to accept; Linux reports it doubled.
    requestBufferSize(fd, .receive, 8192, "test");
    const got = bufferSize(fd, .receive).?;
    try std.testing.expect(got == 8192 or got == 16384);
}

test "a buffer size past the OS's limit leaves a buffer no smaller than the default" {
    const fd = try open(posix.AF.INET, posix.SOCK.DGRAM);
    defer close(fd);
    const default = bufferSize(fd, .receive).?;
    requestBufferSize(fd, .receive, std.math.maxInt(u32), "test");
    try std.testing.expect(bufferSize(fd, .receive).? >= default);
}

test "a nonblocking UDP socket with nothing queued reports would_block" {
    const fd = try open(posix.AF.INET, posix.SOCK.DGRAM);
    defer close(fd);
    var addr = posix.sockaddr.in{ .family = posix.AF.INET, .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    try std.testing.expectEqual(@as(c_int, 0), c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
    try setNonblocking(fd);
    var buf: [16]u8 = undefined;
    try std.testing.expect(c.recv(fd, &buf, buf.len, 0) < 0);
    try std.testing.expectEqual(Error.would_block, lastError());
}

test "poll reports a UDP socket readable once a datagram is queued" {
    const fd = try open(posix.AF.INET, posix.SOCK.DGRAM);
    defer close(fd);
    var addr = posix.sockaddr.in{ .family = posix.AF.INET, .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    try std.testing.expectEqual(@as(c_int, 0), c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));
    var len: posix.socklen_t = @sizeOf(@TypeOf(addr));
    try std.testing.expectEqual(@as(c_int, 0), c.getsockname(fd, @ptrCast(&addr), &len));

    var fds = [_]PollFd{.{ .fd = pollHandle(fd), .events = POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), poll(&fds, 0));

    const byte = [1]u8{1};
    try std.testing.expect(c.sendto(fd, &byte, 1, 0, @ptrCast(&addr), len) == 1);
    try std.testing.expectEqual(@as(usize, 1), poll(&fds, 1000));
    try std.testing.expect(fds[0].revents & POLL.IN != 0);
}
