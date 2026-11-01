//! Socket primitives shared by the readiness backend and the UDP and TCP
//! transports: opening and closing sockets, nonblocking mode, readiness
//! polling and the error of the socket call that just failed. BSD sockets on
//! POSIX; Winsock on Windows, where `std.posix` has no poll and Winsock
//! reports errors through `WSAGetLastError` rather than errno.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

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
